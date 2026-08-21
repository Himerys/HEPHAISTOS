<#
.SYNOPSIS
    HEPHAISTOS - HTML-Report nach PDF konvertieren (Edge headless).
.DESCRIPTION
    Wird von abnahme/Test-HephaistosDevice.ps1 per Dot-Sourcing geladen und
    definiert die Funktion Convert-HtmlToPdf sowie den kleinen Helfer
    Format-ProcessArg. Läuft nur im Vollwindows (best effort) - fehlt Edge,
    wird still $null zurückgegeben und der HTML-Report bleibt das Ergebnis.
    Änderung gegenüber dem Original (Bugfix Handoff 7.5): Das frühere
    '--print-to-pdf="{0}"' bettete Anführungszeichen IN den Argumentwert ein
    und zerbrach damit bei Pfaden mit Leerzeichen. Jetzt werden die Argumente
    ohne eingebettete Quotes aufgebaut und Elemente mit Whitespace komplett
    in Anführungszeichen gewrappt (Format-ProcessArg).
.NOTES
    HEPHAISTOS v1.2.1 - portiert aus USB_ScriptTool Rev05 (_SLG\SLG-Onboarding.ps1).
    Benötigt PowerShell 5.1. Datei ist UTF-8 MIT BOM gespeichert (Pflicht für PS 5.1 + Umlaute).
#>

function Format-ProcessArg {
    param([string]$Arg)
    # ACHTUNG: Start-Process unter PS 5.1 fügt die -ArgumentList-Elemente nur
    # mit Leerzeichen zusammen und quotet NICHT selbst (anders als PS 7).
    # Elemente mit Whitespace müssen deshalb komplett in "..." gewrappt werden,
    # sonst zerfällt z.B. ein PDF-Pfad mit Leerzeichen in mehrere Argumente.
    if ($Arg -match '\s') { return ('"{0}"' -f $Arg) }
    return $Arg
}

function Convert-HtmlToPdf {
    param([string]$HtmlPath)
    $edge = @(
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $edge) { return $null }
    $pdf = [IO.Path]::ChangeExtension($HtmlPath, '.pdf')
    $uri = ([Uri]$HtmlPath).AbsoluteUri
    try {
        Write-Progress -Activity 'PDF-Erzeugung' -Status 'Microsoft Edge (headless) druckt den Report ...'
        # Quoting-Fix (Handoff 7.5): keine Anführungszeichen im Wert einbetten;
        # stattdessen jedes Element bei Bedarf via Format-ProcessArg wrappen.
        # OFFENER PUNKT: mit einem Leerzeichen-Pfad auf echter Hardware testen.
        $argList = @(
            '--headless', '--disable-gpu', '--no-first-run',
            ('--print-to-pdf={0}' -f $pdf), $uri
        ) | ForEach-Object { Format-ProcessArg -Arg $_ }
        Start-Process -FilePath $edge -ArgumentList $argList -Wait -WindowStyle Hidden
        if (Test-Path $pdf) { return $pdf }
    } catch {
    } finally {
        Write-Progress -Activity 'PDF-Erzeugung' -Completed
    }
    return $null
}
