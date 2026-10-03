@echo off
rem CloudDrives - mounts OneDrive and Google Drive accounts as Windows drive letters.
rem Without arguments the interactive menu opens. "CloudDrives.bat help" lists all commands.
setlocal
rem Started from PowerShell 7, the inherited PSModulePath would make Windows PowerShell load
rem incompatible core modules. Clearing it restores the defaults for this process only.
set "PSModulePath="
set "CD_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%CD_PS%" set "CD_PS=powershell.exe"
"%CD_PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\CloudDrives.ps1" %*
set "CD_EXIT=%ERRORLEVEL%"
if "%CD_EXIT%"=="4" pause
endlocal & exit /b %CD_EXIT%
