@echo off
rem =====================================================================
rem  HEPHAISTOS - OOBE-Einstieg (Shift+F10 -> C:\OSDCloud\HEPHAISTOS\oobe.cmd)
rem  Diese Datei ist ein TEMPLATE im Repo: boot\Start-Hephaistos.ps1 ersetzt
rem  beim Staging den Platzhalter {{RAWBASE}} durch die Repo-RawBase aus
rem  config\deploy.json und legt die Datei nach C:\OSDCloud\HEPHAISTOS\.
rem  Ablauf: immer aktuelle Version aus dem Repo laden; ohne Netz Fallback
rem  auf die lokal gestagte Kopie unter C:\OSDCloud\HEPHAISTOS\Fallback\.
rem =====================================================================
setlocal EnableExtensions
chcp 850 >nul
title HEPHAISTOS Onboarding (OOBE)

rem --- Einmalig Adminrechte anfordern (fltmc statt "net session"). In der
rem     OOBE-Konsole (Shift+F10) ist bereits alles elevated -> kein Prompt.
rem     Relevant fuer Nachlaeufe aus dem fertigen Windows (BIOS-Schritt braucht
rem     Admin). /elevated-Marker verhindert eine Relaunch-Schleife.
fltmc >nul 2>&1
if errorlevel 1 (
    if "%~1"=="/elevated" (
        echo WARNUNG: Keine Administratorrechte erhalten - der BIOS-Schritt
        echo wird so fehlschlagen.
        pause
    ) else (
        echo Administratorrechte werden angefordert ^(UAC^) ...
        powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '/elevated' -Verb RunAs"
        exit /b
    )
)

powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; [Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor 3072; $d=Join-Path $env:TEMP 'HEPHAISTOS\oobe'; $null=New-Item -Path $d -ItemType Directory -Force; $f=Join-Path $d 'Invoke-HephaistosOnboarding.ps1'; try { Invoke-WebRequest -UseBasicParsing -Uri '{{RAWBASE}}/oobe/Invoke-HephaistosOnboarding.ps1' -OutFile $f } catch { Write-Host 'OFFLINE - nutze lokale Kopie (C:\OSDCloud\HEPHAISTOS\Fallback)' -ForegroundColor Yellow; $f='C:\OSDCloud\HEPHAISTOS\Fallback\oobe\Invoke-HephaistosOnboarding.ps1' }; & $f"
rem Nach UAC-Relaunch laeuft dies in einem NEUEN Fenster, das sich beim Ende
rem sofort schliessen wuerde - Ausgabe (Zusammenfassung/Fehler) sichtbar halten.
if "%~1"=="/elevated" pause
exit /b %ERRORLEVEL%
