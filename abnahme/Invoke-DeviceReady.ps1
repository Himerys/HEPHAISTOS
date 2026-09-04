<#
.SYNOPSIS
    HEPHAISTOS - Device-Ready-Melder (geplante Aufgabe, läuft als SYSTEM).
.DESCRIPTION
    Wird von der OOBE-Phase als geplante Aufgabe 'HEPHAISTOS-DeviceReady'
    registriert (Trigger: beim Systemstart, verzögert; deploy.json
    Abnahme.ReadyMessage) und postet EINMALIG eine Teams-Karte "Gerät fertig -
    bitte anmelden", sobald das Gerät nach dem Reseal am Anmeldebildschirm
    steht. Erkennung pro Systemstart (alles Heuristiken, deshalb mehrfach
    abgesichert):
      1. Gerät ist in Intune enrolled (Registry: Enrollments, MS DM Server)
         UND die Intune Management Extension ist installiert
      2. es existiert noch KEIN echtes Benutzerprofil (erste Anmeldung offen)
      3. niemand ist interaktiv angemeldet - auch nach 60 s Kontrollpause
         nicht (während des ESP ist defaultuser0 binnen Sekunden automatisch
         angemeldet; die Provisioning-Zwischenboots fallen damit durch)
    Ist ein regulärer Benutzer angemeldet oder hat sich je angemeldet, ist die
    Karte überflüssig - die Aufgabe entfernt sich dann still selbst.
    Webhook-Quelle: der DPAPI-Geräte-Cache aus der OOBE-Phase (v1.2.1) - keine
    Passphrase, kein Stick, keine zusätzlichen Graph-Berechtigungen nötig.
    Läuft unsichtbar als SYSTEM; Protokoll: C:\OSDCloud\HEPHAISTOS\deviceready.log
    Bewusst OHNE Lib-Abhängigkeit (selbsttragend), damit die Aufgabe nie crasht.
.NOTES
    HEPHAISTOS v1.3.1. PowerShell 5.1. UTF-8 mit BOM.
#>
$ErrorActionPreference = 'Stop'
$TaskName = 'HEPHAISTOS-DeviceReady'
$LogFile  = 'C:\OSDCloud\HEPHAISTOS\deviceready.log'
$DoneFlag = 'C:\OSDCloud\HEPHAISTOS\deviceready.done'
$HookBin  = 'C:\OSDCloud\HEPHAISTOS\teams.webhook.bin'

function Write-DrLog {
    param([string]$Text)
    try { ('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Text) | Add-Content -Path $LogFile -Encoding UTF8 } catch { }
}
function Remove-OwnTask {
    try { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false } catch { }
}
function Get-ConsoleUser {
    try { return [string](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).UserName } catch { return $null }
}

Write-DrLog '--- Device-Ready-Lauf gestartet ---'

# --- Schon erledigt? ---
if (Test-Path $DoneFlag) {
    Write-DrLog 'Karte wurde bereits gepostet - Aufgabe entfernt sich selbst.'
    Remove-OwnTask
    exit 0
}

# --- Zu spät? Reguläre Anmeldung aktiv ODER es gab schon eine (Profil da) ---
$consoleUser = Get-ConsoleUser
if ($consoleUser -and ($consoleUser -notmatch 'defaultuser\d+')) {
    Write-DrLog ('Regulärer Benutzer bereits angemeldet ({0}) - Karte überflüssig, Aufgabe entfernt sich selbst.' -f $consoleUser)
    Set-Content -Path $DoneFlag -Value 'obsolet: Benutzer war schneller' -Encoding UTF8
    Remove-OwnTask
    exit 0
}
# defaultuser\d+ (Review): Windows legt je nach Build/Ablauf auch defaultuser1/
# defaultuser100000 an - die dürfen nicht als "echtes" Profil zählen.
$realProfiles = @()
try {
    $realProfiles = @(Get-CimInstance Win32_UserProfile -ErrorAction Stop | Where-Object {
        (-not $_.Special) -and ($_.LocalPath -notmatch '\\defaultuser\d+$') -and ($_.LocalPath -notmatch '\\WDAGUtilityAccount$')
    })
} catch { }
if ($realProfiles.Count -gt 0) {
    Write-DrLog ('Es existiert bereits ein Benutzerprofil ({0}) - Karte überflüssig, Aufgabe entfernt sich selbst.' -f $realProfiles[0].LocalPath)
    Set-Content -Path $DoneFlag -Value 'obsolet: Benutzerprofil vorhanden' -Encoding UTF8
    Remove-OwnTask
    exit 0
}

# --- Provisioning noch aktiv? (defaultuser* angemeldet = ESP läuft) ---
if ($consoleUser -match 'defaultuser\d+') {
    Write-DrLog 'defaultuser0 ist angemeldet (ESP/OOBE läuft) - warte auf den nächsten Systemstart.'
    exit 0
}

# --- Setup wirklich durch? Enrollment + Intune Management Extension ---
$enrolled = $false
try {
    foreach ($k in @(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Enrollments' -ErrorAction Stop)) {
        $p = Get-ItemProperty -Path $k.PSPath -ErrorAction SilentlyContinue
        if ($p -and ($p.ProviderID -eq 'MS DM Server')) { $enrolled = $true; break }
    }
} catch { }
if (-not $enrolled) {
    Write-DrLog 'Noch kein Intune-Enrollment gefunden - Provisioning läuft vermutlich noch.'
    exit 0
}
if (-not (Get-Service -Name 'IntuneManagementExtension' -ErrorAction SilentlyContinue)) {
    Write-DrLog 'IntuneManagementExtension fehlt noch - Provisioning läuft vermutlich noch.'
    exit 0
}

# --- Kontrollpause gegen Zwischenboot-Fenster: Beim ESP meldet sich
#     defaultuser0 binnen Sekunden automatisch an. Bleibt es auch nach 60 s
#     bei "niemand angemeldet", steht das Gerät am Anmeldebildschirm. ---
Start-Sleep -Seconds 60
$consoleUser = Get-ConsoleUser
if ($consoleUser) {
    if ($consoleUser -match 'defaultuser\d+') {
        Write-DrLog 'defaultuser0 hat sich während der Kontrollpause angemeldet (ESP) - nächster Systemstart.'
        exit 0
    }
    Write-DrLog ('Benutzer hat sich während der Kontrollpause angemeldet ({0}) - Karte überflüssig, Aufgabe entfernt sich selbst.' -f $consoleUser)
    Set-Content -Path $DoneFlag -Value 'obsolet: Benutzer war schneller' -Encoding UTF8
    Remove-OwnTask
    exit 0
}

# --- Webhook aus dem DPAPI-Geräte-Cache (v1.2.1, Machine-Scope) ---
$webhook = $null
try {
    if (Test-Path $HookBin) {
        Add-Type -AssemblyName System.Security
        $entropy = [Text.Encoding]::UTF8.GetBytes('HEPHAISTOS.TeamsWebhook.v1')
        $plain = [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($HookBin), $entropy, [Security.Cryptography.DataProtectionScope]::LocalMachine)
        $webhook = [Text.Encoding]::UTF8.GetString($plain)
    }
} catch { $webhook = $null }
if (-not $webhook) {
    # Ohne Cache wird es auch bei künftigen Starts keinen geben (er entsteht
    # nur in der OOBE-Phase) - Aufgabe beendet sich dauerhaft statt zu spuken.
    Write-DrLog 'Kein Teams-Webhook-Cache vorhanden - Meldung entfällt, Aufgabe entfernt sich selbst.'
    Set-Content -Path $DoneFlag -Value 'entfallen: kein Webhook-Cache' -Encoding UTF8
    Remove-OwnTask
    exit 0
}

# --- Gerätedaten + Karte ---
$serial = ''; $model = ''
try { $serial = ([string](Get-CimInstance Win32_BIOS -ErrorAction Stop).SerialNumber).Trim() } catch { }
try { $model  = ([string](Get-CimInstance Win32_ComputerSystemProduct -ErrorAction Stop).Name).Trim() } catch { }
if (-not $model) { $model = 'Unbekanntes Modell' }

$card = @{
    type      = 'AdaptiveCard'
    version   = '1.4'
    '$schema' = 'http://adaptivecards.io/schemas/adaptive-card.json'
    msteams   = @{ width = 'Full' }
    body      = @(
        @{ type = 'Container'; style = 'accent'; bleed = $true; items = @(
            @{ type = 'TextBlock'; text = 'SLG NOTEBOOK-ONBOARDING'; size = 'Small'; weight = 'Bolder'; isSubtle = $true },
            @{ type = 'TextBlock'; text = ([string][char]0x2705 + '  GERÄT FERTIG EINGERICHTET'); size = 'ExtraLarge'; weight = 'Bolder'; wrap = $true }
        ) },
        @{ type = 'FactSet'; spacing = 'Medium'; facts = @(
            @{ title = 'Hostname';    value = $env:COMPUTERNAME },
            @{ title = 'Gerät';       value = $model },
            @{ title = 'Service Tag'; value = $serial },
            @{ title = 'Zeit';        value = (Get-Date -Format 'dd.MM.yyyy HH:mm') }
        ) },
        @{ type = 'TextBlock'; wrap = $true; spacing = 'Medium'
           text = 'Das Gerät steht am Anmeldebildschirm. Bitte anmelden, um die Abnahme zu starten - das lokale Administratorkennwort (LAPS) steht in Intune beim Gerät unter "Lokales Administratorkennwort".' }
    )
    actions   = @(@{ type = 'Action.OpenUrl'; title = 'Intune: Geräteliste öffnen (Service Tag suchen)'
                     url = 'https://intune.microsoft.com/#view/Microsoft_Intune_DeviceSettings/DevicesMenu/~/allDevices' })
}
$payload = @{ type = 'message'; attachments = @(@{
    contentType = 'application/vnd.microsoft.card.adaptive'
    contentUrl  = $null
    content     = $card
}) } | ConvertTo-Json -Depth 14

# Retry im selben Lauf (Review): Am finalen Anmeldebildschirm gibt es evtl.
# keinen weiteren Systemstart mehr - ein transienter Netzfehler (WLAN/NCSI
# noch nicht bereit) darf die Karte nicht dauerhaft kosten.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 } catch { }
$posted = $false
for ($try = 1; $try -le 3; $try++) {
    try {
        Invoke-RestMethod -Method POST -Uri $webhook `
            -Body ([Text.Encoding]::UTF8.GetBytes($payload)) -ContentType 'application/json; charset=utf-8' | Out-Null
        $posted = $true
        break
    } catch {
        Write-DrLog ('Teams-Posting fehlgeschlagen (Versuch {0}/3: {1}).' -f $try, $_.Exception.Message)
        if ($try -lt 3) { Start-Sleep -Seconds 60 }
    }
}
if ($posted) {
    Set-Content -Path $DoneFlag -Value ('gepostet {0:yyyy-MM-dd HH:mm:ss}' -f (Get-Date)) -Encoding UTF8
    Write-DrLog 'Device-Ready-Karte gepostet - Aufgabe entfernt sich selbst.'
    Remove-OwnTask
} else {
    Write-DrLog 'Alle 3 Versuche fehlgeschlagen - neuer Versuch beim nächsten Systemstart.'
}
exit 0
