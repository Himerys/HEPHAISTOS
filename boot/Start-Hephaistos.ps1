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
    HEPHAISTOS v1.2.0 - portiert aus USB_ScriptTool Rev05 (START-ONBOARDING.cmd +
    SLG-Onboarding.ps1). PowerShell 5.1. UTF-8 mit BOM (Pflicht für PS 5.1 + Umlaute).
    Bugfix (Handoff 7.1): step2_osinstall.started wird ERST unmittelbar vor
    Start-OSDCloud geschrieben - nicht schon bei der Menüauswahl wie im alten
    START-ONBOARDING.cmd (dort bestätigte sich :Step2FullOS damit selbst).
#>

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

# --- HEPHAISTOS Lib-Bootstrap (identisch in allen Entry-Scripts) ---
$Script:HephVersion = '1.2.0'
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

# Zeitzonen-Korrektur (Praxisfund 08/2026): OSDCloud-WinPE steht standardmäßig
# auf Pacific Time - alle Zeitstempel (State-Flags, install.json) wären damit um
# Stunden verschoben. Die Flotte ist DE/FR/PL = einheitlich CET/CEST, daher
# best effort auf mitteleuropäische Zeit stellen.
if ($Script:IsWinPE) {
    try { & tzutil.exe /s 'W. Europe Standard Time' 2>$null | Out-Null } catch { }
}

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

function Add-HephSpecializeHook {
    # OOBE-Autostart (v1.2.0): hängt einen RunSynchronous-Befehl an den
    # Specialize-Pass des gestagten Unattend an. WICHTIG: OSDCloud staged unter
    # C:\Windows\Panther\Unattend.xml ein EIGENES Unattend (Treiber-Injection) -
    # das darf nicht überschrieben werden, deshalb echtes XML-Merge. Idempotent:
    # ein bereits vorhandener HEPHAISTOS-Eintrag wird nicht dupliziert.
    param(
        [Parameter(Mandatory = $true)][string]$UnattendPath,
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string]$Description
    )
    $ns    = 'urn:schemas-microsoft-com:unattend'
    $wcmNs = 'http://schemas.microsoft.com/WMIConfig/2002/State'
    if (Test-Path $UnattendPath) {
        [xml]$x = Get-Content -Path $UnattendPath -Raw
    } else {
        [xml]$x = ('<?xml version="1.0" encoding="utf-8"?><unattend xmlns="{0}"></unattend>' -f $ns)
    }
    $root = $x.DocumentElement
    $settings = $null
    foreach ($n in $root.ChildNodes) {
        if ($n.LocalName -eq 'settings' -and $n.GetAttribute('pass') -eq 'specialize') { $settings = $n; break }
    }
    if (-not $settings) {
        $settings = $x.CreateElement('settings', $ns)
        $settings.SetAttribute('pass', 'specialize')
        $null = $root.AppendChild($settings)
    }
    $comp = $null
    foreach ($n in $settings.ChildNodes) {
        if ($n.LocalName -eq 'component' -and $n.GetAttribute('name') -eq 'Microsoft-Windows-Deployment') { $comp = $n; break }
    }
    if (-not $comp) {
        $comp = $x.CreateElement('component', $ns)
        $comp.SetAttribute('name', 'Microsoft-Windows-Deployment')
        $comp.SetAttribute('processorArchitecture', 'amd64')
        $comp.SetAttribute('publicKeyToken', '31bf3856ad364e35')
        $comp.SetAttribute('language', 'neutral')
        $comp.SetAttribute('versionScope', 'nonSxS')
        $null = $settings.AppendChild($comp)
    }
    $runs = $null
    foreach ($n in $comp.ChildNodes) {
        if ($n.LocalName -eq 'RunSynchronous') { $runs = $n; break }
    }
    if (-not $runs) {
        $runs = $x.CreateElement('RunSynchronous', $ns)
        $null = $comp.AppendChild($runs)
    }
    $maxOrder = 0
    foreach ($n in $runs.ChildNodes) {
        if ($n.LocalName -ne 'RunSynchronousCommand') { continue }
        foreach ($c in $n.ChildNodes) {
            if ($c.LocalName -eq 'Path' -and $c.InnerText -match 'HEPHAISTOS') { return 'bereits vorhanden' }
            if ($c.LocalName -eq 'Order') {
                $o = 0
                if ([int]::TryParse($c.InnerText, [ref]$o) -and $o -gt $maxOrder) { $maxOrder = $o }
            }
        }
    }
    $cmdEl = $x.CreateElement('RunSynchronousCommand', $ns)
    $attr = $x.CreateAttribute('wcm', 'action', $wcmNs)
    $attr.Value = 'add'
    $null = $cmdEl.Attributes.Append($attr)
    foreach ($pair in @(@('Order', [string]($maxOrder + 1)), @('Description', $Description), @('Path', $Command))) {
        $el = $x.CreateElement($pair[0], $ns)
        $el.InnerText = $pair[1]
        $null = $cmdEl.AppendChild($el)
    }
    $null = $runs.AppendChild($cmdEl)
    $x.Save($UnattendPath)
    return ('Order {0}' -f ($maxOrder + 1))
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

# ============================================================ GroupTag-Vorauswahl (v1.1.0)
# Aus der Sprache abgeleitet (Languages[n].GroupTag in deploy.json) - in der
# OOBE-Phase genügt dann Enter. Die Auswahl bleibt dort weiterhin änderbar.
$groupTagPre = $null
if ($langProp.Value.PSObject.Properties['GroupTag']) { $groupTagPre = [string]$langProp.Value.GroupTag }
$cfgTags = @()
if ($cfg.GroupTags) { $cfgTags = @($cfg.GroupTags) }
if ($cfgTags.Count -gt 0) {
    Write-Host ''
    Write-HephInfo 'Autopilot Group Tag (Vorauswahl für die OOBE-Phase):'
    for ($i = 0; $i -lt $cfgTags.Count; $i++) {
        $mark = ''
        if ($groupTagPre -and ($cfgTags[$i] -ieq $groupTagPre)) { $mark = '   <- Vorschlag (aus der Sprache)' }
        Write-Host ("  [{0}] {1}{2}" -f ($i + 1), $cfgTags[$i], $mark)
    }
    $defTag = $cfgTags[0]
    if ($groupTagPre) { $defTag = $groupTagPre }
    $selTag = (Read-Host ('Group Tag [Enter = {0}]' -f $defTag)).Trim()
    $ti = 0
    if ($selTag -and [int]::TryParse($selTag, [ref]$ti) -and $ti -ge 1 -and $ti -le $cfgTags.Count) {
        $groupTagPre = $cfgTags[$ti - 1]
    } else {
        if ($selTag) { Write-HephWarn ('Ungültige Eingabe "{0}" - Vorschlag {1} übernommen (in der OOBE-Phase änderbar).' -f $selTag, $defTag) }
        $groupTagPre = $defTag
    }
    Write-HephOk ('Group Tag: {0}' -f $groupTagPre)
}

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

# ============================================================ Storage-Modus-Preflight (v1.1.0)
# Praxisfund: Das Werks-BIOS steht auf RAID/VMD, Ziel ist AHCI/NVMe. Dieser
# Wechsel darf NICHT nach der Windows-Installation passieren (der Boot-Treiber-
# Stack passt dann nicht mehr -> INACCESSIBLE_BOOT_DEVICE). Deshalb wird der
# Modus HIER, VOR Start-OSDCloud, geprüft und bei Bedarf umgestellt:
# Disk leeren -> Modus setzen -> Neustart. Die leere Disk bootet automatisch
# wieder vom Stick (kein F12 nötig); im zweiten Durchlauf passt der Modus.
# Der volle BIOS-Schritt (Passwort usw.) bleibt in der OOBE-Phase.
$storageTarget = 'Ahci'
if ($cfg.Bios -and $cfg.Bios.StorageMode) { $storageTarget = [string]$cfg.Bios.StorageMode }
if ($storageTarget -and ($storageTarget -notin @('Keep','None',''))) {
    $cctkExe = $null
    if ($usbRoot -and (Get-Command Get-HephBiosPackageDir -ErrorAction SilentlyContinue)) {
        $toolsDir = Join-Path $usbRoot '_HEPHAISTOS\Tools'
        $pkgInfo  = Get-HephBiosPackageDir -Model $Model -BiosConfig $(if ($cfg.Bios) { $cfg.Bios } else { $null }) -ToolsDir $toolsDir
        if (Test-Path $pkgInfo.Dir) {
            # x64-Binary bevorzugen: WinPE x64 hat kein WOW64 - eine X86-cctk.exe
            # würde dort gar nicht starten.
            $cctkExe = Get-ChildItem -Path $pkgInfo.Dir -Filter 'cctk.exe' -Recurse -ErrorAction SilentlyContinue |
                Sort-Object { if ($_.FullName -match '(?i)x86_64|amd64|x64') { 0 } else { 1 } } |
                Select-Object -First 1
        }
    }
    if (-not $cctkExe) {
        Write-HephDim 'Storage-Modus-Preflight übersprungen (cctk.exe nicht auf dem Stick gefunden).'
    } else {
        $cur  = $null
        $qOut = ''
        try {
            $qOut = (cmd /c ('"{0}" --embsataraid 2>&1' -f $cctkExe.FullName)) | Out-String
            if ($qOut -match '(?i)embsataraid\s*=\s*(\S+)') { $cur = $Matches[1] }
        } catch { }
        if (-not $cur) {
            Write-HephDim 'Storage-Modus nicht abfragbar (Option auf diesem Modell nicht vorhanden?) - Preflight übersprungen.'
            if ($qOut) { Write-HephDim ('  cctk-Ausgabe: {0}' -f (($qOut -split "`r?`n" | Where-Object { $_ } | Select-Object -First 2) -join ' | ')) }
        } elseif ($cur -ieq $storageTarget) {
            Write-HephDim ('Storage-Modus bereits {0} - kein Preflight nötig.' -f $cur)
        } else {
            Write-HephWarn ('Storage-Modus ist "{0}", Ziel ist "{1}" (deploy.json Bios.StorageMode).' -f $cur, $storageTarget)
            $secondRun = Test-Step -StateDir $StateDir -Name 'storage_mode.attempted'
            if ($secondRun -or (-not $usbRoot)) {
                if ($secondRun) {
                    Write-HephErr 'Der Modus wurde bereits einmal umgestellt, steht aber immer noch falsch'
                    Write-HephErr '(BIOS-Passwort gesetzt? Einstellung im BIOS gesperrt?).'
                } else {
                    # Ohne Stick überlebt das Schutz-Flag den Neustart nicht - der
                    # automatische Zyklus könnte endlos loopen. Nur interaktiv weiter.
                    Write-HephWarn 'Kein Stick gefunden - automatische Umstellung wird nicht riskiert (Schutz-Flag würde den Neustart nicht überleben).'
                }
                if (Confirm-Choice ('Trotzdem unter "{0}" installieren? Der OOBE-BIOS-Schritt wendet das CCTK-Paket dann nur nach Rückfrage an.' -f $cur)) {
                    # Merker für die OOBE-Phase: Storage-Modus NICHT mehr anfassen -
                    # ein Wechsel NACH der Installation macht Windows unbootbar.
                    try { Set-Step -StateDir $StateDir -Name 'storage_mode.keep' -Detail ('installiert unter {0}, Ziel war {1}' -f $cur, $storageTarget) } catch { }
                } else {
                    Invoke-HephReboot -ExitCode 1
                }
            } else {
                Write-HephInfo 'Ablauf: Disk leeren -> Modus umstellen -> automatischer Neustart vom Stick.'
                Set-Step -StateDir $StateDir -Name 'storage_mode.attempted' -Detail ('{0} -> {1}' -f $cur, $storageTarget)
                # NUR interne Bus-Typen (Thunderbolt/SD/USB bleiben außen vor) und
                # ALLE internen Disks leeren - sonst könnte eine zweite Disk mit
                # bootfähigem Rest-OS den automatischen Stick-Boot verhindern.
                $cands = @()
                try {
                    $cands = @(Get-Disk | Where-Object { ($_.BusType -in @('NVMe','SATA','SAS','RAID','ATA')) -and ($_.Size -gt 60GB) })
                } catch { }
                if ($cands.Count -ge 1) {
                    foreach ($d in $cands) {
                        try {
                            Write-HephInfo ('Leere Disk {0} ({1:N0} GB, {2}) ...' -f $d.Number, ($d.Size / 1GB), $d.BusType)
                            Clear-Disk -Number $d.Number -RemoveData -RemoveOEM -Confirm:$false -ErrorAction Stop
                        } catch {
                            Write-HephWarn ('Disk {0} leeren fehlgeschlagen ({1}) - nach dem Neustart ggf. F12 -> USB-Stick wählen.' -f $d.Number, $_.Exception.Message)
                        }
                    }
                } else {
                    Write-HephWarn 'Keine interne Disk eindeutig erkennbar - nach dem Neustart ggf. F12 -> USB-Stick wählen.'
                }
                cmd /c exit 0   # $LASTEXITCODE definiert zurücksetzen (Idiom wie im Hash-Schritt)
                $setFailed = $false
                $setOut    = ''
                try { $setOut = (cmd /c ('"{0}" --embsataraid={1} 2>&1' -f $cctkExe.FullName, $storageTarget.ToLower())) | Out-String } catch { $setFailed = $true; $setOut = $_.Exception.Message }
                if ((-not $setFailed) -and ($LASTEXITCODE -eq 0)) {
                    Write-HephOk ('Storage-Modus auf {0} gesetzt - Neustart, danach läuft die Installation normal weiter.' -f $storageTarget)
                    Invoke-HephReboot -CountdownSeconds 5
                } else {
                    Write-HephErr ('Umstellen fehlgeschlagen: {0}' -f $setOut.Trim())
                    Write-HephErr '(BIOS-Admin-Passwort bereits gesetzt? Dann den Modus manuell im BIOS umstellen.)'
                    if (Confirm-Choice ('Trotzdem unter "{0}" installieren? Der OOBE-BIOS-Schritt wendet das CCTK-Paket dann nur nach Rückfrage an.' -f $cur)) {
                        try { Set-Step -StateDir $StateDir -Name 'storage_mode.keep' -Detail ('installiert unter {0}, Umstellung fehlgeschlagen' -f $cur) } catch { }
                    } else {
                        Invoke-HephReboot -ExitCode 1
                    }
                }
            }
        }
    }
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
        # Kurzbefehl für die OOBE-Konsole (v1.1.0): "c:\o" statt langem Pfad.
        try { $tpl.Replace('{{RAWBASE}}', $Script:HephRawBase) | Set-Content -Path 'C:\o.cmd' -Encoding ASCII } catch { }

        # --- OOBE-Autostart (v1.2.0, deploy.json Oobe.AutoLaunch): oobe.cmd wird
        #     über den Specialize-Pass des Windows-Setups gestartet - Shift+F10
        #     entfällt. Merge in das von OSDCloud gestagte Unattend (Treiber!).
        if ($cfg.Oobe -and $cfg.Oobe.AutoLaunch -eq $true) {
            try {
                $hookRes = Add-HephSpecializeHook -UnattendPath 'C:\Windows\Panther\Unattend.xml' `
                    -Command 'cmd.exe /c C:\OSDCloud\HEPHAISTOS\oobe.cmd /specialize' `
                    -Description 'HEPHAISTOS OOBE-Onboarding (BIOS + Autopilot-Hash)'
                Write-HephOk ('OOBE-Autostart eingerichtet (Specialize-Pass, {0}) - Shift+F10 wird nur noch als Fallback gebraucht.' -f $hookRes)
            } catch {
                Write-HephWarn ('OOBE-Autostart konnte nicht eingerichtet werden ({0}) - Fallback: Shift+F10, dann c:\o.' -f $_.Exception.Message)
            }
        } else {
            Write-HephDim 'OOBE-Autostart deaktiviert (deploy.json Oobe.AutoLaunch) - Start per Shift+F10, dann c:\o.'
        }
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
            'abnahme\Invoke-AutoAbnahme.ps1',
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
            GroupTagPreselect = $groupTagPre
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
Write-HephInfo '    C:\OSDCloud\HEPHAISTOS\oobe.cmd     (Kurzform: c:\o)'
Write-HephDim  'Der USB-Stick bleibt eingesteckt (Logs, Status und Tools liegen dort).'
Write-Host ''
Invoke-HephReboot -CountdownSeconds 10
