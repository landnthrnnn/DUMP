Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Fail {
    param([string]$Message)
    throw $Message
}

try {
    Write-Host ""
    Write-Host "============================================"
    Write-Host " CARTER / LANDON REPO PULL"
    Write-Host "============================================"
    Write-Host ""

    $Git = Get-Command git -ErrorAction SilentlyContinue
    if (-not $Git) {
        Fail "Git was not found in PATH. Install Git for Windows first."
    }

    $CarterTools = Split-Path $PSScriptRoot -Parent

    $RepoRoot = (& git -C $CarterTools rev-parse --show-toplevel 2>$null).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($RepoRoot)) {
        Fail "This carter-tools folder is not inside the DUMP Git repository."
    }

    $Remote = (& git -C $RepoRoot remote get-url origin 2>$null).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($Remote)) {
        Fail "Could not read the Git origin remote."
    }

    if ($Remote -notmatch '(?i)github\.com[:/]+landnthrnnn/DUMP(?:\.git)?$') {
        Fail "Unexpected Git origin remote: $Remote"
    }

    $Branch = (& git -C $RepoRoot branch --show-current).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($Branch)) {
        Fail "Could not determine the current Git branch."
    }

    if ($Branch -ne "main") {
        Fail "Expected branch 'main', found '$Branch'."
    }

    & git -C $RepoRoot diff --quiet
    if ($LASTEXITCODE -ne 0) {
        Fail "Tracked local changes exist in the repository. Pull stopped."
    }

    & git -C $RepoRoot diff --cached --quiet
    if ($LASTEXITCODE -ne 0) {
        Fail "Staged local changes exist in the repository. Pull stopped."
    }

    $Before = (& git -C $RepoRoot rev-parse HEAD).Trim()

    Write-Host "Repository: $RepoRoot"
    Write-Host "Pulling latest main..."
    Write-Host ""

    & git -C $RepoRoot pull --ff-only origin main
    if ($LASTEXITCODE -ne 0) {
        Fail "git pull failed."
    }

    $After = (& git -C $RepoRoot rev-parse HEAD).Trim()

    Write-Host ""
    if ($Before -eq $After) {
        Write-Host "ALREADY UP TO DATE"
    }
    else {
        Write-Host "PULL COMPLETE"
        Write-Host "Old commit: $Before"
        Write-Host "New commit: $After"
    }

    Write-Host ""
    Write-Host "Now run update.bat to apply the pulled sync payload."
    exit 0
}
catch {
    Write-Host ""
    Write-Host "============================================"
    Write-Host " PULL FAILED"
    Write-Host "============================================"
    Write-Host ""
    Write-Host $_.Exception.Message
    exit 1
}
