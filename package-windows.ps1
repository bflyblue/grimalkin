[CmdletBinding()]
param(
    [ValidateSet('ZIP', 'NSIS', 'All')]
    [string] $Format = 'All'
)

$ErrorActionPreference = 'Stop'
$projectRoot = $PSScriptRoot
$buildDirectory = Join-Path $projectRoot 'build/windows'
$packageDirectory = Join-Path $buildDirectory 'packages'
$nsisCandidates = @(
    (Get-Command makensis.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source),
    'C:\Program Files (x86)\NSIS\makensis.exe',
    'C:\Program Files\NSIS\makensis.exe'
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

if ($nsisCandidates) {
    $nsisDirectory = Split-Path -Parent $nsisCandidates[0]
    $env:PATH = "$nsisDirectory;$env:PATH"
}

& (Join-Path $projectRoot 'build-windows.ps1') -Configuration Release -Target grimalkin
if ($LASTEXITCODE -ne 0) {
    throw "Windows release build failed with exit code $LASTEXITCODE."
}

if (-not (Test-Path -LiteralPath $packageDirectory)) {
    New-Item -ItemType Directory -Path $packageDirectory | Out-Null
}

$generators = if ($Format -eq 'All') { @('ZIP', 'NSIS') } else { @($Format) }
foreach ($generator in $generators) {
    if ($generator -eq 'NSIS' -and -not $nsisCandidates) {
        if ($Format -eq 'NSIS') {
            throw 'NSIS was requested but makensis.exe was not found. Install NSIS.NSIS with WinGet.'
        }
        Write-Warning 'NSIS is not installed; produced the portable ZIP only. Install NSIS.NSIS with WinGet to build the installer.'
        continue
    }

    & cpack --config (Join-Path $buildDirectory 'CPackConfig.cmake') `
        -G $generator -B $packageDirectory
    if ($LASTEXITCODE -ne 0) {
        throw "$generator packaging failed with exit code $LASTEXITCODE."
    }
}

Write-Host "Windows packages are in $packageDirectory"
