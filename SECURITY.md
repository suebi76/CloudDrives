# Sicherheit

## Sicherheitslücken melden

Bitte melde Sicherheitslücken **vertraulich** über GitHub: Reiter **Security → Report a vulnerability**
([direkt hier](https://github.com/suebi76/CloudDrives/security/advisories/new)). Lege dafür bitte kein öffentliches Issue an.
Sicherheitskorrekturen gibt es für die jeweils neueste Version.

## So schützt CloudDrives deine Daten

| Was | Schutz |
|---|---|
| Passwörter deiner Konten | Werden nie eingegeben oder gespeichert. Du meldest dich nur auf den Seiten von Microsoft bzw. Google an (OAuth). |
| Anmelde-Tokens, eigene Client-IDs, Tresor-Passwörter | Liegen in `%LOCALAPPDATA%\CloudDrives\rclone.conf`, immer verschlüsselt (rclone-Konfigurationsverschlüsselung). |
| Schlüssel dieser Datei | Zufällig erzeugt (256 Bit) und DPAPI-geschützt in der Windows-Anmeldeinformationsverwaltung. Alternativ wird er aus einem Master-Passwort abgeleitet (PBKDF2-SHA256, 600 000 Runden), das nirgends gespeichert wird. |
| Steuerung des Hintergrunddienstes | Nur über 127.0.0.1, mit zufälligem Port und bei jedem Start neuen Zugangsdaten. |
| Datenordner | Nur für deinen Windows-Benutzer und SYSTEM lesbar. |
| Protokolle | Tokens, Passwörter und Schlüssel werden geschwärzt. |
| Support-Paket | Schwärzt zusätzlich E-Mail-Adressen, Benutzer- und Computername. Vor dem Speichern wird es auf jedes Geheimnis geprüft, das CloudDrives kennt. Bei einem Treffer wird es verworfen. |
| Neu-Anmeldung | Wird nur übernommen, wenn sie zum selben Konto gehört. Eine Anmeldung mit einem anderen Konto ändert nichts. |
| Downloads | rclone mit fest hinterlegter SHA256-Prüfsumme. WinFsp mit Prüfsumme und Authenticode-Signatur. Updates von CloudDrives mit der Prüfsumme des Releases. |
| Verschlüsselte Tresore | rclone crypt (Inhalte XSalsa20-Poly1305, Namen AES-256-EME). Eine Prüfdatei verhindert, dass ein Tresor mit falschem Schlüssel eingebunden wird. |

## Dieses Repository

Es enthält niemals Zugangsdaten. Dafür sorgen mehrere Schutzschichten:

- eine Allowlist-`.gitignore`
- Tests auf Token-Muster
- gitleaks in der CI
- GitHub Push Protection

## Grenzen

- Schadsoftware, die unter deinem eigenen Windows-Konto läuft, kann auf alles zugreifen, was du selbst öffnen kannst.
  Das kann keine lokale Lösung verhindern.
- Wer deinen entsperrten PC benutzt, kann auf die verbundenen Laufwerke zugreifen.
- Ohne Passwort und Salt aus dem Recovery-Kit sind die Daten eines Tresors verloren.

## English summary

Report vulnerabilities privately via **Security → Report a vulnerability**. CloudDrives never sees account passwords
(OAuth only). Tokens, client secrets and vault passwords are stored in an always-encrypted rclone.conf whose key is
kept DPAPI-protected in the Windows Credential Manager (or derived from a master password). The engine is reachable on
127.0.0.1 only, with a random port and per-start credentials. Logs are redacted. Support bundles are additionally
checked against every known secret before they are saved. Downloads are checksum- or signature-verified. The
repository is protected against secrets by an allowlist `.gitignore`, tests, gitleaks and GitHub push protection.
