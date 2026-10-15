@echo off
chcp 65001 >nul
title OmniAgent Komuta Merkezi Baslatici
echo ==========================================================
echo   OMNIAGENT 7/24 OTONOM SUNUCU KOMUTA MERKEZI BASLATILIYOR
echo ==========================================================

:: 1. Hub Sunucusunu Baslat
start "OmniAgent Central Hub" /min python "%~dp0hub\server.py"
timeout /t 2 >nul

:: 2. Yerel Test Ajanini Baslat
start "OmniAgent Local Agent" /min powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0agent\OmniAgent.ps1"
timeout /t 2 >nul

:: 3. Canli Web Komuta Panelini Tarayicida Ac
start "" "http://127.0.0.1:8088"

echo [+] OmniAgent Hub, Ajan ve Web Komuta Paneli acildi!
exit
