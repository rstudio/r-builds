param(
    [Parameter(Mandatory=$true)]
    [string]$RHome
)

$ErrorActionPreference = "Stop"
# Suppress the PS 5.1 progress bar during package downloads.
$ProgressPreference = "SilentlyContinue"

$Pass = 0
$Fail = 0

function Test-Pass($msg) { Write-Host "  PASS: $msg"; $script:Pass++ }
function Test-Fail($msg) { Write-Host "  FAIL: $msg"; $script:Fail++ }

Write-Host "=== Testing Windows R at $RHome ==="

Write-Host "--- Layout ---"
foreach ($p in @("bin\R.exe","bin\Rscript.exe","bin\x64\R.exe","bin\x64\Rscript.exe","bin\x64\Rterm.exe")) {
    $full = Join-Path $RHome $p
    if (Test-Path $full) { Write-Host "  present: $p" } else { Write-Host "  missing: $p" }
}

# R < 4.2 on Windows: bin\R.exe and bin\Rscript.exe are Rfe.exe launchers
# that re-assemble argv into a cmd.exe string without escaping quotes
# (src/gnuwin32/front-ends/Rfe.c), silently truncating -e expressions.
# bin\x64\R.exe is the real binary. R 4.2+ puts real binaries in bin\.
$x64RExe = Join-Path $RHome "bin\x64\R.exe"
if (Test-Path $x64RExe) {
    $RExe = $x64RExe
} else {
    $RExe = Join-Path $RHome "bin\R.exe"
}
Write-Host "  using: $RExe"

# R.exe -f <path> avoids the Windows Rfe argv-quoting bug present in R < 4.2:
# R reads the file directly instead of needing -e "..." reassembled by cmd.exe.
function Invoke-RExpr {
    param(
        [string]$Binary,
        [string]$Expression
    )
    $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) ("rtest-" + [System.Guid]::NewGuid().ToString() + ".R")
    [System.IO.File]::WriteAllText($tempFile, $Expression, (New-Object System.Text.UTF8Encoding $false))
    try {
        $ErrorActionPreference = "Continue"
        $output = & $Binary --vanilla --slave -f $tempFile 2>&1
        $exit = $LASTEXITCODE
        $ErrorActionPreference = "Stop"
        return [pscustomobject]@{ Output = $output; ExitCode = $exit }
    } finally {
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-StdoutLine {
    param($Result)
    $Result.Output | Where-Object {
        $_ -is [string] -and $_ -notmatch "^(Error|Warning|trying URL|Content type|downloaded|installing|package |\s*$)"
    } | Select-Object -First 1
}

# ── 1. R starts ─────────────────────────────────────────────────────
# Released R reports "R version X.Y.Z (...)"; devel reports "R Under
# development (unstable) (YYYY-MM-DD rXXXXX) ...". Match both.
Write-Host "--- Test: R starts ---"
$ErrorActionPreference = "Continue"
$rVersion = & $RExe --version 2>&1 | Select-Object -First 1
$ErrorActionPreference = "Stop"
if ("$rVersion" -match "^R (version|Under development)") {
    Test-Pass "R --version reports R version"
} else {
    Test-Fail "R --version failed: $rVersion"
}

# ── 2. R_HOME ───────────────────────────────────────────────────────
Write-Host "--- Test: R_HOME ---"
$r = Invoke-RExpr -Binary $RExe -Expression "cat(normalizePath(R.home(), winslash='/'))"
$reported = Get-StdoutLine -Result $r
$expected = (Resolve-Path $RHome).Path -replace '\\', '/'
if ("$reported" -eq $expected) {
    Test-Pass "R.home() matches expected"
} else {
    Test-Fail "R.home() = '$reported' (exit $($r.ExitCode)), expected '$expected'"
}

# ── 3. Expression evaluation ────────────────────────────────────────
Write-Host "--- Test: R -f expression ---"
$r = Invoke-RExpr -Binary $RExe -Expression "cat('hello')"
$out = Get-StdoutLine -Result $r
if ("$out" -eq "hello") {
    Test-Pass "R evaluates expressions"
} else {
    Test-Fail "R -f output: '$out' (exit $($r.ExitCode))"
}

# ── 4. Relocatability ───────────────────────────────────────────────
Write-Host "--- Test: Relocatability ---"
$movedDir = "$env:TEMP\r-relocated-test"
if (Test-Path $movedDir) { Remove-Item $movedDir -Recurse -Force }
Copy-Item $RHome -Destination $movedDir -Recurse
$movedX64 = Join-Path $movedDir "bin\x64\R.exe"
if (Test-Path $movedX64) {
    $movedRExe = $movedX64
} else {
    $movedRExe = Join-Path $movedDir "bin\R.exe"
}
$r = Invoke-RExpr -Binary $movedRExe -Expression "cat('relocated OK')"
$movedOut = Get-StdoutLine -Result $r
if ("$movedOut" -eq "relocated OK") {
    Test-Pass "relocated R works"
} else {
    Test-Fail "relocated R failed: '$movedOut' (exit $($r.ExitCode))"
}
Remove-Item $movedDir -Recurse -Force

# ── 5. Base Rprofile hooks survive --vanilla ────────────────────────
# Invoke-RExpr always passes --vanilla, so this run also proves the hooks
# survive --vanilla (the whole reason we use the base Rprofile rather than
# etc/Rprofile.site, which --vanilla skips). Asserts:
#   - default CRAN repo is p3m.dev (PPM)
#   - the portable site-library is on .libPaths() pointing into R_HOME
Write-Host "--- Test: Base Rprofile hooks under --vanilla ---"
$hookExpr = @'
cat("repo=", getOption("repos")["CRAN"], "\n", sep="")
site_lib <- file.path(Sys.getenv("R_HOME"), "site-library")
cat("site_lib_on_path=", normalizePath(site_lib, mustWork=FALSE) %in% normalizePath(.libPaths(), mustWork=FALSE), "\n", sep="")
'@
$hookResult = Invoke-RExpr -Binary $RExe -Expression $hookExpr
$hookOut = $hookResult.Output | Out-String
if ($hookOut -match "repo=https://p3m\.dev/") {
    Test-Pass "default CRAN repo set to p3m.dev under --vanilla"
} else {
    Test-Fail "default CRAN repo not p3m.dev under --vanilla"
    $hookOut -split "`n" | Where-Object { $_ -match "^repo=" } | ForEach-Object { Write-Host "    $_" }
}
if ($hookOut -match "site_lib_on_path=TRUE") {
    Test-Pass "portable site-library on .libPaths() under --vanilla"
} else {
    Test-Fail "portable site-library not on .libPaths() under --vanilla"
    $hookOut -split "`n" | Where-Object { $_ -match "^site_lib_on_path=" } | ForEach-Object { Write-Host "    $_" }
}

# ── 6. Binary package install ────────────────────────────────────────
# Use Posit Package Manager because CRAN's Windows contrib/3.6/ is empty
# (CRAN only keeps installers for old R, not compiled packages). PPM serves
# Windows binaries for every R minor from 3.6 onward.
Write-Host "--- Test: Binary package install ---"
$pkgExpr = @'
tmp <- tempdir()
install.packages("jsonlite", repos = "https://packagemanager.posit.co/cran/latest", lib = tmp, quiet = TRUE)
stopifnot(requireNamespace("jsonlite", lib.loc = tmp))
cat("pkg OK")
'@
$r = Invoke-RExpr -Binary $RExe -Expression $pkgExpr
$pkgStr = ($r.Output | Out-String)
if ($pkgStr -match "pkg OK") {
    Test-Pass "binary package install (jsonlite)"
} else {
    Test-Fail "binary package install failed (exit $($r.ExitCode))"
    Write-Host "---- install output (first 20 lines) ----"
    $r.Output | Select-Object -First 20 | ForEach-Object { Write-Host "    $_" }
}

# ── Summary ──────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=== Results: $Pass passed, $Fail failed ==="
if ($Fail -gt 0) { exit 1 }
