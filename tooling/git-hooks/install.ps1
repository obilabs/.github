# Install the ObiLabs hygiene git hooks on Windows by running install.sh with
# Git for Windows' bundled sh. Arguments are passed through (repo dirs to check).
#
#   powershell -ExecutionPolicy Bypass -File tooling\git-hooks\install.ps1 [repo-dir ...]

$ErrorActionPreference = 'Stop'

$git = Get-Command git -ErrorAction SilentlyContinue
if (-not $git) { throw 'git was not found on PATH. Install Git for Windows first.' }

# git.exe lives in <GitRoot>\cmd or <GitRoot>\bin; sh.exe lives in <GitRoot>\bin.
$gitRoot = Split-Path (Split-Path $git.Source -Parent) -Parent
$sh = Join-Path $gitRoot 'bin\sh.exe'
if (-not (Test-Path $sh)) {
    $found = Get-Command sh -ErrorAction SilentlyContinue
    if (-not $found) { throw "Could not find Git's sh.exe (looked in $gitRoot\bin and on PATH)." }
    $sh = $found.Source
}

$script = Join-Path $PSScriptRoot 'install.sh'
& $sh $script @args
exit $LASTEXITCODE
