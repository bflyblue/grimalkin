[CmdletBinding()]
param(
    [string] $DownloadDirectory,
    [string] $ToolchainDirectory
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$defaultBuildDirectory = Join-Path $PSScriptRoot '..\build\windows'
if (-not $DownloadDirectory) {
    $downloadRoot = if ($env:GRIMALKIN_WINDOWS_CACHE_DIR) {
        $env:GRIMALKIN_WINDOWS_CACHE_DIR
    } else {
        $defaultBuildDirectory
    }
    $DownloadDirectory = Join-Path $downloadRoot 'downloads'
}
if (-not $ToolchainDirectory) {
    $toolchainRoot = if ($env:GRIMALKIN_WINDOWS_CACHE_DIR) {
        $env:GRIMALKIN_WINDOWS_CACHE_DIR
    } else {
        $defaultBuildDirectory
    }
    $ToolchainDirectory = Join-Path $toolchainRoot 'toolchains'
}

$odinVersion = 'dev-2026-07a'
$odinArchiveName = "odin-windows-amd64-$odinVersion.zip"
$odinUrl = "https://github.com/odin-lang/Odin/releases/download/$odinVersion/$odinArchiveName"
$odinSha256 = 'cfe09f1c086b29d12158f14d6772a775ecc2b842119f8ff5a78e62a5cb656cf8'

$vulkanVersion = '1.4.350.0'
$vulkanUrl = "https://sdk.lunarg.com/sdk/download/$vulkanVersion/windows/vulkan_sdk.exe"
$vulkanSha256 = '855b27ba05d2d8119c5114c5d4ff870ca38f2c632b11e1bb9923b9b7e6ecfe7b'

$nsisVersion = '3.12'
# SourceForge's generic endpoint can return an HTML mirror-selection page to
# non-browser clients. MacPorts provides the same archive at a direct URL.
$nsisUrl = "https://distfiles.macports.org/nsis/nsis-$nsisVersion.zip"
$nsisSha256 = '56581f90db321581c5381193d796fffcf2d24b2f8fed2160a6c6a3baa67f2c4f'

function Get-VerifiedDownload {
    param(
        [Parameter(Mandatory)] [string] $Uri,
        [Parameter(Mandatory)] [string] $Destination,
        [Parameter(Mandatory)] [string] $Sha256
    )

    if (Test-Path -LiteralPath $Destination) {
        $existingHash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
        if ($existingHash -ieq $Sha256) {
            Write-Host "Using verified cached download $Destination"
            return
        }
        Write-Warning "Discarding cached download with the wrong checksum: $Destination"
        Remove-Item -LiteralPath $Destination -Force
    }

    foreach ($attempt in 1..3) {
        try {
            Write-Host "Downloading $Uri (attempt $attempt of 3)"
            Invoke-WebRequest -Uri $Uri -OutFile $Destination
            $downloadedHash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
            if ($downloadedHash -ine $Sha256) {
                throw "Checksum mismatch. Expected $Sha256, received $downloadedHash."
            }
            return
        } catch {
            if (Test-Path -LiteralPath $Destination) {
                Remove-Item -LiteralPath $Destination -Force
            }
            if ($attempt -eq 3) {
                throw "Unable to download and verify $Uri after 3 attempts: $_"
            }
            Start-Sleep -Seconds (5 * $attempt)
        }
    }
}

function Add-ReleasePath {
    param([Parameter(Mandatory)] [string] $Path)

    $env:PATH = "$Path;$env:PATH"
    if ($env:GITHUB_PATH) {
        $Path | Out-File -FilePath $env:GITHUB_PATH -Encoding utf8 -Append
    }
}

function Export-ReleaseEnvironment {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Value
    )

    Set-Item -Path "Env:$Name" -Value $Value
    if ($env:GITHUB_ENV) {
        "$Name=$Value" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
    }
}

New-Item -ItemType Directory -Path $DownloadDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $ToolchainDirectory -Force | Out-Null

$odinArchive = Join-Path $DownloadDirectory $odinArchiveName
$odinRoot = Join-Path $ToolchainDirectory $odinVersion
Get-VerifiedDownload -Uri $odinUrl -Destination $odinArchive -Sha256 $odinSha256
$odinExecutable = Get-ChildItem -LiteralPath $odinRoot -Recurse -Filter odin.exe -ErrorAction SilentlyContinue |
    Select-Object -First 1
if (-not $odinExecutable) {
    if (Test-Path -LiteralPath $odinRoot) {
        Remove-Item -LiteralPath $odinRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $odinRoot | Out-Null
    Expand-Archive -LiteralPath $odinArchive -DestinationPath $odinRoot
    $odinExecutable = Get-ChildItem -LiteralPath $odinRoot -Recurse -Filter odin.exe |
        Select-Object -First 1
}
if (-not $odinExecutable) {
    throw "The Odin archive did not contain odin.exe: $odinArchive"
}
Add-ReleasePath -Path $odinExecutable.DirectoryName

$nsisArchive = Join-Path $DownloadDirectory "nsis-$nsisVersion.zip"
$nsisRoot = Join-Path $ToolchainDirectory "nsis-$nsisVersion"
Get-VerifiedDownload -Uri $nsisUrl -Destination $nsisArchive -Sha256 $nsisSha256
$makeNsis = Get-ChildItem -LiteralPath $nsisRoot -Recurse -Filter makensis.exe -ErrorAction SilentlyContinue |
    Select-Object -First 1
if (-not $makeNsis) {
    if (Test-Path -LiteralPath $nsisRoot) {
        Remove-Item -LiteralPath $nsisRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $nsisRoot | Out-Null
    Expand-Archive -LiteralPath $nsisArchive -DestinationPath $nsisRoot
    $makeNsis = Get-ChildItem -LiteralPath $nsisRoot -Recurse -Filter makensis.exe |
        Select-Object -First 1
}
if (-not $makeNsis) {
    throw "The NSIS archive did not contain makensis.exe: $nsisArchive"
}
Add-ReleasePath -Path $makeNsis.DirectoryName

$vulkanInstaller = Join-Path $DownloadDirectory "vulkan-sdk-$vulkanVersion.exe"
$vulkanRoot = "C:\VulkanSDK\$vulkanVersion"
$glslc = Join-Path $vulkanRoot 'Bin\glslc.exe'
Get-VerifiedDownload -Uri $vulkanUrl -Destination $vulkanInstaller -Sha256 $vulkanSha256
if (-not (Test-Path -LiteralPath $glslc)) {
    Write-Host "Installing Vulkan SDK $vulkanVersion"
    $vulkanProcess = Start-Process -FilePath $vulkanInstaller -Wait -PassThru -ArgumentList @(
        '--accept-licenses',
        '--default-answer',
        '--confirm-command',
        'install'
    )
    if ($vulkanProcess.ExitCode -ne 0) {
        throw "Vulkan SDK installer failed with exit code $($vulkanProcess.ExitCode)."
    }
}
if (-not (Test-Path -LiteralPath $glslc)) {
    throw "Vulkan SDK installation did not create $glslc"
}
Export-ReleaseEnvironment -Name VULKAN_SDK -Value $vulkanRoot
Add-ReleasePath -Path (Join-Path $vulkanRoot 'Bin')

$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$vcpkgManifest = Get-Content -LiteralPath (Join-Path $projectRoot 'vcpkg.json') -Raw |
    ConvertFrom-Json
$vcpkgBaseline = $vcpkgManifest.'builtin-baseline'
if ($vcpkgBaseline -notmatch '^[0-9a-f]{40}$') {
    throw 'vcpkg.json does not contain a valid builtin-baseline.'
}
$vcpkgRoot = Join-Path $ToolchainDirectory 'vcpkg'
if (-not (Test-Path -LiteralPath (Join-Path $vcpkgRoot '.git'))) {
    if (Test-Path -LiteralPath $vcpkgRoot) {
        Remove-Item -LiteralPath $vcpkgRoot -Recurse -Force
    }
    git init --quiet $vcpkgRoot
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to initialize the vcpkg checkout (exit code $LASTEXITCODE)."
    }
    git -C $vcpkgRoot remote add origin https://github.com/microsoft/vcpkg.git
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to configure the vcpkg remote (exit code $LASTEXITCODE)."
    }
}
git -C $vcpkgRoot fetch --depth 1 origin $vcpkgBaseline
if ($LASTEXITCODE -ne 0) {
    throw "Unable to fetch vcpkg baseline $vcpkgBaseline (exit code $LASTEXITCODE)."
}
git -C $vcpkgRoot checkout --quiet --detach FETCH_HEAD
if ($LASTEXITCODE -ne 0) {
    throw "Unable to check out vcpkg baseline $vcpkgBaseline (exit code $LASTEXITCODE)."
}
$vcpkgBootstrap = Join-Path $vcpkgRoot 'bootstrap-vcpkg.bat'
& $vcpkgBootstrap -disableMetrics
if ($LASTEXITCODE -ne 0) {
    throw "Unable to bootstrap vcpkg (exit code $LASTEXITCODE)."
}
Export-ReleaseEnvironment -Name VCPKG_ROOT -Value $vcpkgRoot
if ($env:VCPKG_DEFAULT_BINARY_CACHE) {
    New-Item -ItemType Directory -Path $env:VCPKG_DEFAULT_BINARY_CACHE -Force | Out-Null
}

Write-Host "Odin: $($odinExecutable.FullName)"
Write-Host "NSIS: $($makeNsis.FullName)"
Write-Host "Vulkan SDK: $vulkanRoot"
Write-Host "vcpkg: $vcpkgRoot ($vcpkgBaseline)"
