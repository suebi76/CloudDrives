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

function Get-CdHttpStatusCode {
    # HTTP status of a failed web request (WebException in Windows PowerShell, HttpResponseException in
    # PowerShell 7), or 0 when no response arrived.
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)
    $response = $ErrorRecord.Exception.Response
    if ($response -and $response.StatusCode) { return [int]$response.StatusCode }
    0
}

function ConvertTo-CdApiErrorCode {
    # 401 = sign-in invalid, other HTTP errors = provider refused, no response = no connection.
    param([int]$Status)
    if ($Status -eq 401) { return 'CD-3001' }
    if ($Status -ge 400) { return 'CD-3008' }
    'CD-5001'
}

function Invoke-CdApiGet {
    # GET request to a cloud API with an OAuth access token. Neither the token nor the response is logged.
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$AccessToken,
        [int]$TimeoutSec = 20
    )
    Initialize-CdTls
    $headers = @{ Authorization = "Bearer $AccessToken"; 'User-Agent' = "CloudDrives/$((Get-CdContext).Version)" }
    try { Invoke-RestMethod -Uri $Uri -Headers $headers -UseBasicParsing -TimeoutSec $TimeoutSec }
    catch {
        $status = Get-CdHttpStatusCode -ErrorRecord $_
        throw (New-CdException -Code (ConvertTo-CdApiErrorCode -Status $status) -Detail "GET $($Uri.Split('?')[0]): HTTP $status" -InnerException $_.Exception)
    }
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
    # Waits with exponential backoff until the cloud is reachable (e.g. right after logon). $OnWaiting is called
    # once when there is no connection at first (for a progress display).
    param([int]$TimeoutSec = 120, [scriptblock]$OnWaiting)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $delay = 2
    $told = $false
    while ($true) {
        if (Test-CdInternet) { return $true }
        if ((Get-Date) -ge $deadline) { return $false }
        if ($OnWaiting -and -not $told) { & $OnWaiting; $told = $true }
        Write-CdLog -Component 'Net' -Message "No connection yet, retrying in $delay s."
        Start-Sleep -Seconds $delay
        $delay = [Math]::Min($delay * 2, 15)
    }
}
