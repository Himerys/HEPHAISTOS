@echo off
chcp 850 >nul
rem HEPHAISTOS Report-Versand - auf DEINEM NOTEBOOK starten (nicht am aufgesetzten Geraet).
rem Sendet alle noch nicht versendeten Abnahme-Reports vom Stick per Graph-SSO
rem des angemeldeten ITlers bzw. klassischem Outlook (COM-Fallback).
rem Das Script kommt zur Laufzeit aus dem GitHub-Repo; ohne Netz wird die
rem lokale Spiegelkopie unter _HEPHAISTOS\Fallback\send\ genutzt.
rem Template: {{RAWBASE}} wird von tools\Build-USB.ps1 ersetzt.
title HEPHAISTOS Report-Versand
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; [Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor 3072; $d=Join-Path $env:TEMP 'HEPHAISTOS\send'; $null=New-Item -Path $d -ItemType Directory -Force; $f=Join-Path $d 'Send-QueuedReports.ps1'; try { Invoke-WebRequest -UseBasicParsing -Uri '{{RAWBASE}}/send/Send-QueuedReports.ps1' -OutFile $f } catch { Write-Host 'OFFLINE - nutze lokale Kopie (%~dp0_HEPHAISTOS\Fallback)' -ForegroundColor Yellow; $f='%~dp0_HEPHAISTOS\Fallback\send\Send-QueuedReports.ps1' }; & $f"
pause
