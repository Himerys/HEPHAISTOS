<#
.SYNOPSIS
    HEPHAISTOS - Teams-Benachrichtigung (AdaptiveCard via Workflows-Webhook).
.DESCRIPTION
    Wird von abnahme/Test-HephaistosDevice.ps1 per Dot-Sourcing geladen und
    definiert ausschließlich die Funktion Send-TeamsCard. Die Karte selbst
    (AdaptiveCard 1.4, FactSet, {{FILEURL}}-Button) ist 1:1 aus
    SLG-Onboarding.ps1 (Rev05) übernommen. Änderungen:
      - Webhook-URL und AttachPdf-Schalter kommen als Parameter
        (Webhook aus dem verschlüsselten Secrets-Blob, AttachPdf aus
        deploy.json Report.TeamsAttachPdf) - kein $Config-Zugriff mehr.
      - Serial/Model kommen als Parameter statt aus Script-Variablen.
    WICHTIG: Das Payload-Feld 'slg' (Dateiname + base64 + Status) bleibt
    BEWUSST 'slg' - der bestehende Power-Automate-Flow parst genau dieses
    Feld (Flow-Kompatibilität, NICHT in 'hephaistos' umbenennen).
.NOTES
    HEPHAISTOS v1.0.4 - portiert aus USB_ScriptTool Rev05 (_SLG\SLG-Onboarding.ps1).
    Benötigt PowerShell 5.1. Datei ist UTF-8 MIT BOM gespeichert (Pflicht für PS 5.1 + Umlaute).
#>

function Send-TeamsCard {
    param(
        # Teams: Power-Automate-Flow mit HTTP-Trigger (Premium) ODER Workflows-Webhook.
        # Leer = kein Teams-Posting. URL wie ein Secret behandeln (wer sie hat, kann posten).
        [string]$WebhookUrl,
        # $true = PDF wird base64 im Payload mitgesendet + Karte bekommt einen
        # "Report öffnen"-Button ({{FILEURL}}-Platzhalter, den der Flow ersetzt).
        # NUR mit dem Premium-Flow nutzen - das simple Webhook-Template kann das nicht.
        [bool]$AttachPdf = $true,
        [string]$ResultState,
        [string]$ReportName,
        [string]$Serial,
        [string]$Model,
        [string]$Technician = '',
        [string]$PrimaryUser = '',
        [string]$AttachmentPath = ''
    )
    if (-not $WebhookUrl) { return }
    try {
        if (-not $PrimaryUser) { $PrimaryUser = 'unbekannt' }
        if (-not $Technician)  { $Technician  = $env:USERNAME }
        $stateText = switch ($ResultState) {
            'SUCCESS'               { 'BESTANDEN' }
            'SUCCESS_WITH_WARNINGS' { 'BESTANDEN - MIT HINWEISEN' }
            default                 { 'NICHT BESTANDEN' }
        }
        $stateColor = switch ($ResultState) {
            'SUCCESS'               { 'Good' }
            'SUCCESS_WITH_WARNINGS' { 'Warning' }
            default                 { 'Attention' }
        }
        $contStyle = switch ($ResultState) {
            'SUCCESS'               { 'good' }
            'SUCCESS_WITH_WARNINGS' { 'warning' }
            default                 { 'attention' }
        }
        $icon = switch ($ResultState) {
            'SUCCESS'               { [char]0x2714 }   # Haken
            'SUCCESS_WITH_WARNINGS' { [char]0x26A0 }   # Warndreieck
            default                 { [char]0x2716 }   # Kreuz
        }
        $card = @{
            type      = 'AdaptiveCard'
            version   = '1.4'
            '$schema' = 'http://adaptivecards.io/schemas/adaptive-card.json'
            msteams   = @{ width = 'Full' }
            body      = @(
                @{ type = 'Container'; style = $contStyle; bleed = $true; items = @(
                    @{ type = 'TextBlock'; text = 'SLG NOTEBOOK-ONBOARDING'; size = 'Small'; weight = 'Bolder'; isSubtle = $true },
                    @{ type = 'TextBlock'; text = ('{0}  {1}' -f $icon, $stateText); size = 'ExtraLarge'; weight = 'Bolder'; color = $stateColor; wrap = $true }
                ) },
                @{ type = 'FactSet'; spacing = 'Medium'; facts = @(
                    @{ title = 'Gerät';          value = $Model },
                    @{ title = 'Service Tag';    value = $Serial },
                    @{ title = 'Hostname';       value = $env:COMPUTERNAME },
                    @{ title = 'Prim. Benutzer'; value = $PrimaryUser },
                    @{ title = 'Techniker';      value = $Technician },
                    @{ title = 'Zeit';           value = (Get-Date -Format 'dd.MM.yyyy HH:mm') }
                ) },
                @{ type = 'TextBlock'; wrap = $true; isSubtle = $true; size = 'Small'; spacing = 'Medium'
                   text = ('Detail-Report (PDF): {0} - Versand per Mail über SEND-REPORTS, Ablage im Geräteordner des Sticks.' -f $ReportName) }
            )
        }
        # PDF anhaengen: base64 im Payload + Button mit {{FILEURL}}-Platzhalter,
        # den der Power-Automate-Flow nach dem SharePoint-Upload ersetzt.
        $attachFile = ($AttachPdf -and $AttachmentPath -and (Test-Path $AttachmentPath))
        if ($attachFile) {
            $card.actions = @(@{ type = 'Action.OpenUrl'; title = 'Report (PDF) öffnen'; url = '{{FILEURL}}' })
        }
        $payloadObj = @{ type = 'message'; attachments = @(@{
            contentType = 'application/vnd.microsoft.card.adaptive'
            contentUrl  = $null
            content     = $card
        }) }
        if ($attachFile) {
            # Feldname 'slg' beibehalten - der bestehende Flow erwartet genau diesen Key!
            $payloadObj.slg = @{
                fileName          = [IO.Path]::GetFileName($AttachmentPath)
                fileContentBase64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($AttachmentPath))
                state             = $ResultState
                serial            = $Serial
            }
        }
        $payload = $payloadObj | ConvertTo-Json -Depth 14
        Invoke-RestMethod -Method POST -Uri $WebhookUrl `
            -Body ([Text.Encoding]::UTF8.GetBytes($payload)) -ContentType 'application/json; charset=utf-8' | Out-Null
        Write-Host 'Teams-Benachrichtigung gepostet.' -ForegroundColor Green
    } catch {
        Write-Host ('Teams-Posting fehlgeschlagen: {0}' -f $_.Exception.Message) -ForegroundColor Yellow
    }
}
