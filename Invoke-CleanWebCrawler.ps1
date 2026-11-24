param(
    [string[]]$Urls = @(
        "https://robdoe.com/",
        "https://github.com/LadbotOneLad",
        "https://github.com/backupsonbackupsrobby-cyber"
    ),
    [int]$MaxThreads = 4,
    [int]$TimeoutMs = 6000
)

$ErrorActionPreference = "SilentlyContinue"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

try {
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor 3072 -bor 12288
} catch {
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
}

function Get-Sha256Hex {
    param([Parameter(Mandatory = $true)][string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash($utf8NoBom.GetBytes($Text))
        return ([System.BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

$pool = [RunspaceFactory]::CreateRunspacePool(1, $MaxThreads)
$pool.Open()
$jobs = @()

$workerBlock = {
    param([string]$TargetUrl, [int]$Timeout)
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor 3072 -bor 12288
    } catch {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $req = [System.Net.HttpWebRequest]::Create($TargetUrl)
        $req.Method = "GET"
        $req.Timeout = $Timeout
        $req.AllowAutoRedirect = $true
        $req.UserAgent = "PS51-CleanCrawler/1.0"

        $resp = $req.GetResponse()
        $code = [int]$resp.StatusCode
        $stream = $resp.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($stream)
        $body = $reader.ReadToEnd()
        $reader.Close()
        $resp.Close()
        $sw.Stop()

        $sha = [System.Security.Cryptography.SHA256]::Create()
        $hashBytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($body))
        $sha.Dispose()
        $bodyHash = ([System.BitConverter]::ToString($hashBytes) -replace '-', '').ToLowerInvariant()

        [PSCustomObject]@{
            url        = $TargetUrl
            online     = $true
            status     = $code
            ms         = $sw.ElapsedMilliseconds
            bytes      = $body.Length
            sha256     = $bodyHash
        }
    } catch {
        $sw.Stop()
        [PSCustomObject]@{
            url        = $TargetUrl
            online     = $false
            status     = 0
            ms         = $sw.ElapsedMilliseconds
            bytes      = 0
            sha256     = ("0" * 64)
        }
    }
}

foreach ($u in $Urls) {
    $ps = [PowerShell]::Create()
    $ps.RunspacePool = $pool
    [void]$ps.AddScript($workerBlock).AddArgument($u).AddArgument($TimeoutMs)
    $jobs += [PSCustomObject]@{ PowerShell = $ps; Handle = $ps.BeginInvoke() }
}

$crawlResults = foreach ($j in $jobs) {
    $j.PowerShell.EndInvoke($j.Handle)
    $j.PowerShell.Dispose()
}
$pool.Close()
$pool.Dispose()

$crawlResults | Format-Table online, status, ms, bytes, @{Name="sha256_16"; Expression={$_.sha256.Substring(0, 16)}}, url -AutoSize

$utcNow = (Get-Date).ToUniversalTime().ToString("o")
$crawlLedger = "C:\PowerShell-Fkn-RobDoing\web_crawl_ledger.jsonl"
$crawlRecord = [ordered]@{
    timestamp_utc = $utcNow
    results       = $crawlResults
} | ConvertTo-Json -Compress -Depth 4
[System.IO.File]::AppendAllLines($crawlLedger, [string[]]@($crawlRecord), $utf8NoBom)

# Git fsck + HEAD root hash verification
$headCommit = (git -C "C:\PowerShell-Fkn-RobDoing" rev-parse HEAD 2>$null)
$headTree   = (git -C "C:\PowerShell-Fkn-RobDoing" rev-parse "HEAD^{tree}" 2>$null)
$fsckOut    = (git -C "C:\PowerShell-Fkn-RobDoing" fsck --full --no-dangling 2>&1) -join " | "
$fsckClean  = ($LASTEXITCODE -eq 0)

$fsckLedger = "C:\PowerShell-Fkn-RobDoing\git_fsck_roothash_ledger.jsonl"
$fsckRecord = [ordered]@{
    timestamp_utc = $utcNow
    head_commit   = $headCommit
    head_tree     = $headTree
    fsck_ok       = $fsckClean
    notes         = if ($fsckOut) { $fsckOut } else { "OK" }
} | ConvertTo-Json -Compress
[System.IO.File]::AppendAllLines($fsckLedger, [string[]]@($fsckRecord), $utf8NoBom)

Write-Host "Crawl logged -> $crawlLedger" -ForegroundColor Green
Write-Host "Git fsck ($fsckClean) -> $fsckLedger (Tree: $headTree)" -ForegroundColor Green