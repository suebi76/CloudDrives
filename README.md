# CloudDrives

**OneDrive und Google Drive als Laufwerke in Windows – per Doppelklick.**
*Mount OneDrive and Google Drive as Windows drive letters with one double-click (English summary below).*

CloudDrives bindet deine Cloud-Speicher als echte Laufwerksbuchstaben ein, z. B. `M:` für OneDrive und `K:` für Google Drive.
Grundlage sind [rclone](https://rclone.org) und [WinFsp](https://winfsp.dev). Bedient wird es über ein deutsches Konsolen-Menü
mit geführten Assistenten. Die Installation läuft automatisch, und Anmeldedaten werden verschlüsselt gespeichert.

> **Status:** in Entwicklung (Version 0.1). Kern, Engine, Laufwerksverwaltung und verschlüsselte Tresore sind getestet.
> Autostart, Diagnose und Updates folgen.

## Funktionen

- **Mehrere Konten:** privates OneDrive (auch Microsoft 365 Family), privates Google-Konto und Google Workspace
- **Verschlüsselung nach Wahl:** Pro Konto entscheidest du, ob du ein normales Laufwerk möchtest, zusätzlich einen
  verschlüsselten Tresor oder nur einen Tresor. Mehr dazu in [docs/ENCRYPTION.md](docs/ENCRYPTION.md)
- **Sichere Anmeldung im Browser:** CloudDrives sieht nie ein Passwort und speichert nur widerrufbare Tokens,
  verschlüsselt mit einem Schlüssel in der Windows-Anmeldeinformationsverwaltung
- **Wie lokale Laufwerke:** Office, Bildbearbeitung und andere Programme arbeiten direkt auf dem Laufwerk.
  Uploads laufen im Hintergrund und werden nach einem Neustart fortgesetzt
- **Explorer-Integration:** sprechende Namen wie „Google Pro (K:)“ und echte Speicheranzeige
- **Fehleranalyse:** verständliche Meldungen mit Fehlercode (z. B. `CD-4001`) und konkreter Lösung, ausführliche Protokolle
- **Keine Admin-Rechte nötig:** Ausnahme ist die einmalige Installation des Treibers WinFsp

## Voraussetzungen

- Windows 10 oder 11 (x64 oder ARM64)
- Windows PowerShell 5.1 (vorinstalliert); PowerShell 7 wird ebenfalls unterstützt

## Schnellstart

1. Repository herunterladen (grüner Button **Code → Download ZIP**) und entpacken oder per `git clone` klonen.
2. **`CloudDrives.bat`** doppelklicken.
3. Der Assistent installiert rclone (mit geprüfter Prüfsumme) und WinFsp, danach verbindest du dein erstes Konto.

Später folgt die Installation per Einzeiler.

## Bedienung

| Befehl | Wirkung |
|---|---|
| `CloudDrives.bat` | Menü öffnen |
| `CloudDrives.bat verbinden` | alle Laufwerke verbinden (`verbinden K` nur eines) |
| `CloudDrives.bat trennen` | alle Laufwerke trennen (`--force` trotz laufender Uploads) |
| `CloudDrives.bat status --json` | Status für Skripte |
| `CloudDrives.bat hilfe` | alle Befehle |

## Sicherheit

- **Anmeldung:** ausschließlich auf den Seiten von Microsoft bzw. Google (OAuth). CloudDrives fragt nie nach deinem Passwort.
- **Tokens:** liegen in `%LOCALAPPDATA%\CloudDrives\rclone.conf`, verschlüsselt mit einem zufälligen 256-Bit-Schlüssel.
  Der Schlüssel liegt DPAPI-geschützt in der Windows-Anmeldeinformationsverwaltung. Der Ordner ist nur für deinen Benutzer lesbar.
- **Repository:** Es enthält nie Zugangsdaten. Mehrere Schutzschichten sorgen dafür: Allowlist-`.gitignore`, Secret-Scans in
  den Tests und GitHub Push Protection.
- **Grenze:** Schadsoftware, die unter deinem eigenen Windows-Konto läuft, kann keine lokale Lösung zuverlässig abwehren.

## Google: eigene Client-ID (empfohlen)

Mit der Standard-Kennung von rclone bremst Google bei viel Nutzung. Die Anleitung für eine eigene, kostenlose Client-ID
steht in [docs/GOOGLE-OAUTH.md](docs/GOOGLE-OAUTH.md).

## Entwicklung

```powershell
.\tools\Install-DevTools.ps1                          # Pester + PSScriptAnalyzer (privater Ordner)
.\tools\Invoke-Build.ps1 -Edition Both                # Format-, Lint- und Unit-Tests in PowerShell 5.1 und 7
.\tools\Invoke-Build.ps1 -Edition Both -Integration   # zusätzlich echte Engine + Laufwerk (benötigt WinFsp)
.\tools\Format-SourceFiles.ps1                        # Kodierung/Zeilenenden normalisieren
```

Aufbau: `src/Infrastructure` (Technik) → `src/Providers` → `src/Services` → `src/Commands` → `src/UI`.
Abhängigkeiten zeigen nur nach unten.

## English summary

CloudDrives mounts OneDrive and Google Drive (personal and Workspace) as Windows drive letters using rclone and WinFsp.
Run `CloudDrives.bat` and follow the guided setup. You sign in through the provider's own page (OAuth). Tokens are stored
encrypted with a key kept in the Windows Credential Manager. The UI language follows Windows (German/English).

## Lizenz

[MIT](LICENSE). rclone (MIT) und WinFsp (GPLv3 mit FLOSS-Ausnahme) werden zur Laufzeit von den offiziellen Quellen geladen
und sind nicht Teil dieses Repositorys.
