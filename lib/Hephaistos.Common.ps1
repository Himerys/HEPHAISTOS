<#
.SYNOPSIS
    HEPHAISTOS - Gemeinsame Bibliothek für alle Phasen (WinPE, OOBE, Vollwindows, Techniker-PC).
.DESCRIPTION
    Wird von den Entry-Scripts (boot/, oobe/, abnahme/, send/) per Dot-Sourcing geladen -
    entweder frisch aus dem GitHub-Repo heruntergeladen oder aus der lokalen
    Fallback-Kopie (siehe Referenz-Bootstrap-Block am Dateiende). Enthält:
        - Konsolen-Helfer (Statusfarben, Banner, Phasen-Kopfzeilen, Ergebniszeilen)
        - Stick-Suche, Geräteerkennung, Geräteordner + State-System (Logs\<Serial>\state\*.done)
        - Download-/Config-Helfer mit Offline-Fallback (GitHub raw -> lokale Kopie)
        - Secrets: AES-256 + PBKDF2 (v2-Format SHA-256/600000; alte Rev05-Blobs lesbar,
          werden beim nächsten Entsperren automatisch neu verschlüsselt)
        - Graph-App-Token (client_credentials), Technikername, VC++-Runtime-Workaround
.NOTES
    HEPHAISTOS v1.2.4 - portiert aus USB_ScriptTool Rev05 (_SLG\SLG-Onboarding.ps1).
    Benötigt PowerShell 5.1 (WinPE/OOBE/Win11 Standard). Datei ist UTF-8 MIT BOM
    gespeichert (Pflicht für PS 5.1 + Umlaute).
#>

# ============================================================ Version (zentral)
# Eine Quelle für Banner, Report-Header UND Report-Footer (behebt Rev04/Rev05-Drift).
$HephaistosVersion = '1.2.4'

# Konsole auf UTF-8, damit Haken/Linien-Zeichen sauber dargestellt werden
# (in WinPE/OOBE nicht immer möglich - best effort wie im Original).
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

# ============================================================ Konsolen-Helfer
# Konsistente Statusfarben (Handoff §4.5): Grün = OK, Gelb = Warnung/Hinweis,
# Rot = Fehler, Cyan = Aktion/Info, DarkGray = Nebeninfo.
function Write-HephOk   { param([string]$Text) Write-Host $Text -ForegroundColor Green }
function Write-HephWarn { param([string]$Text) Write-Host $Text -ForegroundColor Yellow }
function Write-HephErr  { param([string]$Text) Write-Host $Text -ForegroundColor Red }
function Write-HephInfo { param([string]$Text) Write-Host $Text -ForegroundColor Cyan }
function Write-HephDim  { param([string]$Text) Write-Host $Text -ForegroundColor DarkGray }

function Write-HephBanner {
    # Versions-Banner (Handoff §2.8): jedes Entry-Script zeigt beim Start Version +
    # Quelle (GitHub-URL oder lokale Kopie) - verhindert Versions-Drift zwischen Sticks.
    # Doppellinie zur Laufzeit erzeugt (ASCII-sichere Quelldatei, Port von Write-Head).
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$Source,
        [string]$Model = '',
        [string]$Serial = '',
        [string]$Env = ''
    )
    $bar = [string][char]0x2550 * 70
    Write-Host ''
    Write-Host $bar -ForegroundColor DarkCyan
    Write-Host ('   {0}' -f $Title) -ForegroundColor White
    Write-Host ('   Version {0}   |   Quelle: {1}' -f $Version, $Source) -ForegroundColor Gray
    if ($Model -and $Serial) {
        Write-Host ('   {0}   |   Service Tag: {1}' -f $Model, $Serial) -ForegroundColor Gray
    } elseif ($Model) {
        Write-Host ('   {0}' -f $Model) -ForegroundColor Gray
    } elseif ($Serial) {
        Write-Host ('   Service Tag: {0}' -f $Serial) -ForegroundColor Gray
    }
    if ($Env) { Write-Host ('   Umgebung: {0}' -f $Env) -ForegroundColor DarkGray }
    Write-Host $bar -ForegroundColor DarkCyan
    Write-Host ''
}

function Write-HephPhase {
    # Phasen-Kopfzeile (Handoff §4.5): was passiert + geschätzte Dauer.
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [string]$EstimatedDuration = ''
    )
    Write-Host ''
    Write-Host ('==> {0}' -f $Title) -ForegroundColor Cyan
    if ($EstimatedDuration) {
        Write-Host ('    (geschätzte Dauer: {0})' -f $EstimatedDuration) -ForegroundColor DarkGray
    }
}

function Write-HephResult {
    # Eindeutige grün/rote Ergebniszeile am Phasenende (Handoff §4.5).
    # Haken/Kreuz zur Laufzeit erzeugt (ASCII-sichere Quelldatei).
    param(
        [Parameter(Mandatory = $true)][bool]$Success,
        [Parameter(Mandatory = $true)][string]$Text
    )
    if ($Success) { Write-Host ('  {0} {1}' -f [char]0x2713, $Text) -ForegroundColor Green }
    else          { Write-Host ('  {0} {1}' -f [char]0x2717, $Text) -ForegroundColor Red }
}

function Confirm-Choice {
    param([string]$Prompt)
    (Read-Host ("{0} [j/n]" -f $Prompt)) -match '^[jJyY]'
}

function Read-Passphrase {
    param([string]$Prompt)
    $sec = Read-Host $Prompt -AsSecureString
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

# ============================================================ TLS + Netz
function Enable-Tls12AndGallery {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    # v1.2.2: Unter SYSTEM ohne Benutzerprofil (z.B. Specialize-Phase) lassen sich
    # PowerShellGet/PackageManagement nicht laden (Feldtest 2026-08-21:
    # Get-PSRepository -> "Modul konnte nicht geladen werden"). Das darf den
    # Aufrufer nicht hart beenden - TLS 1.2 ist dann trotzdem gesetzt, und der
    # Aufrufer bekommt beim eigentlichen Install-* seine eigene klare Meldung.
    try {
        if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
            Write-HephDim 'NuGet-Provider wird installiert ...'
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
        }
        if ((Get-PSRepository -Name PSGallery -ErrorAction Stop).InstallationPolicy -ne 'Trusted') {
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
        }
    } catch {
        Write-HephWarn ('PSGallery in dieser Sitzung nicht nutzbar ({0}).' -f $_.Exception.Message)
    }
}

function Test-HephInternet {
    # Erreichbarkeit von graph.microsoft.com:443 (Port von Test-Internet).
    # In WinPE fehlt Test-NetConnection -> roher TCP-Connect mit 5s-Timeout.
    if (Get-Command Test-NetConnection -ErrorAction SilentlyContinue) {
        try { return [bool](Test-NetConnection -ComputerName 'graph.microsoft.com' -Port 443 -WarningAction SilentlyContinue).TcpTestSucceeded }
        catch { return $false }
    }
    try {
        $client = New-Object Net.Sockets.TcpClient
        $async  = $client.BeginConnect('graph.microsoft.com', 443, $null, $null)
        $ok     = $false
        if ($async.AsyncWaitHandle.WaitOne(5000)) {
            $client.EndConnect($async)
            $ok = $client.Connected
        }
        $client.Close()
        return $ok
    } catch { return $false }
}

# ============================================================ UEFI-Boot
function Set-HephBootNextToCurrent {
    # v1.2.4: Einmaliger Boot-Override auf den Stick. Die UEFI-Firmware merkt
    # sich in der Variable BootCurrent, von welchem Boot-Eintrag das laufende
    # WinPE gestartet wurde - also vom Stick. Dieser Wert wird nach BootNext
    # kopiert: Der NÄCHSTE Start geht damit garantiert wieder auf den Stick,
    # auch wenn in der Boot-Reihenfolge z.B. HTTP-Boot an erster Stelle steht
    # (Feldtest: nach der RAID->AHCI-Umstellung landete das Gerät im
    # HTTP-Boot statt auf dem Stick). BootNext gilt genau EINMAL und wird von
    # der Firmware danach automatisch gelöscht - die dauerhafte
    # Boot-Reihenfolge bleibt unangetastet. Rückgabe: $true bei Erfolg;
    # $false z.B. ohne UEFI oder wenn die Firmware-Variablen nicht erreichbar
    # sind (dann gilt der bisherige Weg: F12 -> USB-Stick wählen).
    try {
        if (-not ('HephUefi' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class HephUefi
{
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern uint GetFirmwareEnvironmentVariableW(string name, string guid, byte[] buffer, uint size);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool SetFirmwareEnvironmentVariableW(string name, string guid, byte[] value, uint size);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool LookupPrivilegeValueW(string system, string name, out long luid);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, ref TokenPrivileges newState, uint length, IntPtr previous, IntPtr returnLength);
    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    struct TokenPrivileges { public uint Count; public long Luid; public uint Attributes; }
    public static bool EnableEnvironmentPrivilege()
    {
        IntPtr token;
        if (!OpenProcessToken(System.Diagnostics.Process.GetCurrentProcess().Handle, 0x28, out token)) return false;
        long luid;
        if (!LookupPrivilegeValueW(null, "SeSystemEnvironmentPrivilege", out luid)) return false;
        TokenPrivileges tp;
        tp.Count = 1; tp.Luid = luid; tp.Attributes = 2;
        return AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
    }
}
'@
        }
        # EFI Global Variable Namespace (fest in der UEFI-Spezifikation).
        $guid = '{8BE4DF61-93CA-11D2-AA0D-00E098032B8C}'
        [void][HephUefi]::EnableEnvironmentPrivilege()
        $cur = New-Object byte[] 2   # BootCurrent/BootNext sind UINT16
        $got = [HephUefi]::GetFirmwareEnvironmentVariableW('BootCurrent', $guid, $cur, 2)
        if ($got -ne 2) { return $false }
        return [bool][HephUefi]::SetFirmwareEnvironmentVariableW('BootNext', $guid, $cur, 2)
    } catch { return $false }
}

# ============================================================ Stick + Gerät
function Find-HephaistosUsb {
    # Sucht den HEPHAISTOS-Stick über sein Marker-Verzeichnis \_HEPHAISTOS.
    # Bewusst über [IO.DriveInfo] statt Get-Volume - läuft so auch in WinPE.
    foreach ($drive in [IO.DriveInfo]::GetDrives()) {
        try {
            if ($drive.IsReady -and (Test-Path (Join-Path $drive.RootDirectory.FullName '_HEPHAISTOS'))) {
                return $drive.RootDirectory.FullName   # z.B. 'E:\'
            }
        } catch { }
    }
    return $null
}

function Get-HephaistosDeviceInfo {
    # Service Tag + Modell (Port aus SLG-Onboarding.ps1 Pfad-Block).
    # Fallback wie START-ONBOARDING.cmd: liefert WMI keinen Service Tag,
    # wird er manuell abgefragt (Aufkleber Unterseite).
    # -NoPrompt (v1.2.0): fuer nicht-interaktive Laeufe (Auto-Abnahme als
    # SYSTEM) - NIE Read-Host; Serial kann dann leer zurueckkommen, der
    # Aufrufer muss das behandeln.
    param([switch]$NoPrompt)
    $serial = $null; $model = ''
    try {
        $bios = Get-CimInstance Win32_BIOS -ErrorAction Stop
        if ($bios -and $bios.SerialNumber) { $serial = ([string]$bios.SerialNumber).Trim() -replace '\s', '' }
    } catch { }
    try {
        $csp = Get-CimInstance Win32_ComputerSystemProduct -ErrorAction Stop
        if ($csp -and $csp.Name) { $model = ([string]$csp.Name).Trim() }
    } catch { }
    if (-not $model) { $model = 'Unbekanntes Modell' }
    while (-not $serial) {
        if ($NoPrompt) { break }
        Write-Host 'Seriennummer konnte nicht automatisch gelesen werden.' -ForegroundColor Yellow
        $serial = (Read-Host 'Service Tag bitte manuell eingeben (Aufkleber Unterseite)').Trim() -replace '\s', ''
    }
    @{ Serial = $serial; Model = $model }
}

function Initialize-HephaistosDevice {
    # Legt den sichtbaren Geräteordner Logs\<Serial>\state an (Port aus
    # SLG-Onboarding.ps1 Pfad-Block). Der Stick ist beim Einsatz immer eingesteckt
    # und bleibt Ablageort; ohne Stick lokaler Notbehelf unter C:\OSDCloud\HEPHAISTOS.
    param(
        [string]$UsbRoot,
        [Parameter(Mandatory = $true)][string]$Serial
    )
    if ([string]::IsNullOrWhiteSpace($UsbRoot)) {
        Write-HephWarn ('Stick nicht gefunden - Geräteordner wird lokal angelegt: C:\OSDCloud\HEPHAISTOS\Logs\{0}' -f $Serial)
        $devDir = Join-Path 'C:\OSDCloud\HEPHAISTOS\Logs' $Serial
    } else {
        $devDir = Join-Path $UsbRoot ("Logs\{0}" -f $Serial)
    }
    $stateDir = Join-Path $devDir 'state'
    foreach ($d in @($devDir, $stateDir)) {
        if (-not (Test-Path $d)) { New-Item -Path $d -ItemType Directory -Force | Out-Null }
    }
    @{ DevDir = $devDir; StateDir = $stateDir }
}

# ============================================================ State-System
# Flag-Namen unverändert aus dem Original (Kontinuität bestehender Geräteordner):
# step1_bios.done, step2_osinstall.started, step2_osinstall.done,
# step3_hash.done, step4_compliance.done.
# Neu: expliziter -StateDir Parameter statt Script-Variable (Lib wird von
# mehreren Entry-Scripts genutzt).
function Get-StepFlag {
    param([string]$StateDir, [string]$Name)
    Join-Path $StateDir $Name
}

function Test-Step {
    param([string]$StateDir, [string]$Name)
    Test-Path (Get-StepFlag -StateDir $StateDir -Name $Name)
}

function Set-Step {
    param([string]$StateDir, [string]$Name, [string]$Detail = '')
    "{0:yyyy-MM-dd HH:mm}  {1}" -f (Get-Date), $Detail | Set-Content -Path (Get-StepFlag -StateDir $StateDir -Name $Name) -Encoding UTF8
}

# ============================================================ Download + Offline-Fallback
function Get-HephaistosRemote {
    # Roher Download (GitHub raw). Wirft bei Fehler - Fallback-Logik liegt in
    # Get-HephaistosScript/-Config bzw. beim Aufrufer.
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$OutFile
    )
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $dir = Split-Path -Parent $OutFile
    if ($dir -and -not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $OutFile -ErrorAction Stop
}

function Get-HephaistosScript {
    # Holt eine Repo-Datei: bevorzugt frisch von GitHub (immer aktuelle Version),
    # sonst erste existierende lokale Fallback-Kopie (Handoff §2.7) mit GELBER
    # Warnung inkl. Stand der Kopie. Nichts gefunden -> wirft.
    param(
        [Parameter(Mandatory = $true)][string]$RelPath,
        [Parameter(Mandatory = $true)][string]$RawBase,
        [string[]]$FallbackRoots = @()
    )
    $relWin = $RelPath -replace '/', '\'
    $url    = '{0}/{1}' -f $RawBase.TrimEnd('/'), ($RelPath -replace '\\', '/')
    $tmp    = Join-Path (Join-Path $env:TEMP 'HEPHAISTOS') $relWin
    try {
        Get-HephaistosRemote -Url $url -OutFile $tmp
        return @{ Path = $tmp; Source = 'GitHub'; Detail = $url }
    } catch {
        Write-HephDim ('Download fehlgeschlagen: {0} ({1})' -f $url, $_.Exception.Message)
    }
    foreach ($root in $FallbackRoots) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        $cand = Join-Path $root $relWin
        if (Test-Path $cand) {
            Write-HephWarn ('OFFLINE-FALLBACK: nutze lokale Kopie {0}, Stand {1:yyyy-MM-dd HH:mm}' -f $cand, (Get-Item $cand).LastWriteTime)
            return @{ Path = $cand; Source = 'Lokal'; Detail = $cand }
        }
    }
    throw ("Datei weder online noch als lokale Kopie verfügbar: {0}" -f $RelPath)
}

function Get-HephaistosConfig {
    # Wie Get-HephaistosScript, zusätzlich JSON-Parse (deploy.json, report-checks.json).
    param(
        [Parameter(Mandatory = $true)][string]$RelPath,
        [Parameter(Mandatory = $true)][string]$RawBase,
        [string[]]$FallbackRoots = @()
    )
    $src  = Get-HephaistosScript -RelPath $RelPath -RawBase $RawBase -FallbackRoots $FallbackRoots
    $data = Get-Content $src.Path -Raw | ConvertFrom-Json
    @{ Data = $data; Source = $src.Source; Detail = $src.Detail }
}

# ============================================================ Secrets (AES-256 + PBKDF2)
# v2-Format (Härtung Handoff §6.1): PBKDF2 mit explizitem SHA-256 und 600000
# Iterationen. Alte Rev05-Blobs (100000 Iterationen, implizit SHA-1) bleiben
# LESBAR und werden in Get-HephaistosSecrets beim nächsten erfolgreichen
# Entsperren automatisch im v2-Format neu gespeichert (Migrationspfad).
function Protect-HephaistosSecret {
    param(
        [Parameter(Mandatory = $true)][string]$Plain,
        [Parameter(Mandatory = $true)][string]$Pass
    )
    $salt = New-Object byte[] 16
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($salt)
    # 4-Arg-Konstruktor (expliziter Hash-Algorithmus) braucht .NET >= 4.7.2 -
    # auf Win11 (OOBE/Vollwindows) und aktuellem WinPE gegeben.
    $kdf = New-Object Security.Cryptography.Rfc2898DeriveBytes($Pass, $salt, 600000, [Security.Cryptography.HashAlgorithmName]::SHA256)
    $aes = [Security.Cryptography.Aes]::Create(); $aes.Key = $kdf.GetBytes(32); $aes.GenerateIV()
    $data = [Text.Encoding]::UTF8.GetBytes($Plain)
    $cipher = $aes.CreateEncryptor().TransformFinalBlock($data, 0, $data.Length)
    [pscustomobject]@{
        Version    = 2
        Kdf        = 'PBKDF2'
        Hash       = 'SHA256'
        Iterations = 600000
        Salt       = [Convert]::ToBase64String($salt)
        IV         = [Convert]::ToBase64String($aes.IV)
        Data       = [Convert]::ToBase64String($cipher)
    }
}

function Unprotect-HephaistosSecret {
    # Rückgabe: Klartext-String oder $null (falsche Passphrase / defekter Blob).
    # v2-Blob (hat Iterations/Hash) -> KDF-Parameter aus dem Blob;
    # Legacy-Blob (nur Salt/IV/Data) -> 100000 Iterationen, implizit SHA-1 (Rev05).
    param(
        [Parameter(Mandatory = $true)]$Blob,
        [Parameter(Mandatory = $true)][string]$Pass
    )
    try {
        $salt = [Convert]::FromBase64String($Blob.Salt)
        if ($Blob.PSObject.Properties['Iterations'] -and $Blob.PSObject.Properties['Hash']) {
            $hashName = New-Object Security.Cryptography.HashAlgorithmName([string]$Blob.Hash)
            $kdf = New-Object Security.Cryptography.Rfc2898DeriveBytes($Pass, $salt, [int]$Blob.Iterations, $hashName)
        } else {
            $kdf = New-Object Security.Cryptography.Rfc2898DeriveBytes($Pass, $salt, 100000)
        }
        $aes = [Security.Cryptography.Aes]::Create(); $aes.Key = $kdf.GetBytes(32); $aes.IV = [Convert]::FromBase64String($Blob.IV)
        $c = [Convert]::FromBase64String($Blob.Data)
        [Text.Encoding]::UTF8.GetString($aes.CreateDecryptor().TransformFinalBlock($c, 0, $c.Length))
    } catch { $null }
}

function Get-HephaistosSecrets {
    # Liest den verschlüsselten Secrets-Blob (liegt NUR auf dem Stick unter
    # HEPHAISTOS-Secrets\, nie im Repo - Handoff §6.2), fragt die Team-Passphrase
    # ab (max. 3 Versuche, Port von Get-GraphConfig) und cached das Ergebnis für
    # die Sitzung. Rückgabe: Objekt (TenantId, AppId, AppSecret, ReportRecipient,
    # TeamsWebhookUrl, MailSender) oder $null.
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$MaxTries = 3
    )
    if ($Script:HephSecrets) { return $Script:HephSecrets }
    if (-not (Test-Path $Path)) { return $null }
    $blob = Get-Content $Path -Raw | ConvertFrom-Json
    $isLegacy = -not $blob.PSObject.Properties['Iterations']
    for ($try = 1; $try -le $MaxTries; $try++) {
        $pass = Read-Passphrase 'Passphrase für die HEPHAISTOS-Secrets'
        $json = Unprotect-HephaistosSecret -Blob $blob -Pass $pass
        if ($json) {
            if ($isLegacy) {
                # Migrationspfad (Handoff §6.1): alten Blob SOFORT mit derselben
                # Passphrase im gehärteten v2-Format neu verschlüsseln.
                try {
                    Protect-HephaistosSecret -Plain $json -Pass $pass | ConvertTo-Json | Set-Content -Path $Path -Encoding ASCII
                    Write-HephOk ('Secrets-Datei auf v2-Format aktualisiert (PBKDF2-SHA256, 600000 Iterationen): {0}' -f $Path)
                } catch {
                    Write-HephWarn ('Re-Encrypt auf v2 fehlgeschlagen - Datei bleibt im alten Format: {0}' -f $_.Exception.Message)
                }
            }
            $Script:HephSecrets = $json | ConvertFrom-Json
            return $Script:HephSecrets
        }
        Write-HephWarn 'Falsche Passphrase.'
    }
    Write-HephWarn ('Secrets bleiben gesperrt ({0}x falsche Passphrase).' -f $MaxTries)
    return $null
}

# ============================================================ Graph-Token
function Get-GraphAppToken {
    param($Cfg)
    (Invoke-RestMethod -Method POST -Uri ("https://login.microsoftonline.com/{0}/oauth2/v2.0/token" -f $Cfg.TenantId) -Body @{
        client_id = $Cfg.AppId; client_secret = $Cfg.AppSecret
        scope = 'https://graph.microsoft.com/.default'; grant_type = 'client_credentials'
    }).access_token
}

# ============================================================ Techniker-Name
function Get-TechnicianName {
    # Freitext-Pflichtfeld statt Technicians.txt (Handoff §4.1). Einmal pro
    # Sitzung gecacht ($Script:TechName wie bisher); fließt in Report,
    # Teams-Karte, Mail und Logs. Mit -Default (z.B. WinPE-Wert aus
    # technician.txt) übernimmt Enter den Vorschlag.
    param([string]$Default = '')
    if ($Script:TechName) { return $Script:TechName }
    while ($true) {
        if ($Default) {
            $name = (Read-Host ('Dein Name [Enter = {0}]' -f $Default)).Trim()
            if (-not $name) { $name = $Default }
        } else {
            $name = (Read-Host 'Dein Name').Trim()
        }
        if ($name) {
            $Script:TechName = $name
            return $Script:TechName
        }
        Write-HephWarn 'Name ist ein Pflichtfeld - bitte eingeben.'
    }
}

# ============================================================ VC++-Runtime-Workaround
function Save-HephTeamsWebhookCache {
    # v1.2.1: Teams-Webhook-URL DPAPI-verschlüsselt (Machine-Scope) auf dem
    # GERÄT cachen. Wird in der OOBE-Phase beim ohnehin nötigen Secrets-
    # Entsperren geschrieben, damit die Auto-Abnahme die Teams-Karte OHNE
    # Passphrase posten kann. Machine-Scope heißt: außerhalb dieses einen
    # Geräts ist die Datei kryptographisch wertlos (kein Klartext at rest,
    # nichts im Repo/auf dem Stick); sie verschwindet mit dem nächsten Wipe.
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [string]$Path = 'C:\OSDCloud\HEPHAISTOS\teams.webhook.bin'
    )
    Add-Type -AssemblyName System.Security
    $entropy = [Text.Encoding]::UTF8.GetBytes('HEPHAISTOS.TeamsWebhook.v1')
    $cipher  = [Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($Url), $entropy, [Security.Cryptography.DataProtectionScope]::LocalMachine)
    $null = New-Item -Path (Split-Path -Parent $Path) -ItemType Directory -Force
    [IO.File]::WriteAllBytes($Path, $cipher)
}

function Get-HephTeamsWebhookCache {
    # Gegenstück zu Save-HephTeamsWebhookCache: liefert die Webhook-URL oder
    # $null (Datei fehlt, anderes Gerät, beschädigt - alles still $null).
    param([string]$Path = 'C:\OSDCloud\HEPHAISTOS\teams.webhook.bin')
    try {
        if (-not (Test-Path $Path)) { return $null }
        Add-Type -AssemblyName System.Security
        $entropy = [Text.Encoding]::UTF8.GetBytes('HEPHAISTOS.TeamsWebhook.v1')
        $plain = [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($Path), $entropy, [Security.Cryptography.DataProtectionScope]::LocalMachine)
        return [Text.Encoding]::UTF8.GetString($plain)
    } catch { return $null }
}

function Get-HephBiosPackageDir {
    # Modell-spezifisches CCTK-Paket auflösen (v1.1.0): deploy.json Bios.Packages
    # mappt Modell-Teilstrings auf Ordnernamen unter <ToolsDir>. Der LÄNGSTE
    # passende Schlüssel gewinnt ("Pro 14 Premium" schlägt "Pro 14"). Kein
    # Treffer bzw. Ordner fehlt auf dem Stick -> DefaultPackage. Ohne Bios-Block
    # in der Config verhält sich alles wie bisher (Tools\CCTK).
    param(
        [Parameter(Mandatory = $true)][string]$Model,
        $BiosConfig,
        [Parameter(Mandatory = $true)][string]$ToolsDir
    )
    $defaultPkg = 'CCTK'
    if ($BiosConfig -and $BiosConfig.DefaultPackage) { $defaultPkg = [string]$BiosConfig.DefaultPackage }
    $bestKey = $null
    $bestPkg = $null
    if ($BiosConfig -and $BiosConfig.Packages) {
        foreach ($p in $BiosConfig.Packages.PSObject.Properties) {
            $k = [string]$p.Name
            if ($k -and ($Model -match [regex]::Escape($k))) {
                if (-not $bestKey -or ($k.Length -gt $bestKey.Length)) {
                    $bestKey = $k
                    $bestPkg = [string]$p.Value
                }
            }
        }
    }
    $pkg = $bestPkg
    $why = ''
    if ($pkg) { $why = ('Modell-Treffer "{0}"' -f $bestKey) }
    else      { $pkg = $defaultPkg; $why = 'Standard-Paket (kein Modell-Treffer)' }
    $dir = Join-Path $ToolsDir $pkg
    $mappedMissing = $false
    if (-not (Test-Path $dir) -and ($pkg -ne $defaultPkg)) {
        $mappedMissing = $true
        $why = ('Ordner "{0}" fehlt auf dem Stick - Standard-Paket als Ersatz' -f $pkg)
        $pkg = $defaultPkg
        $dir = Join-Path $ToolsDir $pkg
    }
    @{ Dir = $dir; Package = $pkg; Reason = $why; MappedMissing = $mappedMissing }
}

function Install-VcRuntimeIfMissing {
    # miniunz.exe (SCE-Selbstextraktion) braucht die VC++-Runtime; auf dem
    # Dell-Werksimage fehlt sie (Praxistest 07/2026: 0xC0000135).
    param([Parameter(Mandatory = $true)][string]$ToolsDir)
    if (Test-Path "$env:SystemRoot\System32\VCRUNTIME140.dll") { return $true }
    $redist = Join-Path $ToolsDir 'vc_redist.x64.exe'
    if (-not (Test-Path $redist)) {
        Write-HephWarn ('VC++-Runtime fehlt und {0} liegt nicht auf dem Stick.' -f $redist)
        return $false
    }
    Write-HephDim 'VC++-Runtime fehlt - wird still installiert (~20 Sekunden) ...'
    $p = Start-Process -FilePath $redist -ArgumentList '/install', '/quiet', '/norestart' -Wait -PassThru
    if ($p.ExitCode -in @(0, 3010, 1638)) { return $true }   # 3010=Reboot ausstehend, 1638=neuere Version vorhanden
    Write-HephWarn ("VC++-Installation fehlgeschlagen (Exit {0})." -f $p.ExitCode)
    return $false
}

# ============================================================ Referenz: Lib-Bootstrap-Block
<#
Referenz-Implementierung des Lib-Bootstrap-Blocks (SPEC §4). Alle Entry-Scripts
(boot/Start-Hephaistos.ps1, oobe/Invoke-HephaistosOnboarding.ps1,
abnahme/Test-HephaistosDevice.ps1, send/Send-QueuedReports.ps1) tragen diesen
Block WORTGLEICH am Anfang - nur die FallbackRoots-Zeile wird je Phase angepasst
(Reihenfolge: Staged (C:) vor Stick, siehe SPEC §7.x der jeweiligen Datei).

# --- HEPHAISTOS Lib-Bootstrap (identisch in allen Entry-Scripts) ---
$Script:HephVersion = '1.2.4'
$Script:HephRawBase = 'https://raw.githubusercontent.com/Himerys/HEPHAISTOS/main'
# FallbackRoots je Phase; Beispiel OOBE: Staged (C:) zuerst, dann Stick.
$Script:HephFallbackRoots = @('C:\OSDCloud\HEPHAISTOS\Fallback')
# Minimal-Sticksuche VOR dem Lib-Load (die Lib ist hier noch nicht verfuegbar):
foreach ($drv in [IO.DriveInfo]::GetDrives()) {
    try {
        if ($drv.IsReady -and (Test-Path (Join-Path $drv.RootDirectory.FullName '_HEPHAISTOS'))) {
            $Script:HephFallbackRoots += (Join-Path $drv.RootDirectory.FullName '_HEPHAISTOS\Fallback'); break
        }
    } catch { }
}
# 1) TLS 1.2 aktivieren (3072 = Tls12), 2) Download der Lib nach TEMP versuchen,
# 3) sonst erste existierende Fallback-Kopie, 4) Dot-Source, 5) sonst Abbruch.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
$libTmp = Join-Path (Join-Path $env:TEMP 'HEPHAISTOS') 'lib\Hephaistos.Common.ps1'
$libPath = $null
try {
    $libDir = Split-Path -Parent $libTmp
    if (-not (Test-Path $libDir)) { New-Item -Path $libDir -ItemType Directory -Force | Out-Null }
    Invoke-WebRequest -UseBasicParsing -Uri ('{0}/lib/Hephaistos.Common.ps1' -f $Script:HephRawBase) -OutFile $libTmp -ErrorAction Stop
    $libPath = $libTmp
    $Script:HephLibSource = ('GitHub ({0}/lib/Hephaistos.Common.ps1)' -f $Script:HephRawBase)
} catch {
    foreach ($root in $Script:HephFallbackRoots) {
        $cand = Join-Path $root 'lib\Hephaistos.Common.ps1'
        if (Test-Path $cand) { $libPath = $cand; $Script:HephLibSource = ('lokale Kopie: {0}' -f $cand); break }
    }
}
if (-not $libPath) {
    Write-Host 'FEHLER: HEPHAISTOS-Bibliothek weder online noch als lokale Kopie verfuegbar.' -ForegroundColor Red
    exit 1
}
. $libPath
if ($Script:HephLibSource -like 'lokale Kopie*') {
    Write-Host ('OFFLINE-FALLBACK: Bibliothek aus {0}, Stand {1:yyyy-MM-dd HH:mm}' -f $libPath, (Get-Item $libPath).LastWriteTime) -ForegroundColor Yellow
}
# --- Ende Lib-Bootstrap ---
#>
