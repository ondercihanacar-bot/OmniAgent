<#
.SYNOPSIS
    OmniAgent - 7/24 Tam Otonom Windows Server Koruma, İzleme ve Onarım Ajanı
.DESCRIPTION
    - Elektrik Kesintisi & UPS Takibi (Kernel-Power 41 / 6008 ve Akü Durumu)
    - İnternet Kopması, Paket Kaybı, WAN IP Değişimi ve Offline Kara Kutu Kaydı
    - Mesai Saatleri Dışı Giriş & RDP Brute-Force Otomatik IP Engelleme
    - Otonom Onarım (Çöken Servisleri Başlatma, Otomatik Disk Temp Temizliği)
    - Uzaktan PowerShell & Güvenlik Duvarı İşlem Yürütücü
#>

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
$ErrorActionPreference = "Continue"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigFile = Join-Path $ScriptDir "config.json"
$OutageLogFile = Join-Path $ScriptDir "offline_outage.json"

if (-not (Test-Path $ConfigFile)) {
    Write-Host "[!] HATA: config.json bulunamadi!" -ForegroundColor Red
    exit 1
}

$Config = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
$HubUrl = $Config.HubUrl.TrimEnd("/")
$AuthToken = $Config.AuthToken
$ServerId = if ($Config.ServerId) { $Config.ServerId } else { $env:COMPUTERNAME }
$CustomerName = if ($Config.CustomerName) { $Config.CustomerName } else { $ServerId }
$HeartbeatInterval = if ($Config.HeartbeatIntervalSec) { [int]$Config.HeartbeatIntervalSec } else { 6 }
$GatewayIp = $Config.GatewayIp

# Durum İzleme Değişkenleri
$script:KnownActiveUsers = @()
$script:FirstRunUsersChecked = $false
$script:LastDiskCleanTime = (Get-Date).AddHours(-12)
$script:LastWanIpCheck = (Get-Date).AddMinutes(-10)
$script:CachedWanIp = ""
$script:BlockedIps = @{}
$script:ConsecutiveWanFailures = 0
$script:ConsecutiveHubFailures = 0
$script:GhostMaxIdle = 120
$script:GhostExcludeUsers = @("Administrator", "admin.senkron")
$script:LastAuditCheck = (Get-Date).AddMinutes(-5)

# İntihar / Tehlikeli Komut Kara Listesi
$Blacklist = @(
    "Disable-NetAdapter",
    "Remove-NetIPAddress",
    "format c:",
    "del /s /q c:\windows",
    "rmdir /s /q c:\windows",
    "Remove-Item -Recurse -Force C:\Windows"
)

Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host " 🛡️  OmniAgent 7/24 Otonom Sunucu Ajanı Başlatıldı" -ForegroundColor Green
Write-Host " 🖥️  Sunucu ID : $ServerId ($CustomerName)" -ForegroundColor Yellow
Write-Host " 🌐 Merkez Hub: $HubUrl" -ForegroundColor Yellow
Write-Host "=========================================================" -ForegroundColor Cyan

function Invoke-HubRequest {
    param (
        [string]$Path,
        [string]$Method = "GET",
        [object]$Body = $null
    )
    $headers = @{
        "X-Auth-Token" = $AuthToken
        "Content-Type" = "application/json; charset=utf-8"
    }
    $url = "$HubUrl$Path"
    try {
        if ($Body) {
            $jsonBody = $Body | ConvertTo-Json -Depth 6 -Compress
            return Invoke-RestMethod -Uri $url -Method $Method -Headers $headers -Body ([System.Text.Encoding]::UTF8.GetBytes($jsonBody)) -TimeoutSec 12
        } else {
            return Invoke-RestMethod -Uri $url -Method $Method -Headers $headers -TimeoutSec 12
        }
    } catch {
        return $null
    }
}

function Get-PowerOutageBootReport {
    <# Sunucu yeni açıldığında son 2 saat içinde Kernel-Power 41 veya Event 6008 (Ani Elektrik Kesintisi) var mı inceler #>
    try {
        $since = (Get-Date).AddHours(-2)
        $kpEvents = Get-WinEvent -FilterHashtable @{LogName='System'; Id=41,6008; StartTime=$since} -MaxEvents 5 -ErrorAction SilentlyContinue
        if ($kpEvents) {
            $latest = $kpEvents | Select-Object -First 1
            return "Event ID $($latest.Id) ($($latest.TimeCreated.ToString('dd.MM.yyyy HH:mm:ss'))): $($latest.Message.Split([Environment]::NewLine)[0])"
        }
    } catch {}
    return ""
}

function Get-UpsStatus {
    <# UPS (Kesintisiz Güç Kaynağı) veya Batarya durumunu okur #>
    try {
        $bat = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($bat) {
            # BatteryStatus = 2 -> AC Power (Şebeke elektriği var), 1 -> Discharging (Elektrik kesik, Aküde!)
            $st = if ($bat.BatteryStatus -eq 1) { "ON_BATTERY" } else { "AC_POWER" }
            $pct = if ($null -ne $bat.EstimatedChargeRemaining) { [int]$bat.EstimatedChargeRemaining } else { 100 }
            return @{ status = $st; pct = $pct }
        }
    } catch {}
    return @{ status = "AC_POWER"; pct = 100 }
}

function Test-NetworkAndInternet {
    <# 3 Katmanlı Ağ Kalitesi ve İnternet Kontrolü (Gateway, WAN Ping/PacketLoss, DNS, WAN IP) #>
    # 1. WAN Ping & Paket Kaybı (8.8.8.8 veya 1.1.1.1 üzerinden)
    $wanPing = 0
    $lossPct = 100
    $wanOk = $false
    try {
        $pings = Test-Connection -ComputerName "8.8.8.8" -Count 2 -ErrorAction SilentlyContinue
        if (-not $pings) {
            $pings = Test-Connection -ComputerName "1.1.1.1" -Count 2 -ErrorAction SilentlyContinue
        }
        if ($pings) {
            $wanOk = $true
            $received = @($pings).Count
            $lossPct = [Math]::Round(((2 - $received) / 2) * 100, 0)
            $wanPing = [Math]::Round(($pings | Measure-Object -Property ResponseTime -Average).Average, 0)
        }
    } catch {}

    # 2. Gateway Kontrolü (Eğer WAN açıksa Gateway üzerinden geçtiği için kesinlikle aktiftir)
    $gwPing = 0
    $gwOk = $false
    if ($wanOk) {
        $gwOk = $true
        if ($GatewayIp) {
            try {
                $p = Test-Connection -ComputerName $GatewayIp -Count 1 -ErrorAction SilentlyContinue
                if ($p) { $gwPing = [int]$p.ResponseTime }
            } catch {}
        }
    } elseif ($GatewayIp) {
        # WAN kapalıysa ağ geçidini test et (Switch/Firewall mu kapalı, yoksa Telekom mu?)
        try {
            $p = Test-Connection -ComputerName $GatewayIp -Count 2 -ErrorAction SilentlyContinue
            if ($p) {
                $gwPing = [int]($p | Measure-Object -Property ResponseTime -Average).Average
                $gwOk = $true
            }
        } catch { $gwOk = $false }
    }

    # Her 5 dakikada bir Dış (WAN) IP kontrolü
    if ($wanOk -and ((Get-Date) - $script:LastWanIpCheck).TotalMinutes -ge 5) {
        try {
            $ipRes = Invoke-RestMethod -Uri "https://api.ipify.org?format=json" -TimeoutSec 5 -ErrorAction SilentlyContinue
            if ($ipRes -and $ipRes.ip) {
                $script:CachedWanIp = $ipRes.ip
                $script:LastWanIpCheck = Get-Date
            }
        } catch {}
    }

    return @{
        gateway_ok = $gwOk
        gateway_ping_ms = $gwPing
        wan_ok = $wanOk
        wan_ping_ms = $wanPing
        packet_loss_pct = $lossPct
        wan_ip = $script:CachedWanIp
    }
}

function Record-OfflineOutage {
    param([hashtable]$NetInfo)
    if (-not (Test-Path $OutageLogFile)) {
        $reason = if (-not $NetInfo.gateway_ok) {
            "Yerel Ağ Geçidi / SonicWall ($GatewayIp) erişilemedi (Switch veya Firewall kesintisi)"
        } elseif (-not $NetInfo.wan_ok) {
            "Yerel Ağ Geçidi ($GatewayIp) aktif, ancak ISS (Türk Telekom / WAN) internet hattı koptu"
        } else {
            "İnternet var ancak Merkez Hub bulut sunucusuna ulaşılamadı"
        }

        $outageData = @{
            start_time = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            start_epoch = [int][double]::Parse((Get-Date -UFormat %s))
            diagnosis = $reason
        }
        $outageData | ConvertTo-Json | Set-Content -Path $OutageLogFile -Encoding UTF8
        Write-Host "[!] KARA KUTU: Gerçek kesinti başlangıcı kaydedildi -> $reason" -ForegroundColor Yellow
    }
}

function Consume-OfflineOutageReport {
    if (Test-Path $OutageLogFile) {
        try {
            $data = Get-Content $OutageLogFile -Raw -Encoding UTF8 | ConvertFrom-Json
            Remove-Item $OutageLogFile -Force -ErrorAction SilentlyContinue
            $nowEpoch = [int][double]::Parse((Get-Date -UFormat %s))
            $startEpoch = if ($data.start_epoch) { [int]$data.start_epoch } else { $nowEpoch - 60 }
            $durationSec = [Math]::Max(1, ($nowEpoch - $startEpoch))
            
            # Anlık 25 saniye altındaki geçici paket dalgalanmalarını kesinti olarak raporlayıp alarm üretme
            if ($durationSec -ge 25) {
                $endTime = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                $mins = [Math]::Floor($durationSec / 60)
                $secs = $durationSec % 60
                $durStr = if ($mins -gt 0) { "$mins dk $secs sn" } else { "$secs sn" }
                return "Kesinti Başlangıcı: $($data.start_time) | Bitiş: $endTime | Süre: $durStr | Kök Neden: $($data.diagnosis) (Elektrik kesilmedi, sunucu kesintisiz çalıştı)."
            }
        } catch {
            Remove-Item $OutageLogFile -Force -ErrorAction SilentlyContinue
        }
    }
    return ""
}

function Get-ActiveSessionsAndNewLogins {
    <# Sunucuda açık olan RDP / Konsol kullanıcılarını bulur ve yeni girişleri tespit eder #>
    $currentUsers = @()
    $newLogins = @()
    try {
        $quserOut = quser 2>$null
        if ($quserOut) {
            $lines = $quserOut | Select-Object -Skip 1
            foreach ($line in $lines) {
                $clean = $line.Trim() -replace '^>', ''
                $parts = $clean -split '\s+'
                if ($parts.Count -ge 2) {
                    $uName = $parts[0]
                    $currentUsers += $uName
                    if ($script:FirstRunUsersChecked -and ($script:KnownActiveUsers -notcontains $uName)) {
                        $newLogins += @{
                            user = $uName
                            ip = "RDP/Konsol"
                            type = "Oturum Açıldı"
                        }
                    }
                }
            }
        }
    } catch {}

    $script:KnownActiveUsers = $currentUsers
    $script:FirstRunUsersChecked = $true
    return @{
        active_users = $currentUsers
        new_logins = $newLogins
    }
}

function Invoke-DeepDiskCleanup {
    <# Kapsamlı ve Güvenli Derin Disk Temizliği:
       - Windows Temp & Kullanıcı Temp (Tüm Profiller)
       - Windows Update İndirme Önbelleği (SoftwareDistribution\Download)
       - Geri Dönüşüm Kutusu (Tüm Sürücüler)
       - Windows Hata Raporları & Crash Dumps
       - 30 Günden Eski IIS Web Logları
    #>
    $beforeFree = (Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'").FreeSpace

    # 1. Windows Temp
    try { Remove-Item -Path "C:\Windows\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue } catch {}

    # 2. Tüm Kullanıcı Profillerinin Temp Klasörleri (Terminal Server & Yerel)
    try {
        Get-ChildItem -Path "C:\Users" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $uTemp = Join-Path $_.FullName "AppData\Local\Temp"
            if (Test-Path $uTemp) {
                Remove-Item -Path "$uTemp\*" -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {}

    # 3. Windows Update Eski İndirme Önbelleği
    try {
        $swDownload = "C:\Windows\SoftwareDistribution\Download"
        if (Test-Path $swDownload) {
            Remove-Item -Path "$swDownload\*" -Recurse -Force -ErrorAction SilentlyContinue
        }
    } catch {}

    # 4. Geri Dönüşüm Kutuları
    try { Clear-RecycleBin -Force -ErrorAction SilentlyContinue } catch {}

    # 5. Windows Hata Raporları & Minidump
    try {
        Remove-Item -Path "C:\ProgramData\Microsoft\Windows\WER\ReportArchive\*" -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "C:\ProgramData\Microsoft\Windows\WER\ReportQueue\*" -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "C:\Windows\Minidump\*" -Force -ErrorAction SilentlyContinue
    } catch {}

    # 6. Eski IIS Web Logları (30 günden eski)
    try {
        $iisLogPath = "C:\inetpub\logs\LogFiles"
        if (Test-Path $iisLogPath) {
            Get-ChildItem -Path $iisLogPath -Recurse -File -Filter "*.log" -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } |
                Remove-Item -Force -ErrorAction SilentlyContinue
        }
    } catch {}

    $afterFree = (Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'").FreeSpace
    $freedMb = [Math]::Round((($afterFree - $beforeFree) / 1MB), 1)
    if ($freedMb -lt 0) { $freedMb = 0 }
    $freedGb = [Math]::Round(($freedMb / 1024), 2)
    $gainStr = if ($freedGb -ge 1) { "$freedGb GB ($freedMb MB)" } else { "$freedMb MB" }

    return @{
        freed_mb = $freedMb
        gain_str = $gainStr
        total_free_gb = [Math]::Round(($afterFree / 1GB), 1)
    }
}

function Invoke-SelfHealing {
    param([double]$DiskFreeGb, [double]$DiskTotalGb)
    $healedEvents = @()
    $serviceStates = @()

    # 1. Kritik Servis Kontrolü ve Otonom Başlatma
    if ($Config.CriticalServices) {
        foreach ($srvName in $Config.CriticalServices) {
            try {
                $s = Get-Service -Name $srvName -ErrorAction SilentlyContinue
                if ($s) {
                    if ($s.Status -ne 'Running') {
                        Start-Service -Name $srvName -ErrorAction SilentlyContinue
                        Start-Sleep -Seconds 1
                        $sAfter = Get-Service -Name $srvName -ErrorAction SilentlyContinue
                        if ($sAfter.Status -eq 'Running') {
                            $msg = "'$($s.DisplayName)' ($srvName) servisi durmuştu, otonom olarak yeniden başlatıldı."
                            $healedEvents += $msg
                            Write-Host "[+] OTONOM ONARIM: $msg" -ForegroundColor Green
                        }
                    }
                    $serviceStates += @{ name = $srvName; status = $s.Status.ToString() }
                }
            } catch {}
        }
    }

    # 2. Disk Doluluğu Otonom Derin Temizliği
    if ($DiskTotalGb -gt 0) {
        $usedPct = (($DiskTotalGb - $DiskFreeGb) / $DiskTotalGb) * 100
        $threshold = if ($Config.AutoCleanDiskThresholdPct) { [double]$Config.AutoCleanDiskThresholdPct } else { 88 }
        if ($usedPct -ge $threshold -and ((Get-Date) - $script:LastDiskCleanTime).TotalHours -ge 6) {
            $clRes = Invoke-DeepDiskCleanup
            $script:LastDiskCleanTime = Get-Date
            $healedEvents += "C: Diski %$([Math]::Round($usedPct,1)) doluluğa ulaştığı için otonom derin disk temizliği yapıldı ($($clRes.gain_str) alan açıldı, Kalan Boş: $($clRes.total_free_gb) GB)."
        }
    }

    return @{
        healed_events = $healedEvents
        services = $serviceStates
    }
}

function Invoke-SecurityAndBruteForceGuard {
    <# Son 10 dakikadaki Event ID 4625 başarısız girişleri inceler ve saldırgan IP'yi otonom engeller #>
    $securityEvents = @()
    try {
        $since = (Get-Date).AddMinutes(-10)
        $events = Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4625; StartTime=$since} -MaxEvents 60 -ErrorAction SilentlyContinue
        if ($events) {
            $ipCounts = @{}
            foreach ($evt in $events) {
                $xml = [xml]$evt.ToXml()
                $ipNode = $xml.Event.EventData.Data | Where-Object { $_.Name -eq 'IpAddress' }
                $ip = if ($ipNode) { $ipNode.'#text' } else { "" }
                if ($ip -and $ip -ne "-" -and $ip -ne "127.0.0.1" -and $ip -ne "::1") {
                    if (-not $ipCounts.ContainsKey($ip)) { $ipCounts[$ip] = 0 }
                    $ipCounts[$ip]++
                }
            }

            $threshold = if ($Config.BruteForceThreshold) { [int]$Config.BruteForceThreshold } else { 5 }
            foreach ($ip in $ipCounts.Keys) {
                $cnt = $ipCounts[$ip]
                if ($cnt -ge $threshold -and -not $script:BlockedIps.ContainsKey($ip)) {
                    if ($Config.AutoBlockBruteForce) {
                        $ruleName = "OmniAgent_Block_$ip"
                        New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -RemoteAddress $ip -Action Block -ErrorAction SilentlyContinue | Out-Null
                        $script:BlockedIps[$ip] = Get-Date
                        $securityEvents += "Saldırgan IP ($ip) son 10 dakikada $cnt başarısız şifre denemesi yaptı ve Windows Güvenlik Duvarında OTONOM OLARAK ENGELLENDİ!"
                    } else {
                        $script:BlockedIps[$ip] = Get-Date
                        $securityEvents += "Şüpheli IP ($ip) son 10 dakikada $cnt başarısız giriş denemesi yaptı!"
                    }
                }
            }
        }
    } catch {}
    return $securityEvents
}

function Get-BackupStatus {
    if (-not $Config.BackupFolderToWatch) { return "OK" }
    if (-not (Test-Path $Config.BackupFolderToWatch)) { return "YEDEK KLASÖRÜ YOK" }
    try {
        $latest = Get-ChildItem -Path $Config.BackupFolderToWatch -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $latest) { return "YEDEK DOSYASI BULUNAMADI" }
        $hoursOld = ((Get-Date) - $latest.LastWriteTime).TotalHours
        if ($hoursOld -gt 26) {
            return "GECİKMİŞ ($([Math]::Round($hoursOld,0)) sa önce)"
        }
        return "GÜNCEL ($($latest.LastWriteTime.ToString('dd.MM HH:mm')))"
    } catch {
        return "KONTROL HATASI"
    }
}

function Invoke-GhostSessionKiller {
    param(
        [int]$MaxIdleMinutes = 120,
        [string[]]$ExcludeUsers = @("Administrator", "admin.senkron")
    )
    if ($MaxIdleMinutes -le 0) { return @() }

    $killedEvents = @()
    try {
        $quserLines = quser 2>$null | Select-Object -Skip 1
        foreach ($line in $quserLines) {
            $clean = $line.Trim() -replace '^\>', ''
            if ($clean -match '^(\S+)\s+(?:(\S+)\s+)?(\d+)\s+([A-Za-z]+)\s+([^\s]+)\s+(.+)$') {
                $uName = $Matches[1]
                $sessId = [int]$Matches[3]
                $state = $Matches[4]
                $idleStr = $Matches[5]

                if ($state -like "Disc*" -or $state -like "Ayr*") {
                    $totalMins = 0
                    if ($idleStr -match '^(\d+)\+(\d+):(\d+)$') {
                        $totalMins = ([int]$Matches[1] * 1440) + ([int]$Matches[2] * 60) + [int]$Matches[3]
                    } elseif ($idleStr -match '^(\d+):(\d+)$') {
                        $totalMins = ([int]$Matches[1] * 60) + [int]$Matches[2]
                    } elseif ($idleStr -match '^\d+$') {
                        $totalMins = [int]$idleStr
                    }

                    if ($totalMins -ge $MaxIdleMinutes -and ($ExcludeUsers -notcontains $uName)) {
                        Write-Host "[!] HAYALET OTURUM OTONOM SONLANDIRILIYOR: $uName (ID: $sessId, $totalMins dk bosta)" -ForegroundColor Yellow
                        logoff $sessId 2>$null
                        $h = [Math]::Floor($totalMins / 60)
                        $m = $totalMins % 60
                        $durText = if ($h -gt 0) { "$h sa $m dk" } else { "$m dk" }
                        $killedEvents += "👻 Hayalet Oturum Otonom Sonlandırıldı: '$uName' (ID: $sessId) $durText boyunca askıdaydı, SQL ve sistem kilitleri temizlendi."
                    }
                }
            }
        }
    } catch {}

    return $killedEvents
}

function Invoke-AuditTrailGuard {
    <# Yönetici Hareket Takibi (Audit Trail):
       - Event 4720: Yeni kullanıcı hesabı açıldı
       - Event 4726: Kullanıcı silindi
       - Event 4728/4732: Administrators grubuna üye eklendi
       - Event 4950: Windows Güvenlik Duvarı kuralı değiştirildi
       - Event 7036: Kritik servis durduruldu
    #>
    $auditEvents = @()
    $now = Get-Date
    if (-not $script:LastAuditCheck) {
        $script:LastAuditCheck = $now.AddMinutes(-5)
    }

    try {
        # 1. Güvenlik Günlüğü
        $secEvts = Get-WinEvent -FilterHashtable @{
            LogName = 'Security'
            Id = 4720, 4726, 4728, 4732, 4950
            StartTime = $script:LastAuditCheck
        } -MaxEvents 15 -ErrorAction SilentlyContinue

        if ($secEvts) {
            foreach ($evt in $secEvts) {
                $timeStr = $evt.TimeCreated.ToString("HH:mm:ss")
                if ($evt.Id -eq 4720) {
                    $auditEvents += "[$timeStr] 👤 YENİ KULLANICI OLUŞTURULDU: $($evt.Message.Split([Environment]::NewLine)[0])"
                } elseif ($evt.Id -eq 4726) {
                    $auditEvents += "[$timeStr] 🗑️ KULLANICI HESABI SİLİNDİ: $($evt.Message.Split([Environment]::NewLine)[0])"
                } elseif ($evt.Id -in 4728, 4732) {
                    $auditEvents += "[$timeStr] 👑 YÖNETİCİ (ADMIN) GRUBUNA YENİ ÜYE EKLENDİ!"
                } elseif ($evt.Id -eq 4950) {
                    $auditEvents += "[$timeStr] 🛡️ GÜVENLİK DUVARI AYARI DEĞİŞTİRİLDİ!"
                }
            }
        }

        # 2. Sistem Günlüğü (Kritik Servis Durdurulmaları)
        $sysEvts = Get-WinEvent -FilterHashtable @{
            LogName = 'System'
            Id = 7036
            StartTime = $script:LastAuditCheck
        } -MaxEvents 20 -ErrorAction SilentlyContinue

        if ($sysEvts) {
            foreach ($evt in $sysEvts) {
                $msg = $evt.Message
                if ($msg -like "*durduruldu*" -or $msg -like "*stopped*") {
                    if ($msg -like "*SQL*" -or $msg -like "*Spooler*" -or $msg -like "*Remote Desktop*" -or $msg -like "*Firewall*") {
                        $timeStr = $evt.TimeCreated.ToString("HH:mm:ss")
                        $cleanMsg = $msg.Split([Environment]::NewLine)[0]
                        $auditEvents += "[$timeStr] ⚠️ KRİTİK SERVİS DURDURULDU: $cleanMsg"
                    }
                }
            }
        }
    } catch {}

    $script:LastAuditCheck = $now
    return $auditEvents
}

function Find-LargeHogFiles {
    param(
        [string]$Drive = "C:\",
        [int]$TopCount = 5,
        [int]$DaysOld = 7
    )
    $results = @()
    try {
        $since = (Get-Date).AddDays(-$DaysOld)
        $files = Get-ChildItem -Path $Drive -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.FullName -notlike "*\$Recycle.Bin\*" -and
                $_.FullName -notlike "*\System Volume Information\*" -and
                $_.Name -notlike "pagefile.sys" -and
                $_.Name -notlike "hiberfil.sys" -and
                $_.Name -notlike "swapfile.sys" -and
                $_.LastWriteTime -ge $since
            } |
            Sort-Object Length -Descending |
            Select-Object -First $TopCount

        foreach ($f in $files) {
            $owner = try { (Get-Acl -Path $f.FullName -ErrorAction SilentlyContinue).Owner } catch { "Bilinmiyor" }
            if (-not $owner) { $owner = "Bilinmiyor" }
            $sizeMb = [Math]::Round(($f.Length / 1MB), 1)
            $sizeGb = [Math]::Round(($f.Length / 1GB), 2)
            $sizeStr = if ($sizeGb -ge 1) { "$sizeGb GB ($sizeMb MB)" } else { "$sizeMb MB" }

            $results += [PSCustomObject]@{
                Dosya = $f.FullName
                Boyut = $sizeStr
                Sahibi = $owner
                Tarih = $f.LastWriteTime.ToString("dd.MM.yyyy HH:mm")
            }
        }
    } catch {}

    return $results
}

function Execute-TaskSafely {
    param($Task)
    $TaskId = $Task.task_id
    $Command = $Task.command
    $TimeoutSec = if ($Task.timeout_sec) { [int]$Task.timeout_sec } else { 60 }

    Write-Host "[*] Merkezden Gorev Geldi [$TaskId]: $Command" -ForegroundColor Magenta

    foreach ($blocked in $Blacklist) {
        if ($Command -like "*$blocked*") {
            Invoke-HubRequest -Path "/api/agent/task_result" -Method "POST" -Body @{
                task_id = $TaskId
                server_id = $ServerId
                exit_code = -1
                output = ""
                error = "GÜVENLİK ENGELİ: '$blocked' komutu kara listededir!"
            } | Out-Null
            return
        }
    }

    $output = ""
    $errorMsg = ""
    $exitCode = 0
    try {
        $wrappedCmd = "`$ProgressPreference = 'SilentlyContinue'; [Console]::OutputEncoding = [System.Text.Encoding]::UTF8; $Command"
        $encodedCmd = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($wrappedCmd))
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "powershell.exe"
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedCmd"
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true

        $proc = [System.Diagnostics.Process]::Start($psi)
        if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
            $proc.Kill()
            $exitCode = -2
            $errorMsg = "Komut zaman aşımına ($TimeoutSec sn) uğradı."
        } else {
            $output = $proc.StandardOutput.ReadToEnd()
            $rawErr = $proc.StandardError.ReadToEnd()
            if ($rawErr -match '(?s)#< CLIXML.*?<Objs Version=.*?</Objs>') {
                $rawErr = $rawErr -replace '(?s)#< CLIXML.*?<Objs Version=.*?</Objs>', ''
            }
            $errorMsg = $rawErr.Trim()
            $exitCode = $proc.ExitCode
        }
    } catch {
        $exitCode = -3
        $errorMsg = $_.Exception.Message
    }

    Invoke-HubRequest -Path "/api/agent/task_result" -Method "POST" -Body @{
        task_id = $TaskId
        server_id = $ServerId
        exit_code = $exitCode
        output = $output.Trim()
        error = $errorMsg.Trim()
    } | Out-Null
}

# --- 1. Sunucu Kaydı & Elektrik Kesintisi Sonrası Açılış Kontrolü ---
$osInfo = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
$csInfo = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
$cpuInfo = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
$localIp = (Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias "Ethernet*", "vEthernet*", "Wi-Fi*" -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike "169.254*" } | Select-Object -ExpandProperty IPAddress -First 1)
if (-not $localIp) { $localIp = "127.0.0.1" }

$bootPowerReport = Get-PowerOutageBootReport
$netInit = Test-NetworkAndInternet

$registered = $false
while (-not $registered) {
    $regRes = Invoke-HubRequest -Path "/api/agent/register" -Method "POST" -Body @{
        server_id = $ServerId
        customer_name = $CustomerName
        hostname = $env:COMPUTERNAME
        os_version = "$($osInfo.Caption)"
        ip_address = $localIp
        wan_ip = $netInit.wan_ip
        total_ram_gb = [Math]::Round(($csInfo.TotalPhysicalMemory / 1GB), 1)
        cpu_model = $cpuInfo.Name
        firewall_ip = $Config.SonicWallUrl
        unexpected_shutdown_details = $bootPowerReport
    }
    if ($regRes -and $regRes.status -eq "registered") {
        $registered = $true
        Write-Host "[+] Merkez Hub'a kayit basarili!" -ForegroundColor Green
    } else {
        Record-OfflineOutage -NetInfo (Test-NetworkAndInternet)
        Write-Host "[-] Hub'a ulasilamadi, 5 sn sonra tekrar denenecek..." -ForegroundColor Yellow
        Start-Sleep -Seconds 5
    }
}

# --- 2. 7/24 Ana Otonom Döngü ---
while ($true) {
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        $cpuLoad = (Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Measure-Object -Property LoadPercentage -Average).Average
        if ($null -eq $cpuLoad) { $cpuLoad = 0 }

        $ramPct = if ($os.TotalVisibleMemorySize -gt 0) {
            [Math]::Round(((($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize) * 100), 1)
        } else { 0 }

        $diskC = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction SilentlyContinue
        $diskFreeGb = if ($diskC) { [Math]::Round(($diskC.FreeSpace / 1GB), 1) } else { 0 }
        $diskTotalGb = if ($diskC) { [Math]::Round(($diskC.Size / 1GB), 1) } else { 0 }
        $uptimeHours = if ($os.LastBootUpTime) { [Math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours, 1) } else { 0 }

        $net = Test-NetworkAndInternet
        $ups = Get-UpsStatus
        $sessions = Get-ActiveSessionsAndNewLogins
        $heal = Invoke-SelfHealing -DiskFreeGb $diskFreeGb -DiskTotalGb $diskTotalGb
        $ghostKilled = Invoke-GhostSessionKiller -MaxIdleMinutes $script:GhostMaxIdle -ExcludeUsers $script:GhostExcludeUsers
        $allHealed = @($heal.healed_events) + @($ghostKilled)
        $auditEvts = Invoke-AuditTrailGuard
        $secEvents = Invoke-SecurityAndBruteForceGuard
        $backupSt = Get-BackupStatus

        # Eğer internet kesintisinden yeni çıkıldıysa Kara Kutu raporunu al
        $outageReport = ""
        if ($net.wan_ok) {
            $script:ConsecutiveWanFailures = 0
            $outageReport = Consume-OfflineOutageReport
        } else {
            $script:ConsecutiveWanFailures++
            # Sadece art arda en az 3 deneme (yaklaşık 20-30 saniye) boyunca WAN yoksa kara kutu kesinti kaydı aç
            if ($script:ConsecutiveWanFailures -ge 3) {
                Record-OfflineOutage -NetInfo $net
            }
        }

        $hbPayload = @{
            server_id = $ServerId
            customer_name = $CustomerName
            hostname = $env:COMPUTERNAME
            os_version = "$($osInfo.Caption)"
            ip_address = $localIp
            total_ram_gb = [Math]::Round(($csInfo.TotalPhysicalMemory / 1GB), 1)
            cpu_percent = [Math]::Round($cpuLoad, 1)
            ram_percent = $ramPct
            disk_free_gb = $diskFreeGb
            disk_total_gb = $diskTotalGb
            uptime_hours = $uptimeHours
            wan_ip = $net.wan_ip
            gateway_ping_ms = $net.gateway_ping_ms
            wan_ping_ms = $net.wan_ping_ms
            packet_loss_pct = $net.packet_loss_pct
            dns_ok = $net.wan_ok
            ups_status = $ups.status
            ups_battery_pct = $ups.pct
            active_users = $sessions.active_users
            new_logins = $sessions.new_logins
            healed_events = $allHealed
            audit_events = $auditEvts
            services = $heal.services
            security_events = $secEvents
            backup_status = $backupSt
            offline_outage_report = $outageReport
        }

        $hbRes = Invoke-HubRequest -Path "/api/agent/heartbeat" -Method "POST" -Body $hbPayload
        if (-not $hbRes) {
            $script:ConsecutiveHubFailures++
            # Sadece ve sadece hem Hub hem de WAN gerçekten 4 deneme boyunca yoksa kaydet
            if ($script:ConsecutiveHubFailures -ge 4 -and (-not $net.wan_ok)) {
                Record-OfflineOutage -NetInfo $net
            }
        } else {
            $script:ConsecutiveHubFailures = 0
            if ($null -ne $hbRes.ghost_session_max_idle_min) {
                $script:GhostMaxIdle = [int]$hbRes.ghost_session_max_idle_min
            }
            if ($null -ne $hbRes.ghost_session_enabled -and (-not $hbRes.ghost_session_enabled)) {
                $script:GhostMaxIdle = 0
            }
        }

        # Bekleyen görevleri çek ve çalıştır
        $taskRes = Invoke-HubRequest -Path "/api/agent/tasks/$ServerId" -Method "GET"
        if ($taskRes -and $taskRes.tasks) {
            foreach ($t in $taskRes.tasks) {
                Execute-TaskSafely -Task $t
            }
        }
    } catch {
        Write-Host "[-] Dongu hatasi: $($_.Exception.Message)" -ForegroundColor Red
    }

    Start-Sleep -Seconds $HeartbeatInterval
}
