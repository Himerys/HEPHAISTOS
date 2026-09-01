# CHANGELOG

## 1.3.0 (2026-09-01) — Ein Eingabeblock am Anfang: Passphrase-Handoff, Preflight-Wiederanlauf, deutsche WinPE-Tastatur

Ziel dieses Releases: **alle Techniker-Eingaben an den Anfang ziehen.** Danach
bleibt nur noch der von Microsoft vorgegebene Pre-Provisioning-Block
(Windows-Taste ×5 … Reseal — per Doku nicht automatisierbar, Self-Deploying ist
für Hybrid Join ausgeschlossen) und der Abnahme-Login. Design und Risiken wurden
vor der Umsetzung von einer mehrstufigen Analyse + zwei adversarialen Reviews
geprüft; alle Auflagen sind eingearbeitet.

### Neu

- **Team-Passphrase gleich am Anfang (WinPE) statt mitten im Setup** — mit
  sofortiger Prüfung (Tippfehler fallen in Sekunde 30 auf, nicht in Minute 25).
  Transport zur Specialize-Phase per **Split-Key-Handoff**: Die entsperrten
  Upload-Felder (TenantId, AppId, AppSecret, TeamsWebhookUrl — bewusst NICHT
  die Mail-Felder) werden mit einem zufälligen Einmal-Schlüssel AES-256-
  verschlüsselt; **Ciphertext auf C:, Schlüssel auf dem Stick**. Jede Hälfte
  allein ist kryptographisch wertlos. Die Specialize-Phase prüft Seriennummer
  (live via WMI), Paarungs-Hash und TTL (24 h), entschlüsselt im Speicher und
  **überschreibt + löscht beide Dateien sofort** — Erfolg wie Fehlschlag
  (One-Shot). Neue Lib-Funktionen: `New-HephHandoffKey`, `Save-HephHandoff`,
  `Restore-HephHandoff`, `Clear-HephHandoffKeys`, `Remove-HephSecureFile`
  (Überschreiben vor dem Löschen). Konsum sitzt IN `Get-HephaistosSecrets`
  (Review-Blocker: `$Script:`-Scope reicht nicht über die `&`-Grenze in die
  Schritt-Scripts) und ist auf den OOBE-/Specialize-Kontext begrenzt —
  Abnahme/Send behalten den Passphrase-Weg. Harte Regeln aus dem Review:
  Handoff wird verweigert, wenn Schlüssel und Ciphertext auf demselben Medium
  landen würden (Kein-Stick-Fallback!); halbe Paare werden entsorgt;
  Sweeps beim WinPE-Start (eigene Serial immer, fremde nach TTL — Stick-
  Wandern zwischen parallelen Geräten bleibt möglich) und in der Abnahme.
  **Kein Gate:** 3× falsche Passphrase / kein Blob / kein Stick ⇒ Installation
  läuft normal, die Specialize-Phase fragt wie bisher (voller Fallback).
- **Preflight-Wiederanlauf ohne Neu-Eintippen:** Nach der automatischen
  RAID→AHCI-Umstellung (Neustart) zeigt Lauf 2 eine Zusammenfassung (Gerät,
  Techniker, Sprache, Tag) mit **15-s-Countdown** — nichts drücken heißt
  weiterlaufen, jede Taste heißt normale Eingabe. Die gespeicherte Zustimmung
  ist **einmalig** (wird beim Lesen sofort gelöscht), per Zufalls-Nonce an
  GENAU diesen Umstell-Zyklus gebunden (Nonce steht auch im
  `storage_mode.attempted`-Flag), wird nur akzeptiert, wenn Seriennummer +
  Modell live per WMI passen (manuell eingetippte Seriennummern sind
  ausgeschlossen) und wenn **alle internen Disks nachweislich leer** sind —
  der Uhr wird bewusst nicht vertraut (bekannter WinPE-Skew), leeren Disks
  schon. Geschrieben wird die Zustimmung ausschließlich im Erfolgszweig
  unmittelbar vor dem Neustart, nie nach LOESCHEN selbst und nie in
  Abbruchzweigen. Countdown fail-closed: jede Konsolen-Exception = interaktiv;
  Puffer wird vorher nicht geleert (gepufferte Taste bricht ab = fail-safe).
  Die Passphrase kommt im RAID-Fall erst in Lauf 2 dran (in Lauf 1 rebootet
  das Gerät vor der Abfrage; sie wird bewusst nirgends persistiert) - Lauf 2
  besteht damit aus genau einer Eingabe.
- **Deutsche Tastatur schon in WinPE** (Y/Z-Falle bei Passphrase/LOESCHEN):
  `boot/Start-Hephaistos.ps1` stellt zur Laufzeit per
  `wpeutil SetKeyboardLayout 0407:00000407` um und startet die Konsole
  einmalig neu (das Layout greift nur in neuen Fenstern; Guard per
  Umgebungsvariable, Selbst-Kopie via Repo/Stick-Fallback). Wirkt auf **alle
  existierenden Sticks sofort** (Script kommt live aus dem Repo). Zusätzlich
  baut `tools/Build-USB.ps1` neue Templates mit `-SetInputLocale de-de`
  (der Parameter existiert nur an `New-OSDCloudTemplate`, nicht an
  `Edit-OSDCloudWinPE`).
- **technician.txt jetzt auch in WinPE als Enter-Default:** Der in einem
  früheren Lauf gespeicherte Techniker-Name wird beim erneuten Stick-Boot
  vorgeschlagen (bisher las ihn nur die Abnahme).
- **Neuer Config-Schalter `Oobe.PassphraseUpfront`** (Default `true`):
  schaltet die Passphrase-Vorabfrage + den Handoff ab - dann fragt die
  Specialize-Konsole wie in v1.2.x (passend zum Kill-Switch-Muster von
  `Oobe.AutoLaunch` / `Abnahme.AutoRun`).
- **Doku:** Neues Kapitel 2.7 (Intune-Feinschliff: Autopilot-Profil — EULA/
  Datenschutz/Kontooptionen ausblenden, feste Sprache + Auto-Tastatur nur mit
  LAN; damit schrumpft die End-OOBE auf einschalten → Anmeldung → Desktop);
  Ablauf 3.1/3.2 neu geschrieben (ein Eingabeblock); Kapitel 8 um drei
  Hardware-Checks ergänzt (Tastatur-Neustart, Wiederanlauf inkl. Gegenproben,
  Handoff-Roundtrip inkl. Fallback-Gegenprobe); Kapitel 7 um die
  Handoff-Sicherheitsbetrachtung ergänzt.

### Review-Härtung (3 adversariale Reviewer vor Release; 2 Majors gefunden und behoben)

- **MAJOR behoben:** Ein defekter/halb geschriebener Secrets-Blob (FAT32-
  Klassiker) hätte die neue WinPE-Passphrase-Abfrage als Terminating Error
  abbrechen können - auf dem RAID-Wiederanlauf wäre das Gerät gewiped ohne
  Installation gestrandet. Jetzt: Parse-Guard in `Get-HephaistosSecrets`
  (unlesbarer Blob ⇒ gelbe Warnung + `$null`) UND try/catch um die
  Vorabfrage - das „nie ein Gate"-Versprechen gilt damit auch für Ausnahmen.
- **MAJOR behoben:** Zwei frühe Rückwege in `Restore-HephHandoff` (Serial
  nicht lesbar; Stick-Wurzel = Systemlaufwerk) ließen das Handoff-Paar
  unangetastet liegen. Jetzt wird auf JEDEM Rückweg mindestens der Ciphertext
  geschreddert; zusätzlich schreibt WinPE bei manuell eingetippter
  Seriennummer gar keinen Handoff mehr (Specialize könnte ihn nie zuordnen).
- Kleinere Härtungen: `.tmp`-Reste des atomaren Schreibens werden überall
  mitgeschreddert (Save-Fehlerpfad, Sweep-Filter `handoff.key.json*`,
  Abnahme-Sweep); der Tastatur-Konsolen-Neustart quotet den Pfad und fällt
  bei Startfehler auf das US-Layout-Fenster zurück statt hart zu enden; die
  WinPE-Abschlussmeldung verspricht „ohne weitere Eingabe" nur noch, wenn der
  Handoff wirklich geschrieben wurde.

### Sicherheitsbetrachtung (Kurzfassung)

Ein Angreifer mit NUR Stick oder NUR Gerät gewinnt gegenüber heute nichts
(Zufallsschlüssel ohne Ciphertext bzw. Ciphertext ohne Schlüssel). Das einzige
neue Fenster — Diebstahl BEIDER Medien zwischen Staging und Specialize-Konsum —
ist Minuten kurz, an die physische Anwesenheit des Technikers gebunden und
kleiner als das bestehende akzeptierte Risiko (Stick-Diebstahl + Offline-
Brute-Force gegen die Team-Passphrase, unbegrenzte Zeit). Der Schlüssel wird
NIE aus der Passphrase abgeleitet (sonst wäre der Haupt-Blob auf dem Stick
direkt entsperrbar). Löschen überschreibt vorher den Dateiinhalt (auf Flash
best effort — die echte Rückfallebene bleibt die Rotierbarkeit von App-Secret
und Webhook in Entra ID).

## 1.2.4 (2026-08-27) — UEFI-Boot-Override nach der RAID→AHCI-Umstellung

### Behoben

- **Nach dem Preflight-Neustart (RAID→AHCI) startete das Gerät nicht vom
  Stick, sondern im HTTP-Boot** (Feldtest: HTTP-Boot steht in der
  Werks-Boot-Reihenfolge vor USB — der Techniker musste per F12 erneut den
  Stick wählen). Die bisherige Annahme „leere Disk → Firmware fällt auf den
  Stick durch" gilt nur, wenn kein anderer Boot-Eintrag vorher greift.
- **Fix: Einmaliger UEFI-Boot-Override.** Neue Lib-Funktion
  `Set-HephBootNextToCurrent`: liest die UEFI-Variable `BootCurrent` (der
  Eintrag, von dem das laufende WinPE gebootet wurde = der Stick) und kopiert
  sie nach `BootNext` — der nächste Start geht damit garantiert wieder auf den
  Stick, unabhängig von der Boot-Reihenfolge. `BootNext` gilt genau einmal und
  wird von der Firmware danach automatisch gelöscht; die **dauerhafte
  Boot-Reihenfolge bleibt unangetastet** (kein „USB immer zuerst"-Risiko für
  die Flotte). Technisch: Win32 `Get/SetFirmwareEnvironmentVariableW` im
  EFI-Global-Namespace, inkl. Aktivierung des dafür nötigen Privilegs
  `SeSystemEnvironmentPrivilege` (Add-Type/P-Invoke, PS-5.1-tauglich).
- Eingebaut an allen drei Preflight-Neustarts (automatischer
  Umstell-Zyklus + die beiden Abbruch-Neustarts, nach denen es ebenfalls
  zurück auf den Stick geht). Schlägt der Override fehl (kein UEFI,
  Firmware-Variablen nicht erreichbar), erscheint ein gelber Hinweis und es
  gilt der bisherige Weg: F12 → USB-Stick. Der Neustart nach der
  Installation (→ Windows/Specialize) bleibt bewusst unangetastet.
- Doku: Kapitel 2.5/3.1 (Ablaufbeschreibung) und 8 (neuer Hardware-Check)
  aktualisiert.

### Hinweis für die Flotte

- Die HTTP-Boot-Einträge selbst bleiben bestehen (sie stören nur diesen einen
  automatischen Neustart). Wer sie generell loswerden will, kann HTTPs-Boot im
  CCTK-Paket deaktivieren — das beschleunigt jeden Boot, ist aber eine
  Paket-Entscheidung (betrifft die ganze Flotte) und bewusst nicht Teil dieses
  Fixes.

## 1.2.3 (2026-08-24) — Stick-Warteschleife nach dem Neustart

### Behoben

- **Stick wurde nach dem Neustart nicht erkannt und musste ab-/angesteckt
  werden** (Feldtest): Die Specialize-Konsole startet sehr früh im Boot — der
  USB-Stack ist zu diesem Zeitpunkt oft noch nicht fertig initialisiert und
  das Stick-Volume noch nicht gemountet. Die OOBE-Phase hat den Stick aber nur
  **genau einmal** beim Start gesucht. Jetzt wartet sie bei fehlendem Stick
  **bis zu 90 Sekunden aktiv** (Suche alle 3 s, mit sichtbarem Hinweis inkl.
  Ab-/Anstecken-Tipp) und läuft sofort weiter, sobald der Stick auftaucht —
  ist er direkt da, kostet die Schleife nichts. Nach Ablauf der 90 s greift
  unverändert der bisherige Ohne-Stick-Pfad (gelbe Warnung, Schritte melden
  fehlende CCTK-Tools/Secrets einzeln).
- Doku: Troubleshooting 6.8 ergänzt (Warteschleife, Neu-Enumeration durch
  Ab-/Anstecken, Empfehlung: Stick direkt am Gerät statt in der Dock — Docks
  initialisieren sich beim Boot selbst erst spät).

## 1.2.2 (2026-08-21) — Hash-Upload nativ per Graph-REST (Specialize-Fix)

### Behoben

- **Autopilot-Hash-Upload schlug in der Specialize-Phase immer fehl**
  (Feldtest 2026-08-21, 3× Dell Pro 13 Plus, Dock/Ethernet — identisches Bild
  auf allen drei Geräten): Der Upload lief bis dahin über das
  PSGallery-Script `Get-WindowsAutopilotInfo` (1:1-Port aus Rev05,
  `Install-Script` zur Laufzeit). Unter SYSTEM ohne Benutzerprofil lässt sich
  PowerShellGet aber nicht laden — im Log als
  `TerminatingError(Join-Path): NULL` gefolgt von `Get-PSRepository: Modul
  konnte nicht geladen werden` sichtbar. Export, GroupTag, Passphrase und
  Webhook-Cache liefen durch; nur der Upload starb, das Setup lief (gewollt
  crash-sicher) ohne Profilzuweisung in die OOBE weiter.
- **Fix: Der Upload läuft mit App-Auth jetzt nativ über die Graph-API** —
  POST auf `beta/deviceManagement/importedWindowsAutopilotDeviceIdentities`
  (Serial, GroupTag, Hardware-Hash aus WMI unverändert als Base64), danach
  Import-Status-Polling (alle 15 s, max. 20 Minuten; eine 401-Token-Erneuerung
  wie beim Zuweisungs-Polling). `deviceErrorCode 806 / ZtdDeviceAlreadyAssigned`
  wird als „bereits registriert" = Erfolg gewertet. Das ist intern derselbe
  Weg, den `Get-WindowsAutopilotInfo -Online` nimmt — nur ohne
  PSGallery/PowerShellGet/NuGet-Bootstrap, damit SYSTEM-/Specialize-tauglich.
  Gleiche App-Berechtigung wie bisher (`DeviceManagementServiceConfig.ReadWrite.All`),
  am Secrets-Blob ändert sich nichts. Anschließend unverändert das bestehende
  Profilzuweisungs-Polling + Weiterlauf ins Provisioning.
- Interaktiver Fallback ohne App-Zugang (Microsoft-Anmeldung) bleibt als
  PSGallery-Weg erhalten, aber gehärtet: `Enable-Tls12AndGallery` beendet den
  Aufrufer nicht mehr hart, wenn PowerShellGet nicht ladbar ist, und ein
  Null-Guard ersetzt den kryptischen `Join-Path`-Bindungsfehler durch eine
  klare Meldung.

### Feldtest-Bestätigungen (aus demselben Log)

- Specialize-Autostart: Konsole erscheint, Passphrase-Eingabe funktioniert,
  Tastatur-Fix (de-DE) greift, Techniker + GroupTag werden automatisch
  übernommen, Auto-Abnahme-Aufgabe wird registriert. ✔
- v1.2.1-Webhook-Cache: „Teams-Webhook für die Auto-Abnahme hinterlegt
  (DPAPI)" auf echter Hardware. ✔ (Roundtrip beim Abnahme-Lauf weiter offen.)
- Modell-Mapping: Praxis-Modellname „Dell Pro 13 Plus PB13250" matcht den
  Mapping-Schlüssel „Pro 13 Plus"; Fallback aufs Standard-Paket griff korrekt,
  weil der Ordner `CCTK-Pro13Plus` auf dem Test-Stick fehlte (Stick-Inhalt,
  kein Code-Fehler).

### Review-Härtung (adversarial Review vor Release)

- **Graph-Fehlerdetails sichtbar:** Schlägt der Import-POST fehl (400/403/
  Throttling), zeigt die Fehlermeldung zusätzlich die `error.message` aus dem
  OData-Response-Body — unter PS 5.1 enthält `Exception.Message` sonst nur den
  nackten HTTP-Status, die eigentliche Ursache (fehlende Berechtigung,
  ungültiger Hash, ...) bliebe unsichtbar.
- **Import-Polling-Fenster 20 statt 15 Minuten:** Microsofts dokumentierter
  Worst Case für den Autopilot-Import ist „bis zu 15 Minuten" — das Fenster
  endete exakt dort und hätte einen langsamen, aber erfolgreichen Import als
  Fehler gewertet.

### Hardware-offen

- Nativer Graph-Import gegen den echten Tenant (Import-Status bis `complete`,
  danach Profilzuweisung) — auf den drei wartenden Geräten direkt per
  Shift+F10 → `c:\o.cmd` nachholbar, sobald diese Version auf `main` liegt.

## 1.2.1 (2026-08-21) — Teams-Karte in der Auto-Abnahme (ohne Passphrase)

### Neu

- **Auto-Abnahme postet jetzt die Teams-Karte — ohne Passphrase.** Mechanik:
  Die OOBE-Phase entsperrt die Secrets ohnehin (Hash-Upload); in diesem Moment
  wird NUR die Teams-Webhook-URL zusätzlich **DPAPI-verschlüsselt
  (Machine-Scope)** auf dem Gerät hinterlegt
  (`C:\OSDCloud\HEPHAISTOS\teams.webhook.bin`, neue Lib-Funktionen
  `Save-/Get-HephTeamsWebhookCache`). Die Abnahme nutzt als Webhook-Quelle den
  Secrets-Blob ODER diesen Geräte-Cache — der nicht-interaktive Automatik-Lauf
  kommt damit ohne Passphrase zur Karte. Sicherheitsbetrachtung: kein Klartext
  at rest, nichts im Repo/auf dem Stick, außerhalb genau dieses Geräts
  kryptographisch wertlos (DPAPI-Maschinenschlüssel), verschwindet mit dem
  nächsten Wipe. Wurden die Secrets in der OOBE nicht entsperrt, existiert kein
  Cache und die Karte entfällt still (Dim-Hinweis). Versions-Skew-geschützt
  über Get-Command-Guards. Hardware-offen: DPAPI-Roundtrip auf dem Zielgerät
  (hier nicht ausführbar, Windows-API).

## 1.2.0 (2026-08-14) — Autostart OOBE + Auto-Abnahme

### Neu

- **OOBE-Autostart ohne Shift+F10** (`deploy.json Oobe.AutoLaunch`, Default an):
  Das Boot-Script hängt beim Staging einen RunSynchronous-Eintrag an den
  **Specialize-Pass** des Windows-Setups — per echtem XML-Merge in das von
  OSDCloud gestagte Unattend (dessen Treiber-Injection bleibt unangetastet;
  idempotent, kein Doppel-Eintrag). Beim ersten Boot öffnet sich die
  HEPHAISTOS-Konsole automatisch während „Geräte werden vorbereitet".
  Eleganter Nebeneffekt: Da die Profilzuweisung damit VOR dem OOBE-Start
  bestätigt wird, **entfällt der Auto-Reboot komplett** — das Setup fährt
  einfach fort und die OOBE startet direkt in das Autopilot-Provisioning.
  Im Specialize-Modus wird das GroupTag automatisch aus der WinPE-Vorauswahl
  übernommen (keine vermeidbare Eingabe im Setup-Vollbild); die
  Passphrase-Eingabe bleibt interaktiv. Shift+F10 + `c:\o` bleibt als
  dokumentierter Fallback erhalten (auch wenn der Hook fehlschlägt: gelbe
  Meldung, Ablauf unverändert).
- **Auto-Abnahme nach dem Provisioning** (`deploy.json Abnahme.AutoRun`,
  Default an, `DelayMinutes` konfigurierbar): Die OOBE-Phase registriert die
  geplante Aufgabe `HEPHAISTOS-AutoAbnahme` (SYSTEM, bei Anmeldung, verzögert).
  Der neue Wächter `abnahme/Invoke-AutoAbnahme.ps1` prüft selbstständig:
  regulärer Benutzer angemeldet (kein defaultuser0), Intune Management
  Extension installiert, Stick eingesteckt — sonst wartet er still auf die
  nächste Anmeldung. Dann läuft die Abnahme im neuen **nicht-interaktiven
  Modus** (`-NonInteractive`): Techniker-Name aus der WinPE-Phase, Secrets/
  Teams/Mail übersprungen (Mail wie gehabt später via SEND-REPORTS), Report
  landet automatisch im Geräteordner auf dem Stick. Nach BESTANDENER Abnahme
  entfernt die Aufgabe sich selbst; bei FAILED bleibt sie aktiv und versucht
  es bei der nächsten Anmeldung erneut. Protokoll:
  `C:\OSDCloud\HEPHAISTOS\autoabnahme.log`. Manuelles START-ABNAHME.cmd
  bleibt unverändert möglich (z. B. für Teams-Karte mit Passphrase).
- Abnahme: neuer Parameter `-NonInteractive` (keinerlei Eingaben; sauberes
  Überspringen von Teams/Mail).

### Review-Härtung (adversarial Review vor Release)

- **Setup-Schutz:** Im Specialize-Modus beendet sich `oobe.cmd` IMMER mit
  Exit-Code 0 — ein RunSynchronous-Befehl mit Exit ≠ 0 würde sonst das gesamte
  Windows-Setup abreißen („installation failed in the SPECIALIZE phase").
  Onboarding-Fehler stehen in Logs/Flags und sind manuell nachholbar.
- **Kein unsichtbares Hängen:** `Get-HephaistosDeviceInfo` bekommt `-NoPrompt`;
  der nicht-interaktive Abnahme-Lauf bricht bei unlesbarem Service Tag sauber
  ab, statt als verstecktes SYSTEM-Fenster ewig auf Read-Host zu warten. Der
  Auto-Abnahme-Wächter bekommt zusätzlich ein 90-Minuten-Timeout (hängender
  Kindprozess wird beendet, nächste Anmeldung versucht es erneut) und einen
  Exit-Code-Ersatzpfad für die Selbst-Entfernung.
- Specialize-Modus übernimmt auch den **Technikernamen** automatisch aus der
  WinPE-Phase (konsistent zum GroupTag — einzige Eingabe ist die Passphrase).
- `oobe.cmd` reagiert nur noch auf das echte `/specialize`-Argument (nicht auf
  eine zufällig geerbte Umgebungsvariable); ANLEITUNG 3.2/3.3 präzisiert
  (Polling sichtbar in der Setup-Konsole; reboot-freier Standardweg).

## 1.1.0 (2026-08-14) — Multi-Modell, Storage-Preflight, Bedienkomfort

### Neu

- **Storage-Modus-Preflight in WinPE (kritischer Fix):** Werks-BIOS = RAID/VMD,
  Ziel = AHCI. Der Wechsel darf NICHT nach der Windows-Installation passieren
  (Boot-Treiber-Stack passt dann nicht mehr → INACCESSIBLE_BOOT_DEVICE — der
  bisherige OOBE-BIOS-Schritt hätte genau das ausgelöst). Neu: VOR
  `Start-OSDCloud` wird der Modus per cctk geprüft; bei Abweichung: Disk leeren
  → Modus setzen → Neustart (leere Disk bootet automatisch wieder vom Stick,
  kein F12) → zweiter Durchlauf installiert direkt im Zielmodus.
  Loop-Schutz über State-Flag `storage_mode.attempted`; konfigurierbar über
  `deploy.json Bios.StorageMode` (Default `Ahci`, `Keep` = aus); nicht
  abfragbare Option/fehlendes cctk = Preflight wird sauber übersprungen.
- **Multi-Modell-Unterstützung (5 Modelle):** `Bios.Packages` in `deploy.json`
  mappt Modell-Teilstrings auf CCTK-Paket-Ordner unter `_HEPHAISTOS\Tools\`
  (z. B. `"Pro 13 Plus" → CCTK-Pro13Plus`). Auflösung automatisch am
  WMI-Modellnamen, längster Treffer gewinnt („Pro 14 Premium" schlägt
  „Pro 14"); fehlender Modell-Ordner fällt auf `DefaultPackage` (CCTK) zurück —
  vollständig rückwärtskompatibel. Neue Lib-Funktion `Get-HephBiosPackageDir`
  (pure, trockengetestet). Treiber brauchen keine Konfiguration: OSDCloud zieht
  den Dell-Treiberpack passend zum Modell automatisch.
- **GroupTag-Vorauswahl in WinPE:** Der Tag wird schon im Boot-Dialog bestätigt
  (Vorschlag aus der gewählten Sprache via `Languages[n].GroupTag`), wandert
  über `install.json` in die OOBE-Phase und ist dort nur noch mit Enter zu
  bestätigen (Umwahl per Nummer weiter möglich).
- **Tastatur-Layout-Fix in der OOBE:** Die Konsole wird automatisch auf das
  Layout der Installationssprache gestellt (`Set-WinUserLanguageList`, best
  effort) — die US-Layout-Falle (Y/Z vertauscht) bei der Passphrase ist
  entschärft.
- **Kurzbefehl `c:\o`:** Das Boot-Script staged zusätzlich `C:\o.cmd` —
  in der OOBE-Konsole reicht `c:\o` statt des langen Pfads.
- Build-USB-Checkliste listet die konfigurierten Modell-Paket-Ordner auf;
  ANLEITUNG entsprechend erweitert (Multi-Modell, Preflight, Kurzbefehl).

### Review-Härtung (adversarial Review vor Release)

- Preflight-Abfrage nutzt korrekt `--embsataraid` (ohne `--` hätte cctk die
  Abfrage als Subkommando missverstanden und der Preflight wäre stillschweigend
  wirkungslos geblieben); bei nicht matchender Ausgabe wird die cctk-Antwort
  als Diagnose mitgeloggt.
- **Brick-Schutz durchgezogen:** Entscheidet der Techniker, unter dem
  „falschen" Modus zu installieren, wird das Flag `storage_mode.keep` gesetzt —
  der OOBE-BIOS-Schritt wendet das CCTK-Paket dann nur nach harter roter
  Rückfrage an (EmbSataRaid im Paket würde das frische Windows unbootbar machen).
- Erfolgskriterium der Umstellung ist jetzt ausschließlich der Exit-Code
  (kein Text-Match mehr, der auf „UNSUCCESSFUL" hereinfallen konnte), mit
  definiertem `$LASTEXITCODE`-Reset davor.
- Ohne Stick kein automatischer Umstell-Zyklus (das Schutz-Flag würde den
  Neustart nicht überleben → Endlos-Loop-Gefahr) — stattdessen interaktive
  Entscheidung.
- Disk-Auswahl auf interne Bus-Typen begrenzt (NVMe/SATA/SAS/RAID/ATA —
  Thunderbolt-/SD-/USB-Medien sind sicher) und es werden ALLE internen Disks
  geleert (zweite Disk mit Rest-OS hätte sonst den Stick-Autoboot verhindert).
- cctk.exe-Suche bevorzugt das x64-Binary (WinPE x64 hat kein WOW64).
- Versions-Skew-Schutz: läuft eine veraltete Lib-Kopie ohne
  `Get-HephBiosPackageDir`, wird der Preflight sauber übersprungen bzw. das
  Standard-Paket verwendet statt hart zu crashen.

## 1.0.5 (2026-08-13) — Feedback aus der Testphase (2)

### Behoben

- **Assignment-Polling erkannte die Profilzuweisung nie:**
  `deploymentProfileAssignmentStatus` existiert NUR im Graph-**beta**-Endpunkt —
  v1.0 liefert die Property gar nicht, der Status blieb leer und das Polling
  lief trotz erfolgter Zuweisung immer in den 30-Minuten-Timeout. Polling und
  Registrierungs-Vorabprüfung nutzen jetzt `/beta/` (die App-Berechtigung deckt
  das ab); die Vorabprüfung zeigt zusätzlich den aktuellen Zuweisungs-Status,
  und ein leerer Status wird einmalig als Diagnose-Hinweis gemeldet.
- **Abnahme: `entra-prt` in lokaler Admin-Session jetzt SKIPPED.** Meldet sich
  der lokale LAPS-Admin (`<HOST>\<LocalAdminAccount>`) an der Konsole an, hat
  das lokale Konto konstruktionsbedingt keinen Entra-PRT — der Test war in
  dieser Konstellation immer falsch-rot bzw. landete im generischen INFO-Zweig.
  Jetzt: SKIPPED mit klarem Hinweis („SSO als Mitarbeiter separat prüfen").
  Die Entscheidung nutzt dieselbe geprüfte Funktion wie der Netskope-Sonderfall;
  `LocalAdminAccount` wird zentral aufgelöst (eine Quelle für beide Checks).
  Netskope-Verhalten unverändert: Admin-Session = nur Dienststatus, sonst
  nsdiag-Steering-Prüfung.

## 1.0.4 (2026-08-12) — Feedback aus der Testphase

### Neu

- **oobe.cmd fordert Adminrechte selbst an** (fltmc-Probe + UAC-Relaunch, wie
  START-ABNAHME.cmd): In der OOBE-Konsole ändert sich nichts (bereits elevated),
  aber Nachläufe aus dem fertigen Windows scheitern nicht mehr am fehlenden
  Admin-Kontext (BIOS-Schritt braucht Elevation). Hinweis: gilt für neu
  gestagte Geräte; bereits installierte Testgeräte tragen noch die alte Kopie
  unter C:\OSDCloud\HEPHAISTOS\.
- **Autopilot: Vorabprüfung auf bestehende Registrierung.** Vor dem Upload wird
  die Seriennummer per Graph gesucht (exakter Treffer erforderlich). Bereits
  registrierte Geräte überspringen den Upload (kein Doppel-Import), melden das
  hinterlegte GroupTag (mit Warnung bei Abweichung zur aktuellen Auswahl) und
  gehen direkt ins Assignment-Polling. Schlägt die Vorabprüfung fehl, läuft der
  Upload normal weiter.

### Behoben

- **Schritt-2-Erkennung jetzt uhr-frei.** Primärer Nachweis ist die vom
  Boot-Script NACH Start-OSDCloud auf das frische C: geschriebene
  `install.json` (Seriennummern-Abgleich) — ein Werks-OS kann diese Datei nicht
  besitzen, Zeitzonen/FAT-Zeitstempel spielen keine Rolle mehr. Der
  Zeitstempel-Vergleich mit 26-h-Toleranz (1.0.3) bleibt als Fallback erhalten.

## 1.0.3 (2026-08-10) — Erkenntnisse aus dem ersten Hardware-Test (Dell Pro 16 Plus)

### Behoben

- **BIOS-Schritt: Teilerfolg wurde als Fehlschlag gewertet.** Praxisfund: cctk
  endet mit `CCTK STATUS CODE : FAILURE` (RC 146), wenn auch nur EINE
  hardwareabhängige Option nicht anwendbar ist (beobachtet: `Wimob` auf einem
  Gerät ohne WWAN-Modul) — obwohl alle übrigen Einstellungen inkl.
  BIOS-Admin-Passwort gesetzt wurden. Der Schritt wertet bei RC != 0 jetzt das
  CCTK-Log aus: nicht anwendbare Optionen ⇒ GELB („angewendet MIT HINWEISEN",
  Flag `step1_bios.done` wird gesetzt, Optionen werden benannt);
  passwort-relevante oder unbekannte Fehler bleiben ROT. Sicherheitsnetz
  unverändert: Die Abnahme prüft das BIOS-Admin-Passwort separat.
- **Schritt-2-Erkennung scheiterte am WinPE-Zeitzonen-Versatz.** Praxisfund:
  OSDCloud-WinPE steht standardmäßig auf Pacific Time; FAT/exFAT-Sticks
  speichern Ortszeit ohne Zonenbezug. Der Flag-Zeitstempel lag dadurch
  scheinbar ~10 h in der Zukunft, das echte Installationsdatum wirkte „älter"
  ⇒ `step2_osinstall.done` wurde nie gesetzt. Zwei Ebenen behoben:
  (1) Boot stellt WinPE per `tzutil` auf CET (best effort; Flotte DE/FR/PL ist
  einheitlich CET/CSET), (2) die Erkennung bekommt ein 26-h-Toleranzfenster —
  ein Werks-OS ist Tage bis Wochen älter und fällt weiterhin sicher durch.

## 1.0.2 (2026-08-07)

### Neu

- **Build-USB.ps1 Schritt 0 — ADK-Vorprüfung:** `New-OSDCloudTemplate` scheitert
  ohne Windows ADK mit der wenig hilfreichen Meldung "Could not get ADK going".
  Das Script prüft jetzt VOR allen Aktionen, ob Deployment Tools UND das
  separat zu installierende WinPE-Add-on vorhanden sind (Registry
  `Installed Roots\KitsRoot10` + Ordnerprüfung), und gibt sonst eine deutsche
  Anleitung mit beiden Downloads aus (häufige Stolperfalle: nur adksetup.exe
  installiert, adkwinpesetup.exe vergessen).

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
