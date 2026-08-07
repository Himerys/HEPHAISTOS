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
├──╼ startnet.cmd ──▶ StartURL ──▶ GitHub raw ──▶ boot/Start-Hephaistos.ps1
│                                                  ├─ Sprach-/Technikermenü
│                                                  ├─ Start-OSDCloud -ZTI  ░░ WIPE ░░ + 25H2
│                                                  └─ staged C:\OSDCloud\HEPHAISTOS\oobe.cmd
│
├─[ OOBE ]──╼ Shift+F10 ──▶ oobe.cmd ──▶ oobe/Invoke-HephaistosOnboarding.ps1
│              ├─ BIOS-Konfiguration (Dell CCTK)
│              ├─ Autopilot-Hash ──▶ Intune ──▶ Assignment-Polling ──▶ Auto-Reboot
│              └─ optional: RemoveWinRE (Config-Flag)
│
└─[ Fertiges Windows ]──╼ START-ABNAHME.cmd ──▶ abnahme/Test-HephaistosDevice.ps1
               └─ HTML/PDF-Report + Teams-Karte + Mail-Queue (SEND-REPORTS)
```

Jeder Boot zieht die **aktuellste Script-Version** von GitHub — ohne Netz greift
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
│   └── report/                        # HTML ─ PDF ─ Teams ─ Mail
├── send/                              # Sammel-Versand vom Techniker-PC
├── config/
│   ├── deploy.json                    # OS, Sprachen, MinBuild, GroupTags, RawBase
│   └── report-checks.json             # Abnahme-Checks einzeln an/aus
├── tools/
│   ├── Build-USB.ps1                  # Stick schmieden (einmalig)
│   ├── New-HephaistosSecrets.ps1      # Secrets-Blob verschlüsseln
│   └── secrets.template.json          # Schema-Referenz (nur Platzhalter!)
└── docs/ANLEITUNG.md                  # das Grimoire
```

## [03] 🔥 Stick schmieden (Quickstart)

```text
┌──(admin㉿schmiede)-[~/HEPHAISTOS]  (PowerShell ALS ADMINISTRATOR)
└─$ .\tools\Build-USB.ps1              # OSDCloud-WinPE + USB + Repo-Spiegel

┌──(admin㉿schmiede)-[~/HEPHAISTOS]
└─$ .\tools\New-HephaistosSecrets.ps1  # Secrets-Blob → <Stick>:\HEPHAISTOS-Secrets\
```

Danach von Hand: CCTK-Paket + `vc_redist.x64.exe` nach `<Stick>:\_HEPHAISTOS\Tools\`
(zu groß/lizenzpflichtig fürs Repo). Pro Gerät dann nur noch: **F12 → USB → tippen: `LOESCHEN`** —
den Rest erledigt die Esse.

## [04] 🛡 OPSEC — Secrets-Policy

> *Dieses Repo ist public. Es weiß nichts. Es hat nie etwas gewusst.*

Hier liegen **niemals**: Tenant-/App-IDs, Client Secrets, Webhook-URLs,
Mail-Adressen, Seriennummern echter Geräte. Alles Sensible wandert
**AES-256-verschlüsselt** (PBKDF2-SHA256, 600 000 Iterationen) in
`HEPHAISTOS-Secrets\` auf den Stick — erzeugt mit `tools/New-HephaistosSecrets.ps1`.
Die `.gitignore` steht Wache, GitHub Push Protection ist der zweite Wall.

## [05] 📜 Grimoire & Historie

| Schriftrolle | Inhalt |
|---|---|
| [docs/ANLEITUNG.md](docs/ANLEITUNG.md) | Ersteinrichtung, Ablauf pro Gerät, Troubleshooting, offene Hardware-Prüfungen |
| [CHANGELOG.md](CHANGELOG.md) | jede Abweichung vom Ur-Toolkit, begründet |

---

<div align="center">

*Je leiser der Stick, desto lauter singt die Esse.* ⚒🐉

**SLG IT — interne Werkzeugkette** · portiert aus USB_ScriptTool Rev05

</div>
