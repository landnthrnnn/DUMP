param(
    [string]$ProfileName = "Default-extras"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

try {
    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
}
catch {
    # ZipFile may already be available through the loaded framework assemblies.
}

$ScriptDir = $PSScriptRoot
$ToolDir = Split-Path $ScriptDir -Parent
$ProjectRoot = Split-Path $ToolDir -Parent
$PassoverRoot = Join-Path $ProjectRoot "passover"
$DataDir = Join-Path $ToolDir "data"
$StateFile = Join-Path $DataDir "mod-update-state.json"
$ReportFile = Join-Path $DataDir "mod-update-report.md"
$IndexFile = Join-Path $DataDir "mod-index.md"

$Profile = Join-Path $env:APPDATA "Thunderstore Mod Manager\DataFolder\LethalCompany\profiles\$ProfileName"
$ModsYml = Join-Path $Profile "mods.yml"
$LiveConfigRoot = Join-Path $Profile "BepInEx\config"
$PassoverConfigRoot = Join-Path $PassoverRoot "profile\BepInEx\config"
$LethalCompanyRoot = Split-Path (Split-Path $Profile -Parent) -Parent
$CacheRoot = Join-Path $LethalCompanyRoot "cache"
$PassoverManifest = Join-Path $PassoverRoot "payload-sha256.txt"

$Pad = "   "
$RuleWidth = 72

function Fail([string]$Message) {
    throw $Message
}

function Ensure-CorePaths {
    if (-not (Test-Path -LiteralPath $Profile -PathType Container)) {
        Fail "Thunderstore profile missing: $Profile"
    }
    if (-not (Test-Path -LiteralPath $ModsYml -PathType Leaf)) {
        Fail "mods.yml missing: $ModsYml"
    }
    if (-not (Test-Path -LiteralPath $LiveConfigRoot -PathType Container)) {
        Fail "Live BepInEx config folder missing: $LiveConfigRoot"
    }
    if (-not (Test-Path -LiteralPath $PassoverConfigRoot -PathType Container)) {
        Fail "Passover config folder missing: $PassoverConfigRoot"
    }
    New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
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

function Write-Pad {
    Write-Host -NoNewline $Pad
}

function Write-Rule([char]$Character = '=') {
    Write-Pad
    Write-Host (($Character.ToString()) * $RuleWidth) -ForegroundColor Magenta
}

function Write-Title([string]$Text) {
    Write-Host ""
    Write-Rule '='
    Write-Pad
    Write-Host $Text.ToUpperInvariant() -ForegroundColor Magenta
    Write-Rule '='
    Write-Host ""
}

function Write-Section([string]$Text) {
    Write-Host ""
    Write-Pad
    Write-Host $Text -ForegroundColor Magenta
    Write-Rule '-'
}

function Write-Line {
    param(
        [string]$Text = "",
        [ConsoleColor]$Color = [ConsoleColor]::White,
        [switch]$NoPadding
    )

    if (-not $NoPadding) {
        Write-Pad
    }
    Write-Host $Text -ForegroundColor $Color
}

function Write-Field {
    param(
        [string]$Label,
        [string]$Value,
        [ConsoleColor]$ValueColor = [ConsoleColor]::DarkGray
    )

    Write-Pad
    Write-Host -NoNewline ("{0,-18}: " -f $Label) -ForegroundColor White
    Write-Host $Value -ForegroundColor $ValueColor
}

function Write-Option {
    param(
        [string]$Key,
        [string]$Text
    )

    Write-Pad
    Write-Host -NoNewline "[" -ForegroundColor White
    Write-Host -NoNewline $Key -ForegroundColor Magenta
    Write-Host -NoNewline "]" -ForegroundColor White
    Write-Host " $Text" -ForegroundColor White
}

function Write-Status {
    param(
        [string]$Label,
        [string]$Value,
        [ConsoleColor]$Color
    )

    Write-Pad
    Write-Host -NoNewline ("{0,-24} " -f $Label) -ForegroundColor White
    Write-Host $Value -ForegroundColor $Color
}

function Format-DisplayTimestamp([object]$Value = $null) {
    $DateValue = $null

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        $DateValue = Get-Date
    }
    elseif ($Value -is [datetime]) {
        $DateValue = [datetime]$Value
    }
    else {
        try {
            $DateValue = [datetimeoffset]::Parse([string]$Value).LocalDateTime
        }
        catch {
            try {
                $DateValue = [datetime]::Parse([string]$Value)
            }
            catch {
                return [string]$Value
            }
        }
    }

    return $DateValue.ToString("MM/dd/yy hh:mmtt").ToLowerInvariant()
}

function Format-DisplayPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $Path
    }

    $Clean = $Path.TrimEnd([char[]]"\/")
    $Parts = @(
        $Clean -split '[\\/]' |
            Where-Object { $_ -and $_ -notmatch '^[A-Za-z]:$' }
    )

    $Tail = @($Parts | Select-Object -Last 3)
    return "\" + ($Tail -join "\")
}

function Pause-AnyKey {
    Write-Host ""
    Write-Pad
    Write-Host -NoNewline "Press any key to continue..." -ForegroundColor DarkGray
    [void][Console]::ReadKey($true)
}

function Read-OneKey {
    param(
        [string[]]$Allowed,
        [switch]$AllowEscape
    )

    while ($true) {
        $Key = [Console]::ReadKey($true)

        if ($AllowEscape -and $Key.Key -eq [ConsoleKey]::Escape) {
            return "ESC"
        }

        $Text = $Key.KeyChar.ToString().ToLowerInvariant()
        if ($Allowed -contains $Text) {
            return $Text
        }
    }
}

function Read-LineEsc {
    Write-Pad
    Write-Host -NoNewline "> " -ForegroundColor White

    $Buffer = New-Object System.Text.StringBuilder

    while ($true) {
        $Key = [Console]::ReadKey($true)

        if ($Key.Key -eq [ConsoleKey]::Escape) {
            Write-Host ""
            return $null
        }

        if ($Key.Key -eq [ConsoleKey]::Enter) {
            Write-Host ""
            return $Buffer.ToString()
        }

        if ($Key.Key -eq [ConsoleKey]::Backspace) {
            if ($Buffer.Length -gt 0) {
                [void]$Buffer.Remove($Buffer.Length - 1, 1)
                Write-Host -NoNewline "`b `b"
            }
            continue
        }

        if (-not [char]::IsControl($Key.KeyChar)) {
            [void]$Buffer.Append($Key.KeyChar)
            Write-Host -NoNewline $Key.KeyChar -ForegroundColor White
        }
    }
}

function Confirm-YesNo([string]$Question) {
    Write-Host ""
    Write-Pad
    Write-Host $Question -ForegroundColor White
    Write-Host ""
    Write-Pad
    Write-Host -NoNewline "[" -ForegroundColor White
    Write-Host -NoNewline "y" -ForegroundColor Magenta
    Write-Host -NoNewline "]" -ForegroundColor White
    Write-Host -NoNewline " Yes   " -ForegroundColor White
    Write-Host -NoNewline "[" -ForegroundColor White
    Write-Host -NoNewline "n" -ForegroundColor Magenta
    Write-Host -NoNewline "]" -ForegroundColor White
    Write-Host " No" -ForegroundColor White

    $Choice = Read-OneKey -Allowed @("y", "n") -AllowEscape
    if ($Choice -eq "ESC") {
        return $null
    }
    return ($Choice -eq "y")
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
                name = $Name.Groups[1].Value.Trim().Trim([char[]]@([char]39, [char]34))
                version = "{0}.{1}.{2}" -f `
                    $Version.Groups[1].Value,
                    $Version.Groups[2].Value,
                    $Version.Groups[3].Value
                enabled = ($Enabled.Groups[1].Value -eq "true")
            }
        }
    }
}

function Get-CurrentMods {
    $Mods = @(Read-ModState $ModsYml | Sort-Object name)
    if ($Mods.Count -eq 0) {
        Fail "Could not parse mods.yml."
    }
    return $Mods
}

function Normalize-Token([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ""
    }
    return (($Text.ToLowerInvariant()) -replace '[^a-z0-9]', '')
}

function Get-PackageParts([string]$Name) {
    $Split = $Name -split '-', 2
    if ($Split.Count -eq 2) {
        return [pscustomobject]@{
            owner = $Split[0]
            package = $Split[1]
        }
    }
    return [pscustomobject]@{
        owner = ""
        package = $Name
    }
}

function Get-CachePackageIndex {
    $Results = [System.Collections.Generic.List[object]]::new()

    if (-not (Test-Path -LiteralPath $CacheRoot -PathType Container)) {
        return @()
    }

    $Archives = @(Get-ChildItem -LiteralPath $CacheRoot -File -Recurse -Filter *.zip -ErrorAction SilentlyContinue)

    foreach ($Archive in $Archives) {
        $Zip = $null
        try {
            $Zip = [IO.Compression.ZipFile]::OpenRead($Archive.FullName)
            $ManifestEntry = $Zip.Entries | Where-Object {
                $_.FullName -match '(^|/)manifest\.json$'
            } | Select-Object -First 1

            if ($null -eq $ManifestEntry) {
                continue
            }

            $Reader = New-Object IO.StreamReader($ManifestEntry.Open())
            try {
                $ManifestText = $Reader.ReadToEnd()
            }
            finally {
                $Reader.Dispose()
            }

            $Manifest = $ManifestText | ConvertFrom-Json
            $Name = ""
            $Version = ""

            if ($null -ne $Manifest.PSObject.Properties['name']) {
                $Name = [string]$Manifest.name
            }
            if ($null -ne $Manifest.PSObject.Properties['version_number']) {
                $Version = [string]$Manifest.version_number
            }

            if (-not [string]::IsNullOrWhiteSpace($Name)) {
                $Rel = $Archive.FullName.Substring($CacheRoot.Length).TrimStart("\")
                [void]$Results.Add([pscustomobject]@{
                    manifestName = $Name
                    version = $Version
                    relativePath = $Rel
                    fullPath = $Archive.FullName
                })
            }
        }
        catch {
            continue
        }
        finally {
            if ($null -ne $Zip) {
                $Zip.Dispose()
            }
        }
    }

    return @($Results)
}

function Resolve-CacheArchive {
    param(
        [object]$Mod,
        [object[]]$CacheIndex
    )

    $Parts = Get-PackageParts $Mod.name
    $PackageNorm = Normalize-Token $Parts.package
    $OwnerNorm = Normalize-Token $Parts.owner

    $Candidates = @($CacheIndex | Where-Object {
        (Normalize-Token $_.manifestName) -eq $PackageNorm -and
        ([string]::IsNullOrWhiteSpace($_.version) -or $_.version -eq $Mod.version)
    })

    if ($Candidates.Count -eq 0) {
        return $null
    }

    if ($Candidates.Count -eq 1 -or [string]::IsNullOrWhiteSpace($OwnerNorm)) {
        return $Candidates[0]
    }

    foreach ($Candidate in $Candidates) {
        if ((Normalize-Token $Candidate.relativePath).Contains($OwnerNorm)) {
            return $Candidate
        }
    }

    return $Candidates[0]
}

function Get-FileKind([string]$Path) {
    $Ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    switch ($Ext) {
        ".cfg" { return "cfg" }
        ".ini" { return "cfg" }
        ".json" { return "json" }
        default { return "other" }
    }
}

function Get-CfgSettings([string]$Path) {
    $Settings = [System.Collections.Generic.List[object]]::new()
    $Section = ""

    foreach ($Line in [IO.File]::ReadAllLines($Path)) {
        $Trimmed = $Line.Trim()

        if ([string]::IsNullOrWhiteSpace($Trimmed)) {
            continue
        }
        if ($Trimmed.StartsWith("#") -or $Trimmed.StartsWith(";")) {
            continue
        }
        if ($Trimmed -match '^\[(.+)\]$') {
            $Section = $Matches[1].Trim()
            continue
        }
        if ($Line -match '^\s*([^#;][^=]*?)\s*=\s*(.*?)\s*$') {
            $Key = $Matches[1].Trim()
            $Value = $Matches[2]
            $FullKey = if ([string]::IsNullOrWhiteSpace($Section)) {
                $Key
            }
            else {
                "$Section.$Key"
            }

            [void]$Settings.Add([pscustomobject]@{
                key = $FullKey
                value = $Value
            })
        }
    }

    return @($Settings)
}

function Add-JsonSetting {
    param(
        [System.Collections.Generic.List[object]]$List,
        [string]$Key,
        [object]$Value
    )

    $Rendered = if ($null -eq $Value) {
        "null"
    }
    else {
        try {
            $Value | ConvertTo-Json -Compress -Depth 20
        }
        catch {
            [string]$Value
        }
    }

    [void]$List.Add([pscustomobject]@{
        key = $Key
        value = $Rendered
    })
}

function Walk-JsonValue {
    param(
        [System.Collections.Generic.List[object]]$List,
        [object]$Value,
        [string]$Path
    )

    if ($null -eq $Value) {
        Add-JsonSetting $List $Path $null
        return
    }

    if ($Value -is [string] -or $Value -is [ValueType]) {
        Add-JsonSetting $List $Path $Value
        return
    }

    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($Key in $Value.Keys) {
            $Child = if ([string]::IsNullOrWhiteSpace($Path)) { [string]$Key } else { "$Path.$Key" }
            Walk-JsonValue $List $Value[$Key] $Child
        }
        return
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        $Index = 0
        foreach ($Item in $Value) {
            $Child = "$Path[$Index]"
            Walk-JsonValue $List $Item $Child
            $Index++
        }
        return
    }

    $Properties = @($Value.PSObject.Properties | Where-Object {
        $_.MemberType -eq 'NoteProperty' -or $_.MemberType -eq 'Property'
    })

    if ($Properties.Count -eq 0) {
        Add-JsonSetting $List $Path $Value
        return
    }

    foreach ($Property in $Properties) {
        $Child = if ([string]::IsNullOrWhiteSpace($Path)) { $Property.Name } else { "$Path.$($Property.Name)" }
        Walk-JsonValue $List $Property.Value $Child
    }
}

function Get-JsonSettings([string]$Path) {
    $Settings = [System.Collections.Generic.List[object]]::new()
    try {
        $Value = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        Walk-JsonValue $Settings $Value ""
    }
    catch {
        return @()
    }
    return @($Settings)
}

function Get-ParsedSettings([string]$Path) {
    $Kind = Get-FileKind $Path
    switch ($Kind) {
        "cfg" { return @(Get-CfgSettings $Path) }
        "json" { return @(Get-JsonSettings $Path) }
        default { return @() }
    }
}

function Get-ConfigSnapshot {
    param(
        [string]$Root,
        [switch]$IncludeSettings
    )

    $Files = [System.Collections.Generic.List[object]]::new()

    foreach ($File in Get-ChildItem -LiteralPath $Root -File -Recurse -Force | Sort-Object FullName) {
        if (Is-ConfigBackup $File.Name) {
            continue
        }

        $Rel = $File.FullName.Substring($Root.Length).TrimStart("\")
        $Settings = @()
        if ($IncludeSettings) {
            $Settings = @(Get-ParsedSettings $File.FullName)
        }

        [void]$Files.Add([pscustomobject]@{
            path = $Rel
            sha256 = (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash
            size = $File.Length
            kind = Get-FileKind $File.FullName
            settings = $Settings
        })
    }

    return @($Files)
}

function To-PathMap([object[]]$Items) {
    $Map = @{}
    foreach ($Item in $Items) {
        $Map[[string]$Item.path] = $Item
    }
    return $Map
}

function Compare-ConfigSnapshots {
    param(
        [object[]]$Baseline,
        [object[]]$Current
    )

    $BaseMap = To-PathMap $Baseline
    $CurrentMap = To-PathMap $Current
    $Changes = [System.Collections.Generic.List[object]]::new()

    foreach ($Path in $CurrentMap.Keys | Sort-Object) {
        if (-not $BaseMap.ContainsKey($Path)) {
            [void]$Changes.Add([pscustomobject]@{
                status = "ADDED"
                path = $Path
                before = $null
                after = $CurrentMap[$Path]
            })
        }
        elseif ($BaseMap[$Path].sha256 -ne $CurrentMap[$Path].sha256) {
            [void]$Changes.Add([pscustomobject]@{
                status = "MODIFIED"
                path = $Path
                before = $BaseMap[$Path]
                after = $CurrentMap[$Path]
            })
        }
    }

    foreach ($Path in $BaseMap.Keys | Sort-Object) {
        if (-not $CurrentMap.ContainsKey($Path)) {
            [void]$Changes.Add([pscustomobject]@{
                status = "DELETED"
                path = $Path
                before = $BaseMap[$Path]
                after = $null
            })
        }
    }

    return @($Changes)
}

function Compare-LiveToPassover {
    $Live = @(Get-ConfigSnapshot $LiveConfigRoot)
    $Stored = @(Get-ConfigSnapshot $PassoverConfigRoot)
    return @(Compare-ConfigSnapshots $Stored $Live)
}

function Get-SettingsDiff {
    param(
        [object]$Before,
        [object]$After
    )

    $BeforeMap = @{}
    $AfterMap = @{}

    if ($null -ne $Before -and $null -ne $Before.settings) {
        foreach ($Setting in @($Before.settings)) {
            $BeforeMap[[string]$Setting.key] = [string]$Setting.value
        }
    }

    if ($null -ne $After -and $null -ne $After.settings) {
        foreach ($Setting in @($After.settings)) {
            $AfterMap[[string]$Setting.key] = [string]$Setting.value
        }
    }

    $Diffs = [System.Collections.Generic.List[object]]::new()

    foreach ($Key in $AfterMap.Keys | Sort-Object) {
        if (-not $BeforeMap.ContainsKey($Key)) {
            [void]$Diffs.Add([pscustomobject]@{
                status = "ADDED"
                key = $Key
                before = $null
                after = $AfterMap[$Key]
            })
        }
        elseif ($BeforeMap[$Key] -ne $AfterMap[$Key]) {
            [void]$Diffs.Add([pscustomobject]@{
                status = "CHANGED"
                key = $Key
                before = $BeforeMap[$Key]
                after = $AfterMap[$Key]
            })
        }
    }

    foreach ($Key in $BeforeMap.Keys | Sort-Object) {
        if (-not $AfterMap.ContainsKey($Key)) {
            [void]$Diffs.Add([pscustomobject]@{
                status = "REMOVED"
                key = $Key
                before = $BeforeMap[$Key]
                after = $null
            })
        }
    }

    return @($Diffs)
}

function Get-OverwriteDetections {
    param(
        [object[]]$ConfigChanges
    )

    $Detections = [System.Collections.Generic.List[object]]::new()

    foreach ($Change in $ConfigChanges) {
        $SettingDiffs = @(Get-SettingsDiff $Change.before $Change.after)
        $OverwriteDiffs = @($SettingDiffs | Where-Object {
            $_.status -eq "CHANGED" -or $_.status -eq "REMOVED"
        })

        $WholeFileDeleted = ($Change.status -eq "DELETED" -and $null -ne $Change.before)

        if ($WholeFileDeleted -or $OverwriteDiffs.Count -gt 0) {
            [void]$Detections.Add([pscustomobject]@{
                path = $Change.path
                fileStatus = $Change.status
                wholeFileDeleted = $WholeFileDeleted
                settingDiffs = $OverwriteDiffs
            })
        }
    }

    return @($Detections)
}

function Load-State {
    if (-not (Test-Path -LiteralPath $StateFile -PathType Leaf)) {
        return $null
    }

    try {
        return (Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json)
    }
    catch {
        Fail "Baseline state is unreadable: $StateFile"
    }
}

function Get-ModChanges {
    param(
        [object[]]$BaselineMods,
        [object[]]$CurrentMods
    )

    $BaseMap = @{}
    $CurrentMap = @{}

    foreach ($Mod in $BaselineMods) {
        $BaseMap[[string]$Mod.name] = $Mod
    }
    foreach ($Mod in $CurrentMods) {
        $CurrentMap[[string]$Mod.name] = $Mod
    }

    $Changes = [System.Collections.Generic.List[object]]::new()

    foreach ($Name in $CurrentMap.Keys | Sort-Object) {
        $Current = $CurrentMap[$Name]
        if (-not $BaseMap.ContainsKey($Name)) {
            [void]$Changes.Add([pscustomobject]@{
                type = "ADDED"
                name = $Name
                oldVersion = $null
                newVersion = [string]$Current.version
                oldEnabled = $null
                newEnabled = [bool]$Current.enabled
                current = $Current
            })
            continue
        }

        $Base = $BaseMap[$Name]
        if ([string]$Base.version -ne [string]$Current.version) {
            [void]$Changes.Add([pscustomobject]@{
                type = "VERSION"
                name = $Name
                oldVersion = [string]$Base.version
                newVersion = [string]$Current.version
                oldEnabled = [bool]$Base.enabled
                newEnabled = [bool]$Current.enabled
                current = $Current
            })
        }
        elseif ([bool]$Base.enabled -ne [bool]$Current.enabled) {
            [void]$Changes.Add([pscustomobject]@{
                type = "ENABLED"
                name = $Name
                oldVersion = [string]$Base.version
                newVersion = [string]$Current.version
                oldEnabled = [bool]$Base.enabled
                newEnabled = [bool]$Current.enabled
                current = $Current
            })
        }
    }

    foreach ($Name in $BaseMap.Keys | Sort-Object) {
        if (-not $CurrentMap.ContainsKey($Name)) {
            $Base = $BaseMap[$Name]
            [void]$Changes.Add([pscustomobject]@{
                type = "REMOVED"
                name = $Name
                oldVersion = [string]$Base.version
                newVersion = $null
                oldEnabled = [bool]$Base.enabled
                newEnabled = $null
                current = $null
            })
        }
    }

    return @($Changes)
}

function Get-VersionChangedMods([object[]]$ModChanges) {
    return @($ModChanges | Where-Object {
        $_.type -eq "VERSION" -or $_.type -eq "ADDED" -or $_.type -eq "REMOVED"
    })
}

function Get-ConfigNeedle([string]$RelativePath) {
    $Leaf = [IO.Path]::GetFileName($RelativePath)
    return [IO.Path]::GetFileNameWithoutExtension($Leaf)
}

function Get-ArchiveNeedleMatches {
    param(
        [string]$ArchivePath,
        [string[]]$Needles
    )

    $Found = @{}
    if ([string]::IsNullOrWhiteSpace($ArchivePath) -or -not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
        return $Found
    }

    $ValidNeedles = @($Needles | Where-Object {
        (Normalize-Token $_).Length -ge 5
    } | Select-Object -Unique)

    if ($ValidNeedles.Count -eq 0) {
        return $Found
    }

    $Zip = $null
    try {
        $Zip = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
        foreach ($Entry in $Zip.Entries) {
            if (-not $Entry.FullName.EndsWith(".dll", [StringComparison]::OrdinalIgnoreCase)) {
                continue
            }

            $Stream = $Entry.Open()
            $Memory = New-Object IO.MemoryStream
            try {
                $Stream.CopyTo($Memory)
                $Text = [Text.Encoding]::ASCII.GetString($Memory.ToArray())
                foreach ($Needle in $ValidNeedles) {
                    if ($Found.ContainsKey($Needle)) {
                        continue
                    }
                    if ($Text.IndexOf($Needle, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                        $Found[$Needle] = $true
                    }
                }
            }
            finally {
                $Memory.Dispose()
                $Stream.Dispose()
            }
        }
    }
    catch {
        return $Found
    }
    finally {
        if ($null -ne $Zip) {
            $Zip.Dispose()
        }
    }

    return $Found
}

function Build-OwnershipMap {
    param(
        [object[]]$ConfigChanges,
        [object[]]$UpdatedMods,
        [object[]]$CacheIndex
    )

    $Map = @{}
    $Needles = @($ConfigChanges | ForEach-Object { Get-ConfigNeedle $_.path } | Select-Object -Unique)

    foreach ($ModChange in $UpdatedMods) {
        if ($null -eq $ModChange.current) {
            continue
        }

        $Archive = Resolve-CacheArchive $ModChange.current $CacheIndex
        if ($null -eq $Archive) {
            continue
        }

        $Matches = Get-ArchiveNeedleMatches $Archive.fullPath $Needles
        foreach ($Needle in $Matches.Keys) {
            if (-not $Map.ContainsKey($Needle)) {
                $Map[$Needle] = [System.Collections.Generic.List[object]]::new()
            }
            [void]$Map[$Needle].Add([pscustomobject]@{
                name = $ModChange.name
                confidence = "CONFIRMED"
                reason = "Current package DLL contains the config identifier"
            })
        }
    }

    foreach ($Change in $ConfigChanges) {
        $Needle = Get-ConfigNeedle $Change.path
        if ($Map.ContainsKey($Needle)) {
            continue
        }

        $NeedleNorm = Normalize-Token $Needle
        $Candidates = [System.Collections.Generic.List[object]]::new()

        foreach ($ModChange in $UpdatedMods) {
            $Parts = Get-PackageParts $ModChange.name
            $FullNorm = Normalize-Token $ModChange.name
            $PackageNorm = Normalize-Token $Parts.package
            $OwnerNorm = Normalize-Token $Parts.owner

            $High = $false
            if ($PackageNorm.Length -ge 5 -and ($NeedleNorm.Contains($PackageNorm) -or $PackageNorm.Contains($NeedleNorm))) {
                $High = $true
            }
            elseif ($OwnerNorm.Length -ge 3 -and $PackageNorm.Length -ge 4 -and $NeedleNorm.Contains($OwnerNorm) -and $NeedleNorm.Contains($PackageNorm)) {
                $High = $true
            }
            elseif ($FullNorm.Length -ge 5 -and ($NeedleNorm.Contains($FullNorm) -or $FullNorm.Contains($NeedleNorm))) {
                $High = $true
            }

            if ($High) {
                [void]$Candidates.Add([pscustomobject]@{
                    name = $ModChange.name
                    confidence = "HIGH"
                    reason = "Config identifier matches the updated package name"
                })
            }
        }

        if ($Candidates.Count -eq 0 -and $UpdatedMods.Count -eq 1) {
            [void]$Candidates.Add([pscustomobject]@{
                name = $UpdatedMods[0].name
                confidence = "POSSIBLE"
                reason = "Only one package changed version during this baseline interval"
            })
        }

        if ($Candidates.Count -gt 0) {
            $Map[$Needle] = $Candidates
        }
    }

    return $Map
}

function Escape-Markdown([object]$Value) {
    if ($null -eq $Value) {
        return ""
    }
    $Text = [string]$Value
    $Text = $Text.Replace("`r", " ").Replace("`n", " ")
    $Text = $Text.Replace("|", "\|")
    return $Text
}

function Write-DetectionReport {
    param(
        [object]$State,
        [object[]]$CurrentMods,
        [object[]]$ModChanges,
        [object[]]$ConfigChanges,
        [object[]]$OverwriteDetections,
        [hashtable]$OwnershipMap
    )

    $Lines = [System.Collections.Generic.List[string]]::new()
    $Now = Format-DisplayTimestamp
    $UpdatedMods = @(Get-VersionChangedMods $ModChanges)

    [void]$Lines.Add("# Lethal Company Mod Update Report")
    [void]$Lines.Add("")
    [void]$Lines.Add("- Scan time: $Now")
    [void]$Lines.Add("- Profile: $ProfileName")
    [void]$Lines.Add("- Baseline captured: $(Format-DisplayTimestamp $State.capturedAt)")
    [void]$Lines.Add("- Installed packages now: $($CurrentMods.Count)")
    [void]$Lines.Add("- Package version/add/remove changes: $($UpdatedMods.Count)")
    [void]$Lines.Add("- Config file changes: $($ConfigChanges.Count)")
    [void]$Lines.Add("- Overwritten config files: $($OverwriteDetections.Count)")
    [void]$Lines.Add("")

    [void]$Lines.Add("## Package changes")
    [void]$Lines.Add("")
    if ($UpdatedMods.Count -eq 0) {
        [void]$Lines.Add("No package version/add/remove changes were detected.")
    }
    else {
        [void]$Lines.Add("| Package | Change | Before | After |")
        [void]$Lines.Add("|---|---|---:|---:|")
        foreach ($Change in $UpdatedMods) {
            $Before = Escape-Markdown $Change.oldVersion
            $After = Escape-Markdown $Change.newVersion
            [void]$Lines.Add("| $(Escape-Markdown $Change.name) | $($Change.type) | $Before | $After |")
        }
    }
    [void]$Lines.Add("")

    [void]$Lines.Add("## Config detections")
    [void]$Lines.Add("")
    [void]$Lines.Add("Any added, deleted, or byte-level modified config file appears here. This includes changes that do not overwrite a baseline setting value.")
    [void]$Lines.Add("")

    foreach ($Change in $ConfigChanges) {
        $Needle = Get-ConfigNeedle $Change.path
        [void]$Lines.Add("### $($Change.status): ``$($Change.path)``")
        [void]$Lines.Add("")

        if ($OwnershipMap.ContainsKey($Needle)) {
            foreach ($Owner in @($OwnershipMap[$Needle])) {
                [void]$Lines.Add("- Related updated package: **$($Owner.name)**")
                [void]$Lines.Add("- Match confidence: **$($Owner.confidence)** — $($Owner.reason)")
            }
        }
        else {
            [void]$Lines.Add("- Related updated package: unresolved")
            [void]$Lines.Add("- The file change itself is confirmed; package ownership was not guessed.")
        }

        $BeforeHash = if ($null -ne $Change.before) { [string]$Change.before.sha256 } else { "" }
        $AfterHash = if ($null -ne $Change.after) { [string]$Change.after.sha256 } else { "" }
        [void]$Lines.Add("- Baseline SHA256: ``$BeforeHash``")
        [void]$Lines.Add("- Current SHA256: ``$AfterHash``")

        $SettingDiffs = @(Get-SettingsDiff $Change.before $Change.after)
        if ($SettingDiffs.Count -gt 0) {
            [void]$Lines.Add("")
            [void]$Lines.Add("#### Parsed setting changes")
            [void]$Lines.Add("")
            [void]$Lines.Add("| Status | Setting | Before | After |")
            [void]$Lines.Add("|---|---|---|---|")
            foreach ($Diff in $SettingDiffs) {
                [void]$Lines.Add("| $($Diff.status) | ``$(Escape-Markdown $Diff.key)`` | ``$(Escape-Markdown $Diff.before)`` | ``$(Escape-Markdown $Diff.after)`` |")
            }
        }
        else {
            [void]$Lines.Add("")
            [void]$Lines.Add("No parsed CFG/INI/JSON setting value differences were found. The file still changed at the byte/content level.")
        }

        $PassoverCopy = Join-Path $PassoverConfigRoot $Change.path
        if ((Test-Path -LiteralPath $PassoverCopy -PathType Leaf) -and $null -ne $Change.before) {
            $PassoverHash = (Get-FileHash -LiteralPath $PassoverCopy -Algorithm SHA256).Hash
            [void]$Lines.Add("")
            if ($PassoverHash -eq [string]$Change.before.sha256) {
                [void]$Lines.Add("- Baseline before-copy: ``passover\profile\BepInEx\config\$($Change.path)``")
            }
            else {
                [void]$Lines.Add("- Passover warning: the current passover copy no longer matches the baseline hash; use the baseline settings recorded in ``data\mod-update-state.json`` for the old values.")
            }
        }

        [void]$Lines.Add("")
    }

    [void]$Lines.Add("## Overwritten detections")
    [void]$Lines.Add("")
    [void]$Lines.Add("These are the higher-priority detections: a baseline setting value changed, a baseline option disappeared, or an existing baseline config file was deleted.")
    [void]$Lines.Add("")

    if ($OverwriteDetections.Count -eq 0) {
        [void]$Lines.Add("No overwritten baseline settings were detected.")
    }
    else {
        foreach ($Detection in $OverwriteDetections) {
            [void]$Lines.Add("### ``$($Detection.path)``")
            [void]$Lines.Add("")

            if ($Detection.wholeFileDeleted) {
                [void]$Lines.Add("- **DELETED:** the entire baseline config file is gone.")
            }

            if (@($Detection.settingDiffs).Count -gt 0) {
                [void]$Lines.Add("| Status | Setting | Baseline | Current |")
                [void]$Lines.Add("|---|---|---|---|")
                foreach ($Diff in @($Detection.settingDiffs)) {
                    [void]$Lines.Add("| $($Diff.status) | ``$(Escape-Markdown $Diff.key)`` | ``$(Escape-Markdown $Diff.before)`` | ``$(Escape-Markdown $Diff.after)`` |")
                }
            }
            [void]$Lines.Add("")
        }
    }

    [void]$Lines.Add("## Recommended workflow")
    [void]$Lines.Add("")
    [void]$Lines.Add("1. Review/fix the detected config files, prioritizing Overwritten detections.")
    [void]$Lines.Add("2. Run ``update-n-passover.bat`` so the passover reflects the finalized setup.")
    [void]$Lines.Add("3. Use this checker's Update baseline option to accept the finalized setup and current mod versions.")
    [void]$Lines.Add("4. Commit/push the passover changes, then have Carter pull and apply them.")

    $Lines | Set-Content -LiteralPath $ReportFile -Encoding UTF8
}

function Save-Baseline {
    $CurrentMods = @(Get-CurrentMods)
    $Existing = Load-State
    $PendingModChanges = @()
    if ($null -ne $Existing) {
        $PendingModChanges = @(Get-ModChanges @($Existing.mods) $CurrentMods)
    }

    $PassoverConfigCount = @(
        Get-ChildItem -LiteralPath $PassoverConfigRoot -File -Recurse -Force |
            Where-Object { -not (Is-ConfigBackup $_.Name) }
    ).Count

    Clear-Host
    Write-Title "Update baseline"
    Write-Field "Profile" $ProfileName
    Write-Field "Packages" "$($CurrentMods.Count)"
    Write-Field "Config files" "$PassoverConfigCount"

    if ($PendingModChanges.Count -gt 0) {
        Write-Host ""
        Write-Status "Package drift" "$($PendingModChanges.Count) change(s) from current baseline" Yellow
    }

    $Confirm = Confirm-YesNo "Accept the current synced setup as the new baseline?"
    if ($null -eq $Confirm -or -not $Confirm) {
        return
    }

    Clear-Host
    Write-Title "Checking baseline"
    Write-Line "Verifying live configs match passover..." -NoPadding
    $PassoverDrift = @(Compare-LiveToPassover)
    if ($PassoverDrift.Count -gt 0) {
        Write-Host ""
        Write-Status "Baseline" "NOT UPDATED" Red
        Write-Status "Passover mismatch" "$($PassoverDrift.Count) config file(s)" Red
        Write-Line ""
        Write-Line "Live configs do not match the passover snapshot." -Color Red
        Write-Line "Finalize the configs and run update-n-passover.bat first." -Color Yellow
        Pause-AnyKey
        return
    }

    Clear-Host
    Write-Title "Updating baseline"
    Write-Line "Reading package state..." -NoPadding
    $CacheIndex = @(Get-CachePackageIndex)

    $StateMods = [System.Collections.Generic.List[object]]::new()
    foreach ($Mod in $CurrentMods) {
        $Archive = Resolve-CacheArchive $Mod $CacheIndex
        $Rel = if ($null -ne $Archive) { [string]$Archive.relativePath } else { $null }
        [void]$StateMods.Add([pscustomobject]@{
            name = $Mod.name
            version = $Mod.version
            enabled = [bool]$Mod.enabled
            cacheRelativePath = $Rel
        })
    }

    Write-Line "Hashing and indexing passover configs..." -NoPadding
    $ConfigFiles = @(Get-ConfigSnapshot $PassoverConfigRoot -IncludeSettings)

    $ManifestHash = $null
    if (Test-Path -LiteralPath $PassoverManifest -PathType Leaf) {
        $ManifestHash = (Get-FileHash -LiteralPath $PassoverManifest -Algorithm SHA256).Hash
    }

    $State = [ordered]@{
        schema = 1
        profile = $ProfileName
        capturedAt = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssK")
        packageCount = $StateMods.Count
        enabledCount = @($StateMods | Where-Object { $_.enabled }).Count
        disabledCount = @($StateMods | Where-Object { -not $_.enabled }).Count
        cacheRoot = "%APPDATA%\Thunderstore Mod Manager\DataFolder\LethalCompany\cache"
        passoverConfigRoot = "passover\profile\BepInEx\config"
        passoverManifestSha256 = $ManifestHash
        mods = @($StateMods)
        configFiles = $ConfigFiles
    }

    $State | ConvertTo-Json -Depth 24 | Set-Content -LiteralPath $StateFile -Encoding UTF8

    Write-Host ""
    Write-Status "Baseline" "UPDATED" Green
    Write-Status "Packages" "$($StateMods.Count)" Cyan
    Write-Status "Config files" "$($ConfigFiles.Count)" Cyan
    Write-Field "State file" (Format-DisplayPath $StateFile) Cyan
    Pause-AnyKey
}

function Show-Inventory {
    $Search = ""

    while ($true) {
        $Mods = @(Get-CurrentMods)
        $EnabledAll = @($Mods | Where-Object { $_.enabled } | Sort-Object name)
        $DisabledAll = @($Mods | Where-Object { -not $_.enabled } | Sort-Object name)

        $Enabled = $EnabledAll
        $Disabled = $DisabledAll
        if (-not [string]::IsNullOrWhiteSpace($Search)) {
            $Enabled = @($EnabledAll | Where-Object { $_.name -like "*$Search*" })
            $Disabled = @($DisabledAll | Where-Object { $_.name -like "*$Search*" })
        }

        Clear-Host
        Write-Title "Mod inventory"
        Write-Field "Installed" "$($Mods.Count)"
        Write-Field "Enabled" "$($EnabledAll.Count)"
        Write-Field "Disabled" "$($DisabledAll.Count)"
        if (-not [string]::IsNullOrWhiteSpace($Search)) {
            Write-Field "Search" $Search Cyan
        }

        Write-Section "Packages"
        Write-Host ""

        $WindowWidth = 120
        try {
            if ([Console]::WindowWidth -gt 40) {
                $WindowWidth = [Console]::WindowWidth
            }
        }
        catch {}

        $Available = [Math]::Max(60, $WindowWidth - $Pad.Length - 4)
        $ColumnWidth = [Math]::Floor(($Available - 4) / 2)
        if ($ColumnWidth -gt 58) { $ColumnWidth = 58 }
        if ($ColumnWidth -lt 26) { $ColumnWidth = 26 }

        Write-Pad
        Write-Host -NoNewline (("ENABLED ({0})" -f $Enabled.Count).PadRight($ColumnWidth)) -ForegroundColor Green
        Write-Host -NoNewline "    "
        Write-Host (("DISABLED ({0})" -f $Disabled.Count).PadRight($ColumnWidth)) -ForegroundColor Red

        $Rows = [Math]::Max($Enabled.Count, $Disabled.Count)
        for ($i = 0; $i -lt $Rows; $i++) {
            $Left = if ($i -lt $Enabled.Count) { [string]$Enabled[$i].name } else { "" }
            $Right = if ($i -lt $Disabled.Count) { [string]$Disabled[$i].name } else { "" }

            if ($Left.Length -gt ($ColumnWidth - 1)) {
                $Left = $Left.Substring(0, $ColumnWidth - 2) + "…"
            }
            if ($Right.Length -gt ($ColumnWidth - 1)) {
                $Right = $Right.Substring(0, $ColumnWidth - 2) + "…"
            }

            Write-Pad
            Write-Host -NoNewline $Left.PadRight($ColumnWidth) -ForegroundColor White
            Write-Host -NoNewline "    "
            Write-Host $Right.PadRight($ColumnWidth) -ForegroundColor White
        }

        Write-Host ""
        Write-Option "s" "Search"
        if (-not [string]::IsNullOrWhiteSpace($Search)) {
            Write-Option "c" "Clear search"
        }
        Write-Option "q" "Exit"

        $Allowed = @("s", "q")
        if (-not [string]::IsNullOrWhiteSpace($Search)) {
            $Allowed += "c"
        }

        $Choice = Read-OneKey -Allowed $Allowed -AllowEscape
        if ($Choice -eq "ESC") {
            return "back"
        }
        if ($Choice -eq "q") {
            return "exit"
        }
        if ($Choice -eq "c") {
            $Search = ""
            continue
        }
        if ($Choice -eq "s") {
            Write-Host ""
            $Query = Read-LineEsc
            if ($null -ne $Query) {
                $Search = $Query.Trim()
            }
        }
    }
}

function Export-ModIndex {
    Clear-Host
    Write-Title "Export mod index"
    Write-Line "Reading Thunderstore package inventory..." -NoPadding

    $Mods = @(Get-CurrentMods)
    $CacheIndex = @(Get-CachePackageIndex)
    $Lines = [System.Collections.Generic.List[string]]::new()
    $Now = Format-DisplayTimestamp
    $Enabled = @($Mods | Where-Object { $_.enabled }).Count
    $Disabled = $Mods.Count - $Enabled

    [void]$Lines.Add("# Lethal Company Mod Index")
    [void]$Lines.Add("")
    [void]$Lines.Add("- Exported: $Now")
    [void]$Lines.Add("- Profile: $ProfileName")
    [void]$Lines.Add("- Profile path: ``$Profile``")
    [void]$Lines.Add("- mods.yml: ``$ModsYml``")
    [void]$Lines.Add("- Cache root: ``$CacheRoot``")
    [void]$Lines.Add("- Installed: $($Mods.Count)")
    [void]$Lines.Add("- Enabled: $Enabled")
    [void]$Lines.Add("- Disabled: $Disabled")
    [void]$Lines.Add("")
    [void]$Lines.Add("| State | Package | Version | Package source/cache path |")
    [void]$Lines.Add("|---|---|---:|---|")

    $FoundCount = 0
    foreach ($Mod in $Mods) {
        $Archive = Resolve-CacheArchive $Mod $CacheIndex
        $Source = "Not found in current Thunderstore cache"
        if ($null -ne $Archive) {
            $Source = "%APPDATA%\Thunderstore Mod Manager\DataFolder\LethalCompany\cache\$($Archive.relativePath)"
            $FoundCount++
        }
        $State = if ($Mod.enabled) { "Enabled" } else { "Disabled" }
        [void]$Lines.Add("| $State | $(Escape-Markdown $Mod.name) | $($Mod.version) | ``$(Escape-Markdown $Source)`` |")
    }

    $Lines | Set-Content -LiteralPath $IndexFile -Encoding UTF8

    Write-Host ""
    Write-Status "Export" "COMPLETE" Green
    Write-Status "Packages" "$($Mods.Count)" Cyan
    Write-Status "Cache paths found" "$FoundCount" Cyan
    Write-Status "Index file" (Format-DisplayPath $IndexFile) Cyan
    Pause-AnyKey
}

function Run-DetectionScan {
    $State = Load-State
    if ($null -eq $State) {
        Clear-Host
        Write-Title "Detection scan"
        Write-Status "Baseline" "MISSING" Red
        Write-Line "Create the initial baseline with [4] before using detection scans." -Color Yellow
        Pause-AnyKey
        return
    }

    Clear-Host
    Write-Title "Detection scan"
    Write-Line "Reading current package versions..." -NoPadding
    $CurrentMods = @(Get-CurrentMods)
    $ModChanges = @(Get-ModChanges @($State.mods) $CurrentMods)
    $UpdatedMods = @(Get-VersionChangedMods $ModChanges)

    Write-Line "Hashing current configs..." -NoPadding
    $CurrentConfigBasic = @(Get-ConfigSnapshot $LiveConfigRoot)
    $ConfigChangesBasic = @(Compare-ConfigSnapshots @($State.configFiles) $CurrentConfigBasic)

    $ConfigChanges = [System.Collections.Generic.List[object]]::new()
    foreach ($Change in $ConfigChangesBasic) {
        $Before = $Change.before
        $After = $Change.after

        if ($null -ne $After) {
            $LivePath = Join-Path $LiveConfigRoot $Change.path
            $After = [pscustomobject]@{
                path = $After.path
                sha256 = $After.sha256
                size = $After.size
                kind = $After.kind
                settings = @(Get-ParsedSettings $LivePath)
            }
        }

        [void]$ConfigChanges.Add([pscustomobject]@{
            status = $Change.status
            path = $Change.path
            before = $Before
            after = $After
        })
    }

    $OverwriteDetections = @(Get-OverwriteDetections @($ConfigChanges))

    $OwnershipMap = @{}
    if ($ConfigChanges.Count -gt 0 -and $UpdatedMods.Count -gt 0) {
        Write-Line "Correlating changed configs to updated packages..." -NoPadding
        $CacheIndex = @(Get-CachePackageIndex)
        $OwnershipMap = Build-OwnershipMap @($ConfigChanges) $UpdatedMods $CacheIndex
    }

    Clear-Host
    Write-Title "Detection results"
    Write-Status "Package changes" "$($ModChanges.Count)" $(if ($ModChanges.Count -gt 0) { [ConsoleColor]::Yellow } else { [ConsoleColor]::Green })
    Write-Status "Version/add/remove" "$($UpdatedMods.Count)" $(if ($UpdatedMods.Count -gt 0) { [ConsoleColor]::Yellow } else { [ConsoleColor]::Green })
    Write-Status "Config detections" "$($ConfigChanges.Count)" $(if ($ConfigChanges.Count -gt 0) { [ConsoleColor]::Yellow } else { [ConsoleColor]::Green })
    Write-Status "Overwritten detections" "$($OverwriteDetections.Count)" $(if ($OverwriteDetections.Count -gt 0) { [ConsoleColor]::Red } else { [ConsoleColor]::Green })

    if ($UpdatedMods.Count -gt 0) {
        Write-Section "Package version changes"
        foreach ($Change in $UpdatedMods) {
            if ($Change.type -eq "VERSION") {
                Write-Pad
                Write-Host -NoNewline $Change.name -ForegroundColor White
                Write-Host -NoNewline "  "
                Write-Host -NoNewline $Change.oldVersion -ForegroundColor DarkGray
                Write-Host -NoNewline " -> " -ForegroundColor Yellow
                Write-Host $Change.newVersion -ForegroundColor Yellow
            }
            elseif ($Change.type -eq "ADDED") {
                Write-Status "ADDED" "$($Change.name) $($Change.newVersion)" Cyan
            }
            elseif ($Change.type -eq "REMOVED") {
                Write-Status "REMOVED" "$($Change.name) $($Change.oldVersion)" Red
            }
        }
    }

    if ($ConfigChanges.Count -gt 0) {
        Write-Section "Config detections"
        foreach ($Change in $ConfigChanges) {
            $Color = if ($Change.status -eq "ADDED") { [ConsoleColor]::Cyan } elseif ($Change.status -eq "MODIFIED") { [ConsoleColor]::Yellow } else { [ConsoleColor]::Red }
            Write-Status $Change.status $Change.path $Color

            $Needle = Get-ConfigNeedle $Change.path
            if ($OwnershipMap.ContainsKey($Needle)) {
                foreach ($Owner in @($OwnershipMap[$Needle])) {
                    $OwnerColor = if ($Owner.confidence -eq "CONFIRMED") { [ConsoleColor]::Green } elseif ($Owner.confidence -eq "HIGH") { [ConsoleColor]::Cyan } else { [ConsoleColor]::Yellow }
                    Write-Pad
                    Write-Host -NoNewline "   related: " -ForegroundColor DarkGray
                    Write-Host -NoNewline $Owner.name -ForegroundColor $OwnerColor
                    Write-Host " [$($Owner.confidence)]" -ForegroundColor DarkGray
                }
            }
        }

        if ($OverwriteDetections.Count -gt 0) {
            Write-Section "Overwritten detections"
            foreach ($Detection in $OverwriteDetections) {
                Write-Status "OVERWRITTEN" $Detection.path Red
                if ($Detection.wholeFileDeleted) {
                    Write-Pad
                    Write-Host "   entire baseline config file deleted" -ForegroundColor Red
                }
                foreach ($Diff in @($Detection.settingDiffs)) {
                    $DiffColor = if ($Diff.status -eq "REMOVED") { [ConsoleColor]::Red } else { [ConsoleColor]::Yellow }
                    Write-Pad
                    Write-Host -NoNewline "   $($Diff.status): " -ForegroundColor $DiffColor
                    Write-Host -NoNewline $Diff.key -ForegroundColor White
                    Write-Host -NoNewline "  "
                    Write-Host -NoNewline ([string]$Diff.before) -ForegroundColor DarkGray
                    Write-Host -NoNewline " -> " -ForegroundColor $DiffColor
                    Write-Host ([string]$Diff.after) -ForegroundColor $DiffColor
                }
            }
        }

        Write-DetectionReport $State $CurrentMods $ModChanges @($ConfigChanges) @($OverwriteDetections) $OwnershipMap
        Write-Host ""
        Write-Status "Report" "CREATED" Cyan
        Write-Field "Report file" (Format-DisplayPath $ReportFile) Cyan
    }
    else {
        if (Test-Path -LiteralPath $ReportFile -PathType Leaf) {
            Remove-Item -LiteralPath $ReportFile -Force
        }

        Write-Host ""
        Write-Status "Configs" "NO CHANGES DETECTED" Green
        if ($UpdatedMods.Count -gt 0) {
            Write-Line "If the game has not been launched since those mod updates, launch it once and scan again before accepting a new baseline." -Color Yellow
        }
    }

    if (@($ModChanges | Where-Object { $_.type -eq "ENABLED" }).Count -gt 0) {
        Write-Section "Enabled / disabled changes"
        foreach ($Change in @($ModChanges | Where-Object { $_.type -eq "ENABLED" })) {
            $Before = if ($Change.oldEnabled) { "Enabled" } else { "Disabled" }
            $After = if ($Change.newEnabled) { "Enabled" } else { "Disabled" }
            Write-Status $Change.name "$Before -> $After" Yellow
        }
    }

    Pause-AnyKey
}

function Show-MainMenu {
    while ($true) {
        $Mods = @(Get-CurrentMods)
        $Enabled = @($Mods | Where-Object { $_.enabled }).Count
        $Disabled = $Mods.Count - $Enabled
        $State = Load-State

        Clear-Host
        Write-Title "Lethal Company Mod Update Checker"
        Write-Field "Profile" $ProfileName
        Write-Field "Installed" "$($Mods.Count)"
        Write-Field "Enabled" "$Enabled"
        Write-Field "Disabled" "$Disabled"

        if ($null -eq $State) {
            Write-Field "Baseline" "Missing"
        }
        else {
            Write-Field "Baseline" "Ready"
            Write-Field "Captured" (Format-DisplayTimestamp $State.capturedAt)
            Write-Field "Baseline configs" "$(@($State.configFiles).Count)"
        }

        Write-Section "Options"
        Write-Option "1" "View mod inventory"
        Write-Option "2" "Export mod index"
        Write-Option "3" "Scan for mod/config changes"
        Write-Option "4" "Update baseline"
        Write-Option "q" "Exit"
        Write-Host ""
        Write-Pad
        Write-Host -NoNewline ">" -ForegroundColor White

        $Choice = Read-OneKey -Allowed @("1", "2", "3", "4", "q")
        Write-Host ""

        switch ($Choice) {
            "1" {
                $Result = Show-Inventory
                if ($Result -eq "exit") {
                    return
                }
            }
            "2" { Export-ModIndex }
            "3" { Run-DetectionScan }
            "4" { Save-Baseline }
            "q" { return }
        }
    }
}

try {
    Ensure-CorePaths
    Show-MainMenu
}
catch {
    Write-Host ""
    Write-Host "ERROR" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ""
    Write-Host -NoNewline "Press any key to continue..." -ForegroundColor DarkGray
    [void][Console]::ReadKey($true)
    exit 1
}
