# Client for the rclone remote control (RC) API of the local engine.
# Uses HttpClient without proxy (the engine only listens on 127.0.0.1) and Basic authentication.

# Windows PowerShell 5.1 does not load System.Net.Http by default; type literals below need it.
Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue

$script:CdHttpClient = $null

function Get-CdHttpClient {
    if (-not $script:CdHttpClient) {
        $handler = New-Object System.Net.Http.HttpClientHandler
        $handler.UseProxy = $false
        $client = New-Object System.Net.Http.HttpClient($handler)
        $client.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan
        $script:CdHttpClient = $client
    }
    $script:CdHttpClient
}

function Invoke-CdRc {
    param(
        [Parameter(Mandatory, Position = 0)][string]$Command,
        [Parameter(Position = 1)][System.Collections.IDictionary]$Body = @{},
        [int]$TimeoutSec = 60,
        [object]$Connection
    )
    if (-not $Connection) { $Connection = Get-CdEngineConnection }
    if (-not $Connection) { throw (New-CdException -Code 'CD-5003' -Detail 'engine is not running') }

    $client = Get-CdHttpClient
    $json = ConvertTo-Json -InputObject $Body -Depth 10 -Compress
    $request = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Post, "http://127.0.0.1:$($Connection.Port)/$Command")
    $request.Headers.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Basic', $Connection.AuthToken)
    $request.Content = New-Object System.Net.Http.StringContent($json, [Text.Encoding]::UTF8, 'application/json')
    $cancel = New-Object System.Threading.CancellationTokenSource([TimeSpan]::FromSeconds($TimeoutSec))
    try {
        try {
            $response = $client.SendAsync($request, $cancel.Token).GetAwaiter().GetResult()
            $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        }
        catch {
            $message = $_.Exception.Message
            if ($cancel.IsCancellationRequested) { $message = "timeout after $TimeoutSec s ($Command)" }
            throw (New-CdException -Code 'CD-5003' -Detail "$Command : $message" -InnerException $_.Exception)
        }
        if ($response.IsSuccessStatusCode) {
            if ([string]::IsNullOrWhiteSpace($text)) { return $null }
            return ($text | ConvertFrom-Json)
        }
        $errorText = $text
        try { $parsed = $text | ConvertFrom-Json; if ($parsed.error) { $errorText = [string]$parsed.error } } catch { $errorText = $text }
        if ([int]$response.StatusCode -eq 401) { throw (New-CdException -Code 'CD-5003' -Detail "$Command : unauthorized") }
        $code = Resolve-CdErrorCode -Text $errorText
        Write-CdLog -Level WARN -Component 'Rc' -Message "$Command failed ($code): $errorText"
        throw (New-CdException -Code $code -Detail $errorText)
    }
    finally {
        $cancel.Dispose()
        $request.Dispose()
    }
}
