[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $TestExecutable,

    [Parameter(Mandatory = $true)]
    [string] $SourceDirectory,

    [ValidateRange(1, 3600)]
    [int] $TimeoutSeconds = 60
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $TestExecutable -PathType Leaf)) {
    throw "Odin test executable was not found: $TestExecutable"
}
if (-not (Test-Path -LiteralPath $SourceDirectory -PathType Container)) {
    throw "Odin source directory was not found: $SourceDirectory"
}

# Odin's runner accepts exact test names at runtime but cannot list them. Keep
# discovery deliberately narrow to the declaration form used by this package.
$testPattern = '(?ms)@\(test\)\s*(?<name>[A-Za-z_][A-Za-z0-9_]*)\s*::\s*proc\s*\('
$testNames = @(
    Get-ChildItem -LiteralPath $SourceDirectory -Filter '*.odin' -File |
        Sort-Object FullName |
        ForEach-Object {
            $source = Get-Content -LiteralPath $_.FullName -Raw
            foreach ($match in [regex]::Matches($source, $testPattern)) {
                $match.Groups['name'].Value
            }
        }
)

if ($testNames.Count -eq 0) {
    throw "No @(test) procedures were found under $SourceDirectory"
}

$duplicates = @($testNames | Group-Object | Where-Object Count -gt 1 | Select-Object -ExpandProperty Name)
if ($duplicates.Count -ne 0) {
    throw "Duplicate Odin test names cannot be selected independently: $($duplicates -join ', ')"
}

Write-Host "Running $($testNames.Count) Odin tests in isolated processes."

for ($index = 0; $index -lt $testNames.Count; $index++) {
    $testName = $testNames[$index]
    Write-Host "[$($index + 1)/$($testNames.Count)] $testName"

    $process = Start-Process `
        -FilePath $TestExecutable `
        -ArgumentList "-tests:$testName" `
        -NoNewWindow `
        -PassThru

    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        throw "Odin test '$testName' exceeded the $TimeoutSeconds second timeout."
    }
    if ($process.ExitCode -ne 0) {
        throw "Odin test '$testName' failed with exit code $($process.ExitCode)."
    }
}

Write-Host "All $($testNames.Count) isolated Odin tests passed."
