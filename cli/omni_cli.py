"""
OmniAgent CLI - Antigravity Doğrudan Otonom Komuta Aracı
Antigravity bu aracı kullanarak tüm müşteri sunucularının durumunu çeker,
kesinti/güvenlik/elektrik raporlarını okur, sunuculara ve güvenlik duvarlarına doğrudan işlem yaptırır.
"""

import sys
import json
import time
import urllib.request
import urllib.error

if sys.platform == "win32":
    try:
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")
    except Exception:
        pass

HUB_URL = "https://omniagent-hub.onrender.com"
AUTH_TOKEN = "OmniAgentSecretToken2026"


def api_req(endpoint, method="GET", payload=None):
    url = f"{HUB_URL}{endpoint}"
    headers = {
        "X-Auth-Token": AUTH_TOKEN,
        "Content-Type": "application/json; charset=utf-8"
    }
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=15) as res:
            return json.loads(res.read().decode("utf-8"))
    except Exception as e:
        print(f"[!] Hub İletişim Hatası: {e}")
        return None


def cmd_status():
    summary = api_req("/api/reports/summary")
    servers_res = api_req("/api/servers")
    if not summary or not servers_res:
        return

    print("=" * 112)
    print(f" 🛡️  OMNIAGENT KOMUTA ÖZETİ ({summary['generated_at']})")
    print(f" 📊 Toplam: {summary['total_servers']} | 🟢 Online: {summary['online_servers']} | 🔴 Kesinti: {summary['offline_servers']} | 🛠️ Onarılan: {summary['healed_issues_24h']} | 🚨 Güvenlik: {summary['security_events_24h']}")
    print("=" * 112)

    if summary.get("predictive_warnings"):
        print(" 🔮 ÖNGÖRÜLÜ UYARILAR:")
        for w in summary["predictive_warnings"]:
            print(f"    {w}")
        print("-" * 112)

    print(f"{'DURUM':<9} {'SUNUCU ID':<18} {'İÇ IP':<15} {'WAN IP':<15} {'CPU%':<6} {'RAM%':<6} {'DİSK BOŞ':<13} {'PING/KAYIP':<14} {'GÜÇ/UPS':<12} {'AÇIK KULLANICILAR'}")
    print("-" * 112)
    for s in servers_res.get("servers", []):
        st = "🟢 ON" if s["is_online"] else f"🔴 OFF({s['last_seen_sec_ago']}s)"
        disk = f"{s['disk_free_gb']}/{s['disk_total_gb']}GB"
        net = f"{s['wan_ping_ms']}ms / %{s['packet_loss_pct']}"
        ups = f"{s['ups_status']}(%{s['ups_battery_pct']})"
        users = ",".join(s.get("active_users", [])) or "-"
        print(f"{st:<9} {s['server_id']:<18} {s['ip_address']:<15} {(s['wan_ip'] or '-'):<15} %{s['cpu_percent']:<5} %{s['ram_percent']:<5} {disk:<13} {net:<14} {ups:<12} {users}")
    print("=" * 112)


def cmd_alerts():
    res = api_req("/api/alerts")
    if not res:
        return
    print("=" * 105)
    print(f"{'TARİH/SAAT':<20} {'SEVİYE':<10} {'SUNUCU':<18} {'BAŞLIK':<32} {'DETAY'}")
    print("=" * 105)
    for a in res.get("alerts", [])[:25]:
        dt = time.strftime("%d.%m.%Y %H:%M:%S", time.localtime(a["timestamp"]))
        print(f"{dt:<20} {a['level']:<10} {a['server_id']:<18} {a['title']:<32} {a['message']}")
    print("=" * 105)


def cmd_exec(server_id, command, timeout=60):
    print(f"[*] [{server_id}] sunucusuna otonom görev gönderiliyor: {command}")
    res = api_req("/api/tasks/create", "POST", {
        "server_id": server_id,
        "command": command,
        "timeout_sec": timeout
    })
    if not res or "task_id" not in res:
        print("[-] Görev oluşturulamadı!")
        return

    task_id = res["task_id"]
    start = time.time()
    while time.time() - start < timeout + 10:
        time.sleep(1)
        tres = api_req(f"/api/tasks/{task_id}")
        if not tres:
            continue
        if tres.get("status") in ("COMPLETED", "FAILED"):
            print("\n" + "=" * 45 + f" [{server_id}] ÇIKTI " + "=" * 45)
            if tres.get("output"):
                print(tres["output"])
            if tres.get("error"):
                print(f"[!] HATA:\n{tres['error']}")
            print("=" * 104)
            return
    print("[!] Zaman aşımı!")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        cmd_status()
        sys.exit(0)

    act = sys.argv[1].lower()
    if act in ("status", "list", "summary"):
        cmd_status()
    elif act == "alerts":
        cmd_alerts()
    elif act == "exec" and len(sys.argv) >= 4:
        cmd_exec(sys.argv[2], " ".join(sys.argv[3:]))
    else:
        print("Kullanım: python omni_cli.py [status | alerts | exec <SUNUCU_ID> \"<KOMUT>\"]")
