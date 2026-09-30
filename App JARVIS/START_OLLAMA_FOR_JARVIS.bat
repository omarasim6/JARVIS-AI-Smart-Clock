@echo off
setlocal

echo ============================================
echo JARVIS - Ollama LAN Setup
echo ============================================
echo.
echo This configures Ollama so the JARVIS Android app can reach it over Wi-Fi.
echo.

set "OLLAMA_HOST=0.0.0.0:11434"
setx OLLAMA_HOST "0.0.0.0:11434" >nul

where ollama >nul 2>&1
if errorlevel 1 (
    echo Ollama was not found in PATH.
    echo Install Ollama first, then run this file again.
    pause
    exit /b 1
)

echo Allowing TCP port 11434 through Windows Firewall...
netsh advfirewall firewall add rule name="JARVIS Ollama 11434" dir=in action=allow protocol=TCP localport=11434 >nul 2>&1
if errorlevel 1 (
    echo Firewall rule could not be added automatically.
    echo Run this file as Administrator, or allow TCP port 11434 manually.
    echo.
)

echo.
echo Restarting Ollama with OLLAMA_HOST=%OLLAMA_HOST% ...
taskkill /IM ollama.exe /F >nul 2>&1

timeout /t 2 /nobreak >nul
start "" ollama serve

echo.
echo Ollama is being started on 0.0.0.0:11434.
echo Keep this window open if Ollama is running in the foreground.
echo Your phone and this PC must be on the same Wi-Fi network.
echo.
echo Test from the PC with:  ollama list

echo Then set JARVIS AI Settings to:
echo http://YOUR-PC-LAN-IP:11434

echo.
pause
endlocal
