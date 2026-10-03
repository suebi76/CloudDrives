# Verschlüsselte Tresore

Für jedes Konto entscheidest du selbst, ob und wie verschlüsselt wird:

| Auswahl im Assistenten | Ergebnis |
|---|---|
| **Normales Laufwerk** | Dateien liegen unverschlüsselt in der Cloud, also wie gewohnt im Browser und in der Handy-App lesbar. |
| **Normales Laufwerk + Tresor** | Zwei Laufwerke, z. B. `K:` (normal) und `V:` (Tresor). |
| **Nur Tresor** | Nur das verschlüsselte Laufwerk. |

Einen Tresor kannst du jederzeit nachträglich anlegen oder wieder entfernen: **Menü → Laufwerke verwalten**.

## Wie funktioniert der Tresor?

- Er ist ein **eigener Ordner** in der Cloud, Standard `CloudDrives-Tresor`. Deine übrigen Dateien bleiben unberührt.
- Dateien werden **auf deinem PC verschlüsselt, bevor sie hochgeladen werden**. Das gilt auch für Datei- und Ordnernamen.
  Microsoft und Google sehen nur Zeichensalat.
- Technik: [rclone crypt](https://rclone.org/crypt/)
  - Inhalte: XSalsa20-Poly1305
  - Namen: EME/AES-256
  - Schlüssel: per scrypt aus **Passwort und Salt** abgeleitet
- Bei OneDrive werden die verschlüsselten Namen mit `base32768` kodiert, bei Google Drive mit `base32`.
  `base32768` hält die Namen unter der Längengrenze von OneDrive.
- Im Tresor liegt eine kleine verschlüsselte Prüfdatei. Mit falschem Passwort bindet CloudDrives den Tresor **gar nicht erst
  ein** (Fehler `CD-6001`). So können nie Dateien mit einem falschen Schlüssel entstehen.

## Passwort und Salt – das Recovery-Kit

Beim Anlegen erzeugt CloudDrives ein starkes Passwort und ein Salt (je 24 Zeichen). Ein eigenes Passwort ist ebenfalls möglich.
Beides zeigt das **Recovery-Kit** einmalig an.

> **Ohne Passwort UND Salt sind die Daten im Tresor unwiederbringlich verloren.** Weder CloudDrives noch Microsoft oder
> Google können sie wiederherstellen.

- Bewahre das Kit im **Passwort-Manager** oder als **Ausdruck** auf.
- Speichere es **nicht** unverschlüsselt in einem Cloud-Ordner. CloudDrives warnt, wenn der gewählte Speicherort mit
  OneDrive oder Google Drive synchronisiert wird.
- Auf diesem PC liegen Passwort und Salt nur in der **verschlüsselten** `rclone.conf`. Deren Schlüssel steht in der
  Windows-Anmeldeinformationsverwaltung.

## Tresor auf einem weiteren PC öffnen

1. CloudDrives installieren und das Konto hinzufügen.
2. **Laufwerke verwalten → Laufwerk hinzufügen → Verschlüsselter Tresor**
3. Denselben Ordner angeben. CloudDrives erkennt den vorhandenen Tresor.
4. Passwort und Salt aus dem Recovery-Kit eingeben. CloudDrives prüft sie, bevor das Laufwerk eingebunden wird.

Auch ein Ordner, den du früher mit reinem rclone (`crypt`) verschlüsselt hast, lässt sich so übernehmen.
Voraussetzungen: dieselben Einstellungen `filename_encryption=standard`, `directory_name_encryption=true` und eine passende
`filename_encoding`.

## Zugriff ohne CloudDrives

Das Recovery-Kit enthält einen fertigen `rclone`-Befehl. Damit kommst du auch ohne CloudDrives an deine Daten, mit jedem
Betriebssystem, das rclone unterstützt. Es entsteht also keine Abhängigkeit von diesem Projekt.

## Grenzen

- Im Browser und in den Handy-Apps von OneDrive/Google Drive sind Tresor-Dateien nicht lesbar. Das ist gewollt.
- Freigaben und Links an andere funktionieren für Tresor-Dateien nicht sinnvoll.
- Verschlüsselte Namen sind länger als die Originale, deshalb sind sehr lange Pfade im Tresor etwas eingeschränkt.
- Ein Tresor-Laufwerk zu entfernen löscht **keine** Dateien in der Cloud. Es entfernt nur den Schlüssel auf diesem PC.
