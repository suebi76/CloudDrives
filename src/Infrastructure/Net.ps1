# Network helpers: TLS setup for Windows PowerShell, verified downloads, free ports, connectivity checks.

function Initialize-CdTls {
    if ($PSVersionTable.PSEdition -ne 'Desktop') { return }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    catch { Write-CdLog -Level DEBUG -Component 'Net' -Message "TLS 1.2 setup: $($_.Exception.Message)" }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]'Tls13'
    }
    catch { Write-CdLog -Level DEBUG -Component 'Net' -Message 'TLS 1.3 not available in this .NET version.' }
}

function Get-CdFreeTcpPort {
    # Lets Windows choose a free loopback port; such ports are never in an excluded (reserved) range.
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try { $listener.LocalEndpoint.Port } finally { $listener.Stop() }
}

function Invoke-CdDownload {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile,
        [int]$TimeoutSec = 600,
        [int]$Retries = 3
    )
    Initialize-CdTls
    $previous = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        for ($attempt = 1; $attempt -le $Retries; $attempt++) {
            try {
                Write-CdLog -Component 'Net' -Message "Download $Uri (attempt $attempt)"
                Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -TimeoutSec $TimeoutSec `
                    -Headers @{ 'User-Agent' = "CloudDrives/$((Get-CdContext).Version)" }
                return
            }
            catch {
                Write-CdLog -Level WARN -Component 'Net' -Message "Download failed: $($_.Exception.Message)"
                if ($attempt -eq $Retries) {
                    throw (New-CdException -Code 'CD-1004' -Detail "$Uri : $($_.Exception.Message)" -InnerException $_.Exception)
                }
                Start-Sleep -Seconds ([int][Math]::Pow(2, $attempt))
            }
        }
    }
    finally { $ProgressPreference = $previous }
}

function Get-CdWebText {
    param([Parameter(Mandatory)][string]$Uri, [int]$TimeoutSec = 60)
    Initialize-CdTls
    $response = Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec $TimeoutSec -Headers @{ 'User-Agent' = "CloudDrives/$((Get-CdContext).Version)" }
    if ($response.Content -is [byte[]]) { return [Text.Encoding]::UTF8.GetString($response.Content) }
    [string]$response.Content
}

function Test-CdFileHash {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Sha256)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ieq $Sha256
}

function Test-CdTcpEndpoint {
    param([Parameter(Mandatory)][string]$HostName, [int]$Port = 443, [int]$TimeoutMs = 3000)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync($HostName, $Port)
        if ($task.Wait($TimeoutMs)) { return $client.Connected }
        $false
    }
    catch { $false }
    finally { $client.Dispose() }
}

function Test-CdInternet {
    # True when at least one of the cloud endpoints is reachable.
    foreach ($hostName in @('www.googleapis.com', 'graph.microsoft.com', 'login.microsoftonline.com')) {
        if (Test-CdTcpEndpoint -HostName $hostName -Port 443 -TimeoutMs 3000) { return $true }
    }
    $false
}

function Wait-CdNetwork {
    # Waits with exponential backoff until the cloud is reachable (e.g. right after logon).
    param([int]$TimeoutSec = 120)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $delay = 2
    while ($true) {
        if (Test-CdInternet) { return $true }
        if ((Get-Date) -ge $deadline) { return $false }
        Write-CdLog -Component 'Net' -Message "No connection yet, retrying in $delay s."
        Start-Sleep -Seconds $delay
        $delay = [Math]::Min($delay * 2, 15)
    }
}
