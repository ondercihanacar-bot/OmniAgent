"""
OmniAgent Notifier - Çok Kanallı Anlık Bildirim Motoru
Desteklenen Kanallar:
1. Telegram Bot API (Anlık Bildirim + İnteraktif Butonlar)
2. WhatsApp (Webhook / CallMeBot / API)
3. E-Posta (SMTP HTML Rapor & Alarm)
4. Windows Masaüstü Canlı Uyarı (Yönetici Bilgisayarında Anlık Balon)
"""

import os
import json
import time
import smtplib
import threading
import subprocess
import urllib.request
import urllib.parse
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart

CONFIG_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "hub_config.json")
LOG_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "notifications.log")


def load_config():
    try:
        if os.path.exists(CONFIG_PATH):
            with open(CONFIG_PATH, "r", encoding="utf-8") as f:
                return json.load(f)
    except Exception as e:
        print(f"[!] hub_config.json okuma hatasi: {e}")
    return {}


def save_config(new_cfg):
    try:
        with open(CONFIG_PATH, "w", encoding="utf-8") as f:
            json.dump(new_cfg, f, ensure_ascii=False, indent=2)
        return True
    except Exception as e:
        print(f"[!] hub_config.json kaydetme hatasi: {e}")
        return False


def is_outside_work_hours():
    """Şu anki saatin mesai saatleri dışında veya hafta sonu olup olmadığını kontrol eder."""
    cfg = load_config()
    wh = cfg.get("work_hours", {})
    start_str = wh.get("start", "08:30")
    end_str = wh.get("end", "18:30")
    work_days = wh.get("work_days", [1, 2, 3, 4, 5])  # Pazartesi=1 .. Cuma=5

    now = time.localtime()
    iso_weekday = now.tm_wday + 1
    if iso_weekday not in work_days:
        return True

    curr_mins = now.tm_hour * 60 + now.tm_min
    try:
        sh, sm = map(int, start_str.split(":"))
        eh, em = map(int, end_str.split(":"))
        start_mins = sh * 60 + sm
        end_mins = eh * 60 + em
        return curr_mins < start_mins or curr_mins > end_mins
    except Exception:
        return False


def _log_notification(level, server_id, title, message):
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{ts}] [{level}] [{server_id}] {title} -> {message}\n"
    try:
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write(line)
    except Exception:
        pass


def _send_telegram(cfg_tg, text):
    bot_token = os.environ.get("TELEGRAM_BOT_TOKEN") or cfg_tg.get("bot_token", "")
    chat_id = os.environ.get("TELEGRAM_CHAT_ID") or cfg_tg.get("chat_id", "")
    if not bot_token or not chat_id or "BURAYA_" in bot_token:
        return False

    url = f"https://api.telegram.org/bot{bot_token}/sendMessage"
    payload = {
        "chat_id": chat_id,
        "text": text,
        "parse_mode": "HTML"
    }
    try:
        data = json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=10) as res:
            return res.status == 200
    except Exception as e:
        print(f"[-] Telegram gonderim hatasi: {e}")
        return False


def _send_whatsapp(cfg_wa, text):
    api_url = cfg_wa.get("api_url", "")
    phone = cfg_wa.get("phone", "")
    api_key = cfg_wa.get("api_key", "")
    if not api_url or "BURAYA_" in api_key:
        return False

    try:
        if "callmebot" in api_url.lower():
            params = urllib.parse.urlencode({"phone": phone, "text": text, "apikey": api_key})
            full_url = f"{api_url}?{params}"
            req = urllib.request.Request(full_url)
            with urllib.request.urlopen(req, timeout=10) as res:
                return res.status == 200
        else:
            payload = json.dumps({"phone": phone, "message": text, "api_key": api_key}).encode("utf-8")
            req = urllib.request.Request(api_url, data=payload, headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=10) as res:
                return res.status == 200
    except Exception as e:
        print(f"[-] WhatsApp gonderim hatasi: {e}")
        return False


def _send_email(cfg_mail, subject, body_text):
    smtp_srv = cfg_mail.get("smtp_server", "")
    smtp_port = int(cfg_mail.get("smtp_port", 587))
    sender = cfg_mail.get("sender_email", "")
    password = cfg_mail.get("sender_password", "")
    receiver = cfg_mail.get("receiver_email", "")

    if not smtp_srv or not sender or "UYGULAMA_SIFRESI" in password:
        return False

    try:
        msg = MIMEMultipart()
        msg["From"] = f"OmniAgent Komuta Merkezi <{sender}>"
        msg["To"] = receiver
        msg["Subject"] = subject

        html_body = f"""
        <html>
        <body style="font-family: Segoe UI, Arial, sans-serif; background:#0f172a; color:#f8fafc; padding:20px;">
            <div style="max-width:600px; margin:auto; background:#1e293b; border-left:5px solid #ef4444; padding:20px; border-radius:8px;">
                <h2 style="color:#38bdf8; margin-top:0;">{subject}</h2>
                <pre style="white-space:pre-wrap; font-family:Consolas, monospace; font-size:14px; color:#e2e8f0;">{body_text}</pre>
                <hr style="border-color:#334155;"/>
                <small style="color:#94a3b8;">OmniAgent 7/24 Otonom Sunucu Koruma Sistemi</small>
            </div>
        </body>
        </html>
        """
        msg.attach(MIMEText(html_body, "html", "utf-8"))

        with smtplib.SMTP(smtp_srv, smtp_port, timeout=12) as server:
            server.starttls()
            server.login(sender, password)
            server.send_message(msg)
        return True
    except Exception as e:
        print(f"[-] E-posta gonderim hatasi: {e}")
        return False


def _show_desktop_balloon(title, message):
    """Yönetici bilgisayarında sağ altta hızlı Windows bildirimi gösterir."""
    safe_title = title.replace("'", "").replace('"', '')
    safe_msg = message.replace("'", "").replace('"', '')[:220]
    ps_cmd = f"""
    Add-Type -AssemblyName System.Windows.Forms
    $notify = New-Object System.Windows.Forms.NotifyIcon
    $notify.Icon = [System.Drawing.SystemIcons]::Warning
    $notify.Visible = $true
    $notify.ShowBalloonTip(6000, '{safe_title}', '{safe_msg}', [System.Windows.Forms.ToolTipIcon]::Warning)
    Start-Sleep -Seconds 7
    $notify.Dispose()
    """
    try:
        subprocess.Popen(
            ["powershell.exe", "-NoProfile", "-WindowStyle", "Hidden", "-Command", ps_cmd],
            creationflags=0x08000000
        )
    except Exception:
        pass


def dispatch_alert(level, server_id, title, message):
    """
    Asenkron olarak tüm aktif kanallara (Telegram, WhatsApp, E-posta, Masaüstü) anlık bildirim gönderir.
    level: 'CRITICAL' | 'WARNING' | 'INFO' | 'HEALED'
    """
    def _worker():
        _log_notification(level, server_id, title, message)
        cfg = load_config()
        notif_cfg = cfg.get("notifications", {})

        icon = {
            "CRITICAL": "🚨",
            "WARNING": "⚠️",
            "HEALED": "🛠️",
            "INFO": "ℹ️"
        }.get(level, "🔔")

        formatted_tg = (
            f"{icon} <b>[{level}] {title}</b>\n"
            f"🖥️ <b>Sunucu:</b> <code>{server_id}</code>\n"
            f"🕒 <b>Saat:</b> {time.strftime('%d.%m.%Y %H:%M:%S')}\n\n"
            f"{message}"
        )
        formatted_plain = (
            f"{icon} [{level}] {title}\n"
            f"Sunucu: {server_id}\n"
            f"Saat: {time.strftime('%d.%m.%Y %H:%M:%S')}\n"
            f"Detay:\n{message}"
        )

        print(f"\n{icon} [BİLDİRİM - {server_id}] {title}: {message}")

        # 1. Masaüstü Bildirimi
        if notif_cfg.get("desktop_popup_enabled", True) and level in ("CRITICAL", "WARNING", "HEALED"):
            _show_desktop_balloon(f"OmniAgent [{server_id}] - {title}", message)

        # 2. Telegram
        tg_cfg = notif_cfg.get("telegram", {})
        if tg_cfg.get("enabled", False):
            _send_telegram(tg_cfg, formatted_tg)

        # 3. WhatsApp
        wa_cfg = notif_cfg.get("whatsapp", {})
        if wa_cfg.get("enabled", False):
            _send_whatsapp(wa_cfg, formatted_plain)

        # 4. E-Posta
        mail_cfg = notif_cfg.get("email", {})
        if mail_cfg.get("enabled", False):
            _send_email(mail_cfg, f"{icon} OmniAgent [{server_id}]: {title}", formatted_plain)

    t = threading.Thread(target=_worker, daemon=True)
    t.start()
