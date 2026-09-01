# HEPHAISTOS — Techniker-Anleitung

**SLG Notebook-Onboarding (HEPHAISTOS) v1.3.0** — portiert und korrigiert aus dem
USB_ScriptTool (Rev03–Rev05). Diese Anleitung beschreibt den **neuen** Ablauf:
kompletter Disk-Wipe via OSDCloud, Neuaufbau nach Vorlage, alle Scripts kommen zur
Laufzeit aus dem GitHub-Repo. Der USB-Stick ist statisch und wartungsfrei.

Alle Laufwerksbuchstaben in dieser Anleitung sind **Beispiele**: `E:` steht für den
USB-Stick (der tatsächliche Buchstabe kann abweichen — im Explorer bzw. in der
Eingabeaufforderung prüfen). Beispiel-Hostname: `SLGDE-XXXXXXX`.

---

## Inhalt

1. [Überblick und Architektur](#1-überblick-und-architektur)
2. [Einmalige Einrichtung](#2-einmalige-einrichtung)
3. [Ablauf pro Gerät](#3-ablauf-pro-gerät)
4. [Abnahme und Reports](#4-abnahme-und-reports)
5. [Konfiguration](#5-konfiguration)
6. [Troubleshooting](#6-troubleshooting)
7. [Sicherheits- und Secrets-Policy](#7-sicherheits--und-secrets-policy)
8. [Offene Hardware-Verifikationen](#8-offene-hardware-verifikationen)

---

## 1. Überblick und Architektur

HEPHAISTOS schmiedet aus roher Dell-Hardware fertige Flottengeräte. Der Ablauf hat
vier Phasen; jede Phase lädt ihr Script **zur Laufzeit aus GitHub** und fällt bei
fehlendem Netz auf eine lokale Kopie zurück (gelbe Warnung mit Versionsangabe):

```
USB-Stick (OSDCloud WinPE, statisch)
  └─ StartURL ──> GitHub raw ──> boot/Start-Hephaistos.ps1
                                   ├─ Technikername + Sprachauswahl + Bestätigung
                                   └─ Start-OSDCloud -ZTI  (kompletter Wipe + Windows 11 25H2)
OOBE (Shift+F10)
  └─ C:\OSDCloud\HEPHAISTOS\oobe.cmd ──> GitHub raw ──> oobe/Invoke-HephaistosOnboarding.ps1
                                   ├─ BIOS-Konfiguration (CCTK vom Stick)
                                   ├─ optional: WinRE entfernen (Config-Flag, Default aus)
                                   └─ Autopilot-Hash + Profilzuweisungs-Polling + Auto-Reboot
Autopilot-Provisioning (Hybrid Entra Join — Join-Modell unverändert)
Fertiges Windows (Abnahme)
  └─ E:\START-ABNAHME.cmd ──> abnahme/Test-HephaistosDevice.ps1
                                   └─ Report (TXT/JSON/HTML/PDF) + Teams-Karte + Mail-Queue
Techniker-PC
  └─ E:\SEND-REPORTS.cmd  (sendet alle offenen Reports gesammelt)
```

**Grundprinzipien:**

- **Scripts live aus GitHub:** Änderungen im Repo wirken sofort auf alle Sticks —
  kein Versions-Drift mehr. Jedes Script zeigt beim Start ein **Versions-Banner**
  mit Version und Quelle (GitHub-URL oder "lokale Kopie: `<Pfad>`").
- **Offline-Fallback:** Ohne Internet nutzt jede Phase den Repo-Spiegel auf dem
  Stick (`E:\_HEPHAISTOS\Fallback\`) bzw. auf `C:` — erkennbar an einer **gelben**
  OFFLINE-FALLBACK-Warnung inkl. Stand der lokalen Kopie.
- **Status pro Gerät:** Der Stick bleibt während des gesamten Ablaufs eingesteckt.
  Alles Sichtbare liegt im Geräteordner `E:\Logs\<ServiceTag>\` (Transcripte,
  Reports, CSV-Kopien, Technikername, Status-Flags unter `state\`).
- **Join-Modell:** Die Flotte ist **Hybrid Entra joined**. Die Abnahme prüft
  `AzureAdJoined` UND `DomainJoined` = YES. Nichts an diesem Modell ändern.

---

## 2. Einmalige Einrichtung

### 2.1 GitHub-Repo anlegen und PUBLIC schalten

Das Repo **muss public sein**: Die StartURL im WinPE und alle `raw.githubusercontent.com`-
Abrufe (oobe.cmd, Abnahme, Config-Refresh) laufen **unauthentifiziert**. Ein privates
Repo liefert dort 404 und der Stick startet nur noch im Offline-Fallback.

> **WICHTIG:** Public Repo heißt: **niemals** Secrets, Tenant-/App-IDs, Webhook-URLs,
> personenbezogene Mailadressen oder echte Seriennummern ins Repo. Details in
> [Kapitel 7](#7-sicherheits--und-secrets-policy).

Danach in `config/deploy.json` prüfen, dass `Repo.RawBase` auf das eigene Repo zeigt,
z. B.:

```
https://raw.githubusercontent.com/Himerys/HEPHAISTOS/main
```

### 2.2 App-Registrierung (Entra ID)

Für Hash-Upload und Profilzuweisungs-Polling wird die bestehende App-Registrierung
genutzt. Benötigte **Application**-Berechtigung (Microsoft Graph):

| Berechtigung | Zweck |
|---|---|
| `DeviceManagementServiceConfig.ReadWrite.All` | Autopilot-Import **und** Lesen des Zuweisungsstatus (deckt beides ab) |
| `Mail.Send` (optional) | nur für den reservierten App-Mailversand (`MailSender`) — im Standard nicht nötig |

Der Sammel-Mailversand vom Techniker-PC (SEND-REPORTS) nutzt das persönliche SSO
des Technikers (delegiertes `Mail.Send`), keine App-Berechtigung.

### 2.3 Secrets-Blob erstellen (verschlüsselt, nur auf dem Stick)

Am Admin-PC im Repo-Checkout ausführen — **zwei Schritte** (erst Verzeichnis
wechseln, dann Aufruf):

```bat
cd /d C:\Repos\HEPHAISTOS
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\New-HephaistosSecrets.ps1
```

Abgefragt werden: Tenant-ID, App-ID, Client Secret, Report-Empfänger
(z. B. `it-team@example.com`), Teams-Webhook-URL (optional), MailSender (optional,
reserviert) sowie eine **Team-Passphrase** (2x). Ergebnis:

```
E:\HEPHAISTOS-Secrets\hephaistos.secrets.enc.json
```

AES-256-verschlüsselt (PBKDF2-SHA-256, 600.000 Iterationen). Die Datei liegt **nur
auf dem Stick**, nie im Repo. Alte Blobs (100k/SHA-1) bleiben lesbar und werden beim
nächsten Entsperren automatisch neu verschlüsselt.

### 2.4 USB-Stick bauen (Build-USB)

Am Admin-PC (Administrator-PowerShell, Internet erforderlich):

```bat
cd /d C:\Repos\HEPHAISTOS
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Build-USB.ps1
```

Das Script installiert das OSD-Modul, erstellt Template/Workspace, baut das WinPE
mit `-CloudDriver Dell,WiFi` und der StartURL auf `boot/Start-Hephaistos.ps1`,
erzeugt den Stick (`New-OSDCloudUSB`) und synchronisiert danach:

- `E:\_HEPHAISTOS\Fallback\` — 1:1-Spiegel des Repos (Offline-Fallback),
- `E:\START-ABNAHME.cmd` und `E:\SEND-REPORTS.cmd` in den Stick-Root,
- leere Ordner `HEPHAISTOS-Secrets\`, `Logs\`, `HWID\`, `_HEPHAISTOS\Tools\`.

Zum späteren **Aktualisieren nur der Stick-Inhalte** (Fallback-Spiegel + CMDs, ohne
WinPE-Neubau): `-SkipUsbCreation` anhängen.

### 2.5 CCTK und VC++-Runtime auf den Stick kopieren (manuell)

Die Dell-Werkzeuge sind zu groß bzw. lizenzpflichtig fürs Repo und werden von
Build-USB als Abschluss-Checkliste ausgegeben. Manuell nach `E:\_HEPHAISTOS\Tools\`
kopieren:

| Datei/Ordner | Zweck |
|---|---|
| `CCTK\` (mit `applyconfig.bat`) | **bevorzugt:** vorentpacktes CCTK-Paket — umgeht die fehleranfällige SCE-Selbstextraktion |
| `Pro16Plus_CCTK_x64.exe` | SCE-Fallback, falls kein vorentpacktes Paket vorliegt |
| `vc_redist.x64.exe` | VC++-Runtime-Workaround für die SCE-Selbstextraktion (siehe [6.1](#61-bios-cctk-extraction-error--0xc0000135)) |

Vorentpacktes Paket erzeugen (am Admin-PC): `Pro16Plus_CCTK_x64.exe /s /e=C:\Temp\CCTK`,
danach den Inhalt von `C:\Temp\CCTK` nach `E:\_HEPHAISTOS\Tools\CCTK\` kopieren.

**Mehrere Modelle (ab v1.1.0):** `config/deploy.json` → `Bios.Packages` mappt
Modell-Teilstrings auf eigene Paket-Ordner, z. B. `"Pro 13 Plus": "CCTK-Pro13Plus"`
→ `E:\_HEPHAISTOS\Tools\CCTK-Pro13Plus\applyconfig.bat`. Das passende Paket wird
zur Laufzeit **automatisch am Modellnamen erkannt** (längster Treffer gewinnt);
fehlt der Modell-Ordner auf dem Stick, greift automatisch das Standard-Paket
(`Bios.DefaultPackage`, Default `CCTK`). Pro Modell also einfach das SCE am
Referenzgerät exportieren, entpacken und in den jeweiligen Ordner legen —
Build-USB listet die konfigurierten Ordner in der Abschluss-Checkliste.

**Storage-Modus (ab v1.1.0):** `Bios.StorageMode` (Default `Ahci`) wird schon in
der **WinPE-Phase vor der Installation** geprüft und bei Bedarf umgestellt —
ein Wechsel RAID→AHCI *nach* der Installation würde Windows nicht mehr booten
lassen. Steht das Werksgerät auf RAID, leert HEPHAISTOS die Disk, stellt um und
startet neu; der zweite Durchlauf installiert dann direkt unter AHCI. Seit
v1.2.4 setzt das Script vor diesem Neustart einen **einmaligen UEFI-Boot-Override
(`BootNext`)** auf den Stick — das Gerät startet damit auch dann direkt wieder
vom Stick, wenn in der Boot-Reihenfolge z. B. HTTP-Boot an erster Stelle steht
(die dauerhafte Reihenfolge bleibt unverändert). Schlägt der Override fehl,
erscheint ein gelber Hinweis: dann wie früher F12 → USB-Stick wählen.
`"StorageMode": "Keep"` schaltet den Preflight ab.

### 2.6 Erstverifikation

Vor dem Flotteneinsatz **ein** Gerät mit GroupTag `SLGTEST` komplett durchlaufen
lassen und die Punkte aus [Kapitel 8](#8-offene-hardware-verifikationen) abhaken.

### 2.7 Intune-Feinschliff: Autopilot-Profil (optional, keine Script-Änderung)

Die Windows-Taste ×5 → Provision → **Reseal** sind von Microsoft bewusst
interaktiv (kein unterstützter Autostart; Self-Deploying ist für Hybrid Join
ausgeschlossen). Was sich aber sehr wohl reduzieren lässt: die **End-OOBE nach
dem Reseal** — per Einstellungen im Autopilot-Deployment-Profil (Intune-Portal,
kein HEPHAISTOS-Bestandteil):

| Profileinstellung | Wirkung |
|---|---|
| Microsoft-Software-Lizenzbedingungen: **Ausblenden** | EULA-Seite entfällt |
| Datenschutzeinstellungen: **Ausblenden** | Privacy-Seite entfällt (Hinweis: Ortungsdienste sind dann standardmäßig aus — bei Bedarf per Intune-Richtlinie aktivieren) |
| Optionen zum Ändern des Kontos: **Ausblenden** | erfordert Entra-Company-Branding |
| Sprache/Region **fest** + Tastatur **automatisch konfigurieren** | Sprach-/Tastaturseiten entfallen — **nur mit LAN/Dock** (bei WLAN müssen die Seiten für die WLAN-Auswahl sichtbar bleiben) |

Damit schrumpft der Endnutzer-Teil auf: einschalten → Anmeldung → Desktop.
Zwei Praxis-Hinweise: Mit fester Sprache springt die OOBE schnell zur
Anmeldeseite — die Windows-Taste ×5 für das Pre-Provisioning funktioniert auch
dort. Und seit dem Januar-2026-Update gibt es einen bekannten, von Microsoft
noch offenen Fehler, dass nach dem Reseal der Benutzername (UPN) manuell
einzutippen ist, statt vorausgefüllt zu sein.

---

## 3. Ablauf pro Gerät

Der Stick bleibt während **aller** Phasen eingesteckt (Logs, State, CCTK, Secrets).

### 3.1 Phase 1 — WinPE: Wipe + Windows-Installation

1. Gerät einschalten, **F12** drücken, den USB-Stick (UEFI-Eintrag) booten.
2. OSDCloud-WinPE startet und lädt `boot/Start-Hephaistos.ps1` aus GitHub
   (LAN bevorzugt; WLAN wird vom OSDCloud-WinPE unterstützt). Ab v1.3.0 stellt
   das Script zuerst die **deutsche Tastatur** ein (die Konsole startet dafür
   einmalig neu — kein Fehler) — Passphrase und `LOESCHEN` tippen sich damit
   ohne Y/Z-Falle. Das Versions-Banner zeigt Version, Quelle, Modell und
   Service Tag.
3. **Der eine Eingabeblock** (ab v1.3.0 alles an einem Stück, danach ist bis
   zur Windows-Taste ×5 nichts mehr zu tun):
   - **Technikername** (Pflichtfeld; Enter übernimmt den Namen vom letzten
     Lauf, falls vorhanden),
   - **Sprache** (`1` = Deutsch, Enter genügt),
   - **Group Tag** (aus der Sprache vorausgewählt, Enter genügt),
   - **ROTER Warnblock** → `LOESCHEN` eintippen (jede andere Eingabe bricht ab),
   - **Team-Passphrase** — wird **sofort geprüft** (Tippfehler fallen hier auf,
     nicht erst in der Specialize-Konsole). 3× falsch/kein Blob: kein Abbruch —
     die Installation läuft weiter und die Specialize-Phase fragt wie früher.
     (Konfigurierbar über `Oobe.PassphraseUpfront`.)
     **RAID-Werksgerät:** Die Passphrase kommt erst in dem Durchlauf dran, der
     wirklich installiert — steht das BIOS noch auf RAID, rebootet das Gerät
     zuerst (nächster Punkt) und fragt die Passphrase dann in Lauf 2 (sie wird
     bewusst nirgends zwischengespeichert).
4. **Storage-Modus-Preflight** (nur beim ersten Durchlauf): Steht das Werks-BIOS
   auf RAID, leert das Script die Disk, stellt auf AHCI um und startet neu — das
   Gerät bootet per `BootNext` **automatisch wieder vom Stick**. Ab v1.3.0
   erscheint dann eine **Wiederanlauf-Zusammenfassung** (Gerät, Techniker,
   Sprache, Tag) mit 15-Sekunden-Countdown: nichts drücken = es läuft ohne
   Neu-Eintippen weiter, nur die Passphrase wird in Lauf 2 abgefragt (erste und
   einzige Eingabe dort); beliebige Taste = normale Eingabe. Der Wiederanlauf
   greift nur, wenn Seriennummer/Modell live passen, die Zustimmung aus GENAU
   diesem Umstell-Zyklus stammt (Einmal-Nonce) und **alle internen Disks
   nachweislich leer sind** — sonst wird ganz normal gefragt.
5. Danach läuft alles automatisch: `Start-OSDCloud -ZTI` installiert
   **Windows 11 25H2** in der gewählten Sprache (ESD-Download, je nach Netz ca.
   20–40 Minuten). Anschließend staged das Script `C:\OSDCloud\HEPHAISTOS\`
   (oobe.cmd, Repo-Spiegel, Gerätedaten) und schreibt den
   **Split-Key-Handoff**: die in Schritt 3 entsperrten Zugänge, verschlüsselt
   mit einem Einmal-Schlüssel — Daten auf `C:`, Schlüssel auf dem Stick. Jede
   Hälfte allein ist wertlos; die Specialize-Phase verbraucht beide und löscht
   sie sofort. Neustart nach 10-Sekunden-Countdown.

Erst mit der `LOESCHEN`-Bestätigung wird das Flag `step2_osinstall.started`
geschrieben — ein Abbruch hinterlässt keinen falschen Status (behobener Fehler der
alten Version).

### 3.2 Phase 2 — OOBE: BIOS + Autopilot-Hash

**Autostart (ab v1.2.0, Default an):** Ist `Oobe.AutoLaunch` aktiv, öffnet sich
die HEPHAISTOS-Konsole nach dem Neustart **automatisch** während „Geräte werden
vorbereitet" (Specialize-Pass des Windows-Setups) — Shift+F10 entfällt. GroupTag
und Technikername kommen automatisch aus der WinPE-Phase; die Zugänge für den
Hash-Upload kommen ab v1.3.0 aus dem **Split-Key-Handoff** — es ist also
**keine Passphrase-Eingabe mehr nötig** (nur falls der Handoff fehlt oder
ungültig ist, erscheint der Passphrase-Prompt wie früher). Das anschließende
Profilzuweisungs-Polling (bis zu 30 min) läuft sichtbar in dieser Konsole —
das Setup ist dann nicht „hängen geblieben". Nach bestätigter Profilzuweisung fährt
das Setup einfach fort und die OOBE startet **ohne zusätzlichen Neustart**
direkt in das Autopilot-Provisioning.

Der folgende manuelle Weg gilt als **Fallback** (Autostart deaktiviert oder
fehlgeschlagen — dann erscheint die Region-Auswahl wie gewohnt):

1. **Shift+F10** drücken — eine Eingabeaufforderung öffnet sich.
2. Das gestagte Onboarding starten — **entweder** in zwei Schritten:

   ```bat
   cd /d C:\OSDCloud\HEPHAISTOS
   oobe.cmd
   ```

   **oder** direkt mit vollem Pfad als ein Befehl:

   ```bat
   C:\OSDCloud\HEPHAISTOS\oobe.cmd
   ```

   **oder** am kürzesten (ab v1.1.0):

   ```bat
   c:\o
   ```

   Die Konsole stellt sich automatisch auf das Tastatur-Layout der gewählten
   Installationssprache um (ab v1.1.0) — die Y/Z-Falle bei der Passphrase ist
   damit entschärft.

> **ACHTUNG — bekannter Fehler der alten Anleitung:** `cd` und Dateiaufruf **niemals
> mischen**. `cd C:\OSDCloud\HEPHAISTOS\oobe.cmd` ist **kein** gültiger Befehl
> (`cd` erwartet ein Verzeichnis, keine Datei) und schlägt fehl. Immer eine der
> beiden oben gezeigten Varianten verwenden.

Die `oobe.cmd` lädt die jeweils aktuelle Version von
`oobe/Invoke-HephaistosOnboarding.ps1` aus GitHub (Fallback: lokale Kopie) und führt
aus:

1. **BIOS-Konfiguration** (CCTK vom Stick, 30–90 Sekunden). Kein separater Neustart —
   die Einstellungen werden mit dem automatischen Reboot nach dem Hash-Schritt wirksam.
2. **Optional: WinRE entfernen** — nur wenn `RemoveWinRE` in `config/deploy.json`
   auf `true` steht (Default: `false`). Konsequenzen siehe [5.3](#53-removewinre-flag-mit-konsequenzen).
3. **Autopilot-Hash:**
   - Offline-Export **immer zuerst**: CSV nach `E:\HWID\<ServiceTag>.csv`
     (Backup, Kopie im Geräteordner).
   - **GroupTag** wählen: `SLGDE` / `SLGFR` / `SLGPL` / `SLGTEST` — wird direkt in
     die CSV eingetragen und beim Upload mitgegeben.
   - Online-Upload nach Intune mit dem gespeicherten App-Zugang. Die Zugänge
     kommen ab v1.3.0 aus dem **WinPE-Handoff** (keine Passphrase-Eingabe);
     nur wenn der Handoff fehlt oder ungültig ist, wird die **Team-Passphrase**
     abgefragt. Ohne Netz oder ohne Zugänge bleibt die Offline-CSV gesichert;
     der Import kann später manuell erfolgen.
4. **Profilzuweisungs-Polling:** Nach erfolgreichem Upload fragt das Script alle
   30 Sekunden (max. 30 Minuten, mit Fortschrittsanzeige) den Zuweisungsstatus des
   Autopilot-Deployment-Profils ab.
   - **Zugewiesen:** grüne Meldung, automatischer Neustart nach 10-Sekunden-Countdown —
     das Gerät bootet direkt ins Autopilot-Provisioning.
   - **Timeout:** gelbe Meldung `Profilzuweisung prüfen: Gruppenzuordnung des
     GroupTags` — **kein** automatischer Neustart. Siehe [6.5](#65-profilzuweisung-timeout-beim-polling).

**Auto-Abnahme (ab v1.2.0, Default an):** Die OOBE-Phase merkt die geplante
Aufgabe `HEPHAISTOS-AutoAbnahme` vor (SYSTEM, startet verzögert nach einer
Anmeldung). Sie wartet selbstständig, bis das Provisioning durch ist (regulärer
Benutzer angemeldet, Intune Management Extension installiert, Stick eingesteckt)
und führt die Abnahme dann **unsichtbar und ohne Eingaben** aus — Report landet
automatisch im Geräteordner auf dem Stick, Protokoll unter
`C:\OSDCloud\HEPHAISTOS\autoabnahme.log`. Nach bestandener Abnahme entfernt sich
die Aufgabe selbst. **Die Teams-Karte wird auch im Automatik-Lauf gepostet** —
ohne Passphrase: Die OOBE-Phase hinterlegt den Webhook beim Secrets-Entsperren
DPAPI-verschlüsselt auf dem Gerät (ab v1.2.1; nur nutzbar auf genau diesem
Gerät, verschwindet mit dem nächsten Wipe). Wurden die Secrets in der OOBE
nicht entsperrt, entfällt die Karte still. Direkt-Mail entfällt im
Automatik-Lauf immer (Mail kommt wie gewohnt gesammelt über SEND-REPORTS).

### 3.3 Phase 3 — Autopilot-Provisioning (Hybrid Join)

Direkt nach dem Setup (Autostart-Weg, ohne zusätzlichen Neustart) bzw. nach dem
Auto-Reboot (manueller Weg) durchläuft das Gerät das Autopilot-Provisioning wie gewohnt
(Hybrid Entra Join, unverändertes Join-Modell). Danach folgt die Abnahme
([Kapitel 4](#4-abnahme-und-reports)).

> **VORSICHT — Autopilot-Pre-Provisioning (White Glove):** Pre-Provisioning in
> Kombination mit **Hybrid Join** ist die fehleranfälligste Autopilot-Kombination.
> Das Auto-Reseal-Verhalten (Windows 11 24H2+) ist auf unserer Hardware **noch nicht
> verifiziert**. Pre-Provisioning erst dann als Standardablauf nutzen (und hier
> dokumentieren), wenn es auf **einem** Gerät vollständig erfolgreich getestet wurde
> — bis dahin gilt das normale, benutzergesteuerte Provisioning wie oben beschrieben.

---

## 4. Abnahme und Reports

### 4.1 Abnahme starten

Voraussetzungen: Autopilot-Provisioning abgeschlossen, fertiges Windows, Stick
eingesteckt. Am Gerät (Mitarbeiter-Session mit Techniker-Elevation oder lokale
`intuneadm`-Session):

- Im Explorer `E:\START-ABNAHME.cmd` doppelklicken, **oder** in einer
  Eingabeaufforderung mit vollem Pfad aufrufen:

  ```bat
  E:\START-ABNAHME.cmd
  ```

Die CMD fordert einmalig Adminrechte an (UAC) und lädt die aktuelle
`abnahme/Test-HephaistosDevice.ps1` aus GitHub (Fallback: Stick-Spiegel). Der
Technikername aus der WinPE-Phase wird als Default angeboten (Enter übernimmt).

### 4.2 Was passiert

1. **BitLocker-Escrow** läuft vor den Checks: Recovery-Keys werden aktiv nach
   Entra ID gesichert (BackupToAAD), damit die Event-845-Prüfung das Ergebnis sieht.
2. **Abnahme-Checks** (Hostname-Konvention, Hybrid Join, PRT, TPM 2.0, Secure Boot,
   BIOS-Admin-Passwort, BitLocker inkl. Escrow-Event 845, Dienste, Netskope-Tunnel,
   AV-Rollen, Company Portal, Windows-Build >= MinBuild, Aktivierung, sowie
   Hinweis-Checks: Pending Reboot, Treiberfehler, Zeitzone, Windows Update).
   Der Windows-Update-Scan dauert 1–3 Minuten (Fortschrittsanzeige).
3. **Ergebnis dreistufig:**

   | Ergebnis | Bedeutung |
   |---|---|
   | `SUCCESS` | alle Pflichttests PASSED — übergabefähig |
   | `SUCCESS_WITH_WARNINGS` | Pflichttests PASSED, gelbe Hinweise (WARN) — übergabefähig, Hinweise im Report beachten |
   | `FAILED` | mindestens ein Pflichttest FAILED — Troubleshooting, Abnahme wiederholen |

   Per Config deaktivierte Checks erscheinen als `SKIPPED` und zählen weder ins
   Ergebnis noch in den Exit-Code (siehe [5.2](#52-configreport-checksjson--checks-einzeln-anaus)).

### 4.3 Reports

Alle Reports landen im Geräteordner `E:\Logs\<ServiceTag>\`:

- Text- und JSON-Report (`<Hostname>_<Zeitstempel>.txt/.json`),
- HTML-Report und (best effort, via Edge headless) **PDF**,
- **Teams-Karte** mit Ergebnis, Gerät, Techniker, primärem Benutzer — sofern eine
  Webhook-URL im Secrets-Blob hinterlegt ist,
- **Mail:** Am Kundengerät wird bewusst **nicht** angemeldet. Reports werden
  gesammelt vom Techniker-PC versendet (nächster Abschnitt). Nur wenn im
  Secrets-Blob ein `MailSender` (reserviert) hinterlegt und entsperrt ist, bietet
  das Script den direkten App-Versand an.

### 4.4 Gesammelter Mailversand (Techniker-PC)

Auf dem **eigenen** Notebook (nicht am aufgesetzten Gerät): Stick anstecken, dann

```bat
E:\SEND-REPORTS.cmd
```

Das Script sammelt alle Reports ohne `.sent`-Marker (PDF bevorzugt, sonst HTML) und
sendet sie an den Empfänger aus dem Secrets-Blob (Passphrase wird abgefragt):

1. **bevorzugt** Microsoft Graph `/me/sendMail` (SSO des Technikers, ein Login pro
   Sitzung, keine Outlook-Prompts),
2. **Fallback** klassisches Outlook (COM): Outlook zeigt hier **pro Mail** die
   Sicherheitsabfrage „Ein Programm versucht, in Ihrem Auftrag eine E-Mail zu
   senden" (Object Model Guard) — das ist erwartetes Verhalten, „Zulassen" klicken.

Pro versendeter Datei entsteht `<Report>.sent`. Erneut senden: den `.sent`-Marker
der Datei löschen und SEND-REPORTS erneut starten.

---

## 5. Konfiguration

Beide Config-Dateien liegen im Repo und werden **zur Laufzeit** geladen — Änderungen
auf GitHub wirken sofort auf alle Sticks. Offline greift der Stick-Spiegel
(aktualisieren mit `Build-USB.ps1 -SkipUsbCreation`).

### 5.1 `config/deploy.json` — zentrale Laufzeit-Config

| Feld | Bedeutung |
|---|---|
| `OS.OSName` / `OSEdition` / `OSActivation` | Zielimage für OSDCloud: `Windows 11 25H2 x64`, `Pro`, `Retail`. Der exakte OSName-String muss vom installierten OSD-Modul gelistet sein (Warnung in WinPE bzw. Build-USB bei Abweichung). |
| `Languages` / `DefaultLanguageKey` | Sprachmenü der WinPE-Phase (1=DE Default, 2=FR, 3=PL); je Sprache optional `GroupTag` als Vorauswahl (ab v1.1.0) |
| `Bios.StorageMode` | Ziel-Storage-Modus, Default `Ahci` — wird VOR der Installation in WinPE geprüft/gesetzt; `Keep` = Preflight aus (ab v1.1.0, siehe [2.5](#25-cctk-und-vc-runtime-auf-den-stick-kopieren-manuell)) |
| `Bios.DefaultPackage` / `Bios.Packages` | Standard- bzw. modell-spezifische CCTK-Paketordner unter `_HEPHAISTOS\Tools\` (ab v1.1.0, siehe [2.5](#25-cctk-und-vc-runtime-auf-den-stick-kopieren-manuell)) |
| `Oobe.AutoLaunch` | Default `true` — OOBE-Phase startet automatisch aus dem Windows-Setup (Specialize); `false` = manuell per Shift+F10 + `c:\o` (ab v1.2.0) |
| `Oobe.PassphraseUpfront` | Default `true` — Team-Passphrase wird schon in WinPE abgefragt und per Split-Key-Handoff übergeben; `false` = Passphrase-Prompt wie früher erst in der Specialize-Konsole (ab v1.3.0) |
| `Abnahme.AutoRun` / `Abnahme.DelayMinutes` | Default `true` / `5` — Abnahme läuft nach dem Provisioning automatisch (geplante Aufgabe, nicht-interaktiv); `false` = nur manuell (ab v1.2.0) |
| `MinBuild` | Mindest-Build für die Abnahme, Default **26200** (= 25H2). Eine Quelle für WinPE und Abnahme. |
| `RemoveWinRE` | Default `false` — siehe [5.3](#53-removewinre-flag-mit-konsequenzen) |
| `GroupTags` | Auswahlreihenfolge im Hash-Schritt (`SLGDE`, `SLGFR`, `SLGPL`, `SLGTEST`) |
| `Report.TeamsAttachPdf` | `true` = PDF wird base64 an den Teams-Flow übergeben + Karte erhält „Report öffnen"-Button |
| `Repo.RawBase` | Basis-URL aller Laufzeit-Downloads (raw.githubusercontent.com) |

**Keine** Mailadressen, Webhook-URLs oder Tenant-Daten in diese Datei — das Repo ist
public. Solche Werte gehören ausschließlich in den Secrets-Blob ([Kapitel 7](#7-sicherheits--und-secrets-policy)).

### 5.2 `config/report-checks.json` — Checks einzeln an/aus

Jeder Abnahme-Check hat eine stabile ID. Schema:

```json
{
  "LocalAdminAccount": "intuneadm",
  "Checks": {
    "hostname-convention": true,
    "netskope-tunnel": true,
    "windows-update-scan": false
  }
}
```

Verhalten:

- **Fehlender Key = Check aktiv** (Default an). Nur explizites `false` deaktiviert.
- Ein deaktivierter Check **verschwindet nicht**, sondern erscheint im Report als
  `SKIPPED` mit Detail `per Config deaktiviert` (Sichtbarkeit gewollt).
- `SKIPPED` zählt weder in den Exit-Code noch in den Summary-Status.
- `LocalAdminAccount` steuert den intuneadm-Sonderfall des Netskope-Checks
  ([6.4](#64-netskope-tunnel-failed-in-der-intuneadm-session)).

Check-IDs (Auszug — vollständige Liste in der Datei selbst):

| ID | Prüfung | Art |
|---|---|---|
| `hostname-convention` | Hostname-Konvention `SLG(DE\|FR\|PL\|TEST)-` | Pflicht |
| `hybrid-join-azuread` / `hybrid-join-domain` | Hybrid Join (dsregcmd) | Pflicht |
| `entra-prt` | Primary Refresh Token (SSO) | Pflicht (INFO bei Fremdkontext) |
| `tpm-20`, `secure-boot`, `bios-admin-password` | Firmware/Sicherheit | Pflicht |
| `bitlocker-protection`, `bitlocker-recovery-protector`, `bitlocker-escrow-845` | BitLocker inkl. Key-Escrow | Pflicht |
| `service-netskope`, `service-sentinelone`, `service-intune-ime` | Dienste (Running + Autostart) | Pflicht |
| `netskope-tunnel` | Tunnelstatus via nsdiag (mit intuneadm-Sonderfall) | Pflicht |
| `av-roles`, `company-portal`, `windows-min-build`, `windows-activation` | Software/OS | Pflicht |
| `pending-reboot`, `driver-errors`, `timezone-country`, `windows-update-scan` | unkritisch | Hinweis (WARN) |

### 5.3 RemoveWinRE-Flag (mit Konsequenzen!)

Bei `"RemoveWinRE": true` entfernt die OOBE-Phase die Windows-Recovery-Umgebung:
`reagentc /disable`, Recovery-Partition löschen, `C:` auf Maximum erweitern,
gestagte `winre.wim` löschen. Vor der Ausführung zeigt das Script die Konsequenzen
als gelben Hinweis und fragt nach Bestätigung.

> **WARNUNG — Konsequenzen von `RemoveWinRE: true`:**
>
> - **Kein „Diesen PC zurücksetzen"** (Reset this PC) mehr möglich.
> - **Kein Intune-Wipe/Fresh-Start**, der die Recovery-Umgebung benötigt.
> - **Keine BitLocker-Recovery-Umgebung** — bei Boot-Problemen bleibt nur die
>   Neuinstallation vom Stick.
>
> Das Flag nur bewusst und flottenweit abgestimmt aktivieren. Default ist `false`.

**Zusätzlich beachten:** Nach Windows-**Feature-Updates** kann WinRE automatisch
zurückkehren (Setup legt Recovery-Partition/winre.wim neu an). Wenn die Entfernung
gewollt dauerhaft ist, nach Feature-Updates mit `reagentc /info` prüfen und ggf.
erneut entfernen.

---

## 6. Troubleshooting

### 6.1 BIOS: CCTK „Extraction Error" / 0xC0000135

**Symptom:** Der SCE-EXE-Aufruf (`Pro16Plus_CCTK_x64.exe`) bricht mit
„Extraction Error" bzw. Fehlercode `0xC0000135` ab.

**Ursache:** Die SCE-Selbstextraktion (miniunz.exe) benötigt die **VC++-Runtime** —
auf dem Dell-Werksimage fehlt sie (Praxisbefund 07/2026).

**Lösung (in dieser Reihenfolge):**

1. HEPHAISTOS installiert die Runtime automatisch still, wenn
   `E:\_HEPHAISTOS\Tools\vc_redist.x64.exe` auf dem Stick liegt (ca. 20 Sekunden).
2. **Dauerhaft besser:** das CCTK-Paket einmalig am Admin-PC entpacken —
   `Pro16Plus_CCTK_x64.exe /s /e=C:\Temp\CCTK` — und den Inhalt nach
   `E:\_HEPHAISTOS\Tools\CCTK\` kopieren. Das vorentpackte Paket
   (`applyconfig.bat`) wird bevorzugt genutzt und umgeht die Selbstextraktion
   komplett.

Exit-Code und Log (`cctk_apply.log`) liegen im Geräteordner `E:\Logs\<ServiceTag>\`.

### 6.2 BitLocker: Event 845 fehlt / Event 846 vorhanden

**Hintergrund:** Der Check `bitlocker-escrow-845` verlangt ein Event 845
(„Key-Escrow nach Entra ID") im Log `Microsoft-Windows-BitLocker/BitLocker
Management`, das **jünger als das OS-Installationsdatum** ist — ältere Events
stammen von einer früheren Installation und zählen nicht.

**Fälle:**

- **„Event 845 ist AELTER als die OS-Installation":** Der Escrow dieser Installation
  fehlt noch. Abnahme erneut starten — der BitLocker-Escrow (BackupToAAD) läuft bei
  jedem Abnahme-Lauf vor den Checks erneut.
- **Kein Event 845, aber Event 846 (Fehler):** Der Escrow-Versuch ist fehlgeschlagen.
  Häufige Ursache in unserer Umgebung: **Netskope** (SSL-Interception/Steering)
  blockiert die Verbindung zu den Entra-Endpunkten. Netskope-Tunnelstatus prüfen
  (siehe 6.4), Verbindung herstellen, dann Abnahme wiederholen. Bleibt 846 bestehen:
  Steering-/Bypass-Konfiguration für die Microsoft-Login-/Registrierungs-Endpunkte
  mit dem Netskope-Verantwortlichen prüfen.
- **Gar kein Event:** Gerät hatte beim Escrow keinen Netzzugang — online bringen,
  Abnahme wiederholen.

### 6.3 PRT-Check: INFO oder FAILED (Benutzerkontext)

**Hintergrund:** `AzureAdPrt` gilt **nur für den Benutzer, unter dem `dsregcmd`
läuft**. Elevated der Techniker in der Mitarbeiter-Session mit einem anderen Konto,
zeigt `dsregcmd` den PRT des **Technikers** — der Check ist dann nicht bewertbar und
wird als **INFO** ausgewiesen.

- **INFO („Nicht bewertbar"):** Manuell prüfen — als Mitarbeiter **ohne**
  Adminrechte `dsregcmd /status` ausführen, Abschnitt `SSO State`:
  `AzureAdPrt` muss `YES` sein.
- **FAILED (`AzureAdPrt != YES`) in der Mitarbeiter-Session:** SSO/Conditional
  Access werden fehlschlagen. Gerät **sperren und wieder entsperren** (frische
  Anmeldung erzwingt PRT-Erneuerung), dann erneut prüfen.
- **Lokale `intuneadm`-Session:** Ein lokales Konto hat **nie** einen PRT — der
  Check kann in dieser Session nicht bestehen. Für die PRT-Bewertung die Abnahme in
  der Mitarbeiter-Session ausführen bzw. dort manuell wie oben prüfen.

### 6.4 Netskope: Tunnel FAILED in der intuneadm-Session

**Hintergrund:** Für den lokalen LAPS-Admin (`SLGDE-XXXXXXX\intuneadm`) existiert
**kein Netskope-Steering-Profil** — `nsdiag -f` meldet dann
`NSTUNNEL_DISCONNECTED`, obwohl der Client in Ordnung ist.

**Neues Verhalten (automatisch):** Erkennt der Check, dass der Konsolen-Benutzer
`<HOSTNAME>\<LocalAdminAccount>` ist (Konto aus `config/report-checks.json`,
Default `intuneadm`), prüft er **nur** den Dienst `stAgentSvc` (Running +
Autostart) und meldet bei laufendem Dienst **PASSED** mit dem Detail
„Lokale Admin-Session (intuneadm) — kein Steering-Profil erwartet; nur Dienststatus
geprüft".

- **FAILED trotz intuneadm-Session:** Dann läuft der Netskope-Dienst tatsächlich
  nicht — Client-Installation prüfen.
- **FAILED in der Mitarbeiter-Session:** Normale nsdiag-Diagnose — Tunnelstatus
  in der Netskope-Client-UI prüfen, Netzwerk/Anmeldung prüfen; „Keine
  Tunnel-Statuszeile" kann auf aktiven Tamperproof-Modus hindeuten.

### 6.5 Profilzuweisung: Timeout beim Polling

**Symptom:** Nach dem Hash-Upload endet das Polling nach 30 Minuten mit der gelben
Meldung `Profilzuweisung prüfen: Gruppenzuordnung des GroupTags` — kein Auto-Reboot.

**Prüfen (Intune-Portal):**

1. Taucht das Gerät unter *Windows-Registrierung > Geräte (Autopilot)* auf und trägt
   es das richtige **GroupTag**?
2. Ist die **dynamische Gruppe** für dieses GroupTag korrekt definiert und hat die
   Mitgliedschaft das Gerät schon aufgenommen? (Dynamische Gruppen brauchen
   manchmal länger.)
3. Ist der Gruppe ein **Autopilot-Deployment-Profil** zugewiesen?

Sobald der Profilstatus „Zugewiesen" ist, das Gerät **manuell neu starten** — es
bootet dann ins Autopilot-Provisioning. Der Hash ist bereits hochgeladen; der
Schritt muss nicht wiederholt werden.

### 6.6 Gelbe OFFLINE-FALLBACK-Warnung

Eine Phase konnte GitHub nicht erreichen und nutzt die lokale Kopie (Stick bzw.
`C:\OSDCloud\HEPHAISTOS\Fallback`). Der Ablauf funktioniert, aber die Kopie kann
veraltet sein — die Warnung nennt den Stand. Netzwerk prüfen; Stick-Spiegel bei
Gelegenheit mit `Build-USB.ps1 -SkipUsbCreation` aktualisieren.

### 6.7 WinPE: Warnung „OSName nicht in der Liste"

`Get-OSDCloudOperatingSystems` kennt den in `deploy.json` konfigurierten
`OS.OSName`-String nicht (z. B. nach OSD-Modul-Update oder Tippfehler). Die Warnung
zeigt die nächstliegenden gelisteten Namen. Entweder abbrechen und `deploy.json`
auf den tatsächlich gelisteten String korrigieren, oder bewusst bestätigen.

### 6.8 „Stick nicht gefunden"

Wird der Stick (Marker-Ordner `_HEPHAISTOS`) zur Laufzeit nicht gefunden, landen
Logs/State ersatzweise unter `C:\OSDCloud\HEPHAISTOS\Logs\<ServiceTag>` (gelbe
Warnung). Stick neu einstecken bzw. nach Abschluss die Ordner manuell auf den Stick
kopieren, damit die Historie vollständig bleibt.

**Direkt nach dem Neustart (Specialize-Konsole):** Die Konsole startet sehr früh —
der USB-Stack ist dann oft noch nicht fertig. Seit v1.2.3 wartet die OOBE-Phase
deshalb **bis zu 90 Sekunden aktiv** auf den Stick („Warte bis zu 90 Sekunden …").
Taucht er trotzdem nicht auf: kurz ab- und wieder anstecken (löst eine
Neu-Enumeration aus) — und den Stick bevorzugt **direkt am Gerät** einstecken statt
in der Dock: Docks (v. a. USB-C/Thunderbolt) initialisieren sich beim Boot selbst
erst spät.

---

## 7. Sicherheits- und Secrets-Policy

Das Repo ist **public** (Voraussetzung für die unauthentifizierten raw-URLs). Daraus
folgt zwingend:

1. **Verboten im Repo** — auch in Beispielen, Kommentaren, Commits und Testdaten:
   Tenant-ID, App-ID, Client Secrets, Webhook-URLs, personenbezogene Mailadressen,
   Seriennummern/Hostnamen echter Geräte.
   **Erlaubt:** Hostname-Konvention `SLG(DE|FR|PL|TEST)-`, GroupTag-Namen,
   Dienstnamen, Produktnamen.
2. **Alle Geheimnisse liegen dauerhaft nur verschlüsselt auf dem Stick:**
   `E:\HEPHAISTOS-Secrets\hephaistos.secrets.enc.json` (AES-256, PBKDF2-SHA-256,
   600.000 Iterationen). Enthält: TenantId, AppId, AppSecret, ReportRecipient,
   TeamsWebhookUrl, MailSender. Alt-Blobs werden beim nächsten Entsperren
   automatisch auf das neue Verfahren migriert.
   **Vorübergehende Ausnahme (v1.3.0, Minuten-Fenster):** Der Split-Key-Handoff
   legt zwischen Staging und Specialize-Konsum einen AES-verschlüsselten
   Auszug (Upload-Felder) auf `C:` und den zufälligen Einmal-Schlüssel auf dem
   Stick ab — jede Hälfte allein ist wertlos, beide werden beim Verbrauch
   überschrieben und gelöscht (One-Shot, TTL 24 h, Sweeps in WinPE und
   Abnahme). Einziges neues Risiko: Diebstahl BEIDER Medien in genau diesem
   Fenster — kleiner als das ohnehin akzeptierte Stick-Diebstahl-Szenario;
   Gegenmittel bleibt die Rotation von App-Secret/Webhook in Entra ID.
3. Die **Team-Passphrase** wird nur mündlich/teamintern weitergegeben — niemals auf
   dem Stick oder im Repo notieren.
4. Die **Teams-Webhook-URL wie ein Secret behandeln** — wer sie hat, kann in den
   Kanal posten. Deshalb liegt sie im Secrets-Blob, nicht in der Config.
   Zusätzlich legt die OOBE-Phase (ab v1.2.1) eine **DPAPI-verschlüsselte
   Gerätekopie** an (`C:\OSDCloud\HEPHAISTOS\teams.webhook.bin`, Machine-Scope):
   nie Klartext, außerhalb des Geräts wertlos, wird beim nächsten Wipe zerstört —
   ermöglicht die Teams-Karte der Auto-Abnahme ohne Passphrase.
5. `.gitignore` schützt `*secrets*`, `HEPHAISTOS-Secrets/`, `Logs/`, `*.log` — vor
   jedem Push trotzdem prüfen, dass keine Geräte-Logs oder Blobs im Commit sind.
6. Der **Stick enthält Gerätedaten** (Logs, Reports, Hash-CSVs) und den
   Secrets-Blob — wie ein Firmen-Asset behandeln: nicht liegen lassen, Verlust
   melden (dann Client Secret der App-Registrierung rotieren und neuen Blob
   erzeugen).

---

## 8. Offene Hardware-Verifikationen

Die folgenden Punkte sind **nur auf echter Hardware** prüfbar und vor dem breiten
Flotteneinsatz auf einem Testgerät (GroupTag `SLGTEST`) abzuhaken:

- [x] **OOBE-Autostart (v1.2.0): BESTÄTIGT** (Feldtest 2026-08-21, 3× Dell
      Pro 13 Plus): Konsole erscheint sichtbar während „Geräte werden
      vorbereitet", Passphrase-Eingabe und Tastatur-Fix (de-DE) funktionieren,
      Techniker/GroupTag werden automatisch übernommen.
- [ ] **Hash-Upload nativ per Graph-REST (v1.2.2):** Import-Status erreicht
      `complete`, danach greift das Zuweisungs-Polling und das Setup fährt ohne
      Neustart in die OOBE → Autopilot. (Der frühere PSGallery-Weg schlug in
      der Specialize-Phase unter SYSTEM immer fehl — siehe CHANGELOG 1.2.2.)
- [ ] **Auto-Abnahme (v1.2.0):** geplante Aufgabe feuert nach der Anmeldung
      (Verzögerung beachten), Bedingungs-Checks greifen (defaultuser0/IME/Stick),
      Report entsteht, Aufgabe entfernt sich nach bestandener Abnahme
      (`autoabnahme.log` prüfen).
- [ ] **Storage-Preflight (v1.1.0):** auf einem RAID-Werksgerät den kompletten
      Zyklus prüfen (Disk leeren → AHCI → automatischer Stick-Boot → Installation)
      inkl. `cctk --embsataraid`-Ausgabeformat.
- [ ] **UEFI-Boot-Override (v1.2.4):** Nach der RAID→AHCI-Umstellung startet das
      Gerät ohne F12 direkt wieder vom Stick (Konsole meldet vorher „Boot-Override
      gesetzt (BootNext)"); die dauerhafte Boot-Reihenfolge im BIOS bleibt
      unverändert. (Feldtest davor: HTTP-Boot an erster Stelle fing den Neustart
      ab.)
- [ ] **WinPE-Tastatur (v1.3.0):** Beim Start erscheint „Deutsche Tastatur
      aktiviert — die Konsole startet einmalig neu", danach tippen sich
      Y/Z und Sonderzeichen korrekt (Passphrase-Probe!). Falls der Selbst-
      Neustart scheitert: gelber Hinweis + US-Layout wie bisher.
- [ ] **Preflight-Wiederanlauf (v1.3.0):** Auf einem RAID-Werksgerät nach dem
      automatischen Neustart erscheint die Wiederanlauf-Zusammenfassung mit
      15-s-Countdown; ohne Tastendruck läuft alles bis zur Passphrase-Abfrage
      durch. Gegenprobe: Taste drücken → normale Eingabe; und ein DRITTER
      Stick-Boot (nach abgeschlossenem Zyklus) fragt wieder komplett
      interaktiv (One-Shot-Zustimmung).
- [ ] **Split-Key-Handoff (v1.3.0):** Passphrase in WinPE eingeben; in der
      Specialize-Konsole erscheint „Zugänge aus dem WinPE-Handoff übernommen"
      und es kommt KEIN Passphrase-Prompt mehr; danach existieren weder
      `C:\OSDCloud\HEPHAISTOS\handoff.enc.json` noch
      `<Stick>:\Logs\<Serial>\state\handoff.key.json` mehr. Gegenprobe:
      Passphrase in WinPE 3× falsch → Installation läuft trotzdem, Specialize
      fragt wie früher.

- [ ] **CCTK auf Dell Pro 16 Plus:** vorentpacktes Paket (`applyconfig.bat`) und
      SCE-Fallback inkl. VC++-Workaround anwenden, Exit-Code 0, BIOS-Einstellungen
      nach Reboot verifizieren (inkl. gesetztem Admin-Passwort).
- [ ] **WinPE-Treiber:** OSDCloud-WinPE (`-CloudDriver Dell,WiFi`) auf der
      Zielhardware — NVMe/Storage, Tastatur und speziell **WLAN** funktionieren.
- [ ] **25H2-OSName:** `Get-OSDCloudOperatingSystems` listet den String
      `Windows 11 25H2 x64` der installierten OSD-Modulversion exakt; sonst
      `deploy.json` anpassen.
- [ ] **Start-OSDCloud-Reboot-Verhalten:** Kehrt `Start-OSDCloud -ZTI` wie erwartet
      zum Script zurück (Staging läuft), oder rebootet es selbst? Im zweiten Fall
      muss das Staging in SetupComplete verlagert werden.
- [ ] **nsdiag-Ausgabeformat:** aktuelle Netskope-Client-Version liefert weiterhin
      `NSTUNNEL_CONNECTED` und eine „Tunnel status"-Zeile bei `nsdiag -f`.
- [ ] **Hybrid-Pre-Provisioning / Auto-Reseal:** Verhalten (Windows 11 24H2+) auf
      **einem** Gerät vollständig verifizieren, **bevor** Pre-Provisioning als
      Standardablauf dokumentiert wird (siehe Warnung in [3.3](#33-phase-3--autopilot-provisioning-hybrid-join)).
- [ ] **PDF-Konvertierung mit Leerzeichen-Pfad:** Convert-HtmlToPdf mit einem Pfad,
      der Leerzeichen enthält, testen (Quoting-Fix verifizieren).
- [ ] **Assignment-Polling gegen den echten Tenant:** Statuswechsel auf
      `assigned*` und Auto-Reboot einmal live beobachten; Timeout-Zweig gegenprüfen.
- [ ] **Kompletter Praxislauf:** WinPE → OOBE → Provisioning → Abnahme
      `SUCCESS` inkl. Teams-Karte und SEND-REPORTS vom Techniker-PC.
