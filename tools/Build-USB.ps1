<#
.SYNOPSIS
    HEPHAISTOS - einmalige USB-Stick-Erstellung (OSDCloud) am Admin-PC.
.DESCRIPTION
    Baut den statischen HEPHAISTOS-Boot-Stick:
      1. OSD-Modul installieren, OSDCloud-Template + Workspace anlegen
      2. WinPE mit Dell-/WiFi-Treibern und der StartURL auf
         boot/Start-Hephaistos.ps1 (GitHub raw) bauen
      3. Stick erstellen (New-OSDCloudUSB)
      4. Repo-Spiegel als Offline-Fallback nach <Stick>:\_HEPHAISTOS\Fallback\
         kopieren, Stick-Root-Launcher (START-ABNAHME.cmd, SEND-REPORTS.cmd)
         aus den Templates erzeugen, Ordnerstruktur anlegen
      5. Abschluss-Checkliste ausgeben (Secrets-Blob + CCTK sind Handarbeit)
    Aufruf (PowerShell ALS ADMINISTRATOR, aus dem Repo-Checkout):
        powershell -ExecutionPolicy Bypass -File .\tools\Build-USB.ps1
    Nur Stick-Inhalte aktualisieren (ohne WinPE/USB neu zu bauen):
        ... -SkipUsbCreation
.NOTES
    HEPHAISTOS v1.0.1 - portiert/erweitert aus USB_ScriptTool Rev05 (Handoff §8).
    PowerShell 5.1. UTF-8 mit BOM.
#>
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$WorkspacePath = 'C:\OSDCloud',
    [switch]$SkipUsbCreation,
    [string]$UsbDriveLetter = ''
)

$ErrorActionPreference = 'Stop'
$Script:HephVersion = '1.0.1'

# --- Repo-Checkout + zentrale Config (RawBase kommt NUR aus deploy.json) ----
$RepoRoot   = Split-Path -Parent $PSScriptRoot
$DeployPath = Join-Path $RepoRoot 'config\deploy.json'
if (-not (Test-Path $DeployPath)) {
    Write-Host ("FEHLER: {0} nicht gefunden - Script aus dem Repo-Checkout starten." -f $DeployPath) -ForegroundColor Red
    exit 1
}
$Deploy  = Get-Content $DeployPath -Raw | ConvertFrom-Json
$RawBase = $Deploy.Repo.RawBase
$OSName  = $Deploy.OS.OSName

$bar = [string][char]0x2550 * 70
Write-Host $bar -ForegroundColor DarkCyan
Write-Host '   HEPHAISTOS - USB-Stick-Erstellung (OSDCloud)' -ForegroundColor White
Write-Host ('   Version {0}   |   Quelle: {1}' -f $Script:HephVersion, $RepoRoot) -ForegroundColor Gray
Write-Host ('   RawBase: {0}' -f $RawBase) -ForegroundColor DarkGray
Write-Host $bar -ForegroundColor DarkCyan
Write-Host ''
if ($RawBase -match 'CHANGE-ME-ORG') {
    Write-Host 'FEHLER: config\deploy.json enthaelt noch den Platzhalter CHANGE-ME-ORG.' -ForegroundColor Red
    exit 1
}

if (-not $SkipUsbCreation) {
    # --- Schritt 1: OSD-Modul -------------------------------------------------
    Write-Host '==> OSD-Modul pruefen/installieren' -ForegroundColor Cyan
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    if (-not (Get-Module -ListAvailable -Name OSD)) {
        Install-Module OSD -Force
    }
    Import-Module OSD -Force
    Write-Host ('OSD-Modul: Version {0}' -f (Get-Module OSD).Version) -ForegroundColor Green
    Write-Host ''

    # --- Schritt 2: 25H2-OSName gegen die OSD-Modulversion verifizieren (§4.2) -
    Write-Host ('==> Verifikation: "{0}" gegen Get-OSDCloudOperatingSystems' -f $OSName) -ForegroundColor Cyan
    try {
        $osList = @(Get-OSDCloudOperatingSystems)
        $names  = @($osList | ForEach-Object { $_.Name })
        # Neuere OSD-Kataloge listen VOLLNAMEN ("<OSName> <Sprache> <Aktivierung> <Build>",
        # z.B. "Windows 11 25H2 x64 de-de Retail 26200.8653"). Sprache/Aktivierung sind
        # separate Start-OSDCloud-Parameter -> Praefix-Matching: OK, wenn fuer JEDE
        # konfigurierte Sprache ein Eintrag mit OSName-Praefix + Sprache + Aktivierung existiert.
        $osdOk = ($names -contains $OSName)
        if (-not $osdOk) {
            $cfgLangs = @($Deploy.Languages.PSObject.Properties | ForEach-Object { [string]$_.Value.OSLanguage } | Where-Object { $_ })
            $act      = [string]$Deploy.OS.OSActivation
            if ($cfgLangs.Count -gt 0) {
                $osdOk = $true
                foreach ($lg in $cfgLangs) {
                    $hit = @($names | Where-Object { $_ -like ($OSName + '*') -and $_ -like ('*' + $lg + '*') -and $_ -like ('*' + $act + '*') })
                    if ($hit.Count -eq 0) { $osdOk = $false; break }
                }
            }
        }
        if ($osdOk) {
            Write-Host ('OK: "{0}" ist im OSD-Katalog abgedeckt (alle Sprachen + {1}).' -f $OSName, $Deploy.OS.OSActivation) -ForegroundColor Green
        } else {
            Write-Host ('WARNUNG: "{0}" ist NICHT in der OSD-Liste!' -f $OSName) -ForegroundColor Yellow
            $candidates = @($names | Where-Object { $_ -match '25H2' })
            if ($candidates.Count -gt 0) {
                Write-Host 'Gelistete 25H2-Kandidaten:' -ForegroundColor Yellow
                $candidates | ForEach-Object { Write-Host ('  - {0}' -f $_) -ForegroundColor Yellow }
            } else {
                Write-Host 'Keine 25H2-Eintraege gefunden - OSD-Modul aktualisieren oder OSName pruefen.' -ForegroundColor Yellow
            }
            Write-Host 'Bei Abweichung: exakten String in config\deploy.json eintragen und im CHANGELOG notieren.' -ForegroundColor Yellow
            if ((Read-Host 'Trotzdem fortfahren? [j/n]') -notmatch '^[jJyY]') { exit 1 }
        }
    } catch {
        Write-Host ('Verifikation nicht moeglich ({0}) - offener Punkt, auf Hardware pruefen.' -f $_.Exception.Message) -ForegroundColor Yellow
    }
    Write-Host ''

    # --- Schritt 3: Template + Workspace + WinPE + USB (Handoff §8) -----------
    Write-Host '==> OSDCloud-Template (einmalig, dauert einige Minuten)' -ForegroundColor Cyan
    New-OSDCloudTemplate
    Write-Host '==> OSDCloud-Workspace' -ForegroundColor Cyan
    New-OSDCloudWorkspace -WorkspacePath $WorkspacePath
    Write-Host '==> WinPE bauen (Dell- + WiFi-Treiber, StartURL -> boot/Start-Hephaistos.ps1)' -ForegroundColor Cyan
    Edit-OSDCloudWinPE -CloudDriver Dell,WiFi `
        -StartURL ("{0}/boot/Start-Hephaistos.ps1" -f $RawBase)
    Write-Host '==> USB-Stick erstellen (New-OSDCloudUSB) - Stick anstecken!' -ForegroundColor Cyan
    New-OSDCloudUSB
    Write-Host 'WinPE/USB-Erstellung abgeschlossen.' -ForegroundColor Green
    Write-Host ''
}

# --- Schritt 4: Stick-Inhalte synchronisieren --------------------------------
Write-Host '==> Stick-Inhalte synchronisieren (Offline-Fallback + Launcher)' -ForegroundColor Cyan
# Datenvolume von New-OSDCloudUSB heisst "OSDCloudUSB"; sonst Buchstabe abfragen.
$usbRoot = $null
if ($UsbDriveLetter) {
    $usbRoot = ('{0}:\' -f $UsbDriveLetter.TrimEnd(':','\'))
} else {
    try {
        $vol = Get-Volume -FileSystemLabel 'OSDCloudUSB' -ErrorAction Stop | Select-Object -First 1
        if ($vol -and $vol.DriveLetter) { $usbRoot = ('{0}:\' -f $vol.DriveLetter) }
    } catch { }
    if (-not $usbRoot) {
        $dl = (Read-Host 'Laufwerksbuchstabe des Stick-DATENVOLUMES (Label OSDCloudUSB), z.B. E').Trim()
        if (-not $dl) { Write-Host 'Abgebrochen - kein Laufwerk angegeben.' -ForegroundColor Red; exit 1 }
        $usbRoot = ('{0}:\' -f $dl.TrimEnd(':','\'))
    }
}
if (-not (Test-Path $usbRoot)) {
    Write-Host ("FEHLER: {0} nicht erreichbar." -f $usbRoot) -ForegroundColor Red
    exit 1
}
Write-Host ('Stick: {0}' -f $usbRoot) -ForegroundColor Gray

# Repo-Spiegel als Offline-Fallback (Pfad-Kontrakt: <Stick>:\_HEPHAISTOS\Fallback\)
$fallback = Join-Path $usbRoot '_HEPHAISTOS\Fallback'
foreach ($dir in @('boot','lib','oobe','abnahme','send','config','docs')) {
    $src = Join-Path $RepoRoot $dir
    if (-not (Test-Path $src)) { continue }
    $dst = Join-Path $fallback $dir
    if (Test-Path $dst) { Remove-Item -Path $dst -Recurse -Force }
    Copy-Item -Path $src -Destination $dst -Recurse -Force
    Write-Host ('  gespiegelt: {0} -> {1}' -f $dir, $dst) -ForegroundColor DarkGray
}

# Stick-Root-Launcher aus den Templates erzeugen ({{RAWBASE}} ersetzen)
$launchers = @(
    @{ Template = 'abnahme\START-ABNAHME.cmd'; Target = 'START-ABNAHME.cmd' },
    @{ Template = 'send\SEND-REPORTS.cmd';     Target = 'SEND-REPORTS.cmd' }
)
foreach ($l in $launchers) {
    $tpl = Join-Path $RepoRoot $l.Template
    if (-not (Test-Path $tpl)) {
        Write-Host ('WARNUNG: Template fehlt: {0}' -f $tpl) -ForegroundColor Yellow
        continue
    }
    $content = (Get-Content $tpl -Raw) -replace '\{\{RAWBASE\}\}', $RawBase
    $target  = Join-Path $usbRoot $l.Target
    # CMD-Dateien sind reines ASCII -> Encoding ASCII reicht und ist CP850-sicher.
    Set-Content -Path $target -Value $content -Encoding ASCII
    Write-Host ('  Launcher erzeugt: {0}' -f $target) -ForegroundColor DarkGray
}

# Ordnerstruktur (Secrets/Logs/HWID/Tools) anlegen
foreach ($dir in @('HEPHAISTOS-Secrets','Logs','HWID','_HEPHAISTOS\Tools')) {
    $p = Join-Path $usbRoot $dir
    if (-not (Test-Path $p)) { New-Item -Path $p -ItemType Directory -Force | Out-Null }
}
Write-Host 'Stick-Synchronisation abgeschlossen.' -ForegroundColor Green
Write-Host ''

# --- Schritt 5: Abschluss-Checkliste (Handoff §8) ----------------------------
Write-Host $bar -ForegroundColor DarkCyan
Write-Host ' NOCH VON HAND ZU ERLEDIGEN (pro Stick):' -ForegroundColor Cyan
Write-Host ('  [ ] Secrets-Blob erzeugen und kopieren nach {0}HEPHAISTOS-Secrets\' -f $usbRoot) -ForegroundColor Cyan
Write-Host '      -> tools\New-HephaistosSecrets.ps1 (Datei: hephaistos.secrets.enc.json)' -ForegroundColor DarkGray
Write-Host ('  [ ] CCTK-Paket kopieren nach {0}_HEPHAISTOS\Tools\' -f $usbRoot) -ForegroundColor Cyan
Write-Host '      -> vorentpacktes CCTK nach Tools\CCTK\ (applyconfig.bat) UND/ODER' -ForegroundColor DarkGray
Write-Host '         Pro16Plus_CCTK_x64.exe + vc_redist.x64.exe' -ForegroundColor DarkGray
Write-Host '         (zu gross/lizenzpflichtig fuers Repo)' -ForegroundColor DarkGray
Write-Host '  [ ] Repo public schalten - die StartURL muss unauthentifiziert abrufbar sein' -ForegroundColor Cyan
Write-Host $bar -ForegroundColor DarkCyan
