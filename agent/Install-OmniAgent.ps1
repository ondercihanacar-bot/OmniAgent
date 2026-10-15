<#
.SYNOPSIS
    OmniAgent 7/24 Sistem Görevi Kurulum Aracı (Otomatik Açılış & Ölümsüzlük Kalkanı)
.DESCRIPTION
    Müşteri sunucusu elektrik kesintisinden sonra yeniden başladığında kimse Windows oturumu açmasa bile
    NT AUTHORITY\SYSTEM yetkisiyle otomatik devreye girmesini sağlar.
#>

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[!] LÜTFEN 'YÖNETİCİ OLARAK ÇALIŞTIR' (Run as Administrator) İLE AÇIN!" -ForegroundColor Red
    exit 1
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$AgentScript = Join-Path $ScriptDir "OmniAgent.ps1"
$TaskName = "OmniAgent_7x24_Service"

Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host " 🛡️  OmniAgent 7/24 Otonom Sistem Servisi Kuruluyor..." -ForegroundColor Green
Write-Host "=========================================================" -ForegroundColor Cyan

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

$Action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$AgentScript`""
$TriggerStartup = New-ScheduledTaskTrigger -AtStartup
$Settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit (New-TimeSpan -Days 3650)

$Principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest

Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $TriggerStartup -Settings $Settings -Principal $Principal -Description "OmniAgent 7/24 Autonomous Server & Security Guardian" | Out-Null
Start-ScheduledTask -TaskName $TaskName

Write-Host "[+] KURULUM TAMAMLANDI!" -ForegroundColor Green
Write-Host "[+] Ajan şu an arka planda 7/24 çalışıyor." -ForegroundColor Cyan
Write-Host "[+] Elektrik kesintisi veya yeniden başlatma sonrası oturum açılmasa bile otomatik devreye girecektir." -ForegroundColor Yellow
