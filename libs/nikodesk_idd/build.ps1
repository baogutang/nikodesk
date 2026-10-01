# Build only: never installs, imports certificates, signs, or changes OS policy.
param([string]$MsBuild = 'msbuild.exe')
$ErrorActionPreference = 'Stop'
$workspace = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\..')).Path
$output = Join-Path $workspace ('artifacts\windows-driver\' + (Get-Date -Format 'yyyyMMddTHHmmss'))
$intermediate = Join-Path $workspace '.tools\nikodesk-idd-build\x64'
$project = Join-Path $PSScriptRoot 'NikoDeskIddDriver.vcxproj'
& $MsBuild $project /m /t:Build /p:Configuration=Release /p:Platform=x64 /p:SignMode=Off "/p:OutDir=$output\" "/p:IntDir=$intermediate\"
if ($LASTEXITCODE -ne 0) { throw 'NikoDesk IDD compilation failed' }
$binary = Join-Path $output 'NikoDeskIddDriver.dll'
if (-not (Test-Path -LiteralPath $binary)) { throw 'Expected driver DLL was not produced' }
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'NikoDeskIddDriver.inf') -Destination $output
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'LICENSE') -Destination $output
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'NOTICE') -Destination $output
Write-Output "Unsigned source build: $output"
Write-Output 'This is not installable by NikoDesk until a production-signed catalog covers the exact INF and DLL.'
