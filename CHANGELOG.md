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
