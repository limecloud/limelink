param([ValidateSet('x64')][string]$Architecture='x64')
$ErrorActionPreference='Stop'
$TaskRoot=Split-Path $PSScriptRoot -Parent
$TaskOutput=Join-Path $TaskRoot '.dev/artifacts/windows'
dotnet publish (Join-Path $TaskRoot 'apps/windows/LimeLink.App/LimeLink.App.csproj') -c Release -r "win-$Architecture" -p:Platform=$Architecture -p:WindowsAppSDKSelfContained=true --self-contained true -o $TaskOutput
if($LASTEXITCODE -ne 0){throw 'Windows App 构建未通过'}
cargo build --manifest-path (Join-Path $TaskRoot 'runtime/Cargo.toml') --release --locked
if($LASTEXITCODE -ne 0){throw 'Windows 执行端构建未通过'}
Copy-Item (Join-Path $TaskRoot 'runtime/target/release/limelink-runtime.exe') $TaskOutput
Compress-Archive -Path "$TaskOutput/*" -DestinationPath (Join-Path $TaskRoot '.dev/artifacts/LimeLink-windows-x64-development.zip') -Force
