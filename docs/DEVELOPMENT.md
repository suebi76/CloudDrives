# Entwickler-Handbuch

*English version: [DEVELOPMENT.en.md](DEVELOPMENT.en.md)*

Wie du CloudDrives einrichtest, prüfst und veröffentlichst. Wie es aufgebaut ist, steht in
[ARCHITECTURE.md](ARCHITECTURE.md), die Regeln für neuen Code in [CONTRIBUTING.md](../CONTRIBUTING.md).

## Voraussetzungen

- Windows 10 oder 11 mit **Windows PowerShell 5.1** (vorinstalliert) und **PowerShell 7** – der Code muss in beiden laufen
- Git
- Für die Integrationstests: [WinFsp](https://winfsp.dev) (CloudDrives installiert es beim ersten Start; einmal UAC)
- rclone musst du nicht installieren: CloudDrives holt die festgelegte Version 1.75.1 selbst und prüft ihre Prüfsumme.

Die Werkzeuge für Tests und Lint installiert ein Skript in einen privaten Ordner
(`%LOCALAPPDATA%\CloudDrives-dev\Modules`, mit `CLOUDDRIVES_DEVTOOLS` änderbar) – nichts wird systemweit installiert:

```powershell
.\tools\Install-DevTools.ps1      # Pester 5.7.1 und PSScriptAnalyzer 1.25.0
```

## Starten

```powershell
.\CloudDrives.bat                                   # Menü
.\CloudDrives.bat help                              # alle Befehle
.\CloudDrives.bat status --home="$env:TEMP\cd-test" # mit eigenem Datenordner
```

Aus dem Repository läuft die **Entwicklungskopie**. Sie bietet an, sich nach `%LOCALAPPDATA%\Programs\CloudDrives` zu
installieren; Updates gibt es nur für die installierte Kopie.

**Eigene Testdaten:** `--home=<Ordner>` oder `CLOUDDRIVES_HOME` wählt einen anderen Datenordner. Er bekommt eigene
Einträge in der Windows-Anmeldeinformationsverwaltung, eigene Sperren und eigene geplante Aufgaben; die echte
Einrichtung bleibt unberührt.

Weitere Umgebungsvariablen für Entwicklung und Tests:

| Variable | Wirkung |
|---|---|
| `CLOUDDRIVES_INSTALL_DIR`, `CLOUDDRIVES_SHORTCUT_DIR` | Installieren in einen Sandkasten-Ordner, Verknüpfungen ebenso |
| `CLOUDDRIVES_RELEASE_SOURCE` | Installieren und Aktualisieren aus einem lokal gebauten Paket statt von GitHub |
| `CLOUDDRIVES_SECRET_BACKEND=dpapi` | Geheimnisse in einer DPAPI-Datei statt in der Anmeldeinformationsverwaltung |
| `CLOUDDRIVES_DEBUG=1` | Alles ins Protokoll schreiben, auch die Stufe DEBUG |

## Prüfen

```powershell
.\tools\Format-SourceFiles.ps1                        # Kodierung und Zeilenenden in Ordnung bringen
.\tools\Invoke-Build.ps1 -Edition Both                # Lint und Unit-Tests in PowerShell 5.1 und 7 (wie die CI)
.\tools\Invoke-Build.ps1 -Edition Both -Integration   # zusätzlich echte Engine, Laufwerke und geplante Aufgaben
```

Das Quality Gate (`Invoke-Build.ps1`) prüft:

1. **Quelldateien:** `.ps1`/`.psm1`/`.psd1` UTF-8 mit BOM, `.cs`/`.json`/`.md` UTF-8 ohne BOM, `.bat` und `install.ps1` nur
   ASCII, Windows-Zeilenenden, eine Zeilenschaltung am Dateiende (`Format-SourceFiles.ps1 -Check`).
2. **PSScriptAnalyzer** mit den Regeln aus `PSScriptAnalyzerSettings.psd1`.
3. **Pester** in der gewählten PowerShell-Ausgabe; `-Edition Both` startet beide.

- **Unit-Tests** (`tests/Unit`) laufen ohne Netz, ohne Engine und ohne Laufwerke. `tests/TestHelper.ps1` legt für jede
  Datei einen eigenen Datenordner im Temp-Ordner an (`New-CdTestHome`); Tests greifen mit `InModuleScope CloudDrives` auf
  die Funktionen zu und ersetzen Systemzugriffe mit `Mock`.
- **Integrationstests** (`tests/Integration`) starten echtes rclone, binden Laufwerke über WinFsp ein und legen geplante
  Aufgaben an – alles mit eigenem Datenordner und Sandkasten-Ordnern, nie für die echte Einrichtung.
- Auf GitHub laufen bei jedem Push und Pull Request Lint, Unit-Tests unter 5.1 und 7 und ein Geheimnis-Scan
  (`.github/workflows/ci.yml`).

## Pakete und Veröffentlichen

**Lokal bauen:**

```powershell
.\tools\Build-Release.ps1 -LocalSource     # ZIP, install.ps1, SHA256SUMS.txt und release.json in .\out
$env:CLOUDDRIVES_RELEASE_SOURCE = "$PWD\out"
```

Das ZIP enthält nur, was Nutzer brauchen (`src/Resources/app.json`, `packageItems`), nie Tests oder Werkzeuge.

**Veröffentlichen:**

1. Version in `src/CloudDrives.psd1` (`ModuleVersion`) und Abschnitt `## [X.Y.Z] – <Datum>` in `CHANGELOG.md`.
2. Committen, Pull Request, mergen.
3. Tag `vX.Y.Z` auf den Merge-Commit setzen und pushen. Der Workflow `.github/workflows/release.yml` prüft, dass Tag
   und Version zusammenpassen, läuft durch das Quality Gate, baut ZIP, `install.ps1` und Prüfsummen und veröffentlicht
   das Release mit dem Abschnitt aus dem CHANGELOG.

**Testversionen:** zusätzlich `Prerelease = 'preview.1'` unter `PrivateData.PSData` im Manifest, Abschnitt
`## [X.Y.Z-preview.1]` im CHANGELOG, Tag `vX.Y.Z-preview.1`. Der Workflow veröffentlicht sie als Pre-Release; nur
Installationen mit „Testversionen erhalten“ bekommen sie, `install.ps1` bleibt bei der neuesten regulären Version.

## Fehlersuche

- Protokolle: `%LOCALAPPDATA%\CloudDrives\logs\` – CloudDrives (geschwärzt) und `rclone.log`.
- `CloudDrives.bat doctor` prüft alles mit Ampel, `--fix` repariert, `--bundle` packt ein geschwärztes Support-Paket.
- `CLOUDDRIVES_DEBUG=1` schreibt auch Einzelheiten ins Protokoll.

## Wo anfangen?

1. [ARCHITECTURE.md](ARCHITECTURE.md) lesen.
2. `src/CloudDrives.psm1` – in welcher Reihenfolge das Modul seine Dateien lädt.
3. `src/UI/Cli.ps1` (`Invoke-CdCli`) – was bei jedem Aufruf passiert.
4. `src/Commands/Connection.ps1` und `src/Services/Drives.ps1` – vom Befehl zum Laufwerk.
5. `src/Infrastructure/Engine.ps1` – wie die Engine startet und wie man mit ihr spricht.

## Häufige Änderungen

- **Ein neuer Text:** Schlüssel in `src/Resources/lang/de.json` **und** `en.json`, im Code `Get-CdText '<schlüssel>'`.
  Ein Test prüft, dass beide Dateien dieselben Schlüssel haben.
- **Ein neuer Fehlercode:** Eintrag in `src/Resources/errors.json` (Erkennungsmuster, optional eine automatische Aktion),
  Titel und Lösung als `error.<code>.title`/`.fix` in beiden Sprachdateien, dann `.\tools\New-TroubleshootingDoc.ps1`
  – ein Test prüft, dass `docs/TROUBLESHOOTING.md` dazu passt.
- **Eine neue Einstellung:** Standardwert in `New-CdDefaultSettings` (ältere Dateien bekommen ihn beim Laden), bei Bedarf
  eine Prüfung in `Test-CdSettings`, dann der Eintrag im Einstellungsmenü (`src/UI/SettingsMenu.ps1`).
- **Ein neuer Anbieter:** eine Datei in `src/Providers` mit `Register-CdProvider` (rclone-Typ, Arten, Antworten auf
  rclones Einrichtungsfragen), Texte in beiden Sprachdateien, Tests.
- **Ein neuer Befehl:** Alias in `$script:CdCommandAliases`, Zweig in `Invoke-CdCli`, Beschreibung in `help.text` beider
  Sprachdateien.
