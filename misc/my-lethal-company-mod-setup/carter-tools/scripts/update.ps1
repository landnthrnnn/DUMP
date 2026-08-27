param(
    [switch]$VerifyOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = $PSScriptRoot
$ToolRoot = Split-Path $ScriptDir -Parent
$ProjectRoot = Split-Path $ToolRoot -Parent
$Passover = Join-Path $ProjectRoot "passover"
$StateFile = Join-Path $Passover "profile-configs-n-customs.json"

$Profile = Join-Path $env:APPDATA `
    "Thunderstore Mod Manager\DataFolder\LethalCompany\profiles\Default-extras"

$ModsYml = Join-Path $Profile "mods.yml"

function Fail {
    param([string]$Message)
    throw $Message
}

function Get-Rel {
    param(
        [string]$Base,
        [string]$Path
    )

    $Path.Substring($Base.Length).TrimStart("\")
}

function Read-ModState {
    param([string]$Path)

    $Raw = [IO.File]::ReadAllText($Path)

    $Blocks = [regex]::Split(
        $Raw,
        '(?m)(?=^- manifestVersion:\s*1\s*$)'
    ) | Where-Object {
        $_ -match '(?m)^- manifestVersion:\s*1\s*$'
    }

    foreach ($Block in $Blocks) {

        $Name = [regex]::Match(
            $Block,
            '(?m)^\s{2}name:\s*(.+?)\s*$'
        )

        $Enabled = [regex]::Match(
            $Block,
            '(?m)^\s{2}enabled:\s*(true|false)\s*$'
        )

        $Version = [regex]::Match(
            $Block,
            '(?ms)^\s{2}versionNumber:\s*\r?\n\s{4}major:\s*(\d+)\s*\r?\n\s{4}minor:\s*(\d+)\s*\r?\n\s{4}patch:\s*(\d+)'
        )

        if ($Name.Success -and $Enabled.Success -and $Version.Success) {

            [pscustomobject]@{
                name = $Name.Groups[1].Value.Trim().Trim("'`"")
                version = (
                    "{0}.{1}.{2}" -f
                    $Version.Groups[1].Value,
                    $Version.Groups[2].Value,
                    $Version.Groups[3].Value
                )
                enabled = ($Enabled.Groups[1].Value -eq "true")
            }
        }
    }
}

function Test-ProfileState {

    if (-not (Test-Path -LiteralPath $StateFile)) {
        Fail "profile-configs-n-customs.json is missing."
    }

    if (-not (Test-Path -LiteralPath $ModsYml)) {
        Fail @"
Default-extras was not found.

Import Landon's Thunderstore profile code FIRST, then run this again.

Expected:
$ModsYml
"@
    }

    $Expected = Get-Content -LiteralPath $StateFile -Raw |
        ConvertFrom-Json

    $Current = @(
        Read-ModState $ModsYml
    )

    $ExpectedMods = @($Expected.mods)

    if ($Current.Count -ne $ExpectedMods.Count) {
        Fail "Thunderstore package count mismatch. Expected $($ExpectedMods.Count), found $($Current.Count)."
    }

    $CurrentMap = @{}

    foreach ($Mod in $Current) {
        $CurrentMap[$Mod.name.ToLowerInvariant()] = $Mod
    }

    foreach ($Wanted in $ExpectedMods) {

        $Key = $Wanted.name.ToLowerInvariant()

        if (-not $CurrentMap.ContainsKey($Key)) {
            Fail "Required Thunderstore package missing: $($Wanted.name)"
        }

        $Have = $CurrentMap[$Key]

        if ($Have.version -ne $Wanted.version) {
            Fail "Version mismatch for $($Wanted.name): expected $($Wanted.version), found $($Have.version)"
        }

        if ([bool]$Have.enabled -ne [bool]$Wanted.enabled) {
            Fail "Enabled/disabled mismatch for $($Wanted.name)"
        }
    }

    Write-Host "Thunderstore package/version/enabled state: VERIFIED"
}

function Test-PayloadManifest {

    $Manifest = Join-Path $Passover "payload-sha256.txt"

    if (-not (Test-Path -LiteralPath $Manifest)) {
        Fail "payload-sha256.txt is missing."
    }

    $Lines = @(
        Get-Content -LiteralPath $Manifest |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        }
    )

    $ActualFiles = @(
        Get-ChildItem -LiteralPath $Passover -File -Recurse -Force |
        Where-Object {
            $_.FullName -ne $Manifest
        }
    )

    if ($Lines.Count -ne $ActualFiles.Count) {
        Fail "Payload manifest file-count mismatch."
    }

    $Verified = 0

    foreach ($Line in $Lines) {

        if ($Line -notmatch '^([A-Fa-f0-9]{64}) \*(.+)$') {
            Fail "Invalid payload manifest entry: $Line"
        }

        $ExpectedHash = $Matches[1].ToUpperInvariant()
        $Relative = $Matches[2]
        $Path = Join-Path $Passover $Relative

        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            Fail "Payload file missing: $Relative"
        }

        $ActualHash = (
            Get-FileHash -LiteralPath $Path -Algorithm SHA256
        ).Hash

        if ($ActualHash -ne $ExpectedHash) {
            Fail "Payload SHA256 mismatch: $Relative"
        }

        $Verified++
    }

    Write-Host "Payload files/hash integrity: VERIFIED ($Verified files)"
}

function Get-TreeMap {
    param([string]$Root)

    $Map = @{}

    Get-ChildItem -LiteralPath $Root -File -Recurse -Force |
        ForEach-Object {

            $Rel = Get-Rel $Root $_.FullName

            $Map[$Rel] = (
                Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256
            ).Hash
        }

    return $Map
}

function Assert-TreeMatches {
    param(
        [string]$Source,
        [string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Destination)) {
        Fail "Destination missing after sync: $Destination"
    }

    $A = Get-TreeMap $Source
    $B = Get-TreeMap $Destination

    if ($A.Count -ne $B.Count) {
        Fail "Destination file-count mismatch: $Destination"
    }

    foreach ($Key in $A.Keys) {

        if (-not $B.ContainsKey($Key)) {
            Fail "Destination missing file: $Destination\$Key"
        }

        if ($A[$Key] -ne $B[$Key]) {
            Fail "Destination hash mismatch: $Destination\$Key"
        }
    }
}

function Replace-Directory {
    param(
        [string]$Source,
        [string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        Fail "Source directory missing: $Source"
    }

    $Parent = Split-Path $Destination -Parent
    New-Item -ItemType Directory -Path $Parent -Force | Out-Null

    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Recurse -Force
    }

    Copy-Item `
        -LiteralPath $Source `
        -Destination $Destination `
        -Recurse `
        -Force

    Assert-TreeMatches $Source $Destination

    Write-Host "SYNCED: $Destination"
}

function Replace-File {
    param(
        [string]$Source,
        [string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        Fail "Source file missing: $Source"
    }

    $Parent = Split-Path $Destination -Parent
    New-Item -ItemType Directory -Path $Parent -Force | Out-Null

    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Force -Recurse
    }

    Copy-Item -LiteralPath $Source -Destination $Destination -Force

    $A = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash
    $B = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash

    if ($A -ne $B) {
        Fail "Destination file hash mismatch: $Destination"
    }

    Write-Host "SYNCED: $Destination"
}

try {

    Write-Host ""
    Write-Host "============================================"
    Write-Host " CARTER / LANDON LETHAL COMPANY FINAL SYNC"
    Write-Host "============================================"
    Write-Host ""

    if (-not (Test-Path -LiteralPath $Passover)) {
        Fail "passover folder is missing."
    }

    Test-ProfileState
    Test-PayloadManifest

    $MapFile = Join-Path $Passover "destination-map.json"

    if (-not (Test-Path -LiteralPath $MapFile)) {
        Fail "destination-map.json is missing."
    }

    $Map = Get-Content -LiteralPath $MapFile -Raw |
        ConvertFrom-Json

    Write-Host "Destination map: VERIFIED"
    Write-Host ""

    if ($VerifyOnly) {
        Write-Host "VERIFY-ONLY RESULT: PASS"
        Write-Host "Nothing was modified."
        exit 0
    }

    $Running = @(
        Get-Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ProcessName -match '(?i)lethal|thunderstore|r2modman'
        }
    )

    if ($Running.Count -gt 0) {

        $Names = (
            $Running |
            Select-Object -ExpandProperty ProcessName -Unique
        ) -join ", "

        Fail "Close Lethal Company / Thunderstore first. Running: $Names"
    }

    Write-Host "Preflight complete."
    Write-Host "NO BACKUP / ROLLBACK LAYER IS BEING USED."
    Write-Host ""
    Write-Host "Applying final parity sync..."
    Write-Host ""

    foreach ($Entry in @($Map.profilePayload)) {

        $Source = Join-Path $Passover $Entry.source
        $Destination = Join-Path $Profile $Entry.destination

        if ($Entry.mode -ne "replace-directory") {
            Fail "Unsupported profile mode: $($Entry.mode)"
        }

        Replace-Directory $Source $Destination
    }

    foreach ($Entry in @($Map.sharedPayload)) {

        $Source = Join-Path $Passover $Entry.source

        if ($Entry.mode -ne "replace-directory") {
            Fail "Unsupported shared mode: $($Entry.mode)"
        }

        foreach ($RelativeDestination in @($Entry.destinations)) {

            $Destination = Join-Path $Profile $RelativeDestination

            Replace-Directory $Source $Destination
        }
    }

    foreach ($Entry in @($Map.externalPayload)) {

        $Source = Join-Path $Passover $Entry.source

        $Destination = [Environment]::ExpandEnvironmentVariables(
            [string]$Entry.destination
        )

        if ($Entry.mode -eq "replace-file") {
            Replace-File $Source $Destination
        }
        elseif ($Entry.mode -eq "replace-directory") {
            Replace-Directory $Source $Destination
        }
        else {
            Fail "Unsupported external mode: $($Entry.mode)"
        }
    }

    Write-Host ""
    Write-Host "============================================"
    Write-Host " FINAL SYNC COMPLETE"
    Write-Host "============================================"
    Write-Host ""
    Write-Host "Thunderstore packages : VERIFIED"
    Write-Host "Configs               : SYNCED + VERIFIED"
    Write-Host "Custom songs          : SYNCED + VERIFIED"
    Write-Host "Escape music/scripts  : SYNCED + VERIFIED"
    Write-Host "Kouky sound tree      : SYNCED + VERIFIED"
    Write-Host "Terminal videos       : SYNCED + VERIFIED"
    Write-Host "TooManyEmotes data    : SYNCED + VERIFIED"
    Write-Host ""
    Write-Host "Carter's Default-extras is synced to Landon's finalized setup."

    exit 0
}
catch {

    Write-Host ""
    Write-Host "============================================"
    Write-Host " SYNC FAILED"
    Write-Host "============================================"
    Write-Host ""
    Write-Host $_.Exception.Message
    Write-Host ""
    Write-Host "No backup/rollback layer exists by design."

    exit 1
}
