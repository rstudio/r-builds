param(
    [Parameter(Mandatory=$true)]
    [string]$Version,

    [string]$OutputDir = "output"
)

$ErrorActionPreference = "Stop"
# Suppress the PS 5.1 progress bar; it slows Invoke-WebRequest / Expand-Archive
# by 50-100x when running non-interactively.
$ProgressPreference = "SilentlyContinue"
$StagingDir = "$env:TEMP\r-build\R-$Version"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir

try {

Write-Host "=== Building R $Version for Windows ==="

Write-Host "--- Downloading CRAN installer ---"
$InstallerPath = "$env:TEMP\R-$Version-win.exe"
if (Test-Path $InstallerPath) {
    Write-Host "  Using cached installer: $InstallerPath"
} else {
    if ($Version -eq "devel") {
        $InstallerUrl = "https://cloud.r-project.org/bin/windows/base/R-devel-win.exe"
        Write-Host "  Downloading: $InstallerUrl"
        Invoke-WebRequest -Uri $InstallerUrl -OutFile $InstallerPath -UseBasicParsing
    } else {
        $CurrentUrl = "https://cloud.r-project.org/bin/windows/base/R-$Version-win.exe"
        $ArchiveUrl = "https://cloud.r-project.org/bin/windows/base/old/$Version/R-$Version-win.exe"
        Write-Host "  Trying current URL: $CurrentUrl"
        try {
            Invoke-WebRequest -Uri $CurrentUrl -OutFile $InstallerPath -UseBasicParsing
            $InstallerUrl = $CurrentUrl
        } catch {
            Write-Host "  Current URL failed, trying archive URL: $ArchiveUrl"
            Invoke-WebRequest -Uri $ArchiveUrl -OutFile $InstallerPath -UseBasicParsing
            $InstallerUrl = $ArchiveUrl
        }
    }
    Write-Host "  Downloaded: $InstallerPath"
}

Write-Host "--- Extracting installer ---"
if (Test-Path $StagingDir) { Remove-Item $StagingDir -Recurse -Force }
New-Item -ItemType Directory -Path $StagingDir -Force | Out-Null

$extracted = $false

# Primary method: innoextract (fast, no side effects, no admin)
$innoextract = Get-Command innoextract -ErrorAction SilentlyContinue
if (-not $innoextract) {
    # Try choco first
    $choco = Get-Command choco -ErrorAction SilentlyContinue
    if ($choco) {
        Write-Host "  Installing innoextract via choco..."
        choco install innoextract -y --no-progress 2>&1 | Out-Null
        $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH", "User")
        $innoextract = Get-Command innoextract -ErrorAction SilentlyContinue
    }
    # Fallback: download innoextract from GitHub releases
    if (-not $innoextract) {
        Write-Host "  Downloading innoextract from GitHub..."
        $innoDir = Join-Path $env:TEMP "innoextract"
        New-Item -ItemType Directory -Path $innoDir -Force | Out-Null
        $innoZip = Join-Path $env:TEMP "innoextract.zip"
        Invoke-WebRequest -Uri "https://github.com/dscharrer/innoextract/releases/download/1.9/innoextract-1.9-windows.zip" -OutFile $innoZip -UseBasicParsing
        Expand-Archive -Path $innoZip -DestinationPath $innoDir -Force
        $innoExe = Get-ChildItem -Path $innoDir -Recurse -Filter "innoextract.exe" | Select-Object -First 1
        if ($innoExe) {
            $env:PATH = "$($innoExe.DirectoryName);$env:PATH"
        }
        $innoextract = Get-Command innoextract -ErrorAction SilentlyContinue
    }
}

if ($innoextract) {
    Write-Host "  Extracting with innoextract..."
    $output = & innoextract -d $StagingDir --extract $InstallerPath 2>&1
    if ($LASTEXITCODE -eq 0) {
        $AppDir = Join-Path $StagingDir "app"
        if (Test-Path $AppDir) {
            Get-ChildItem $AppDir | Move-Item -Destination $StagingDir -Force
            Remove-Item $AppDir -Force -ErrorAction SilentlyContinue
        }
        $extracted = $true
        Write-Host "  Extracted with innoextract to: $StagingDir"
    } else {
        Write-Host "  innoextract failed (exit $LASTEXITCODE), falling back to silent install..."
        if (Test-Path $StagingDir) { Remove-Item $StagingDir -Recurse -Force }
        New-Item -ItemType Directory -Path $StagingDir -Force | Out-Null
    }
}

# Fallback: run the Inno Setup installer silently (aligns with portable-r-windows)
if (-not $extracted) {
    Write-Host "  Using silent install fallback (/VERYSILENT /DIR=...)..."
    $proc = Start-Process -PassThru -FilePath $InstallerPath -ArgumentList @(
        "/VERYSILENT",
        "/SUPPRESSMSGBOXES",
        "/CURRENTUSER",
        "/NOICONS",
        "/DIR=$StagingDir"
    )
    $finished = $proc.WaitForExit(600000)  # 10 minute timeout
    if (-not $finished) {
        $proc.Kill()
        throw "Silent install timed out after 10 minutes"
    }
    if ($proc.ExitCode -ne 0) {
        throw "Installer exited with code $($proc.ExitCode)"
    }
    # Clean up installer artifacts left by silent install
    Remove-Item -Path (Join-Path $StagingDir "unins*.exe") -Force -ErrorAction SilentlyContinue
    Remove-Item -Path (Join-Path $StagingDir "unins*.dat") -Force -ErrorAction SilentlyContinue
    Remove-Item -Path (Join-Path $StagingDir "unins*.msg") -Force -ErrorAction SilentlyContinue
    Write-Host "  Extracted via silent install to: $StagingDir"
}

Write-Host "--- Cleaning up installer artifacts ---"
Get-ChildItem $StagingDir -Filter "unins*" | Remove-Item -Force -ErrorAction SilentlyContinue
Get-ChildItem $StagingDir -Filter "*.iss" | Remove-Item -Force -ErrorAction SilentlyContinue
Write-Host "  Removed installer artifacts"

Write-Host "--- Configuring Rprofile.site ---"
$RprofilePath = Join-Path $StagingDir "etc\Rprofile.site"

$RprofileContent = @"
# Rprofile.site -- rstudio/r-builds portable R distribution

# Portable package library: install packages within this R directory
local_lib <- file.path(Sys.getenv("R_HOME"), "site-library")
if (!dir.exists(local_lib)) dir.create(local_lib, recursive = TRUE)
.libPaths(c(local_lib, .libPaths()))

# Default repository: Posit Package Manager
local({
  r <- getOption("repos")
  r["CRAN"] <- "https://packagemanager.posit.co/cran/latest"
  options(repos = r)
})
"@
[System.IO.File]::WriteAllText($RprofilePath, $RprofileContent, (New-Object System.Text.UTF8Encoding $false))
Write-Host "  Rprofile.site configured"

Write-Host "--- Packaging ---"
$OutputPath = Join-Path $RepoRoot $OutputDir
if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath | Out-Null }
$ZipName = "R-$Version-windows.zip"
$ZipPath = Join-Path $OutputPath $ZipName

if (Test-Path $ZipPath) { Remove-Item $ZipPath }
Compress-Archive -Path $StagingDir -DestinationPath $ZipPath
Write-Host "=== Package created: $ZipPath ==="
Get-Item $ZipPath | Select-Object Name, Length

} finally {
    # Keep the installer cached at $InstallerPath so re-runs of the same R
    # version skip the ~80 MB download (see the "Using cached installer" branch
    # above). Only the staging tree is removed.
    Remove-Item $StagingDir -Recurse -Force -ErrorAction SilentlyContinue
}
