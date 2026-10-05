# CloudDrives

[![CI](https://github.com/suebi76/CloudDrives/actions/workflows/ci.yml/badge.svg)](https://github.com/suebi76/CloudDrives/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/suebi76/CloudDrives)](https://github.com/suebi76/CloudDrives/releases/latest)

**OneDrive, Google Drive, Nextcloud und IServ als Laufwerke in Windows – per Doppelklick.**
*Mount OneDrive, Google Drive, Nextcloud, IServ and other WebDAV servers as Windows drive letters (English summary below).*

CloudDrives bindet deine Cloud-Speicher als echte Laufwerksbuchstaben ein, z. B. `M:` für OneDrive, `K:` für Google
Drive und `X:` für Nextcloud oder IServ.
Grundlage sind [rclone](https://rclone.org) und [WinFsp](https://winfsp.dev). Bedient wird es über ein deutsches Konsolen-Menü
mit geführten Assistenten. Die Installation läuft automatisch, und Anmeldedaten werden verschlüsselt gespeichert.

> **Status:** in Entwicklung (Version 0.3). Getestet sind Kern, Engine, Laufwerksverwaltung, verschlüsselte Tresore,
> Autostart, automatisches Wiederverbinden, Diagnose, Symbol im Infobereich sowie Installation und Updates.

## Funktionen

- **Mehrere Konten:** privates OneDrive (auch Microsoft 365 Family), privates Google-Konto, Google Workspace,
  Nextcloud, IServ (Schulserver) und jeder andere WebDAV-Server
- **Verschlüsselung nach Wahl:** Pro Konto entscheidest du, ob du ein normales Laufwerk möchtest, zusätzlich einen
  verschlüsselten Tresor oder nur einen Tresor. Mehr dazu in [docs/ENCRYPTION.md](docs/ENCRYPTION.md)
- **Sichere Anmeldung im Browser:** CloudDrives sieht nie ein Passwort und speichert nur widerrufbare Tokens,
  verschlüsselt mit einem Schlüssel in der Windows-Anmeldeinformationsverwaltung
- **Wie lokale Laufwerke:** Office, Bildbearbeitung und andere Programme arbeiten direkt auf dem Laufwerk.
  Uploads laufen im Hintergrund und werden nach einem Neustart fortgesetzt
- **Verbindet sich selbst wieder:** Nach Standby, Netzwerkwechsel oder einem Absturz holt der Watchdog die Laufwerke
  zurück. Er prüft alle 5 Minuten, nach dem Aufwachen und nach Netzwerkwechseln. Laufwerke, die du selbst trennst,
  bleiben getrennt
- **Explorer-Integration:** sprechende Namen wie „Google Pro (K:)“ und echte Speicheranzeige
- **Symbol im Infobereich:** Ein farbiger Punkt zeigt den Status: grün = verbunden, gelb = wird wieder verbunden,
  rot = braucht dich, grau = nichts verbunden. Per Rechtsklick öffnest du Laufwerke, verbindest oder trennst alle,
  startest die Diagnose oder meldest ein Konto neu an
- **Fehleranalyse:** verständliche Meldungen mit Fehlercode (z. B. `CD-4001`) und konkreter Lösung, ausführliche Protokolle
- **Keine Admin-Rechte nötig:** Ausnahme ist die einmalige Installation des Treibers WinFsp

## Voraussetzungen

- Windows 10 oder 11 (x64 oder ARM64)
- Windows PowerShell 5.1 (vorinstalliert); PowerShell 7 wird ebenfalls unterstützt

## Installation

**Empfohlen: per Einzeiler.** PowerShell öffnen (Startmenü → „PowerShell“, ohne Administratorrechte) und eingeben:

```powershell
irm https://github.com/suebi76/CloudDrives/releases/latest/download/install.ps1 | iex
```

Was dabei passiert:

1. Das Skript lädt die neueste Version und prüft ihre SHA256-Prüfsumme.
2. Es installiert CloudDrives nach `%LOCALAPPDATA%\Programs\CloudDrives` und legt Verknüpfungen im Startmenü und auf
   dem Desktop an.
3. Danach startet der Assistent. Er installiert rclone (mit geprüfter Prüfsumme) und den Treiber WinFsp. Für WinFsp
   bestätigst du einmal die Windows-Abfrage, ob Änderungen erlaubt sind.
4. Zum Schluss verbindest du dein erstes Konto.

Du möchtest das Skript vorher lesen? Dann lade `install.ps1` aus dem
[neuesten Release](https://github.com/suebi76/CloudDrives/releases/latest) herunter, prüfe es und starte es mit
Rechtsklick → „Mit PowerShell ausführen“.

**Alternative: als ZIP.**

1. `CloudDrives-<Version>.zip` aus dem [neuesten Release](https://github.com/suebi76/CloudDrives/releases/latest)
   herunterladen und entpacken.
2. **`CloudDrives.bat`** doppelklicken.
3. CloudDrives bietet beim ersten Start an, sich zu installieren. Danach kannst du den entpackten Ordner löschen.

**Updates:** Im Menü unter Einstellungen → „Nach Updates suchen“ oder per `CloudDrives.bat aktualisieren`.

- Nach dem Autostart prüft CloudDrives einmal täglich, ob es eine neue Version gibt, und meldet sich dann.
- Installiert wird ein Update nur, wenn du zustimmst.
- Jedes Update wird per SHA256 geprüft. Klappt der Austausch nicht, bleibt die bisherige Version erhalten.

**Deinstallieren:** Im Menü unter Einstellungen → „CloudDrives deinstallieren“ oder per `CloudDrives.bat deinstallieren`.

- Mit `--remove-data` werden zusätzlich die Anmeldungen, Einstellungen und der Zwischenspeicher auf diesem PC gelöscht.
- Deine Dateien in der Cloud bleiben unverändert.
- Der Treiber WinFsp bleibt installiert.

## Bedienung

Gestartet wird CloudDrives über das Startmenü. Die Befehle unten gelten für die installierte Kopie unter
`%LOCALAPPDATA%\Programs\CloudDrives\CloudDrives.bat`.

| Befehl | Wirkung |
|---|---|
| `CloudDrives.bat` | Menü öffnen |
| `CloudDrives.bat verbinden` | alle Laufwerke verbinden (`verbinden K` nur eines) |
| `CloudDrives.bat trennen` | alle Laufwerke trennen (`--force` trotz laufender Uploads) |
| `CloudDrives.bat status --json` | Status für Skripte |
| `CloudDrives.bat diagnose` | Diagnose mit Ampel-Anzeige (`--fix` behebt automatisch, `--bundle` erstellt ein Support-Paket) |
| `CloudDrives.bat neu-anmelden K` | Konto von Laufwerk K: neu anmelden, ohne es zu entfernen |
| `CloudDrives.bat client-id K` | eigene Google-Client-ID des Kontos ändern |
| `CloudDrives.bat autostart an` | bei der Windows-Anmeldung automatisch verbinden (`aus` schaltet es ab) |
| `CloudDrives.bat watchdog an` | nach Standby, Netzwerkwechsel oder Absturz automatisch wieder verbinden (`aus`, `status`) |
| `CloudDrives.bat tray an` | Symbol im Infobereich bei jeder Anmeldung zeigen (`aus`, `status`; ohne Option: jetzt zeigen) |
| `CloudDrives.bat aktualisieren` | nach Updates suchen und installieren (`--check` nur prüfen) |
| `CloudDrives.bat deinstallieren` | CloudDrives von diesem PC entfernen |
| `CloudDrives.bat hilfe` | alle Befehle |

## Hilfe bei Problemen

Alle Fehlercodes mit Erklärung und Lösung stehen in [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

Im Menü unter **Diagnose & Hilfe** prüft CloudDrives in wenigen Sekunden diese Punkte und zeigt das Ergebnis als
Ampel-Liste, jeweils mit Lösungsvorschlag:

- System, rclone und WinFsp
- Einstellungen und Verschlüsselung
- Netzwerk (Erreichbarkeit, Proxy)
- Hintergrunddienst
- Konten (Anmeldung, Speicherplatz)
- Laufwerke (Lesetest, Tresor-Schlüssel, Uploads)
- letzte Fehler und Autostart

Vieles behebt **„Automatisch beheben“** selbst: fehlende Komponenten installieren, Laufwerke verbinden, Autostart
reparieren und abgelaufene Anmeldungen erneuern.

Für eine Fehlermeldung erstellst du dort ein **Support-Paket**, eine ZIP-Datei auf dem Desktop.

- **Nicht enthalten:** Passwörter, Tokens, Schlüssel und Dateiinhalte.
- **Geschwärzt:** E-Mail-Adressen, Benutzername, Computername und Profilpfade.
- **Sicherheitsprüfung:** Vor dem Speichern durchsucht CloudDrives das Paket nach jedem Geheimnis, das es kennt. Bei einem
  Treffer wird das Paket verworfen.

## Sicherheit

- **Anmeldung:** bei Microsoft und Google ausschließlich auf deren Seiten (OAuth). CloudDrives sieht dort nie ein
  Passwort. Bei Nextcloud bekommt CloudDrives ein eigenes, widerrufbares App-Passwort. IServ und andere WebDAV-Server
  brauchen Benutzername und Passwort. Die gibst du verdeckt in CloudDrives ein, gespeichert werden sie nur verschlüsselt.
- **Neu anmelden:** Ist eine Anmeldung abgelaufen oder widerrufen, meldest du das Konto unter **Konten verwalten** neu an.
  Das Konto selbst bleibt dabei bestehen. CloudDrives prüft, dass du dich mit demselben Konto anmeldest. So landen die
  Dateien eines Laufwerks nie versehentlich in einem anderen Konto.
- **Tokens:** liegen in `%LOCALAPPDATA%\CloudDrives\rclone.conf`, verschlüsselt mit einem zufälligen 256-Bit-Schlüssel.
  Der Schlüssel liegt DPAPI-geschützt in der Windows-Anmeldeinformationsverwaltung. Der Ordner ist nur für deinen Benutzer lesbar.
- **Repository:** Es enthält nie Zugangsdaten. Mehrere Schutzschichten sorgen dafür: Allowlist-`.gitignore`, Secret-Scans in
  den Tests und GitHub Push Protection.
- **Grenze:** Schadsoftware, die unter deinem eigenen Windows-Konto läuft, kann keine lokale Lösung zuverlässig abwehren.

## Nextcloud, IServ und andere WebDAV-Server

CloudDrives verbindet sich über rclone direkt per WebDAV. Der WebDAV-Client von Windows wird nicht gebraucht, ebenso
wenig Registry-Patches. Für Office ist das Laufwerk ein ganz normales Laufwerk, deshalb gibt es auch keine Warnungen zur
Basic-Anmeldung.

- **Nextcloud:** Du gibst die Adresse ein, unter der du Nextcloud im Browser öffnest. Die WebDAV-Adresse aus den
  Nextcloud-Dateieinstellungen geht auch. Dann meldest du dich im Browser an, auch mit Zwei-Faktor-Anmeldung, und
  Nextcloud erstellt ein eigenes App-Passwort für CloudDrives. Dein Passwort bleibt bei Nextcloud.
  - **Wenn der Betreiber diese Anmeldung für Programme sperrt:** CloudDrives fragt dann nach einem App-Passwort. Du
    erstellst es in Nextcloud unter *Einstellungen → Sicherheit → Neues App-Passwort erstellen*.
  - **Widerrufen:** Das App-Passwort lässt sich dort jederzeit widerrufen.
- **IServ:** Du gibst die Adresse deiner Schule ein, z. B. `meine-schule.de`. CloudDrives verbindet sich mit
  `webdav.meine-schule.de` und fragt nach IServ-Benutzername und Passwort. Im Laufwerk siehst du „Eigene“ und „Gruppen“.
- **Andere WebDAV-Server:** Du gibst die vollständige WebDAV-Adresse ein, dazu Benutzername und Passwort.

Passwörter gibst du nur in CloudDrives ein, die Eingabe bleibt unsichtbar. Sie liegen ausschließlich in der verschlüsselten
rclone-Konfiguration, nie in Einstellungen, Protokollen oder im Repository. Erlaubt sind nur `https`-Adressen. Lehnt der
Server die Anmeldung ab, etwa nach einer Passwortänderung, meldest du das Konto unter **Konten verwalten** neu an. Dabei
fragt CloudDrives nur das neue Passwort ab.

## Google: eigene Client-ID (erforderlich)

rclone stellt seine gemeinsame Google-Client-ID im Laufe von 2026 ein, und Google drosselt sie schon jetzt stark.
Für Google-Konten brauchst du deshalb eine eigene, kostenlose Client-ID. Die Anleitung steht in
[docs/GOOGLE-OAUTH.md](docs/GOOGLE-OAUTH.md).

## Entwicklung

```powershell
.\tools\Install-DevTools.ps1                          # Pester + PSScriptAnalyzer (privater Ordner)
.\tools\Invoke-Build.ps1 -Edition Both                # Format-, Lint- und Unit-Tests in PowerShell 5.1 und 7
.\tools\Invoke-Build.ps1 -Edition Both -Integration   # zusätzlich echte Engine + Laufwerk (benötigt WinFsp)
.\tools\Format-SourceFiles.ps1                        # Kodierung/Zeilenenden normalisieren
.\tools\Build-Release.ps1 -LocalSource                # Release-Paket (ZIP, install.ps1, SHA256SUMS.txt) in .\out
```

Mit `CLOUDDRIVES_RELEASE_SOURCE=<Ordner mit release.json>` installieren und aktualisieren `install.ps1` und
`CloudDrives.bat aktualisieren` aus einem lokal gebauten Paket statt aus GitHub.

Aufbau: `src/Infrastructure` (Technik) → `src/Providers` → `src/Services` → `src/Commands` → `src/UI`.
Abhängigkeiten zeigen nur nach unten.

- **Regeln für Beiträge:** [CONTRIBUTING.md](CONTRIBUTING.md)
- **Sicherheitsmodell und Melden von Lücken:** [SECURITY.md](SECURITY.md)
- **Automatische Prüfungen:** Jeder Push und jeder Pull Request durchläuft auf GitHub Lint, Unit-Tests unter
  PowerShell 5.1 und 7 und einen Geheimnis-Scan.
- **Releases:** Ein Versions-Tag erzeugt automatisch ZIP, `install.ps1` und Prüfsummen.

## English summary

CloudDrives mounts OneDrive, Google Drive (personal and Workspace), Nextcloud, IServ and other WebDAV servers as Windows
drive letters using rclone and WinFsp.
Install it without administrator rights from PowerShell:

```powershell
irm https://github.com/suebi76/CloudDrives/releases/latest/download/install.ps1 | iex
```

The installer verifies the SHA256 checksum, installs to `%LOCALAPPDATA%\Programs\CloudDrives` and starts the guided
setup. Alternatively, download the ZIP from the latest release and double-click `CloudDrives.bat`. You sign in through
the provider's own page (OAuth). Tokens are stored encrypted with a key kept in the Windows Credential Manager. Updates
are checksum-verified and only installed with your consent. The UI language follows Windows (German/English).

## Lizenz

© 2026 Steffen Schwabe · [Projekt auf GitHub](https://github.com/suebi76/CloudDrives)

- **Quellcode:** [MIT-Lizenz](LICENSE). Du darfst ihn frei nutzen, verändern und weitergeben, solange der
  Copyright-Hinweis und die Lizenz erhalten bleiben.
- **Dokumentation und Grafiken** (Texte in diesem Repository außerhalb des Quellcodes, die Symbole):
  [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/deed.de). Bei Weitergabe nennst du „Steffen Schwabe,
  CloudDrives“ und verlinkst die Lizenz.
- **Verwendete Bausteine:** rclone (MIT) und WinFsp (GPLv3 mit FLOSS-Ausnahme) werden zur Laufzeit von den offiziellen
  Quellen geladen und sind nicht Teil dieses Repositorys; Einzelheiten in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
