$ErrorActionPreference = 'Stop'
$project = Join-Path $PSScriptRoot 'WordMath.Windows/WordMath.Windows.csproj'
$repo = Split-Path $PSScriptRoot
$version = ([xml](Get-Content $project -Raw)).Project.PropertyGroup.Version
$publish = Join-Path $repo 'dist/windows-x64'
if (Test-Path $publish) { throw "The publish directory already exists. Choose a clean build directory: $publish" }
dotnet publish $project -c Release -r win-x64 --self-contained true -p:DebugType=None -p:DebugSymbols=false -o $publish
if ($LASTEXITCODE) { throw "dotnet publish failed with $LASTEXITCODE" }
$iscc = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6/ISCC.exe'
if (!(Test-Path $iscc)) { $iscc = (Get-Command ISCC.exe -ErrorAction Stop).Source }
& $iscc "/DPackageVersion=$version" "/DPublishDir=$publish" (Join-Path $PSScriptRoot 'setup.iss')
if ($LASTEXITCODE) { throw "Creating the installer failed with $LASTEXITCODE" }
