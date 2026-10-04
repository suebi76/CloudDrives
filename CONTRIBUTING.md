# Mitwirken

Danke für dein Interesse an CloudDrives!

- **Fehler und Wünsche** meldest du als [Issue](https://github.com/suebi76/CloudDrives/issues). Hänge bei Fehlern bitte ein
  Support-Paket an (Menü → *Diagnose & Hilfe*).
- **Sicherheitslücken** meldest du bitte vertraulich, siehe [SECURITY.md](SECURITY.md).

## Entwicklungsumgebung

- Windows 10 oder 11 mit Windows PowerShell 5.1 und PowerShell 7, dazu Git
- `.\tools\Install-DevTools.ps1` installiert Pester und PSScriptAnalyzer in einen privaten Ordner.
- Für die Integrationstests brauchst du WinFsp. CloudDrives installiert es beim ersten Start.

## Prüfen

```powershell
.\tools\Format-SourceFiles.ps1                        # Kodierung und Zeilenenden normalisieren
.\tools\Invoke-Build.ps1 -Edition Both                # Lint und Unit-Tests in PowerShell 5.1 und 7 (wie die CI)
.\tools\Invoke-Build.ps1 -Edition Both -Integration   # zusätzlich echte Engine, Laufwerke und geplante Aufgaben
```

## Regeln für den Code

- **Schichten:** `src/Infrastructure` → `src/Providers` → `src/Services` → `src/Commands` → `src/UI`.
  Abhängigkeiten zeigen nur nach unten.
- **Ausgabe:** Dienste geben Ergebnisobjekte zurück und schreiben nichts auf den Bildschirm. Nur `src/UI` spricht mit dem Nutzer.
- **Fehler:**
  - Fehler sind Ausnahmen mit einem Code `CD-xxxx` (`New-CdException`).
  - Jeder Code steht in `src/Resources/errors.json` und hat Titel und Lösung auf Deutsch und Englisch.
  - Nach Änderungen daran `.\tools\New-TroubleshootingDoc.ps1` ausführen.
- **Texte** kommen nur über `Get-CdText` und stehen in beiden Sprachdateien.
- **Kompatibilität:** Code muss unter PowerShell 5.1 laufen, also ohne `? :`, `??` oder `&&` in Skripten.
- **Kodierung:**
  - `.ps1`-Dateien sind UTF-8 mit BOM und CRLF.
  - `CloudDrives.bat` und `install.ps1` enthalten nur ASCII.
- **Tests:** Jede Änderung braucht Tests. Systemnahes (Engine, Laufwerke, geplante Aufgaben) bekommt zusätzlich Integrationstests.
- **Keine echten Daten:** Niemals echte Zugangsdaten, Tokens oder persönliche Daten committen, auch nicht in Tests.

## Pull Requests

- Arbeite auf einem eigenen Branch mit aussagekräftigen Commits und ergänze einen Eintrag in `CHANGELOG.md`.
- Die CI muss grün sein: Lint, Unit-Tests unter PowerShell 5.1 und 7 sowie gitleaks.

## Releases

1. Version in `src/CloudDrives.psd1` und in `CHANGELOG.md` setzen.
2. Tag `vX.Y.Z` pushen. Der Release-Workflow baut `CloudDrives-X.Y.Z.zip`, `install.ps1` und `SHA256SUMS.txt` und
   veröffentlicht das Release mit dem passenden Abschnitt aus dem CHANGELOG.
