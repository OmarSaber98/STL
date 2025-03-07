# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

<#
.SYNOPSIS
Sets up a machine to be an image for a scale set.

.DESCRIPTION
provision-image.ps1 runs on an existing, freshly provisioned virtual machine,
and sets up that virtual machine as a build machine. After this is done,
(outside of this script), we take that machine and make it an image to be copied
for setting up new VMs in the scale set.

This script must either be run as admin, or one must pass AdminUserPassword;
if the script is run with AdminUserPassword, it runs itself again as an
administrator.

.PARAMETER AdminUserPassword
The administrator user's password; if this is $null, or not passed, then the
script assumes it's running on an administrator account.
#>
param(
  [string]$AdminUserPassword = $null
)

$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
Gets a random file path in the temp directory.

.DESCRIPTION
Get-TempFilePath takes an extension, and returns a path with a random
filename component in the temporary directory with that extension.

.PARAMETER Extension
The extension to use for the path.
#>
Function Get-TempFilePath {
  Param(
    [String]$Extension
  )

  if ([String]::IsNullOrWhiteSpace($Extension)) {
    throw 'Missing Extension'
  }

  $tempPath = [System.IO.Path]::GetTempPath()
  $tempName = [System.IO.Path]::GetRandomFileName() + '.' + $Extension
  return Join-Path $tempPath $tempName
}

<#
.SYNOPSIS
Downloads and extracts a ZIP file to a newly created temporary subdirectory.

.DESCRIPTION
DownloadAndExtractZip returns a path containing the extracted contents.

.PARAMETER Url
The URL of the ZIP file to download.
#>
Function DownloadAndExtractZip {
  Param(
    [String]$Url
  )

  if ([String]::IsNullOrWhiteSpace($Url)) {
    throw 'Missing Url'
  }

  $ZipPath = Get-TempFilePath -Extension 'zip'
  & curl.exe -L -o $ZipPath -s -S $Url
  $TempSubdirPath = Get-TempFilePath -Extension 'dir'
  Expand-Archive -Path $ZipPath -DestinationPath $TempSubdirPath -Force

  return $TempSubdirPath
}

$TranscriptPath = 'C:\provision-image-transcript.txt'

if ([string]::IsNullOrEmpty($AdminUserPassword)) {
  Start-Transcript -Path $TranscriptPath -UseMinimalHeader
} else {
  Write-Host 'AdminUser password supplied; switching to AdminUser.'

  # https://docs.microsoft.com/en-us/sysinternals/downloads/psexec
  $PsToolsZipUrl = 'https://download.sysinternals.com/files/PSTools.zip'
  Write-Host "Downloading: $PsToolsZipUrl"
  $ExtractedPsToolsPath = DownloadAndExtractZip -Url $PsToolsZipUrl
  $PsExecPath = Join-Path $ExtractedPsToolsPath 'PsExec64.exe'

  # https://github.com/PowerShell/PowerShell/releases/latest
  $PowerShellZipUrl = 'https://github.com/PowerShell/PowerShell/releases/download/v7.2.0/PowerShell-7.2.0-win-x64.zip'
  Write-Host "Downloading: $PowerShellZipUrl"
  $ExtractedPowerShellPath = DownloadAndExtractZip -Url $PowerShellZipUrl
  $PwshPath = Join-Path $ExtractedPowerShellPath 'pwsh.exe'

  $PsExecArgs = @(
    '-u',
    'AdminUser',
    '-p',
    'AdminUserPassword_REDACTED',
    '-accepteula',
    '-i',
    '-h',
    $PwshPath,
    '-ExecutionPolicy',
    'Unrestricted',
    '-File',
    $PSCommandPath
  )
  Write-Host "Executing: $PsExecPath $PsExecArgs"
  $PsExecArgs[3] = $AdminUserPassword

  $proc = Start-Process -FilePath $PsExecPath -ArgumentList $PsExecArgs -Wait -PassThru
  Write-Host 'Reading transcript...'
  Get-Content -Path $TranscriptPath
  Write-Host 'Cleaning up...'
  Remove-Item -Recurse -Path $ExtractedPsToolsPath
  Remove-Item -Recurse -Path $ExtractedPowerShellPath
  exit $proc.ExitCode
}

$Workloads = @(
  'Microsoft.VisualStudio.Component.VC.ASAN',
  'Microsoft.VisualStudio.Component.VC.CLI.Support',
  'Microsoft.VisualStudio.Component.VC.CMake.Project',
  'Microsoft.VisualStudio.Component.VC.CoreIde',
  'Microsoft.VisualStudio.Component.VC.Llvm.Clang',
  'Microsoft.VisualStudio.Component.VC.Runtimes.ARM.Spectre',
  'Microsoft.VisualStudio.Component.VC.Runtimes.ARM64.Spectre',
  'Microsoft.VisualStudio.Component.VC.Runtimes.x86.x64.Spectre',
  'Microsoft.VisualStudio.Component.VC.Tools.ARM',
  'Microsoft.VisualStudio.Component.VC.Tools.ARM64',
  'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
  # TRANSITION, LLVM-51128 (Clang 12 targeting ARM64 is incompatible with WinSDK 10.0.20348.0)
  'Microsoft.VisualStudio.Component.Windows10SDK.19041'
)

$ReleaseInPath = 'Preview'
$Sku = 'Enterprise'
$VisualStudioBootstrapperUrl = 'https://aka.ms/vs/17/pre/vs_enterprise.exe'
$PythonUrl = 'https://www.python.org/ftp/python/3.10.0/python-3.10.0-amd64.exe'

$CudaUrl = `
  'https://developer.download.nvidia.com/compute/cuda/10.1/Prod/local_installers/cuda_10.1.243_426.00_win10.exe'
$CudaFeatures = 'nvcc_10.1 cuobjdump_10.1 nvprune_10.1 cupti_10.1 gpu_library_advisor_10.1 memcheck_10.1 ' + `
  'nvdisasm_10.1 nvprof_10.1 visual_profiler_10.1 visual_studio_integration_10.1 cublas_10.1 cublas_dev_10.1 ' + `
  'cudart_10.1 cufft_10.1 cufft_dev_10.1 curand_10.1 curand_dev_10.1 cusolver_10.1 cusolver_dev_10.1 cusparse_10.1 ' + `
  'cusparse_dev_10.1 nvgraph_10.1 nvgraph_dev_10.1 npp_10.1 npp_dev_10.1 nvrtc_10.1 nvrtc_dev_10.1 nvml_dev_10.1 ' + `
  'occupancy_calculator_10.1 fortran_examples_10.1'

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

<#
.SYNOPSIS
Writes a message to the screen depending on ExitCode.

.DESCRIPTION
Since msiexec can return either 0 or 3010 successfully, in both cases
we write that installation succeeded, and which exit code it exited with.
If msiexec returns anything else, we write an error.

.PARAMETER ExitCode
The exit code that msiexec returned.
#>
Function PrintMsiExitCodeMessage {
  Param(
    $ExitCode
  )

  # 3010 is probably ERROR_SUCCESS_REBOOT_REQUIRED
  if ($ExitCode -eq 0 -or $ExitCode -eq 3010) {
    Write-Host "Installation successful! Exited with $ExitCode."
  }
  else {
    Write-Error "Installation failed! Exited with $ExitCode."
  }
}

<#
.SYNOPSIS
Install Visual Studio.

.DESCRIPTION
InstallVisualStudio takes the $Workloads array, and installs it with the
installer that's pointed at by $BootstrapperUrl.

.PARAMETER Workloads
The set of VS workloads to install.

.PARAMETER BootstrapperUrl
The URL of the Visual Studio installer, i.e. one of vs_*.exe.

.PARAMETER InstallPath
The path to install Visual Studio at.

.PARAMETER Nickname
The nickname to give the installation.
#>
Function InstallVisualStudio {
  Param(
    [String[]]$Workloads,
    [String]$BootstrapperUrl,
    [String]$InstallPath = $null,
    [String]$Nickname = $null
  )

  try {
    Write-Host 'Downloading Visual Studio...'
    [string]$bootstrapperExe = Get-TempFilePath -Extension 'exe'
    curl.exe -L -o $bootstrapperExe -s -S $BootstrapperUrl
    Write-Host 'Installing Visual Studio...'
    $args = @('/c', $bootstrapperExe, '--quiet', '--norestart', '--wait', '--nocache')
    foreach ($workload in $Workloads) {
      $args += '--add'
      $args += $workload
    }

    if (-not ([String]::IsNullOrWhiteSpace($InstallPath))) {
      $args += '--installpath'
      $args += $InstallPath
    }

    if (-not ([String]::IsNullOrWhiteSpace($Nickname))) {
      $args += '--nickname'
      $args += $Nickname
    }

    $proc = Start-Process -FilePath cmd.exe -ArgumentList $args -Wait -PassThru
    PrintMsiExitCodeMessage $proc.ExitCode
  }
  catch {
    Write-Error "Failed to install Visual Studio! $($_.Exception.Message)"
  }
}

<#
.SYNOPSIS
Installs Python.

.DESCRIPTION
InstallPython installs Python from the supplied URL.

.PARAMETER Url
The URL of the Python installer.
#>
Function InstallPython {
  Param(
    [String]$Url
  )

  Write-Host 'Downloading Python...'
  [string]$installerPath = Get-TempFilePath -Extension 'exe'
  curl.exe -L -o $installerPath -s -S $Url
  Write-Host 'Installing Python...'
  $proc = Start-Process -FilePath $installerPath -ArgumentList `
  @('/passive', 'InstallAllUsers=1', 'PrependPath=1', 'CompileAll=1') -Wait -PassThru
  $exitCode = $proc.ExitCode
  if ($exitCode -eq 0) {
    Write-Host 'Installation successful!'
  }
  else {
    Write-Error "Installation failed! Exited with $exitCode."
  }
}

<#
.SYNOPSIS
Installs NVIDIA's CUDA Toolkit.

.DESCRIPTION
InstallCuda installs the CUDA Toolkit with the features specified as a
space-separated list of strings in $Features.

.PARAMETER Url
The URL of the CUDA installer.

.PARAMETER Features
A space-separated list of features to install.
#>
Function InstallCuda {
  Param(
    [String]$Url,
    [String]$Features
  )

  try {
    Write-Host 'Downloading CUDA...'
    [string]$installerPath = Get-TempFilePath -Extension 'exe'
    curl.exe -L -o $installerPath -s -S $Url
    Write-Host 'Installing CUDA...'
    $proc = Start-Process -FilePath $installerPath -ArgumentList @('-s ' + $Features) -Wait -PassThru
    $exitCode = $proc.ExitCode
    if ($exitCode -eq 0) {
      Write-Host 'Installation successful!'
    }
    else {
      Write-Error "Installation failed! Exited with $exitCode."
    }
  }
  catch {
    Write-Error "Failed to install CUDA! $($_.Exception.Message)"
  }
}

<#
.SYNOPSIS
Install or upgrade a pip package.

.DESCRIPTION
Installs or upgrades a pip package specified in $Package.

.PARAMETER Package
The name of the package to be installed or upgraded.
#>
Function PipInstall {
  Param(
    [String]$Package
  )

  try {
    Write-Host "Installing or upgrading $Package..."
    python.exe -m pip install --progress-bar off --upgrade $Package
    Write-Host "Done installing or upgrading $Package."
  }
  catch {
    Write-Error "Failed to install or upgrade $Package."
  }
}

Write-Host 'AdminUser password not supplied; assuming already running as AdminUser.'

Write-Host 'Configuring AntiVirus exclusions...'
Add-MpPreference -ExclusionPath C:\agent
Add-MpPreference -ExclusionPath D:\
Add-MpPreference -ExclusionProcess ninja.exe
Add-MpPreference -ExclusionProcess clang-cl.exe
Add-MpPreference -ExclusionProcess cl.exe
Add-MpPreference -ExclusionProcess link.exe
Add-MpPreference -ExclusionProcess python.exe

InstallPython $PythonUrl
InstallVisualStudio -Workloads $Workloads -BootstrapperUrl $VisualStudioBootstrapperUrl
InstallCuda -Url $CudaUrl -Features $CudaFeatures

Write-Host 'Updating PATH...'

# Step 1: Read the system path, which was just updated by installing Python.
$currentSystemPath = [Environment]::GetEnvironmentVariable("Path", "Machine")

# Step 2: Update the local path (for this running script), so PipInstall can run python.exe.
# Additional directories can be added here (e.g. if we extracted a zip file
# or installed something that didn't update the system path).
$Env:PATH="$($currentSystemPath)"

# Step 3: Update the system path, permanently recording any additional directories that were added in the previous step.
[Environment]::SetEnvironmentVariable("Path", "$Env:PATH", "Machine")

Write-Host 'Finished updating PATH!'

Write-Host 'Running PipInstall...'

PipInstall pip
PipInstall psutil

Write-Host 'Finished running PipInstall!'

Write-Host 'Setting other environment variables...'

# The STL's PR/CI builds are totally unrepresentative of customer usage.
[Environment]::SetEnvironmentVariable("VSCMD_SKIP_SENDTELEMETRY", "1", "Machine")

Write-Host 'Finished setting other environment variables!'

Write-Host 'Done!'
