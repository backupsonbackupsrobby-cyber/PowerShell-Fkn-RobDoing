param(
    [string[]]$ExternalSeeds = @(
        "https://github.com",
        "https://github.com",
        "https://robdoe.com"
    ),
    [int]$MaxExternalPages = 15,
    [int]$DelayMs = 400
)

$ErrorActionPreference = "SilentlyContinue"
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
$utf8NoBom  = New-Object System.Text.UTF8Encoding($false)

$PsRobDir   = "C:\PowerShell-Fkn-RobDoing"
$AtmDir     = "C:\atmospheric-truth-layer"
$LedgerOut  = Join-Path $PsRobDir "web_resonance_ledger.jsonl"
$MerkleLog  = Join-Path $PsRobDir "fractal_merkle_seal.log"

$tick       = [char]0x2713
$esc        = [char]27
$reset      = "$esc[0m"
$nodeGlyph  = [string][char]0x25C9
$koruGlyph  = [string][char]0x058D

function Get-Sha256Hex {
    param([Parameter(Mandatory = $true)][string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash($utf8NoBom.GetBytes($Text))
        return ([System.BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-Sha3_512Hex {
    param([Parameter(Mandatory = $true)][string]$Text)
    $bytes = $utf8NoBom.GetBytes($Text)
    $pyExe = if (Test-Path -LiteralPath "C:\Python314\python.exe") { "C:\Python314\python.exe" } else { $null }
    if ($pyExe) {
        $b64 = [System.Convert]::ToBase64String($bytes)
        $pyCode = "import sys,base64,hashlib; print(hashlib.sha3_512(base64.b64decode(sys.argv)).hexdigest())"
        $res = & $pyExe -c $pyCode $b64 2>$null
        if ($LASTEXITCODE -eq 0 -and $res) {
            return ([string]$res).Trim().ToLowerInvariant()
        }
    }
    $h1 = Get-Sha256Hex -Text "SHA3_A|$Text"
    $h2 = Get-Sha256Hex -Text "SHA3_B|$Text"
    return ($h1 + $h2)
}

function Get-MerkleRoot {
    param([string[]]$Leaves)
    if (-not $Leaves -or $Leaves.Count -eq 0) { return (Get-Sha256Hex -Text "EMPTY_RESONANCE") }
    $level = @($Leaves | Sort-Object)
    while ($level.Count -gt 1) {
        $next = New-Object System.Collections.Generic.List[string]
        for ($i = 0; $i -lt $level.Count; $i += 2) {
            $l = $level[$i]
            $r = if (($i + 1) -lt $level.Count) { $level[$i + 1] } else { $l }
            $next.Add((Get-Sha256Hex -Text ($l + $r)))
        }
        $level = $next.ToArray()
    }
    return $level
}

# 1. Internal Resonance Crawl (Local Repos & Ledgers)
Write-Host "`n[1/3] Crawling Internal Substrate (PS 5.1)..." -ForegroundColor Cyan
$internalLeaves = New-Object System.Collections.Generic.List[string]
$skipFiles = @("web_resonance_ledger.jsonl", "fractal_merkle_seal.log", "chain_ledger.jsonl", "local_repo_index.jsonl")

foreach ($root in @($PsRobDir, $AtmDir)) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    $rootFull = (Resolve-Path -LiteralPath $root).Path.TrimEnd('\')
    $files = Get-ChildItem -LiteralPath $rootFull -File
    foreach ($f in $files) {
        if ($skipFiles -contains $f.Name) { continue }
        $fh = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $internalLeaves.Add((Get-Sha256Hex -Text "INT|$($f.Name)|$($f.Length)|$fh"))
    }
}
$internalMerkle = Get-MerkleRoot -Leaves $internalLeaves.ToArray()
Write-Host " [$tick] Internal Merkle Root ($($internalLeaves.Count) files): $internalMerkle" -ForegroundColor Green

# 2. External Resonance Crawl (HttpWebRequest / Invoke-WebRequest PS 5.1)
Write-Host "`n[2/3] Crawling External Endpoints..." -ForegroundColor Cyan
$visited      = New-Object 'System.Collections.Generic.HashSet[string]'
$queue        = New-Object 'System.Collections.Generic.Queue[string]'
$allowedHosts = New-Object 'System.Collections.Generic.HashSet[string]'

foreach ($seed in $ExternalSeeds) {
    $u = $null
    if ([System.Uri]::TryCreate($seed, [System.UriKind]::Absolute, [ref]$u)) {
        $queue.Enqueue($u.AbsoluteUri)
        [void]$allowedHosts.Add($u.Host)
    }
}

$externalLeaves  = New-Object 'System.Collections.Generic.List[string]'
$externalResults = New-Object 'System.Collections.Generic.List[object]'

while ($queue.Count -gt 0 -and $visited.Count -lt $MaxExternalPages) {
    $targetUrl = $queue.Dequeue()
    if (-not $visited.Add($targetUrl)) { continue }

    try {
        $resp = Invoke-WebRequest -Uri $targetUrl -UseBasicParsing -TimeoutSec 12 -Headers @{ "User-Agent" = "RobDoePS51Audit/1.0" }
        $bodyHash = Get-Sha256Hex -Text $resp.Content
        $externalLeaves.Add((Get-Sha256Hex -Text "EXT|$targetUrl|$($resp.StatusCode)|$bodyHash"))
        $externalResults.Add([ordered]@{ url = $targetUrl; status = [int]$resp.StatusCode; bytes = $resp.Content.Length; sha256 = $bodyHash })
        Write-Host " [$tick] EXT $($resp.StatusCode) | $($bodyHash.Substring(0,16))... | $targetUrl" -ForegroundColor Green

        $currUri = New-Object System.Uri($targetUrl)
        foreach ($lnk in $resp.Links) {
            if (-not $lnk.href) { continue }
            $nextUri = $null
            if ([System.Uri]::TryCreate($currUri, $lnk.href, [ref]$nextUri)) {
                if ($allowedHosts.Contains($nextUri.Host) -and ($nextUri.Scheme -eq "http" -or $nextUri.Scheme -eq "https")) { if ($nextUri.Host -eq "github.com" -and $nextUri.AbsolutePath -notmatch "^/(backupsonbackupsrobby-cyber|LESSGOObitty|LadbotOneLad)(/|$)") { continue } if ($nextUri.Host -eq "github.com" -and $nextUri.AbsolutePath -notmatch "^/(backupsonbackupsrobby-cyber|LESSGOObitty|LadbotOneLad)(/|$)") { continue }
                    $cleanPath = $nextUri.GetLeftPart([System.UriPartial]::Path)
                    if (-not $visited.Contains($cleanPath) -and $cleanPath -notmatch '\.(zip|tar|gz|png|jpg|svg|ico)$') {
                        $queue.Enqueue($cleanPath)
                    }
                }
            }
        }
    }
    catch {
        $errHash = Get-Sha256Hex -Text "OFFLINE|$targetUrl"
        $externalLeaves.Add($errHash)
        $externalResults.Add([ordered]@{ url = $targetUrl; status = 0; bytes = 0; sha256 = $errHash; note = "unreachable_or_parked" })
        Write-Host " [!] EXT OFFLINE | $targetUrl" -ForegroundColor DarkYellow
    }

    Start-Sleep -Milliseconds $DelayMs
}
$externalMerkle = Get-MerkleRoot -Leaves $externalLeaves.ToArray()
Write-Host " [$tick] External Merkle Root ($($visited.Count) endpoints): $externalMerkle" -ForegroundColor Green

# 3. Unified Internal x External 14-Chakra Alignment
$nowLocal    = Get-Date
$utcNow      = $nowLocal.ToUniversalTime().ToString("o")
$stamp       = $nowLocal.ToString("yyyy-MM-dd HH:mm:ss zzz")
$dualSeal512 = Get-Sha3_512Hex -Text "DUAL_RESONANCE_PS51|$internalMerkle|$externalMerkle|$utcNow"

$minsDay  = ($nowLocal.Hour * 60.0) + $nowLocal.Minute + ($nowLocal.Second / 60.0)
$solarRad = ((($minsDay / 1440.0) * 2.0 * [math]::PI) - ([math]::PI / 2.0))
$bC = [Convert]::ToByte($dualSeal512.Substring(0, 2), 16) / 255.0
$bN = [Convert]::ToByte($dualSeal512.Substring(6, 2), 16) / 255.0
$cReal = [math]::Round(-0.745 + (($bC - 0.5) * 0.036) + (0.012 * [math]::Cos($solarRad)), 6)
$cImag = [math]::Round(0.186  + (($bN - 0.5) * 0.036) + (0.012 * [math]::Sin($solarRad)), 6)

$chakras14 = @(
    @{ Id = "14"; Name = "STELLAR GATE "; Hz = 1440; Fg = 231; Pol = "YANG"; Off = 0.00 },
    @{ Id = "13"; Name = "SOUL STAR    "; Hz = 1296; Fg = 183; Pol = "YIN "; Off = 0.24 },
    @{ Id = "12"; Name = "CAUSAL GATE  "; Hz = 1152; Fg = 147; Pol = "YANG"; Off = 0.48 },
    @{ Id = "11"; Name = "GALACTIC     "; Hz = 1074; Fg = 135; Pol = "YIN "; Off = 0.72 },
    @{ Id = "10"; Name = "CROWN        "; Hz = 963;  Fg = 129; Pol = "YANG"; Off = 0.96 },
    @{ Id = "09"; Name = "THIRD EYE    "; Hz = 852;  Fg = 63;  Pol = "YIN "; Off = 1.20 },
    @{ Id = "08"; Name = "ALTA MAJOR   "; Hz = 796;  Fg = 39;  Pol = "YANG"; Off = 1.44 },
    @{ Id = "07"; Name = "THROAT       "; Hz = 741;  Fg = 45;  Pol = "YIN "; Off = 1.68 },
    @{ Id = "06"; Name = "HIGH HEART   "; Hz = 684;  Fg = 49;  Pol = "YANG"; Off = 1.92 },
    @{ Id = "05"; Name = "HEART        "; Hz = 639;  Fg = 46;  Pol = "YIN "; Off = 2.16 },
    @{ Id = "04"; Name = "SOLAR PLEXUS "; Hz = 528;  Fg = 226; Pol = "YANG"; Off = 2.40 },
    @{ Id = "03"; Name = "SACRAL       "; Hz = 417;  Fg = 208; Pol = "YIN "; Off = 2.64 },
    @{ Id = "02"; Name = "ROOT         "; Hz = 396;  Fg = 196; Pol = "YANG"; Off = 2.88 },
    @{ Id = "01"; Name = "EARTH STAR   "; Hz = 174;  Fg = 130; Pol = "YIN "; Off = 3.14 }
)

Write-Host "`n$esc[36m======================================================================================================$reset"
Write-Host "$esc[97m PS 5.1 DUAL RESONANCE: INTERNAL ($($internalLeaves.Count) FILES) x EXTERNAL ($($visited.Count) URLS) -> 14-CHAKRA$reset"
Write-Host "$esc[36m Dual SHA3-512 : $($dualSeal512.Substring(0, 64))... | Julia c: $cReal + ${cImag}i$reset"
Write-Host "$esc[36m======================================================================================================$reset"

$Cols = 72; $MaxIter = 22
$plainRows = New-Object 'System.Collections.Generic.List[string]'
for ($r = 0; $r -lt $chakras14.Count; $r++) {
    $chk = $chakras14[$r]
    $ny  = -1.25 + (2.50 * ($r / 13.0))
    $rowPlain = New-Object System.Text.StringBuilder
    $rowAnsi  = New-Object System.Text.StringBuilder
    for ($c = 0; $c -lt $Cols; $c++) {
        $nx = -1.75 + (3.50 * ($c / ($Cols - 1.0)))
        $lx = $nx + 0.68; $ly = $ny; $radL = [math]::Sqrt(($lx*$lx)+($ly*$ly)); $thL = [math]::Atan2($ly,$lx)
        $spL = [math]::Abs([math]::Sin((2.0*$thL) - (5.2*[math]::Log([math]::Max(0.04,$radL))) + $solarRad + $chk.Off))
        $rx = $nx - 0.68; $ry = $ny; $radR = [math]::Sqrt(($rx*$rx)+($ry*$ry)); $thR = [math]::Atan2($ry,$rx)
        $spR = [math]::Abs([math]::Sin((2.0*$thR) + (5.2*[math]::Log([math]::Max(0.04,$radR))) - $solarRad - $chk.Off))
        $songY = 0.58 * [math]::Sin(($nx * 2.2) + ($bC * 2.0 * [math]::PI) + $solarRad)
        $distSong = [math]::Abs($ny - $songY)
Use code with caution.
$isNode = ($distSong -lt 0.09) -and (([math]::Abs([math]::Sin(($nx * 4.4) + $bN + $solarRad))) -gt 0.91)
$zr = $nx; $zi = $ny; $it = 0
while ($it -lt $MaxIter) {
$zr2 = $zr*$zr; $zi2 = $zi*$zi
if (($zr2 + $zi2) -gt 4.0) { break }
$zi = (2.0*$zr*$zi) + $cImag; $zr = ($zr2 - $zi2) + $cReal; $it++
}
if ($isNode) { [void]$rowPlain.Append("0"); [void]$rowAnsi.Append("$esc[93m$nodeGlyph$reset") }
elseif ($distSong -lt 0.065) { [void]$rowPlain.Append("~"); [void]$rowAnsi.Append("$esc[38;5;208m~$reset") }
elseif ((($radL -lt 0.88) -and ($spL -lt 0.13) -and ($it -lt $MaxIter)) -or (($radR -lt 0.88) -and ($spR -lt 0.13) -and ($it -lt $MaxIter))) {
[void]$rowPlain.Append("K"); [void]$rowAnsi.Append("$esc[38;5;42m$koruGlyph$reset")
}
elseif ($it -eq $MaxIter) { [void]$rowPlain.Append("@"); [void]$rowAnsi.Append("$esc[38;5;$($chk.Fg)m@$reset") }
elseif ($it -ge 13) { [void]$rowPlain.Append("C"); [void]$rowAnsi.Append("$esc[38;5;46mC$reset") }
elseif ($it -ge 9) { [void]$rowPlain.Append("N"); [void]$rowAnsi.Append("$esc[38;5;129mN$reset") }
elseif ($it -ge 5) { [void]$rowPlain.Append("O"); [void]$rowAnsi.Append("$esc[38;5;45mO$reset") }
elseif ($it -ge 3) { [void]$rowPlain.Append("H"); [void]$rowAnsi.Append("$esc[38;5;226mH$reset") }
else { [void]$rowPlain.Append("."); [void]$rowAnsi.Append("$esc[38;5;$($chk.Fg)m.$reset") }
}
$prefix = ("C{0} [{1}] {2} {3,4}Hz : " -f $chk.Id, $chk.Pol, $chk.Name, $chk.Hz)
$plainRows.Add($prefix + $rowPlain.ToString())
Write-Host (" $esc[38;5;$($chk.Fg)m$prefix$reset" + $rowAnsi.ToString())
}
$asciiSha = Get-Sha256Hex -Text ($plainRows -join "`n")
$record = [ordered]@{
timestamp_utc     = $utcNow
local_clock       = $stamp
ps_version        = $PSVersionTable.PSVersion.ToString()
internal_files    = $internalLeaves.Count
internal_merkle   = $internalMerkle
external_pages    = $visited.Count
external_merkle   = $externalMerkle
external_targets  = $externalResults
ascii_base_sha256 = $asciiSha
dual_seal_sha3    = $dualSeal512
} | ConvertTo-Json -Compress -Depth 4
[System.IO.File]::AppendAllLines($LedgerOut, [string[]]@($record), $utf8NoBom)
[System.IO.File]::AppendAllLines($MerkleLog, [string[]]@("[$stamp] PS51_DUAL_RESONANCE=$dualSeal512 | INT=$internalMerkle | EXT=$externalMerkle"), $utf8NoBom)
Write-Host "$esc[36m------------------------------------------------------------------------------------------------------$reset"
Write-Host " [$tick] Internal Merkle Root  : $internalMerkle" -ForegroundColor Cyan
Write-Host " [$tick] External Merkle Root  : $externalMerkle" -ForegroundColor Cyan
Write-Host " [$tick] Unified Dual SHA3-512 : $($dualSeal512.Substring(0, 64))..." -ForegroundColor Green
Write-Host "$esc[36m======================================================================================================$reset`n"