# CloudDrives.bat must allow an update to replace the program folder while CloudDrives runs: it leaves the
# folder (Windows locks a process's working directory), never re-reads itself after starting PowerShell and
# passes the exit code on. A stand-in for src\CloudDrives.ps1 keeps the launcher running during the test.

BeforeAll {
    . (Join-Path $PSScriptRoot '..\TestHelper.ps1')
    $script:TestHome = New-CdTestHome

    function Invoke-CdWithRetry {
        # Virus scanners may briefly hold freshly written files.
        param([scriptblock]$Action)
        for ($attempt = 1; ; $attempt++) {
            try { & $Action; return }
            catch { if ($attempt -ge 10) { throw }; Start-Sleep -Milliseconds 200 }
        }
    }
}

AfterAll {
    Remove-CdTestHome -Path $script:TestHome
}

Describe 'CloudDrives.bat' {
    It 'leaves its folder, survives being replaced while running and passes the exit code on' {
        $root = Join-Path $script:TestHome 'launcher test'
        $app = Join-Path $root 'app'
        [void](New-Item -ItemType Directory -Path (Join-Path $app 'src') -Force)
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'CloudDrives.bat') -Destination $app
        $cwdFile = Join-Path $root 'cwd.txt'
        $goFile = Join-Path $root 'go.txt'
        $stub = @(
            "[IO.File]::WriteAllText('$cwdFile', [Environment]::CurrentDirectory + '|' + (`$args -join ','))"
            '$deadline = [DateTime]::UtcNow.AddSeconds(30)'
            "while (-not (Test-Path -LiteralPath '$goFile') -and [DateTime]::UtcNow -lt `$deadline) { Start-Sleep -Milliseconds 100 }"
            'exit 3'
        )
        Set-Content -LiteralPath (Join-Path $app 'src\CloudDrives.ps1') -Value $stub -Encoding ASCII

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = Join-Path $env:WINDIR 'System32\cmd.exe'
        $psi.Arguments = '/d /c ""{0}" status --json"' -f (Join-Path $app 'CloudDrives.bat')
        $psi.WorkingDirectory = $app
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $process = [Diagnostics.Process]::Start($psi)
        try {
            $deadline = [DateTime]::UtcNow.AddSeconds(30)
            while (-not (Test-Path -LiteralPath $cwdFile) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
            $cwd, $arguments = ([IO.File]::ReadAllText($cwdFile)).Split('|')
            $cwd.TrimEnd('\') | Should -Not -BeLike "$app*"
            $arguments | Should -Be 'status,--json'

            # Replace the program folder like an update does; a re-read of the new launcher would print the marker.
            Invoke-CdWithRetry { Rename-Item -LiteralPath $app -NewName 'app.old' }
            [void](New-Item -ItemType Directory -Path $app)
            Set-Content -LiteralPath (Join-Path $app 'CloudDrives.bat') -Value (@('@echo off') + @('echo REREAD-MARKER') * 200) -Encoding ASCII
            [void](New-Item -ItemType File -Path $goFile)

            $process.WaitForExit(30000) | Should -BeTrue
            $output = $process.StandardOutput.ReadToEnd() + $process.StandardError.ReadToEnd()
            $output | Should -Not -Match 'MARKER|ARKER'
            $process.ExitCode | Should -Be 3
        }
        finally {
            if (-not $process.HasExited) { $process.Kill() }
        }
    }
}
