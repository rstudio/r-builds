param(
    [Parameter(Mandatory=$true)]
    [string]$RHome
)

$ErrorActionPreference = "Stop"
$Pass = 0
$Fail = 0

function Test-Pass($msg) { Write-Host "  PASS: $msg"; $script:Pass++ }
function Test-Fail($msg) { Write-Host "  FAIL: $msg"; $script:Fail++ }

Write-Host "=== Testing Windows R at $RHome ==="

# Set R_HOME so older R versions (< 4.2) can locate their installation.
# R 4.2+ auto-detects from the executable path; older versions need this.
$env:R_HOME = $RHome

# R < 4.2 on Windows uses bin/x64/ for the real binaries; bin/R.exe is a
# front-end launcher that depends on registry. R 4.2+ puts binaries in bin/.
$x64Rscript = Join-Path $RHome "bin\x64\Rscript.exe"
$x64RExe = Join-Path $RHome "bin\x64\R.exe"
if (Test-Path $x64Rscript) {
    $Rscript = $x64Rscript
    $RExe = $x64RExe
} else {
    $Rscript = Join-Path $RHome "bin\Rscript.exe"
    $RExe = Join-Path $RHome "bin\R.exe"
}

# ── 1. R starts ─────────────────────────────────────────────────────
Write-Host "--- Test: R starts ---"
$ErrorActionPreference = "Continue"
$rVersion = & $RExe --version 2>&1 | Select-Object -First 1
$ErrorActionPreference = "Stop"
if ("$rVersion" -match "R version") {
    Test-Pass "R --version reports R version"
} else {
    Test-Fail "R --version failed: $rVersion"
}

# ── 2. R_HOME ───────────────────────────────────────────────────────
Write-Host "--- Test: R_HOME ---"
$ErrorActionPreference = "Continue"
$reported = & $Rscript -e "cat(normalizePath(R.home(), winslash='/'))" 2>&1 | Where-Object { $_ -is [string] -and $_ -notmatch "^Error" } | Select-Object -First 1
$ErrorActionPreference = "Stop"
$expected = (Resolve-Path $RHome).Path -replace '\\', '/'
if ("$reported" -eq $expected) {
    Test-Pass "R.home() matches expected"
} else {
    Test-Fail "R.home() = '$reported', expected '$expected'"
}

# ── 3. Rscript ──────────────────────────────────────────────────────
Write-Host "--- Test: Rscript ---"
$ErrorActionPreference = "Continue"
$out = & $Rscript -e "cat('hello')" 2>&1 | Where-Object { $_ -is [string] -and $_ -notmatch "^Error" } | Select-Object -First 1
$ErrorActionPreference = "Stop"
if ("$out" -eq "hello") {
    Test-Pass "Rscript works"
} else {
    Test-Fail "Rscript output: '$out'"
}

# ── 4. Relocatability ───────────────────────────────────────────────
Write-Host "--- Test: Relocatability ---"
$movedDir = "$env:TEMP\r-relocated-test"
if (Test-Path $movedDir) { Remove-Item $movedDir -Recurse -Force }
$oldRHome = $env:R_HOME
try {
    $env:R_HOME = $movedDir
    Copy-Item $RHome -Destination $movedDir -Recurse
    $movedX64 = Join-Path $movedDir "bin\x64\Rscript.exe"
    if (Test-Path $movedX64) {
        $movedRscript = $movedX64
    } else {
        $movedRscript = Join-Path $movedDir "bin\Rscript.exe"
    }
    $ErrorActionPreference = "Continue"
    $movedOut = & $movedRscript -e "cat('relocated OK')" 2>&1 | Where-Object { $_ -is [string] -and $_ -notmatch "^Error" } | Select-Object -First 1
    $ErrorActionPreference = "Stop"
    if ("$movedOut" -eq "relocated OK") {
        Test-Pass "relocated R works"
    } else {
        Test-Fail "relocated R failed: '$movedOut'"
    }
} finally {
    $env:R_HOME = $oldRHome
    Remove-Item $movedDir -Recurse -Force -ErrorAction SilentlyContinue
}

# ── 5. Binary package install ────────────────────────────────────────
Write-Host "--- Test: Binary package install ---"
$ErrorActionPreference = "Continue"
$pkgResult = & $Rscript -e "tmp <- tempdir(); install.packages('jsonlite', repos='https://cloud.r-project.org', lib=tmp, quiet=TRUE); stopifnot(requireNamespace('jsonlite', lib.loc=tmp)); cat('pkg OK')" 2>&1
$ErrorActionPreference = "Stop"
$pkgStr = ($pkgResult | Out-String)
if ($pkgStr -match "pkg OK") {
    Test-Pass "binary package install (jsonlite)"
} else {
    Test-Fail "binary package install failed"
}

# ── Summary ──────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=== Results: $Pass passed, $Fail failed ==="
if ($Fail -gt 0) { exit 1 }
