BeforeAll {
    . (Join-Path $PSScriptRoot '..\TestHelper.ps1')
    function Read-JsonFile([string]$Path) { [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json }
    $script:Lang = @{}
    foreach ($language in @('de', 'en')) {
        $table = @{}
        foreach ($p in (Read-JsonFile (Join-Path $script:SrcRoot "Resources\lang\$language.json")).PSObject.Properties) { $table[$p.Name] = $p.Value }
        $script:Lang[$language] = $table
    }
    $script:Errors = @((Read-JsonFile (Join-Path $script:SrcRoot 'Resources\errors.json')).errors)
    $script:Deps = Read-JsonFile (Join-Path $script:SrcRoot 'Resources\dependencies.json')
}

Describe 'Language files' {
    It 'German and English define exactly the same keys' {
        $de = @($script:Lang['de'].Keys | Sort-Object)
        $en = @($script:Lang['en'].Keys | Sort-Object)
        @(Compare-Object $de $en) | Should -BeNullOrEmpty
    }

    It 'every error code has a title and a fix in both languages' {
        foreach ($entry in $script:Errors) {
            foreach ($language in @('de', 'en')) {
                $script:Lang[$language]["error.$($entry.code).title"] | Should -Not -BeNullOrEmpty -Because "$($entry.code) ($language)"
                $script:Lang[$language]["error.$($entry.code).fix"] | Should -Not -BeNullOrEmpty -Because "$($entry.code) ($language)"
            }
        }
    }

    It 'every literal text key used in the source exists' {
        $keys = foreach ($file in Get-ChildItem -LiteralPath $script:SrcRoot -Recurse -Filter '*.ps1') {
            foreach ($match in [regex]::Matches([IO.File]::ReadAllText($file.FullName), "Get-CdText\s+(?:-Key\s+)?'([a-zA-Z0-9\.\-]+)'")) { $match.Groups[1].Value }
        }
        foreach ($key in ($keys | Sort-Object -Unique)) {
            $script:Lang['en'].ContainsKey($key) | Should -BeTrue -Because "key '$key' is used in the source"
        }
    }

    It 'placeholders match between the languages' {
        foreach ($key in $script:Lang['en'].Keys) {
            $enPlaceholders = @([regex]::Matches([string]$script:Lang['en'][$key], '\{\d\}') | ForEach-Object Value | Sort-Object -Unique)
            $dePlaceholders = @([regex]::Matches([string]$script:Lang['de'][$key], '\{\d\}') | ForEach-Object Value | Sort-Object -Unique)
            ($dePlaceholders -join ',') | Should -Be ($enPlaceholders -join ',') -Because "key '$key'"
        }
    }
}

Describe 'Error catalog' {
    It 'has unique codes' {
        $codes = @($script:Errors | ForEach-Object code)
        $codes.Count | Should -Be (@($codes | Sort-Object -Unique).Count)
    }

    It 'contains only valid regular expressions' {
        foreach ($entry in $script:Errors) {
            foreach ($pattern in @($entry.patterns)) {
                { [void][regex]::new($pattern) } | Should -Not -Throw -Because "$($entry.code): $pattern"
            }
        }
    }
}

Describe 'Documentation' {
    It 'docs/TROUBLESHOOTING.md matches the current error catalog' {
        $temp = Join-Path ([IO.Path]::GetTempPath()) ('troubleshooting-' + [guid]::NewGuid().ToString('N') + '.md')
        try {
            & (Join-Path $script:RepoRoot 'tools\New-TroubleshootingDoc.ps1') -OutFile $temp 6>$null
            [IO.File]::ReadAllText($temp) | Should -Be ([IO.File]::ReadAllText((Join-Path $script:RepoRoot 'docs\TROUBLESHOOTING.md'))) -Because 'tools\New-TroubleshootingDoc.ps1 must be run after changing error codes or their texts'
        }
        finally { Remove-Item -LiteralPath $temp -ErrorAction SilentlyContinue }
    }

    It 'has release notes for the current version' {
        $manifest = [IO.File]::ReadAllText((Join-Path $script:SrcRoot 'CloudDrives.psd1'))
        $version = [regex]::Match($manifest, "ModuleVersion\s*=\s*'([0-9.]+)'").Groups[1].Value
        $notes = & (Join-Path $script:RepoRoot 'tools\Get-ReleaseNotes.ps1') -Version $version
        $notes | Should -Match '(?m)^### (Added|Changed|Deprecated|Removed|Fixed|Security)$'
        $notes | Should -Not -Match '(?m)^## \['
    }
}

Describe 'Dependencies' {
    It 'pins rclone with SHA256 checksums for all Windows architectures' {
        $script:Deps.rclone.version | Should -Match '^\d+\.\d+\.\d+$'
        foreach ($arch in @('amd64', 'arm64', '386')) { $script:Deps.rclone.sha256.$arch | Should -Match '^[0-9a-f]{64}$' }
        [version]$script:Deps.rclone.version | Should -BeGreaterOrEqual ([version]$script:Deps.rclone.minimumVersion)
    }

    It 'pins WinFsp with a checksum and an HTTPS download' {
        $script:Deps.winfsp.sha256 | Should -Match '^[0-9a-f]{64}$'
        $script:Deps.winfsp.msiUrl | Should -Match '^https://github\.com/winfsp/winfsp/releases/download/'
    }
}
