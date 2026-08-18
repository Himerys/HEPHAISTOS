<#
.SYNOPSIS
    HEPHAISTOS Report-Versand - läuft auf dem TECHNIKER-PC (eigene Windows-Session).
.DESCRIPTION
    Sammelt alle Abnahme-Reports unter <Stick>\Logs\<ServiceTag>\, die noch
    keine .sent-Markierung haben, und sendet sie an den ReportRecipient aus dem
    verschlüsselten Secrets-Blob des Sticks:
      1. bevorzugt über Microsoft Graph /me/sendMail (SSO des Technikers)
         -> kein Outlook-Sicherheitsprompt, ein Login pro Sitzung
      2. Fallback: lokales klassisches Outlook (COM) - Absender = Techniker
         -> Outlook zeigt hier pro Mail die Sicherheitsabfrage
            "Ein Programm versucht, in Ihrem Auftrag eine E-Mail zu senden"
            (Object Model Guard). Das ist erwartetes Verhalten: Zulassen klicken.
    Pro versendeter Datei wird <Report>.sent geschrieben.
.NOTES
    HEPHAISTOS v1.2.0 - portiert aus USB_ScriptTool Rev05 (Send-QueuedReports.ps1 Rev04).
    PowerShell 5.1. UTF-8 mit BOM.
    Beibehaltene Rev04-Logik:
      - Versandreihenfolge: Graph zuerst, Outlook-COM nur als Fallback.
        Grund: Der COM-Weg ($m.Send()) triggert den Outlook Object Model Guard
        (Sicherheitsprompt mit 5-Sekunden-Timer, PRO Mail). Graph kennt den nicht.
      - Graph-Ausfall wird gemerkt ($graphBroken): schlägt Graph einmal fehl,
        wird für den Rest des Laufs direkt Outlook genutzt statt bei jedem
        Report erneut Connect-MgGraph/Login-Prompts auszulösen.
    Änderung HEPHAISTOS (Handoff §7.4): $ReportRecipient steht nicht mehr im
    Script-Kopf, sondern kommt aus dem verschlüsselten Secrets-Blob auf dem
    Stick (eine Quelle für Abnahme UND Versand) - Passphrase-Abfrage beim Start.
#>

$ErrorActionPreference = 'Stop'

# --- HEPHAISTOS Lib-Bootstrap (identisch in allen Entry-Scripts) ---
$Script:HephVersion = '1.2.0'
$Script:HephRawBase = 'https://raw.githubusercontent.com/Himerys/HEPHAISTOS/main'
# FallbackRoots für die Send-Phase: das Script kann aus der Stick-Spiegelkopie
# (<Stick>:\_HEPHAISTOS\Fallback\send\) laufen -> Wurzel relativ zum Script;
# zusätzlich alle Sticks via Minimal-Suche (DriveInfo, wie in der Boot-Phase).
$Script:HephFallbackRoots = @()
$relRoot = Split-Path -Parent $PSScriptRoot   # ..\ = _HEPHAISTOS\Fallback (Stick-Kopie) bzw. Repo-Checkout
if ($relRoot -and (Test-Path (Join-Path $relRoot 'lib\Hephaistos.Common.ps1'))) {
    $Script:HephFallbackRoots += $relRoot
}
foreach ($drv in [IO.DriveInfo]::GetDrives()) {
    try {
        if ($drv.IsReady -and (Test-Path (Join-Path $drv.RootDirectory.FullName '_HEPHAISTOS'))) {
            $Script:HephFallbackRoots += (Join-Path $drv.RootDirectory.FullName '_HEPHAISTOS\Fallback')
        }
    } catch { }
}
# 1) TLS12 aktivieren, 2) versuche Download lib/Hephaistos.Common.ps1 -> TEMP,
# 3) sonst erste existierende Fallback-Kopie, 4) Dot-Source; 5) Fehler -> rote
# Meldung + exit 1. Quelle in $Script:HephLibSource merken (fürs Banner).
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$libPath = $null
try {
    $tmp = Join-Path $env:TEMP 'HEPHAISTOS\lib'
    $null = New-Item -Path $tmp -ItemType Directory -Force
    $libPath = Join-Path $tmp 'Hephaistos.Common.ps1'
    Invoke-WebRequest -UseBasicParsing -Uri ($Script:HephRawBase + '/lib/Hephaistos.Common.ps1') -OutFile $libPath
    $Script:HephLibSource = 'GitHub: ' + $Script:HephRawBase
} catch {
    $libPath = $null
    foreach ($root in $Script:HephFallbackRoots) {
        $cand = Join-Path $root 'lib\Hephaistos.Common.ps1'
        if (Test-Path $cand) {
            $libPath = $cand
            $Script:HephLibSource = 'lokale Kopie: ' + $cand
            Write-Host ('OFFLINE-FALLBACK: nutze lokale Lib-Kopie {0}, Stand {1:yyyy-MM-dd HH:mm}' -f $cand, (Get-Item $cand).LastWriteTime) -ForegroundColor Yellow
            break
        }
    }
}
if (-not $libPath) {
    Write-Host 'FEHLER: lib/Hephaistos.Common.ps1 weder von GitHub noch als lokale Kopie verfügbar.' -ForegroundColor Red
    exit 1
}
. $libPath
# --- Ende Lib-Bootstrap ---

Write-HephBanner -Title 'HEPHAISTOS - Report-Versand' -Version $Script:HephVersion -Source $Script:HephLibSource -Env 'Techniker-PC'

# Stick suchen: bevorzugt Marker-Suche (_HEPHAISTOS), sonst Laufwerkswurzel des
# Scripts (das Original nahm stur die eigene Laufwerkswurzel - dieses Script
# kann jetzt aber auch aus dem TEMP-Download von SEND-REPORTS.cmd laufen).
$UsbRoot = Find-HephaistosUsb
if (-not $UsbRoot) {
    $selfRoot = [IO.Path]::GetPathRoot((Split-Path -Parent $PSCommandPath))
    if ($selfRoot -and (Test-Path (Join-Path $selfRoot '_HEPHAISTOS'))) { $UsbRoot = $selfRoot }
}
if (-not $UsbRoot) {
    Write-HephErr 'FEHLER: Kein HEPHAISTOS-Stick gefunden (Marker-Ordner _HEPHAISTOS fehlt auf allen Laufwerken).'
    exit 1
}
Write-HephDim ('Stick: {0}' -f $UsbRoot)

# Empfänger aus dem verschlüsselten Secrets-Blob (Handoff §7.4: eine Quelle,
# kein doppelt gepflegter Script-Kopf mehr). Passphrase wird bis zu 3x abgefragt.
$SecretsPath = Join-Path $UsbRoot 'HEPHAISTOS-Secrets\hephaistos.secrets.enc.json'
$secrets = Get-HephaistosSecrets -Path $SecretsPath
if (-not $secrets) {
    Write-HephErr ('FEHLER: Secrets-Blob nicht vorhanden oder nicht entschlüsselbar: {0}' -f $SecretsPath)
    Write-HephErr 'Blob mit tools\New-HephaistosSecrets.ps1 erzeugen bzw. Passphrase prüfen.'
    exit 1
}
$ReportRecipient = $secrets.ReportRecipient
if (-not $ReportRecipient) {
    Write-HephErr 'FEHLER: ReportRecipient fehlt im Secrets-Blob (tools\New-HephaistosSecrets.ps1 erneut ausführen).'
    exit 1
}

$LogRoot = Join-Path $UsbRoot 'Logs'
if (-not (Test-Path $LogRoot)) { Write-Host 'Keine Logs auf dem Stick gefunden.' -ForegroundColor Yellow; exit 0 }

# Offene Reports einsammeln: bevorzugt PDF, sonst HTML - jeweils ohne .sent-Marker
$pending = @()
foreach ($dev in Get-ChildItem -Path $LogRoot -Directory) {
    $files = Get-ChildItem -Path $dev.FullName -File | Where-Object {
        $_.Name -like 'Onboarding-Report_*.pdf' -or $_.Name -like 'Onboarding-Report_*.html'
    }
    # pro Basisname nur eine Variante (PDF schlägt HTML)
    $byBase = $files | Group-Object { [IO.Path]::GetFileNameWithoutExtension($_.Name) }
    foreach ($g in $byBase) {
        $f = ($g.Group | Sort-Object { $_.Extension -ne '.pdf' } | Select-Object -First 1)
        if (-not (Test-Path ($f.FullName + '.sent'))) { $pending += $f }
    }
}
if (-not $pending) { Write-Host 'Alles bereits versendet - nichts zu tun.' -ForegroundColor Green; exit 0 }
Write-Host ('{0} offene Report(s) gefunden.' -f $pending.Count) -ForegroundColor Cyan
Write-HephPhase -Title ('Versand an {0}' -f $ReportRecipient) -EstimatedDuration 'wenige Sekunden pro Report; beim ersten Graph-Lauf einmalige Anmeldung'

function Send-ViaOutlook {
    param($File, [string]$Subject)
    $ol = New-Object -ComObject Outlook.Application
    $m = $ol.CreateItem(0)
    $m.To = $ReportRecipient
    $m.Subject = $Subject
    $m.Body = "Abnahme-Report im Anhang (automatischer Versand vom Onboarding-Stick).`r`nDatei: $($File.Name)"
    $null = $m.Attachments.Add($File.FullName)
    $m.Send()
}

$graphReady  = $false
$graphBroken = $false
function Send-ViaGraph {
    param($File, [string]$Subject)
    if (-not $script:graphReady) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        if (-not (Get-Module -ListAvailable Microsoft.Graph.Authentication)) {
            Write-Host 'Microsoft.Graph.Authentication wird installiert (einmalig) ...' -ForegroundColor DarkGray
            Install-Module Microsoft.Graph.Authentication -Force -Scope CurrentUser
        }
        Import-Module Microsoft.Graph.Authentication
        Connect-MgGraph -Scopes 'Mail.Send' -NoWelcome
        $script:graphReady = $true
    }
    $body = @{
        message = @{
            subject      = $Subject
            body         = @{ contentType = 'Text'; content = "Abnahme-Report im Anhang (automatischer Versand vom Onboarding-Stick). Datei: $($File.Name)" }
            toRecipients = @(@{ emailAddress = @{ address = $ReportRecipient } })
            attachments  = @(@{
                '@odata.type' = '#microsoft.graph.fileAttachment'
                name          = $File.Name
                contentBytes  = [Convert]::ToBase64String([IO.File]::ReadAllBytes($File.FullName))
            })
        }
        saveToSentItems = $true
    } | ConvertTo-Json -Depth 8
    Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/me/sendMail' -Body $body -ContentType 'application/json'
}

$ok = 0; $fail = 0
foreach ($f in $pending) {
    $serial = Split-Path (Split-Path $f.FullName -Parent) -Leaf
    $subject = "SLG Onboarding-Report {0} - {1}" -f $serial, [IO.Path]::GetFileNameWithoutExtension($f.Name)
    try {
        $sent = $false
        if (-not $graphBroken) {
            try {
                Send-ViaGraph -File $f -Subject $subject
                $sent = $true
            } catch {
                $script:graphBroken = $true
                Write-Host ('Graph-Versand nicht möglich ({0})' -f $_.Exception.Message) -ForegroundColor DarkGray
                Write-Host 'Wechsle auf klassisches Outlook (COM). Outlook fragt ggf. pro Mail nach - "Zulassen" klicken.' -ForegroundColor Yellow
            }
        }
        if (-not $sent) { Send-ViaOutlook -File $f -Subject $subject }
        Get-Date -Format 'yyyy-MM-dd HH:mm' | Set-Content -Path ($f.FullName + '.sent') -Encoding ASCII
        Write-Host ('  gesendet: {0}' -f $f.Name) -ForegroundColor Green
        $ok++
    } catch {
        Write-Host ('  FEHLER bei {0}: {1}' -f $f.Name, $_.Exception.Message) -ForegroundColor Red
        $fail++
    }
}
Write-Host ''
Write-HephResult -Success (-not $fail) -Text ('Fertig: {0} gesendet, {1} fehlgeschlagen.' -f $ok, $fail)
