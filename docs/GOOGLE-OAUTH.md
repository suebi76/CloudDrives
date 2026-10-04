# Eigene Google-Client-ID einrichten

Für Google Drive brauchst du eine **eigene Client-ID**.

- **Die gemeinsame Client-ID von rclone wird abgeschaltet.** rclone stellt sie laut eigener Dokumentation im Laufe von 2026
  ein. Eine eigene Client-ID ist deshalb *„required rather than merely recommended“*.
- **Die gemeinsame Kennung ist gedrosselt.** Alle rclone-Nutzer weltweit teilen sie, deshalb bremst Google sie stark:
  - Ordner laden langsam.
  - Speicherabfragen dauern 30 Sekunden und länger.
  - Es erscheinen Meldungen wie *„User Rate Limit Exceeded“* (Fehler **CD-3002**).
- **Mit einer eigenen Client-ID** hast du ein eigenes Kontingent. Die Einrichtung dauert einmalig etwa 10 Minuten und ist kostenlos.

> **Sicherheit:** Client-ID und Client-Geheimnis landen ausschließlich in der verschlüsselten `rclone.conf`
> unter `%LOCALAPPDATA%\CloudDrives`. Trage sie niemals in Dateien des Repositorys ein.

## 1. Projekt anlegen und Drive API aktivieren

1. Öffne die [Google Cloud Console](https://console.cloud.google.com/) und melde dich an.
   Melde dich mit dem Workspace-Konto an, wenn die App nur für Workspace gedacht ist, sonst mit dem privaten Konto.
2. Lege oben über die Projektauswahl ein **neues Projekt** an, z. B. `CloudDrives`.
3. Öffne **APIs & Dienste → Bibliothek**, suche **Google Drive API** und klicke **Aktivieren**.

## 2. Zustimmungsbildschirm (Google Auth Platform)

1. Öffne **Google Auth Platform** (früher „OAuth-Zustimmungsbildschirm“) und klicke **Jetzt starten**.
2. **Branding:** App-Name `CloudDrives`, deine E-Mail als Support- und Entwickler-Kontakt.
3. **Zielgruppe:**
   - **Extern** – für private Google-Konten. Diese Variante funktioniert auch für Workspace-Konten.
   - **Intern** – nur Konten deiner Workspace-Organisation. Dann gibt es weder Warnhinweis noch Veröffentlichung.
     Dein privates Konto kann diese App aber nicht nutzen.
4. **Datenzugriff → Bereiche hinzufügen:** `https://www.googleapis.com/auth/drive`
5. **Nur bei „Extern“:** Klicke unter **Zielgruppe** auf **App veröffentlichen** („In Produktion“).
   Im Status „Test“ laufen Anmeldungen nach **7 Tagen** ab. Eine Überprüfung (Verifizierung) durch Google ist für die eigene
   Nutzung nicht nötig.

## 3. Client-ID erstellen

1. **Google Auth Platform → Clients → Client erstellen**
2. Anwendungstyp: **Desktop-App**, Name z. B. `CloudDrives`
3. Notiere **Client-ID** (`…apps.googleusercontent.com`) und **Clientschlüssel** (Client-Geheimnis).

## 4. Nur Google Workspace: App als vertrauenswürdig markieren

Als Superadmin in der [Admin-Konsole](https://admin.google.com/):

1. **Sicherheit → Zugriffs- und Datenverwaltung → API-Steuerung**
2. **Zugriff von Drittanbieter-Apps verwalten → App konfigurieren → OAuth-App-Name oder Client-ID**
3. Client-ID eintragen, App auswählen, Zugriff **Vertrauenswürdig** setzen.

Ohne diesen Schritt kann die Anmeldung mit **Fehler 400: admin_policy_enforced** scheitern (CloudDrives-Code **CD-3003**).

## 5. In CloudDrives verwenden

1. `CloudDrives.bat` starten und **Konto hinzufügen** wählen.
2. **Google Drive** bzw. **Google Workspace** wählen, danach **Eigene Client-ID** (Voreinstellung).
3. Client-ID einfügen und das Client-Geheimnis eingeben. Die Eingabe bleibt unsichtbar.
4. Im Browser anmelden. Bei einer externen App zeigt Google einmalig **„Google hat diese App nicht überprüft“**.
   Klicke **Erweitert → Zu CloudDrives wechseln**. Das ist unbedenklich, weil es deine eigene App ist.

**Ein bestehendes Konto umstellen:** Menü → **Konten verwalten → Google-Client-ID ändern** (oder
`CloudDrives.bat client-id <Konto>`).

- CloudDrives übernimmt den Client eines anderen Kontos, liest die heruntergeladene Client-Datei oder fragt nach ID und Geheimnis.
- Danach meldest du dich im Browser neu an.
- Laufwerke, Tresore und Einstellungen bleiben erhalten.
- Die bisherige Anmeldung wird erst ersetzt, wenn die neue funktioniert und zum selben Google-Konto gehört.

So tauschst du auch ein neues Client-Geheimnis ein: gleiche ID, neues Geheimnis.

## Häufige Fragen

- **Kostet das etwas?** Nein. Die Drive API ist für diese Nutzung kostenlos.
- **Kann ich eine Client-ID für mehrere Konten verwenden?** Ja. Eine externe, veröffentlichte App funktioniert für dein
  privates Konto und für Workspace-Konten. Bei Workspace muss sie dort zusätzlich als vertrauenswürdig markiert sein (Schritt 4).
- **Wie widerrufe ich den Zugriff?** Unter [myaccount.google.com/permissions](https://myaccount.google.com/permissions).
  Danach meldest du das Konto in CloudDrives unter **Konten verwalten → Neu anmelden** wieder an.
