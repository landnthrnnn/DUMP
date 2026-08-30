Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoUrl = "https://github.com/landnthrnnn/DUMP.git"
$SparsePath = "misc/my-lethal-company-mod-setup"

function Fail {
    param([string]$Message)
    throw $Message
}

function Refresh-ProcessPath {
    $machine = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $user = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = (($machine, $user) -join ";").Trim(";")
}

function Find-GitExe {
    $cmd = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    $candidates = @(
        (Join-Path $env:ProgramFiles "Git\cmd\git.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "Git\cmd\git.exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\Git\cmd\git.exe")
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) }

    $candidates = @($candidates)

    if ($candidates.Count -gt 0) {
        return $candidates[0]
    }

    return $null
}

function Ensure-GitOnUserPath {
    param([string]$GitExe)

    $gitDir = Split-Path $GitExe -Parent
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")

    $allEntries = @()
    if ($userPath) {
        $allEntries += $userPath -split ";"
    }

    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    if ($machinePath) {
        $allEntries += $machinePath -split ";"
    }

    $alreadyPresent = $false
    foreach ($entry in $allEntries) {
        if (-not [string]::IsNullOrWhiteSpace($entry)) {
            try {
                if ([IO.Path]::GetFullPath($entry.TrimEnd("\")) -ieq [IO.Path]::GetFullPath($gitDir)) {
                    $alreadyPresent = $true
                    break
                }
            }
            catch {
                # Ignore malformed PATH entries.
            }
        }
    }

    if (-not $alreadyPresent) {
        $newUserPath = if ([string]::IsNullOrWhiteSpace($userPath)) {
            $gitDir
        }
        else {
            $userPath.TrimEnd(";") + ";" + $gitDir
        }

        [Environment]::SetEnvironmentVariable("Path", $newUserPath, "User")
        Write-Host "Added Git to the user PATH."
    }

    Refresh-ProcessPath
}

function Install-GitIfNeeded {
    Refresh-ProcessPath
    $gitExe = Find-GitExe
    if ($gitExe) {
        Write-Host "Git already installed: $gitExe"
        Ensure-GitOnUserPath $gitExe
        return $gitExe
    }

    Write-Host "Git not found. Installing Git for Windows..."

    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) {
        Fail "winget is not available. Install Microsoft's App Installer or Git for Windows manually, then rerun setup."
    }

    $wingetExe = $winget.Source

    & $wingetExe install `
        --id Git.Git `
        --exact `
        --source winget `
        --scope user `
        --silent `
        --accept-source-agreements `
        --accept-package-agreements | Out-Host

    $installExitCode = $LASTEXITCODE
    if ($installExitCode -ne 0) {
        Write-Host "User-scope install did not succeed; retrying the standard Git installer..."

        & $wingetExe install `
            --id Git.Git `
            --exact `
            --source winget `
            --silent `
            --accept-source-agreements `
            --accept-package-agreements | Out-Host

        $installExitCode = $LASTEXITCODE
        if ($installExitCode -ne 0) {
            Fail "Git installation failed."
        }
    }

    Refresh-ProcessPath
    $gitExe = Find-GitExe

    if (-not $gitExe) {
        Fail "Git installed, but git.exe could not be located."
    }

    Ensure-GitOnUserPath $gitExe
    Write-Host "Git installed: $gitExe"
    return $gitExe
}

try {
    Write-Host ""
    Write-Host "============================================"
    Write-Host " CARTER / LANDON INITIAL SYNC SETUP"
    Write-Host "============================================"
    Write-Host ""

    $gitExe = Install-GitIfNeeded

    $documents = [Environment]::GetFolderPath("MyDocuments")
    $defaultRoot = Join-Path $documents "LethalCompany-CarterSync"

    Write-Host ""
    $answer = Read-Host "Install sync repo here? [$defaultRoot]"
    $repoRoot = if ([string]::IsNullOrWhiteSpace($answer)) {
        $defaultRoot
    }
    else {
        [Environment]::ExpandEnvironmentVariables($answer.Trim().Trim('"'))
    }

    $repoRoot = [IO.Path]::GetFullPath($repoRoot)
    $projectRoot = Join-Path $repoRoot "misc\my-lethal-company-mod-setup"

    Write-Host ""
    Write-Host "Repo root: $repoRoot"
    Write-Host "Visible sync project: $projectRoot"
    Write-Host ""

    if (Test-Path -LiteralPath $repoRoot) {
        $gitDir = Join-Path $repoRoot ".git"

        if (-not (Test-Path -LiteralPath $gitDir)) {
            $items = @(Get-ChildItem -LiteralPath $repoRoot -Force -ErrorAction SilentlyContinue)
            if ($items.Count -gt 0) {
                Fail "Install location already exists and is not an empty Git repo: $repoRoot"
            }
        }
    }
    else {
        New-Item -ItemType Directory -Path (Split-Path $repoRoot -Parent) -Force | Out-Null
    }

    if (-not (Test-Path -LiteralPath (Join-Path $repoRoot ".git"))) {
        Write-Host "Creating sparse checkout..."

        & $gitExe clone `
            --filter=blob:none `
            --no-checkout `
            --single-branch `
            --branch main `
            $RepoUrl `
            $repoRoot

        if ($LASTEXITCODE -ne 0) {
            Fail "Git clone failed."
        }

        & $gitExe -C $repoRoot sparse-checkout init --cone
        if ($LASTEXITCODE -ne 0) {
            Fail "Sparse-checkout initialization failed."
        }

        & $gitExe -C $repoRoot sparse-checkout set $SparsePath
        if ($LASTEXITCODE -ne 0) {
            Fail "Sparse-checkout path setup failed."
        }

        & $gitExe -C $repoRoot checkout main
        if ($LASTEXITCODE -ne 0) {
            Fail "Checking out main failed."
        }
    }
    else {
        Write-Host "Existing Git repo found. Verifying it..."

        $remote = ((@(& $gitExe -C $repoRoot remote get-url origin 2>$null) -join "`n").Trim())
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($remote)) {
            Fail "Existing repo has no readable origin remote."
        }

        if ($remote -notmatch '(?i)github\.com[:/]+landnthrnnn/DUMP(?:\.git)?$') {
            Fail "Existing repo points to an unexpected origin: $remote"
        }

        & $gitExe -C $repoRoot sparse-checkout init --cone
        if ($LASTEXITCODE -ne 0) {
            Fail "Could not enable sparse checkout."
        }

        & $gitExe -C $repoRoot sparse-checkout set $SparsePath
        if ($LASTEXITCODE -ne 0) {
            Fail "Could not set the sparse checkout path."
        }

        $branch = ((@(& $gitExe -C $repoRoot branch --show-current) -join "`n").Trim())
        if ($branch -ne "main") {
            & $gitExe -C $repoRoot checkout main
            if ($LASTEXITCODE -ne 0) {
                Fail "Could not switch the existing repo to main."
            }
        }

        & $gitExe -C $repoRoot pull --ff-only origin main
        if ($LASTEXITCODE -ne 0) {
            Fail "Could not fast-forward the existing repo."
        }
    }

    $required = @(
        (Join-Path $projectRoot "carter-tools\pull-in.bat"),
        (Join-Path $projectRoot "carter-tools\scripts\pull-in.ps1"),
        (Join-Path $projectRoot "carter-tools\update.bat"),
        (Join-Path $projectRoot "carter-tools\scripts\update.ps1"),
        (Join-Path $projectRoot "passover"),
        (Join-Path $projectRoot "passover\profile-configs-n-customs.json")
    )

    foreach ($path in $required) {
        if (-not (Test-Path -LiteralPath $path)) {
            Fail "Setup verification failed; missing: $path"
        }
    }

    $head = ((@(& $gitExe -C $repoRoot rev-parse HEAD) -join "`n").Trim())

    Write-Host ""
    Write-Host "============================================"
    Write-Host " SETUP COMPLETE"
    Write-Host "============================================"
    Write-Host ""
    Write-Host "Git: $gitExe"
    Write-Host "Commit: $head"
    Write-Host "Carter tools:"
    Write-Host "  $(Join-Path $projectRoot 'carter-tools\pull-in.bat')"
    Write-Host "  $(Join-Path $projectRoot 'carter-tools\update.bat')"
    Write-Host ""
    Write-Host "Future workflow:"
    Write-Host "  1. Run pull-in.bat"
    Write-Host "  2. Run update.bat"
    Write-Host ""
    Write-Host "No GitHub login is required for this public read-only clone."
    exit 0
}
catch {
    Write-Host ""
    Write-Host "============================================"
    Write-Host " SETUP FAILED"
    Write-Host "============================================"
    Write-Host ""
    Write-Host $_.Exception.Message
    exit 1
}
