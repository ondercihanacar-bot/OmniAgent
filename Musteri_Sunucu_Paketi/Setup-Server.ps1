<#
.SYNOPSIS
    OmniAgent Müşteri Sunucusu Tek Tık Kurulum Sihirbazı
#>

$ErrorActionPreference = "Continue"
$SourceDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$TargetDir = "C:\OmniAgent"

Clear-Host
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " 🛡️  OMNIAGENT 7/24 SUNUCU KURULUM SİHİRBAZI" -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host ""

$defaultServerId = $env:COMPUTERNAME
$inputServerId = Read-Host "1. Sunucu Kodu [Varsayılan: $defaultServerId]"
if ([string]::IsNullOrWhiteSpace($inputServerId)) { $inputServerId = $defaultServerId }

$inputCustomer = Read-Host "2. Müşteri / Firma Adı [Varsayılan: $inputServerId]"
if ([string]::IsNullOrWhiteSpace($inputCustomer)) { $inputCustomer = $inputServerId }

$defaultHub = "https://omniagent-hub.onrender.com"
$inputHub = Read-Host "3. Merkez Bulut Hub Adresi [Varsayılan: $defaultHub]"
if ([string]::IsNullOrWhiteSpace($inputHub)) { $inputHub = $defaultHub }
if ($inputHub -notmatch "^http") { $inputHub = "https://$inputHub" }

$defaultGw = "192.168.1.1"
$inputGw = Read-Host "4. SonicWall / Modem IP Adresi [Varsayılan: $defaultGw]"
if ([string]::IsNullOrWhiteSpace($inputGw)) { $inputGw = $defaultGw }

Write-Host ""
Write-Host "[*] Dosyalar C:\OmniAgent klasörüne kopyalanıyor..." -ForegroundColor Yellow
New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null

Copy-Item -Path (Join-Path $SourceDir "OmniAgent.ps1") -Destination "$TargetDir\OmniAgent.ps1" -Force
Copy-Item -Path (Join-Path $SourceDir "OmniRobot.ps1") -Destination "$TargetDir\OmniRobot.ps1" -Force
Copy-Item -Path (Join-Path $SourceDir "gemini_robot_opt.mp4") -Destination "$TargetDir\gemini_robot_opt.mp4" -Force

# Config.json oluştur
$cfgObj = @{
    HubUrl = $inputHub
    AuthToken = "OmniAgentSecretToken2026"
    ServerId = $inputServerId
    CustomerName = $inputCustomer
    HeartbeatIntervalSec = 6
    GatewayIp = $inputGw
    SonicWallUrl = "https://$inputGw"
    CriticalServices = @("Spooler", "W32Time")
    AutoCleanDiskThresholdPct = 90
    AutoBlockBruteForce = $true
    BruteForceThreshold = 5
    BackupFolderToWatch = ""
}
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText("$TargetDir\config.json", ($cfgObj | ConvertTo-Json -Depth 4), $utf8NoBom)

# Hub Güvenlik Duvarı Port İzni ve Antivirüs İstisnası
New-NetFirewallRule -DisplayName "OmniAgent Outbound" -Direction Outbound -Action Allow -ErrorAction SilentlyContinue | Out-Null
Add-MpPreference -ExclusionPath $TargetDir -ErrorAction SilentlyContinue | Out-Null

# 7/24 Sistem Görevi (NT AUTHORITY\SYSTEM) Kaydı + 5 Dakikalık Watchdog Tetikleyici
$TaskName = "OmniAgent_7x24_Service"
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

$Action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$TargetDir\OmniAgent.ps1`""
$TriggerStartup = New-ScheduledTaskTrigger -AtStartup
$TriggerWatchdog = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5)
$Settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit (New-TimeSpan -Days 3650)

$Principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger @($TriggerStartup, $TriggerWatchdog) -Settings $Settings -Principal $Principal -Description "OmniAgent 7/24 Autonomous Server Guardian" | Out-Null
Start-ScheduledTask -TaskName $TaskName

Write-Host ""
Write-Host "==========================================================" -ForegroundColor Green
Write-Host " ✅ KURULUM BAŞARIYLA TAMAMLANDI!" -ForegroundColor Green
Write-Host " 🖥️  Sunucu Kodu : $inputServerId ($inputCustomer)" -ForegroundColor Cyan
Write-Host " 🌐 Merkez Hub  : $inputHub" -ForegroundColor Cyan
Write-Host " 🔄 7/24 Servis : Arka planda sessiz ve görünmez çalışıyor." -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Green
Write-Host ""
Read-Host "Çıkmak için ENTER tuşuna basın"
