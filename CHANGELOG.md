# Changelog

All notable changes to CloudDrives are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/de/1.1.0/), versions follow [Semantic Versioning](https://semver.org/lang/de/).

## [0.3.2] – 2026-10-05

### Changed

- "CloudDrive-Sync öffnen" also finds CloudDrive-Sync when it was installed with its new setup program: the place it
  records in Windows ("App Paths") comes first, then its usual folders

## [0.3.1] – 2026-10-05

### Added

- The symbol in the notification area opens CloudDrive-Sync - the new, separate program that keeps folders on
  this PC in step with Nextcloud, IServ and other WebDAV servers - when it is installed ("CloudDrive-Sync öffnen")

### Changed

- Test data uses neutral example names and addresses

## [0.3.0] – 2026-10-04

### Added

- Nextcloud, IServ and other WebDAV servers as drives ("Konto hinzufügen" [4]–[6])
  - rclone connects by itself: no Windows WebDAV client, no registry patches, no Office warnings about basic
    authentication
  - Nextcloud: sign-in in the browser (Login Flow v2, also with two-factor authentication); Nextcloud creates an app
    password of its own for CloudDrives, revocable under Settings > Security. Where the operator blocks this sign-in for
    programs, CloudDrives asks for an app password and explains where to create it. A normal password typed there is
    exchanged for an app password where Nextcloud allows it. The WebDAV address from the Nextcloud file settings is
    taken over as it is
  - IServ: the school's address becomes `webdav.<address>`; user name and IServ password
  - other servers: the WebDAV address, user name and password
  - passwords are typed hidden and stored only in the encrypted rclone configuration; only https addresses are
    accepted (http only on this computer)
  - signing in again asks only for the new password; removing the account deletes it from this PC (for Nextcloud with
    the link to revoke the app password)
  - new codes: CD-3012 (user name or password refused, offers to sign in again), CD-3013 (WebDAV address not found),
    CD-3014 (Nextcloud sign-in not possible)

## [0.2.5] – 2026-10-04

### Changed

- The status line also accompanies the other longer actions:
  - "Alle verbinden" and connecting new drives: starting the engine, each drive ("Verbinde OneDrive (M:) …"),
    and waiting for the internet connection when there is none yet
  - disconnecting: each drive, and waiting for pending uploads
  - the update: looking for updates, downloading, checking the package, installing
  - the diagnosis: the area being checked, each automatic fix, creating the support bundle
- The status line redraws itself four times a second (a small native helper), so the bar turns and the time runs
  also while CloudDrives waits for a slow answer, for example while a drive is being connected. Any other output
  and every question remove it first, so it never writes into an input.

## [0.2.4] – 2026-10-04

### Changed

- Signing in shows what CloudDrives is doing. A status line with a turning bar and the seconds so far replaces the
  fixed "Warte auf die Anmeldung im Browser …", so it is visible at any moment that CloudDrives is still working:
  - waiting for the sign-in in the browser
  - "Anmeldung erhalten – CloudDrives richtet das Konto ein …" as soon as the browser has delivered the sign-in,
    with the attempt when rclone has to try again
  - reading the storage space, checking which account signed in, reconnecting or connecting the drives

### Fixed

- OneDrive: the sign-in takes the user's own drive right away. For some OneDrive Personal accounts Microsoft also
  lists stale drives ("ObjectHandle is Invalid"), and rclone offered those first; each cost about ten seconds
  before the next drive was tried. CloudDrives now asks Microsoft Graph for the user's drive (`/me/drive`) and
  answers with it.

## [0.2.3] – 2026-10-04

### Fixed

- Adding a OneDrive account no longer hangs after the browser sign-in at "Warte auf die Anmeldung im Browser …".
  After the sign-in, rclone asks which drive to use. CloudDrives now answers rclone's questions itself, step by step
  (OneDrive Personal or Business, the user's own drive, confirmed). Before, rclone answered them with its defaults
  and, when a step failed, started over again and again without a message.
  - when the check of a drive fails, the next drive offered is tried
  - otherwise the sign-in ends with rclone's error message instead of waiting, for example for the "Database Is Read
    Only" error some OneDrive Personal accounts currently get (new code CD-3011)
  - signing a OneDrive account in again is fixed the same way; Google accounts answer rclone's questions the same way

## [0.2.2] – 2026-10-04

### Fixed

- `status --json` and `diagnose --json` escape characters outside ASCII (`\u00fc`). Scripts in Windows PowerShell 5.1
  read umlauts in drive names and messages intact instead of garbled by the console code page.

## [0.2.1] – 2026-10-04

### Fixed

- Drives renamed in Explorer keep their names. Explorer stores such a name where CloudDrives sets the drive name,
  and CloudDrives used to overwrite it when connecting, installing or updating. Now it adopts the name: when
  connecting, installing or updating, when the menu opens and every 5 minutes through the watchdog. The diagnosis
  shows such a rename as information instead of offering to undo it.

## [0.2.0] – 2026-10-04

### Added

- GitHub: CI (lint and unit tests in Windows PowerShell 5.1 and PowerShell 7, gitleaks secret scan), release
  workflow (tag → ZIP, `install.ps1`, `SHA256SUMS.txt`, notes from this changelog), Dependabot for actions
- `SECURITY.md`, `CONTRIBUTING.md`, bug report template, and `docs/TROUBLESHOOTING.md` with every error code
  (generated from the error catalog; a test keeps it up to date)
- Installation into `%LOCALAPPDATA%\Programs\CloudDrives`
  - no administrator rights needed
  - Start menu and optional desktop shortcut
  - own icon, also for the drives in Explorer
- Web installer: `irm …/install.ps1 | iex` with SHA256-verified release package
- `update` with checksum verification and rollback
  - works while CloudDrives runs: `CloudDrives.bat` leaves the program folder and never re-reads itself
  - afterwards CloudDrives restarts from the program folder (also after the first installation)
- Daily update hint after the autostart
- `uninstall`, optionally including all local sign-ins and settings
- Symbol in the notification area (lean on purpose; a full program is planned as a separate v2)
  - status dot: green = connected, yellow = reconnecting, red = needs the user, grey = nothing connected;
    the tooltip names the drives or the problem
  - menu: open a drive, sign an account in again, connect all, disconnect all, open CloudDrives, diagnosis, hide
  - actions run as separate CloudDrives processes, so the symbol never blocks; status every 10 seconds
  - shown at every sign-in (scheduled task, turned on with the autostart), own switch in the settings,
    `tray [on|off|status]`; one symbol per user; replaced by the new version after an update
  - the diagnosis checks it and can show it again
- Watchdog: reconnects the drives after standby, a network change or a crash of the engine
  - a scheduled task runs a short check every 5 minutes, after waking up and after a network connection
  - restarts an engine that is gone or no longer responds (a busy engine gets a second chance)
  - only reconnects drives the user or the autostart connected since the last Windows start; drives the user
    disconnected stay disconnected
  - persistent problems are retried after 0, 15, 60 and then 360 minutes and reported once
  - turned on together with the autostart; own switch in the settings and `watchdog [on|off|status]`
  - connecting, disconnecting and the watchdog never run at the same time
- Diagnosis ("Diagnose & Hilfe", `doctor|diagnose [--fix] [--bundle] [--json]`)
  - traffic-light checks of system, components, settings, network, updates, engine, accounts, drives, recent
    errors and autostart, with the explanation of each error code
  - "fix automatically": install rclone/WinFsp, restart the engine, connect drives, set Explorer names, repair
    the autostart, protect the data folder, renew sign-ins
  - knows typical cases such as the 15 GB per-user limit of Google Workspace or a Windows proxy rclone cannot see
  - rclone log noise (CloudDrives' own probing requests, cancelled requests, symbolic link queries) is ignored
- Support bundle (ZIP) with diagnosis, versions, settings and the logs of the last 7 days
  - secrets, e-mail addresses, user and computer name and profile paths are redacted
  - before saving, it is searched for every secret CloudDrives knows; a hit discards it (CD-9003)
- "Manage accounts": sign an account in again or change its Google client ID without removing it
  - the browser sign-in runs on a temporary remote; the account changes only when the new sign-in works
  - it must belong to the same cloud account (Google user ID, OneDrive drive ID), otherwise nothing changes (CD-3009)
  - mounted drives of the account reconnect with the new sign-in
  - offered right away when connecting fails because a sign-in expired; notifications say where to renew it
  - command line: `relogin|neu-anmelden [<account>]`, `change-client|client-id [<account>]`
- Accounts remember who is signed in (also learned for existing accounts while connecting); the same cloud
  account cannot be added twice (CD-3010)
- Autostart at Windows sign-in, with notifications when something goes wrong
- Settings menu
- Rename drives
- Encrypted vaults (rclone crypt): per account, a normal drive, a vault or both
  - recovery kit
  - wrong-password protection
- Own Google client ID as the default
  - reuse across accounts
  - import of the downloaded client file

### Changed

- Quotas in the menu use a short timeout so a slow provider never blocks the menu.

## [0.1.0] – 2026-10-03

### Added

- First version: engine (`rclone rcd`), OneDrive and Google Drive accounts, drives as network drives, encrypted
  configuration, console menu and wizards, error catalog, tests.
