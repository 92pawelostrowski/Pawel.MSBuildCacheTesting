# escape=`
FROM mcr.microsoft.com/dotnet/sdk:10.0.403-windowsservercore-ltsc2025 AS sdk
FROM mcr.microsoft.com/dotnet/framework/runtime:4.8.1-windowsservercore-ltsc2025

USER ContainerAdministrator
COPY --from=sdk ["C:/Program Files/dotnet", "C:/Program Files/dotnet"]
COPY --from=sdk ["C:/Program Files/powershell", "C:/Program Files/powershell"]
COPY --from=sdk ["C:/Program Files/MinGit", "C:/Program Files/MinGit"]
SHELL ["C:\\Program Files\\powershell\\pwsh.exe", "-NoLogo", "-NoProfile", "-Command", "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue';"]

ENV DOTNET_CLI_TELEMETRY_OPTOUT=1 `
    DOTNET_NOLOGO=1 `
    DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1 `
    NUGET_PACKAGES=C:\NuGetPackages

# The .NET Framework runtime base supports Visual Studio's full-framework
# MSBuild.exe and file-access reporting. Copy the pinned SDK, Git and PowerShell
# from the official SDK image, then expose their tools in subsequent layers.
RUN $buildToolPath = [Environment]::GetEnvironmentVariable('PATH', 'Machine') + ';C:\Program Files\dotnet;C:\Program Files\powershell;C:\Program Files\MinGit\cmd'; `
    [Environment]::SetEnvironmentVariable('PATH', $buildToolPath, 'Machine')

# Install MSBuild, its .NET SDK resolver, and NuGet without C++ workloads.
RUN New-Item -ItemType Directory -Path C:\TEMP -Force | Out-Null; `
    Invoke-WebRequest -Uri 'https://aka.ms/vs/18/stable/vs_buildtools.exe' -OutFile C:\TEMP\vs_buildtools.exe; `
    $installation = Start-Process -FilePath C:\TEMP\vs_buildtools.exe -WindowStyle Hidden -Wait -PassThru -ArgumentList @('--quiet', '--wait', '--norestart', '--nocache', '--installPath', 'C:\BuildTools', '--add', 'Microsoft.VisualStudio.Workload.MSBuildTools', '--add', 'Microsoft.NetCore.Component.SDK', '--add', 'Microsoft.VisualStudio.Component.NuGet.BuildTools'); `
    if ($installation.ExitCode -notin @(0, 3010)) { throw "Visual Studio Build Tools installation failed: $($installation.ExitCode)" }; `
    Remove-Item -LiteralPath C:\TEMP\vs_buildtools.exe; `
    if (-not (Test-Path -LiteralPath C:\BuildTools\MSBuild\Current\Bin\amd64\MSBuild.exe)) { throw 'Visual Studio x64 MSBuild.exe was not installed.' }; `
    & C:\BuildTools\MSBuild\Current\Bin\amd64\MSBuild.exe -version -nologo; `
    if ($LASTEXITCODE -ne 0) { throw 'Visual Studio x64 MSBuild.exe could not start.' }; `
    if (-not ((& dotnet --list-sdks) -match '^10\.0\.403 ')) { throw 'The pinned .NET SDK is unavailable.' }; `
    if ($LASTEXITCODE -ne 0) { throw 'The pinned .NET SDK could not start.' }; `
    git --version; `
    if ($LASTEXITCODE -ne 0) { throw 'Git is unavailable.' }

WORKDIR C:\workspace
COPY . .

# The host .git directory and cache are excluded from the image. Create a local,
# deterministic Git snapshot so the plugin can obtain source hashes. This does
# not copy the user's Git configuration, credentials or repository history.
RUN if ((& dotnet --version) -ne '10.0.403') { throw 'global.json did not select the pinned .NET SDK.' }; `
    if ($LASTEXITCODE -ne 0) { throw 'Could not resolve the pinned .NET SDK.' }; `
    $env:GIT_AUTHOR_DATE = '2000-01-01T00:00:00Z'; `
    $env:GIT_COMMITTER_DATE = '2000-01-01T00:00:00Z'; `
    git init --quiet --initial-branch=main; `
    if ($LASTEXITCODE -ne 0) { throw 'Could not initialize the container Git snapshot.' }; `
    git -c core.autocrlf=false add --all; `
    if ($LASTEXITCODE -ne 0) { throw 'Could not stage the container Git snapshot.' }; `
    git -c user.name='MSBuildCache Test Fixture' -c user.email='msbuildcache-test@localhost' commit --quiet --message='Container fixture snapshot'; `
    if ($LASTEXITCODE -ne 0) { throw 'Could not commit the container Git snapshot.' }; `
    $resolvedSdk = (& C:\BuildTools\MSBuild\Current\Bin\amd64\MSBuild.exe src\Project0000\Project0000.csproj -nologo -property:MSBuildCacheEnabled=false -getProperty:NETCoreSdkVersion | Out-String).Trim(); `
    if ($LASTEXITCODE -ne 0 -or $resolvedSdk -ne '10.0.403') { throw "Full-framework MSBuild could not resolve the pinned SDK: $resolvedSdk" }; `
    Write-Host "Full-framework MSBuild resolved .NET SDK $resolvedSdk."

# Restore and compilation run on every container invocation, outside image layers.
# Only C:\MSBuildCache and C:\results are host-mounted. The cache survives fresh
# containers; sources and compiler outputs remain isolated inside each container.
ENTRYPOINT ["C:\\Program Files\\powershell\\pwsh.exe", "-NoLogo", "-NoProfile", "-File", "C:\\workspace\\scripts\\build-in-container.ps1"]
