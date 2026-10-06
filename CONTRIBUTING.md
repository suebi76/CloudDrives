# Mitwirken

*English version: [CONTRIBUTING.en.md](CONTRIBUTING.en.md)*

Danke für dein Interesse an CloudDrives!

- **Fehler und Wünsche** meldest du als [Issue](https://github.com/suebi76/CloudDrives/issues). Hänge bei Fehlern bitte ein
  Support-Paket an (Menü → *Diagnose & Hilfe*).
- **Sicherheitslücken** meldest du bitte vertraulich, siehe [SECURITY.md](SECURITY.md).

Wie du das Projekt einrichtest, prüfst und veröffentlichst, steht im [Entwickler-Handbuch](docs/DEVELOPMENT.md), wie es
aufgebaut ist in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Kurz:

```powershell
.\tools\Install-DevTools.ps1                          # Pester und PSScriptAnalyzer in einen privaten Ordner
.\tools\Format-SourceFiles.ps1                        # Kodierung und Zeilenenden normalisieren
.\tools\Invoke-Build.ps1 -Edition Both                # Lint und Unit-Tests in PowerShell 5.1 und 7 (wie die CI)
.\tools\Invoke-Build.ps1 -Edition Both -Integration   # zusätzlich echte Engine, Laufwerke und geplante Aufgaben
```

## Regeln für den Code

Das Ziel: Wer den Code zum ersten Mal liest – ob Autor, Schul-IT oder Entwickler aus einem anderen Land –, soll ihn ohne
Vorwissen verstehen. Die Regeln gelten für neuen und geänderten Code.

### Aufbau

- **Schichten:** `src/Infrastructure` → `src/Providers` → `src/Services` → `src/Commands` → `src/UI`. Abhängigkeiten
  zeigen nur nach unten. Neue Dateien lädt das Modul von selbst (je Ordner alphabetisch).
- **Ausgabe:** Dienste geben Ergebnisobjekte zurück (`New-CdResult`) und schreiben nichts auf den Bildschirm. Nur
  `src/UI` spricht mit dem Nutzer.
- **Eine Datei, ein Thema**, und der Dateiname sagt es (`Watchdog.ps1`, `AccountSignIn.ps1`). Ab etwa 400 Zeilen wird
  nach Themen aufgeteilt. Begründete Ausnahme: `src/Resources/Native.cs` bleibt eine Datei, weil Windows PowerShell sie
  bei jedem Start übersetzt.

### Namen

- Funktionen heißen *Verb-Substantiv* mit einem freigegebenen PowerShell-Verb (`Get-Verb`) und dem Präfix `Cd`:
  `Get-CdDrive`, `Invoke-CdConnect`. Parameter und Variablen sind englisch, ausgeschrieben und sprechend.
- Zustand des Moduls liegt in `$script:Cd…`-Variablen am Anfang der Datei, die ihn verwaltet.
- Begriffe einheitlich verwenden, wie sie im Code schon vorkommen: *drive* (ein Laufwerk), *account*, *vault*
  (Tresor), *engine* (der rclone-Prozess), *watchdog*, *symbol* (im Infobereich), *wanted drives* (die verbunden sein
  sollen).

### Kommentare

- **Englisch**, in ganzen Sätzen, für Leser ohne Vorwissen.
- **Jede Datei** beginnt mit einem Kommentar, der ihre Aufgabe nennt.
- **Funktionen**, deren Name nicht alles sagt, beginnen mit einem Kommentar: was sie tun, was sie zurückgeben, was
  Besonderes gilt.
- Kommentare erklären das **Warum** – eine Eigenheit von rclone, WinFsp oder Windows, eine Entscheidung, eine Gefahr –,
  nicht das Was, das ohnehin im Code steht.
- Wissen über rclone, WinFsp und Windows gehört zusätzlich in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
- Kein auskommentierter Code, keine `TODO` ohne Issue.

### Texte der Oberfläche

- Texte kommen nur über `Get-CdText` und stehen in **beiden** Sprachdateien (`src/Resources/lang`).
- Deutsch: freundlich, ohne Fachjargon, der Nutzer wird geduzt. Meldungen sagen, was passiert ist und was hilft.

### Fehler

- Fehler sind Ausnahmen mit einem Code `CD-xxxx` (`New-CdException`).
- Jeder Code steht in `src/Resources/errors.json` und hat Titel und Lösung auf Deutsch und Englisch. Nach Änderungen
  daran `.\tools\New-TroubleshootingDoc.ps1` ausführen.
- Eine Ausnahme wird nie stillschweigend geschluckt: Entweder ein Kommentar sagt, warum das in Ordnung ist, oder sie
  wird protokolliert.

### Kompatibilität

- Der Code muss unter **Windows PowerShell 5.1** laufen: kein `? :`, `??` oder `&&` in Skripten, JSON-Listen mit
  `foreach` durchgehen (5.1 liefert sie als ein Objekt), `.ps1`-Dateien mit BOM.
- `CloudDrives.bat` und `install.ps1` enthalten nur ASCII.

### Sicherheit und Daten

- **Geheimnisse** (Tokens, Passwörter, Schlüssel) nur in der verschlüsselten `rclone.conf` und im Geheimnisspeicher –
  nie in `settings.json`, Protokollen, Tests oder diesem Repository.
- **Keine echten Daten:** niemals echte Zugangsdaten, Tokens oder persönliche Daten committen, auch nicht in Tests.
- **Was der Nutzer selbst einstellt, bleibt:** z. B. Namen, die er einem Laufwerk im Explorer gibt, werden übernommen,
  nie überschrieben.

### Tests

- Jede Änderung braucht Tests. Systemnahes (Engine, Laufwerke, geplante Aufgaben) bekommt zusätzlich
  Integrationstests.
- Testnamen beschreiben das Verhalten als Satz (`It 'installs automatically, but only when no CloudDrives window is open'`).

### Form

- Kodierung und Zeilenenden: `.\tools\Format-SourceFiles.ps1`.
- PSScriptAnalyzer meldet nichts (`PSScriptAnalyzerSettings.psd1`).

## Pull Requests

- Arbeite auf einem eigenen Branch mit aussagekräftigen Commits (englisch) und ergänze einen Eintrag in `CHANGELOG.md`.
- Die CI muss grün sein: Lint, Unit-Tests unter PowerShell 5.1 und 7 sowie gitleaks.

## Releases

Version in `src/CloudDrives.psd1` und `CHANGELOG.md` setzen, Tag `vX.Y.Z` pushen – den Rest erledigt der
Release-Workflow. Testversionen (`vX.Y.Z-preview.1`) und alle Einzelheiten: [Entwickler-Handbuch](docs/DEVELOPMENT.md#pakete-und-veröffentlichen).
