BeforeAll {
    . (Join-Path $PSScriptRoot '..\TestHelper.ps1')
}

Describe 'Source files' {
    It 'are normalised (encoding, BOM, line endings)' {
        $output = & (Join-Path $script:RepoRoot 'tools\Format-SourceFiles.ps1') -Check *>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
    }

    It 'parse without syntax errors' {
        $scripts = Get-ChildItem -LiteralPath $script:RepoRoot -Recurse -File |
            Where-Object { @('.ps1', '.psm1', '.psd1') -contains $_.Extension -and $_.FullName -notmatch '\\(\.git|\.claude)\\' }
        foreach ($file in $scripts) {
            $tokens = $null
            $parseErrors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
            @($parseErrors) | Should -BeNullOrEmpty -Because $file.FullName
        }
    }

    It 'the module manifest is valid' {
        $manifest = Test-ModuleManifest -Path (Join-Path $script:SrcRoot 'CloudDrives.psd1')
        $manifest.Version | Should -Not -BeNullOrEmpty
        $manifest.ExportedFunctions.Keys | Should -Contain 'Invoke-CdCli'
    }
}

Describe 'Repository hygiene' {
    BeforeAll {
        # Everything git would commit: tracked files plus new files that are not ignored.
        $list = & git -C $script:RepoRoot -c core.quotepath=off ls-files --cached --others --exclude-standard 2>$null
        if ($LASTEXITCODE -eq 0 -and $list) {
            $script:Files = @($list | ForEach-Object { Get-Item -LiteralPath (Join-Path $script:RepoRoot $_) -Force -ErrorAction SilentlyContinue } | Where-Object { $_ })
        }
        else {
            $script:Files = Get-ChildItem -LiteralPath $script:RepoRoot -Recurse -File -Force |
                Where-Object { $_.FullName -notmatch '\\(\.git|\.claude|\.vscode|TestResults)\\' }
        }
    }

    It 'contains no runtime data or secrets files' {
        $forbidden = @($script:Files | Where-Object { $_.Name -match '(?i)^(rclone\.conf|settings\.json)$|\.(dpapi|conf|log|token|secret|pfx|pem|key)$' })
        $forbidden.FullName | Should -BeNullOrEmpty
    }

    It 'contains no token-like strings' {
        $patterns = @(
            'ya29\.[0-9A-Za-z\-_]{20,}',
            '\b1//0[0-9A-Za-z\-_]{30,}',
            'RCLONE_ENCRYPT_V0:\s*\r?\n[A-Za-z0-9+/=]{40,}',
            '"refresh_token"\s*:\s*"[^"*]{10,}"',
            'GOCSPX-[0-9A-Za-z\-_]{20,}'
        )
        foreach ($file in $script:Files) {
            if ($file.Length -gt 2MB -or $file.Extension -in @('.ico', '.png', '.exe', '.dll', '.zip')) { continue }
            $text = [IO.File]::ReadAllText($file.FullName)
            foreach ($pattern in $patterns) {
                $text -match $pattern | Should -BeFalse -Because "$($file.FullName) must not contain secrets ($pattern)"
            }
        }
    }

    It 'uses an allowlist .gitignore that blocks configuration files' {
        $gitignore = [IO.File]::ReadAllText((Join-Path $script:RepoRoot '.gitignore'))
        $gitignore | Should -Match '(?m)^/\*\s*$'
        $gitignore | Should -Match '(?m)^\*\.conf\s*$'
        $gitignore | Should -Match '(?m)^settings\.json\s*$'
    }
}
