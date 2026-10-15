@echo off
chcp 65001 >nul
title OmniAgent Komuta Merkezi Baslatici
echo ==========================================================
echo   OMNIAGENT 7/24 BULUT SUNUCU KOMUTA MERKEZI ACILIYOR
echo ==========================================================

:: 1. Yerel Test Ajanini Baslat (Render Bulut Hub'a baglanir)
start "OmniAgent Local Agent" /min powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0agent\OmniAgent.ps1"
timeout /t 2 >nul

:: 2. Canli Bulut Web Komuta Panelini Tarayicida Ac
start "" "https://omniagent-hub.onrender.com"

echo [+] OmniAgent Ajan ve Bulut Komuta Paneli (https://omniagent-hub.onrender.com) acildi!
exit
