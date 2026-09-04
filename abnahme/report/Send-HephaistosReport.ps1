<#
.SYNOPSIS
    HEPHAISTOS - Abnahme-Report per Mail versenden (Graph, Port von Send-SLGReport).
.DESCRIPTION
    Wird von abnahme/Test-HephaistosDevice.ps1 per Dot-Sourcing geladen und
    definiert ausschließlich die Funktion Send-HephaistosReport. Änderungen
    gegenüber dem Original:
      - Empfänger, MailSender und App-Zugangsdaten kommen als -Secrets-Objekt
        (entschlüsselter Blob: TenantId, AppId, AppSecret, ReportRecipient,
        MailSender) - der ReportRecipient wird damit nur noch an EINER Stelle
        gepflegt (Bugfix Handoff 7.4, vorher doppelt in zwei Scripts).
      - Serial/Model kommen als Parameter statt aus Script-Variablen.
    Benötigt die geladene Lib (Test-HephInternet, Get-GraphAppToken,
    Enable-Tls12AndGallery).
.NOTES
    HEPHAISTOS v1.3.1 - portiert aus USB_ScriptTool Rev05 (_SLG\SLG-Onboarding.ps1).
    Benötigt PowerShell 5.1. Datei ist UTF-8 MIT BOM gespeichert (Pflicht für PS 5.1 + Umlaute).
#>

function Send-HephaistosReport {
    param(
        [object]$Secrets,
        [string]$AttachmentPath,
        [string]$ResultState = 'FAILED',
        [string]$Serial,
        [string]$Model
    )
    try {
        if (-not $Secrets -or -not $Secrets.ReportRecipient) {
            Write-Host 'Kein ReportRecipient in den Secrets hinterlegt - Mailversand übersprungen.' -ForegroundColor Yellow
            return
        }
        if (-not (Test-HephInternet)) { throw 'Kein Internetzugriff.' }
        $state = $ResultState
        $msg = @{
            message = @{
                subject      = ("SLG Onboarding {0} - {1} ({2})" -f $state, $env:COMPUTERNAME, $Serial)
                body         = @{ contentType = 'Text'; content = ("Abnahme-Report im Anhang. Gerät: {0} / {1} - Ergebnis: {2}" -f $Model, $Serial, $state) }
                toRecipients = @(@{ emailAddress = @{ address = $Secrets.ReportRecipient } })
                attachments  = @(@{
                    '@odata.type' = '#microsoft.graph.fileAttachment'
                    name          = [IO.Path]::GetFileName($AttachmentPath)
                    contentBytes  = [Convert]::ToBase64String([IO.File]::ReadAllBytes($AttachmentPath))
                })
            }
            saveToSentItems = $true
        } | ConvertTo-Json -Depth 8
        # RESERVIERT (Handoff 7.6): App-Versand über ein festes Absender-Postfach
        # (Secrets.MailSender) - nur wenn ein Postfach hinterlegt ist UND die App
        # Mail.Send inkl. Exchange-Scope besitzt. Der Zweig ist derzeit ungenutzt
        # (MailSender wird in den Secrets nicht gepflegt), bleibt aber als
        # vorbereitete Option erhalten. Standardfall ohne Exchange-Regel:
        # der angemeldete Techniker sendet selbst via /me/sendMail.
        $sent = $false
        if ($Secrets.MailSender) {
            try {
                $tok = Get-GraphAppToken -Cfg $Secrets
                $uri = "https://graph.microsoft.com/v1.0/users/{0}/sendMail" -f $Secrets.MailSender
                Invoke-RestMethod -Method POST -Uri $uri -Headers @{ Authorization = "Bearer $tok" } -Body $msg -ContentType 'application/json; charset=utf-8'
                $sent = $true
            } catch {
                Write-Host 'App-Versand nicht möglich (Mail.Send fehlt oder kein Scope) - wechsle auf persönliche Anmeldung.' -ForegroundColor DarkGray
            }
        }
        if (-not $sent) {
            Enable-Tls12AndGallery
            if (-not (Get-Module -ListAvailable Microsoft.Graph.Authentication)) {
                Write-Host 'Microsoft.Graph.Authentication wird installiert (einmalig) ...' -ForegroundColor DarkGray
                Install-Module Microsoft.Graph.Authentication -Force -Scope CurrentUser
            }
            Import-Module Microsoft.Graph.Authentication
            Connect-MgGraph -Scopes 'Mail.Send' -NoWelcome
            Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/me/sendMail' -Body $msg -ContentType 'application/json'
        }
        Write-Host ("Mail an {0} gesendet." -f $Secrets.ReportRecipient) -ForegroundColor Green
    } catch {
        Write-Host ("Mailversand fehlgeschlagen: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
        Write-Host 'Report liegt weiterhin im Geräteordner.' -ForegroundColor Yellow
    }
}
