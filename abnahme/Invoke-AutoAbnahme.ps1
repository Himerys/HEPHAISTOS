<#
.SYNOPSIS
    HEPHAISTOS - Auto-Abnahme-Wächter (geplante Aufgabe, läuft als SYSTEM).
.DESCRIPTION
    Wird von der OOBE-Phase als geplante Aufgabe 'HEPHAISTOS-AutoAbnahme'
    registriert (Trigger: bei Anmeldung, verzögert; deploy.json Abnahme.AutoRun)
    und startet die Abnahme automatisch im nicht-interaktiven Modus, sobald die
    Bedingungen stimmen:
      1. ein regulärer Benutzer ist angemeldet (kein defaultuser0/OOBE)
      2. die Intune Management Extension ist installiert (ESP-Gerätephase durch)
      3. der HEPHAISTOS-Stick ist eingesteckt (Reports/State liegen dort)
    Sind die Bedingungen nicht erfüllt, beendet sich der Lauf still - die
    Aufgabe feuert bei der nächsten Anmeldung erneut. Nach BESTANDENER Abnahme
    (Flag step4_compliance.done) entfernt die Aufgabe sich selbst.
    Läuft unsichtbar als SYSTEM; Protokoll: C:\OSDCloud\HEPHAISTOS\autoabnahme.log
    Bewusst OHNE Lib-Abhängigkeit (selbsttragend), damit die Aufgabe auch bei
    Repo-/Stick-Problemen nie crasht, sondern nur protokolliert und wartet.
.NOTES
    HEPHAISTOS v1.3.1. PowerShell 5.1. UTF-8 mit BOM.
#>
$ErrorActionPreference = 'Stop'
$TaskName = 'HEPHAISTOS-AutoAbnahme'
$RawBase  = 'https://raw.githubusercontent.com/Himerys/HEPHAISTOS/main'
$LogFile  = 'C:\OSDCloud\HEPHAISTOS\autoabnahme.log'

function Write-AaLog {
    param([string]$Text)
    try { ('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Text) | Add-Content -Path $LogFile -Encoding UTF8 } catch { }
}
function Remove-OwnTask {
    try { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false } catch { }
}

Write-AaLog '--- Auto-Abnahme-Lauf gestartet ---'

# --- Bedingung 1: regulärer Benutzer angemeldet (kein defaultuser0/OOBE) ---
$consoleUser = $null
try { $consoleUser = [string](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).UserName } catch { }
if (-not $consoleUser -or ($consoleUser -match 'defaultuser0')) {
    Write-AaLog ('Noch kein regulärer Benutzer angemeldet ({0}) - warte auf die nächste Anmeldung.' -f $(if ($consoleUser) { $consoleUser } else { 'niemand' }))
    exit 0
}

# --- Bedingung 2: Intune Management Extension installiert (ESP-Gerätephase) ---
if (-not (Get-Service -Name 'IntuneManagementExtension' -ErrorAction SilentlyContinue)) {
    Write-AaLog 'IntuneManagementExtension noch nicht installiert - Provisioning läuft vermutlich noch.'
    exit 0
}

# --- Bedingung 3: HEPHAISTOS-Stick eingesteckt ---
$usbRoot = $null
foreach ($drv in [IO.DriveInfo]::GetDrives()) {
    try {
        if ($drv.IsReady -and (Test-Path (Join-Path $drv.RootDirectory.FullName '_HEPHAISTOS'))) {
            $usbRoot = $drv.RootDirectory.FullName
            break
        }
    } catch { }
}
if (-not $usbRoot) {
    Write-AaLog 'Kein HEPHAISTOS-Stick gefunden - warte auf die nächste Anmeldung (Stick anstecken).'
    exit 0
}

# --- Bereits bestanden? Dann Aufgabe entfernen und Schluss. ---
$serial = ''
try { $serial = ([string](Get-CimInstance Win32_BIOS -ErrorAction Stop).SerialNumber).Trim() -replace '\s', '' } catch { }
$doneFlag = $null
if ($serial) { $doneFlag = Join-Path $usbRoot ('Logs\{0}\state\step4_compliance.done' -f $serial) }
if ($doneFlag -and (Test-Path $doneFlag)) {
    Write-AaLog 'Abnahme bereits bestanden - Aufgabe entfernt sich selbst.'
    Remove-OwnTask
    exit 0
}

# --- Abnahme-Script frisch aus dem Repo laden (Fallback: Stick/Staging) ---
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 } catch { }
$target = Join-Path $env:TEMP 'HEPHAISTOS\abnahme\Test-HephaistosDevice.ps1'
$script = $null
try {
    $null = New-Item -Path (Split-Path -Parent $target) -ItemType Directory -Force
    Invoke-WebRequest -UseBasicParsing -Uri ('{0}/abnahme/Test-HephaistosDevice.ps1' -f $RawBase) -OutFile $target -ErrorAction Stop
    $script = $target
    Write-AaLog 'Abnahme-Script aus dem Repo geladen.'
} catch {
    foreach ($cand in @((Join-Path $usbRoot '_HEPHAISTOS\Fallback\abnahme\Test-HephaistosDevice.ps1'), 'C:\OSDCloud\HEPHAISTOS\Fallback\abnahme\Test-HephaistosDevice.ps1')) {
        if (Test-Path $cand) {
            $script = $cand
            Write-AaLog ('Offline-Fallback: {0}' -f $cand)
            break
        }
    }
}
if (-not $script) {
    Write-AaLog 'Kein Abnahme-Script verfügbar (weder Repo noch lokale Kopie) - Abbruch dieses Laufs.'
    exit 0
}

# --- Abnahme in einem Kindprozess ausführen (das Script beendet sich mit exit;
#     im eigenen Prozess würde das den Wächter samt Aufräum-Logik mitreißen). ---
Write-AaLog 'Starte Abnahme (nicht-interaktiv) ...'
$rc = -1
try {
    $p = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script, '-NonInteractive'
    )
    # Timeout 90 min: ein haengender Kindprozess (z.B. WU-Scan) darf den
    # unsichtbaren Waechter nicht dauerhaft blockieren (IgnoreNew wuerde sonst
    # alle weiteren Anmelde-Trigger bis zum Neustart unterdruecken).
    if (-not $p.WaitForExit(5400000)) {
        try { $p.Kill() } catch { }
        Write-AaLog 'Timeout (90 min) - Abnahme-Prozess beendet; neuer Versuch bei der nächsten Anmeldung.'
        exit 0
    }
    $rc = $p.ExitCode
} catch {
    Write-AaLog ('Abnahme-Start fehlgeschlagen: {0}' -f $_.Exception.Message)
}
Write-AaLog ('Abnahme beendet, Exit-Code {0} (0 = alle Pflichttests bestanden).' -f $rc)

# Selbst-Entfernung: bestandene Abnahme (Flag) ODER - falls der Serial/Flag-Pfad
# nicht bestimmbar war - ersatzweise Exit-Code 0 des Abnahme-Laufs.
if (($doneFlag -and (Test-Path $doneFlag)) -or ((-not $doneFlag) -and ($rc -eq 0))) {
    Write-AaLog 'Abnahme bestanden - Aufgabe entfernt sich selbst. Report liegt im Geräteordner auf dem Stick.'
    Remove-OwnTask
} else {
    Write-AaLog 'Abnahme (noch) nicht bestanden - Aufgabe bleibt für den nächsten Anmelde-Versuch aktiv.'
}
