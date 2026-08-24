[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $Version,

    [string] $PackageDirectory = (Join-Path $PSScriptRoot '..\build\windows\packages')
)

$ErrorActionPreference = 'Stop'
$installer = Join-Path $PackageDirectory "grimalkin-$Version-windows-x64.exe"
if (-not (Test-Path -LiteralPath $installer)) {
    throw "Windows installer was not created: $installer"
}

function Get-PeMachine {
    param([Parameter(Mandatory)] [string] $Path)

    $stream = [System.IO.File]::OpenRead($Path)
    $reader = [System.IO.BinaryReader]::new($stream)
    try {
        if ($reader.ReadUInt16() -ne 0x5a4d) {
            throw "$Path does not have a DOS executable header."
        }
        $stream.Position = 0x3c
        $peOffset = $reader.ReadUInt32()
        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550) {
            throw "$Path does not have a PE executable header."
        }
        return $reader.ReadUInt16()
    } finally {
        $reader.Dispose()
        $stream.Dispose()
    }
}

$installDirectory = Join-Path $env:RUNNER_TEMP "grimalkin-installer-test-$PID"
$installProcess = Start-Process -FilePath $installer -Wait -PassThru -ArgumentList @(
    '/S',
    "/D=$installDirectory"
)
if ($installProcess.ExitCode -ne 0) {
    throw "Silent installer test failed with exit code $($installProcess.ExitCode)."
}

$requiredFiles = @(
    'grimalkin.exe',
    'conpty.dll',
    'x64\OpenConsole.exe',
    'freetype.dll',
    'harfbuzz.dll',
    'fontconfig-1.dll',
    'libpng16.dll',
    'z.dll',
    'bz2.dll',
    'brotlidec.dll',
    'brotlicommon.dll',
    'libexpat.dll',
    'fonts.conf',
    'fonts\SymbolsNerdFontMono-Regular.ttf',
    'fonts\NerdFonts-LICENSE.txt',
    'LICENSE',
    'THIRD_PARTY_NOTICES.md',
    'licenses\Ghostty.txt',
    'licenses\Microsoft-Terminal.txt',
    'licenses\Odin.txt',
    'licenses\Zig.txt',
    'licenses\brotli.txt',
    'licenses\bzip2.txt',
    'licenses\expat.txt',
    'licenses\fontconfig.txt',
    'licenses\freetype.txt',
    'licenses\glfw3.txt',
    'licenses\harfbuzz.txt',
    'licenses\libpng.txt',
    'licenses\zlib.txt',
    'Uninstall.exe'
)
foreach ($relativePath in $requiredFiles) {
    $installedPath = Join-Path $installDirectory $relativePath
    if (-not (Test-Path -LiteralPath $installedPath)) {
        throw "Installer omitted required file: $relativePath"
    }
}

$x64Machine = 0x8664
foreach ($relativePath in @('grimalkin.exe', 'conpty.dll', 'x64\OpenConsole.exe')) {
    $installedPath = Join-Path $installDirectory $relativePath
    $machine = Get-PeMachine -Path $installedPath
    if ($machine -ne $x64Machine) {
        throw ('Installed file {0} has PE machine 0x{1:x4}; expected x64 (0x8664).' -f $relativePath, $machine)
    }
}

$uninstaller = Join-Path $installDirectory 'Uninstall.exe'
$uninstallProcess = Start-Process -FilePath $uninstaller -Wait -PassThru -ArgumentList '/S'
if ($uninstallProcess.ExitCode -ne 0) {
    throw "Silent uninstaller test failed with exit code $($uninstallProcess.ExitCode)."
}

$installerHash = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant()
$checksumPath = "$installer.sha256"
"$installerHash  $(Split-Path -Leaf $installer)" |
    Out-File -FilePath $checksumPath -Encoding ascii

Write-Host "Verified x64 installer: $installer"
Write-Host "SHA-256: $installerHash"
