# Developer handbook

*Deutsche Fassung: [DEVELOPMENT.md](DEVELOPMENT.md)*

How to set up, check and publish CloudDrives. How it is built is described in [ARCHITECTURE.en.md](ARCHITECTURE.en.md),
the rules for new code in [CONTRIBUTING.en.md](../CONTRIBUTING.en.md).

## Prerequisites

- Windows 10 or 11 with **Windows PowerShell 5.1** (preinstalled) and **PowerShell 7** - the code must run in both
- Git
- For the integration tests: [WinFsp](https://winfsp.dev) (CloudDrives installs it at its first start; one UAC prompt)
- You do not need to install rclone: CloudDrives fetches the pinned version 1.75.1 itself and checks its checksum.

A script installs the tools for tests and lint into a private folder (`%LOCALAPPDATA%\CloudDrives-dev\Modules`,
changeable with `CLOUDDRIVES_DEVTOOLS`) - nothing is installed system-wide:

```powershell
.\tools\Install-DevTools.ps1      # Pester 5.7.1 and PSScriptAnalyzer 1.25.0
```

## Running

```powershell
.\CloudDrives.bat                                   # menu
.\CloudDrives.bat help                              # all commands
.\CloudDrives.bat status --home="$env:TEMP\cd-test" # with a data folder of its own
```

From the repository the **development copy** runs. It offers to install itself into
`%LOCALAPPDATA%\Programs\CloudDrives`; updates exist only for the installed copy.

**Test data of your own:** `--home=<folder>` or `CLOUDDRIVES_HOME` chooses another data folder. It gets entries of its
own in the Windows Credential Manager, locks of its own and scheduled tasks of its own; the real set-up stays untouched.

More environment variables for development and tests:

| Variable | Effect |
|---|---|
| `CLOUDDRIVES_INSTALL_DIR`, `CLOUDDRIVES_SHORTCUT_DIR` | Install into a sandbox folder, shortcuts as well |
| `CLOUDDRIVES_RELEASE_SOURCE` | Install and update from a locally built package instead of GitHub |
| `CLOUDDRIVES_SECRET_BACKEND=dpapi` | Secrets in a DPAPI file instead of the Credential Manager |
| `CLOUDDRIVES_DEBUG=1` | Log everything, including level DEBUG |

## Checking

```powershell
.\tools\Format-SourceFiles.ps1                        # put encodings and line ends right
.\tools\Invoke-Build.ps1 -Edition Both                # lint and unit tests in PowerShell 5.1 and 7 (like the CI)
.\tools\Invoke-Build.ps1 -Edition Both -Integration   # also real engine, drives and scheduled tasks
```

The quality gate (`Invoke-Build.ps1`) checks:

1. **Source files:** `.ps1`/`.psm1`/`.psd1` UTF-8 with BOM, `.cs`/`.json`/`.md` UTF-8 without BOM, `.bat` and `install.ps1`
   ASCII only, Windows line ends, a line break at the end of every file (`Format-SourceFiles.ps1 -Check`).
2. **PSScriptAnalyzer** with the rules in `PSScriptAnalyzerSettings.psd1`.
3. **Pester** in the chosen PowerShell edition; `-Edition Both` runs both.

- **Unit tests** (`tests/Unit`) run without network, engine or drives. `tests/TestHelper.ps1` creates a data folder of
  its own in the temp folder for every file (`New-CdTestHome`); tests reach the functions with `InModuleScope CloudDrives`
  and replace system access with `Mock`.
- **Integration tests** (`tests/Integration`) start real rclone, mount drives through WinFsp and create scheduled tasks -
  always with a data folder and sandbox folders of their own, never for the real set-up.
- On GitHub every push and pull request runs lint, unit tests in 5.1 and 7 and a secret scan
  (`.github/workflows/ci.yml`).

## Packages and publishing

**Build locally:**

```powershell
.\tools\Build-Release.ps1 -LocalSource     # ZIP, install.ps1, SHA256SUMS.txt and release.json in .\out
$env:CLOUDDRIVES_RELEASE_SOURCE = "$PWD\out"
```

The ZIP holds only what users need (`src/Resources/app.json`, `packageItems`), never tests or tools.

**Publish:**

1. The version in `src/CloudDrives.psd1` (`ModuleVersion`) and a section `## [X.Y.Z] – <date>` in `CHANGELOG.md`.
2. Commit, pull request, merge.
3. Put the tag `vX.Y.Z` on the merge commit and push it. The workflow `.github/workflows/release.yml` checks that tag
   and version match, runs the quality gate, builds the ZIP, `install.ps1` and checksums, and publishes the release with
   the section from the changelog.

**Test versions:** additionally `Prerelease = 'preview.1'` under `PrivateData.PSData` in the manifest, a section
`## [X.Y.Z-preview.1]` in the changelog, the tag `vX.Y.Z-preview.1`. The workflow publishes it as a pre-release; only
installations with "Testversionen erhalten" (receive test versions) get it, `install.ps1` stays with the newest regular
version.

## Troubleshooting

- Logs: `%LOCALAPPDATA%\CloudDrives\logs\` - CloudDrives (redacted) and `rclone.log`.
- `CloudDrives.bat doctor` checks everything with a traffic light, `--fix` repairs, `--bundle` packs a redacted support
  bundle.
- `CLOUDDRIVES_DEBUG=1` writes details to the log, too.

## Where to start

1. Read [ARCHITECTURE.en.md](ARCHITECTURE.en.md).
2. `src/CloudDrives.psm1` - the order in which the module loads its files.
3. `src/UI/Cli.ps1` (`Invoke-CdCli`) - what happens on every call.
4. `src/Commands/Connection.ps1` and `src/Services/Drives.ps1` - from the command to the drive.
5. `src/Infrastructure/Engine.ps1` - how the engine starts and how to talk to it.

## Common changes

- **A new text:** a key in `src/Resources/lang/de.json` **and** `en.json`, in the code `Get-CdText '<key>'`. A test makes
  sure both files have the same keys.
- **A new error code:** an entry in `src/Resources/errors.json` (recognition patterns, optionally an automatic action),
  title and fix as `error.<code>.title`/`.fix` in both language files, then `.\tools\New-TroubleshootingDoc.ps1` - a test
  makes sure `docs/TROUBLESHOOTING.md` matches.
- **A new setting:** a default in `New-CdDefaultSettings` (older files get it when loaded), a check in `Test-CdSettings`
  where needed, then its entry in the settings menu (`src/UI/SettingsMenu.ps1`).
- **A new provider:** a file in `src/Providers` with `Register-CdProvider` (rclone type, kinds, answers to rclone's set-up
  questions), texts in both language files, tests.
- **A new command:** an alias in `$script:CdCommandAliases`, a branch in `Invoke-CdCli`, a description in `help.text` of
  both language files.
