# Datenschutzerklärung / Privacy Policy

## Deutsch

CloudDrives ist ein Open-Source-Programm, das vollständig **lokal auf deinem Windows-PC** läuft.

- **Keine Datensammlung:** CloudDrives hat keinen Server und keine Telemetrie. Es sendet keine Daten an den Entwickler.
- **Zugriff auf deine Cloud:** Nach deiner Anmeldung beim Anbieter (Google, Microsoft, Nextcloud, IServ oder ein anderer
  WebDAV-Server, den du einträgst) greift CloudDrives über die offiziellen Schnittstellen auf deine Dateien zu. Das
  geschieht ausschließlich, um sie auf deinem PC als Laufwerk bereitzustellen. Die Daten fließen direkt zwischen deinem PC
  und dem Anbieter.
- **Weitere Verbindungen**, bei denen nur die technischen Angaben jeder Webanfrage übertragen werden (deine IP-Adresse,
  die Programmversion) – keine Dateien, keine Anmeldedaten:
  - **Netz prüfen:** Bevor es verbindet, prüft CloudDrives mit einem kurzen Verbindungsaufbau zu Servern von Google und
    Microsoft, ob das Internet erreichbar ist. Die Diagnose prüft außerdem die Server deiner Anbieter und GitHub.
  - **Updates:** Wie in den Einstellungen gewählt, sieht CloudDrives bei GitHub nach neuen Versionen und lädt sie dort
    herunter. Mit „Nur wenn ich nachsehe“ geschieht das nur, wenn du selbst danach suchst. Es gilt die
    [Datenschutzerklärung von GitHub](https://docs.github.com/site-policy/privacy-policies/github-general-privacy-statement).
  - **Bausteine:** rclone kommt von downloads.rclone.org (ersatzweise von GitHub oder über winget), WinFsp über winget oder
    von GitHub – jeweils mit geprüfter Prüfsumme.
- **Anmeldedaten:** Bei Google, Microsoft und Nextcloud meldest du dich auf der Seite des Anbieters an – CloudDrives sieht
  dein Passwort nie, es bekommt nur widerrufbare Zugriffsschlüssel (Tokens, bei Nextcloud ein eigenes App-Passwort). Bei
  IServ und anderen WebDAV-Servern gibst du Benutzername und Passwort in CloudDrives ein; sie gehen nur an deinen Server.
  Alles wird nur auf deinem PC gespeichert, verschlüsselt mit einem Schlüssel in der Windows-Anmeldeinformationsverwaltung
  (oder mit deinem Master-Passwort, wenn du eines eingerichtet hast).
- **Widerruf:** Den Zugriff kannst du jederzeit widerrufen:
  - Google: [myaccount.google.com/permissions](https://myaccount.google.com/permissions)
  - Microsoft: [account.live.com/consent/Manage](https://account.live.com/consent/Manage)
  - Nextcloud: in Nextcloud unter *Einstellungen › Sicherheit*
- **Lokale Dateien:** Einstellungen, Protokolle und Zwischenspeicher liegen unter `%LOCALAPPDATA%\CloudDrives` und lassen sich
  über die Deinstallation entfernen.

Die Nutzung von Google-API-Daten entspricht der
[Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy),
einschließlich der Anforderungen zur eingeschränkten Nutzung (Limited Use).

## English

CloudDrives is open-source software that runs entirely **locally on your Windows PC**.

- **No data collection:** CloudDrives has no server and no telemetry. It sends no data to the developer.
- **Access to your cloud:** After you sign in with the provider (Google, Microsoft, Nextcloud, IServ or another WebDAV server
  you enter), CloudDrives accesses your files through the official APIs. It does so solely to make them available on your
  PC as a drive. Data flows directly between your PC and the provider.
- **Other connections**, which transfer only the technical details of any web request (your IP address, the program
  version) - no files, no sign-in details:
  - **Checking the network:** before connecting, CloudDrives briefly opens a connection to servers of Google and Microsoft
    to find out whether the internet can be reached. The diagnosis also checks your providers' servers and GitHub.
  - **Updates:** as chosen in the settings, CloudDrives looks for new versions on GitHub and downloads them from there. With
    "Nur wenn ich nachsehe" (only when I check) this happens only when you look yourself. GitHub's
    [privacy statement](https://docs.github.com/site-policy/privacy-policies/github-general-privacy-statement) applies.
  - **Components:** rclone comes from downloads.rclone.org (or else from GitHub or through winget), WinFsp through winget or
    from GitHub - each with a verified checksum.
- **Credentials:** with Google, Microsoft and Nextcloud you sign in on the provider's own page - CloudDrives never sees your
  password, it only receives revocable access keys (tokens; with Nextcloud an app password of its own). With IServ and
  other WebDAV servers you enter user name and password in CloudDrives; they go only to your server. Everything is stored
  only on your PC, encrypted with a key kept in the Windows Credential Manager (or with your master password, if you set
  one up).
- **Revocation:** You can revoke access at any time:
  - Google: [myaccount.google.com/permissions](https://myaccount.google.com/permissions)
  - Microsoft: [account.live.com/consent/Manage](https://account.live.com/consent/Manage)
  - Nextcloud: in Nextcloud under *Settings › Security*
- **Local files:** Settings, logs and cache live in `%LOCALAPPDATA%\CloudDrives` and are removed when you uninstall.

CloudDrives' use of information received from Google APIs adheres to the
[Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy),
including the Limited Use requirements.
