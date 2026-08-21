<#
.SYNOPSIS
    HEPHAISTOS Secrets-Einrichtung - interaktiv am Admin-PC (Ersatz für den
    Menüpunkt [S] / Save-GraphConfig des alten Sticks).
.DESCRIPTION
    Fragt alle geheimen Felder ab (Tenant-ID, App-ID, Client Secret,
    Report-Empfänger; optional Teams-Webhook und MailSender), verschlüsselt sie
    als v2-Blob (AES-256, PBKDF2/SHA-256, 600000 Iterationen) und legt
    hephaistos.secrets.enc.json standardmäßig auf dem erkannten Stick unter
    HEPHAISTOS-Secrets\ ab.
    Der Blob und die Passphrase gehören NIEMALS ins Repo (das Repo ist public!).
.PARAMETER OutFile
    Zielpfad des verschlüsselten Blobs. Ohne Angabe: erkannter Stick
    (<Stick>:\HEPHAISTOS-Secrets\hephaistos.secrets.enc.json), sonst aktuelles
    Verzeichnis mit Kopier-Hinweis.
.NOTES
    HEPHAISTOS v1.2.1 - portiert aus USB_ScriptTool Rev05 (Save-GraphConfig).
    PowerShell 5.1. UTF-8 mit BOM.
#>
param(
    [string]$OutFile = ''
)

$ErrorActionPreference = 'Stop'
$Script:HephVersion = '1.2.1'
$Script:HephRawBase = 'https://raw.githubusercontent.com/Himerys/HEPHAISTOS/main'

# Lib-Load: bevorzugt LOKAL aus dem Repo-Checkout (dieses Tool liegt in tools\,
# die Lib daneben in lib\) - erst wenn das fehlt, Download von GitHub.
# Bewusst umgekehrte Reihenfolge zum Entry-Script-Bootstrap (SPEC §7.11).
$libPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\Hephaistos.Common.ps1'
if (Test-Path $libPath) {
    $Script:HephLibSource = 'lokale Kopie: ' + $libPath
} else {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    try {
        $tmp = Join-Path $env:TEMP 'HEPHAISTOS\lib'
        $null = New-Item -Path $tmp -ItemType Directory -Force
        $libPath = Join-Path $tmp 'Hephaistos.Common.ps1'
        Invoke-WebRequest -UseBasicParsing -Uri ($Script:HephRawBase + '/lib/Hephaistos.Common.ps1') -OutFile $libPath
        $Script:HephLibSource = 'GitHub: ' + $Script:HephRawBase
    } catch {
        Write-Host 'FEHLER: lib/Hephaistos.Common.ps1 weder im Checkout noch von GitHub verfügbar.' -ForegroundColor Red
        exit 1
    }
}
. $libPath

Write-HephBanner -Title 'HEPHAISTOS - Secrets-Einrichtung' -Version $Script:HephVersion -Source $Script:HephLibSource

# Pflichtfeld-Abfrage: leere Eingabe -> erneut fragen (gleiches Muster wie beim
# Technikernamen, Handoff §4.1).
function Read-RequiredValue {
    param([string]$Prompt)
    while ($true) {
        $v = (Read-Host $Prompt).Trim()
        if ($v) { return $v }
        Write-HephWarn '  Pflichtfeld - bitte einen Wert eingeben.'
    }
}

# Zielpfad VOR den Eingaben klären (erspart vergebliches Tippen bei Abbruch).
if (-not $OutFile) {
    $usb = Find-HephaistosUsb
    if ($usb) {
        $secDir = Join-Path $usb 'HEPHAISTOS-Secrets'
        $null = New-Item -Path $secDir -ItemType Directory -Force
        $OutFile = Join-Path $secDir 'hephaistos.secrets.enc.json'
        Write-HephInfo ('Ziel: erkannter Stick -> {0}' -f $OutFile)
    } else {
        $OutFile = Join-Path (Get-Location).Path 'hephaistos.secrets.enc.json'
        Write-HephWarn 'Kein HEPHAISTOS-Stick gefunden (Marker-Ordner _HEPHAISTOS).'
        Write-HephWarn ('Schreibe stattdessen: {0}' -f $OutFile)
        Write-HephWarn 'Datei anschließend manuell nach <Stick>:\HEPHAISTOS-Secrets\ kopieren!'
    }
}
if (Test-Path $OutFile) {
    if (-not (Confirm-Choice ('Datei existiert bereits - überschreiben? ({0})' -f $OutFile))) {
        Write-HephWarn 'Abgebrochen - bestehende Datei bleibt unverändert.'
        exit 0
    }
}

Write-Host ''
Write-Host 'Einrichtung Graph-Zugang + Report-Versand (App-Registrierung, siehe docs/ANLEITUNG.md):' -ForegroundColor Cyan
$tenantId = Read-RequiredValue '  Tenant-ID (GUID oder domain.onmicrosoft.com)'
$appId    = Read-RequiredValue '  App-ID (Client-ID der App-Registrierung)'
$appSecret = ''
while (-not $appSecret) {
    $appSecret = Read-Passphrase '  Client Secret (Eingabe verdeckt)'
    if (-not $appSecret) { Write-HephWarn '  Pflichtfeld - bitte einen Wert eingeben.' }
}
$recipient = Read-RequiredValue '  Report-Empfänger (Mail-Postfach des IT-Teams, z.B. it-team@example.com)'
$webhook   = (Read-Host '  Teams-Webhook-URL (optional, Enter = keine Teams-Karte)').Trim()
$mailFrom  = (Read-Host '  MailSender-Postfach (optional, reserviert für App-Versand - Enter = leer)').Trim()

$cfg = [ordered]@{
    TenantId        = $tenantId
    AppId           = $appId
    AppSecret       = $appSecret
    ReportRecipient = $recipient
    TeamsWebhookUrl = $webhook
    MailSender      = $mailFrom
}

# Passphrase 2x abfragen (Port Save-GraphConfig): leer oder ungleich -> Abbruch.
$p1 = Read-Passphrase '  Passphrase zum Verschlüsseln (Team-intern)'
$p2 = Read-Passphrase '  Passphrase wiederholen'
if (-not $p1 -or $p1 -ne $p2) { Write-HephErr 'Passphrasen leer oder ungleich - abgebrochen.'; exit 1 }

$outDir = Split-Path -Parent $OutFile
if ($outDir -and -not (Test-Path $outDir)) { $null = New-Item -Path $outDir -ItemType Directory -Force }
$blob = Protect-HephaistosSecret -Plain ($cfg | ConvertTo-Json -Compress) -Pass $p1
$blob | ConvertTo-Json | Set-Content -Path $OutFile -Encoding ASCII

Write-HephOk ('Gespeichert (verschlüsselt, v2: PBKDF2/SHA-256, 600000 Iterationen): {0}' -f $OutFile)
Write-HephOk 'Ab jetzt fragen die Scripts nur noch die Passphrase ab - keine Klartext-Secrets auf dem Stick.'
Write-HephDim 'Hinweis: Blob und Passphrase NIE ins Repo committen (Repo ist public). Passphrase nur Team-intern weitergeben.'
