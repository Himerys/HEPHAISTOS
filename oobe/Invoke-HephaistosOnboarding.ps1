<#
.SYNOPSIS
    HEPHAISTOS - OOBE-Onboarding: BIOS-Konfiguration, optional WinRE-Entfernung,
    Autopilot-Hash inkl. Profilzuweisungs-Polling und Auto-Reboot.
.DESCRIPTION
    Wird in der OOBE per Shift+F10 über C:\OSDCloud\HEPHAISTOS\oobe.cmd gestartet
    (holt immer die aktuelle Version aus dem Repo; offline: gestagte Kopie).
    Direktaufruf:
        powershell -NoProfile -ExecutionPolicy Bypass -File Invoke-HephaistosOnboarding.ps1
    Ablauf:
        1. BIOS-Konfiguration (Dell CCTK, Binärdateien vom Stick)
        2. optional: WinRE entfernen (nur wenn deploy.json: RemoveWinRE = true)
        3. Autopilot-Hash: Offline-CSV + Online-Upload + Profilzuweisungs-Polling
           (bei zugewiesenem Profil: automatischer Neustart in das Provisioning)
    Status pro Gerät: <Stick>:\Logs\<ServiceTag>\state\*.done
.NOTES
    HEPHAISTOS v1.0.1 - portiert aus USB_ScriptTool Rev05 (_SLG\SLG-Onboarding.ps1).
    Benötigt PowerShell 5.1 (OOBE/Win11 Standard). Datei ist UTF-8 MIT BOM gespeichert
    (Pflicht für PS 5.1 + Umlaute).
#>

$ErrorActionPreference = 'Stop'

$Check = [char]0x2713   # Haken-Symbol, zur Laufzeit erzeugt (ASCII-sichere Quelldatei)
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

# --- HEPHAISTOS Lib-Bootstrap (identisch in allen Entry-Scripts) ---
$Script:HephVersion = '1.0.1'
$Script:HephRawBase = 'https://raw.githubusercontent.com/Himerys/HEPHAISTOS/main'
# FallbackRoots dieser Phase (OOBE): zuerst die gestagte Kopie auf C:, dann der
# Stick. Der Stick wird hier per Minimal-Suche gefunden (DriveInfo-Schleife nach
# \_HEPHAISTOS) - die Lib mit Find-HephaistosUsb ist an dieser Stelle noch nicht geladen.
$Script:HephFallbackRoots = @('C:\OSDCloud\HEPHAISTOS\Fallback')
foreach ($drv in [IO.DriveInfo]::GetDrives()) {
    try {
        if (-not $drv.IsReady) { continue }
        $root = $drv.RootDirectory.FullName
        if (Test-Path (Join-Path $root '_HEPHAISTOS')) {
            $Script:HephFallbackRoots += (Join-Path $root '_HEPHAISTOS\Fallback')
            break
        }
    } catch { }
}
# 1) TLS 1.2 aktivieren, 2) Download lib/Hephaistos.Common.ps1 -> TEMP versuchen,
# 3) sonst erste existierende Fallback-Kopie, 4) Dot-Source; 5) Fehler -> rote
# Meldung + exit 1. Quelle in $Script:HephLibSource merken (fürs Banner).
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$libRel  = 'lib/Hephaistos.Common.ps1'
$libTemp = Join-Path $env:TEMP 'HEPHAISTOS\lib\Hephaistos.Common.ps1'
$libPath = $null
try {
    $null = New-Item -Path (Split-Path $libTemp) -ItemType Directory -Force
    Invoke-WebRequest -UseBasicParsing -Uri ("{0}/{1}" -f $Script:HephRawBase, $libRel) -OutFile $libTemp -ErrorAction Stop
    $libPath = $libTemp
    $Script:HephLibSource = ("GitHub: {0}/{1}" -f $Script:HephRawBase, $libRel)
} catch {
    foreach ($fbRoot in $Script:HephFallbackRoots) {
        $cand = Join-Path $fbRoot 'lib\Hephaistos.Common.ps1'
        if (Test-Path $cand) {
            $libPath = $cand
            $Script:HephLibSource = ("lokale Kopie: {0}" -f $cand)
            Write-Host ("OFFLINE-FALLBACK: nutze lokale Lib-Kopie {0}, Stand {1:yyyy-MM-dd HH:mm}" -f $cand, (Get-Item $cand).LastWriteTime) -ForegroundColor Yellow
            break
        }
    }
}
if (-not $libPath) {
    Write-Host 'FATAL: lib/Hephaistos.Common.ps1 weder online noch als lokale Kopie gefunden.' -ForegroundColor Red
    exit 1
}
try { . $libPath } catch {
    Write-Host ("FATAL: Lib konnte nicht geladen werden: {0}" -f $_.Exception.Message) -ForegroundColor Red
    exit 1
}
# --- Ende Lib-Bootstrap ---

# ============================================================ Gerät + Banner
$devInfo = Get-HephaistosDeviceInfo
$Serial  = $devInfo.Serial
$Model   = $devInfo.Model

# OOBE-Erkennung: in der OOBE läuft die Shift+F10-Konsole als defaultuser0
$IsOobe  = ($env:USERNAME -ieq 'defaultuser0')
$envText = 'Windows'
if ($IsOobe) { $envText = 'OOBE' }

Write-HephBanner -Title 'HEPHAISTOS - OOBE Onboarding' -Version $Script:HephVersion -Source $Script:HephLibSource -Model $Model -Serial $Serial -Env $envText

# Adminrechte prüfen. Die OOBE-Konsole (Shift+F10) läuft bereits mit Adminrechten;
# eine Selbst-Elevation wie im Original-Menü entfällt hier bewusst (ein Relaunch
# würde den Download-Kontext von oobe.cmd verlieren) - es bleibt bei der Warnung.
$Script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
                  ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $Script:IsAdmin) {
    Write-HephWarn 'Adminrechte FEHLEN - BIOS-Konfiguration und Autopilot-Hash werden voraussichtlich fehlschlagen.'
}

# ============================================================ Konfiguration laden
Write-HephPhase -Title 'Konfiguration laden (deploy.json)' -EstimatedDuration 'wenige Sekunden'
try {
    $cfgLoad = Get-HephaistosConfig -RelPath 'config/deploy.json' -RawBase $Script:HephRawBase -FallbackRoots $Script:HephFallbackRoots
    $cfg     = $cfgLoad.Data
    Write-HephResult -Success $true -Text ("deploy.json geladen (ConfigVersion {0}, Quelle: {1})" -f $cfg.ConfigVersion, $cfgLoad.Source)
} catch {
    Write-HephResult -Success $false -Text ("deploy.json konnte nicht geladen werden: {0}" -f $_.Exception.Message)
    exit 1
}

# ============================================================ Stick + Geräteordner
# Der Stick bleibt während des gesamten Ablaufs eingesteckt: dort liegen die
# CCTK-Tools, der Secrets-Blob und der sichtbare Geräteordner (Logs\<Serial>).
$UsbRoot = Find-HephaistosUsb
if ($UsbRoot) {
    Write-HephDim ("USB-Stick gefunden: {0}" -f $UsbRoot)
    $stickFallback = Join-Path $UsbRoot '_HEPHAISTOS\Fallback'
    if ($Script:HephFallbackRoots -notcontains $stickFallback) { $Script:HephFallbackRoots += $stickFallback }
} else {
    Write-HephWarn 'Ohne Stick fehlen CCTK-Tools und Secrets - die betroffenen Schritte melden das einzeln.'
}

$dirs     = Initialize-HephaistosDevice -UsbRoot $UsbRoot -Serial $Serial
$DevDir   = $dirs.DevDir
$StateDir = $dirs.StateDir
Write-HephDim ("Geräteordner: {0}" -f $DevDir)

# Sitzung protokollieren (best effort, Port SLG-Onboarding.ps1 Z.81-84)
try {
    Start-Transcript -Path (Join-Path $DevDir ("OOBE_{0}.log" -f (Get-Date -Format 'yyyy-MM-dd_HHmm'))) -Append | Out-Null
} catch { }

# ============================================================ install.json + Techniker
# install.json wird vom WinPE-Boot-Script gestaged und liefert u.a. den in WinPE
# erfassten Technikernamen als Default (Enter übernimmt ihn unverändert).
$StagedRoot  = 'C:\OSDCloud\HEPHAISTOS'
$techDefault = $null
$installJson = Join-Path $StagedRoot 'install.json'
if (Test-Path $installJson) {
    try {
        $inst = Get-Content $installJson -Raw | ConvertFrom-Json
        if ($inst.Technician) { $techDefault = ([string]$inst.Technician).Trim() }
        Write-HephDim ("install.json: Wipe gestartet {0}, Sprache {1}, Quelle {2}" -f $inst.WipeStartedUtc, $inst.OSLanguage, $inst.Source)
    } catch {
        Write-HephDim ("install.json vorhanden, aber nicht lesbar: {0}" -f $_.Exception.Message)
    }
}
if ($techDefault) { $Technician = Get-TechnicianName -Default $techDefault }
else              { $Technician = Get-TechnicianName }
# Namen für die Abnahme-Phase festhalten (Geräteordner, best effort)
try { $Technician | Set-Content -Path (Join-Path $DevDir 'technician.txt') -Encoding UTF8 } catch { }

# ============================================================ Schritt-2-Auto-Erkennung
# Schritt 2 gilt NUR dann als erledigt, wenn die Neuinstallation nachweislich
# von diesem Stick initiiert wurde: Das Flag step2_osinstall.started entsteht
# ausschließlich in WinPE (unmittelbar vor Start-OSDCloud), und das
# Installationsdatum des laufenden Windows muss JUENGER sein als dieses Flag.
# Das Werks-OS fällt durch beide Prüfungen (kein Flag bzw. InstallDate älter
# als der Wipe). (Port SLG-Onboarding.ps1 Z.93-111)
$Script:InstallDate = $null
try {
    $epoch = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop).InstallDate
    $Script:InstallDate = ([datetime]::new(1970,1,1,0,0,0,[DateTimeKind]::Utc)).AddSeconds($epoch)
} catch { }
if (-not (Test-Step -StateDir $StateDir -Name 'step2_osinstall.done')) {
    $startedFlag = Get-StepFlag -StateDir $StateDir -Name 'step2_osinstall.started'
    if ((Test-Path $startedFlag) -and $Script:InstallDate) {
        $startedTime = (Get-Item $startedFlag).LastWriteTimeUtc
        if ($Script:InstallDate -gt $startedTime) {
            Set-Step -StateDir $StateDir -Name 'step2_osinstall.done' -Detail ("Neuinstallation erkannt: OS-InstallDate {0:yyyy-MM-dd HH:mm}Z liegt nach Wipe-Start {1:yyyy-MM-dd HH:mm}Z" -f $Script:InstallDate, $startedTime)
            Write-HephOk 'Windows-Installation automatisch als erledigt erkannt.'
        }
    }
}
if (-not (Test-Step -StateDir $StateDir -Name 'step2_osinstall.done')) {
    # Ohne Menü gibt es keinen Nachfrage-Dialog mehr - nur sichtbare Prüfdetails
    # (Kurzform von Invoke-Step2Info, Port Z.299-305).
    $startedFlag = Get-StepFlag -StateDir $StateDir -Name 'step2_osinstall.started'
    Write-HephWarn 'Neuinstallation wurde NICHT erkannt. Prüfdetails:'
    Write-HephWarn ("  Wipe-Flag vom Stick (WinPE): {0}" -f $(if (Test-Path $startedFlag) { ('vorhanden, {0:yyyy-MM-dd HH:mm}Z' -f (Get-Item $startedFlag).LastWriteTimeUtc) } else { 'FEHLT' }))
    Write-HephWarn ("  OS-Installationsdatum:       {0}" -f $(if ($Script:InstallDate) { '{0:yyyy-MM-dd HH:mm}Z' -f $Script:InstallDate } else { 'unbekannt' }))
    Write-HephWarn '  Läuft hier noch das WERKS-OS? Dann Gerät vom Stick booten (F12) und neu installieren.'
}

# ============================================================ Kontext für die Schritte
$SecretsPath = $null
if ($UsbRoot) { $SecretsPath = Join-Path $UsbRoot 'HEPHAISTOS-Secrets\hephaistos.secrets.enc.json' }

$ctx = @{
    UsbRoot       = $UsbRoot
    DevDir        = $DevDir
    StateDir      = $StateDir
    Serial        = $Serial
    Model         = $Model
    Config        = $cfg
    ConfigSource  = $cfgLoad.Source
    StagedRoot    = $StagedRoot
    RawBase       = $Script:HephRawBase
    FallbackRoots = $Script:HephFallbackRoots
    Technician    = $Technician
    SecretsPath   = $SecretsPath
}

# ============================================================ Schritte ausführen
# Reihenfolge: BIOS -> (optional) RemoveWinRE -> Autopilot-Hash. Der Hash-Schritt
# endet bei erfolgreicher Profilzuweisung mit einem automatischen Neustart!
$stepList = @()
$stepList += @{ Titel = 'BIOS-Konfiguration';               Rel = 'oobe/steps/Invoke-BiosConfig.ps1' }
if ($cfg.RemoveWinRE -eq $true) {
    $stepList += @{ Titel = 'WinRE entfernen (RemoveWinRE)'; Rel = 'oobe/steps/Invoke-RemoveWinRE.ps1' }
} else {
    Write-HephDim 'RemoveWinRE ist in deploy.json deaktiviert - Schritt wird übersprungen.'
}
$stepList += @{ Titel = 'Autopilot-Hash + Profilzuweisung'; Rel = 'oobe/steps/Invoke-AutopilotHash.ps1' }

$total = $stepList.Count
for ($i = 0; $i -lt $total; $i++) {
    $s = $stepList[$i]
    Write-Host ''
    Write-HephInfo ("--- Schritt {0}/{1}: {2} ---" -f ($i + 1), $total, $s.Titel)
    try {
        $item = Get-HephaistosScript -RelPath $s.Rel -RawBase $Script:HephRawBase -FallbackRoots $Script:HephFallbackRoots
        Write-HephDim ("Script-Quelle: {0} ({1})" -f $item.Source, $item.Detail)
        & $item.Path -Context $ctx
    } catch {
        # Fehlerbehandlung im Stil des Original-Menü-Loops (Z.846-851)
        Write-HephErr ("FEHLER: {0}" -f $_.Exception.Message)
        if (-not (Confirm-Choice -Prompt 'Trotzdem fortfahren?')) {
            Write-HephErr 'Onboarding abgebrochen - Gerät bleibt im aktuellen Zustand.'
            try { Stop-Transcript | Out-Null } catch { }
            exit 1
        }
    }
}

# ============================================================ Zusammenfassung
# Hat der Hash-Schritt den Auto-Reboot eingeleitet, läuft bereits shutdown /r /t 10 -
# dann entfällt die Zusammenfassung (best effort: der Schritt kann $Context.AutoReboot
# setzen; ohne das Feld erscheint die Zusammenfassung noch während des Countdowns,
# was harmlos ist - das Gerät startet trotzdem neu).
if ($ctx.ContainsKey('AutoReboot') -and $ctx.AutoReboot) {
    Write-HephInfo 'Automatischer Neustart eingeleitet - Gerät bootet in das Autopilot-Provisioning.'
    try { Stop-Transcript | Out-Null } catch { }
    exit 0
}

$bar = [string][char]0x2550 * 70
Write-Host ''
Write-Host $bar -ForegroundColor DarkCyan
Write-Host '   ONBOARDING-STATUS (OOBE-Phase abgeschlossen)' -ForegroundColor White
Write-Host $bar -ForegroundColor DarkCyan
# Anzeige in der neuen Ablauf-Reihenfolge: Installation, BIOS, Hash, Abnahme
# (Flag-Namen bleiben aus Kontinuitätsgründen die alten step1-4-Namen).
$summarySteps = @(
    @{ N = 1; T = 'Windows-Installation'; F = 'step2_osinstall.done' },
    @{ N = 2; T = 'BIOS-Konfiguration';   F = 'step1_bios.done' },
    @{ N = 3; T = 'Autopilot-Hash';       F = 'step3_hash.done' },
    @{ N = 4; T = 'Abnahme-Prüfung';      F = 'step4_compliance.done' }
)
foreach ($s in $summarySteps) {
    $flag = Get-StepFlag -StateDir $StateDir -Name $s.F
    if (Test-Path $flag) {
        Write-Host ('    [{0}] ' -f $Check) -NoNewline -ForegroundColor Green
        Write-Host ('{0}. {1}' -f $s.N, $s.T) -NoNewline -ForegroundColor DarkGreen
        $detail = ''
        try { $detail = (Get-Content $flag -Raw).Trim() } catch { }
        if ($detail) { Write-Host ('  {0}' -f $detail) -ForegroundColor DarkGray } else { Write-Host '' }
    } else {
        Write-Host '    [ ] ' -NoNewline -ForegroundColor DarkGray
        Write-Host ('{0}. {1}' -f $s.N, $s.T) -NoNewline -ForegroundColor White
        Write-Host '  (offen)' -ForegroundColor DarkGray
    }
}
Write-Host ''
Write-HephInfo 'Nächste Schritte: OOBE weiterlaufen lassen (Autopilot-Provisioning).'
if ($UsbRoot) {
    Write-HephInfo ('Abnahme danach im fertigen Windows: {0}START-ABNAHME.cmd' -f $UsbRoot)
} else {
    Write-HephInfo 'Abnahme danach im fertigen Windows: START-ABNAHME.cmd vom Stick-Root starten.'
}

try { Stop-Transcript | Out-Null } catch { }
