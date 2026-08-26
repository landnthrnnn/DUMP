param(
    [string]$ProfileName = "Default-extras"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ToolDir = $PSScriptRoot
$Root = Split-Path $ToolDir -Parent
$Passover = Join-Path $Root "passover-to-carter"
$StateFile = Join-Path $ToolDir "expected-profile-state.json"
$RepoRoot = (Resolve-Path (Join-Path $Root "..\..")).Path

$Profile = Join-Path $env:APPDATA "Thunderstore Mod Manager\DataFolder\LethalCompany\profiles\$ProfileName"
$LocalLow = Join-Path $env:USERPROFILE "AppData\LocalLow\ZeekerssRBLX\Lethal Company"

function Fail([string]$Message) {
    throw $Message
}

function Is-ConfigBackup([string]$Name) {
    return (
        $Name -match '(?i)\.bak$' -or
        $Name -match '(?i)\.bak-' -or
        $Name -match '(?i)\.before-.+\.bak$' -or
        $Name -match '(?i)\.orig$' -or
        $Name -match '(?i)\.original$'
    )
}

function Get-TreeMap {
    param(
        [string]$Path,
        [switch]$FilterConfig
    )

    $Map = @{}

    if (-not (Test-Path -LiteralPath $Path)) {
        return $Map
    }

    foreach ($File in Get-ChildItem -LiteralPath $Path -File -Recurse -Force) {
        if ($FilterConfig -and (Is-ConfigBackup $File.Name)) {
            continue
        }

        $Rel = $File.FullName.Substring($Path.Length).TrimStart("\")
        $Map[$Rel] = (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash
    }

    return $Map
}

function Compare-Maps {
    param(
        [string]$Label,
        [hashtable]$Live,
        [hashtable]$Stored
    )

    $Changes = [System.Collections.Generic.List[string]]::new()

    foreach ($Key in $Live.Keys | Sort-Object) {
        if (-not $Stored.ContainsKey($Key)) {
            [void]$Changes.Add("ADD     $Label\$Key")
        }
        elseif ($Live[$Key] -ne $Stored[$Key]) {
            [void]$Changes.Add("MODIFY  $Label\$Key")
        }
    }

    foreach ($Key in $Stored.Keys | Sort-Object) {
        if (-not $Live.ContainsKey($Key)) {
            [void]$Changes.Add("DELETE  $Label\$Key")
        }
    }

    return $Changes
}

function Replace-Directory {
    param(
        [string]$Source,
        [string]$Destination,
        [switch]$FilterConfig
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        Fail "Missing live source: $Source"
    }

    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Recurse -Force
    }

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null

    if ($FilterConfig) {
        foreach ($File in Get-ChildItem -LiteralPath $Source -File -Recurse -Force) {
            if (Is-ConfigBackup $File.Name) {
                continue
            }

            $Rel = $File.FullName.Substring($Source.Length).TrimStart("\")
            $Dest = Join-Path $Destination $Rel

            New-Item -ItemType Directory -Path (Split-Path $Dest -Parent) -Force | Out-Null
            Copy-Item -LiteralPath $File.FullName -Destination $Dest -Force
        }
    }
    else {
        foreach ($Item in Get-ChildItem -LiteralPath $Source -Force) {
            Copy-Item -LiteralPath $Item.FullName -Destination $Destination -Recurse -Force
        }
    }
}

function Read-ModState([string]$Path) {
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
                version = "{0}.{1}.{2}" -f `
                    $Version.Groups[1].Value,
                    $Version.Groups[2].Value,
                    $Version.Groups[3].Value
                enabled = ($Enabled.Groups[1].Value -eq "true")
            }
        }
    }
}

function Get-StateJson {
    $ModsYml = Join-Path $Profile "mods.yml"

    if (-not (Test-Path -LiteralPath $ModsYml)) {
        Fail "mods.yml missing: $ModsYml"
    }

    $Mods = @(Read-ModState $ModsYml | Sort-Object name)

    if ($Mods.Count -eq 0) {
        Fail "Could not parse mods.yml."
    }

    return (
        [ordered]@{
            schema = 1
            profile = $ProfileName
            modCount = $Mods.Count
            mods = $Mods
        } | ConvertTo-Json -Depth 6
    )
}

if (-not (Test-Path -LiteralPath $Profile)) {
    Fail "Profile missing: $Profile"
}

if (-not (Test-Path -LiteralPath $Passover)) {
    Fail "Passover missing: $Passover"
}

$TerminalA = Join-Path $Profile "BepInEx\plugins\Television Videos"
$TerminalB = Join-Path $Profile "BepInEx\plugins\darmuh-darmuhsTerminalVideos"

Write-Host ""
Write-Host "Checking terminal-video mirrors..."

$TA = Get-TreeMap $TerminalA
$TB = Get-TreeMap $TerminalB
$TerminalDrift = @(Compare-Maps "terminal-mirror" $TA $TB)

if ($TerminalDrift.Count -gt 0) {
    Write-Host ""
    Write-Host "TERMINAL VIDEO MIRRORS DIFFER. Nothing changed."

    $TerminalDrift | ForEach-Object {
        Write-Host $_
    }

    Fail "Resolve which terminal-video folder is authoritative before syncing."
}

Write-Host "Terminal-video mirrors: VERIFIED"

$Mappings = @(
    [pscustomobject]@{
        Label = "config"
        Live = Join-Path $Profile "BepInEx\config"
        Stored = Join-Path $Passover "profile\BepInEx\config"
        FilterConfig = $true
    },
    [pscustomobject]@{
        Label = "custom-songs"
        Live = Join-Path $Profile "BepInEx\Custom Songs"
        Stored = Join-Path $Passover "profile\BepInEx\Custom Songs"
        FilterConfig = $false
    },
    [pscustomobject]@{
        Label = "pizza-music"
        Live = Join-Path $Profile "BepInEx\plugins\BGN-PizzaTowerEscapeMusic\DefaultMusic"
        Stored = Join-Path $Passover "profile\BepInEx\plugins\BGN-PizzaTowerEscapeMusic\DefaultMusic"
        FilterConfig = $false
    },
    [pscustomobject]@{
        Label = "pizza-scripts"
        Live = Join-Path $Profile "BepInEx\plugins\BGN-PizzaTowerEscapeMusic\DefaultScripts"
        Stored = Join-Path $Passover "profile\BepInEx\plugins\BGN-PizzaTowerEscapeMusic\DefaultScripts"
        FilterConfig = $false
    },
    [pscustomobject]@{
        Label = "kouky-sounds"
        Live = Join-Path $Profile "BepInEx\plugins\Koukycola-KoukysCustomSounds\CustomSounds\KoukysCustomSounds"
        Stored = Join-Path $Passover "profile\BepInEx\plugins\Koukycola-KoukysCustomSounds\CustomSounds\KoukysCustomSounds"
        FilterConfig = $false
    },
    [pscustomobject]@{
        Label = "terminal-videos"
        Live = $TerminalA
        Stored = Join-Path $Passover "shared\terminal-videos"
        FilterConfig = $false
    }
)

$AllChanges = [System.Collections.Generic.List[string]]::new()
$ChangedMappings = [System.Collections.Generic.List[object]]::new()

Write-Host ""
Write-Host "Scanning inventoried profile content..."

foreach ($M in $Mappings) {
    if (-not (Test-Path -LiteralPath $M.Live -PathType Container)) {
        Fail "Inventoried live directory missing: $($M.Live)"
    }

    $LiveMap = Get-TreeMap $M.Live -FilterConfig:$M.FilterConfig
    $StoredMap = Get-TreeMap $M.Stored
    $Changes = @(Compare-Maps $M.Label $LiveMap $StoredMap)

    if ($Changes.Count -gt 0) {
        [void]$ChangedMappings.Add($M)

        foreach ($Line in $Changes) {
            [void]$AllChanges.Add($Line)
        }
    }
}

$TmeLive = Join-Path $LocalLow "TooManyEmotes_LocalSaveData"
$TmeStored = Join-Path $Passover "external\TooManyEmotes_LocalSaveData"

if (-not (Test-Path -LiteralPath $TmeLive -PathType Leaf)) {
    Fail "TooManyEmotes_LocalSaveData missing: $TmeLive"
}

$TmeLiveHash = (Get-FileHash -LiteralPath $TmeLive -Algorithm SHA256).Hash

$TmeStoredHash = if (Test-Path -LiteralPath $TmeStored -PathType Leaf) {
    (Get-FileHash -LiteralPath $TmeStored -Algorithm SHA256).Hash
}
else {
    $null
}

$TmeChanged = ($TmeLiveHash -ne $TmeStoredHash)

if ($TmeChanged) {
    if ($TmeStoredHash) {
        [void]$AllChanges.Add("MODIFY  TooManyEmotes_LocalSaveData")
    }
    else {
        [void]$AllChanges.Add("ADD     TooManyEmotes_LocalSaveData")
    }
}

$NewStateJson = Get-StateJson
$StateChanged = $true

if (Test-Path -LiteralPath $StateFile) {
    try {
        $Old = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json

        $OldCanonical = (
            [ordered]@{
                schema = $Old.schema
                profile = $Old.profile
                modCount = $Old.modCount
                mods = @($Old.mods)
            } | ConvertTo-Json -Depth 6
        )

        $StateChanged = ($OldCanonical -ne $NewStateJson)
    }
    catch {
        $StateChanged = $true
    }
}

if ($StateChanged) {
    [void]$AllChanges.Add("MODIFY  expected-profile-state.json")
}

Write-Host ""

if ($AllChanges.Count -eq 0) {
    Write-Host "NO INVENTORIED CHANGES DETECTED."
    Write-Host "Passover already matches your live finalized setup."
    exit 0
}

Write-Host "DETECTED CHANGES"
Write-Host "================"

$AllChanges | ForEach-Object {
    Write-Host $_
}

Write-Host ""

$Answer = Read-Host "Update passover-to-carter with these changes? [y/N]"

if ($Answer -notmatch '^(?i)y(es)?$') {
    Write-Host "Cancelled. Nothing changed."
    exit 0
}

foreach ($M in $ChangedMappings) {
    Write-Host "Syncing $($M.Label)..."

    Replace-Directory `
        $M.Live `
        $M.Stored `
        -FilterConfig:$M.FilterConfig
}

if ($TmeChanged) {
    New-Item `
        -ItemType Directory `
        -Path (Split-Path $TmeStored -Parent) `
        -Force | Out-Null

    Copy-Item `
        -LiteralPath $TmeLive `
        -Destination $TmeStored `
        -Force
}

if ($StateChanged) {
    $NewStateJson |
        Set-Content -LiteralPath $StateFile -Encoding UTF8
}

$Manifest = Join-Path $Passover "payload-sha256.txt"

$Lines = foreach ($File in (
    Get-ChildItem -LiteralPath $Passover -File -Recurse -Force |
    Where-Object {
        $_.FullName -ne $Manifest
    } |
    Sort-Object FullName
)) {
    $Rel = $File.FullName.Substring($Passover.Length).TrimStart("\")
    $Hash = (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash

    "$Hash *$Rel"
}

$Lines |
    Set-Content -LiteralPath $Manifest -Encoding UTF8

Write-Host ""
Write-Host "PASSOVER UPDATED."
Write-Host ""

Set-Location -LiteralPath $RepoRoot

git status --short -- "misc/my-lethal-company-mod-setup"

Write-Host ""

$Push = Read-Host "Commit and push these changes now? [y/N]"

if ($Push -notmatch '^(?i)y(es)?$') {
    Write-Host "Done locally. Nothing committed or pushed."
    exit 0
}

$Message = Read-Host "Commit message [Update Carter Lethal Company passover]"

if ([string]::IsNullOrWhiteSpace($Message)) {
    $Message = "Update Carter Lethal Company passover"
}

git add -- "misc/my-lethal-company-mod-setup"

if ($LASTEXITCODE -ne 0) {
    Fail "git add failed."
}

git diff --cached --quiet

if ($LASTEXITCODE -eq 0) {
    Write-Host "Nothing staged; no commit needed."
    exit 0
}

git commit -m $Message

if ($LASTEXITCODE -ne 0) {
    Fail "git commit failed."
}

$Branch = (git branch --show-current).Trim()

if ([string]::IsNullOrWhiteSpace($Branch)) {
    Fail "Could not determine current Git branch."
}

git -c lfs.locksverify=false push origin $Branch

if ($LASTEXITCODE -ne 0) {
    Fail "git push failed. Local commit is preserved."
}

Write-Host ""
Write-Host "SYNC + COMMIT + PUSH COMPLETE"
Write-Host "Commit: $((git rev-parse HEAD).Trim())"

