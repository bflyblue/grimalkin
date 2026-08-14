[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Release',

    [ValidateSet('grimalkin', 'grimalkin_tests', 'grimalkin_ci', 'grimalkin_environment')]
    [string] $Target = 'grimalkin'
)

$ErrorActionPreference = 'Stop'
$projectRoot = $PSScriptRoot
$buildDirectory = Join-Path $projectRoot 'build/windows'

$vcpkgRoots = @(
    @(
        $env:VCPKG_ROOT,
        $env:VCPKG_INSTALLATION_ROOT,
        'C:\vcpkg',
        'C:\Program Files\Microsoft Visual Studio\2022\Enterprise\VC\vcpkg',
        'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\vcpkg',
        'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\vcpkg'
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
)

if (-not $vcpkgRoots) {
    throw 'vcpkg was not found. Install the Visual Studio vcpkg component or set VCPKG_ROOT.'
}

$vcpkgRoot = $vcpkgRoots[0]
$toolchain = Join-Path $vcpkgRoot 'scripts/buildsystems/vcpkg.cmake'
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$developerCommandPrompt = $null
if (Test-Path -LiteralPath $vswhere) {
    $visualStudioRoot = & $vswhere -latest -products * `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath
    if ($visualStudioRoot) {
        $developerCommandPrompt = Join-Path $visualStudioRoot 'Common7\Tools\VsDevCmd.bat'
    }
}
if (-not $developerCommandPrompt) {
    $developerCommandPrompt = @(
        'C:\Program Files\Microsoft Visual Studio\2022\Enterprise\Common7\Tools\VsDevCmd.bat',
        'C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\Tools\VsDevCmd.bat',
        'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\Tools\VsDevCmd.bat'
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}
if (-not $developerCommandPrompt -or -not (Test-Path -LiteralPath $developerCommandPrompt)) {
    throw 'The Visual Studio C++ developer command prompt was not found.'
}

$developerEnvironment = cmd.exe /d /s /c "`"$developerCommandPrompt`" -no_logo -arch=x64 -host_arch=x64 && set"
foreach ($entry in $developerEnvironment) {
    $separator = $entry.IndexOf('=')
    if ($separator -gt 0) {
        $name = $entry.Substring(0, $separator)
        $value = $entry.Substring($separator + 1)
        if ($name -notmatch '^Path$') {
            [Environment]::SetEnvironmentVariable($name, $value, 'Process')
        }
    }
}
$developerPath = $developerEnvironment |
    Where-Object { $_ -match '^Path=' } |
    Sort-Object Length -Descending |
    Select-Object -First 1
if (-not $developerPath) {
    throw 'The Visual Studio developer environment did not provide PATH.'
}
$env:PATH = $developerPath.Substring($developerPath.IndexOf('=') + 1)

function Reset-RelocatedCMakeCache {
    param([Parameter(Mandatory)] [string] $Root)

    if (-not (Test-Path -LiteralPath $Root)) {
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
        return
    }

    $cacheFiles = Get-ChildItem -LiteralPath $Root -Filter CMakeCache.txt -Recurse -File -ErrorAction SilentlyContinue
    foreach ($cacheFile in $cacheFiles) {
        $location = Select-String -LiteralPath $cacheFile.FullName `
            -Pattern '^CMAKE_CACHEFILE_DIR:INTERNAL=(.+)$' |
            Select-Object -First 1
        if (-not $location) {
            continue
        }

        $recordedDirectory = [System.IO.Path]::GetFullPath($location.Matches[0].Groups[1].Value)
        $actualDirectory = $cacheFile.Directory.FullName
        if (-not [string]::Equals(
                $recordedDirectory.TrimEnd('\', '/'),
                $actualDirectory.TrimEnd('\', '/'),
                [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-Warning "Discarding relocated CMake FetchContent cache: $Root"
            Remove-Item -LiteralPath $Root -Recurse -Force
            New-Item -ItemType Directory -Path $Root -Force | Out-Null
            return
        }
    }
}

$ninjaCandidates = @(
    @(
        (Get-Command ninja.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source),
        'C:\Program Files\Microsoft Visual Studio\2022\Enterprise\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe',
        'C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe',
        'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe'
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
)

if (-not $ninjaCandidates) {
    throw 'Ninja was not found. Install the C++ CMake tools for Windows Visual Studio component.'
}

$cmakeArguments = @(
    '-S', $projectRoot,
    '-B', $buildDirectory,
    '-G', 'Ninja',
    "-DCMAKE_MAKE_PROGRAM=$($ninjaCandidates[0])",
    '-DCMAKE_C_COMPILER=cl.exe',
    "-DCMAKE_TOOLCHAIN_FILE=$toolchain",
    '-DVCPKG_TARGET_TRIPLET=x64-windows',
    '-DCMAKE_TRY_COMPILE_CONFIGURATION=Release',
    "-DCMAKE_BUILD_TYPE=$Configuration"
)
if ($env:GRIMALKIN_WINDOWS_CACHE_DIR) {
    $fetchContentDirectory = Join-Path $env:GRIMALKIN_WINDOWS_CACHE_DIR '_deps'
    Reset-RelocatedCMakeCache -Root $fetchContentDirectory
    $cmakeArguments += "-DFETCHCONTENT_BASE_DIR=$fetchContentDirectory"
}

cmake @cmakeArguments
if ($LASTEXITCODE -ne 0) {
    throw "CMake configure failed with exit code $LASTEXITCODE."
}

$cmakeTarget = if ($Target -eq 'grimalkin_environment') { 'ghostty_vt' } else { $Target }
cmake --build $buildDirectory --target $cmakeTarget
if ($LASTEXITCODE -ne 0) {
    throw "CMake build failed with exit code $LASTEXITCODE."
}

if ($Target -eq 'grimalkin_environment') {
    Write-Host 'Prepared native Windows build environment.'
} elseif ($Target -eq 'grimalkin_tests') {
    Write-Host 'All Grimalkin tests passed.'
} elseif ($Target -eq 'grimalkin_ci') {
    Write-Host 'All Grimalkin tests passed and the native application was built.'
} else {
    Write-Host "Built $buildDirectory\bin\grimalkin.exe"
}
