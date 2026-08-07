<#
.SYNOPSIS
    HEPHAISTOS Schritt: BIOS-Konfiguration anwenden (Dell CCTK).
.DESCRIPTION
    Teilschritt von oobe\Invoke-HephaistosOnboarding.ps1 - NICHT direkt starten.
    Port von Invoke-Step1Bios (SLG-Onboarding.ps1, USB_ScriptTool Rev05):
        [1] Bevorzugt: vorentpacktes CCTK   <Stick>:\_HEPHAISTOS\Tools\CCTK\applyconfig.bat
            (umgeht die SCE-Selbstextraktion, die auf Systemen ohne VC++-Runtime
            mit 0xC0000135 / "Extraction Error" scheitert)
        [2] Fallback: SCE-EXE               <Stick>:\_HEPHAISTOS\Tools\Pro16Plus_CCTK_x64.exe
            inkl. VC++-Runtime-Workaround (Install-VcRuntimeIfMissing aus der Lib,
            Exit-Codes 0/3010/1638 werden dort behandelt)
    Kein Neustart an dieser Stelle: Das BIOS wird beim automatischen Neustart
    nach dem Autopilot-Hash-Schritt wirksam.
    Die CCTK-Binärdateien liegen bewusst NUR auf dem Stick (zu groß/lizenzpflichtig
    fürs Repo) - ohne Stick kann dieser Schritt nicht laufen.
.NOTES
    HEPHAISTOS v1.0.2 - portiert aus USB_ScriptTool Rev05. PowerShell 5.1. UTF-8 mit BOM.
#>
param([hashtable]$Context)

# --- Guard: Lib muss geladen sein (Dot-Sourcing durch das Onboarding-Script) ---
if (-not (Get-Command Write-HephOk -ErrorAction SilentlyContinue)) {
    Write-Host ''
    Write-Host 'FEHLER: HEPHAISTOS-Bibliothek (lib\Hephaistos.Common.ps1) ist nicht geladen.' -ForegroundColor Red
    Write-Host 'Dieses Script ist ein Teilschritt und wird von oobe\Invoke-HephaistosOnboarding.ps1' -ForegroundColor Yellow
    Write-Host 'aufgerufen - bitte nicht direkt starten.' -ForegroundColor Yellow
    return
}
if (-not $Context) {
    Write-HephErr 'FEHLER: Kein -Context übergeben - BIOS-Schritt wird abgebrochen.'
    return
}

Write-HephPhase -Title 'BIOS-Konfiguration (Dell CCTK)' -EstimatedDuration '30-90 Sekunden'

# --- Stick-Pflicht: CCTK-Paket + vc_redist liegen unter <Stick>:\_HEPHAISTOS\Tools ---
if (-not $Context.UsbRoot) {
    Write-HephErr 'FEHLER: USB-Stick nicht gefunden - das CCTK-Paket liegt unter <Stick>:\_HEPHAISTOS\Tools.'
    Write-HephErr 'BIOS-Konfiguration kann ohne Stick nicht angewendet werden.'
    Write-HephResult -Success $false -Text 'BIOS-Konfiguration NICHT angewendet (Stick fehlt).'
    return
}
$tools   = Join-Path $Context.UsbRoot '_HEPHAISTOS\Tools'
$cctkBat = Join-Path $tools 'CCTK\applyconfig.bat'
$sce     = Join-Path $tools 'Pro16Plus_CCTK_x64.exe'

# --- CCTK-Kette (Port 1:1): vorentpacktes CCTK bevorzugt, sonst SCE-EXE ---
if (Test-Path $cctkBat) {
    Write-HephInfo 'BIOS-Konfiguration wird angewendet [vorentpacktes CCTK] ...'
    $log = Join-Path $Context.DevDir 'cctk_apply.log'
    $p = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', ('call applyconfig.bat -l="{0}"' -f $log) -WorkingDirectory (Split-Path $cctkBat) -Wait -PassThru
} elseif (Test-Path $sce) {
    # miniunz.exe (SCE-Selbstextraktion) braucht die VC++-Runtime; auf dem
    # Dell-Werksimage fehlt sie (Praxistest 07/2026: 0xC0000135) - Lib-Funktion
    # installiert sie bei Bedarf still vom Stick.
    Install-VcRuntimeIfMissing -ToolsDir $tools | Out-Null
    Write-HephInfo 'BIOS-Konfiguration wird angewendet [SCE-EXE] (30-90 Sekunden) ...'
    $p = Start-Process -FilePath $sce -Wait -PassThru
    # SCE schreibt sein Log neben die EXE -> in den Geräteordner sichern
    Get-ChildItem -Path (Split-Path $sce) -Filter '*.log' -ErrorAction SilentlyContinue |
        Copy-Item -Destination $Context.DevDir -Force -ErrorAction SilentlyContinue
} else {
    Write-HephErr ("FEHLER: Weder {0} noch {1} gefunden." -f $cctkBat, $sce)
    Write-HephResult -Success $false -Text 'BIOS-Konfiguration NICHT angewendet (CCTK-Paket fehlt auf dem Stick).'
    return
}

# --- Ergebnis (Port 1:1: nur Exit-Code 0 gilt als Erfolg) ---
if ($p.ExitCode -eq 0) {
    Set-Step -StateDir $Context.StateDir -Name 'step1_bios.done' -Detail 'RC=0, angewendet aus OOBE (HEPHAISTOS)'
    # Kein Reboot hier (Abweichung zum Menü-Original, dort wurde gefragt):
    # Das Gerät startet nach dem Hash-Schritt ohnehin automatisch neu.
    Write-HephDim 'Kein Neustart an dieser Stelle: Die BIOS-Einstellungen werden beim'
    Write-HephDim 'automatischen Neustart nach dem Autopilot-Hash-Schritt wirksam.'
    Write-HephResult -Success $true -Text 'BIOS-Konfiguration ERFOLGREICH. Wird nach Neustart wirksam.'
} else {
    Write-HephErr ("FEHLER: Exit-Code {0}. Logs im Geräteordner prüfen." -f $p.ExitCode)
    Write-HephDim ("Geräteordner: {0}" -f $Context.DevDir)
    Write-HephWarn 'Bei "Extraction Error" der SCE-EXE: Paket am Admin-PC mit /s /e= entpacken'
    Write-HephWarn '(Pro16Plus_CCTK_x64.exe /s /e=C:\Temp\CCTK) und den Inhalt nach'
    Write-HephWarn '_HEPHAISTOS\Tools\CCTK\ auf dem Stick kopieren (siehe docs\ANLEITUNG.md).'
    Write-HephResult -Success $false -Text ("BIOS-Konfiguration fehlgeschlagen (Exit-Code {0})." -f $p.ExitCode)
}
