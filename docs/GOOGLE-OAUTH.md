# Eigene Google-Client-ID einrichten

CloudDrives kann Google Drive sofort mit der **Standard-Client-ID von rclone** verbinden. Diese Kennung teilen sich
allerdings alle rclone-Nutzer weltweit, deshalb bremst Google sie regelmäßig: Ordner laden langsam, und es erscheinen Meldungen wie
*„User Rate Limit Exceeded“* (Fehler **CD-3002**). Mit einer **eigenen Client-ID** hast du ein eigenes Kontingent.
Die Einrichtung dauert einmalig etwa 10 Minuten und ist kostenlos.

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
2. **Google Drive** bzw. **Google Workspace** wählen, danach **Eigene Client-ID**.
3. Client-ID einfügen und das Client-Geheimnis eingeben. Die Eingabe bleibt unsichtbar.
4. Im Browser anmelden. Bei einer externen App zeigt Google einmalig **„Google hat diese App nicht überprüft“**.
   Klicke **Erweitert → Zu CloudDrives wechseln**. Das ist unbedenklich, weil es deine eigene App ist.

Ein bestehendes Konto stellst du um, indem du es entfernst und mit eigener Client-ID neu hinzufügst.
Deine Dateien in der Cloud bleiben dabei unverändert.

## Häufige Fragen

- **Kostet das etwas?** Nein. Die Drive API ist für diese Nutzung kostenlos.
- **Kann ich eine Client-ID für mehrere Konten verwenden?** Ja. Eine externe, veröffentlichte App funktioniert für dein
  privates Konto und für Workspace-Konten. Bei Workspace muss sie dort zusätzlich als vertrauenswürdig markiert sein (Schritt 4).
- **Wie widerrufe ich den Zugriff?** Unter [myaccount.google.com/permissions](https://myaccount.google.com/permissions).
