<#
.SYNOPSIS
    HEPHAISTOS Schritt: Windows-Wiederherstellungsumgebung (WinRE) entfernen.
.DESCRIPTION
    Teilschritt von oobe\Invoke-HephaistosOnboarding.ps1 - NICHT direkt starten.
    Wird NUR aufgerufen, wenn config\deploy.json das Flag "RemoveWinRE": true
    setzt (Default: false). Ablauf (Handoff §4.7):
        [1] reagentc /disable (staged winre.wim zurück nach System32\Recovery)
        [2] Recovery-Partition(en) löschen - NUR auf der Disk, auf der C: liegt
        [3] C: auf Maximum erweitern (Get-PartitionSupportedSize, nur wenn
            Zugewinn > 1 MB)
        [4] gestagte C:\Windows\System32\Recovery\winre.wim löschen
    Jeder Teilschritt ist einzeln abgesichert; am Ende steht eine eindeutige
    Ergebniszeile.
    WICHTIG (Doku-Hinweis): Nach Feature-Updates prüfen, ob Windows die
    WinRE-Partition wieder angelegt hat (reagentc /info) - das Setup stellt
    sie ggf. neu her.
.NOTES
    HEPHAISTOS v1.0.2 - neuer Schritt nach Handoff §4.7 (kein Pendant im
    USB_ScriptTool Rev05). PowerShell 5.1. UTF-8 mit BOM.
#>
param([hashtable]$Context)

# --- Guard: Lib muss geladen sein (Dot-Sourcing durch das Onboarding-Script) ---
if (-not (Get-Command Write-HephOk -ErrorAction SilentlyContinue)) {
    Write-Host ''
    Write-Host 'FEHLER: HEPHAISTOS-Bibliothek (lib\Hephaistos.Common.ps1) ist nicht geladen.' -ForegroundColor Red
    Write-Host 'Dieses Script ist ein Teilschritt und wird von oobe\Invoke-HephaistosOnboarding.ps1' -ForegroundColor Yellow
    Write-Host 'aufgerufen - bitte nicht direkt starten.' -ForegroundColor Yellow
    return
}
if (-not $Context) {
    Write-HephErr 'FEHLER: Kein -Context übergeben - WinRE-Schritt wird abgebrochen.'
    return
}
# Sicherheitsnetz für einen destruktiven Schritt: Das Onboarding-Script ruft uns
# nur bei RemoveWinRE=true - hier trotzdem gegenprüfen (Doppelboden).
if ($Context.Config -and -not $Context.Config.RemoveWinRE) {
    Write-HephWarn 'RemoveWinRE ist in deploy.json NICHT aktiviert - Schritt wird übersprungen.'
    return
}

Write-HephPhase -Title 'WinRE entfernen (RemoveWinRE=true)' -EstimatedDuration '10-30 Sekunden'

# --- Konsequenz-Warnung (§4.7): Der Techniker muss wissen, was wegfällt ---
Write-HephWarn 'ACHTUNG: Die Windows-Wiederherstellungsumgebung (WinRE) wird DAUERHAFT entfernt.'
Write-HephWarn 'Konsequenzen für dieses Gerät:'
Write-HephWarn '  - "Diesen PC zurücksetzen" (Reset this PC) funktioniert nicht mehr'
Write-HephWarn '  - Intune-Wipe/-Autopilot-Reset über die Wiederherstellungsumgebung entfällt'
Write-HephWarn '  - keine BitLocker-Recovery-Umgebung (Reparatur nur noch per USB-Boot-Medium)'
if (-not (Confirm-Choice -Prompt 'WinRE jetzt wirklich entfernen?')) {
    Write-HephWarn 'Abgebrochen - WinRE bleibt unverändert.'
    return
}

$errors = 0

# --- [1/4] reagentc /disable -------------------------------------------------
try {
    Write-HephInfo '[1/4] WinRE deaktivieren (reagentc /disable) ...'
    # Aufruf über cmd /c: reagentc schreibt Fehlermeldungen auf stderr, was in
    # PS 5.1 mit $ErrorActionPreference='Stop' + 2>&1 sonst zum Abbruch führt.
    $out = & "$env:SystemRoot\System32\cmd.exe" /c 'reagentc.exe /disable 2>&1'
    if ($LASTEXITCODE -eq 0) {
        Write-HephOk '      WinRE deaktiviert (winre.wim liegt jetzt gestagt unter C:\Windows\System32\Recovery).'
    } else {
        # Exit-Code != 0 heißt in der Praxis meist "bereits deaktiviert" -
        # gewünschter Zustand erreicht, daher Hinweis statt hartem Fehler.
        Write-HephWarn ("      reagentc meldete Exit-Code {0} (evtl. bereits deaktiviert): {1}" -f $LASTEXITCODE, (($out | Out-String).Trim()))
    }
} catch {
    $errors++
    Write-HephErr ("      reagentc /disable fehlgeschlagen: {0}" -f $_.Exception.Message)
}

# --- [2/4] Recovery-Partition(en) löschen - NUR auf der Disk von C: ----------
try {
    Write-HephInfo '[2/4] Recovery-Partition(en) auf der Systemdisk suchen ...'
    $osDiskNumber = (Get-Partition -DriveLetter C -ErrorAction Stop).DiskNumber
    $recParts = @(Get-Partition -DiskNumber $osDiskNumber -ErrorAction Stop |
                  Where-Object { $_.Type -eq 'Recovery' })
    if ($recParts.Count -eq 0) {
        Write-HephDim '      Keine Recovery-Partition auf der Systemdisk gefunden - nichts zu löschen.'
    } else {
        foreach ($rp in $recParts) {
            Write-HephInfo ("      Lösche Recovery-Partition {0} auf Disk {1} ({2} MB) ..." -f $rp.PartitionNumber, $rp.DiskNumber, [math]::Round($rp.Size / 1MB))
            Remove-Partition -DiskNumber $rp.DiskNumber -PartitionNumber $rp.PartitionNumber -Confirm:$false -ErrorAction Stop
        }
        Write-HephOk ("      {0} Recovery-Partition(en) gelöscht." -f $recParts.Count)
    }
} catch {
    $errors++
    Write-HephErr ("      Recovery-Partition konnte nicht gelöscht werden: {0}" -f $_.Exception.Message)
}

# --- [3/4] C: auf Maximum erweitern (nur wenn Zugewinn > 1 MB) ---------------
try {
    Write-HephInfo '[3/4] C: auf maximale Größe erweitern ...'
    $sup  = Get-PartitionSupportedSize -DriveLetter C -ErrorAction Stop
    $cur  = (Get-Partition -DriveLetter C -ErrorAction Stop).Size
    $gain = $sup.SizeMax - $cur
    if ($gain -gt 1MB) {
        Resize-Partition -DriveLetter C -Size $sup.SizeMax -ErrorAction Stop
        Write-HephOk ("      C: um {0:N0} MB erweitert (neue Größe: {1:N1} GB)." -f ($gain / 1MB), ($sup.SizeMax / 1GB))
    } else {
        Write-HephDim '      Kein nennenswerter Zugewinn (<= 1 MB) - C: bleibt unverändert.'
    }
} catch {
    $errors++
    Write-HephErr ("      C: konnte nicht erweitert werden: {0}" -f $_.Exception.Message)
}

# --- [4/4] gestagte winre.wim löschen ----------------------------------------
try {
    Write-HephInfo '[4/4] Gestagte winre.wim löschen ...'
    $wim = 'C:\Windows\System32\Recovery\winre.wim'
    if (Test-Path $wim) {
        # Datei ist versteckt/systemgeschützt -> Attribute vor dem Löschen entfernen
        $f = Get-Item -Path $wim -Force
        $f.Attributes = [IO.FileAttributes]::Normal
        Remove-Item -Path $wim -Force
        Write-HephOk ("      {0} gelöscht." -f $wim)
    } else {
        Write-HephDim ("      {0} nicht vorhanden - nichts zu tun." -f $wim)
    }
} catch {
    $errors++
    Write-HephErr ("      winre.wim konnte nicht gelöscht werden: {0}" -f $_.Exception.Message)
}

# --- Ergebnis ----------------------------------------------------------------
Write-HephWarn 'Hinweis: Nach künftigen Feature-Updates prüfen, ob WinRE zurückgekehrt ist (reagentc /info).'
if ($errors -eq 0) {
    Write-HephResult -Success $true -Text 'WinRE entfernt - alle Teilschritte erfolgreich.'
} else {
    Write-HephResult -Success $false -Text ("WinRE-Entfernung mit {0} Fehler(n) beendet - Meldungen oben prüfen." -f $errors)
}
