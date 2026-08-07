<#
.SYNOPSIS
    HEPHAISTOS - WinPE-Einstieg (StartURL-Ziel): Techniker-/Sprachdialog, kompletter
    Disk-Wipe + Windows-Neuinstallation via OSDCloud (ZTI), Staging der OOBE-Dateien.
.DESCRIPTION
    Wird von der OSDCloud-WinPE-Umgebung über die eingebaute StartURL geladen:
        startnet.cmd -> StartURL -> <RawBase>/boot/Start-Hephaistos.ps1
    Ablauf:
        [1] Lib-Bootstrap (GitHub, Offline-Fallback: <Stick>:\_HEPHAISTOS\Fallback)
        [2] deploy.json laden + OS-Name gegen das OSD-Modul prüfen (Soft-Check)
        [3] Technikername (Pflichtfeld) + Sprachauswahl
        [4] ROTER Warnblock, Bestätigung des Wipes durch Eingabe von LOESCHEN
        [5] Start-OSDCloud -ZTI (kompletter Wipe + Neuinstallation)
        [6] Staging nach C:\OSDCloud\HEPHAISTOS\ (oobe.cmd, install.json, Fallback-Spiegel)
        [7] Neustart via wpeutil reboot (10-Sekunden-Countdown)
    Status pro Gerät: <Stick>\Logs\<ServiceTag>\state\*.done (Flag-Namen wie im Original).
.NOTES
    HEPHAISTOS v1.0.2 - portiert aus USB_ScriptTool Rev05 (START-ONBOARDING.cmd +
    SLG-Onboarding.ps1). PowerShell 5.1. UTF-8 mit BOM (Pflicht für PS 5.1 + Umlaute).
    Bugfix (Handoff 7.1): step2_osinstall.started wird ERST unmittelbar vor
    Start-OSDCloud geschrieben - nicht schon bei der Menüauswahl wie im alten
    START-ONBOARDING.cmd (dort bestätigte sich :Step2FullOS damit selbst).
#>

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

# --- HEPHAISTOS Lib-Bootstrap (identisch in allen Entry-Scripts) ---
$Script:HephVersion = '1.0.2'
$Script:HephRawBase = 'https://raw.githubusercontent.com/Himerys/HEPHAISTOS/main'
# FallbackRoots je Phase - Boot-Phase: <Stick>:\_HEPHAISTOS\Fallback. Die Lib selbst
# kann vom Stick kommen, deshalb Minimal-Stick-Suche VOR dem Lib-Load (DriveInfo-
# Schleife, keine Get-Volume-Abhängigkeit - läuft so auch in WinPE).
$Script:PreUsbRoot = $null
foreach ($drv in [IO.DriveInfo]::GetDrives()) {
    try {
        if ($drv.IsReady -and (Test-Path (Join-Path $drv.Name '_HEPHAISTOS'))) {
            $Script:PreUsbRoot = $drv.Name
            break
        }
    } catch { }
}
$Script:HephFallbackRoots = @()
if ($Script:PreUsbRoot) {
    $Script:HephFallbackRoots = @((Join-Path $Script:PreUsbRoot '_HEPHAISTOS\Fallback'))
}
# 1) TLS12 aktivieren, 2) versuche Download lib/Hephaistos.Common.ps1 -> TEMP,
# 3) sonst erste existierende Fallback-Kopie, 4) Dot-Source; 5) Fehler -> rote
# Meldung + exit 1. Quelle in $Script:HephLibSource merken (fürs Banner).
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$libRel  = 'lib/Hephaistos.Common.ps1'
$libPath = $null
try {
    $libTemp = Join-Path $env:TEMP 'HEPHAISTOS\lib\Hephaistos.Common.ps1'
    $null = New-Item -Path (Split-Path -Parent $libTemp) -ItemType Directory -Force
    Invoke-WebRequest -UseBasicParsing -Uri ('{0}/{1}' -f $Script:HephRawBase, $libRel) -OutFile $libTemp
    $libPath = $libTemp
    $Script:HephLibSource = ('GitHub: {0}/{1}' -f $Script:HephRawBase, $libRel)
} catch {
    foreach ($fbRoot in $Script:HephFallbackRoots) {
        $cand = Join-Path $fbRoot 'lib\Hephaistos.Common.ps1'
        if (Test-Path $cand) {
            Write-Host ('OFFLINE-FALLBACK: nutze lokale Lib-Kopie {0}, Stand {1:yyyy-MM-dd HH:mm}' -f $cand, (Get-Item $cand).LastWriteTime) -ForegroundColor Yellow
            $libPath = $cand
            $Script:HephLibSource = ('lokale Kopie: {0}' -f $cand)
            break
        }
    }
}
if (-not $libPath) {
    Write-Host 'FEHLER: lib/Hephaistos.Common.ps1 ist weder aus dem Repo noch vom Stick ladbar.' -ForegroundColor Red
    Write-Host ('  Repo : {0}/{1}' -f $Script:HephRawBase, $libRel) -ForegroundColor Red
    Write-Host '  Stick: kein Laufwerk mit \_HEPHAISTOS\Fallback\lib gefunden.' -ForegroundColor Red
    exit 1
}
. $libPath
# --- Ende Lib-Bootstrap ---

# ============================================================ Umgebung + Hilfsfunktionen
# WinPE-Erkennung wie im Original (START-ONBOARDING.cmd: Registry-Key MiniNT).
$Script:IsWinPE = Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT'

function Invoke-HephReboot {
    # Neustart mit optionalem sichtbarem Countdown. In WinPE via wpeutil, sonst
    # shutdown (Port der Verzweigung aus START-ONBOARDING.cmd :Step1).
    param([int]$CountdownSeconds = 0, [int]$ExitCode = 0)
    if ($CountdownSeconds -gt 0) {
        Write-HephDim '(Strg+C bricht den Countdown ab)'
        for ($s = $CountdownSeconds; $s -ge 1; $s--) {
            Write-Host -NoNewline ("`r  Neustart in {0,2} Sekunden ..." -f $s) -ForegroundColor Cyan
            Start-Sleep -Seconds 1
        }
        Write-Host ''
    }
    try { Stop-Transcript | Out-Null } catch { }
    if ($Script:IsWinPE) { wpeutil reboot } else { shutdown.exe /r /t 3 /f }
    exit $ExitCode
}

function Update-HephFallbackMirror {
    # Aktualisiert den gestagten Fallback-Spiegel Datei für Datei frisch aus dem
    # Repo (best effort, Fehler werden still toleriert - offline bzw. bei nicht
    # vorhandener Repo-Datei bleibt die Stick-Kopie unverändert bestehen).
    param([string]$MirrorRoot, [string[]]$RelFiles)
    $ok = 0; $keep = 0; $i = 0
    foreach ($rel in $RelFiles) {
        $i++
        $pct = [int](($i / [math]::Max(1, $RelFiles.Count)) * 100)
        Write-Progress -Activity 'Fallback-Spiegel aus dem Repo aktualisieren' -Status $rel -PercentComplete $pct
        try {
            $url  = '{0}/{1}' -f $Script:HephRawBase, ($rel -replace '\\', '/')
            $tmp  = Join-Path $env:TEMP ('HEPHAISTOS\refresh\{0}' -f $rel)
            $dest = Join-Path $MirrorRoot $rel
            $null = New-Item -Path (Split-Path -Parent $tmp) -ItemType Directory -Force
            Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $tmp
            $null = New-Item -Path (Split-Path -Parent $dest) -ItemType Directory -Force
            Move-Item -Path $tmp -Destination $dest -Force
            $ok++
        } catch { $keep++ }
    }
    Write-Progress -Activity 'Fallback-Spiegel aus dem Repo aktualisieren' -Completed
    @{ Updated = $ok; Kept = $keep }
}

# ============================================================ Gerät + Transcript
$devInfo = Get-HephaistosDeviceInfo
$Serial  = $devInfo.Serial
$Model   = $devInfo.Model
$usbRoot = $Script:PreUsbRoot
if (-not $usbRoot) { $usbRoot = Find-HephaistosUsb }
if (-not $usbRoot) {
    # Ohne Stick landen Flags/Logs auf C: - und C: wird gleich gewiped: die
    # Schritt-2-Auto-Erkennung in der OOBE kann dann NICHT greifen.
    Write-HephErr 'Kein HEPHAISTOS-Stick (_HEPHAISTOS) gefunden!'
    Write-HephWarn 'Ohne Stick überleben Status-Flags und Logs den Disk-Wipe NICHT.'
    if (-not (Confirm-Choice 'Trotzdem ohne Stick fortfahren?')) {
        Write-HephInfo 'Abbruch - Stick anstecken und neu booten.'
        Invoke-HephReboot -ExitCode 1
    }
}
$dirs = $null
try {
    $dirs = Initialize-HephaistosDevice -UsbRoot $usbRoot -Serial $Serial
} catch {
    # WinPE-Sonderfall (z.B. noch kein C:-Volume auf leerer Disk): nicht
    # abbrechen, sondern auf die RAM-Disk ausweichen (überlebt den Wipe nicht).
    Write-HephWarn ('Geräteordner konnte nicht angelegt werden ({0}) - nutze TEMP.' -f $_.Exception.Message)
    $tmpDev = Join-Path $env:TEMP ('HEPHAISTOS\Logs\{0}' -f $Serial)
    $null = New-Item -Path (Join-Path $tmpDev 'state') -ItemType Directory -Force
    $dirs = @{ DevDir = $tmpDev; StateDir = (Join-Path $tmpDev 'state') }
}
$DevDir   = $dirs.DevDir
$StateDir = $dirs.StateDir

# Sitzung protokollieren (best effort, Port aus SLG-Onboarding.ps1)
try {
    Start-Transcript -Path (Join-Path $DevDir ('WinPE_{0}.log' -f (Get-Date -Format 'yyyy-MM-dd_HHmm'))) -Append | Out-Null
} catch { }

$envName = 'Windows'
if ($Script:IsWinPE) { $envName = 'WinPE' }
Write-HephBanner -Title 'HEPHAISTOS - WinPE Boot' -Version $Script:HephVersion -Source $Script:HephLibSource -Model $Model -Serial $Serial -Env $envName
Write-HephDim ('Geräteordner: {0}' -f $DevDir)
Write-Host ''

# ============================================================ Konfiguration
try {
    $cfgInfo = Get-HephaistosConfig -RelPath 'config/deploy.json' -RawBase $Script:HephRawBase -FallbackRoots $Script:HephFallbackRoots
    $cfg = $cfgInfo.Data
    Write-HephDim ('deploy.json geladen ({0}: {1}, ConfigVersion {2})' -f $cfgInfo.Source, $cfgInfo.Detail, $cfg.ConfigVersion)
    # Eine Quelle für die RawBase (Handoff §5): ab jetzt gilt der Wert aus
    # deploy.json - er fließt in Spiegel-Refresh und {{RAWBASE}}-Ersetzung.
    if ($cfg.Repo -and $cfg.Repo.RawBase) { $Script:HephRawBase = [string]$cfg.Repo.RawBase }
} catch {
    Write-HephErr ('deploy.json konnte nicht geladen werden: {0}' -f $_.Exception.Message)
    Write-HephErr 'Ohne Konfiguration kein Deployment - Abbruch.'
    if (Confirm-Choice 'Gerät jetzt neu starten?') { Invoke-HephReboot -ExitCode 1 }
    try { Stop-Transcript | Out-Null } catch { }
    exit 1
}

$osName = [string]$cfg.OS.OSName

# Ohne das OSD-Modul (Start-OSDCloud) läuft hier nichts - dieses Script ist für
# die OSDCloud-WinPE-Umgebung gebaut (Stick kommt aus tools/Build-USB.ps1).
if (-not (Get-Command -Name Start-OSDCloud -ErrorAction SilentlyContinue)) {
    Write-HephErr 'Start-OSDCloud nicht gefunden - dieses Script muss in der OSDCloud-WinPE-Umgebung laufen.'
    if (Confirm-Choice 'Gerät jetzt neu starten?') { Invoke-HephReboot -ExitCode 1 }
    try { Stop-Transcript | Out-Null } catch { }
    exit 1
}

# --- Soft-Check (Handoff 4.2): konfigurierter OS-Name gegen die OSD-Modulliste ---
if (Get-Command -Name Get-OSDCloudOperatingSystems -ErrorAction SilentlyContinue) {
    try {
        Write-HephDim ('Prüfe "{0}" gegen Get-OSDCloudOperatingSystems ...' -f $osName)
        $osdNames = @(Get-OSDCloudOperatingSystems | ForEach-Object { [string]$_.Name } | Where-Object { $_ })
        # Neuere OSD-Kataloge listen VOLLNAMEN ("<OSName> <Sprache> <Aktivierung> <Build>",
        # z.B. "Windows 11 25H2 x64 de-de Retail 26200.8653"). Sprache/Aktivierung sind
        # bei uns separate Start-OSDCloud-Parameter - deshalb gilt der Katalog auch dann
        # als abgedeckt, wenn fuer JEDE konfigurierte Sprache ein Eintrag existiert, der
        # mit dem OSName beginnt und Sprache + Aktivierung enthaelt (Praefix-Matching).
        $osdOk = ($osdNames -contains $osName)
        if (-not $osdOk) {
            $cfgLangs = @($cfg.Languages.PSObject.Properties | ForEach-Object { [string]$_.Value.OSLanguage } | Where-Object { $_ })
            $osdAct   = [string]$cfg.OS.OSActivation
            if ($cfgLangs.Count -gt 0) {
                $osdOk = $true
                foreach ($lg in $cfgLangs) {
                    $hit = @($osdNames | Where-Object { $_ -like ($osName + '*') -and $_ -like ('*' + $lg + '*') -and $_ -like ('*' + $osdAct + '*') })
                    if ($hit.Count -eq 0) { $osdOk = $false; break }
                }
            }
        }
        if ($osdOk) {
            Write-HephOk ('OS-Name "{0}" ist im OSD-Modul abgedeckt (alle Sprachen + {1}).' -f $osName, $cfg.OS.OSActivation)
        } else {
            Write-HephWarn ('OS-Name "{0}" ist im installierten OSD-Modul NICHT gelistet!' -f $osName)
            $token = $null
            if ($osName -match '\d{2}H\d') { $token = $Matches[0] }
            $near = @()
            if ($token) { $near = @($osdNames | Where-Object { $_ -like ('*{0}*' -f $token) } | Select-Object -First 8) }
            if (-not $near) { $near = @($osdNames | Where-Object { $_ -like '*Windows 11*x64*' } | Select-Object -First 8) }
            if ($near) {
                Write-HephWarn 'Nächstliegende gelistete Namen:'
                foreach ($n in $near) { Write-Host ('    {0}' -f $n) -ForegroundColor Yellow }
            }
            if (-not (Confirm-Choice 'Trotzdem mit dem konfigurierten Namen fortfahren?')) {
                Write-HephWarn 'Abbruch durch Techniker - es wurde nichts verändert.'
                Invoke-HephReboot -CountdownSeconds 5
            }
        }
    } catch {
        Write-HephWarn ('OS-Namens-Prüfung fehlgeschlagen ({0}) - fahre fort.' -f $_.Exception.Message)
    }
} else {
    Write-HephDim 'Get-OSDCloudOperatingSystems nicht verfügbar - Prüfung übersprungen.'
}

# ============================================================ Techniker + Sprache
# Handoff 4.1: Freitext-Pflichtfeld so früh wie sinnvoll; der Wert wandert in den
# Geräteordner (Stick) und wird in OOBE/Abnahme als Default angeboten.
Write-Host ''
$tech = Get-TechnicianName
try {
    Set-Content -Path (Join-Path $DevDir 'technician.txt') -Value $tech -Encoding UTF8
    Write-HephDim ('Techniker gespeichert: {0}' -f (Join-Path $DevDir 'technician.txt'))
} catch {
    Write-HephWarn ('technician.txt konnte nicht geschrieben werden: {0}' -f $_.Exception.Message)
}

# Sprachmenü aus der Config (Nummern-Keys, Enter = DefaultLanguageKey)
$langProps = @($cfg.Languages.PSObject.Properties | Sort-Object Name)
if ($langProps.Count -eq 0) {
    Write-HephErr 'deploy.json enthält keine Sprachen (Languages) - Abbruch.'
    Invoke-HephReboot -CountdownSeconds 5 -ExitCode 1
}
$defaultKey  = [string]$cfg.DefaultLanguageKey
$defaultProp = $langProps | Where-Object { $_.Name -eq $defaultKey } | Select-Object -First 1
if (-not $defaultProp) { $defaultProp = $langProps[0]; $defaultKey = $defaultProp.Name }
Write-Host ''
Write-HephInfo 'Sprache der Windows-Installation wählen:'
foreach ($p in $langProps) {
    Write-Host ('  [{0}] {1}' -f $p.Name, $p.Value.Label) -ForegroundColor White
}
$langProp = $null
while (-not $langProp) {
    $sel = (Read-Host ('Sprache [Enter = {0}]' -f $defaultProp.Value.Label)).Trim()
    if (-not $sel) { $sel = $defaultKey }
    $langProp = $langProps | Where-Object { $_.Name -eq $sel } | Select-Object -First 1
    if (-not $langProp) { Write-HephWarn 'Ungültige Auswahl - bitte eine Nummer aus der Liste eingeben.' }
}
$lang      = [string]$langProp.Value.OSLanguage
$langLabel = [string]$langProp.Value.Label
Write-HephOk ('Sprache: {0} ({1})' -f $langLabel, $lang)

# ============================================================ Wipe-Bestätigung
# Port der LOESCHEN-Bestätigung aus START-ONBOARDING.cmd :Step2. Eine Disk-Auswahl
# gibt es nicht mehr: OSDCloud ZTI wählt die interne Disk automatisch.
$barR = [string][char]0x2550 * 70
Write-Host ''
Write-Host $barR -ForegroundColor Red
Write-Host '   ACHTUNG: KOMPLETTER DISK-WIPE' -ForegroundColor Red
Write-Host $barR -ForegroundColor Red
Write-Host ('   Gerät:       {0}' -f $Model) -ForegroundColor White
Write-Host ('   Service Tag: {0}' -f $Serial) -ForegroundColor White
Write-Host ('   Ziel-OS:     {0} ({1}, {2})' -f $osName, $cfg.OS.OSEdition, $langLabel) -ForegroundColor White
Write-Host ''
Write-Host '   Die interne Disk wird UNWIDERRUFLICH gelöscht und Windows wird' -ForegroundColor Red
Write-Host '   anschließend vollautomatisch neu installiert (ZTI, keine Rückfrage mehr).' -ForegroundColor Red
Write-HephDim '   Der USB-Stick ist nicht betroffen; Logs und Status bleiben auf dem Stick.'
Write-Host $barR -ForegroundColor Red
$confirm = Read-Host 'Zum Bestätigen LOESCHEN eintippen'
if ($confirm -ne 'LOESCHEN') {
    Write-HephWarn 'Abgebrochen - es wurde nichts gelöscht.'
    if (Confirm-Choice 'Gerät jetzt neu starten?') { Invoke-HephReboot }
    try { Stop-Transcript | Out-Null } catch { }
    exit 0
}

# ============================================================ Windows-Installation
Write-HephPhase -Title 'Windows-Installation (OSDCloud ZTI)' -EstimatedDuration '15-45 Minuten (ESD-Download + Anwenden; Fortschritt kommt von OSDCloud)'
# BUGFIX (Handoff 7.1): Das Flag step2_osinstall.started wird ERST JETZT geschrieben -
# unmittelbar vor Start-OSDCloud, nicht schon bei der Auswahl/vor der Bestätigung wie
# im alten START-ONBOARDING.cmd. Die step2-Auto-Erkennung der OOBE-Phase vergleicht
# das OS-Installationsdatum gegen den Zeitstempel dieses Flags.
$wipeStartedUtc = (Get-Date).ToUniversalTime()
Set-Step -StateDir $StateDir -Name 'step2_osinstall.started' -Detail ('{0}, Sprache {1}' -f $osName, $lang)
try {
    Start-OSDCloud -OSName $osName -OSEdition $cfg.OS.OSEdition -OSActivation $cfg.OS.OSActivation -OSLanguage $lang -ZTI
} catch {
    Write-HephErr ('Start-OSDCloud fehlgeschlagen: {0}' -f $_.Exception.Message)
    Write-HephResult -Success $false -Text 'Windows-Installation NICHT abgeschlossen.'
    Write-HephWarn 'Das Flag bleibt auf .started - der Schritt gilt als offen.'
    if (Confirm-Choice 'Gerät jetzt neu starten?') { Invoke-HephReboot -ExitCode 1 }
    try { Stop-Transcript | Out-Null } catch { }
    exit 1
}
if (Test-Path 'C:\Windows') {
    Write-HephResult -Success $true -Text 'OSDCloud-Installation abgeschlossen (C:\Windows vorhanden).'
} else {
    Write-HephResult -Success $false -Text 'OSDCloud ist durchgelaufen, aber C:\Windows fehlt - Staging wird trotzdem versucht.'
}

# ============================================================ Staging (Pfad-Kontrakt SPEC 3)
# Hinweis: Falls Start-OSDCloud in künftigen OSD-Versionen selbst neu startet,
# muss dieses Staging in eine SetupComplete-Phase verlagert werden - Verhalten
# auf echter Hardware verifizieren (offener Punkt).
Write-HephPhase -Title 'Staging der OOBE-Dateien nach C:\OSDCloud\HEPHAISTOS' -EstimatedDuration '1-3 Minuten'
$stagedRoot = 'C:\OSDCloud\HEPHAISTOS'
$stagingOk  = $true
try {
    $null = New-Item -Path $stagedRoot -ItemType Directory -Force
} catch {
    Write-HephErr ('Staging-Verzeichnis konnte nicht angelegt werden: {0}' -f $_.Exception.Message)
    $stagingOk = $false
}

if ($stagingOk) {
    # --- a) oobe.cmd aus dem Template erzeugen ({{RAWBASE}} ersetzen) ---
    try {
        $tplInfo = Get-HephaistosScript -RelPath 'oobe/oobe.cmd' -RawBase $Script:HephRawBase -FallbackRoots $Script:HephFallbackRoots
        $tpl = Get-Content -Path $tplInfo.Path -Raw
        $tpl.Replace('{{RAWBASE}}', $Script:HephRawBase) | Set-Content -Path (Join-Path $stagedRoot 'oobe.cmd') -Encoding ASCII
        Write-HephOk ('oobe.cmd gestaged (Quelle: {0}).' -f $tplInfo.Source)
    } catch {
        $stagingOk = $false
        Write-HephErr ('oobe.cmd konnte nicht gestaged werden: {0}' -f $_.Exception.Message)
        Write-HephWarn 'Notbehelf in der OOBE (Shift+F10), Onboarding-Script direkt laden:'
        Write-HephWarn ('  powershell -NoProfile -ExecutionPolicy Bypass -Command "iwr -UseBasicParsing {0}/oobe/Invoke-HephaistosOnboarding.ps1 -OutFile C:\heph-oobe.ps1; & C:\heph-oobe.ps1"' -f $Script:HephRawBase)
    }

    # --- b) Fallback-Spiegel: erst Stick -> C: kopieren, dann jede Datei
    #        best-effort frisch aus dem Repo aktualisieren ---
    $stagedFallback = Join-Path $stagedRoot 'Fallback'
    try {
        $null = New-Item -Path $stagedFallback -ItemType Directory -Force
        $stickFallback = $null
        if ($usbRoot) { $stickFallback = Join-Path $usbRoot '_HEPHAISTOS\Fallback' }
        if ($stickFallback -and (Test-Path $stickFallback)) {
            Write-HephDim ('Kopiere Fallback-Spiegel: {0} -> {1}' -f $stickFallback, $stagedFallback)
            Copy-Item -Path (Join-Path $stickFallback '*') -Destination $stagedFallback -Recurse -Force
        } else {
            Write-HephWarn 'Kein Fallback-Spiegel auf dem Stick (_HEPHAISTOS\Fallback) - Spiegel wird nur aus dem Repo befüllt.'
        }
        # Relative Dateiliste = Inhalt des kopierten Spiegels, ergänzt um die
        # bekannten Kern-Dateien (falls der Stick-Spiegel unvollständig/leer war).
        $coreFiles = @(
            'lib\Hephaistos.Common.ps1',
            'boot\Start-Hephaistos.ps1',
            'oobe\oobe.cmd',
            'oobe\Invoke-HephaistosOnboarding.ps1',
            'oobe\steps\Invoke-BiosConfig.ps1',
            'oobe\steps\Invoke-RemoveWinRE.ps1',
            'oobe\steps\Invoke-AutopilotHash.ps1',
            'abnahme\Test-HephaistosDevice.ps1',
            'abnahme\report\New-HephaistosHtmlReport.ps1',
            'abnahme\report\Convert-HtmlToPdf.ps1',
            'abnahme\report\Send-TeamsCard.ps1',
            'abnahme\report\Send-HephaistosReport.ps1',
            'send\Send-QueuedReports.ps1',
            'config\deploy.json',
            'config\report-checks.json'
        )
        $relFiles = @()
        foreach ($f in @(Get-ChildItem -Path $stagedFallback -Recurse -File -ErrorAction SilentlyContinue)) {
            $relFiles += $f.FullName.Substring($stagedFallback.Length).TrimStart('\')
        }
        foreach ($core in $coreFiles) {
            $known = $false
            foreach ($r in $relFiles) { if ($r -ieq $core) { $known = $true; break } }
            if (-not $known) { $relFiles += $core }
        }
        if (Test-HephInternet) {
            $mirrorRes = Update-HephFallbackMirror -MirrorRoot $stagedFallback -RelFiles $relFiles
            Write-HephOk ('Fallback-Spiegel: {0} Datei(en) frisch aus dem Repo aktualisiert.' -f $mirrorRes.Updated)
            if ($mirrorRes.Kept -gt 0) {
                Write-HephDim ('{0} Datei(en) nicht aktualisierbar - lokale Kopie bleibt bestehen.' -f $mirrorRes.Kept)
            }
        } else {
            Write-HephWarn 'Kein Internet - Fallback-Spiegel bleibt auf dem Stand der Stick-Kopie.'
        }
    } catch {
        $stagingOk = $false
        Write-HephErr ('Fallback-Spiegel fehlgeschlagen: {0}' -f $_.Exception.Message)
    }

    # --- c) install.json + technician.txt (Übergabe an die OOBE-Phase) ---
    try {
        $installInfo = [ordered]@{
            Serial            = $Serial
            Model             = $Model
            Technician        = $tech
            OSLanguage        = $lang
            GroupTagPreselect = $null
            WipeStartedUtc    = $wipeStartedUtc.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
            StagedUtc         = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
            Version           = $Script:HephVersion
            Source            = $Script:HephLibSource
        }
        $installInfo | ConvertTo-Json | Set-Content -Path (Join-Path $stagedRoot 'install.json') -Encoding UTF8
        Set-Content -Path (Join-Path $stagedRoot 'technician.txt') -Value $tech -Encoding UTF8
        Write-HephOk 'install.json + technician.txt geschrieben.'
    } catch {
        $stagingOk = $false
        Write-HephErr ('install.json/technician.txt fehlgeschlagen: {0}' -f $_.Exception.Message)
    }
}
Write-HephResult -Success $stagingOk -Text $(if ($stagingOk) { 'Staging abgeschlossen.' } else { 'Staging unvollständig - Hinweise oben beachten.' })

# ============================================================ Abschluss + Neustart
Write-Host ''
Write-HephOk 'HEPHAISTOS WinPE-Phase abgeschlossen.'
Write-Host ''
Write-HephInfo 'Nach dem Neustart: OOBE abwarten, dann Shift+F10 und starten:'
Write-HephInfo '    C:\OSDCloud\HEPHAISTOS\oobe.cmd'
Write-HephDim  'Der USB-Stick bleibt eingesteckt (Logs, Status und Tools liegen dort).'
Write-Host ''
Invoke-HephReboot -CountdownSeconds 10
