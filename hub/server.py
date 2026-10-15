"""
OmniAgent Hub - Merkezi Komuta, İzleme, Otonom Alarm ve Web Dashboard Sunucusu (Render & Bulut Uyumlu)
Özellikler:
- 7/24 Çoklu Müşteri Sunucusu Takibi (Bulut Auto-Upsert Desteği ile)
- Yönetici Şifre Korumalı Web Komuta Paneli (Şifre: 2213)
- Elektrik Kesintisi & UPS Takibi (Kernel-Power 41 & Akü Durumu)
- İnternet Kopması, Paket Kaybı, WAN IP Değişimi ve Offline Kara Kutu Analizi
- Mesai Dışı Giriş & RDP Brute-Force Saldırı Tespiti
- Otonom Onarım (Self-Healing) Kayıtları
- Sade Öngörülü Rapor Motoru (Predictive Reports)
"""

import os
import sys
import json
import time
import uuid
import sqlite3
import threading
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
if BASE_DIR not in sys.path:
    sys.path.insert(0, BASE_DIR)

if sys.platform == "win32":
    try:
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")
    except Exception:
        pass

from notifier import dispatch_alert, is_outside_work_hours, load_config, save_config

DB_PATH = os.path.join(BASE_DIR, "omni_hub.db")
DASHBOARD_HTML_PATH = os.path.join(BASE_DIR, "dashboard.html")

cfg = load_config()
PORT = int(os.environ.get("PORT", cfg.get("hub_port", 8088)))
AUTH_TOKEN = os.environ.get("AUTH_TOKEN", cfg.get("auth_token", "OmniAgentSecretToken2026"))
ADMIN_PASSWORD = str(os.environ.get("ADMIN_PASSWORD", cfg.get("admin_password", "2213")))


def init_db():
    conn = sqlite3.connect(DB_PATH)
    cur = conn.cursor()

    cur.execute("""
    CREATE TABLE IF NOT EXISTS servers (
        server_id TEXT PRIMARY KEY,
        customer_name TEXT,
        hostname TEXT,
        os_version TEXT,
        ip_address TEXT,
        wan_ip TEXT,
        total_ram_gb REAL DEFAULT 0,
        cpu_model TEXT DEFAULT '',
        last_seen REAL,
        offline_since REAL DEFAULT 0,
        cpu_percent REAL DEFAULT 0,
        ram_percent REAL DEFAULT 0,
        disk_free_gb REAL DEFAULT 0,
        disk_total_gb REAL DEFAULT 0,
        uptime_hours REAL DEFAULT 0,
        gateway_ping_ms REAL DEFAULT 0,
        wan_ping_ms REAL DEFAULT 0,
        packet_loss_pct REAL DEFAULT 0,
        dns_ok INTEGER DEFAULT 1,
        ups_status TEXT DEFAULT 'AC_POWER',
        ups_battery_pct INTEGER DEFAULT 100,
        active_users_json TEXT DEFAULT '[]',
        services_json TEXT DEFAULT '[]',
        backup_status TEXT DEFAULT 'OK',
        firewall_ip TEXT DEFAULT '',
        status TEXT DEFAULT 'ONLINE'
    )
    """)

    cur.execute("""
    CREATE TABLE IF NOT EXISTS tasks (
        task_id TEXT PRIMARY KEY,
        server_id TEXT,
        command TEXT,
        task_type TEXT DEFAULT 'POWERSHELL',
        status TEXT,
        created_at REAL,
        dispatched_at REAL,
        completed_at REAL,
        exit_code INTEGER,
        output TEXT,
        error TEXT,
        timeout_sec INTEGER DEFAULT 60
    )
    """)

    cur.execute("""
    CREATE TABLE IF NOT EXISTS alerts (
        alert_id INTEGER PRIMARY KEY AUTOINCREMENT,
        server_id TEXT,
        timestamp REAL,
        level TEXT,
        category TEXT,
        title TEXT,
        message TEXT
    )
    """)

    conn.commit()
    conn.close()


def get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def record_alert(server_id, level, category, title, message, notify=True):
    conn = get_db()
    cur = conn.cursor()
    cur.execute("""
        INSERT INTO alerts (server_id, timestamp, level, category, title, message)
        VALUES (?, ?, ?, ?, ?, ?)
    """, (server_id, time.time(), level, category, title, message))
    conn.commit()
    conn.close()
    if notify:
        dispatch_alert(level, server_id, title, message)


def watchdog_loop():
    """7/24 Kesinti Bekçisi: Sinyal kesildiğinde anında Elektrik/İnternet kesintisi uyarısı üretir."""
    while True:
        try:
            current_cfg = load_config()
            threshold = int(current_cfg.get("offline_threshold_sec", 35))
            now = time.time()

            conn = get_db()
            cur = conn.cursor()
            cur.execute("SELECT server_id, customer_name, hostname, last_seen, status FROM servers")
            rows = cur.fetchall()

            for r in rows:
                sid = r["server_id"]
                last_seen = r["last_seen"] or 0
                status = r["status"]
                diff = now - last_seen

                if status == "ONLINE" and diff > threshold:
                    cur.execute(
                        "UPDATE servers SET status = 'OFFLINE', offline_since = ? WHERE server_id = ?",
                        (now, sid)
                    )
                    conn.commit()
                    msg = (
                        f"{sid} ({r['hostname']}) sunucusundan {int(diff)} saniyedir sinyal alınamıyor!\n"
                        f"Olası Sebep: Elektrik Kesintisi veya İnternet (WAN) Kopması.\n"
                        f"Bağlantı geri geldiğinde ajanın Kara Kutu kaydından kesin teşhis raporlanacaktır."
                    )
                    record_alert(sid, "CRITICAL", "OUTAGE", "SUNUCU İLETİŞİMİ KESİLDİ", msg, notify=True)

            conn.close()
        except Exception as e:
            print(f"[-] Watchdog hatası: {e}")

        time.sleep(8)


def generate_predictive_summary():
    conn = get_db()
    cur = conn.cursor()
    cur.execute("SELECT * FROM servers ORDER BY server_id ASC")
    servers = [dict(r) for r in cur.fetchall()]

    since_24h = time.time() - 86400
    cur.execute("SELECT * FROM alerts WHERE timestamp > ? ORDER BY timestamp DESC", (since_24h,))
    recent_alerts = [dict(r) for r in cur.fetchall()]
    conn.close()

    online_count = sum(1 for s in servers if s["status"] == "ONLINE")
    offline_count = len(servers) - online_count

    warnings = []
    for s in servers:
        sid = s["server_id"]
        if s["status"] != "ONLINE":
            warnings.append(f"🔴 [{sid}] Şu an ERİŞİLEMİYOR (İnternet veya Elektrik Kesik)!")
            continue

        if s["disk_total_gb"] > 0:
            used_pct = ((s["disk_total_gb"] - s["disk_free_gb"]) / s["disk_total_gb"]) * 100
            if used_pct >= 88:
                warnings.append(f"🟠 [{sid}] C: Diski %{used_pct:.1f} dolu (Kalan: {s['disk_free_gb']} GB). Otomatik temizlik devrede.")

        if s["packet_loss_pct"] >= 10 or s["wan_ping_ms"] >= 250:
            warnings.append(
                f"🟡 [{sid}] Ağ kalitesinde bozulma: Paket Kaybı %{s['packet_loss_pct']}, Ping {s['wan_ping_ms']}ms. RDP donmaları yaşanabilir."
            )

        if s["ups_status"] == "ON_BATTERY":
            warnings.append(f"⚡ [{sid}] ELEKTRİK KESİK! Sunucu UPS Aküsüyle çalışıyor (Akü: %{s['ups_battery_pct']}).")

        if s["backup_status"] and s["backup_status"] not in ("OK", "YAPILANDIRILMADI"):
            warnings.append(f"💾 [{sid}] Yedekleme Uyarısı: {s['backup_status']}")

    healed_count = sum(1 for a in recent_alerts if a["category"] == "SELF_HEAL")
    security_count = sum(1 for a in recent_alerts if a["category"] in ("BRUTE_FORCE", "AFTER_HOURS"))
    outage_count = sum(1 for a in recent_alerts if a["category"] in ("OUTAGE", "POWER", "INTERNET"))

    return {
        "generated_at": time.strftime("%d.%m.%Y %H:%M:%S"),
        "total_servers": len(servers),
        "online_servers": online_count,
        "offline_servers": offline_count,
        "healed_issues_24h": healed_count,
        "security_events_24h": security_count,
        "outage_events_24h": outage_count,
        "predictive_warnings": warnings
    }


class OmniHubHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        if "/api/agent/heartbeat" in self.path or "/api/agent/tasks/" in self.path or "/api/servers" in self.path:
            return
        sys.stderr.write("%s - - [%s] %s\n" % (self.address_string(), self.log_date_time_string(), format % args))

    def _send_json(self, status_code, data):
        body = json.dumps(data, ensure_ascii=False, indent=2).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, X-Auth-Token, X-Admin-Password")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.end_headers()
        self.wfile.write(body)

    def _send_html(self, html_content):
        body = html_content.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self):
        length = int(self.headers.get("Content-Length", 0))
        if length == 0:
            return {}
        return json.loads(self.rfile.read(length).decode("utf-8"))

    def _check_auth(self):
        token = self.headers.get("X-Auth-Token")
        admin_pw = self.headers.get("X-Admin-Password")
        curr_cfg = load_config()
        valid_token = os.environ.get("AUTH_TOKEN", curr_cfg.get("auth_token", AUTH_TOKEN))
        valid_pw = str(os.environ.get("ADMIN_PASSWORD", curr_cfg.get("admin_password", ADMIN_PASSWORD)))
        return (token == valid_token) or (admin_pw == valid_pw)

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, X-Auth-Token, X-Admin-Password")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.end_headers()

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path

        if path in ("/", "/dashboard"):
            if os.path.exists(DASHBOARD_HTML_PATH):
                with open(DASHBOARD_HTML_PATH, "r", encoding="utf-8") as f:
                    self._send_html(f.read())
            else:
                self._send_html("<h1>OmniAgent Hub Aktif</h1>")
            return

        if path == "/api/health":
            self._send_json(200, {"status": "ok", "time": time.time(), "service": "OmniAgent Central Cloud Hub"})
            return

        if not self._check_auth():
            self._send_json(401, {"error": "Yetkisiz erişim. Lütfen yönetici şifresi ile giriş yapın."})
            return

        conn = get_db()
        cur = conn.cursor()

        if path.startswith("/api/agent/tasks/"):
            server_id = path.split("/api/agent/tasks/")[1]
            cur.execute("""
                SELECT task_id, command, task_type, timeout_sec
                FROM tasks
                WHERE server_id = ? AND status = 'PENDING'
                ORDER BY created_at ASC
            """, (server_id,))
            rows = cur.fetchall()
            tasks = []
            now = time.time()
            for r in rows:
                tasks.append({
                    "task_id": r["task_id"],
                    "command": r["command"],
                    "task_type": r["task_type"],
                    "timeout_sec": r["timeout_sec"]
                })
                cur.execute("UPDATE tasks SET status = 'DISPATCHED', dispatched_at = ? WHERE task_id = ?", (now, r["task_id"]))
            conn.commit()
            conn.close()
            self._send_json(200, {"tasks": tasks})
            return

        if path == "/api/servers":
            cur.execute("SELECT * FROM servers ORDER BY server_id ASC")
            rows = cur.fetchall()
            now = time.time()
            threshold = int(load_config().get("offline_threshold_sec", 35))
            servers = []
            for r in rows:
                d = dict(r)
                diff = now - (d["last_seen"] or 0)
                d["last_seen_sec_ago"] = int(diff)
                d["is_online"] = (diff <= threshold) and (d["status"] == "ONLINE")
                try:
                    d["active_users"] = json.loads(d.get("active_users_json") or "[]")
                except Exception:
                    d["active_users"] = []
                try:
                    d["services"] = json.loads(d.get("services_json") or "[]")
                except Exception:
                    d["services"] = []
                servers.append(d)
            conn.close()
            self._send_json(200, {"servers": servers})
            return

        if path == "/api/reports/summary":
            conn.close()
            self._send_json(200, generate_predictive_summary())
            return

        if path == "/api/alerts":
            cur.execute("SELECT * FROM alerts ORDER BY timestamp DESC LIMIT 80")
            alerts = [dict(r) for r in cur.fetchall()]
            conn.close()
            self._send_json(200, {"alerts": alerts})
            return

        if path.startswith("/api/tasks/"):
            task_id = path.split("/api/tasks/")[1]
            cur.execute("SELECT * FROM tasks WHERE task_id = ?", (task_id,))
            r = cur.fetchone()
            conn.close()
            if not r:
                self._send_json(404, {"error": "Görev bulunamadı"})
                return
            self._send_json(200, dict(r))
            return

        if path == "/api/config":
            conn.close()
            self._send_json(200, load_config())
            return

        conn.close()
        self._send_json(404, {"error": "Endpoint bulunamadı"})

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path

        try:
            data = self._read_json()
        except Exception as e:
            self._send_json(400, {"error": f"Geçersiz JSON: {e}"})
            return

        # 0. Yönetici Giriş Doğrulama (/api/auth/login)
        if path == "/api/auth/login":
            pw = str(data.get("password", "")).strip()
            curr_cfg = load_config()
            valid_pw = str(os.environ.get("ADMIN_PASSWORD", curr_cfg.get("admin_password", ADMIN_PASSWORD)))
            valid_token = os.environ.get("AUTH_TOKEN", curr_cfg.get("auth_token", AUTH_TOKEN))
            if pw == valid_pw:
                self._send_json(200, {"status": "ok", "auth_token": valid_token})
            else:
                self._send_json(401, {"status": "error", "error": "Hatalı yönetici şifresi!"})
            return

        if not self._check_auth():
            self._send_json(401, {"error": "Yetkisiz erişim."})
            return

        conn = get_db()
        cur = conn.cursor()
        now = time.time()

        # 1. Ajan Kaydı ve Açılış / Elektrik Kesintisi Raporu
        if path == "/api/agent/register":
            sid = data.get("server_id") or str(uuid.uuid4())[:8]
            cname = data.get("customer_name", sid)
            hostname = data.get("hostname", "Unknown")
            os_ver = data.get("os_version", "Windows Server")
            ip = data.get("ip_address", self.client_address[0])
            wan_ip = data.get("wan_ip", "")
            ram_gb = data.get("total_ram_gb", 0)
            cpu = data.get("cpu_model", "Unknown")
            fw_ip = data.get("firewall_ip", "")
            unexpected_shutdown = data.get("unexpected_shutdown_details", "")

            cur.execute("""
                INSERT INTO servers (server_id, customer_name, hostname, os_version, ip_address, wan_ip, total_ram_gb, cpu_model, firewall_ip, last_seen, status)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'ONLINE')
                ON CONFLICT(server_id) DO UPDATE SET
                    customer_name=excluded.customer_name,
                    hostname=excluded.hostname,
                    os_version=excluded.os_version,
                    ip_address=excluded.ip_address,
                    wan_ip=excluded.wan_ip,
                    total_ram_gb=excluded.total_ram_gb,
                    cpu_model=excluded.cpu_model,
                    firewall_ip=excluded.firewall_ip,
                    last_seen=excluded.last_seen,
                    status='ONLINE'
            """, (sid, cname, hostname, os_ver, ip, wan_ip, ram_gb, cpu, fw_ip, now))
            conn.commit()
            conn.close()

            if unexpected_shutdown:
                record_alert(
                    sid, "CRITICAL", "POWER",
                    "⚡ ELEKTRİK KESİNTİSİ SONRASI AÇILIŞ",
                    f"Sunucu ani güç kaybı (Kernel-Power 41 / 6008) sonrası yeniden başladı!\nDetay: {unexpected_shutdown}"
                )
            else:
                record_alert(
                    sid, "INFO", "SYSTEM",
                    "🟢 AJAN DEVREYE GİRDİ",
                    f"{sid} ({hostname} - {ip}) otonom korumaya bağlandı.",
                    notify=False
                )

            self._send_json(200, {"status": "registered", "server_id": sid})
            return

        # 2. Ajan Kalp Atışı (Heartbeat) & Bulut Auto-Upsert
        if path == "/api/agent/heartbeat":
            sid = data.get("server_id")
            if not sid:
                conn.close()
                self._send_json(400, {"error": "server_id zorunlu"})
                return

            cur.execute("SELECT status, offline_since, wan_ip, ups_status FROM servers WHERE server_id = ?", (sid,))
            prev = cur.fetchone()
            conn.close()

            if prev and prev["status"] == "OFFLINE":
                offline_dur = int(now - (prev["offline_since"] or now))
                mins, secs = divmod(offline_dur, 60)
                outage_report = data.get("offline_outage_report", "")
                diagnosis = outage_report if outage_report else "Bağlantı yeniden sağlandı."
                record_alert(
                    sid, "INFO", "OUTAGE",
                    "🌐 SUNUCU BAĞLANTISI GERİ GELDİ",
                    f"Kesinti Süresi: {mins} dk {secs} sn.\nTeşhis: {diagnosis}"
                )
            elif data.get("offline_outage_report"):
                record_alert(
                    sid, "WARNING", "INTERNET",
                    "🌐 İNTERNET KESİNTİ RAPORU (KARA KUTU)",
                    data.get("offline_outage_report")
                )

            new_wan = data.get("wan_ip", "")
            if prev and prev["wan_ip"] and new_wan and prev["wan_ip"] != new_wan:
                record_alert(
                    sid, "WARNING", "INTERNET",
                    "🔄 DIŞ (WAN) IP ADRESİ DEĞİŞTİ",
                    f"Eski Dış IP: {prev['wan_ip']} -> Yeni Dış IP: {new_wan}\n(İnternet hattı yedek hatta geçmiş veya IP yenilenmiş olabilir.)"
                )

            ups_st = data.get("ups_status", "AC_POWER")
            ups_pct = data.get("ups_battery_pct", 100)
            if ups_st == "ON_BATTERY" and (not prev or prev["ups_status"] != "ON_BATTERY"):
                record_alert(
                    sid, "CRITICAL", "POWER",
                    "🔋 ELEKTRİK KESİLDİ - UPS AKÜ DEVREDE!",
                    f"Sunucu şu an UPS aküsü üzerinden çalışıyor! Kalan Akü: %{ups_pct}"
                )
            elif ups_st == "AC_POWER" and prev and prev["ups_status"] == "ON_BATTERY":
                record_alert(
                    sid, "INFO", "POWER",
                    "⚡ ŞEBEKE ELEKTRİĞİ GERİ GELDİ",
                    f"Elektrik normale döndü, UPS şarj oluyor (Akü: %{ups_pct})."
                )

            for heal_msg in data.get("healed_events", []):
                record_alert(
                    sid, "HEALED", "SELF_HEAL",
                    "🛠️ OTONOM ONARIM GERÇEKLEŞTİRİLDİ",
                    heal_msg
                )

            for sec_msg in data.get("security_events", []):
                record_alert(
                    sid, "CRITICAL", "BRUTE_FORCE",
                    "🛡️ SALDIRI TESPİT EDİLDİ VE ENGELLENDİ",
                    sec_msg
                )

            for login_ev in data.get("new_logins", []):
                user_name = login_ev.get("user", "Bilinmiyor")
                src_ip = login_ev.get("ip", "Yerel")
                logon_type = login_ev.get("type", "RDP")
                if is_outside_work_hours():
                    record_alert(
                        sid, "CRITICAL", "AFTER_HOURS",
                        "🌙 MESAİ SAATLERİ DIŞINDA SUNUCU GİRİŞİ!",
                        f"Kullanıcı: {user_name}\nKaynak IP: {src_ip}\nGiriş Tipi: {logon_type}\nMesai saatleri dışında sunucuda oturum açıldı!"
                    )
                else:
                    record_alert(
                        sid, "INFO", "LOGIN",
                        "👤 KULLANICI OTURUM AÇTI",
                        f"Kullanıcı: {user_name} | IP: {src_ip} ({logon_type})",
                        notify=False
                    )

            # Bulut Auto-Upsert: Render konteyneri yeniden başlasa bile sunucu kaydını otomatik oluşturur/günceller
            conn = get_db()
            cur = conn.cursor()
            cur.execute("""
                INSERT INTO servers (
                    server_id, customer_name, hostname, os_version, ip_address, wan_ip, total_ram_gb,
                    last_seen, offline_since, status, cpu_percent, ram_percent, disk_free_gb, disk_total_gb,
                    uptime_hours, gateway_ping_ms, wan_ping_ms, packet_loss_pct, dns_ok,
                    ups_status, ups_battery_pct, active_users_json, services_json, backup_status
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, 'ONLINE', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(server_id) DO UPDATE SET
                    customer_name = COALESCE(NULLIF(excluded.customer_name, ''), servers.customer_name),
                    hostname = COALESCE(NULLIF(excluded.hostname, ''), servers.hostname),
                    os_version = COALESCE(NULLIF(excluded.os_version, ''), servers.os_version),
                    ip_address = COALESCE(NULLIF(excluded.ip_address, ''), servers.ip_address),
                    wan_ip = COALESCE(NULLIF(excluded.wan_ip, ''), servers.wan_ip),
                    total_ram_gb = CASE WHEN excluded.total_ram_gb > 0 THEN excluded.total_ram_gb ELSE servers.total_ram_gb END,
                    last_seen = excluded.last_seen,
                    offline_since = 0,
                    status = 'ONLINE',
                    cpu_percent = excluded.cpu_percent,
                    ram_percent = excluded.ram_percent,
                    disk_free_gb = excluded.disk_free_gb,
                    disk_total_gb = excluded.disk_total_gb,
                    uptime_hours = excluded.uptime_hours,
                    gateway_ping_ms = excluded.gateway_ping_ms,
                    wan_ping_ms = excluded.wan_ping_ms,
                    packet_loss_pct = excluded.packet_loss_pct,
                    dns_ok = excluded.dns_ok,
                    ups_status = excluded.ups_status,
                    ups_battery_pct = excluded.ups_battery_pct,
                    active_users_json = excluded.active_users_json,
                    services_json = excluded.services_json,
                    backup_status = excluded.backup_status
            """, (
                sid,
                data.get("customer_name", sid),
                data.get("hostname", sid),
                data.get("os_version", "Windows Server"),
                data.get("ip_address", self.client_address[0]),
                new_wan,
                data.get("total_ram_gb", 0),
                now,
                data.get("cpu_percent", 0),
                data.get("ram_percent", 0),
                data.get("disk_free_gb", 0),
                data.get("disk_total_gb", 0),
                data.get("uptime_hours", 0),
                data.get("gateway_ping_ms", 0),
                data.get("wan_ping_ms", 0),
                data.get("packet_loss_pct", 0),
                1 if data.get("dns_ok", True) else 0,
                ups_st,
                ups_pct,
                json.dumps(data.get("active_users", []), ensure_ascii=False),
                json.dumps(data.get("services", []), ensure_ascii=False),
                data.get("backup_status", "OK")
            ))
            conn.commit()
            conn.close()

            self._send_json(200, {"status": "ok"})
            return

        # 3. Görev Sonucu
        if path == "/api/agent/task_result":
            task_id = data.get("task_id")
            exit_code = data.get("exit_code", 0)
            output = data.get("output", "")
            error = data.get("error", "")
            status = "COMPLETED" if exit_code == 0 else "FAILED"

            cur.execute("""
                UPDATE tasks
                SET status = ?, exit_code = ?, output = ?, error = ?, completed_at = ?
                WHERE task_id = ?
            """, (status, exit_code, output, error, now, task_id))
            conn.commit()
            conn.close()
            self._send_json(200, {"status": "acknowledged"})
            return

        # 4. Yeni Görev Oluştur (Tek Sunucu veya ALL ile Tüm Sunuculara)
        if path == "/api/tasks/create":
            sid = data.get("server_id")
            command = data.get("command")
            task_type = data.get("task_type", "POWERSHELL")
            timeout_sec = int(data.get("timeout_sec", 60))

            if not sid or not command:
                conn.close()
                self._send_json(400, {"error": "server_id ve command zorunlu"})
                return

            if sid == "ALL":
                cur.execute("SELECT server_id FROM servers WHERE status = 'ONLINE'")
                targets = [r["server_id"] for r in cur.fetchall()]
                last_tid = ""
                for t_sid in targets:
                    last_tid = str(uuid.uuid4())[:8]
                    cur.execute("""
                        INSERT INTO tasks (task_id, server_id, command, task_type, status, created_at, timeout_sec)
                        VALUES (?, ?, ?, ?, 'PENDING', ?, ?)
                    """, (last_tid, t_sid, command, task_type, now, timeout_sec))
                conn.commit()
                conn.close()
                self._send_json(200, {"task_id": last_tid, "status": "broadcast_queued", "count": len(targets)})
                return

            task_id = str(uuid.uuid4())[:8]
            cur.execute("""
                INSERT INTO tasks (task_id, server_id, command, task_type, status, created_at, timeout_sec)
                VALUES (?, ?, ?, ?, 'PENDING', ?, ?)
            """, (task_id, sid, command, task_type, now, timeout_sec))
            conn.commit()
            conn.close()
            self._send_json(200, {"task_id": task_id, "status": "queued"})
            return

        # 5. Bildirim ve Mesai Ayarlarını Güncelle
        if path == "/api/config/update":
            conn.close()
            ok = save_config(data)
            self._send_json(200, {"status": "saved" if ok else "error"})
            return

        # 6. Sunucu Kaydı Silme (Panelden veya API'den)
        if path == "/api/servers/delete":
            sid = data.get("server_id")
            if sid:
                cur.execute("DELETE FROM servers WHERE server_id = ?", (sid,))
                cur.execute("DELETE FROM tasks WHERE server_id = ?", (sid,))
                cur.execute("DELETE FROM alerts WHERE server_id = ?", (sid,))
                conn.commit()
                conn.close()
                self._send_json(200, {"status": "deleted", "server_id": sid})
                return
            conn.close()
            self._send_json(400, {"error": "server_id gerekli"})
            return

        # 7. Test Bildirimi Gönder
        if path == "/api/notifications/test":
            conn.close()
            dispatch_alert(
                "WARNING",
                "TEST-SUNUCU",
                "🔔 OMNIAGENT BİLDİRİM TESTİ",
                "Bu bir test mesajıdır. Elektrik, internet, güvenlik ve otonom onarım bildirimleriniz aktif!"
            )
            self._send_json(200, {"status": "sent"})
            return

        conn.close()
        self._send_json(404, {"error": "Endpoint bulunamadı"})


def run_server():
    init_db()
    wd = threading.Thread(target=watchdog_loop, daemon=True)
    wd.start()

    server_address = ("0.0.0.0", PORT)
    httpd = ThreadingHTTPServer(server_address, OmniHubHandler)
    print("==========================================================")
    print(" 🛡️  OmniAgent Merkezi Komuta & Otonom Yönetim Hub Aktif!")
    print(f" 🌐 Canlı Komuta Paneli : http://127.0.0.1:{PORT}")
    print(f" 🔒 Yönetici Şifresi    : {ADMIN_PASSWORD}")
    print("==========================================================")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n[*] OmniAgent Hub durduruldu.")
        httpd.server_close()


if __name__ == "__main__":
    run_server()
