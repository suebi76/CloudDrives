# Contributing

*Deutsche Fassung: [CONTRIBUTING.md](CONTRIBUTING.md)*

Thank you for your interest in CloudDrives!

- **Bugs and wishes:** open an [issue](https://github.com/suebi76/CloudDrives/issues). For bugs, please attach a support
  bundle (menu → *Diagnose & Hilfe*).
- **Security vulnerabilities:** please report them confidentially, see [SECURITY.md](SECURITY.md).

How to set up, check and publish the project is in the [developer handbook](docs/DEVELOPMENT.en.md), how it is built in
[docs/ARCHITECTURE.en.md](docs/ARCHITECTURE.en.md). In short:

```powershell
.\tools\Install-DevTools.ps1                          # Pester and PSScriptAnalyzer into a private folder
.\tools\Format-SourceFiles.ps1                        # normalise encodings and line ends
.\tools\Invoke-Build.ps1 -Edition Both                # lint and unit tests in PowerShell 5.1 and 7 (like the CI)
.\tools\Invoke-Build.ps1 -Edition Both -Integration   # also real engine, drives and scheduled tasks
```

## Rules for the code

The goal: whoever reads the code for the first time - the author, a school's IT staff or a developer from another
country - understands it without prior knowledge. The rules apply to new and changed code.

### Structure

- **Layers:** `src/Infrastructure` → `src/Providers` → `src/Services` → `src/Commands` → `src/UI`. Dependencies only point
  down. The module loads new files by itself (per folder, alphabetically).
- **Output:** services return result objects (`New-CdResult`) and write nothing to the screen. Only `src/UI` talks to the
  user.
- **One file, one topic**, and the file name says which (`Watchdog.ps1`, `AccountSignIn.ps1`). From about 400 lines on,
  split by topic. Justified exception: `src/Resources/Native.cs` stays one file, because Windows PowerShell compiles it at
  every start.

### Names

- Functions are named *Verb-Noun* with an approved PowerShell verb (`Get-Verb`) and the prefix `Cd`: `Get-CdDrive`,
  `Invoke-CdConnect`. Parameters and variables are English, written out and telling.
- Module state lives in `$script:Cd…` variables at the top of the file that manages it.
- Use the terms the code already uses, consistently: *drive*, *account*, *vault*, *engine* (the rclone process),
  *watchdog*, *symbol* (in the notification area), *wanted drives* (those that should be connected).

### Comments

- **English**, in full sentences, for readers without prior knowledge.
- **Every file** starts with a comment that names its job.
- **Functions** whose name does not say everything start with a comment: what they do, what they return, what is
  special.
- Comments explain the **why** - a quirk of rclone, WinFsp or Windows, a decision, a danger - not the what the code shows
  anyway.
- Knowledge about rclone, WinFsp and Windows also belongs in [docs/ARCHITECTURE.en.md](docs/ARCHITECTURE.en.md).
- No commented-out code, no `TODO` without an issue.

### User interface texts

- Texts come only through `Get-CdText` and are in **both** language files (`src/Resources/lang`).
- German: friendly, without jargon, the user is addressed informally ("du"). Messages say what happened and what helps.

### Errors

- Errors are exceptions with a code `CD-xxxx` (`New-CdException`).
- Every code is in `src/Resources/errors.json` and has a title and a fix in German and English. After changing them, run
  `.\tools\New-TroubleshootingDoc.ps1`.
- An exception is never swallowed silently: either a comment says why that is fine, or it is logged.

### Compatibility

- The code must run in **Windows PowerShell 5.1**: no `? :`, `??` or `&&` in scripts, go through JSON lists with
  `foreach` (5.1 hands them over as one object), `.ps1` files with a BOM.
- `CloudDrives.bat` and `install.ps1` contain ASCII only.

### Security and data

- **Secrets** (tokens, passwords, keys) only in the encrypted `rclone.conf` and the secret store - never in
  `settings.json`, logs, tests or this repository.
- **No real data:** never commit real sign-ins, tokens or personal data, not even in tests.
- **What the user sets stays:** e.g. names the user gives a drive in Explorer are adopted, never overwritten.

### Tests

- Every change needs tests. Anything close to the system (engine, drives, scheduled tasks) also gets integration tests.
- Test names describe the behaviour as a sentence (`It 'installs automatically, but only when no CloudDrives window is open'`).

### Form

- Encodings and line ends: `.\tools\Format-SourceFiles.ps1`.
- PSScriptAnalyzer reports nothing (`PSScriptAnalyzerSettings.psd1`).

## Pull requests

- Work on a branch of your own with meaningful commits (in English) and add an entry to `CHANGELOG.md`.
- The CI must be green: lint, unit tests in PowerShell 5.1 and 7, and gitleaks.

## Releases

Set the version in `src/CloudDrives.psd1` and `CHANGELOG.md`, push the tag `vX.Y.Z` - the release workflow does the rest.
Test versions (`vX.Y.Z-preview.1`) and all details: [developer handbook](docs/DEVELOPMENT.en.md#packages-and-publishing).
