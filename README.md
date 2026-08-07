# HEPHAISTOS

HEPHAISTOS (der Schmiedegott, Erbauer von Automaten) ist die naechste Generation
des SLG-Onboarding-Sticks: Er schmiedet aus roher Dell-Hardware fertige
Flottengeraete - kompletter Disk-Wipe via OSDCloud, Neuaufbau nach Vorlage,
und alle Scripts kommen zur Laufzeit aus diesem GitHub-Repo. Der USB-Stick
selbst ist statisch und wartungsfrei.

## Architektur

```
Statischer USB-Stick (OSDCloud WinPE)
  └─ startnet.cmd → StartURL → GitHub raw → boot/Start-Hephaistos.ps1
                                              ├─ Sprach-/Technikermenü
                                              ├─ Start-OSDCloud -ZTI (kompletter Wipe + 25H2)
                                              └─ staged C:\OSDCloud\HEPHAISTOS\oobe.cmd
OOBE (Shift+F10 → oobe.cmd)
  └─ GitHub raw → oobe/Invoke-HephaistosOnboarding.ps1  (immer aktuelle Version)
       ├─ BIOS-Konfiguration (Dell CCTK)
       ├─ Autopilot-Hash-Upload + Profil-Assignment-Polling + Auto-Reboot
       └─ optional RemoveWinRE (Config-Flag)
Fertiges Windows (Abnahme)
  └─ abnahme/Test-HephaistosDevice.ps1
       + HTML/PDF-Report + Teams-Karte + Mail-Queue (SEND-REPORTS am Techniker-PC)
```

## Repo-Layout

| Pfad | Zweck |
|---|---|
| `boot/Start-Hephaistos.ps1` | WinPE-Einstieg (StartURL-Ziel) |
| `lib/Hephaistos.Common.ps1` | gemeinsame Bibliothek (State, Secrets, UI, Loader) |
| `oobe/` | OOBE-Phase: Orchestrator, `oobe.cmd`-Template, Einzelschritte |
| `abnahme/` | Abnahme-Pruefscript, `START-ABNAHME.cmd`-Template, Report-Module |
| `send/` | Sammel-Mailversand vom Techniker-PC |
| `config/deploy.json` | zentrale Laufzeit-Config (OS, Sprachen, MinBuild, GroupTags) |
| `config/report-checks.json` | Abnahme-Checks einzeln an/aus |
| `tools/Build-USB.ps1` | einmalige Stick-Erstellung (OSDCloud) |
| `tools/New-HephaistosSecrets.ps1` | verschluesselten Secrets-Blob erzeugen |
| `docs/ANLEITUNG.md` | Techniker-Anleitung (Einrichtung, Ablauf, Troubleshooting) |

## Wichtig: Secrets-Policy

Dieses Repo ist public (die startnet-URL muss unauthentifiziert abrufbar sein).
Deshalb liegen hier **niemals**: Tenant-/App-IDs, Client Secrets, Webhook-URLs,
Mail-Adressen oder Seriennummern echter Geraete. Alle sensiblen Werte wandern
verschluesselt (AES-256, PBKDF2-SHA256) in `HEPHAISTOS-Secrets\` auf dem Stick -
erzeugt mit `tools/New-HephaistosSecrets.ps1`. Details: `docs/ANLEITUNG.md`,
Kapitel Sicherheits-Policy.

## Einstieg

Komplette Anleitung (Ersteinrichtung, Ablauf pro Geraet, Troubleshooting,
offene Hardware-Verifikationen): **[docs/ANLEITUNG.md](docs/ANLEITUNG.md)**.

Interne SLG-IT-Werkzeugkette. Aenderungshistorie: [CHANGELOG.md](CHANGELOG.md).
