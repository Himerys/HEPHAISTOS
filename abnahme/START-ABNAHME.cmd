@echo off
rem =====================================================================
rem  HEPHAISTOS - Abnahme-Start (liegt nach Build-USB im Stick-Root)
rem  Diese Datei ist ein TEMPLATE im Repo: tools\Build-USB.ps1 ersetzt beim
rem  Kopieren auf den Stick den Platzhalter {{RAWBASE}} durch die RawBase
rem  aus config\deploy.json.
rem  Ablauf: Adminrechte anfordern, dann immer aktuelle Script-Version aus
rem  dem Repo laden; ohne Netz Fallback auf _HEPHAISTOS\Fallback\.
rem =====================================================================
setlocal EnableExtensions
chcp 850 >nul
title HEPHAISTOS Abnahme

rem --- Einmalig Adminrechte anfordern (fltmc statt "net session":
rem     funktioniert ohne laufenden Server-Dienst; /elevated-Marker
rem     verhindert eine Relaunch-Schleife).
fltmc >nul 2>&1
if errorlevel 1 (
    if "%~1"=="/elevated" (
        echo WARNUNG: Keine Administratorrechte erhalten - die Abnahme-Pruefung
        echo wird so fehlschlagen ^(Script verlangt Admin-PowerShell^).
        pause
    ) else (
        echo Administratorrechte werden angefordert ^(UAC^) ...
        powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '/elevated' -Verb RunAs"
        exit /b
    )
)

powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; [Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor 3072; $d=Join-Path $env:TEMP 'HEPHAISTOS\abnahme'; $null=New-Item -Path $d -ItemType Directory -Force; $f=Join-Path $d 'Test-HephaistosDevice.ps1'; try { Invoke-WebRequest -UseBasicParsing -Uri '{{RAWBASE}}/abnahme/Test-HephaistosDevice.ps1' -OutFile $f } catch { Write-Host 'OFFLINE - nutze lokale Kopie vom Stick' -ForegroundColor Yellow; $f='%~dp0_HEPHAISTOS\Fallback\abnahme\Test-HephaistosDevice.ps1' }; & $f; exit $LASTEXITCODE"
pause
exit /b %ERRORLEVEL%
