@echo off
rem CloudDrives - mounts OneDrive and Google Drive accounts as Windows drive letters.
rem Without arguments the interactive menu opens. "CloudDrives.bat help" lists all commands.
setlocal
rem In Windows Terminal the taskbar would show the terminal's symbol: the menu opens in a console window of its own,
rem which shows the CloudDrives symbol.
if "%~1"=="" if defined WT_SESSION (set "WT_SESSION=" & start "" "%SystemRoot%\System32\conhost.exe" "%~f0" --window & exit /b 0)
set "CD_ROOT=%~dp0"
rem Started from PowerShell 7, the inherited PSModulePath would make Windows PowerShell load
rem incompatible core modules. Clearing it restores the defaults for this process only.
set "PSModulePath="
set "CD_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%CD_PS%" set "CD_PS=powershell.exe"
rem An update replaces the program folder while CloudDrives runs. Windows locks the working directory of
rem a process, so leave the folder first. Everything else is one line: cmd.exe re-reads a batch file after
rem each command, and by then this file may have been replaced. Exit code 4 (CloudDrives could not be
rem loaded) keeps the window open so that the message stays readable.
cd /d "%USERPROFILE%" 2>nul
"%CD_PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%CD_ROOT%src\CloudDrives.ps1" %* & (if errorlevel 4 if not errorlevel 5 pause) & endlocal & call exit /b %%ERRORLEVEL%%
