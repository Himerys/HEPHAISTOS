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
    HEPHAISTOS v1.2.1 - portiert aus USB_ScriptTool Rev05. PowerShell 5.1. UTF-8 mit BOM.
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
# v1.1.0: Modell-spezifisches CCTK-Paket (deploy.json Bios.Packages, längster
# Modell-Teilstring gewinnt), Fallback = Standard-Paket (bisheriges Tools\CCTK).
$pkgInfo = $null
if (Get-Command Get-HephBiosPackageDir -ErrorAction SilentlyContinue) {
    $pkgInfo = Get-HephBiosPackageDir -Model ([string]$Context.Model) -BiosConfig $(if ($Context.Config) { $Context.Config.Bios } else { $null }) -ToolsDir $tools
} else {
    # Veraltete Lib-Kopie (Offline-Fallback) ohne die 1.1.0-Funktion: Standard-Paket.
    $pkgInfo = @{ Dir = (Join-Path $tools 'CCTK'); Package = 'CCTK'; Reason = 'Standard-Paket (Lib ohne Modell-Mapping)'; MappedMissing = $false }
}
if ($pkgInfo.MappedMissing) {
    Write-HephWarn ('Für dieses Modell ist ein eigenes CCTK-Paket konfiguriert, der Ordner fehlt aber auf dem Stick - Standard-Paket wird verwendet.')
}
Write-HephDim ('CCTK-Paket: {0} ({1})' -f $pkgInfo.Package, $pkgInfo.Reason)
$cctkBat = Join-Path $pkgInfo.Dir 'applyconfig.bat'
$sce     = Join-Path $tools 'Pro16Plus_CCTK_x64.exe'

# --- Storage-Schutz (v1.1.0): Wurde in WinPE entschieden, unter dem "falschen"
# Storage-Modus zu installieren (Flag storage_mode.keep), darf das CCTK-Paket
# den Modus jetzt NICHT mehr umstellen - ein Wechsel NACH der Installation macht
# Windows unbootbar (INACCESSIBLE_BOOT_DEVICE). applyconfig.bat wendet die
# komplette INI an, deshalb hier die harte Rückfrage.
if ($Context.StateDir -and (Test-Step -StateDir $Context.StateDir -Name 'storage_mode.keep')) {
    Write-HephErr 'ACHTUNG: Windows wurde bewusst unter dem aktuellen Storage-Modus installiert.'
    Write-HephErr 'Enthält das CCTK-Paket eine Storage-Option (EmbSataRaid), macht dessen'
    Write-HephErr 'Anwendung das Gerät beim nächsten Neustart UNBOOTBAR.'
    if (-not (Confirm-Choice 'CCTK-Paket trotzdem anwenden? (Nur wenn es KEINE Storage-Option enthält!)')) {
        Write-HephWarn 'BIOS-Konfiguration übersprungen - manuell nachholen (Paket ohne Storage-Option verwenden).'
        Write-HephResult -Success $false -Text 'BIOS-Konfiguration NICHT angewendet (Storage-Schutz).'
        return
    }
}

# --- CCTK-Kette (Port 1:1): vorentpacktes CCTK bevorzugt, sonst SCE-EXE ---
$log = $null
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
    # Neuestes CCTK-Log für die Teilerfolgs-Auswertung heranziehen
    # (Transcripte ausschließen - die heißen WinPE_*/OOBE_*)
    $sceLog = Get-ChildItem -Path $Context.DevDir -Filter '*.log' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '^(WinPE_|OOBE_|Abnahme)' } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($sceLog) { $log = $sceLog.FullName }
} else {
    Write-HephErr ("FEHLER: Weder {0} noch {1} gefunden." -f $cctkBat, $sce)
    Write-HephResult -Success $false -Text 'BIOS-Konfiguration NICHT angewendet (CCTK-Paket fehlt auf dem Stick).'
    return
}

# --- Ergebnis: RC=0 = voller Erfolg. Bei RC!=0 wird das CCTK-Log ausgewertet.
# Praxisfund (Pro 16 Plus, 08/2026): EINE hardwareabhängige Option (z.B. 'Wimob'
# ohne verbautes WWAN-Modul) lässt cctk mit FAILURE enden (RC 146), obwohl alle
# übrigen Einstellungen inkl. BIOS-Passwort gesetzt wurden. Nicht anwendbare
# Optionen ergeben deshalb GELB (Flag wird gesetzt); Passwort-Fehler und
# unbekannte Fehlerbilder bleiben ROT. Sicherheitsnetz: Die Abnahme prüft das
# BIOS-Admin-Passwort ohnehin separat (Check bios-admin-password).
if ($p.ExitCode -eq 0) {
    Set-Step -StateDir $Context.StateDir -Name 'step1_bios.done' -Detail 'RC=0, angewendet aus OOBE (HEPHAISTOS)'
    # Kein Reboot hier (Abweichung zum Menü-Original, dort wurde gefragt):
    # Das Gerät startet nach dem Hash-Schritt ohnehin automatisch neu.
    Write-HephDim 'Kein Neustart an dieser Stelle: Die BIOS-Einstellungen werden beim'
    Write-HephDim 'automatischen Neustart nach dem Autopilot-Hash-Schritt wirksam.'
    Write-HephResult -Success $true -Text 'BIOS-Konfiguration ERFOLGREICH. Wird nach Neustart wirksam.'
} else {
    $failedOpts = @()
    if ($log -and (Test-Path $log)) {
        $logText = Get-Content -Path $log -Raw -ErrorAction SilentlyContinue
        if ($logText) {
            $failedOpts = @([regex]::Matches($logText, "error setting the option '([^']+)'") |
                ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
        }
    }
    # ROT nur, wenn das BIOS-Passwort SELBST scheitert (SetupPwd/SysPwd/...).
    # Passwort-NAHE Optionen (z.B. MasterPasswordLockout) scheitern erfahrungs-
    # gemäß an der Anwendungsreihenfolge (Passwort muss zuerst gesetzt sein) -
    # das ergibt GELB mit deutlichem Sicherheitshinweis, nicht ROT.
    $pwdFailed = @($failedOpts | Where-Object { $_ -match '(?i)^(val)?(setup|sys|own|admin)pwd$' })
    $pwdNear   = @($failedOpts | Where-Object { ($_ -match '(?i)pwd|password') -and ($pwdFailed -notcontains $_) })
    if ($failedOpts.Count -ge 1 -and $pwdFailed.Count -eq 0) {
        Write-HephWarn ("CCTK Exit-Code {0}: {1} Option(en) nicht anwendbar (Modell-/Ausstattungsunterschiede oder Reihenfolge):" -f $p.ExitCode, $failedOpts.Count)
        foreach ($o in $failedOpts) { Write-HephWarn ('  - {0}' -f $o) }
        if ($pwdNear.Count -gt 0) {
            Write-HephWarn ("ACHTUNG, sicherheitsrelevant: {0} nicht gesetzt - CCTK-Paket prüfen" -f ($pwdNear -join ', '))
            Write-HephWarn '(diese Option braucht i.d.R. ein bereits gesetztes Admin-Passwort / ValSetupPwd).'
        }
        Write-HephDim 'Alle übrigen Einstellungen wurden angewendet (Details: cctk_apply.log im Geräteordner).'
        Set-Step -StateDir $Context.StateDir -Name 'step1_bios.done' -Detail ("RC={0}, angewendet MIT HINWEISEN - nicht anwendbar: {1}" -f $p.ExitCode, ($failedOpts -join ', '))
        Write-HephDim 'Kein Neustart an dieser Stelle: Die BIOS-Einstellungen werden beim'
        Write-HephDim 'automatischen Neustart nach dem Autopilot-Hash-Schritt wirksam.'
        Write-HephResult -Success $true -Text 'BIOS-Konfiguration angewendet - MIT HINWEISEN (gelbe Punkte oben).'
    } else {
        Write-HephErr ("FEHLER: Exit-Code {0}. Logs im Geräteordner prüfen." -f $p.ExitCode)
        if ($pwdFailed.Count -gt 0) {
            Write-HephErr ("Passwort-relevante Option(en) fehlgeschlagen: {0} - CCTK-Paket prüfen (SetupPwd vs. ValSetupPwd)!" -f ($pwdFailed -join ', '))
        }
        Write-HephDim ("Geräteordner: {0}" -f $Context.DevDir)
        Write-HephWarn 'Bei "Extraction Error" der SCE-EXE: Paket am Admin-PC mit /s /e= entpacken'
        Write-HephWarn '(Pro16Plus_CCTK_x64.exe /s /e=C:\Temp\CCTK) und den Inhalt nach'
        Write-HephWarn '_HEPHAISTOS\Tools\CCTK\ auf dem Stick kopieren (siehe docs\ANLEITUNG.md).'
        Write-HephResult -Success $false -Text ("BIOS-Konfiguration fehlgeschlagen (Exit-Code {0})." -f $p.ExitCode)
    }
}
