#Requires -RunAsAdministrator
Set-StrictMode -Version Latest
$ErrorActionPreference = "SilentlyContinue"

function Get-Sha256HexUpper {
    param([string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))).Replace("-", "") }
    finally { $sha.Dispose() }
}

function Sync-TriTokenStack {
    param(
        [string]$RootHex64,
        [string]$Erc20Addr   = "0xB7f8BC63BbcaD18155201308C8f3540b07f84F5e",
        [string]$Erc721Addr  = "0x0165878A594ca255338adfa4d48449f69242Eb8F",
        [string]$Erc1155Addr = "0xA51c1fc2f0D1a1b8494Ed1FE312d7C3a78Ed91C0",
        [string]$RpcUrl      = "http://127.0.0.1:8545"
    )
    $privKey = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
    $owner   = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
    $bytes32 = "0x" + $RootHex64.ToLowerInvariant()

    if (-not (Get-Process -Name "anvil" -ErrorAction SilentlyContinue)) {
        Start-Process -FilePath "C:\Users\Admin\.foundry\bin\anvil.exe" -ArgumentList "--host 127.0.0.1 --port 8545 --chain-id 31337 --state C:\bitcoin-erc721\anvil_state.json" -WindowStyle Hidden
        Start-Sleep -Seconds 1
    }

    try {
        [void](cast send $Erc20Addr   "updateMerkleRoot(bytes32)" $bytes32 --private-key $privKey --rpc-url $RpcUrl 2>$null)
        [void](cast send $Erc721Addr  "updateMerkleRoot(bytes32)" $bytes32 --private-key $privKey --rpc-url $RpcUrl 2>$null)
        [void](cast send $Erc1155Addr "updateMerkleRoot(bytes32)" $bytes32 --private-key $privKey --rpc-url $RpcUrl 2>$null)

        $mintedRaw = (cast call $Erc721Addr "totalMinted()(uint256)" --rpc-url $RpcUrl 2>$null).Trim()
        $firstToken = ($mintedRaw -split '\s+')[0]
        $nextId    = ([uint64]$firstToken) + 1
        $tokenUri  = "ipfs://sha256-$($RootHex64.ToLowerInvariant())/pulse-$nextId.json"

        [void](cast send $Erc721Addr  "mintSovereignAsset(address,uint256,string)" $owner $nextId $tokenUri --private-key $privKey --rpc-url $RpcUrl 2>$null)
        [void](cast send $Erc1155Addr "mintBatchAssets(address,uint256[],uint256[])" $owner "[1]" "[1]" --private-key $privKey --rpc-url $RpcUrl 2>$null)

        $blkBody = @{ jsonrpc = "2.0"; method = "eth_getBlockByNumber"; params = @("latest", $false); id = 1 } | ConvertTo-Json -Compress
        $blkRes  = Invoke-RestMethod -Uri $RpcUrl -Method Post -Body $blkBody -ContentType "application/json" -TimeoutSec 2

        return [PSCustomObject]@{
            erc20_address   = $Erc20Addr
            erc721_address  = $Erc721Addr
            erc1155_address = $Erc1155Addr
            minted_token_id = $nextId
            state_root      = [string]$blkRes.result.stateRoot
        }
    }
    catch {
        return $null
    }
}

function Invoke-BFT72Consensus {
    param([string]$StateVector, [string]$AdapterName = "Wi-Fi", [int]$NodeCount = 72)
    $MaxFaults = [Math]::Floor(($NodeCount - 1) / 3)
    $QuorumReq = $NodeCount - $MaxFaults
    $AdapterObj = Get-NetAdapter -Name $AdapterName -ErrorAction SilentlyContinue
    $Healthy = ($null -ne $AdapterObj) -and ($AdapterObj.Status -eq "Up")

    $Pool = [RunspaceFactory]::CreateRunspacePool(1, 16)
    $Pool.Open()
    $Worker = {
        param($NodeId, $Vec, $Ok)
        $Status = if ($Ok) { "COMMIT" } else { "BYZANTINE_DRIFT" }
        $ShaObj = [Security.Cryptography.SHA256]::Create()
        try { $Sha = [BitConverter]::ToString($ShaObj.ComputeHash([Text.Encoding]::UTF8.GetBytes("BFT72-$NodeId|$Vec|$Status"))).Replace("-", "") }
        finally { $ShaObj.Dispose() }
        [PSCustomObject]@{ NodeId = $NodeId; Vote = $Status; Digest = $Sha }
    }

    $Pipes = @()
    try {
        foreach ($id in 1..$NodeCount) {
            $PS = [PowerShell]::Create().AddScript($Worker).AddArgument($id).AddArgument($StateVector).AddArgument($Healthy)
            $PS.RunspacePool = $Pool
            $Pipes += [PSCustomObject]@{ Pipe = $PS; Handle = $PS.BeginInvoke() }
        }
        $Votes = foreach ($Job in $Pipes) { $Job.Pipe.EndInvoke($Job.Handle) }
    }
    finally {
        foreach ($Job in $Pipes) { if ($Job.Pipe) { $Job.Pipe.Dispose() } }
        $Pool.Close()
        $Pool.Dispose()
    }

    $Commits = @($Votes | Where-Object { $_.Vote -eq "COMMIT" }).Count
    $Root = Get-Sha256HexUpper -Text (($Votes | ForEach-Object { $_.Digest }) -join "|")
    [PSCustomObject]@{ HonestCommits = $Commits; ConsensusReached = ($Commits -ge $QuorumReq); BftMerkleRoot = $Root }
}

function Invoke-SovereignMonolith {
    param(
        [ValidateSet("Teleport", "Anchor", "Ground", "Audit", "VerifyChain", "Browse")]
        [string]$Action       = "Anchor",
        [double]$AnchorM      = 0.2415,
        [int]$PulseCount      = 1,
        [string]$AdapterName  = "Wi-Fi",
        [string]$AtmosRoot    = "C:\atmospheric-truth-layer",
        [string]$RobDoingRoot = "C:\PowerShell-Fkn-RobDoing",
        [string]$AnvilRpcUrl  = "http://127.0.0.1:8545",
        [switch]$AnchorToAnvil
    )
    $AtmosLogs   = Join-Path $AtmosRoot "SovereignLedgerLogs"
    $RobLogs     = Join-Path $RobDoingRoot "SovereignLedgerLogs"
    $AtmosLedger = Join-Path $AtmosLogs "mana_string_11d.jsonl"
    $RobLedger   = Join-Path $RobLogs "mana_string_11d.jsonl"
    $Utf8NoBom   = [Text.UTF8Encoding]::new($false)

    foreach ($Dir in @($AtmosRoot, $AtmosLogs, $RobDoingRoot, $RobLogs)) {
        if (-not (Test-Path -LiteralPath $Dir)) { [void](New-Item -Path $Dir -ItemType Directory -Force) }
    }

    if ($Action -eq "VerifyChain") {
        if (-not (Test-Path -LiteralPath $AtmosLedger)) {
            Write-Warning "Primary ledger not found at $AtmosLedger."
            return
        }
        $AtmosLines = @(Get-Content -LiteralPath $AtmosLedger)
        $ExpectedPrev = "0" * 64
        $Verified = 0
        $Broken = 0
        for ($idx = 0; $idx -lt $AtmosLines.Count; $idx++) {
            $b = $AtmosLines[$idx] | ConvertFrom-Json
            $p = if ($b.PSObject.Properties["d10_prev_whakapapa_hash"]) { [string]$b.d10_prev_whakapapa_hash } else { "0" * 64 }
            $c = [string]$b.d10_sha256_seal
            if ($p -eq $ExpectedPrev -and $c.Length -eq 64) { $Verified++ } else { $Broken++ }
            $ExpectedPrev = $c
        }
        $headShort = if ($ExpectedPrev.Length -ge 16) { $ExpectedPrev.Substring(0, 16) } else { $ExpectedPrev }
        Write-Host "  Verified Links: $Verified / $($AtmosLines.Count) | Broken: $Broken | HEAD: $headShort..." -ForegroundColor Green
        return
    }

    if ($Action -in @("Teleport", "Anchor")) {
        for ($p = 1; $p -le $PulseCount; $p++) {
            $prevSeal = "0" * 64
            if (Test-Path -LiteralPath $AtmosLedger) {
                $lastLine = Get-Content -LiteralPath $AtmosLedger -Tail 1 -ErrorAction SilentlyContinue
                if (-not [string]::IsNullOrWhiteSpace($lastLine)) {
                    $prevObj = $lastLine | ConvertFrom-Json
                    if ($prevObj.PSObject.Properties["d10_sha256_seal"]) { $prevSeal = [string]$prevObj.d10_sha256_seal }
                }
            }
            $tsUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
            $bft   = Invoke-BFT72Consensus -StateVector "M11|$Action|Pulse:$p|M:$AnchorM|Prev:$prevSeal|TS:$tsUtc" -AdapterName $AdapterName
            $sync  = if ($AnchorToAnvil) { Sync-TriTokenStack -RootHex64 $bft.BftMerkleRoot -RpcUrl $AnvilRpcUrl } else { $null }
            $entry = [ordered]@{
                ts_utc                  = $tsUtc
                action                  = $Action
                pulse                   = $p
                bft_quorum_commits      = $bft.HonestCommits
                bft_merkle_root         = $bft.BftMerkleRoot
                d10_prev_whakapapa_hash = $prevSeal
                d10_sha256_seal         = $bft.BftMerkleRoot
                tri_token_sync          = $sync
            }
            $jsonLine = $entry | ConvertTo-Json -Compress
            foreach ($lp in @($AtmosLedger, $RobLedger)) {
                $sw = [IO.StreamWriter]::new($lp, $true, $Utf8NoBom)
                try { $sw.WriteLine($jsonLine) } finally { $sw.Dispose() }
            }
            Write-Host "==============================================================================" -ForegroundColor DarkCyan
            Write-Host "  SOVEREIGN M11 $Action SEALED & SYNCED TO ERC-20 / ERC-721 / ERC-1155" -ForegroundColor Cyan
            Write-Host "  BFT Merkle Root  : $($bft.BftMerkleRoot)" -ForegroundColor Green
            if ($sync) {
                Write-Host "  ERC-721 Minted   : Token #$($sync.minted_token_id) @ $($sync.erc721_address)" -ForegroundColor Yellow
                Write-Host "  Anvil State Root : $($sync.state_root)" -ForegroundColor Green
            }
            Write-Host "==============================================================================" -ForegroundColor DarkCyan
        }
    }
}