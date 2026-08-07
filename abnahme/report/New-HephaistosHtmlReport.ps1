<#
.SYNOPSIS
    HEPHAISTOS - HTML-Abnahme-Report (Port von New-SLGHtmlReport).
.DESCRIPTION
    Wird von abnahme/Test-HephaistosDevice.ps1 per Dot-Sourcing geladen und
    definiert ausschließlich die Funktion New-HephaistosHtmlReport.
    CSS und Layout stammen 1:1 aus SLG-Onboarding.ps1 (Rev05). Änderungen:
      - Schritt-Tabelle in der neuen Ablauf-Reihenfolge (Installation, BIOS,
        Hash, Abnahme) - die Flag-Dateinamen bleiben aus Kontinuitätsgründen
        unverändert (step1_bios.done usw.).
      - Versionsstring zentral aus $HephaistosVersion (Lib): Header-Sub und
        Footer zeigen damit IMMER dieselbe Version (Fix: im Original stand im
        Footer Rev04, im Header Rev05).
      - Gerätedaten kommen als Parameter - kein Zugriff mehr auf die
        Script-Variablen des alten Menüscripts.
.NOTES
    HEPHAISTOS v1.0.0 - portiert aus USB_ScriptTool Rev05 (_SLG\SLG-Onboarding.ps1).
    Benötigt PowerShell 5.1. Datei ist UTF-8 MIT BOM gespeichert (Pflicht für PS 5.1 + Umlaute).
#>

function New-HephaistosHtmlReport {
    param(
        [string]$TestReportFile,
        [string]$ResultState = 'FAILED',
        [string]$Technician = $env:USERNAME,
        [string]$PrimaryUser = 'unbekannt',
        [string]$DevDir,
        [string]$StateDir,
        [string]$Serial,
        [string]$Model
    )
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm'
    $os    = Get-CimInstance Win32_OperatingSystem

    # Versionsstring EINMAL aus der zentralen Lib-Konstante lesen -> Header und
    # Footer können nie mehr auseinanderlaufen (Kosmetik-Bug im Original).
    $ver = $HephaistosVersion

    # Schritt-Tabelle in der neuen Ablauf-Reihenfolge: erst Windows-Installation
    # (OSDCloud-Wipe), dann BIOS + Hash in der OOBE, zuletzt die Abnahme.
    # Die Flag-Namen bleiben die alten (NICHT umbenennen - Kontinuität).
    $steps = @(
        @{ N = 1; T = 'Windows-Installation';  F = 'step2_osinstall.done' },
        @{ N = 2; T = 'BIOS-Konfiguration';    F = 'step1_bios.done' },
        @{ N = 3; T = 'Autopilot-Hash';        F = 'step3_hash.done' },
        @{ N = 4; T = 'Abnahme-Pruefung';      F = 'step4_compliance.done' }
    )
    $stepRows = foreach ($s in $steps) {
        $flag = Get-StepFlag -StateDir $StateDir -Name $s.F
        if (Test-Path $flag) {
            $detail = [System.Net.WebUtility]::HtmlEncode((Get-Content $flag -Raw).Trim())
            "<tr><td class='num'>{0}</td><td>{1}</td><td><span class='pill p-pass'>erledigt</span></td><td class='detail'>{2}</td></tr>" -f $s.N, $s.T, $detail
        } else {
            "<tr><td class='num'>{0}</td><td>{1}</td><td><span class='pill p-skip'>offen</span></td><td class='detail'></td></tr>" -f $s.N, $s.T
        }
    }

    # Testresultate: bevorzugt strukturiert (JSON vom Testscript ab Rev03),
    # Fallback auf den rohen Textreport nur wenn keine JSON vorliegt.
    $sumLine = ''; $testRows = $null; $rawBlock = $null
    if ($TestReportFile -and (Test-Path $TestReportFile)) {
        $jsonPath = [IO.Path]::ChangeExtension($TestReportFile, '.json')
        if (Test-Path $jsonPath) {
            try {
                $data = Get-Content $jsonPath -Raw | ConvertFrom-Json
                $testRows = foreach ($t in $data.Results) {
                    $cls = switch ($t.Status) { 'PASSED' {'p-pass'} 'FAILED' {'p-fail'} 'WARN' {'p-warn'} 'SKIPPED' {'p-skip'} default {'p-info'} }
                    $rowCls = switch ($t.Status) { 'FAILED' { " class='fail-row'" } 'WARN' { " class='warn-row'" } default { '' } }
                    "<tr{0}><td class='num'>{1:00}</td><td>{2}</td><td><span class='pill {3}'>{4}</span></td><td class='detail'>{5}</td></tr>" -f $rowCls, [int]$t.Nr, [System.Net.WebUtility]::HtmlEncode([string]$t.Name), $cls, $t.Status, [System.Net.WebUtility]::HtmlEncode([string]$t.Detail)
                }
                $warnSpan = if ([int]$data.Summary.Warned -gt 0) { "<span class='c-warn'>$($data.Summary.Warned) WARN</span>" } else { '' }
                $sumLine = "<div class='counts'><span class='c-pass'>$($data.Summary.Passed) PASSED</span>$warnSpan<span class='c-fail'>$($data.Summary.Failed) FAILED</span><span class='c-dim'>von $($data.Summary.Total) Pflichttests (Testscript $($data.Rev))</span></div>"
            } catch { $testRows = $null }
        }
        if (-not $testRows) {
            $rawBlock = "<pre>{0}</pre>" -f [System.Net.WebUtility]::HtmlEncode((Get-Content $TestReportFile -Raw))
        }
    }
    $testBlock = if ($testRows) {
        "<h2>Abnahme-Tests</h2>`n$sumLine`n<table><tr><th class='num'>#</th><th>Test</th><th>Status</th><th>Details</th></tr>`n$($testRows -join "`n")`n</table>"
    } elseif ($rawBlock) {
        "<h2>Abnahme-Tests</h2>`n$rawBlock"
    } else { '<p>Kein Testreport vorhanden.</p>' }

    $badge = switch ($ResultState) {
        'SUCCESS'               { "<span class='badge pass'>SUCCESS</span>" }
        'SUCCESS_WITH_WARNINGS' { "<span class='badge warn'>SUCCESS &middot; MIT HINWEISEN</span>" }
        default                 { "<span class='badge fail'>FAILED</span>" }
    }

    $doc = @"
<!DOCTYPE html><html lang="de"><head><meta charset="utf-8">
<title>SLG Onboarding-Report $Serial</title>
<style>
 :root{--slg:#004b87;--ok:#0a7d32;--bad:#b02020;--warn:#b36b00;--info:#0b6ea8;--line:#d9dee3;--dim:#5c6670}
 *{box-sizing:border-box;-webkit-print-color-adjust:exact;print-color-adjust:exact}
 body{font-family:'Segoe UI',Arial,sans-serif;margin:0;padding:2em 2.2em;color:#1c2733;font-size:13px}
 .head{display:flex;justify-content:space-between;align-items:flex-start;border-bottom:3px solid var(--slg);padding-bottom:.7em;margin-bottom:1.1em}
 .head h1{margin:0;font-size:1.45em;color:var(--slg)}
 .head .sub{color:var(--dim);margin-top:.3em;font-size:.98em}
 .badge{display:inline-block;padding:.45em 1.1em;border-radius:5px;color:#fff;font-weight:700;font-size:1.05em;letter-spacing:.04em}
 .badge.pass{background:var(--ok)} .badge.fail{background:var(--bad)} .badge.warn{background:var(--warn)}
 .meta{display:grid;grid-template-columns:auto 1fr auto 1fr;gap:.3em 1.2em;background:#f4f6f8;border:1px solid var(--line);border-radius:6px;padding:.8em 1em;margin-bottom:1.2em}
 .meta b{color:var(--dim);font-weight:600;white-space:nowrap}
 h2{font-size:1.05em;color:var(--slg);margin:1.4em 0 .5em;border-bottom:1px solid var(--line);padding-bottom:.25em}
 table{border-collapse:collapse;width:100%}
 td,th{border-bottom:1px solid var(--line);padding:.4em .55em;text-align:left;vertical-align:top}
 th{background:var(--slg);color:#fff;font-weight:600;font-size:.92em}
 td.num,th.num{width:2.4em;text-align:right;color:var(--dim)}
 td.detail{color:var(--dim);font-size:.92em}
 tr.fail-row td{background:#fdecea}
 tr.warn-row td{background:#fff6e5}
 .pill{display:inline-block;min-width:5.4em;text-align:center;padding:.15em .6em;border-radius:10px;color:#fff;font-weight:600;font-size:.82em;white-space:nowrap}
 .p-pass{background:var(--ok)} .p-fail{background:var(--bad)} .p-warn{background:var(--warn)} .p-skip{background:#8a94a0} .p-info{background:var(--info)}
 .counts{margin:.2em 0 .6em}
 .counts span{margin-right:1.1em;font-weight:600}
 .c-pass{color:var(--ok)} .c-warn{color:var(--warn)} .c-fail{color:var(--bad)} .c-dim{color:var(--dim);font-weight:400}
 pre{background:#f4f6f8;border:1px solid var(--line);padding:1em;font-size:.85em;white-space:pre-wrap}
 .foot{color:var(--dim);font-size:.85em;margin-top:1.6em;border-top:1px solid var(--line);padding-top:.5em}
 @page{margin:14mm}
</style></head><body>
<div class="head">
  <div>
    <h1>SLG Notebook-Onboarding &ndash; Abnahme-Report</h1>
    <div class="sub">HEPHAISTOS v$ver &nbsp;|&nbsp; $Model &nbsp;|&nbsp; Service Tag $Serial &nbsp;|&nbsp; $stamp</div>
  </div>
  <div>$badge</div>
</div>
<div class="meta">
  <b>Hostname</b><span>$env:COMPUTERNAME</span><b>OS</b><span>$($os.Caption) Build $($os.BuildNumber)</span>
  <b>Prim. Benutzer</b><span>$PrimaryUser</span><b>Techniker</b><span>$Technician</span>
  <b>Ger&auml;teordner</b><span>$DevDir</span><b>Erstellt</b><span>$stamp</span>
</div>
<h2>Onboarding-Schritte</h2>
<table><tr><th class="num">#</th><th>Schritt</th><th>Status</th><th>Details</th></tr>
$($stepRows -join "`n")
</table>
$testBlock
<div class="foot">Erzeugt durch HEPHAISTOS v$ver</div>
</body></html>
"@
    $out = Join-Path $DevDir ("Onboarding-Report_{0}_{1}.html" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyy-MM-dd_HHmm'))
    $doc | Set-Content -Path $out -Encoding UTF8
    return $out
}
