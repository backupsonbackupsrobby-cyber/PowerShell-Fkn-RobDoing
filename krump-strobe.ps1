[CmdletBinding()]
param(
    [ValidateRange(40, 2000)]
    [int]$BeatMs = 150,

    [string]$OracleLedger = "C:\PowerShell-Fkn-RobDoing\SovereignLedgerLogs\krump_session.oracle"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}

$utf8Bom = New-Object System.Text.UTF8Encoding($true)
$utf8Raw = New-Object System.Text.UTF8Encoding($false)
$sha256  = [System.Security.Cryptography.SHA256]::Create()

function Get-KrumpHash([string]$Text) {
    $bytes = $utf8Raw.GetBytes($Text)
    return ([System.BitConverter]::ToString($sha256.ComputeHash($bytes)) -replace "-", "").ToLowerInvariant()
}

$moves = @(
    "CHEST-POP",
    "HARD-STOMP",
    "ARM-SWING",
    "BUCK-HOP",
    "GROWN-MAN-THROW",
    "JAB-SNAP"
)

$ledgerDir = Split-Path -Parent $OracleLedger
if ($ledgerDir -and -not (Test-Path -LiteralPath $ledgerDir)) {
    New-Item -ItemType Directory -Path $ledgerDir -Force | Out-Null
}

$prevSeal = "GENESIS"
if ([System.IO.File]::Exists($OracleLedger)) {
    $lastLine = $null
    foreach ($line in [System.IO.File]::ReadLines($OracleLedger)) {
        if ($line.Trim().Length -gt 0) { $lastLine = $line }
    }
    if ($null -ne $lastLine) {
        $prevSeal = Get-KrumpHash -Text $lastLine
    }
}

$beat = 0
$stompCount = 0
$popCount = 0
$lastMove = "CHEST-POP"
$lastIntensity = 0.0

Write-Host ""
Write-Host "=== PURE KRUMP CADENCE LIVE // Press CTRL+C to seal & hold session ===" -ForegroundColor Red
Write-Host "Ledger: $OracleLedger" -ForegroundColor DarkGray

$origCtrlC = [Console]::TreatControlCAsInput
try {
    [Console]::TreatControlCAsInput = $true

    while ($true) {
        $beat++
        $move = $moves[($beat - 1) % $moves.Count]
        $phase = ($beat * 0.78539816339) # pi/4 raw krump pulse
        $intensity = [math]::Round((55.0 + (45.0 * [math]::Abs([math]::Sin($phase)))), 2)

        if ($move -eq "HARD-STOMP" -or $move -eq "BUCK-HOP") { $stompCount++ }
        if ($move -eq "CHEST-POP" -or $move -eq "JAB-SNAP")  { $popCount++ }

        $lastMove = $move
        $lastIntensity = $intensity

        $isHeavy = ($intensity -ge 85.0)
        $tag = if ($isHeavy) { "BUCK-SPIKE" } else { "KRUMP-FLOW" }
        $color = if ($isHeavy) { "Yellow" } else { "Green" }

        $line = "`r[KRUMP | {0} | {1} | Int:{2}% | Pops:{3} Stomps:{4}] Beat #{5} [Ctrl+C=Seal]  " -f `
            $move, $tag, $intensity, $popCount, $stompCount, $beat
        Write-Host $line -NoNewline -ForegroundColor $color

        $deadline = (Get-Date).AddMilliseconds($BeatMs)
        $stopNow = $false
        while ((Get-Date) -lt $deadline) {
            if ([Console]::KeyAvailable) {
                $k = [Console]::ReadKey($true)
                if ((($k.Modifiers -band [ConsoleModifiers]::Control) -ne 0) -and ($k.Key -eq [ConsoleKey]::C)) {
                    $stopNow = $true
                    break
                }
            }
            Start-Sleep -Milliseconds 15
        }
        if ($stopNow) {
            Write-Host ""
            break
        }
    }
}
finally {
    [Console]::TreatControlCAsInput = $origCtrlC
    try {
        $ts = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
        $sessionSeed = "KRUMP|BEATS:$beat|LAST:$lastMove($lastIntensity%)|POPS:$popCount|STOMPS:$stompCount|PREV:$prevSeal|TS:$ts"
        $seal = Get-KrumpHash -Text $sessionSeed
        $row = "$ts | beats=$beat | last_move=$lastMove | intensity=$lastIntensity | pops=$popCount | stomps=$stompCount | prev=$prevSeal | seal=$seal"
        [System.IO.File]::AppendAllText($OracleLedger, $row + [Environment]::NewLine, $utf8Bom)
        Write-Host "[KRUMP SEALED] Beats: $beat | Pops: $popCount | Stomps: $stompCount | Seal: $seal" -ForegroundColor Cyan
    } finally {
        $sha256.Dispose()
    }
}