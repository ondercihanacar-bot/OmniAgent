# 🛡️ OmniAgent — 7/24 Tam Otonom Sunucu, Güvenlik Duvarı & Kesinti Yönetim Sistemi

**OmniAgent**, birden fazla müşteri sunucusunu (**Windows Server 2019 / 2022 / 2025**) tek bir merkezden ve doğrudan **Antigravity** üzerinden tam otonom olarak izlemek, hataları insan müdahalesi olmadan kendi kendine onarmak, elektrik/internet kesintilerini kök nedenleriyle raporlamak ve güvenlik duvarı (SonicWall) işlemlerini izin istemeden yürütmek için tasarlanmıştır.

---

## 🌟 Temel Yetenekler

1. **⚡ Elektrik Kesintisi & UPS Takibi:**
   * UPS bağlıysa şebeke elektriği kesildiği saniyede **UPS Akü Modu** uyarısı ve kalan yüzdeyi bildirir.
   * Ani kapanmalarda sunucu tekrar açılır açılmaz Windows Event Log (`Kernel-Power 41` & `Event 6008`) kaydını analiz ederek **Elektrik Kesintisi Sonrası Açılış Raporu** gönderir.
2. **🌐 İnternet Kopması, Ağ Kalitesi & Kara Kutu (Offline Log):**
   * İç Ağ Geçidi (SonicWall), Dış İnternet (`8.8.8.8`) ve DNS katmanlarını ayrı ayrı test eder.
   * **Ping (ms)** ve **Paket Kaybı (%)** ölçerek RDP donmalarını önceden haber verir.
   * **Dış (WAN) IP** değişimini takip ederek yedek internet (Failover) geçişlerini yakalar.
   * İnternet koptuğunda yerel **Kara Kutu (`offline_outage.json`)** dosyasına kesintinin başlangıcını ve sebebini (*SonicWall erişilebilir miydi, yoksa ISS/Türk Telekom WAN hattı mı koptu?*) kaydeder; internet geldiği saniye merkeze tam raporu iletir.
3. **🌙 Mesai Saatleri Dışı Giriş & 🛡️ Saldırı (Brute-Force) Kalkanı:**
   * Mesai saatleri dışında veya hafta sonu sunucuda oturum açıldığında anında **Kritik Alarm** üretir.
   * Başarısız şifre denemelerini (`Event ID 4625`) izler ve saldırgan yabancı IP adreslerini **otonom olarak** Windows Güvenlik Duvarında engeller.
4. **🛠️ Otonom Onarım (Self-Healing):**
   * Kritik servisler (`Spooler`, `SQL`, `Senkron/ERP`, `W32Time` vb.) durduğunda sana sormadan otomatik olarak yeniden başlatır ve raporlar.
   * Disk doluluğu %90'ı aştığında otomatik `Temp` temizliği yaparak alan açar.
5. **🔥 Tam Yetkili Güvenlik Duvarı (SonicWall) Ajanı:**
   * İzin istemeden doğrudan SonicWall API/Web üzerinden IP Whitelist ekleme, Senkron erişim tanımlama ve saldırgan IP engelleme işlemlerini yapar.
6. **📲 Çok Kanallı Anlık Bildirim:**
   * **Telegram**, **WhatsApp**, **E-Posta (SMTP)** ve **Masaüstü Canlı Uyarı** desteği.

---

## 📁 Proje Dizin Yapısı

```text
OmniAgent/
├── Baslat_OmniAgent.bat          # Tek tıkla Hub, Yerel Ajan ve Canlı Web Panelini başlatır
├── hub/
│   ├── server.py                 # Merkezi Komuta Sunucusu, Kesinti Bekçisi (Watchdog) & API (Port 8088)
│   ├── dashboard.html            # Canlı Web Komuta Merkezi (http://localhost:8088)
│   ├── notifier.py               # Telegram, WhatsApp, E-Posta ve Masaüstü Bildirim Motoru
│   └── hub_config.json           # Mesai saatleri ve bildirim kanalı ayarları
├── agent/
│   ├── OmniAgent.ps1             # 7/24 Müşteri Sunucusunda çalışan otonom PowerShell ajanı
│   ├── config.json               # Sunucu kimliği, izlenen servisler ve eşik değerleri
│   └── Install-OmniAgent.ps1     # Sunucu yeniden başladığında oturum açmadan çalışan 7/24 SYSTEM kurulumu
├── firewall/
│   └── sonicwall_autonomous.py   # Tam yetkili SonicWall kural ve IP yönetim modülü
├── cli/
│   └── omni_cli.py               # Antigravity doğrudan komuta ve sorgulama köprüsü
└── mascot/
    ├── OmniRobot.ps1             # Masaüstü kırmızı gözlü canlı tarama robotu
    └── gemini_robot_opt.mp4      # Optimize edilmiş düşük RAM tüketimli robot animasyonu
```
