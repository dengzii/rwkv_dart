$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

dart run tool/build.dart @args
exit $LASTEXITCODE
