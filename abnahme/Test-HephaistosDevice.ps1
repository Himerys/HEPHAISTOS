<#
.SYNOPSIS
    HEPHAISTOS Abnahme-Pruefscript nach Autopilot-Provisioning (SLG Notebook-Onboarding).
.DESCRIPTION
    Fuehrt alle scriptbaren Abnahme-Tests aus und gibt pro Test PASSED/FAILED aus.
    Orchestriert zusaetzlich (frueher Menuepunkt 4 der SLG-Onboarding.ps1):
    BitLocker-Escrow VOR dem Testlauf, Text-/JSON-Report in den Geraeteordner,
    HTML/PDF-Report, Teams-Karte und Mail-/Queue-Logik.
    Aufruf normalerweise ueber <Stick>:\START-ABNAHME.cmd (holt dieses Script
    frisch aus dem Repo). Direktaufruf (PowerShell ALS ADMINISTRATOR):
        powershell -ExecutionPolicy Bypass -File Test-HephaistosDevice.ps1
.PARAMETER SkipWindowsUpdateScan
    Ueberspringt den Windows-Update-Scan (dauert 1-3 Minuten).
.PARAMETER MinBuild
    Mindest-Buildnummer des installierten Windows. Default 0 = Wert aus
    config/deploy.json (dort 26200 = 25H2) - eine Quelle, nicht zwei.
    Faengt veraltete Installations-Images ab.
.PARAMETER NoReport
    Nur Konsolen-/Text-/JSON-Ausgabe - HTML/PDF/Teams/Mail entfallen.
.NOTES
    HEPHAISTOS v1.3.1 - portiert aus USB_ScriptTool Rev05
    (Test-SLGDeviceOnboarding.ps1 Rev04 + Invoke-Step4Compliance aus
    SLG-Onboarding.ps1). PowerShell 5.1. UTF-8 mit BOM.
    Dreistufiges Ergebnis - unkritische Checks (Windows Update, Pending
    Reboot, Treiberfehler, Zeitzone) ergeben bei Fehlschlag WARN (gelb)
    statt FAILED; WARN blockiert Exit-Code und Abnahme nicht.
    Summary: SUCCESS / SUCCESS_WITH_WARNINGS / FAILED. JSON-Schema 2
    (Summary.Status, Summary.Warned).
    Exit-Code: 0 = alle Pflichttests PASSED, 1 = mindestens ein Test FAILED.
    NEU (HEPHAISTOS):
      - Jeder Check hat eine stabile ID; config/report-checks.json kann
        Checks einzeln deaktivieren -> Ergebnis SKIPPED "per Config
        deaktiviert" (Check wird NICHT ausgefuehrt, zaehlt nicht in
        Exit-Code/Summary).
      - Netskope-Sonderfall: lokale Admin-Session (LocalAdminAccount aus
        report-checks.json, Default intuneadm) hat kein Steering-Profil ->
        nur Dienststatus-Pruefung statt nsdiag.
      - MinBuild kommt aus config/deploy.json; Reports landen direkt im
        Geraeteordner auf dem Stick; Techniker-Name als Freitext mit
        Default aus der WinPE-Phase (technician.txt).
#>
[CmdletBinding()]
param(
    [switch]$SkipWindowsUpdateScan,
    [int]$MinBuild = 0,
    [switch]$NoReport,
    # v1.2.0: für die Auto-Abnahme (geplante Aufgabe, SYSTEM, unsichtbar):
    # keinerlei Eingaben - Techniker-Default wird übernommen, Secrets (Teams/
    # Mail) werden übersprungen. Reports entstehen wie gewohnt auf dem Stick.
    [switch]$NonInteractive
)

# --- HEPHAISTOS Lib-Bootstrap (identisch in allen Entry-Scripts) ---
$Script:HephVersion = '1.3.1'
$Script:HephRawBase = 'https://raw.githubusercontent.com/Himerys/HEPHAISTOS/main'
# FallbackRoots fuer die Abnahme: Stick-Fallback zuerst, dann gestagte Kopie auf C:.
# Minimal-Suche nach dem Stick VOR dem Lib-Load (Find-HephaistosUsb liegt erst in der Lib).
$Script:HephFallbackRoots = @()
try {
    foreach ($drv in [IO.DriveInfo]::GetDrives()) {
        if ($drv.IsReady -and (Test-Path (Join-Path $drv.RootDirectory.FullName '_HEPHAISTOS'))) {
            $Script:HephFallbackRoots += (Join-Path $drv.RootDirectory.FullName '_HEPHAISTOS\Fallback')
            break
        }
    }
} catch { }
$Script:HephFallbackRoots += 'C:\OSDCloud\HEPHAISTOS\Fallback'
# 1) TLS12 aktivieren, 2) versuche Download lib/Hephaistos.Common.ps1 -> TEMP,
# 3) sonst erste existierende Fallback-Kopie, 4) Dot-Source; 5) Fehler -> rote
# Meldung + exit 1. Quelle in $Script:HephLibSource merken (fuers Banner).
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 } catch { }
$libPath = $null
$libTemp = Join-Path $env:TEMP 'HEPHAISTOS\lib\Hephaistos.Common.ps1'
try {
    $null = New-Item -Path (Split-Path -Parent $libTemp) -ItemType Directory -Force
    Invoke-WebRequest -UseBasicParsing -Uri ('{0}/lib/Hephaistos.Common.ps1' -f $Script:HephRawBase) -OutFile $libTemp -ErrorAction Stop
    $libPath = $libTemp
    $Script:HephLibSource = ('GitHub: {0}/lib/Hephaistos.Common.ps1' -f $Script:HephRawBase)
} catch {
    foreach ($root in $Script:HephFallbackRoots) {
        $cand = Join-Path $root 'lib\Hephaistos.Common.ps1'
        if (Test-Path $cand) {
            $mtime = (Get-Item $cand).LastWriteTime
            Write-Host ('OFFLINE-FALLBACK: nutze lokale Lib-Kopie {0}, Stand {1:yyyy-MM-dd HH:mm}' -f $cand, $mtime) -ForegroundColor Yellow
            $libPath = $cand
            $Script:HephLibSource = ('lokale Kopie: {0}' -f $cand)
            break
        }
    }
}
if (-not $libPath) {
    Write-Host 'FEHLER: lib/Hephaistos.Common.ps1 weder online noch als lokale Kopie gefunden - Abbruch.' -ForegroundColor Red
    exit 1
}
. $libPath
# --- Ende Lib-Bootstrap ---

# ============================================================ Vorbereitung
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'FEHLER: Script muss in einer Administrator-PowerShell laufen.' -ForegroundColor Red
    exit 1
}

# NonInteractive (v1.2.0): niemals auf einen Prompt laufen - bei leerem
# Service Tag klarer Abbruch statt unsichtbar haengendem Read-Host (SYSTEM).
# Get-Command-Guard: eine veraltete Lib-Kopie ohne -NoPrompt darf nicht crashen.
if ($NonInteractive -and (Get-Command Get-HephaistosDeviceInfo).Parameters.ContainsKey('NoPrompt')) {
    $dev = Get-HephaistosDeviceInfo -NoPrompt
} else {
    $dev = Get-HephaistosDeviceInfo
}
if ($NonInteractive -and -not $dev.Serial) {
    Write-Host 'FEHLER: Service Tag nicht lesbar - nicht-interaktiver Lauf wird abgebrochen.' -ForegroundColor Red
    exit 1
}
$Serial = $dev.Serial
$Model  = $dev.Model
$IsOobe = ($env:USERNAME -ieq 'defaultuser0')

Write-HephBanner -Title 'HEPHAISTOS - Abnahme-Pruefung' -Version $HephaistosVersion -Source $Script:HephLibSource `
    -Model $Model -Serial $Serial -Env $(if ($IsOobe) { 'OOBE' } else { 'Windows' })

# Port aus Invoke-Step4Compliance: In der OOBE laeuft die Abnahme nicht.
if ($IsOobe) {
    Write-HephWarn 'Die Abnahme-Prüfung läuft erst NACH dem Autopilot-Provisioning'
    Write-HephWarn 'im fertig eingerichteten Windows (Admin-PowerShell).'
    exit 1
}

# ============================================================ Konfiguration
# deploy.json: MinBuild (eine Quelle) + Report-Optionen. Laesst sich die Config
# nicht laden, laufen die Checks mit Notfall-Defaults weiter (gelbe Warnung).
$deployData = $null
try {
    $deployRes  = Get-HephaistosConfig -RelPath 'config/deploy.json' -RawBase $Script:HephRawBase -FallbackRoots $Script:HephFallbackRoots
    $deployData = $deployRes.Data
    Write-HephDim ('deploy.json geladen (Quelle: {0}, ConfigVersion {1})' -f $deployRes.Source, $deployData.ConfigVersion)
} catch {
    Write-HephWarn ('deploy.json nicht ladbar ({0}) - Notfall-Defaults werden verwendet.' -f $_.Exception.Message)
}

# report-checks.json: Per-Check-Konfiguration (§4.4) + LocalAdminAccount (§4.3).
# Fehlt die Datei, sind ALLE Checks aktiv (Default an).
$script:ChecksCfg = $null
try {
    $checksRes = Get-HephaistosConfig -RelPath 'config/report-checks.json' -RawBase $Script:HephRawBase -FallbackRoots $Script:HephFallbackRoots
    $script:ChecksCfg = $checksRes.Data
    Write-HephDim ('report-checks.json geladen (Quelle: {0})' -f $checksRes.Source)
} catch {
    Write-HephWarn 'report-checks.json nicht ladbar - alle Checks aktiv (Default).'
}

# MinBuild: Parameter > 0 uebersteuert; sonst config/deploy.json; Notfall 26200.
if ($MinBuild -le 0) {
    if ($deployData -and $deployData.MinBuild) {
        $MinBuild = [int]$deployData.MinBuild
    } else {
        $MinBuild = 26200
        Write-HephWarn 'MinBuild-Notfall-Default 26200 aktiv (deploy.json fehlt).'
    }
}

# Teams: PDF base64 im Payload + "Report öffnen"-Button ({{FILEURL}}) - war
# frueher Script-Konstante $Config.TeamsAttachPdf, jetzt deploy.Report.TeamsAttachPdf.
$attachPdf = $true
if ($deployData -and $deployData.Report -and ($null -ne $deployData.Report.TeamsAttachPdf)) {
    $attachPdf = [bool]$deployData.Report.TeamsAttachPdf
}

# ============================================================ Pfade + Status
$UsbRoot  = Find-HephaistosUsb
$init     = Initialize-HephaistosDevice -UsbRoot $UsbRoot -Serial $Serial
$DevDir   = $init.DevDir
$StateDir = $init.StateDir

# v1.3.0 (Review-Auflage): liegengebliebene Split-Key-Handoff-Artefakte
# entsorgen (Specialize nie gelaufen / abgebrochen). Zu diesem Zeitpunkt ist
# das Gerät provisioniert - ein Handoff hat hier nichts mehr verloren.
try {
    if (Get-Command Remove-HephSecureFile -ErrorAction SilentlyContinue) {
        Remove-HephSecureFile -Path 'C:\OSDCloud\HEPHAISTOS\handoff.enc.json'
        Remove-HephSecureFile -Path 'C:\OSDCloud\HEPHAISTOS\handoff.enc.json.tmp'
        if ($UsbRoot -and $Serial) {
            Remove-HephSecureFile -Path (Join-Path $UsbRoot ("Logs\{0}\state\handoff.key.json" -f $Serial))
            Remove-HephSecureFile -Path (Join-Path $UsbRoot ("Logs\{0}\state\handoff.key.json.tmp" -f $Serial))
        }
    }
} catch { }

# Sitzung protokollieren (best effort)
try {
    Start-Transcript -Path (Join-Path $DevDir ('Abnahme_{0}.log' -f (Get-Date -Format 'yyyy-MM-dd_HHmm'))) -Append | Out-Null
} catch { }

# ============================================================ Techniker + Benutzer
# Techniker-Name: Freitext-Pflichtfeld (§4.1). Der in WinPE erfasste Name wurde
# in den Geraeteordner (bzw. nach C:\OSDCloud\HEPHAISTOS) geschrieben und wird
# hier als Default angeboten (Enter = uebernehmen).
$techDefault = $null
foreach ($cand in @((Join-Path $DevDir 'technician.txt'), 'C:\OSDCloud\HEPHAISTOS\technician.txt')) {
    if (Test-Path $cand) {
        try {
            $t = (Get-Content $cand -Raw -ErrorAction Stop).Trim()
            if ($t) { $techDefault = $t; break }
        } catch { }
    }
}
if ($NonInteractive) {
    $technician = 'Automatisch (Auto-Abnahme)'
    if ($techDefault) { $technician = $techDefault }
    Write-HephDim ('NonInteractive: Techniker-Name uebernommen: {0}' -f $technician)
} elseif ($techDefault) { $technician = Get-TechnicianName -Default $techDefault }
else                    { $technician = Get-TechnicianName }

# Primaerer Benutzer = interaktiv angemeldeter Mitarbeiter (Konsolen-Session)
$primaryUser = $null
try { $primaryUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).UserName } catch { }
if (-not $primaryUser) { $primaryUser = 'unbekannt (keine interaktive Anmeldung)' }

# ============================================================ BitLocker-Escrow
function Invoke-BitLockerEscrow {
    # Sichert die Recovery-Keys aktiv nach Entra ID (BackupToAAD). Läuft VOR dem
    # Abnahme-Test, damit dessen Event-845-Prüfung das Ergebnis sieht.
    # Später geplant als Intune-Remediation - dies ist die Übergangslösung.
    try {
        $mp  = $env:SystemDrive
        $blv = Get-BitLockerVolume -MountPoint $mp -ErrorAction Stop
        if ($blv.VolumeStatus -eq 'FullyDecrypted') {
            Write-Host 'BitLocker: Laufwerk nicht verschlüsselt - Escrow übersprungen.' -ForegroundColor Yellow
            return
        }
        $rp = @($blv.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' })
        if (-not $rp) {
            Write-Host 'BitLocker: Kein Recovery-Password-Protector - wird angelegt ...' -ForegroundColor DarkGray
            Add-BitLockerKeyProtector -MountPoint $mp -RecoveryPasswordProtector | Out-Null
            $rp = @((Get-BitLockerVolume -MountPoint $mp).KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' })
        }
        foreach ($p in $rp) {
            BackupToAAD-BitLockerKeyProtector -MountPoint $mp -KeyProtectorId $p.KeyProtectorId | Out-Null
        }
        Write-Host ('BitLocker: {0} Recovery-Key(s) nach Entra ID gesichert.' -f $rp.Count) -ForegroundColor Green
    } catch {
        Write-Host ('BitLocker-Escrow fehlgeschlagen: {0}' -f $_.Exception.Message) -ForegroundColor Yellow
        Write-Host 'Hinweis: Der Abnahme-Test prüft Event 845 - Ergebnis dort beachten.' -ForegroundColor DarkGray
    }
}

# ============================================================ Check-Gerueste
$results = New-Object System.Collections.Generic.List[object]
$num = 0

function Add-Result {
    param(
        [string]$Name,
        [ValidateSet('PASSED','FAILED','WARN','INFO','SKIPPED')][string]$Status,
        [string]$Detail = ''
    )
    $script:num++
    $script:results.Add([pscustomobject]@{ Nr = $script:num; Name = $Name; Status = $Status; Detail = $Detail })
}

function Test-HephCheckEnabled {
    # §4.4: fehlender Key in Checks = aktiviert (Default an); nur ein explizites
    # false in config/report-checks.json deaktiviert den Check.
    param([string]$Id)
    if (-not $Id) { return $true }
    if (-not $script:ChecksCfg -or -not $script:ChecksCfg.Checks) { return $true }
    $prop = $script:ChecksCfg.Checks.PSObject.Properties[$Id]
    if ($null -eq $prop) { return $true }
    return (-not ($prop.Value -eq $false))
}

function Invoke-Check {
    # Fuehrt $Test aus; erwartet Rueckgabe: @{ Ok = $bool; Detail = 'text' }
    # -Warning: Fehlschlag ergibt WARN (gelb) statt FAILED - blockiert die
    # Abnahme nicht und geht NICHT in den Exit-Code ein (unkritische Punkte).
    # -Id: stabile Check-ID fuer config/report-checks.json (§4.4). Deaktivierte
    # Checks erscheinen als SKIPPED "per Config deaktiviert", der Testblock
    # wird NICHT ausgefuehrt; SKIPPED zaehlt weder in Exit-Code noch Summary.
    param([string]$Id, [string]$Name, [scriptblock]$Test, [switch]$Warning)
    if (-not (Test-HephCheckEnabled -Id $Id)) {
        Add-Result -Name $Name -Status 'SKIPPED' -Detail 'per Config deaktiviert'
        return
    }
    $failStatus = if ($Warning) { 'WARN' } else { 'FAILED' }
    try {
        $r = & $Test
        Add-Result -Name $Name -Status $(if ($r.Ok) { 'PASSED' } else { $failStatus }) -Detail $r.Detail
    } catch {
        Add-Result -Name $Name -Status $failStatus -Detail $_.Exception.Message
    }
}

function Test-HephLocalAdminSession {
    # §4.3: Pure Entscheidungsfunktion fuer den Netskope-Sonderfall - trocken
    # testbar (SPEC §9): Konsolen-User "<HOSTNAME>\<LocalAdminAccount>"
    # (z.B. SLGDE-XXXXXXX\intuneadm) => $true (nur Dienststatus pruefen),
    # jeder andere Wert => $false (nsdiag). $null/leer => $false.
    param([string]$ConsoleUser, [string]$ComputerName, [string]$LocalAdminAccount)
    if ([string]::IsNullOrEmpty($ConsoleUser)) { return $false }
    return ($ConsoleUser -ieq ('{0}\{1}' -f $ComputerName, $LocalAdminAccount))
}

# OS-Installationsdatum (Unix-Epoch aus der Registry) - wird von mehreren Tests genutzt
$script:OsInstallDate = $null
try {
    $epoch = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop).InstallDate
    $script:OsInstallDate = ([datetime]::new(1970,1,1,0,0,0,[DateTimeKind]::Utc)).AddSeconds($epoch)
} catch { }

# ============================================================ Escrow vor den Tests
Write-HephPhase -Title 'BitLocker-Escrow nach Entra ID' -EstimatedDuration '5-20 Sekunden'
Invoke-BitLockerEscrow

# ============================================================ Tests
Write-HephPhase -Title 'Abnahme-Checks' -EstimatedDuration $(if ($SkipWindowsUpdateScan) { '30-60 Sekunden' } else { '2-4 Minuten (inkl. Windows-Update-Scan)' })

# --- Hostname-Konvention ------------------------------------------------------
# Entkopplung (SPEC §6): $script:CountryCode wird VOR den Checks berechnet,
# damit 'timezone-country' auch bei per Config deaktivierter Hostname-Pruefung
# funktioniert.
$script:CountryCode = $null
if ($env:COMPUTERNAME -match '^SLG(DE|FR|PL|TEST)-') { $script:CountryCode = $Matches[1] }
Invoke-Check -Id 'hostname-convention' -Name 'Hostname-Konvention (SLGxx-XXXXXX)' -Test {
    $h  = $env:COMPUTERNAME
    $ok = $h -match '^SLG(DE|FR|PL|TEST)-'
    @{ Ok = $ok; Detail = $h }
}

# --- Join-Status (dsregcmd) ---------------------------------------------------
$dsreg = (& "$env:windir\System32\dsregcmd.exe" /status) 2>$null
Invoke-Check -Id 'hybrid-join-azuread' -Name 'Hybrid Join: AzureAdJoined' -Test {
    if (-not $dsreg) { return @{ Ok = $false; Detail = 'dsregcmd lieferte keine Ausgabe' } }
    $ok = @($dsreg -match '^\s*AzureAdJoined\s*:\s*YES').Count -gt 0
    @{ Ok = $ok; Detail = if ($ok) { '' } else { 'dsregcmd meldet AzureAdJoined != YES' } }
}
Invoke-Check -Id 'hybrid-join-domain' -Name 'Hybrid Join: DomainJoined' -Test {
    if (-not $dsreg) { return @{ Ok = $false; Detail = 'dsregcmd lieferte keine Ausgabe' } }
    $ok = @($dsreg -match '^\s*DomainJoined\s*:\s*YES').Count -gt 0
    @{ Ok = $ok; Detail = if ($ok) { '' } else { 'dsregcmd meldet DomainJoined != YES' } }
}

# --- Entra SSO: Primary Refresh Token -----------------------------------------
# WICHTIG: AzureAdPrt gilt nur fuer den Benutzer, unter dem dsregcmd laeuft.
# Elevated der Techniker in der Mitarbeiter-Session, zeigt dsregcmd den PRT
# des TECHNIKERS - dann ist der Test nicht bewertbar und wird zu INFO.
# Der INFO-Zweig laeuft ausserhalb von Invoke-Check, deshalb greift das
# Config-Gate (§4.4) hier zusaetzlich ueber Test-HephCheckEnabled.
$consoleUser = $null
try { $consoleUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).UserName } catch { }
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$prtYes = ($dsreg -and (@($dsreg -match '^\s*AzureAdPrt\s*:\s*YES').Count -gt 0))
# LocalAdminAccount einmal zentral auflösen - genutzt von entra-prt UND netskope-tunnel.
$script:LocalAdminName = 'intuneadm'   # Default, wenn report-checks.json fehlt
if ($script:ChecksCfg -and $script:ChecksCfg.LocalAdminAccount) { $script:LocalAdminName = $script:ChecksCfg.LocalAdminAccount }
$script:IsLocalAdminSession = Test-HephLocalAdminSession -ConsoleUser $consoleUser -ComputerName $env:COMPUTERNAME -LocalAdminAccount $script:LocalAdminName
if (-not (Test-HephCheckEnabled -Id 'entra-prt')) {
    Add-Result -Name 'Entra SSO: Primary Refresh Token (AzureAdPrt)' -Status 'SKIPPED' -Detail 'per Config deaktiviert'
} elseif ($script:IsLocalAdminSession) {
    # Lokale Admin-Session (<HOST>\<LocalAdminAccount>): Das lokale Konto hat
    # konstruktionsbedingt KEINEN Entra-PRT - der Test wäre hier immer falsch-rot.
    # Bewusst SKIPPED (sichtbar), SSO wird als Mitarbeiter separat geprüft.
    Add-Result -Name 'Entra SSO: Primary Refresh Token (AzureAdPrt)' -Status 'SKIPPED' -Detail (
        'Lokale Admin-Session ({0}) - lokales Konto hat keinen Entra-PRT; SSO als Mitarbeiter separat pruefen (dsregcmd /status).' -f $script:LocalAdminName)
} elseif ($consoleUser -and ($consoleUser -ieq $currentUser)) {
    Invoke-Check -Id 'entra-prt' -Name 'Entra SSO: Primary Refresh Token (AzureAdPrt)' -Test {
        @{ Ok = $prtYes; Detail = if ($prtYes) { '' } else { 'AzureAdPrt != YES - SSO/Conditional Access werden fehlschlagen. Geraet sperren/entsperren und erneut pruefen.' } }
    }
} else {
    Add-Result -Name 'Entra SSO: Primary Refresh Token (AzureAdPrt)' -Status 'INFO' -Detail (
        'Nicht bewertbar: Script laeuft als "{0}", angemeldet ist "{1}". Manuell pruefen: als Mitarbeiter OHNE Adminrechte "dsregcmd /status" ausfuehren -> SSO State -> AzureAdPrt muss YES sein.' -f $currentUser, $(if ($consoleUser) { $consoleUser } else { 'unbekannt' }))
}

# --- TPM 2.0 -------------------------------------------------------------------
Invoke-Check -Id 'tpm-20' -Name 'TPM 2.0 vorhanden und bereit' -Test {
    $tpm = Get-Tpm
    $spec = ''
    try {
        $spec = (Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftTpm' -ClassName Win32_Tpm -ErrorAction Stop).SpecVersion
    } catch { }
    $is20 = ($spec -match '^\s*2\.0')
    @{ Ok = ($tpm.TpmPresent -and $tpm.TpmReady -and $is20)
       Detail = "Present=$($tpm.TpmPresent) Ready=$($tpm.TpmReady) SpecVersion=$spec" }
}

# --- Secure Boot ---------------------------------------------------------------
Invoke-Check -Id 'secure-boot' -Name 'Secure Boot aktiv' -Test {
    try {
        @{ Ok = [bool](Confirm-SecureBootUEFI); Detail = '' }
    } catch [System.PlatformNotSupportedException] {
        @{ Ok = $false; Detail = 'System bootet NICHT im UEFI-Modus (Legacy/CSM) - BIOS-Konfiguration pruefen.' }
    }
}

# --- BIOS-Admin-Passwort (Regressionstest ValSetupPwd-Bug) ---------------------
Invoke-Check -Id 'bios-admin-password' -Name 'BIOS: Admin-Passwort gesetzt' -Test {
    # Native Dell-WMI-Schnittstelle, kein Dell Command | Monitor noetig.
    $pw = Get-CimInstance -Namespace 'root\dcim\sysman\wmisecurity' -ClassName PasswordObject -ErrorAction Stop |
          Where-Object NameId -eq 'Admin'
    if (-not $pw) { return @{ Ok = $false; Detail = 'PasswordObject "Admin" nicht gefunden (kein Dell / BIOS zu alt?)' } }
    @{ Ok = ($pw.IsPasswordSet -eq 1)
       Detail = if ($pw.IsPasswordSet -eq 1) { '' } else { 'KEIN BIOS-Admin-Passwort gesetzt! CCTK-Paket pruefen (SetupPwd vs. ValSetupPwd).' } }
}

# --- BitLocker Status + Protector ----------------------------------------------
$script:blv = $null
Invoke-Check -Id 'bitlocker-protection' -Name 'BitLocker: Schutz aktiv (C:)' -Test {
    $script:blv = Get-BitLockerVolume -MountPoint 'C:'
    $ok = ($script:blv.ProtectionStatus -eq 'On' -and $script:blv.VolumeStatus -in @('FullyEncrypted','EncryptionInProgress'))
    @{ Ok = $ok; Detail = "Protection=$($script:blv.ProtectionStatus) Status=$($script:blv.VolumeStatus) ($([int]$script:blv.EncryptionPercentage)%) Methode=$($script:blv.EncryptionMethod)" }
}
Invoke-Check -Id 'bitlocker-recovery-protector' -Name 'BitLocker: RecoveryPassword-Protector vorhanden' -Test {
    # Entkopplung (SPEC §6): holt sich das Volume selbst, falls der vorherige
    # BitLocker-Check per Config deaktiviert war oder fehlgeschlagen ist.
    $vol = $script:blv
    if (-not $vol) {
        try { $vol = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop } catch { $vol = $null }
    }
    if (-not $vol) { return @{ Ok = $false; Detail = 'Nicht pruefbar - BitLocker-Volume C: nicht abfragbar.' } }
    $rp = @($vol.KeyProtector | Where-Object KeyProtectorType -eq 'RecoveryPassword')
    @{ Ok = ($rp.Count -ge 1); Detail = "Anzahl RecoveryPassword-Protectoren: $($rp.Count)" }
}

# --- BitLocker Escrow (Event 845) ----------------------------------------------
Invoke-Check -Id 'bitlocker-escrow-845' -Name 'BitLocker: Key-Escrow nach Entra ID (Event 845)' -Test {
    $ev = Get-WinEvent -FilterHashtable @{
            LogName = 'Microsoft-Windows-BitLocker/BitLocker Management'; Id = 845
          } -MaxEvents 1 -ErrorAction SilentlyContinue
    if ($ev) {
        # Schutz gegen Altbestand: Event muss von DIESER Installation stammen.
        if ($script:OsInstallDate -and $ev.TimeCreated.ToUniversalTime() -lt $script:OsInstallDate) {
            return @{ Ok = $false; Detail = ('Event 845 ist AELTER als die OS-Installation ({0:yyyy-MM-dd HH:mm} < {1:yyyy-MM-dd HH:mm}Z) - Escrow dieser Installation fehlt.' -f $ev.TimeCreated, $script:OsInstallDate) }
        }
        return @{ Ok = $true; Detail = ('Letztes Event: {0:yyyy-MM-dd HH:mm}' -f $ev.TimeCreated) }
    }
    $ev846 = Get-WinEvent -FilterHashtable @{
                LogName = 'Microsoft-Windows-BitLocker/BitLocker Management'; Id = 846
             } -MaxEvents 1 -ErrorAction SilentlyContinue
    $d = 'Kein Event 845 gefunden.'
    if ($ev846) { $d += (' Event 846 (Fehler) vorhanden: {0:yyyy-MM-dd HH:mm} - siehe Troubleshooting (Netskope).' -f $ev846.TimeCreated) }
    @{ Ok = $false; Detail = $d }
}

# --- Dienste (Running + Autostart) ----------------------------------------------
$services = @(
    @{ Id = 'service-netskope';    Label = 'Netskope (stAgentSvc)';       Name = 'stAgentSvc' },
    @{ Id = 'service-sentinelone'; Label = 'SentinelOne (SentinelAgent)'; Name = 'SentinelAgent' },
    @{ Id = 'service-intune-ime';  Label = 'Intune Management Extension'; Name = 'IntuneManagementExtension' }
)
foreach ($s in $services) {
    Invoke-Check -Id $s.Id -Name ('Dienst: {0}' -f $s.Label) -Test {
        $svc = Get-Service -Name $s.Name -ErrorAction SilentlyContinue
        if (-not $svc)                      { @{ Ok = $false; Detail = 'Dienst nicht vorhanden (App nicht installiert?)' } }
        elseif ($svc.Status -ne 'Running')  { @{ Ok = $false; Detail = "Status: $($svc.Status)" } }
        elseif ($svc.StartType -ne 'Automatic') { @{ Ok = $false; Detail = "Laeuft, aber StartType=$($svc.StartType) - ueberlebt keinen Neustart!" } }
        else                                { @{ Ok = $true;  Detail = '' } }
    }
}

# --- Netskope: Tunnel wirklich verbunden -----------------------------------------
Invoke-Check -Id 'netskope-tunnel' -Name 'Netskope: Tunnel verbunden (nsdiag)' -Test {
    # §4.3-Sonderfall: Bei Anmeldung mit dem lokalen LAPS-Admin
    # (<HOSTNAME>\<LocalAdminAccount>, z.B. SLGDE-XXXXXXX\intuneadm) gibt es
    # KEIN Netskope-Steering-Profil - nsdiag meldet dann faelschlich
    # NSTUNNEL_DISCONNECTED. In dem Fall wird NUR der Dienststatus geprueft
    # (Running + StartType=Automatic, wie im Dienste-Check).
    # Konsolen-Benutzer: gleiche Quelle wie im PRT-Check ($consoleUser oben).
    $localAdmin = $script:LocalAdminName   # zentral vor dem PRT-Check aufgelöst
    if ($script:IsLocalAdminSession) {
        $svc = Get-Service -Name 'stAgentSvc' -ErrorAction SilentlyContinue
        if (-not $svc)                  { return @{ Ok = $false; Detail = 'Dienst stAgentSvc nicht vorhanden (App nicht installiert?)' } }
        if ($svc.Status -ne 'Running')  { return @{ Ok = $false; Detail = "Dienst stAgentSvc Status: $($svc.Status)" } }
        if ($svc.StartType -ne 'Automatic') { return @{ Ok = $false; Detail = "Dienst stAgentSvc laeuft, aber StartType=$($svc.StartType) - ueberlebt keinen Neustart!" } }
        $dash = [string][char]0x2014   # Gedankenstrich zur Laufzeit (ASCII-sichere Quelldatei)
        return @{ Ok = $true; Detail = ('Lokale Admin-Session ({0}) {1} kein Steering-Profil erwartet; nur Dienststatus geprüft' -f $localAdmin, $dash) }
    }
    # Standardfall: bestehende nsdiag-Logik unveraendert
    $nsdiag = @(
        "${env:ProgramFiles(x86)}\Netskope\STAgent\nsdiag.exe",
        "$env:ProgramFiles\Netskope\STAgent\nsdiag.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $nsdiag) {
        return @{ Ok = $false; Detail = 'nsdiag.exe nicht gefunden - Netskope-Client-Installation pruefen.' }
    }
    $out = (& $nsdiag -f 2>&1) | Out-String
    $tunnelLine = ($out -split "`r?`n" | Where-Object { $_ -match 'Tunnel status' }) -join ' '
    $ok = ($out -match 'NSTUNNEL_CONNECTED')
    @{ Ok = $ok; Detail = if ($tunnelLine) { $tunnelLine.Trim() } else { 'Keine Tunnel-Statuszeile in der nsdiag-Ausgabe (Tamperproof aktiv?)' } }
}

# --- AV-Rollen: SentinelOne primaer, Defender passiv -----------------------------
Invoke-Check -Id 'av-roles' -Name 'AV-Rollen: SentinelOne aktiv, Defender passiv' -Test {
    $avs  = @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop)
    $s1   = $avs | Where-Object { $_.displayName -match 'Sentinel' } | Select-Object -First 1
    $s1On = $false
    if ($s1) {
        # productState-Dekodierung (de-facto-Standard, offiziell undokumentiert):
        # Hex-Stelle 3-4 = 10/11 -> Produkt aktiviert
        $s1On = (('{0:x6}' -f $s1.productState).Substring(2,2) -in @('10','11'))
    }
    $rtp = $false; $mode = 'unbekannt'
    try {
        $mp = Get-MpComputerStatus -ErrorAction Stop
        $rtp = [bool]$mp.RealTimeProtectionEnabled
        if ($mp.AMRunningMode) { $mode = $mp.AMRunningMode }
    } catch { $mode = 'Defender-Modul nicht abfragbar (vermutlich deaktiviert - ok)' }
    $ok = ($s1On -and -not $rtp)
    $d = "SentinelOne: {0} | Defender-Echtzeitschutz: {1} | AMRunningMode: {2}" -f `
         $(if (-not $s1) { 'NICHT REGISTRIERT' } elseif ($s1On) { 'aktiv' } else { 'registriert, aber INAKTIV' }),
         $(if ($rtp) { 'AKTIV (Konflikt: zwei Engines!)' } else { 'aus/passiv' }), $mode
    @{ Ok = $ok; Detail = $d }
}

# --- Company Portal --------------------------------------------------------------
Invoke-Check -Id 'company-portal' -Name 'Company Portal installiert' -Test {
    $cp = Get-AppxPackage -AllUsers -Name 'Microsoft.CompanyPortal' -ErrorAction SilentlyContinue
    @{ Ok = [bool]$cp; Detail = if ($cp) { "Version $($cp.Version)" } else { 'Appx-Paket nicht gefunden' } }
}

# --- Windows-Version + Aktivierung -----------------------------------------------
Invoke-Check -Id 'windows-min-build' -Name ('Windows-Build >= {0}' -f $MinBuild) -Test {
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $build = [int]$cv.CurrentBuildNumber
    # Bewusst OHNE $cv.ProductName: der Registry-Wert meldet auf Windows 11
    # weiterhin "Windows 10" (bekannte Microsoft-Altlast).
    @{ Ok = ($build -ge $MinBuild); Detail = ('Build {0}.{1} ({2})' -f $build, $cv.UBR, $cv.DisplayVersion) }
}
Invoke-Check -Id 'windows-activation' -Name 'Windows aktiviert' -Test {
    $lic = Get-CimInstance -ClassName SoftwareLicensingProduct `
           -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" |
           Select-Object -First 1
    if (-not $lic) { return @{ Ok = $false; Detail = 'Kein Lizenzprodukt mit Product Key gefunden.' } }
    $edition = (Get-CimInstance Win32_OperatingSystem).Caption
    @{ Ok = ($lic.LicenseStatus -eq 1)
       Detail = ('{0} | LicenseStatus={1} (1=Licensed). Hinweis: Enterprise via Subscription Activation greift erst nach Anmeldung eines lizenzierten Benutzers.' -f $edition, $lic.LicenseStatus) }
}

# --- Pending Reboot ---------------------------------------------------------------
Invoke-Check -Id 'pending-reboot' -Name 'Kein Neustart ausstehend' -Warning -Test {
    $cbs = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    $wu  = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    $pfro = $null
    try { $pfro = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction Stop).PendingFileRenameOperations } catch { }
    $d = "CBS=$cbs WU=$wu" + $(if ($pfro) { ' (zusaetzlich PendingFileRenameOperations vorhanden - meist harmlos)' } else { '' })
    @{ Ok = (-not $cbs -and -not $wu); Detail = $d }
}

# --- Geraetetreiber ---------------------------------------------------------------
Invoke-Check -Id 'driver-errors' -Name 'Keine Geraete mit Treiberfehlern' -Warning -Test {
    $bad = @(Get-PnpDevice -Status Error -ErrorAction SilentlyContinue)
    $names = ($bad | Select-Object -First 3 -ExpandProperty FriendlyName) -join '; '
    @{ Ok = ($bad.Count -eq 0)
       Detail = if ($bad.Count -eq 0) { '' } else { ('{0} Geraet(e) mit Fehler: {1}{2} - Dell Command Update ausfuehren.' -f $bad.Count, $names, $(if ($bad.Count -gt 3) { ' ...' } else { '' })) } }
}

# --- Zeitzone passend zum Land ----------------------------------------------------
Invoke-Check -Id 'timezone-country' -Name 'Zeitzone passend zum Laendercode' -Warning -Test {
    $tzMap = @{
        'DE'   = @('W. Europe Standard Time')
        'FR'   = @('Romance Standard Time')
        'PL'   = @('Central European Standard Time')
        'TEST' = @('W. Europe Standard Time','Romance Standard Time','Central European Standard Time')
    }
    $tz = (Get-TimeZone).Id
    if (-not $script:CountryCode) {
        return @{ Ok = $false; Detail = ('Hostname ohne Laendercode - Soll unbekannt. Ist: {0}' -f $tz) }
    }
    $allowed = $tzMap[$script:CountryCode]
    @{ Ok = ($tz -in $allowed); Detail = ('Ist: {0} | Soll ({1}): {2}' -f $tz, $script:CountryCode, ($allowed -join ' oder ')) }
}

# --- Windows Update ---------------------------------------------------------------
if ($SkipWindowsUpdateScan) {
    Add-Result -Name 'Windows Update: keine ausstehenden Updates' -Status 'SKIPPED' -Detail 'per Parameter uebersprungen'
} else {
    Invoke-Check -Id 'windows-update-scan' -Name 'Windows Update: keine ausstehenden Updates' -Warning -Test {
        Write-Host '    (Windows-Update-Scan laeuft, 1-3 Minuten ...)' -ForegroundColor DarkGray
        Write-Progress -Activity 'Windows-Update-Scan' -Status 'Suche nach ausstehenden Updates (dauert 1-3 Minuten) ...'
        try {
            $session  = New-Object -ComObject 'Microsoft.Update.Session'
            $searcher = $session.CreateUpdateSearcher()
            $found    = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Software'")
            $cnt      = $found.Updates.Count
        } finally {
            Write-Progress -Activity 'Windows-Update-Scan' -Completed
        }
        @{ Ok = ($cnt -eq 0); Detail = if ($cnt -eq 0) { '' } else { "$cnt ausstehende(s) Update(s) - Windows Update leerlaufen lassen" } }
    }
}

# --- Infos (kein Pass/Fail) --------------------------------------------------------
Add-Result -Name 'BIOS-Version'      -Status 'INFO' -Detail ((Get-CimInstance Win32_BIOS).SMBIOSBIOSVersion)
if ($script:OsInstallDate) {
    Add-Result -Name 'OS installiert am' -Status 'INFO' -Detail ('{0:yyyy-MM-dd HH:mm}Z' -f $script:OsInstallDate)
}

# ============================================================ Ausgabe
$hostn = $env:COMPUTERNAME
$stamp = Get-Date -Format 'yyyy-MM-dd_HHmm'
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("SLG Abnahme-Report  |  Geraet: $hostn  |  $(Get-Date -Format 'yyyy-MM-dd HH:mm')  |  HEPHAISTOS $HephaistosVersion")
$lines.Add(('-' * 70))

foreach ($r in $results) {
    $label = ('[{0:00}] {1} ' -f $r.Nr, $r.Name).PadRight(55, '.')
    $line  = '{0} {1}' -f $label, $r.Status
    if ($r.Detail) { $line += "  ($($r.Detail))" }
    $lines.Add($line)
    $color = switch ($r.Status) {
        'PASSED' { 'Green' } 'FAILED' { 'Red' } 'WARN' { 'Yellow' } 'SKIPPED' { 'DarkYellow' } default { 'Cyan' }
    }
    Write-Host $line -ForegroundColor $color
}

$mandatory = $results | Where-Object Status -in @('PASSED','FAILED','WARN')
$failed    = @($mandatory | Where-Object Status -eq 'FAILED')
$warned    = @($mandatory | Where-Object Status -eq 'WARN')
$passed    = @($mandatory | Where-Object Status -eq 'PASSED')
$statusStr = if ($failed.Count -gt 0) { 'FAILED' }
             elseif ($warned.Count -gt 0) { 'SUCCESS_WITH_WARNINGS' }
             else { 'SUCCESS' }
$summary = switch ($statusStr) {
    'SUCCESS' {
        "ERGEBNIS: SUCCESS - $($mandatory.Count)/$($mandatory.Count) Tests PASSED." }
    'SUCCESS_WITH_WARNINGS' {
        "ERGEBNIS: SUCCESS_WITH_WARNINGS - $($passed.Count) PASSED, $($warned.Count) Hinweis(e), 0 FAILED - uebergabefaehig." }
    default {
        "ERGEBNIS: FAILED - $($failed.Count) von $($mandatory.Count) Tests fehlgeschlagen$(if ($warned.Count) { ", dazu $($warned.Count) Hinweis(e)" }). Siehe Troubleshooting (docs/ANLEITUNG.md, Kapitel 6)." }
}
$lines.Add(('-' * 70)); $lines.Add($summary)
Write-Host ('-' * 70)
Write-Host $summary -ForegroundColor $(switch ($statusStr) { 'SUCCESS' {'Green'} 'SUCCESS_WITH_WARNINGS' {'Yellow'} default {'Red'} })

# ============================================================ Report-Export (Text + JSON)
# Reports landen direkt im Geraeteordner auf dem Stick (kein interner
# Reports-Ordner mehr - der Stick ist beim Einsatz immer eingesteckt).
$reportFile = $null
try {
    $reportFile = Join-Path $DevDir ('{0}_{1}.txt' -f $hostn, $stamp)
    $lines | Set-Content -Path $reportFile -Encoding UTF8
    # Strukturierte Daten fuer den HTML-Report (Schema 2, wie Rev04)
    $jsonFile = [IO.Path]::ChangeExtension($reportFile, '.json')
    [pscustomobject]@{
        Schema    = 2
        Rev       = ('HEPHAISTOS {0}' -f $HephaistosVersion)
        Hostname  = $hostn
        Timestamp = (Get-Date -Format 's')
        Summary   = [pscustomobject]@{
            Success = ($failed.Count -eq 0)
            Status  = $statusStr
            Passed  = $passed.Count
            Warned  = $warned.Count
            Failed  = $failed.Count
            Total   = $mandatory.Count
        }
        Results   = $results
    } | ConvertTo-Json -Depth 4 | Set-Content -Path $jsonFile -Encoding UTF8
    Write-Host ('Report gespeichert: {0} (Geraeteordner: {1})' -f (Split-Path -Leaf $reportFile), $DevDir)
} catch {
    $reportFile = $null
    Write-Host "Report-Export fehlgeschlagen: $($_.Exception.Message)" -ForegroundColor Yellow
}

# ============================================================ Ergebnis + State-Flag
# Port aus Invoke-Step4Compliance: dreistufiges Ergebnis direkt aus der Summary
# (kein Kindprozess mehr, daher entfaellt der Exit-Code-/JSON-Umweg des Originals).
$resultState = $statusStr
switch ($resultState) {
    'SUCCESS' {
        Set-Step -StateDir $StateDir -Name 'step4_compliance.done' -Detail 'Alle Pflichttests PASSED'
        Write-Host 'Abnahme BESTANDEN.' -ForegroundColor Green
    }
    'SUCCESS_WITH_WARNINGS' {
        Set-Step -StateDir $StateDir -Name 'step4_compliance.done' -Detail 'Bestanden mit Hinweisen (WARN) - Details im Report'
        Write-Host 'Abnahme BESTANDEN - mit Hinweisen (gelbe Punkte im Report).' -ForegroundColor Yellow
    }
    default {
        Write-Host 'Abnahme NICHT bestanden - Schritt bleibt offen. Troubleshooting durchführen.' -ForegroundColor Red
    }
}

# ============================================================ Reports (HTML/PDF/Teams/Mail)
if ($NoReport) {
    Write-HephDim 'Parameter -NoReport gesetzt - HTML/PDF/Teams/Mail werden uebersprungen.'
} else {
    Write-HephPhase -Title 'Report-Erstellung (HTML/PDF/Teams/Mail)' -EstimatedDuration '30-90 Sekunden'
    # Report-Module frisch aus dem Repo laden (Fallback: lokale Kopien) und
    # dot-sourcen - die Funktionen laufen danach im Scope dieses Scripts.
    $modulesOk = $false
    try {
        foreach ($rel in @(
            'abnahme/report/New-HephaistosHtmlReport.ps1',
            'abnahme/report/Convert-HtmlToPdf.ps1',
            'abnahme/report/Send-TeamsCard.ps1',
            'abnahme/report/Send-HephaistosReport.ps1'
        )) {
            $mod = Get-HephaistosScript -RelPath $rel -RawBase $Script:HephRawBase -FallbackRoots $Script:HephFallbackRoots
            . $mod.Path
        }
        $modulesOk = $true
    } catch {
        Write-HephWarn ('Report-Module nicht ladbar: {0}' -f $_.Exception.Message)
        Write-HephWarn 'Text-/JSON-Report liegt im Geraeteordner - HTML/PDF/Teams/Mail entfallen.'
    }

    $html = $null; $pdf = $null
    if ($modulesOk) {
        # --- HTML-Report (immer, auch bei FAILED - dokumentiert den Ist-Stand)
        try {
            $html = New-HephaistosHtmlReport -TestReportFile $reportFile -ResultState $resultState `
                -Technician $technician -PrimaryUser $primaryUser -DevDir $DevDir -StateDir $StateDir `
                -Serial $Serial -Model $Model
            Write-Host ('HTML-Report: {0}' -f $html)
        } catch {
            Write-HephWarn ('HTML-Report fehlgeschlagen: {0}' -f $_.Exception.Message)
        }
    }
    if ($html) {
        # --- PDF via Edge headless (nur Vollwindows, best effort)
        Write-Progress -Id 2 -Activity 'PDF-Report' -Status 'Edge headless erzeugt das PDF ...'
        try { $pdf = Convert-HtmlToPdf -HtmlPath $html } catch { $pdf = $null }
        Write-Progress -Id 2 -Activity 'PDF-Report' -Completed
        if ($pdf) { Write-Host ('PDF-Report:  {0}' -f $pdf) -ForegroundColor Green }

        # --- Secrets (optional): Teams-Webhook + Mail-Empfaenger kommen aus dem
        #     verschluesselten Blob auf dem Stick (§6) - nie mehr aus dem Script.
        $secrets = $null
        $secretsPath = $null
        if ($UsbRoot) { $secretsPath = Join-Path $UsbRoot 'HEPHAISTOS-Secrets\hephaistos.secrets.enc.json' }
        if ($NonInteractive) {
            Write-HephDim 'NonInteractive: Secrets werden uebersprungen - Mail spaeter via SEND-REPORTS; Teams-Karte nur ueber den Geraete-Cache (falls in der OOBE-Phase hinterlegt).'
        } elseif ($secretsPath -and (Test-Path $secretsPath)) {
            Write-HephInfo 'Secrets-Blob gefunden - Passphrase wird fuer Teams-Karte/Mailversand benoetigt.'
            $secrets = Get-HephaistosSecrets -Path $secretsPath
            if (-not $secrets) {
                Write-HephDim 'Secrets nicht entsperrt - Teams-Karte und Mailversand werden uebersprungen (Reports liegen im Geraeteordner).'
            }
        } else {
            Write-HephDim 'Kein Secrets-Blob auf dem Stick - Teams-Karte und Mailversand werden uebersprungen.'
        }

        # --- Teams-Benachrichtigung (Webhook, keine Anmeldung noetig).
        # v1.2.1: Webhook kommt aus dem Secrets-Blob ODER aus dem geraetelokalen
        # DPAPI-Cache (von der OOBE-Phase beim Secrets-Entsperren hinterlegt) -
        # damit postet auch die Auto-Abnahme (NonInteractive) ohne Passphrase.
        $teamsWebhook = $null
        $teamsSource  = ''
        if ($secrets -and $secrets.TeamsWebhookUrl) {
            $teamsWebhook = [string]$secrets.TeamsWebhookUrl
            $teamsSource  = 'Secrets-Blob'
        } elseif (Get-Command Get-HephTeamsWebhookCache -ErrorAction SilentlyContinue) {
            $teamsWebhook = Get-HephTeamsWebhookCache
            if ($teamsWebhook) { $teamsSource = 'Geraete-Cache (DPAPI)' }
        }
        if ($teamsWebhook) {
            Write-HephDim ('Teams-Webhook-Quelle: {0}' -f $teamsSource)
            Send-TeamsCard -ResultState $resultState -ReportName ([IO.Path]::GetFileName($(if ($pdf) { $pdf } else { $html }))) `
                -Technician $technician -PrimaryUser $primaryUser -AttachmentPath $(if ($pdf) { $pdf } else { $html }) `
                -WebhookUrl $teamsWebhook -AttachPdf:$attachPdf -Serial $Serial -Model $Model
        } elseif ($secrets) {
            Write-HephDim 'Keine TeamsWebhookUrl im Secrets-Blob - Teams-Karte uebersprungen.'
        } else {
            Write-HephDim 'Kein Teams-Webhook verfuegbar (weder Secrets noch Geraete-Cache) - Teams-Karte uebersprungen.'
        }

        # --- Mailversand: am Kundengeraet bewusst KEINE Anmeldung (dort läuft die
        #     Session unter dem Mitarbeiter). App-Versand nur, falls im Secrets-Blob
        #     ein MailSender hinterlegt und der Blob bereits entsperrt ist;
        #     ansonsten Sammel-Versand vom Techniker-PC (SEND-REPORTS.cmd).
        $sendCmd = if ($UsbRoot) { Join-Path $UsbRoot 'SEND-REPORTS.cmd' } else { '<Stick>:\SEND-REPORTS.cmd' }
        if ($secrets -and $secrets.ReportRecipient) {
            if ($secrets.MailSender) {
                if (Confirm-Choice ('Report per Mail an {0} senden?' -f $secrets.ReportRecipient)) {
                    Send-HephaistosReport -AttachmentPath $(if ($pdf) { $pdf } else { $html }) -ResultState $resultState -Secrets $secrets -Serial $Serial -Model $Model
                }
            } else {
                Write-Host ''
                Write-Host 'Report gespeichert. Versand gesammelt vom TECHNIKER-PC:' -ForegroundColor Cyan
                Write-Host ('  Stick anstecken und {0} starten' -f $sendCmd) -ForegroundColor Cyan
                Write-Host '  (sendet alle offenen Reports über dein Outlook / dein SSO - ohne Anmeldung hier).' -ForegroundColor DarkGray
            }
        }
    }
}

# ============================================================ Abschluss
Write-HephResult -Success ($failed.Count -eq 0) -Text $(
    if ($failed.Count -eq 0) { ('Abnahme abgeschlossen: {0}' -f $statusStr) }
    else { ('Abnahme abgeschlossen: FAILED ({0} Pflichttest(s) fehlgeschlagen)' -f $failed.Count) }
)
try { Stop-Transcript | Out-Null } catch { }

exit $(if ($failed.Count -eq 0) { 0 } else { 1 })
