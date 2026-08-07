# CHANGELOG

## 1.0.1 (2026-08-07)

### Behoben

- **OSName-Soft-Check (Build-USB.ps1 + boot/Start-Hephaistos.ps1) war zu streng:**
  Die installierte OSD-Modulversion listet den Katalog als VOLLNAMEN
  (`<OSName> <Sprache> <Aktivierung> <Build>`, z. B.
  `Windows 11 25H2 x64 de-de Retail 26200.8653`), während Sprache und
  Aktivierung bei `Start-OSDCloud` separate Parameter sind. Der Exact-Match
  gegen die Kurzform `Windows 11 25H2 x64` schlug deshalb fälschlich fehl —
  im WinPE hätte das bei JEDEM Boot eine gelbe Warnung + Rückfrage erzeugt.
  Beide Checks matchen jetzt komponentenweise: OK, wenn für jede konfigurierte
  Sprache ein Katalogeintrag mit OSName-Präfix + Sprache + Aktivierung existiert.
  `OSName` in `deploy.json` bleibt bewusst die Kurzform (der Vollname würde die
  Sprache hart verdrahten und das Sprachmenü aushebeln).

### Verifiziert

- **§4.2-Verifikation erledigt:** `Get-OSDCloudOperatingSystems` (Admin-PC,
  aktuelle OSD-Modulversion) listet `Windows 11 25H2 x64` für de-de, fr-fr und
  pl-pl jeweils als Retail, Build **26200.8653** (≥ MinBuild 26200). Damit ist
  der offene Punkt aus 1.0.0 abgehakt; verbleibt nur noch der reale
  `Start-OSDCloud`-Lauf auf Hardware.

## 1.0.0 (2026-08-07)

Erstes HEPHAISTOS-Release: Port des produktiven USB-Toolkits
(`USB_ScriptTool.zip`, SLG-Onboarding-Stick Rev03–Rev05) in die
GitHub-zentrierte Architektur gemäß Handoff-Brief. Der Stick wird statisch
(OSDCloud WinPE + Offline-Fallback), alle Scripts kommen zur Laufzeit aus
diesem Repo.

### Portiert (Quelle → Ziel)

| Quelle (USB_ScriptTool Rev05) | Ziel |
|---|---|
| `START-ONBOARDING.cmd` (WinPE-Teil) | ersetzt durch OSDCloud: `boot/Start-Hephaistos.ps1` (StartURL) |
| `START-ONBOARDING.cmd` (UAC-Elevation, fltmc-Probe) | `abnahme/START-ABNAHME.cmd` |
| `SLG-Onboarding.ps1` Menü-/State-System (`Set-Step`/`Test-Step`, `Logs\<Serial>\state`) | `lib/Hephaistos.Common.ps1` (mit explizitem `-StateDir`) |
| `SLG-Onboarding.ps1` `Protect-/Unprotect-SLGSecret`, `Read-Passphrase`, `Get-GraphAppToken`, `Enable-Tls12AndGallery`, `Test-Internet`, `Confirm-Choice`, `Write-Head`-Stil | `lib/Hephaistos.Common.ps1` |
| `Invoke-Step1Bios` + `Install-VcRuntimeIfMissing` + CCTK-Fallback-Kette | `oobe/steps/Invoke-BiosConfig.ps1` (+ Lib) |
| `Invoke-Step3Hash` + `Scripts/Export-AutopilotHash.ps1` | `oobe/steps/Invoke-AutopilotHash.ps1` (Export inline) |
| `Invoke-BitLockerEscrow` | `abnahme/Test-HephaistosDevice.ps1` (vor dem Testlauf, wie bisher) |
| `Scripts/Test-SLGDeviceOnboarding.ps1` (alle Checks, Summary, JSON-Schema 2, Exit-Codes) | `abnahme/Test-HephaistosDevice.ps1` |
| `New-SLGHtmlReport`, `Convert-HtmlToPdf`, `Send-TeamsCard`, `Send-SLGReport` | `abnahme/report/*.ps1` |
| `Send-QueuedReports.ps1` + `SEND-REPORTS.cmd` | `send/` |
| `Save-GraphConfig` (Menüpunkt S) | `tools/New-HephaistosSecrets.ps1` |
| `ANLEITUNG.txt` (Wissen/Troubleshooting) | `docs/ANLEITUNG.md` (neu geschrieben für den HEPHAISTOS-Ablauf) |
| `Tools/Technicians.txt` | entfällt — Freitext-Eingabe (§4.1) |

### Geändert (Abweichungen vom Original, mit Begründung)

**Architektur / Ablauf**

- Reihenfolge neu: WinPE macht zuerst Wipe+Install (OSDCloud ZTI), BIOS +
  Autopilot-Hash laufen danach in der OOBE-Phase; Abnahme unverändert am Ende.
  Grund: Zielarchitektur Handoff §1. State-Flag-Namen (`step1_bios.done` usw.)
  wurden aus Kontinuitätsgründen NICHT umbenannt; Report-Tabelle zeigt die neue
  Reihenfolge (Installation, BIOS, Hash, Abnahme).
- Alle Entry-Scripts tragen einen identischen Lib-Bootstrap (GitHub-Download →
  Offline-Fallback auf gestagte Kopie mit gelber Warnung inkl. Stand-Datum) und
  ein Versions-Banner mit Quelle (Handoff §2.7/§2.8).
- `oobe.cmd`, `START-ABNAHME.cmd`, `SEND-REPORTS.cmd` sind Templates mit
  `{{RAWBASE}}`-Platzhalter; ersetzt beim Staging (Boot-Script) bzw. beim
  Stick-Bau (`tools/Build-USB.ps1`). RawBase kommt aus einer Quelle:
  `config/deploy.json`.
- `RawBase` ist auf `Himerys/HEPHAISTOS` gesetzt (vom Nutzer explizit benanntes
  Repo; ersetzt den Handoff-Platzhalter `CHANGE-ME-ORG`).
- Hash-Schritt: Menü [1] Offline / [2] Online entfällt; fester Ablauf
  Offline-Export zuerst (immer als Backup), danach automatischer Online-Versuch
  je nach Netz/Secrets (SPEC-Ablauf für OOBE ohne Menü). Interaktiver Upload
  ohne App-Auth nur noch nach explizitem Confirm (vorher stiller Fallback) —
  Secrets-Policy §6.
- Der OOBE-Orchestrator verzichtet auf Selbst-Elevation (Shift+F10-Konsole ist
  bereits elevated; Relaunch würde den Download-Kontext verlieren) und auf die
  manuelle „Schritt 2 als erledigt markieren“-Abfrage (nur Auto-Erkennung,
  mit sichtbarer grüner/gelber Meldung statt stillem Flag).
- Transcript-Namen phasen-eindeutig: `WinPE_*`, `OOBE_*`, Abnahme-Reports wie
  bisher `Onboarding-Report_*` (gemeinsamer Geräteordner `Logs\<Serial>`).
- BIOS-Schritt fragt nicht mehr nach Reboot (BIOS wird beim Auto-Reboot nach dem
  Hash-Schritt wirksam); Set-Step-Detail fest `RC=0, angewendet aus OOBE (HEPHAISTOS)`.
- Ohne gefundenen Stick schreibt der Hash-Schritt die CSV nach
  `C:\OSDCloud\HEPHAISTOS\HWID` (gelbe Warnung) statt hart zu scheitern;
  Logs/State fallen ebenfalls auf den Staging-Pfad zurück.
- Technikername (§4.1): Pflicht-Freitext in WinPE, Ablage
  `Logs\<Serial>\technician.txt` + Staging-Kopie; Abnahme bietet ihn als
  Default an; OOBE-Bestätigung schreibt ihn best effort zurück.

**Neue Funktionen (Handoff §4)**

- Assignment-Polling + Auto-Reboot (§4.6): nach erfolgreichem Hash-Upload Graph-
  Polling alle 30 s, max. 60 Polls (30 min), `Write-Progress` mit Poll n/60 und
  verstrichener Zeit, einmalige Token-Erneuerung bei 401; bei
  `deploymentProfileAssignmentStatus -like 'assigned*'` → `shutdown /r /t 10`
  mit Countdown; Timeout → gelber Hinweis auf die GroupTag-Gruppenzuordnung,
  KEIN Reboot. Bei mehreren `contains()`-Treffern wird die exakte Seriennummer
  bevorzugt; transiente Poll-Fehler werden nur dim protokolliert. Nach
  interaktivem Upload (ohne App-Creds) wird das Polling übersprungen (kein
  App-Token möglich) — gelber Hinweis auf manuelle Prüfung.
- `RemoveWinRE`-Flag (§4.7, Default false): gelbe Konsequenz-Warnung + Confirm,
  `reagentc /disable` → Recovery-Partition(en) nur auf der C:-Disk löschen →
  C: maximal erweitern (nur bei Zugewinn > 1 MB) → gestagte `winre.wim` löschen;
  jeder Teilschritt einzeln abgesichert. `reagentc` läuft über `cmd /c … 2>&1`
  (PS-5.1-stderr-Falle); Exit ≠ 0 gilt als „vermutlich bereits deaktiviert“.
  Zusätzlicher Doppelboden: der Schritt prüft das Config-Flag selbst nochmal.
- Per-Check-Konfiguration (§4.4): `config/report-checks.json`, `Invoke-Check -Id`,
  fehlender Key = aktiv, `false` ⇒ SKIPPED „per Config deaktiviert“ (Testblock
  läuft nicht, zählt weder in Exit-Code noch Summary, bleibt sichtbar).
  Entkoppelungen dafür: `CountryCode` wird vor den Checks berechnet (Zeitzonen-
  Check funktioniert auch bei deaktiviertem Hostname-Check);
  `bitlocker-recovery-protector` holt `Get-BitLockerVolume` selbst nach, wenn
  der BitLocker-Check deaktiviert/fehlgeschlagen war.
- Netskope-Sonderfall intuneadm (§4.3): Konsolen-User = `<HOST>\<LocalAdminAccount>`
  (aus `report-checks.json`) ⇒ nur Dienstprüfung `stAgentSvc` (Running +
  Automatic), PASSED-Detail wie im Handoff; sonst nsdiag-Logik unverändert.
  Entscheidung als pure, §9-getestete Funktion `Test-HephLocalAdminSession`.
- Sprachmenü aus `deploy.json.Languages` (Default per `DefaultLanguageKey`),
  OSName/Edition/Activation/MinBuild/GroupTags zentral aus `config/deploy.json`.

**Secrets (§6)**

- `Protect-/Unprotect-HephaistosSecret`: PBKDF2 jetzt explizit SHA-256 mit
  600000 Iterationen (Blob-Format v2 mit KDF-Metadaten). Alte Rev05-Blobs
  (100000/SHA-1) bleiben lesbar; beim nächsten Laden wird automatisch auf v2
  re-encrypted (Migrationspfad §6.1). Per Roundtrip-Test verifiziert.
- `ReportRecipient` und `TeamsWebhookUrl` wandern aus dem Script-Klartext in den
  verschlüsselten Blob `HEPHAISTOS-Secrets\hephaistos.secrets.enc.json` (nur auf
  dem Stick). `TeamsAttachPdf` (unkritisch) liegt neu in `deploy.json` unter
  `Report.TeamsAttachPdf` — dokumentierte Schema-Ergänzung zu Handoff §5.
- Fehlen Secrets, degradiert die Abnahme sauber: Teams/Mail werden mit Hinweis
  übersprungen, Report bleibt auf dem Stick (SEND-REPORTS später).
- `.gitignore` von Anfang an (`*secrets*`, `HEPHAISTOS-Secrets/`, `Logs/`,
  `HWID/`, `*.log`) mit Negationen für `tools/secrets.template.json` und
  `tools/New-HephaistosSecrets.ps1` — Letzteres nötig, weil Git auf Windows
  standardmäßig case-insensitiv matcht und `*secrets*` sonst das Tool-Script
  verschluckt.
- Neu: `.gitattributes` mit `*.cmd -text`. `oobe.cmd` wird zur Laufzeit
  byte-identisch von GitHub raw geladen; cmd.exe-Batch ist nur für CRLF
  garantiert, daher liegen die .cmd-Dateien als CRLF im Repo und dürfen nicht
  normalisiert werden.

**Report / Versand**

- Report-Module als parametrisierte Einzelfunktionen unter `abnahme/report/`
  (kein Script-Scope-Zugriff mehr); Karte/CSS/Layout ansonsten 1:1. Teams-Karte:
  Payload-Feld `slg` und `{{FILEURL}}`-Platzhalter bewusst unverändert
  (Kompatibilität mit dem bestehenden Power-Automate-Flow).
- Reports werden direkt in den Geräteordner `Logs\<Serial>` geschrieben
  (vorher `_SLG\Reports` + Kopie) — ein Ablageort, Rev-Feld jetzt
  `HEPHAISTOS 1.0.0`.
- `Send-QueuedReports`: Logik 1:1 (PDF vor HTML je Basisname, `.sent`-Marker,
  Graph-first mit `graphBroken`-Latch, Outlook-COM-Fallback inkl. Hinweistexte);
  Empfänger jetzt ausschließlich aus dem Secrets-Blob (Passphrase-Abfrage am
  Techniker-PC), fehlender Empfänger = roter Abbruch.

**Werkzeuge / Repo**

- `tools/Build-USB.ps1` (§8): Handoff-Befehlsfolge + Verifikation des
  25H2-OSName gegen `Get-OSDCloudOperatingSystems` (Build-Zeit, §4.2),
  Stick-Sync des Repo-Spiegels nach `_HEPHAISTOS\Fallback\`, Launcher-Erzeugung
  aus den Templates, Ordner-Scaffolding, Abschluss-Checkliste (Secrets-Blob +
  CCTK/vc_redist sind Handarbeit; Repo public schalten). Zusatz: `-SkipUsbCreation`
  für reinen Inhalts-Sync, Auto-Erkennung des Datenvolumes „OSDCloudUSB“.
- `README.md` ergänzt (nicht im Handoff-Layout): Kurzüberblick + Verweise.
- CCTK-Binärdateien und `vc_redist.x64.exe` bleiben auf dem Stick unter
  `_HEPHAISTOS\Tools\` (zu groß/lizenzpflichtig fürs Repo, wie Handoff §3).

### Behobene Bugs (Handoff §7)

1. **Wipe-Flag-Selbstbestätigung** (§7.1): `step2_osinstall.started` wird erst
   unmittelbar vor `Start-OSDCloud` geschrieben — nicht mehr vor der Bestätigung.
   Erkennung „done“ weiterhin nur, wenn das OS-Installationsdatum JÜNGER als das
   Flag ist.
2. **ANLEITUNG-Fehler `CD E:\START-ONBOARDING.cmd`** (§7.2): neue Anleitung
   zeigt durchgängig getrennte Befehle bzw. vollständige Pfadaufrufe.
3. **MinBuild 26100 → 26200** (§7.3): Default kommt aus `config/deploy.json`
   (eine Quelle), Parameter-Override bleibt möglich.
4. **ReportRecipient doppelt gepflegt** (§7.4): nur noch eine Quelle — der
   verschlüsselte Secrets-Blob.
5. **Convert-HtmlToPdf-Quoting** (§7.5): keine eingebetteten Anführungszeichen
   mehr im Argumentwert; `Format-ProcessArg` wrappt Elemente mit Whitespace
   komplett (PS 5.1 `Start-Process` quotet NICHT selbst). Helper per Trockentest
   verifiziert; Hardware-Test mit Leerzeichen-Pfad bleibt offen.
6. **Versions-Drift Footer/Header** (§7.6): eine zentrale Konstante
   `$HephaistosVersion` für Banner, Report-Header und -Footer; der
   `MailSender`-App-Versand-Zweig ist als RESERVIERT kommentiert und bleibt
   funktional.

**Nachgezogen aus dem Review (drei unabhängige Fidelity-Reviews gegen das Original)**

- `Send-TeamsCard`/`Send-HephaistosReport` erhalten `-Serial`/`-Model` explizit
  vom Abnahme-Orchestrator (die parametrisierten Funktionen hätten sonst leere
  Werte in Karte/Betreff gemeldet).
- `START-ABNAHME.cmd` propagiert den Exit-Code des Testscripts
  (`& $f; exit $LASTEXITCODE` — `-Command` gibt sonst immer 0 zurück).
- Der Hash-Schritt signalisiert dem Orchestrator den Auto-Reboot
  (`$Context['AutoReboot']`), damit Zusammenfassung/Transcript nicht gegen den
  laufenden Shutdown laufen.
- Boot übernimmt die RawBase zur Laufzeit aus der geladenen `deploy.json`
  (Spiegel-Refresh + `{{RAWBASE}}`-Ersetzung) statt nur aus der
  Bootstrap-Konstante — eine Quelle, wie in §5 gefordert.
- `Get-HephaistosDeviceInfo`: manuelle Service-Tag-Eingabe als Fallback
  (Port der wmic→powershell→manuell-Kette aus START-ONBOARDING.cmd).
- WinPE ohne gefundenen Stick: rote Warnung + explizite Bestätigung (Flags/Logs
  überleben den Wipe nicht), Geräteordner-Fallback auf die RAM-Disk statt Abbruch.

### Verifiziert (ohne Hardware möglich)

- Alle 14 .ps1 parsen fehlerfrei (`[Parser]::ParseFile`), UTF-8 MIT BOM;
  .cmd-Dateien reines ASCII (CP850-sicher) mit CRLF; JSON-Configs valide.
- Kein PS7-only-Syntax (`??`, ternary, `-Parallel`, 3-Arg-`Join-Path` …).
- Secrets-Grep über den ganzen Baum: keine Treffer der Verbotsliste (§6.4/6.5).
- Trockentests (22/22 PASS): Netskope-Zweigwahl mit den §9-Beispielen,
  SKIPPED-Gate (Detail, nicht ausgeführt, Summary/Exit unverändert),
  Secrets-Roundtrip v2 + Legacy-Blob-Kompatibilität, PDF-Arg-Quoting.

### Offen (nur auf echter Hardware/Umgebung testbar)

- `Get-OSDCloudOperatingSystems`: exakter String `Windows 11 25H2 x64` gegen die
  installierte OSD-Modulversion (Build-Zeit-Check in Build-USB.ps1 eingebaut;
  hier ohne Windows nicht prüfbar). Bei Abweichung: gelisteten String in
  `deploy.json` übernehmen und hier notieren.
- Verhalten von `Start-OSDCloud -ZTI` (kehrt die Kontrolle zum Boot-Script
  zurück? Staging vor Reboot) auf realer Hardware.
- CCTK-Kette auf Dell Pro 16 Plus in echter OOBE (applyconfig.bat / SCE-EXE,
  Exit-Codes, VC++-Workaround 0xC0000135), WinPE-Treiber (Dell, WiFi).
- nsdiag-Ausgabeformat der aktuellen Netskope-Version (`NSTUNNEL_CONNECTED`).
- Hybrid-Join-Pre-Provisioning/Auto-Reseal (Win11 24H2+) auf EINEM Gerät
  verifizieren, bevor es als Standard dokumentiert wird (Handoff §2.4).
- Reale Graph-Antworten beim Assignment-Polling (Statuswerte, Latenz dynamischer
  Gruppen, Drosselung über 30 min); `shutdown /r` im OOBE-Kontext.
- RemoveWinRE auf realem OSDCloud-Partitionslayout (Recovery-Partition hinter C:?),
  WinRE-Rückkehr nach Feature-Updates (`reagentc /info`).
- Convert-HtmlToPdf mit Leerzeichen-Pfad + Edge headless auf frischem Gerät;
  `{{FILEURL}}`/`slg`-Payload gegen den echten Power-Automate-Flow.
- MDM_DevDetail-Hash-Export und PSGallery-Bootstrap in der echten OOBE.
