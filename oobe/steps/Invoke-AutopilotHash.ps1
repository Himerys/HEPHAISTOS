<#
.SYNOPSIS
    HEPHAISTOS OOBE-Schritt: Autopilot-Hardware-Hash exportieren und nach Intune hochladen.
.DESCRIPTION
    Wird von oobe\Invoke-HephaistosOnboarding.ps1 aufgerufen:
        & .\Invoke-AutopilotHash.ps1 -Context $ctx
    Ablauf:
        1) Offline-Export IMMER zuerst: Hardware-Hash lokal via WMI (MDM_DevDetail_Ext01)
           lesen und als Intune-Import-CSV auf den Stick schreiben (<Stick>:\HWID\<Serial>.csv).
           Kein Internet und keine Script-Gallery nötig - die CSV ist das Backup.
        2) Group Tag wählen; Tag fließt direkt in die CSV (kein manuelles Nachtragen mehr).
        3) Online-Upload nach Intune: mit App-Auth aus dem verschlüsselten Secrets-Blob
           nativ per Graph-REST (importedWindowsAutopilotDeviceIdentities, KEINE
           PSGallery-Abhängigkeit - läuft damit auch als SYSTEM in der Specialize-Phase);
           interaktive Microsoft-Anmeldung (Get-WindowsAutopilotInfo) nur als
           expliziter Fallback auf Techniker-Wunsch.
        4) NEU (Handoff Abschnitt 4.6): Nach erfolgreichem Upload wird die Autopilot-Profilzuweisung
           per Graph gepollt (alle 30 s, max. 60 Abfragen = 30 Minuten). Sobald zugewiesen:
           automatischer Neustart (10 s Countdown) direkt in das Autopilot-Provisioning.
           Timeout: gelber Hinweis auf die GroupTag-Gruppenzuordnung, KEIN Neustart.
    Erwartet die geladene HEPHAISTOS-Bibliothek (lib\Hephaistos.Common.ps1) im Scope.
.NOTES
    HEPHAISTOS v1.2.3 - portiert aus USB_ScriptTool Rev05
    (SLG-Onboarding.ps1 / Invoke-Step3Hash + Scripts\Export-AutopilotHash.ps1 Rev02).
    Benötigt PowerShell 5.1 (OOBE/Win11 Standard). Datei ist UTF-8 MIT BOM gespeichert
    (Pflicht für PS 5.1 + Umlaute).
#>
param([hashtable]$Context)

$ErrorActionPreference = 'Stop'

# ============================================================ Standalone-Schutz
# Dieser Schritt ist KEIN eigenständiges Script: Er braucht die Lib-Funktionen
# (Write-Heph*, Set-Step, Test-HephInternet, Get-HephaistosSecrets, ...) im Scope.
if (-not (Get-Command Write-HephOk -ErrorAction SilentlyContinue)) {
    Write-Host ''
    Write-Host 'FEHLER: HEPHAISTOS-Bibliothek (lib\Hephaistos.Common.ps1) ist nicht geladen.' -ForegroundColor Red
    Write-Host 'Dieses Script ist ein Teilschritt und läuft nicht eigenständig.' -ForegroundColor Yellow
    Write-Host 'Bitte über C:\OSDCloud\HEPHAISTOS\oobe.cmd bzw. oobe\Invoke-HephaistosOnboarding.ps1 starten.' -ForegroundColor Yellow
    return
}
if (-not $Context) {
    Write-HephErr 'FEHLER: Kein -Context übergeben - Schritt kann nicht ausgeführt werden.'
    return
}

# ============================================================ Kontext auspacken
$usbRoot    = [string]$Context.UsbRoot
$devDir     = [string]$Context.DevDir
$stateDir   = [string]$Context.StateDir
$serial     = [string]$Context.Serial
$cfg        = $Context.Config
$stagedRoot = [string]$Context.StagedRoot
if (-not $stagedRoot) { $stagedRoot = 'C:\OSDCloud\HEPHAISTOS' }
$secretsPath = [string]$Context.SecretsPath
if (-not $secretsPath -and $usbRoot) {
    $secretsPath = Join-Path $usbRoot 'HEPHAISTOS-Secrets\hephaistos.secrets.enc.json'
}
if (-not $stateDir) {
    Write-HephErr 'FEHLER: Context.StateDir fehlt - Schritt kann nicht ausgeführt werden.'
    return
}

Write-HephPhase -Title 'Autopilot-Hash: Offline-Export + Online-Upload nach Intune' `
    -EstimatedDuration '2-5 Minuten (Profilzuweisung danach bis zu 30 Minuten)'

# ============================================================ 1) Offline-Export (immer zuerst)
# Port von Scripts\Export-AutopilotHash.ps1 (Rev02): lokale WMI-Abfrage
# (MDM_DevDetail_Ext01) - kein Internet und keine Script-Gallery in der OOBE nötig.
# Die CSV auf dem Stick bleibt IMMER als Backup liegen, auch wenn der Upload klappt.
if ($usbRoot) {
    $hwidDir = Join-Path $usbRoot 'HWID'
} else {
    $hwidDir = Join-Path $stagedRoot 'HWID'
    Write-HephWarn ('Stick nicht gefunden - CSV wird lokal abgelegt: {0}' -f $hwidDir)
}
try {
    if (-not (Test-Path $hwidDir)) { New-Item -Path $hwidDir -ItemType Directory -Force | Out-Null }

    # --- Gerätedaten lesen ---
    $bios      = Get-CimInstance -ClassName Win32_BIOS
    $csProd    = Get-CimInstance -ClassName Win32_ComputerSystemProduct
    $csvSerial = $bios.SerialNumber.Trim()
    if (-not $serial) { $serial = $csvSerial -replace '\s','' }

    $devDetail = Get-CimInstance -Namespace 'root/cimv2/mdm/dmmap' `
                 -ClassName 'MDM_DevDetail_Ext01' `
                 -Filter "InstanceID='Ext' AND ParentID='./DevDetail'"
    if (-not $devDetail -or [string]::IsNullOrWhiteSpace($devDetail.DeviceHardwareData)) {
        throw 'Hardware-Hash konnte nicht gelesen werden (MDM_DevDetail_Ext01 leer). Ist das ein physisches Gerät mit TPM?'
    }
    $hash = $devDetail.DeviceHardwareData

    # --- CSV im Intune-Importformat schreiben (Group Tag wird gleich automatisch befüllt) ---
    $outFile = Join-Path $hwidDir ("{0}.csv" -f $serial)
    $line    = '"{0}","{1}","{2}",""' -f $csvSerial, $csProd.Name.Trim(), $hash
    Set-Content -Path $outFile -Value 'Device Serial Number,Windows Product ID,Hardware Hash,Group Tag' -Encoding ASCII
    Add-Content -Path $outFile -Value $line -Encoding ASCII

    Write-HephOk  ('Hash exportiert: {0}' -f $outFile)
    Write-HephDim ('  Modell: {0} | Service Tag: {1}' -f $csProd.Name.Trim(), $csvSerial)
} catch {
    Write-HephErr ('FEHLER: {0}' -f $_.Exception.Message)
    Write-HephErr 'Export nicht erfolgreich - Gerät NICHT weiterverarbeiten.'
    Write-HephResult -Success $false -Text 'Autopilot-Hash: Export fehlgeschlagen.'
    return
}

# ============================================================ 2) Group Tag wählen
# Port aus SLG-Onboarding.ps1 (Invoke-Step3Hash): Tag fließt direkt in die CSV
# -> kein manuelles Nachtragen mehr. Tags kommen aus config\deploy.json.
$groupTags = @()
if ($cfg -and $cfg.GroupTags) { $groupTags = @($cfg.GroupTags) }
if ($groupTags.Count -eq 0) {
    $groupTags = @('SLGDE','SLGFR','SLGPL','SLGTEST')
    Write-HephWarn 'Keine GroupTags in der Config gefunden - nutze Standardliste.'
}
# v1.1.0: Vorauswahl aus der WinPE-Phase (install.json GroupTagPreselect,
# abgeleitet aus der Sprache) - Enter übernimmt sie, Nummer wählt um.
$tagPre = $null
if ($Context.ContainsKey('GroupTagPreselect') -and $Context.GroupTagPreselect) { $tagPre = [string]$Context.GroupTagPreselect }
if ($tagPre -and ($groupTags -notcontains $tagPre)) { $tagPre = $null }   # nur gültige Tags als Default
# Specialize-Autostart (v1.2.0): läuft der Schritt aus dem Windows-Setup heraus,
# wird die WinPE-Vorauswahl ohne Rückfrage übernommen (keine vermeidbare offene
# Eingabe im Setup-Vollbild). Ohne Vorauswahl bleibt der Prompt bestehen.
$specializeMode = ($Context.ContainsKey('SpecializeMode') -and $Context.SpecializeMode)
$tag = $null
if ($specializeMode -and $tagPre) {
    $tag = $tagPre
    Write-HephDim ('Group Tag automatisch übernommen (WinPE-Vorauswahl): {0}' -f $tag)
} else {
    Write-Host ''
    for ($i = 0; $i -lt $groupTags.Count; $i++) {
        $mark = ''
        if ($tagPre -and ($groupTags[$i] -ieq $tagPre)) { $mark = '   <- Vorauswahl (WinPE)' }
        Write-Host ("  [{0}] {1}{2}" -f ($i + 1), $groupTags[$i], $mark)
    }
    $tagPrompt = 'Group Tag'
    if ($tagPre) { $tagPrompt = ('Group Tag [Enter = {0}]' -f $tagPre) }
    $sel = (Read-Host $tagPrompt).Trim()
    $idx = 0
    if (-not $sel -and $tagPre) {
        $tag = $tagPre
    } elseif ([int]::TryParse($sel, [ref]$idx) -and $idx -ge 1 -and $idx -le $groupTags.Count) {
        $tag = $groupTags[$idx - 1]
    }
}
if (-not $tag) {
    Write-HephWarn 'Ungültige Auswahl - abgebrochen.'
    Write-HephResult -Success $false -Text 'Autopilot-Hash: kein Group Tag gewählt - Schritt bleibt offen.'
    return
}

# --- Group Tag automatisch in die CSV eintragen ---
try {
    $rows = Import-Csv -Path $outFile
    foreach ($r in $rows) { $r.'Group Tag' = $tag }
    $rows | Export-Csv -Path $outFile -NoTypeInformation -Encoding ASCII
    Write-HephOk ("Group Tag '{0}' in CSV eingetragen." -f $tag)
} catch {
    Write-HephWarn ("WARNUNG: Group Tag konnte nicht in die CSV geschrieben werden: {0}" -f $_.Exception.Message)
}
if ($devDir -and (Test-Path $devDir)) {
    Copy-Item -Path $outFile -Destination $devDir -Force
    Write-HephDim ('  Kopie im Geräteordner: {0}' -f $devDir)
}

# ============================================================ 3) Internet-Check
if (-not (Test-HephInternet)) {
    Write-HephWarn 'Kein Zugriff auf graph.microsoft.com:443 - Online-Upload nicht möglich.'
    Write-HephWarn 'Offline-CSV ist gesichert; Upload später manuell durchführen.'
    Set-Step -StateDir $stateDir -Name 'step3_hash.done' -Detail ("Offline-CSV (kein Netz), GroupTag={0}" -f $tag)
    Write-HephResult -Success $true -Text 'Autopilot-Hash: Offline-CSV gesichert (kein Netz - Upload folgt manuell).'
    return
}

# ============================================================ 4) Graph-Zugang (Secrets-Blob)
# Bevorzugt App-Auth aus dem verschlüsselten Blob auf dem Stick (ersetzt die
# frühere _SLG\Tools\graph.config.json). Ohne Blob bzw. nach 3x falscher
# Passphrase bleibt der interaktive Upload als expliziter Fallback (wie Original).
$secrets = $null
if ($secretsPath -and (Test-Path $secretsPath)) {
    $secrets = Get-HephaistosSecrets -Path $secretsPath
} else {
    Write-HephWarn ('Keine Secrets-Datei gefunden: {0}' -f $(if ($secretsPath) { $secretsPath } else { '<Stick>:\HEPHAISTOS-Secrets\hephaistos.secrets.enc.json' }))
}
# v1.2.1: Teams-Webhook für die Auto-Abnahme auf DIESEM Gerät hinterlegen
# (DPAPI Machine-Scope) - die Passphrase wurde hier ohnehin gerade eingegeben.
# Die Auto-Abnahme kann die Teams-Karte damit ohne Passphrase posten.
if ($secrets -and $secrets.TeamsWebhookUrl -and (Get-Command Save-HephTeamsWebhookCache -ErrorAction SilentlyContinue)) {
    try {
        Save-HephTeamsWebhookCache -Url ([string]$secrets.TeamsWebhookUrl)
        Write-HephDim 'Teams-Webhook für die Auto-Abnahme hinterlegt (DPAPI, nur dieses Gerät).'
    } catch {
        Write-HephDim ('Teams-Webhook-Cache nicht möglich ({0}) - Auto-Abnahme postet dann keine Karte.' -f $_.Exception.Message)
    }
}
if (-not $secrets) {
    Write-HephWarn 'Kein Graph-Zugang (App-Auth) verfügbar - automatischer Upload nicht möglich, CSV ist gesichert.'
    if (-not (Confirm-Choice 'Stattdessen ONLINE-Upload mit interaktiver Microsoft-Anmeldung versuchen?')) {
        Set-Step -StateDir $stateDir -Name 'step3_hash.done' -Detail ("Offline-CSV (kein Graph-Zugang), GroupTag={0}" -f $tag)
        Write-HephResult -Success $true -Text 'Autopilot-Hash: Offline-CSV gesichert (Upload folgt manuell).'
        return
    }
}

# ============================================================ 4b) NEU (v1.0.4): Bereits in Autopilot registriert?
# Doppelte Uploads vermeiden: Vor dem Upload wird die Seriennummer per Graph
# gesucht (dieselbe Abfrage wie beim Polling). Existiert der Eintrag bereits,
# wird der Upload übersprungen und direkt auf die Profilzuweisung gewartet.
$alreadyRegistered = $false
if ($secrets) {
    try {
        $chkToken = Get-GraphAppToken -Cfg $secrets
        # beta-Endpunkt: liefert zusätzlich deploymentProfileAssignmentStatus
        # (in v1.0 fehlt die Property komplett - siehe Polling unten).
        $chkUri   = "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeviceIdentities?`$filter=contains(serialNumber,'{0}')" -f $serial
        $chkResp  = Invoke-RestMethod -Method GET -Uri $chkUri -Headers @{ Authorization = "Bearer $chkToken" }
        # Nur EXAKTER Serial-Treffer zählt (contains() ist unscharf - für das
        # Überspringen des Uploads reicht ein Teilstring-Treffer NICHT).
        $existing = $null
        foreach ($d in @($chkResp.value)) {
            if ([string]$d.serialNumber -eq $serial) { $existing = $d; break }
        }
        if ($existing) {
            $alreadyRegistered = $true
            $exTag = [string]$existing.groupTag
            Write-HephOk ('Gerät ist bereits in Autopilot registriert (Serial {0}) - Upload wird übersprungen.' -f $serial)
            if ($exTag -and ($exTag -ne $tag)) {
                Write-HephWarn ("GroupTag-Abweichung: registriert '{0}', hier gewählt '{1}' - bei Bedarf im Intune-Portal ändern." -f $exTag, $tag)
            } elseif ($exTag) {
                Write-HephDim ('  GroupTag: {0}' -f $exTag)
            } else {
                # Eintrag OHNE GroupTag: Profilzuweisung über die dynamische Gruppe
                # wird so nie greifen - deutlich warnen und den echten Zustand
                # (nicht das hier gewählte Tag) ins State-Detail schreiben.
                Write-HephWarn ("Registrierung hat KEIN GroupTag (hier gewählt: '{0}') - Tag im Intune-Portal nachtragen," -f $tag)
                Write-HephWarn 'sonst bleibt die Profilzuweisung aus (Polling wird vermutlich in den Timeout laufen).'
            }
            Set-Step -StateDir $stateDir -Name 'step3_hash.done' -Detail ("Bereits in Autopilot registriert, GroupTag={0}" -f $(if ($exTag) { $exTag } else { 'KEINES (nachtragen!)' }))
            $exStatus = [string]$existing.deploymentProfileAssignmentStatus
            if ($exStatus) { Write-HephDim ('  Zuweisungs-Status: {0}' -f $exStatus) }
        }
    } catch {
        Write-HephDim ('Registrierungs-Vorabprüfung nicht möglich ({0}) - Upload wird normal versucht.' -f $_.Exception.Message)
    }
}

# ============================================================ 5) Online-Upload nach Intune
# NEU (v1.2.2): Mit App-Auth läuft der Upload nativ über die Graph-API
# (importedWindowsAutopilotDeviceIdentities) statt über das PSGallery-Script
# Get-WindowsAutopilotInfo. Feldtest 2026-08-21 (3x Dell Pro 13 Plus,
# Specialize-Phase): Unter SYSTEM ohne Benutzerprofil lässt sich PowerShellGet
# nicht laden (Get-PSRepository: "Modul konnte nicht geladen werden") - der
# Upload schlug dort deshalb IMMER fehl. Der REST-Import braucht keinerlei
# Module und nutzt denselben App-Zugang mit derselben Berechtigung
# (DeviceManagementServiceConfig.ReadWrite.All) wie das bisherige Script.
if ($alreadyRegistered) {
    Write-HephResult -Success $true -Text 'Autopilot-Hash: bereits registriert - Upload übersprungen.'
} elseif ($secrets) {
    try {
        Write-HephInfo 'Upload mit gespeichertem Graph-Zugang (App-Auth, keine Anmeldung nötig) ...'
        $impUri   = 'https://graph.microsoft.com/beta/deviceManagement/importedWindowsAutopilotDeviceIdentities'
        $impToken = Get-GraphAppToken -Cfg $secrets
        # hardwareIdentifier ist Edm.Binary: DeviceHardwareData aus WMI ist bereits
        # der passende Base64-String und wird unverändert übergeben.
        $impBody = @{
            '@odata.type'             = '#microsoft.graph.importedWindowsAutopilotDeviceIdentity'
            serialNumber              = $csvSerial
            groupTag                  = $tag
            productKey                = ''
            hardwareIdentifier        = $hash
            assignedUserPrincipalName = ''
            state = @{
                '@odata.type'        = 'microsoft.graph.importedWindowsAutopilotDeviceIdentityState'
                deviceImportStatus   = 'pending'
                deviceRegistrationId = ''
                deviceErrorCode      = 0
                deviceErrorName      = ''
            }
        } | ConvertTo-Json -Depth 4
        $impDev = Invoke-RestMethod -Method POST -Uri $impUri `
                      -Headers @{ Authorization = "Bearer $impToken" } `
                      -ContentType 'application/json; charset=utf-8' -Body $impBody
        Write-HephDim ('  Import angenommen (Id {0}) - Intune verarbeitet den Import asynchron ...' -f $impDev.id)

        # Import-Status pollen (alle 15 s, max. 80 = 20 Minuten; typisch 1-10 min,
        # Microsofts dokumentierter Worst Case ist 15 min - das Fenster liegt
        # bewusst DARÜBER, damit ein langsamer Import nicht als Fehler endet).
        # Terminal: complete = ok; error/failed mit deviceErrorCode 806
        # (ZtdDeviceAlreadyAssigned) = Gerät war schon registriert = ebenfalls ok.
        $impStatus = 'unknown'; $impErrCode = 0; $impErrName = ''
        $impRenewed = $false
        for ($p = 1; $p -le 80; $p++) {
            Start-Sleep -Seconds 15
            try {
                $impState = Invoke-RestMethod -Method GET -Uri ('{0}/{1}' -f $impUri, $impDev.id) `
                                -Headers @{ Authorization = "Bearer $impToken" }
            } catch {
                $impResp = $_.Exception.Response
                if (-not $impRenewed -and $impResp -and [int]$impResp.StatusCode -eq 401) {
                    # Token läuft nach ~60 min ab - hier reicht EINE Erneuerung.
                    $impRenewed = $true
                    $impToken = Get-GraphAppToken -Cfg $secrets
                    Write-HephDim '  Graph-Token erneuert (401) - Abfrage läuft weiter.'
                    continue
                }
                Write-HephDim ('  Status-Abfrage fehlgeschlagen ({0}) - nächster Versuch in 15 s.' -f $_.Exception.Message)
                continue
            }
            if ($impState.state) {
                $impStatus  = [string]$impState.state.deviceImportStatus
                $impErrCode = [int]$impState.state.deviceErrorCode
                $impErrName = [string]$impState.state.deviceErrorName
            }
            if ($impStatus -in @('complete','error','failed')) { break }
            if (($p % 4) -eq 0) { Write-HephDim ('  ... Import-Status nach {0} min: {1}' -f ($p / 4), $impStatus) }
        }

        if ($impStatus -eq 'complete') {
            Set-Step -StateDir $stateDir -Name 'step3_hash.done' -Detail ("Online-Upload nach Intune (Graph-REST), GroupTag={0}" -f $tag)
            Write-HephOk 'Hash ERFOLGREICH nach Intune hochgeladen.'
            Write-HephDim 'Hinweis: Autopilot-Profilzuweisung kann einige Minuten dauern.'
        } elseif ($impErrCode -eq 806 -or $impErrName -eq 'ZtdDeviceAlreadyAssigned') {
            Set-Step -StateDir $stateDir -Name 'step3_hash.done' -Detail ("Bereits in Autopilot registriert (Import-Antwort 806), GroupTag={0}" -f $tag)
            Write-HephOk 'Gerät war bereits in Autopilot registriert (Import-Antwort 806) - kein erneuter Upload nötig.'
        } elseif ($impStatus -in @('error','failed')) {
            throw ('Intune meldet Import-Fehler: {0} (Code {1})' -f $(if ($impErrName) { $impErrName } else { $impStatus }), $impErrCode)
        } else {
            throw ('Import nach 20 Minuten nicht abgeschlossen (letzter Status: {0}) - im Intune-Portal prüfen.' -f $impStatus)
        }
    } catch {
        # Graph legt die eigentliche Ursache (z.B. fehlende Berechtigung,
        # ungültiger hardwareIdentifier, Throttling) als OData-JSON in den
        # Response-Body - unter PS 5.1 steht in Exception.Message nur der nackte
        # HTTP-Status. Body deshalb best effort mit anzeigen.
        $impErrMsg = $_.Exception.Message
        try {
            if ($_.Exception.Response) {
                $impErrStream = $_.Exception.Response.GetResponseStream()
                if ($impErrStream) {
                    $impErrBody = (New-Object IO.StreamReader($impErrStream)).ReadToEnd()
                    $impErrJson = $null
                    if ($impErrBody) { try { $impErrJson = $impErrBody | ConvertFrom-Json } catch { } }
                    if ($impErrJson -and $impErrJson.error -and $impErrJson.error.message) {
                        $impErrMsg = ('{0} | Graph: {1}' -f $impErrMsg, $impErrJson.error.message)
                    } elseif ($impErrBody -and $impErrBody.Length -le 300) {
                        $impErrMsg = ('{0} | Graph: {1}' -f $impErrMsg, $impErrBody)
                    }
                }
            }
        } catch { }
        Write-HephErr  ("Online-Upload fehlgeschlagen: {0}" -f $impErrMsg)
        Write-HephWarn 'Offline-CSV ist gesichert; Upload später manuell durchführen.'
        Set-Step -StateDir $stateDir -Name 'step3_hash.done' -Detail ("Offline-CSV (Online fehlgeschlagen), GroupTag={0}" -f $tag)
        Write-HephResult -Success $false -Text 'Autopilot-Hash: Online-Upload fehlgeschlagen (CSV gesichert).'
        return
    }
    Write-HephResult -Success $true -Text 'Autopilot-Hash: Upload nach Intune abgeschlossen.'
} else {
    # Interaktiver Fallback ohne App-Zugang: Original-Weg über die PSGallery
    # (Get-WindowsAutopilotInfo mit Microsoft-Anmeldung). Nur in einer echten
    # interaktiven Sitzung sinnvoll - in der Specialize-Phase (SYSTEM) ist
    # PowerShellGet nicht ladbar; dorthin führt dieser Zweig aber nur nach
    # der bestätigten Rückfrage oben.
    try {
        Enable-Tls12AndGallery
        if (-not (Get-InstalledScript -Name Get-WindowsAutopilotInfo -ErrorAction SilentlyContinue)) {
            Write-HephDim 'get-windowsautopilotinfo wird aus der PSGallery installiert ...'
            Install-Script -Name Get-WindowsAutopilotInfo -Force -Scope CurrentUser
        }
        $apDir = (Get-InstalledScript -Name Get-WindowsAutopilotInfo -ErrorAction SilentlyContinue).InstalledLocation
        if (-not $apDir) {
            # Ohne den Guard liefe Join-Path mit $null auf einen kryptischen
            # Bindungsfehler (Feldtest 2026-08-21) - klare Meldung stattdessen.
            throw 'Get-WindowsAutopilotInfo ist nicht verfügbar (PowerShellGet/PSGallery in dieser Sitzung nicht nutzbar).'
        }
        $apScript = Join-Path $apDir 'Get-WindowsAutopilotInfo.ps1'
        cmd /c exit 0   # $LASTEXITCODE zurücksetzen (Fremdscript ruft exit nur im Fehlerfall)
        Write-Host ''
        Write-HephInfo 'Es folgt eine Microsoft-Anmeldung. Mit einem Account mit Intune-'
        Write-HephInfo 'Berechtigung anmelden (Autopilot-Import).'
        & $apScript -Online -GroupTag $tag
        if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) { throw "Exit-Code $LASTEXITCODE" }
        Set-Step -StateDir $stateDir -Name 'step3_hash.done' -Detail ("Online-Upload nach Intune (interaktiv), GroupTag={0}" -f $tag)
        Write-HephOk 'Hash ERFOLGREICH nach Intune hochgeladen.'
        Write-HephDim 'Hinweis: Autopilot-Profilzuweisung kann einige Minuten dauern.'
    } catch {
        Write-HephErr  ("Online-Upload fehlgeschlagen: {0}" -f $_.Exception.Message)
        Write-HephWarn 'Offline-CSV ist gesichert; Upload später manuell durchführen.'
        Set-Step -StateDir $stateDir -Name 'step3_hash.done' -Detail ("Offline-CSV (Online fehlgeschlagen), GroupTag={0}" -f $tag)
        Write-HephResult -Success $false -Text 'Autopilot-Hash: Online-Upload fehlgeschlagen (CSV gesichert).'
        return
    }
    Write-HephResult -Success $true -Text 'Autopilot-Hash: Upload nach Intune abgeschlossen.'
}

# ============================================================ 6) NEU: Profilzuweisung pollen + Auto-Reboot (Handoff 4.6)
# Nach dem Upload wartet HEPHAISTOS aktiv auf die Autopilot-Profilzuweisung und
# startet das Gerät dann automatisch neu, damit die OOBE direkt ins Autopilot-
# Provisioning läuft. Die App-Berechtigung DeviceManagementServiceConfig.ReadWrite.All
# (für den Autopilot-Import ohnehin nötig) deckt auch diesen lesenden Zugriff ab.
if (-not $secrets) {
    # Interaktiver Upload ohne App-Zugang: kein Token für den Graph-Read möglich.
    Write-HephWarn 'Kein App-Zugang: Profilzuweisung kann nicht automatisch geprüft werden.'
    Write-HephWarn 'Zuweisung im Intune-Portal prüfen und Gerät danach manuell neu starten.'
    return
}

Write-HephPhase -Title 'Autopilot-Profilzuweisung abwarten' -EstimatedDuration 'wenige Minuten, max. 30 Minuten'
Write-HephDim ('  Abfrage: windowsAutopilotDeviceIdentities, Serial {0}, alle 30 s (max. 60 Abfragen)' -f $serial)

$maxPolls     = 60      # 60 x 30 s = 30 Minuten
$intervalSec  = 30
$assigned     = $false
$lastStatus   = ''
$emptyWarned  = $false
$tokenRenewed = $false
$pollStart    = Get-Date
# WICHTIG (Praxisfund 08/2026): deploymentProfileAssignmentStatus existiert NUR
# im beta-Endpunkt - v1.0 liefert die Property gar nicht. Mit v1.0 blieb der
# Status immer leer und das Polling lief trotz erfolgter Zuweisung in den
# Timeout. Die App-Berechtigung deckt beta genauso ab.
$pollUri      = "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeviceIdentities?`$filter=contains(serialNumber,'{0}')" -f $serial

try {
    $token = Get-GraphAppToken -Cfg $secrets
} catch {
    Write-HephErr  ('Graph-Token konnte nicht geholt werden: {0}' -f $_.Exception.Message)
    Write-HephWarn 'Profilzuweisung im Intune-Portal prüfen; Gerät manuell neu starten.'
    Write-HephResult -Success $false -Text 'Profilzuweisung: Prüfung nicht möglich (kein Token).'
    return
}

for ($n = 1; $n -le $maxPolls; $n++) {
    $elapsed = (Get-Date) - $pollStart
    Write-Progress -Activity 'Autopilot-Profilzuweisung' `
        -Status ('Poll {0}/{1} - verstrichen {2:mm\:ss}' -f $n, $maxPolls, $elapsed) `
        -PercentComplete ([int](($n / $maxPolls) * 100))

    $resp = $null
    try {
        $resp = Invoke-RestMethod -Method GET -Uri $pollUri -Headers @{ Authorization = "Bearer $token" }
    } catch {
        $httpStatus = 0
        try { $httpStatus = [int]$_.Exception.Response.StatusCode } catch { }
        if ($httpStatus -eq 401 -and -not $tokenRenewed) {
            # Token abgelaufen: genau EINMAL erneuern, dann direkt erneut abfragen.
            Write-HephDim '  Graph-Token abgelaufen (401) - wird einmalig erneuert ...'
            $tokenRenewed = $true
            try {
                $token = Get-GraphAppToken -Cfg $secrets
                $resp  = Invoke-RestMethod -Method GET -Uri $pollUri -Headers @{ Authorization = "Bearer $token" }
            } catch {
                Write-HephDim ('  Erneuter Versuch fehlgeschlagen: {0}' -f $_.Exception.Message)
            }
        } else {
            # Transiente Fehler (Netz/Graph-Drosselung) nicht eskalieren - nächster Poll kommt.
            Write-HephDim ('  Poll {0}: Abfrage fehlgeschlagen: {1}' -f $n, $_.Exception.Message)
        }
    }

    if ($resp -and $resp.value) {
        # Der contains()-Filter kann theoretisch mehrere Geräte liefern ->
        # exakte Seriennummer bevorzugen, sonst erstes Ergebnis nehmen.
        $dev = $null
        foreach ($d in @($resp.value)) {
            if ([string]$d.serialNumber -eq $serial) { $dev = $d; break }
        }
        if (-not $dev) { $dev = @($resp.value)[0] }
        $status = [string]$dev.deploymentProfileAssignmentStatus
        if ($status -and $status -ne $lastStatus) {
            Write-HephDim ('  Status: {0}' -f $status)
            $lastStatus = $status
        } elseif (-not $status -and -not $emptyWarned) {
            # Diagnose-Hinweis (einmalig): sollte mit dem beta-Endpunkt nicht
            # mehr auftreten - falls doch, ist das die Erklärung für einen Timeout.
            Write-HephDim '  Hinweis: Graph liefert (noch) keinen Zuweisungs-Status für diesen Eintrag.'
            $emptyWarned = $true
        }
        if ($status -like 'assigned*') { $assigned = $true; break }
    }

    if ($n -lt $maxPolls) { Start-Sleep -Seconds $intervalSec }
}
Write-Progress -Activity 'Autopilot-Profilzuweisung' -Completed

if ($assigned) {
    $elapsed = (Get-Date) - $pollStart
    Write-HephOk ('Autopilot-Profil zugewiesen (Status: {0}, nach {1:mm\:ss}).' -f $lastStatus, $elapsed)
    if ($specializeMode) {
        # Specialize-Autostart (v1.2.0): Die Zuweisung steht fest, BEVOR die OOBE
        # überhaupt startet - ein Neustart ist damit überflüssig. Das Setup fährt
        # fort und die OOBE geht direkt in das zugewiesene Autopilot-Profil.
        Write-HephResult -Success $true -Text 'Profilzuweisung bestätigt - Windows-Setup fährt fort, OOBE startet direkt in das Provisioning.'
    } else {
        Write-HephResult -Success $true -Text 'Profilzuweisung bestätigt - Gerät startet automatisch neu.'
        Write-Host ''
        Write-HephInfo 'Automatischer Neustart in 10 Sekunden - das Gerät bootet direkt in das Autopilot-Provisioning.'
        # Orchestrator informieren (Hashtable ist by-reference): sauberer Exit-Pfad
        # statt Zusammenfassung/Transcript gegen den laufenden Shutdown zu rennen.
        $Context['AutoReboot'] = $true
        shutdown.exe /r /t 10
        Write-Host -NoNewline '  Neustart in ' -ForegroundColor Cyan
        for ($s = 10; $s -ge 1; $s--) {
            Write-Host -NoNewline ('{0} ' -f $s) -ForegroundColor Cyan
            Start-Sleep -Seconds 1
        }
        Write-Host ''
    }
} else {
    Write-HephWarn ('Timeout: Profilzuweisung wurde innerhalb von {0} Minuten nicht bestätigt.' -f [int]($maxPolls * $intervalSec / 60))
    Write-HephWarn 'Profilzuweisung prüfen: Gruppenzuordnung des GroupTags.'
    Write-HephDim  ('  Typische Ursache: dynamische Entra-Gruppe für GroupTag "{0}" fehlt oder ist noch nicht ausgewertet.' -f $tag)
    Write-HephDim  '  Gerät erst neu starten, wenn die Zuweisung im Intune-Portal sichtbar ist.'
    Write-HephResult -Success $false -Text 'Profilzuweisung nicht bestätigt - KEIN automatischer Neustart.'
}
