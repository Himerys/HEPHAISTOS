<div align="center">

```
██╗  ██╗███████╗██████╗ ██╗  ██╗ █████╗ ██╗███████╗████████╗ ██████╗ ███████╗
██║  ██║██╔════╝██╔══██╗██║  ██║██╔══██╗██║██╔════╝╚══██╔══╝██╔═══██╗██╔════╝
███████║█████╗  ██████╔╝███████║███████║██║███████╗   ██║   ██║   ██║███████╗
██╔══██║██╔══╝  ██╔═══╝ ██╔══██║██╔══██║██║╚════██║   ██║   ██║   ██║╚════██║
██║  ██║███████╗██║     ██║  ██║██║  ██║██║███████║   ██║   ╚██████╔╝███████║
╚═╝  ╚═╝╚══════╝╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝╚══════╝   ╚═╝    ╚═════╝ ╚══════╝
                ⚒  d e r   s c h m i e d e g o t t   d e r   f l o t t e  ⚒
```

![Version](https://img.shields.io/badge/Version-1.3.2-2f2f2f?style=for-the-badge)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1-2f2f2f?style=for-the-badge&logo=powershell&logoColor=5391FE)
![Windows](https://img.shields.io/badge/Windows%2011-25H2-2f2f2f?style=for-the-badge&logo=windows11&logoColor=0078D6)
![OSDCloud](https://img.shields.io/badge/OSDCloud-WinPE-2f2f2f?style=for-the-badge&logoColor=orange)
![Join](https://img.shields.io/badge/Join-Hybrid%20Entra-2f2f2f?style=for-the-badge&logoColor=green)
![Secrets](https://img.shields.io/badge/Secrets-AES--256%20%2B%20PBKDF2--SHA256-2f2f2f?style=for-the-badge&logoColor=red)

**Aus roher Dell-Hardware werden fertige Flottengeräte geschmiedet.**<br>
Kompletter Disk-Wipe, Neuaufbau nach Vorlage, Autopilot, Abnahme — alle Scripts
kommen zur Laufzeit aus diesem Repo. *Der Stick ist nur noch der Hammer.*

</div>

---

## [01] ⚡ Die Schmiede-Kette

```text
┌─[ USB-Stick (OSDCloud WinPE, statisch & wartungsfrei) ]
│
├──╼ startnet.cmd ──▶ GitHub raw ──▶ boot/Start-Hephaistos.ps1
│     ├─ EIN Eingabeblock: Techniker · Sprache · GroupTag · LOESCHEN · Passphrase
│     ├─ Storage-Preflight: RAID/VMD ─▶ AHCI ─▶ BootNext ─▶ Wiederanlauf
│     ├─ Start-OSDCloud -ZTI  ░░ WIPE ░░ + Windows 11 25H2
│     └─ Staging nach C:\OSDCloud\HEPHAISTOS\ + Split-Key-Handoff
│
├─[ OOBE / Specialize ]──╼ Autostart ──▶ oobe/Invoke-HephaistosOnboarding.ps1
│     ├─ BIOS-Konfiguration (Dell CCTK)
│     ├─ optional: RemoveWinRE (Config-Flag)
│     ├─ Autopilot-Hash ──▶ Graph-Import ──▶ Sync ──▶ Profil-Polling
│     └─ geplante Aufgaben: DeviceReady + AutoAbnahme
│
├─[ Autopilot ]──╼ Hybrid Entra Join · Pre-Provisioning (Win ×5) bleibt manuell
│     └─ Teams-Karte „Gerät fertig — bitte anmelden"
│
└─[ Erste Anmeldung ]──╼ Auto-Abnahme (oder START-ABNAHME.cmd)
      └─ 22 Checks ──▶ TXT/JSON/HTML/PDF + Teams-Karte ──▶ SEND-REPORTS (Techniker-PC)
```

Jeder Lauf zieht die **aktuellste Script-Version** von GitHub — ohne Netz greift
automatisch die lokal gestagte Kopie (gelbe Warnung inkl. Stand). Kein
Versions-Drift zwischen Sticks. Nie wieder.

## [02] 🗡 Arsenal (Repo-Layout)

```text
┌──(techniker㉿schmiede)-[~/HEPHAISTOS]
└─$ tree
.
├── boot/Start-Hephaistos.ps1          # WinPE-Einstieg (StartURL-Ziel)
├── lib/Hephaistos.Common.ps1          # gemeinsame Lib: State, Secrets, UI, Loader
├── oobe/
│   ├── oobe.cmd                       # OOBE-Einstieg (Template, wird gestaged)
│   ├── Invoke-HephaistosOnboarding.ps1
│   └── steps/                         # BIOS ─ RemoveWinRE ─ AutopilotHash
├── abnahme/
│   ├── START-ABNAHME.cmd              # Stick-Root-Launcher (UAC + Repo-Pull)
│   ├── Test-HephaistosDevice.ps1      # 22 Checks, per Config schaltbar
│   ├── Invoke-AutoAbnahme.ps1         # Wächter: Abnahme nach der ersten Anmeldung
│   ├── Invoke-DeviceReady.ps1         # Wächter: Teams-Karte am Anmeldebildschirm
│   └── report/                        # HTML ─ PDF ─ Teams ─ Mail
├── send/                              # Sammel-Versand vom Techniker-PC
├── config/
│   ├── deploy.json                    # OS, Sprachen, MinBuild, GroupTags, RawBase
│   └── report-checks.json             # Abnahme-Checks einzeln an/aus
├── tools/
│   ├── Build-USB.ps1                  # Stick schmieden (einmalig)
│   ├── New-HephaistosSecrets.ps1      # Secrets-Blob verschlüsseln
│   └── secrets.template.json          # Schema-Referenz (nur Platzhalter!)
└── docs/
    ├── ANLEITUNG.md                   # das Grimoire (Techniker)
    └── DOKUMENTATION.md               # die Baupläne (Architektur, Flags, Sicherheit)
```

## [03] 🔥 Stick schmieden (Quickstart)

```text
┌──(admin㉿schmiede)-[~/HEPHAISTOS]  (PowerShell ALS ADMINISTRATOR)
└─$ .\tools\Build-USB.ps1              # OSDCloud-WinPE + USB + Repo-Spiegel

┌──(admin㉿schmiede)-[~/HEPHAISTOS]
└─$ .\tools\New-HephaistosSecrets.ps1  # Secrets-Blob → <Stick>:\HEPHAISTOS-Secrets\
```

Danach von Hand: CCTK-Paket + `vc_redist.x64.exe` nach `<Stick>:\_HEPHAISTOS\Tools\`
(zu groß/lizenzpflichtig fürs Repo). Erster Lauf auf einem Testgerät mit GroupTag `SLGTEST`.

Pro Gerät dann nur noch: **F12 → USB → Eingabeblock (inkl. `LOESCHEN` + Passphrase)** —
den Rest erledigt die Esse. Pre-Provisioning (Windows-Taste ×5) bleibt Handarbeit,
der Stick bleibt bis zur Abnahme stecken.

## [04] 🛡 OPSEC — Secrets-Policy

> *Dieses Repo ist public. Es weiß nichts. Es hat nie etwas gewusst.*

Hier liegen **niemals**: Tenant-/App-IDs, Client Secrets, Webhook-URLs,
Mail-Adressen, Seriennummern echter Geräte. Alles Sensible wandert
**AES-256-verschlüsselt** (PBKDF2-SHA256, 600 000 Iterationen) in
`HEPHAISTOS-Secrets\` auf den Stick — erzeugt mit `tools/New-HephaistosSecrets.ps1`.
Die `.gitignore` steht Wache, GitHub Push Protection ist der zweite Wall.

> ⚠ `main` **ist Produktion**: Jeder Stick lädt beim nächsten Boot, was hier liegt.
> Änderungen nur per Branch + Pull Request, erst nach einem `SLGTEST`-Lauf mergen.

## [05] 📜 Grimoire & Historie

| Schriftrolle | Inhalt |
|---|---|
| [docs/ANLEITUNG.md](docs/ANLEITUNG.md) | Ersteinrichtung, Ablauf pro Gerät, Troubleshooting, offene Hardware-Prüfungen |
| [docs/DOKUMENTATION.md](docs/DOKUMENTATION.md) | Architektur, Komponenten, Status-Flags, Sicherheitsmodell |
| [CHANGELOG.md](CHANGELOG.md) | jede Abweichung vom Ur-Toolkit, begründet |

---

<div align="center">

*Je leiser der Stick, desto lauter singt die Esse.* ⚒🐉

**SLG IT — interne Werkzeugkette** · portiert aus USB_ScriptTool Rev05

</div>
