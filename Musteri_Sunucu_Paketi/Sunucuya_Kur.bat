@echo off
:: Yönetici yetkisi kontrolü ve otomatik yükseltme (UAC)
net session >nul 2>&1
if %errorLevel% neq 0 (
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup-Server.ps1"
