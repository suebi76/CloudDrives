# Changelog

All notable changes to CloudDrives are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/de/1.1.0/), versions follow [Semantic Versioning](https://semver.org/lang/de/).

## [0.2.0] – unreleased

### Added

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
