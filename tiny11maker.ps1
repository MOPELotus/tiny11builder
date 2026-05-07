<#
.SYNOPSIS
    Scripts to build a trimmed-down Windows 11 image.

.DESCRIPTION
    This is a script created to automate the build of a streamlined Windows 11 image, similar to tiny10.
    My main goal is to use only Microsoft utilities like DISM, and no utilities from external sources.
    The only executable included is oscdimg.exe, which is provided in the Windows ADK and it is used to create bootable ISO images.

.PARAMETER ISO
    Drive letter given to the mounted iso (eg: E)

.PARAMETER SCRATCH
    Drive letter of the desired scratch disk (eg: D)

.EXAMPLE
    .\tiny11maker.ps1 E D
    .\tiny11maker.ps1 -ISO E -SCRATCH D
    .\tiny11maker.ps1 -SCRATCH D -ISO E
    .\tiny11maker.ps1

    *If you ordinal parameters the first one must be the mounted iso. The second is the scratch drive.
    prefer the use of full named parameter (eg: "-ISO") as you can put in the order you want.

.NOTES
    Auteur: ntdevlabs
    Date: 09-07-25
#>

#---------[ Parameters ]---------#
param (
    [ValidatePattern('^[c-zC-Z]$')][string]$ISO,
    [ValidatePattern('^[c-zC-Z]$')][string]$SCRATCH
)

if (-not $SCRATCH) {
    $ScratchDisk = Join-Path ($PSScriptRoot -replace '[\\]+$', '') 'build'
} else {
    $ScratchDisk = Join-Path ($SCRATCH + ":\") 'tiny11builder-work'
}
$ScratchDisk = $ScratchDisk -replace '[\\]+$', ''

#---------[ Functions ]---------#
function Set-RegistryValue {
    param (
        [string]$path,
        [string]$name,
        [string]$type,
        [string]$value
    )
    try {
        & 'reg' 'add' $path '/v' $name '/t' $type '/d' $value '/f' | Out-Null
        Write-Output "Set registry value: $path\$name"
    } catch {
        Write-Output "Error setting registry value: $_"
    }
}

function Remove-RegistryValue {
    param (
		[string]$path
	)
	try {
		& 'reg' 'delete' $path '/f' | Out-Null
		Write-Output "Removed registry value: $path"
	} catch {
		Write-Output "Error removing registry value: $_"
	}
}

function Set-RegistryDefaultValue {
    param (
        [string]$path,
        [string]$value
    )
    try {
        if ($value -eq '') {
            & 'reg' 'add' $path '/ve' '/f' | Out-Null
        } else {
            & 'reg' 'add' $path '/ve' '/d' $value '/f' | Out-Null
        }
        Write-Output "Set default registry value: $path"
    } catch {
        Write-Output "Error setting default registry value: $_"
    }
}

function Assert-LastExitCode {
    param (
        [string]$Action,
        [int[]]$AllowedExitCodes = @(0)
    )

    if ($AllowedExitCodes -notcontains $LASTEXITCODE) {
        throw "$Action failed with exit code $LASTEXITCODE"
    }
}

function Invoke-DismCritical {
    param (
        [string]$Action,
        [string[]]$Arguments
    )

    & dism.exe @Arguments
    Assert-LastExitCode $Action
}

function Invoke-RegCritical {
    param (
        [string]$Action,
        [string[]]$Arguments
    )

    & reg.exe @Arguments | Out-Null
    Assert-LastExitCode $Action
}

function Invoke-DismCapture {
    param (
        [string]$Action,
        [string[]]$Arguments
    )

    $output = & dism.exe @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $output | ForEach-Object { Write-Host $_ }
    if ($exitCode -ne 0) {
        throw "$Action failed with exit code $exitCode"
    }

    return $output
}

function Assert-MountedImage {
    param ([string]$Path)

    if (-not (Test-Path -Path (Join-Path $Path 'Windows\System32\config\SOFTWARE'))) {
        throw "Image mount failed or is not usable: $Path"
    }
}

function Assert-ImageUnmounted {
    param ([string]$Path)

    $normalizedPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $mountInfo = Invoke-DismCapture -Action "Verify WIM mount state" -Arguments @('/English', '/Get-MountedWimInfo')
    foreach ($line in $mountInfo) {
        if ($line -match '^Mount Dir : (.*)$') {
            $mountPath = [System.IO.Path]::GetFullPath($matches[1].Trim()).TrimEnd('\')
            if ($mountPath -ieq $normalizedPath) {
                throw "Image is still mounted after unmount: $Path"
            }
        }
    }
}

function Remove-PathIfExists {
    param (
        [string]$Path,
        [switch]$Recurse
    )

    if (Test-Path -Path $Path) {
        if ($Recurse) {
            Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop | Out-Null
        } else {
            Remove-Item -Path $Path -Force -ErrorAction Stop | Out-Null
        }
    } else {
        Write-Output "Path already absent: $Path"
    }
}

function Remove-CleanupPath {
    param (
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue 2>$null | Out-Null
    } catch {
        Write-Output "Cleanup skipped for ${Path}: $($_.Exception.Message)"
    } finally {
        $ErrorActionPreference = $previousPreference
    }
}

function Set-LotusDefaultWallpaper {
    param (
        [string]$MountPath,
        [string]$PayloadSource
    )

    $wallpaperSourceRoot = Join-Path $PayloadSource 'Wallpapers'
    if (-not (Test-Path -LiteralPath $wallpaperSourceRoot)) {
        Write-Output "No custom wallpaper folder found at $wallpaperSourceRoot."
        return
    }

    $wallpaperSource = Get-ChildItem -LiteralPath $wallpaperSourceRoot -File |
        Where-Object { $_.Extension -in '.jpg', '.jpeg' } |
        Sort-Object Name |
        Select-Object -First 1

    if (-not $wallpaperSource) {
        Write-Output "No JPEG wallpaper found at $wallpaperSourceRoot."
        return
    }

    Write-Output "Applying Lotus default wallpaper from $($wallpaperSource.FullName)"
    $lotusWallpaperRoot = Join-Path $MountPath 'Windows\Setup\Lotus\Wallpapers'
    New-Item -ItemType Directory -Force -Path $lotusWallpaperRoot | Out-Null
    Copy-Item -LiteralPath $wallpaperSource.FullName -Destination (Join-Path $lotusWallpaperRoot 'LotusDefault.jpg') -Force -ErrorAction Stop

    $defaultWallpaperRoot = Join-Path $MountPath 'Windows\Web\Wallpaper\Windows'
    New-Item -ItemType Directory -Force -Path $defaultWallpaperRoot | Out-Null

    $defaultWallpaper = Join-Path $defaultWallpaperRoot 'img0.jpg'
    try {
        & takeown.exe '/f' $defaultWallpaper | Out-Null
        & icacls.exe $defaultWallpaper '/grant' '*S-1-5-32-544:F' '/C' | Out-Null
        Set-ItemProperty -Path $defaultWallpaper -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
        Copy-Item -LiteralPath $wallpaperSource.FullName -Destination $defaultWallpaper -Force -ErrorAction Stop
    } catch {
        Write-Output "Optional img0 wallpaper replacement skipped: $($_.Exception.Message)"
    }

    $fourKWallpaperRoot = Join-Path $MountPath 'Windows\Web\4K\Wallpaper\Windows'
    if (Test-Path -LiteralPath $fourKWallpaperRoot) {
        Get-ChildItem -LiteralPath $fourKWallpaperRoot -Filter 'img0*.jpg' -File |
            ForEach-Object {
                try {
                    & takeown.exe '/f' $_.FullName | Out-Null
                    & icacls.exe $_.FullName '/grant' '*S-1-5-32-544:F' '/C' | Out-Null
                    Set-ItemProperty -Path $_.FullName -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
                    Copy-Item -LiteralPath $wallpaperSource.FullName -Destination $_.FullName -Force -ErrorAction Stop
                } catch {
                    Write-Output "Optional 4K wallpaper replacement skipped for $($_.Name): $($_.Exception.Message)"
                }
            }
    }
}

function Add-LotusSetupPayload {
    param (
        [string]$MountPath,
        [string]$PayloadSource
    )

    $setupRoot = Join-Path $MountPath 'Windows\Setup'
    $scriptsRoot = Join-Path $setupRoot 'Scripts'
    $lotusRoot = Join-Path $setupRoot 'Lotus'
    New-Item -ItemType Directory -Force -Path $scriptsRoot, $lotusRoot | Out-Null

    if (Test-Path -Path $PayloadSource) {
        Write-Output "Staging Lotus payload from $PayloadSource"
        Copy-Item -Path (Join-Path $PayloadSource '*') -Destination $lotusRoot -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        Write-Output "No payload folder found at $PayloadSource. Runtime, font, Office and PowerShell installers will be skipped unless added later."
    }

    $postInstallScript = @'
$ErrorActionPreference = 'SilentlyContinue'
$root = Join-Path $env:WINDIR 'Setup\Lotus'

function Start-LotusProcess {
    param (
        [string]$FilePath,
        [string]$ArgumentList
    )

    if ((Test-Path $FilePath) -or $FilePath -in @('msiexec.exe', 'cmd.exe')) {
        Write-Output "Running: $FilePath $ArgumentList"
        $process = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -Wait -PassThru -WindowStyle Hidden
        Write-Output "Exit code: $($process.ExitCode)"
    }
}

function Get-VCRedistArguments {
    param (
        [string]$InstallerName
    )

    if ($InstallerName -match '2005') {
        return '/q'
    }

    if ($InstallerName -match '2008') {
        return '/q'
    }

    if ($InstallerName -match '2010') {
        return '/q /norestart'
    }

    if ($InstallerName -match '2012|2013') {
        return '/quiet /norestart'
    }

    if ($InstallerName -match 'vc_redist|2015|2017|2019|2022|2026') {
        return '/install /quiet /norestart'
    }

    return '/quiet /norestart'
}

if (Test-Path 'D:\') {
    New-Item -ItemType Directory -Force -Path 'D:\Users' | Out-Null
}

try {
    if (-not (Get-LocalUser -Name 'Lotus' -ErrorAction SilentlyContinue)) {
        New-LocalUser -Name 'Lotus' -NoPassword -AccountNeverExpires -FullName 'Lotus' | Out-Null
    }

    $adminGroupName = Get-LocalGroup |
        Where-Object { $_.SID.Value -eq 'S-1-5-32-544' } |
        Select-Object -First 1 -ExpandProperty Name

    if ($adminGroupName) {
        Add-LocalGroupMember -Group $adminGroupName -Member 'Lotus' -ErrorAction SilentlyContinue
    }

    Get-LocalUser |
        Where-Object { $_.SID.Value -match '-500$' -and $_.Name -ne 'Lotus' } |
        Disable-LocalUser
} catch {
    Write-Output "Local account fallback failed: $_"
}

powercfg.exe /hibernate off | Out-Null

$fontRoot = Join-Path $root 'Fonts'
if (Test-Path $fontRoot) {
    $fontRegistry = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
    Get-ChildItem -Path $fontRoot -Recurse -File |
        Where-Object { $_.Extension -in '.ttf', '.ttc', '.otf' } |
        ForEach-Object {
            $fontName = $_.BaseName
            $fontType = if ($_.Extension -eq '.otf') { 'OpenType' } else { 'TrueType' }
            $targetPath = Join-Path $env:WINDIR "Fonts\$($_.Name)"
            Copy-Item -Path $_.FullName -Destination $targetPath -Force
            New-ItemProperty -Path $fontRegistry -Name "$fontName ($fontType)" -Value $_.Name -PropertyType String -Force | Out-Null
            Write-Output "Installed font: $($_.Name)"
        }
}

$directXSetup = Join-Path $root 'DirectX\DXSETUP.exe'
Start-LotusProcess $directXSetup '/silent'

$vcRoot = Join-Path $root 'VCRedist'
if (Test-Path $vcRoot) {
    Get-ChildItem -Path $vcRoot -Recurse -Filter '*.exe' |
        ForEach-Object {
            Start-LotusProcess $_.FullName (Get-VCRedistArguments $_.Name)
        }
    Get-ChildItem -Path $vcRoot -Recurse -Filter '*.msi' |
        ForEach-Object { Start-LotusProcess 'msiexec.exe' "/i `"$($_.FullName)`" /qn /norestart" }
}

$dotNetRoot = Join-Path $root 'DotNet'
if (Test-Path $dotNetRoot) {
    Get-ChildItem -Path $dotNetRoot -Recurse -Filter '*.exe' |
        ForEach-Object { Start-LotusProcess $_.FullName '/install /quiet /norestart' }
}

$pwshMsi = Get-ChildItem -Path (Join-Path $root 'PowerShell') -Recurse -Filter 'PowerShell-*-win-*.msi' |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
if ($pwshMsi) {
    Start-LotusProcess 'msiexec.exe' "/i `"$($pwshMsi.FullName)`" /qn /norestart ADD_EXPLORER_CONTEXT_MENU_OPENPOWERSHELL=1 ADD_FILE_CONTEXT_MENU_RUNPOWERSHELL=1 ENABLE_PSREMOTING=0 REGISTER_MANIFEST=1 USE_MU=0 ENABLE_MU=0 ADD_PATH=1"
}

$officeRoot = Join-Path $root 'Office2016Mondo'
$officeConfig = Join-Path $officeRoot 'configuration.xml'
if (Test-Path $officeConfig) {
    $officeInstallScript = Join-Path $officeRoot 'InstallOfficeAfterLogon.cmd'
    $officeInstallContent = @"
@echo off
set OFFICE_ROOT=%WINDIR%\Setup\Lotus\Office2016Mondo
set OFFICE_LOG=%WINDIR%\Setup\Lotus\Office2016MondoInstall.log
if not exist "%OFFICE_ROOT%\setup.exe" (
    if exist "%OFFICE_ROOT%\officedeploymenttool.exe" "%OFFICE_ROOT%\officedeploymenttool.exe" /quiet /extract:"%OFFICE_ROOT%"
)
if exist "%OFFICE_ROOT%\setup.exe" "%OFFICE_ROOT%\setup.exe" /configure "%OFFICE_ROOT%\configuration.xml" >> "%OFFICE_LOG%" 2>&1
schtasks.exe /Delete /TN "Lotus Office 2016 Mondo Online Install" /F >nul 2>&1
exit /b 0
"@
    Set-Content -Path $officeInstallScript -Value $officeInstallContent -Encoding ASCII
    & schtasks.exe /Create /TN 'Lotus Office 2016 Mondo Online Install' /SC ONLOGON /DELAY 0001:00 /RL HIGHEST /RU SYSTEM /TR "`"$officeInstallScript`"" /F | Out-Null
}
'@

    $setupComplete = @'
@echo off
set LOG=%WINDIR%\Setup\Lotus\LotusPostInstall.log
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%WINDIR%\Setup\Lotus\LotusPostInstall.ps1" >> "%LOG%" 2>&1
exit /b 0
'@

    Set-Content -Path (Join-Path $lotusRoot 'LotusPostInstall.ps1') -Value $postInstallScript -Encoding ASCII
    Set-Content -Path (Join-Path $scriptsRoot 'SetupComplete.cmd') -Value $setupComplete -Encoding ASCII
}

#---------[ Execution ]---------#
# Check if PowerShell execution is restricted
if ((Get-ExecutionPolicy) -eq 'Restricted') {
    Write-Output "Your current PowerShell Execution Policy is set to Restricted, which prevents scripts from running. Do you want to change it to RemoteSigned? (yes/no)"
    $response = Read-Host
    if ($response -eq 'yes') {
        Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Confirm:$false
    } else {
        Write-Output "The script cannot be run without changing the execution policy. Exiting..."
        exit
    }
}

# Check and run the script as admin if required
$adminSID = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
$adminGroup = $adminSID.Translate([System.Security.Principal.NTAccount])
$myWindowsID=[System.Security.Principal.WindowsIdentity]::GetCurrent()
$myWindowsPrincipal=new-object System.Security.Principal.WindowsPrincipal($myWindowsID)
$adminRole=[System.Security.Principal.WindowsBuiltInRole]::Administrator
if (! $myWindowsPrincipal.IsInRole($adminRole))
{
    Write-Output "Restarting Tiny11 image creator as admin in a new window, you can close this one."
    $newProcess = new-object System.Diagnostics.ProcessStartInfo "PowerShell";
    $newProcess.Arguments = $myInvocation.MyCommand.Definition;
    $newProcess.Verb = "runas";
    [System.Diagnostics.Process]::Start($newProcess);
    exit
}

$DownloadedAutounattend = $false
if (-not (Test-Path -Path "$PSScriptRoot/autounattend.xml")) {
    Invoke-RestMethod "https://raw.githubusercontent.com/ntdevlabs/tiny11builder/refs/heads/main/autounattend.xml" -OutFile "$PSScriptRoot/autounattend.xml"
    $DownloadedAutounattend = $true
}

# Start the transcript and prepare the window
Start-Transcript -Path "$PSScriptRoot\tiny11_$(get-date -f yyyyMMdd_HHmms).log"

$Host.UI.RawUI.WindowTitle = "Tiny11 image creator"
Clear-Host
Write-Output "Welcome to the tiny11 image creator! Release: 09-07-25"

$hostArchitecture = $Env:PROCESSOR_ARCHITECTURE
New-Item -ItemType Directory -Force -Path "$ScratchDisk\tiny11\sources" | Out-Null
do {
    if (-not $ISO) {
        $DriveLetter = Read-Host "Please enter the drive letter for the Windows 11 image"
    } else {
        $DriveLetter = $ISO
    }
    if ($DriveLetter -match '^[c-zC-Z]$') {
        $DriveLetter = $DriveLetter + ":"
        Write-Output "Drive letter set to $DriveLetter"
    } else {
        Write-Output "Invalid drive letter. Please enter a letter between C and Z."
    }
} while ($DriveLetter -notmatch '^[c-zC-Z]:$')

if ((Test-Path "$DriveLetter\sources\boot.wim") -eq $false -or (Test-Path "$DriveLetter\sources\install.wim") -eq $false) {
    if ((Test-Path "$DriveLetter\sources\install.esd") -eq $true) {
        Write-Output "Found install.esd, converting to install.wim..."
        Get-WindowsImage -ImagePath $DriveLetter\sources\install.esd
        $index = Read-Host "Please enter the image index"
        Write-Output ' '
        Write-Output 'Converting install.esd to install.wim. This may take a while...'
        Export-WindowsImage -SourceImagePath $DriveLetter\sources\install.esd -SourceIndex $index -DestinationImagePath $ScratchDisk\tiny11\sources\install.wim -Compressiontype Maximum -CheckIntegrity
    } else {
        Write-Output "Can't find Windows OS Installation files in the specified Drive Letter.."
        Write-Output "Please enter the correct DVD Drive Letter.."
        exit
    }
}

Write-Output "Copying Windows image..."
Copy-Item -Path "$DriveLetter\*" -Destination "$ScratchDisk\tiny11" -Recurse -Force | Out-Null
Set-ItemProperty -Path "$ScratchDisk\tiny11\sources\install.esd" -Name IsReadOnly -Value $false > $null 2>&1
Remove-Item "$ScratchDisk\tiny11\sources\install.esd" > $null 2>&1
Write-Output "Copy complete!"
Start-Sleep -Seconds 2
Clear-Host
Write-Output "Getting image information:"
$ImagesIndex = (Get-WindowsImage -ImagePath $ScratchDisk\tiny11\sources\install.wim).ImageIndex
while ($ImagesIndex -notcontains $index) {
    Get-WindowsImage -ImagePath $ScratchDisk\tiny11\sources\install.wim
    $index = Read-Host "Please enter the image index"
}
Write-Output "Mounting Windows image. This may take a while."
$wimFilePath = "$ScratchDisk\tiny11\sources\install.wim"
& takeown "/F" $wimFilePath
& icacls $wimFilePath "/grant" "$($adminGroup.Value):(F)"
try {
    Set-ItemProperty -Path $wimFilePath -Name IsReadOnly -Value $false -ErrorAction Stop
} catch {
    # This block will catch the error and suppress it.
	Write-Error "$wimFilePath not found"
}
New-Item -ItemType Directory -Force -Path "$ScratchDisk\scratchdir" > $null
Mount-WindowsImage -ImagePath $ScratchDisk\tiny11\sources\install.wim -Index $index -Path $ScratchDisk\scratchdir -ErrorAction Stop
Assert-MountedImage "$ScratchDisk\scratchdir"

$imageIntl = Invoke-DismCapture -Action "Get image international settings" -Arguments @('/English', '/Get-Intl', "/Image:$($ScratchDisk)\scratchdir")
$languageLine = $imageIntl -split '\n' | Where-Object { $_ -match 'Default system UI language : ([a-zA-Z]{2}-[a-zA-Z]{2})' }

if ($languageLine) {
    $languageCode = $Matches[1]
    Write-Output "Default system UI language code: $languageCode"
} else {
    Write-Output "Default system UI language code not found."
}

$imageInfo = Invoke-DismCapture -Action "Get WIM info" -Arguments @('/English', '/Get-WimInfo', "/wimFile:$($ScratchDisk)\tiny11\sources\install.wim", "/index:$index")
$lines = $imageInfo -split '\r?\n'

foreach ($line in $lines) {
    if ($line -like '*Architecture : *') {
        $architecture = $line -replace 'Architecture : ',''
        # If the architecture is x64, replace it with amd64
        if ($architecture -eq 'x64') {
            $architecture = 'amd64'
        }
        Write-Output "Architecture: $architecture"
        break
    }
}

if (-not $architecture) {
    Write-Output "Architecture information not found."
}

Write-Output "Mounting complete! Performing removal of applications..."

$packages = Invoke-DismCapture -Action "Get provisioned UWP packages" -Arguments @('/English', "/image:$($ScratchDisk)\scratchdir", '/Get-ProvisionedAppxPackages') |
    ForEach-Object {
        if ($_ -match 'PackageName : (.*)') {
            $matches[1]
        }
    }

$uwpProtectedPrefixes = @(
    'Microsoft.DesktopAppInstaller',
    'Microsoft.GamingApp',
    'Microsoft.GamingServices',
    'Microsoft.NET.Native.Framework',
    'Microsoft.NET.Native.Runtime',
    'Microsoft.Paint',
    'Microsoft.ScreenSketch',
    'Microsoft.Services.Store.Engagement',
    'Microsoft.StorePurchaseApp',
    'Microsoft.UI.Xaml',
    'Microsoft.VCLibs',
    'Microsoft.Windows.Photos',
    'Microsoft.WindowsAppRuntime',
    'Microsoft.WindowsCalculator',
    'Microsoft.WindowsCamera',
    'Microsoft.WindowsSoundRecorder',
    'Microsoft.WindowsStore',
    'Microsoft.Xbox',
    'Microsoft.XboxApp',
    'Microsoft.XboxGameCallableUI',
    'Microsoft.XboxGameOverlay',
    'Microsoft.XboxGamingOverlay',
    'Microsoft.XboxIdentityProvider',
    'Microsoft.XboxSpeechToTextOverlay'
)

$uwpRemovePrefixes = @(
    'AppUp.IntelManagementandSecurityStatus',
    'Clipchamp.Clipchamp',
    'DolbyLaboratories.DolbyAccess',
    'DolbyLaboratories.DolbyDigitalPlusDecoderOEM',
    'Microsoft.BingNews',
    'Microsoft.BingSearch',
    'Microsoft.BingWeather',
    'Microsoft.Copilot',
    'Microsoft.GetHelp',
    'Microsoft.Getstarted',
    'Microsoft.Microsoft3DViewer',
    'Microsoft.MicrosoftOfficeHub',
    'Microsoft.MicrosoftSolitaireCollection',
    'Microsoft.MSPaint',
    'Microsoft.MixedReality.Portal',
    'Microsoft.Office.OneNote',
    'Microsoft.OfficePushNotificationUtility',
    'Microsoft.OutlookForWindows',
    'Microsoft.People',
    'Microsoft.PowerAutomateDesktop',
    'Microsoft.SkypeApp',
    'Microsoft.StartExperiencesApp',
    'Microsoft.Todos',
    'Microsoft.Wallet',
    'Microsoft.Windows.CrossDevice',
    'Microsoft.Windows.Copilot',
    'Microsoft.Windows.DevHome',
    'Microsoft.Windows.Teams',
    'Microsoft.WindowsAlarms',
    'Microsoft.WindowsFeedbackHub',
    'Microsoft.WindowsMaps',
    'Microsoft.WindowsNotepad',
    'Microsoft.WindowsTerminal',
    'Microsoft.YourPhone',
    'Microsoft.ZuneMusic',
    'Microsoft.ZuneVideo',
    'MicrosoftCorporationII.MicrosoftFamily',
    'MicrosoftCorporationII.QuickAssist',
    'MicrosoftTeams',
    'MSTeams'
)

$packagesToRemove = $packages | Where-Object {
    $packageName = $_
    $protectedPackage = $false
    foreach ($prefix in $uwpProtectedPrefixes) {
        if ($packageName -like "$prefix*") {
            $protectedPackage = $true
            break
        }
    }

    $removePackage = $false
    foreach ($prefix in $uwpRemovePrefixes) {
        if ((-not $protectedPackage) -and ($packageName -like "$prefix*")) {
            $removePackage = $true
            break
        }
    }

    $removePackage
}
foreach ($package in $packagesToRemove) {
    Write-Output "Removing provisioned UWP package: $package"
    Invoke-DismCritical -Action "Remove provisioned UWP package $package" -Arguments @('/English', "/image:$($ScratchDisk)\scratchdir", '/Remove-ProvisionedAppxPackage', "/PackageName:$package")
}

Write-Output "Enabling .NET Framework 3.5 and classic Win32 media components:"
if (Test-Path "$DriveLetter\sources\sxs") {
    Invoke-DismCritical -Action "Enable .NET Framework 3.5" -Arguments @('/English', "/Image:$($ScratchDisk)\scratchdir", '/Enable-Feature', '/FeatureName:NetFx3', '/All', "/Source:$DriveLetter\sources\sxs", '/LimitAccess')
} else {
    Write-Output "SxS source folder not found. Skipping .NET Framework 3.5."
}
Invoke-DismCritical -Action "Enable Windows Media Player" -Arguments @('/English', "/Image:$($ScratchDisk)\scratchdir", '/Enable-Feature', '/FeatureName:WindowsMediaPlayer', '/All', '/NoRestart')

Write-Output "Removing rarely used optional capabilities and packages:"
$capabilityPatterns = @(
    'App.Support.QuickAssist*',
    'Browser.InternetExplorer*',
    'MathRecognizer*',
    'Microsoft.Windows.WordPad*',
    'StepsRecorder*'
)

$capabilities = @()
$currentCapability = $null
foreach ($line in (Invoke-DismCapture -Action "Get optional capabilities" -Arguments @('/English', "/Image:$($ScratchDisk)\scratchdir", '/Get-Capabilities'))) {
    if ($line -match 'Capability Identity : (.*)') {
        $currentCapability = $matches[1].Trim()
        continue
    }
    if (($line -match 'State : Installed') -and $currentCapability) {
        $capabilities += $currentCapability
        $currentCapability = $null
    }
}

foreach ($pattern in $capabilityPatterns) {
    $capabilities |
        Where-Object { $_ -like $pattern } |
        ForEach-Object {
            Write-Output "Removing capability: $_"
            Invoke-DismCritical -Action "Remove capability $_" -Arguments @('/English', "/Image:$($ScratchDisk)\scratchdir", '/Remove-Capability', "/CapabilityName:$_")
        }
}

$packagePatterns = @(
    'Microsoft-Windows-InternetExplorer-Optional-Package~31bf3856ad364e35',
    'Microsoft-Windows-RetailDemo-OfflineContent-Content-Package~',
    'Microsoft-Windows-StepsRecorder-Package~',
    'Microsoft-Windows-TabletPCMath-Package~',
    'Microsoft-Windows-Wallpaper-Content-Extended-FoD-Package~',
    'Microsoft-Windows-WordPad-FoD-Package~'
)

$allPackages = @()
$currentPackage = $null
foreach ($line in (Invoke-DismCapture -Action "Get optional packages" -Arguments @('/English', "/Image:$($ScratchDisk)\scratchdir", '/Get-Packages'))) {
    if ($line -match 'Package Identity : (.*)') {
        $currentPackage = $matches[1].Trim()
        continue
    }
    if (($line -match 'State : Installed') -and $currentPackage) {
        $allPackages += $currentPackage
        $currentPackage = $null
    }
}
foreach ($packagePattern in $packagePatterns) {
    $allPackages |
        Where-Object { ($_ -like "$packagePattern*") -and ($_ -like "*~$architecture~~*") } |
        ForEach-Object {
            $packageIdentity = $_.Trim()
            if ($packageIdentity) {
                Write-Output "Removing optional package: $packageIdentity"
                Invoke-DismCritical -Action "Remove optional package $packageIdentity" -Arguments @('/English', "/Image:$($ScratchDisk)\scratchdir", '/Remove-Package', "/PackageName:$packageIdentity")
            }
        }
}

Write-Output "Removing Edge:"
Remove-PathIfExists -Path "$ScratchDisk\scratchdir\Program Files (x86)\Microsoft\Edge" -Recurse
Remove-PathIfExists -Path "$ScratchDisk\scratchdir\Program Files (x86)\Microsoft\EdgeUpdate" -Recurse
Remove-PathIfExists -Path "$ScratchDisk\scratchdir\Program Files (x86)\Microsoft\EdgeCore" -Recurse
if (Test-Path -Path "$ScratchDisk\scratchdir\Windows\System32\Microsoft-Edge-Webview") {
    & 'takeown' '/f' "$ScratchDisk\scratchdir\Windows\System32\Microsoft-Edge-Webview" '/r' | Out-Null
    & 'icacls' "$ScratchDisk\scratchdir\Windows\System32\Microsoft-Edge-Webview" '/grant' "$($adminGroup.Value):(F)" '/T' '/C' | Out-Null
    Remove-PathIfExists -Path "$ScratchDisk\scratchdir\Windows\System32\Microsoft-Edge-Webview" -Recurse
} else {
    Write-Output "Path already absent: $ScratchDisk\scratchdir\Windows\System32\Microsoft-Edge-Webview"
}
Write-Output "Removing OneDrive:"
if (Test-Path -Path "$ScratchDisk\scratchdir\Windows\System32\OneDriveSetup.exe") {
    & 'takeown' '/f' "$ScratchDisk\scratchdir\Windows\System32\OneDriveSetup.exe" | Out-Null
    & 'icacls' "$ScratchDisk\scratchdir\Windows\System32\OneDriveSetup.exe" '/grant' "$($adminGroup.Value):(F)" '/T' '/C' | Out-Null
    Remove-PathIfExists -Path "$ScratchDisk\scratchdir\Windows\System32\OneDriveSetup.exe"
} else {
    Write-Output "Path already absent: $ScratchDisk\scratchdir\Windows\System32\OneDriveSetup.exe"
}
Write-Output "Removal complete!"
Start-Sleep -Seconds 2
Clear-Host
Write-Output "Loading registry..."
Invoke-RegCritical -Action "Load registry hive HKLM\zCOMPONENTS" -Arguments @('load', 'HKLM\zCOMPONENTS', "$ScratchDisk\scratchdir\Windows\System32\config\COMPONENTS")
Invoke-RegCritical -Action "Load registry hive HKLM\zDEFAULT" -Arguments @('load', 'HKLM\zDEFAULT', "$ScratchDisk\scratchdir\Windows\System32\config\default")
Invoke-RegCritical -Action "Load registry hive HKLM\zNTUSER" -Arguments @('load', 'HKLM\zNTUSER', "$ScratchDisk\scratchdir\Users\Default\ntuser.dat")
Invoke-RegCritical -Action "Load registry hive HKLM\zSOFTWARE" -Arguments @('load', 'HKLM\zSOFTWARE', "$ScratchDisk\scratchdir\Windows\System32\config\SOFTWARE")
Invoke-RegCritical -Action "Load registry hive HKLM\zSYSTEM" -Arguments @('load', 'HKLM\zSYSTEM', "$ScratchDisk\scratchdir\Windows\System32\config\SYSTEM")
Write-Output "Bypassing system requirements(on the system image):"
Set-RegistryValue 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' 'SV1' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' 'SV2' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' 'SV1' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' 'SV2' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassCPUCheck' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassRAMCheck' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassSecureBootCheck' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassStorageCheck' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassTPMCheck' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSYSTEM\Setup\MoSetup' 'AllowUpgradesWithUnsupportedTPMOrCPU' 'REG_DWORD' '1'
Write-Output "Disabling Sponsored Apps:"
Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'OemPreInstalledAppsEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'PreInstalledAppsEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SilentInstalledAppsEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'ContentDeliveryAllowed' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\PolicyManager\current\device\Start' 'ConfigureStartPins' 'REG_SZ' '{"pinnedList": [{}]}'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'FeatureManagementEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'PreInstalledAppsEverEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SoftLandingEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContentEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-310093Enabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338388Enabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338389Enabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338393Enabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-353694Enabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-353696Enabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SystemPaneSuggestionsEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\PushToInstall' 'DisablePushToInstall' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\MRT' 'DontOfferThroughWUAU' 'REG_DWORD' '1'
Remove-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\Subscriptions'
Remove-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\SuggestedApps'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableConsumerAccountStateContent' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableCloudOptimizedContent' 'REG_DWORD' '1'
Write-Output "Enabling Local Accounts on OOBE:"
Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE' 'BypassNRO' 'REG_DWORD' '1'
New-Item -ItemType Directory -Force -Path "$ScratchDisk\scratchdir\Windows\System32\Sysprep" | Out-Null
Copy-Item -Path "$PSScriptRoot\autounattend.xml" -Destination "$ScratchDisk\scratchdir\Windows\System32\Sysprep\autounattend.xml" -Force | Out-Null
New-Item -ItemType Directory -Force -Path "$ScratchDisk\scratchdir\Windows\Panther" | Out-Null
Copy-Item -Path "$PSScriptRoot\autounattend.xml" -Destination "$ScratchDisk\scratchdir\Windows\Panther\Unattend.xml" -Force | Out-Null
Add-LotusSetupPayload -MountPath "$ScratchDisk\scratchdir" -PayloadSource "$PSScriptRoot\payload"
Set-LotusDefaultWallpaper -MountPath "$ScratchDisk\scratchdir" -PayloadSource "$PSScriptRoot\payload"

Write-Output "Disabling Reserved Storage:"
Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager' 'ShippedWithReserves' 'REG_DWORD' '0'
Write-Output "Disabling BitLocker Device Encryption"
Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\BitLocker' 'PreventDeviceEncryption' 'REG_DWORD' '1'
Write-Output "Disabling Chat icon:"
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Chat' 'ChatIcon' 'REG_DWORD' '3'
Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarMn' 'REG_DWORD' '0'
Write-Output "Removing Edge related registries"
Remove-RegistryValue "HKEY_LOCAL_MACHINE\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge"
Remove-RegistryValue "HKEY_LOCAL_MACHINE\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge Update"
Write-Output "Disabling OneDrive folder backup"
Set-RegistryValue "HKLM\zSOFTWARE\Policies\Microsoft\Windows\OneDrive" "DisableFileSyncNGSC" "REG_DWORD" "1"
Write-Output "Disabling Telemetry:"
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' 'HasAccepted' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Input\TIPC' 'Enabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization' 'RestrictImplicitInkCollection' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization' 'RestrictImplicitTextCollection' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization\TrainedDataStore' 'HarvestContacts' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Personalization\Settings' 'AcceptedPrivacyPolicy' 'REG_DWORD' '0'
$personalDataExportKey = 'Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\PersonalDataExport'
foreach ($userHive in @('HKLM\zNTUSER', 'HKLM\zDEFAULT')) {
    Set-RegistryValue "$userHive\$personalDataExportKey" 'PDEShown' 'REG_DWORD' '2'
}
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\dmwappushservice' 'Start' 'REG_DWORD' '4'
## Prevents installation of DevHome and Outlook
Write-Output "Prevents installation of DevHome and Outlook:"
Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate' 'workCompleted' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\OutlookUpdate' 'workCompleted' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\DevHomeUpdate' 'workCompleted' 'REG_DWORD' '1'
Remove-RegistryValue 'HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate'
Remove-RegistryValue 'HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\DevHomeUpdate'
Write-Output "Disabling Copilot"
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Edge' 'HubsSidebarEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 'REG_DWORD' '1'
Write-Output "Prevents installation of Teams:"
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Teams' 'DisableInstallation' 'REG_DWORD' '1'
Write-Output "Prevent installation of New Outlook:"
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Mail' 'PreventRun' 'REG_DWORD' '1'

Write-Output "Applying Lotus desktop, privacy, update, and security defaults:"
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoUpdate' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'AUOptions' 'REG_DWORD' '2'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'ScheduledInstallDay' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'ScheduledInstallTime' 'REG_DWORD' '3'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'SetDisableUXWUAccess' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'ExcludeWUDriversInQualityUpdate' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config' 'DODownloadMode' 'REG_DWORD' '0'

Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender' 'DisableAntiSpyware' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender' 'DisableRealtimeMonitoring' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender' 'DisableSpecialRunningModes' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender' 'ServiceKeepAlive' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection' 'DisableBehaviorMonitoring' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection' 'DisableOnAccessProtection' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection' 'DisableRealtimeMonitoring' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection' 'DisableScanOnRealtimeEnable' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender\Spynet' 'SpynetReporting' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender\Spynet' 'SubmitSamplesConsent' 'REG_DWORD' '2'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\System' 'EnableSmartScreen' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' 'SmartScreenEnabled' 'REG_SZ' 'Off'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Edge' 'SmartScreenEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Edge' 'SmartScreenPuaEnabled' 'REG_DWORD' '0'

Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'EnableLUA' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'ConsentPromptBehaviorAdmin' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'PromptOnSecureDesktop' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'EnableFirstLogonAnimation' 'REG_DWORD' '0'

Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'LaunchTo' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'HideFileExt' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ShowSecondsInSystemClock' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAl' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarDa' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarGlomLevel' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'MMTaskbarGlomLevel' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'SearchboxTaskbarMode' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ShowTaskViewButton' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Start_Layout' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer' 'link' 'REG_BINARY' '00000000'
Set-RegistryDefaultValue 'HKLM\zNTUSER\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32' ''
$lotusDefaultWallpaper = 'C:\Windows\Setup\Lotus\Wallpapers\LotusDefault.jpg'
foreach ($desktopHive in @('HKLM\zDEFAULT\Control Panel\Desktop', 'HKLM\zNTUSER\Control Panel\Desktop')) {
    Set-RegistryValue $desktopHive 'WallPaper' 'REG_SZ' $lotusDefaultWallpaper
    Set-RegistryValue $desktopHive 'WallpaperStyle' 'REG_SZ' '10'
    Set-RegistryValue $desktopHive 'TileWallpaper' 'REG_SZ' '0'
}

Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Shell Icons' '29' 'REG_EXPAND_SZ' '%windir%\System32\imageres.dll,-17'
Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'NoDriveTypeAutoRun' 'REG_DWORD' '255'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers' 'DisableAutoplay' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zNTUSER\Control Panel\Desktop' 'AutoEndTasks' 'REG_SZ' '1'
Set-RegistryValue 'HKLM\zNTUSER\Control Panel\Desktop' 'HungAppTimeout' 'REG_SZ' '2000'
Set-RegistryValue 'HKLM\zNTUSER\Control Panel\Desktop' 'WaitToKillAppTimeout' 'REG_SZ' '2000'
Set-RegistryValue 'HKLM\zNTUSER\Control Panel\Desktop' 'MenuShowDelay' 'REG_SZ' '0'
Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control' 'WaitToKillServiceTimeout' 'REG_SZ' '2000'
Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\Power' 'HibernateEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\Power' 'HiberFileSizePercent' 'REG_DWORD' '0'

Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\PushNotifications' 'ToastEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings' 'NOC_GLOBAL_SETTING_ALLOW_TOASTS_ABOVE_LOCK' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings' 'NOC_GLOBAL_SETTING_ALLOW_CRITICAL_TOASTS_ABOVE_LOCK' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy' '01' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy' '04' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy' '08' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\InputMethod\Settings\CHS' 'Default Mode' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zNTUSER\Keyboard Layout\Preload' '1' 'REG_SZ' '00000804'

Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsSpotlightFeatures' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableSpotlightCollectionOnDesktop' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'RotatingLockScreenEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'RotatingLockScreenOverlayEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338387Enabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338389Enabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338393Enabled' 'REG_DWORD' '0'

Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\AppPrivacy' 'LetAppsAccessAccountInfo' 'REG_DWORD' '2'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\AppPrivacy' 'LetAppsAccessCallHistory' 'REG_DWORD' '2'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\AppPrivacy' 'LetAppsAccessContacts' 'REG_DWORD' '2'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\AppPrivacy' 'LetAppsAccessDiagnosticInfo' 'REG_DWORD' '2'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\AppPrivacy' 'LetAppsAccessEmail' 'REG_DWORD' '2'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\AppPrivacy' 'LetAppsGetDiagnosticInfo' 'REG_DWORD' '2'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\AppPrivacy' 'LetAppsAccessLocation' 'REG_DWORD' '2'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\AppPrivacy' 'LetAppsAccessMessaging' 'REG_DWORD' '2'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\AppPrivacy' 'LetAppsAccessMotion' 'REG_DWORD' '2'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\AppPrivacy' 'LetAppsAccessNotifications' 'REG_DWORD' '2'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\AppPrivacy' 'LetAppsAccessRadios' 'REG_DWORD' '2'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\AppPrivacy' 'LetAppsAccessTasks' 'REG_DWORD' '2'

Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows Photo Viewer\Capabilities\FileAssociations' '.bmp' 'REG_SZ' 'PhotoViewer.FileAssoc.Tiff'
Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows Photo Viewer\Capabilities\FileAssociations' '.dib' 'REG_SZ' 'PhotoViewer.FileAssoc.Tiff'
Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows Photo Viewer\Capabilities\FileAssociations' '.gif' 'REG_SZ' 'PhotoViewer.FileAssoc.Tiff'
Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows Photo Viewer\Capabilities\FileAssociations' '.jfif' 'REG_SZ' 'PhotoViewer.FileAssoc.Tiff'
Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows Photo Viewer\Capabilities\FileAssociations' '.jpe' 'REG_SZ' 'PhotoViewer.FileAssoc.Tiff'
Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows Photo Viewer\Capabilities\FileAssociations' '.jpeg' 'REG_SZ' 'PhotoViewer.FileAssoc.Tiff'
Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows Photo Viewer\Capabilities\FileAssociations' '.jpg' 'REG_SZ' 'PhotoViewer.FileAssoc.Tiff'
Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows Photo Viewer\Capabilities\FileAssociations' '.png' 'REG_SZ' 'PhotoViewer.FileAssoc.Tiff'
Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows Photo Viewer\Capabilities\FileAssociations' '.tif' 'REG_SZ' 'PhotoViewer.FileAssoc.Tiff'
Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows Photo Viewer\Capabilities\FileAssociations' '.tiff' 'REG_SZ' 'PhotoViewer.FileAssoc.Tiff'

$takeOwnershipText = -join ([char[]](31649,29702,21592,21462,24471,25152,26377,26435))
Set-RegistryValue 'HKLM\zSOFTWARE\Classes\*\shell\LotusTakeOwnership' 'MUIVerb' 'REG_SZ' $takeOwnershipText
Set-RegistryValue 'HKLM\zSOFTWARE\Classes\*\shell\LotusTakeOwnership' 'HasLUAShield' 'REG_SZ' '1'
Set-RegistryDefaultValue 'HKLM\zSOFTWARE\Classes\*\shell\LotusTakeOwnership\command' 'cmd.exe /c takeown /f "%1" && icacls "%1" /grant *S-1-5-32-544:F'
Set-RegistryValue 'HKLM\zSOFTWARE\Classes\Directory\shell\LotusTakeOwnership' 'MUIVerb' 'REG_SZ' $takeOwnershipText
Set-RegistryValue 'HKLM\zSOFTWARE\Classes\Directory\shell\LotusTakeOwnership' 'HasLUAShield' 'REG_SZ' '1'
Set-RegistryDefaultValue 'HKLM\zSOFTWARE\Classes\Directory\shell\LotusTakeOwnership\command' 'cmd.exe /c takeown /f "%1" /r /d y && icacls "%1" /grant *S-1-5-32-544:F /t'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'DontUsePowerShellOnWinX' 'REG_DWORD' '0'

$servicesToDisable = @(
    'DiagTrack',
    'dmwappushservice',
    'DoSvc',
    'MapsBroker',
    'PcaSvc',
    'RetailDemo',
    'SecurityHealthService',
    'Sense',
    'WdFilter',
    'WdNisDrv',
    'WdNisSvc',
    'WerSvc',
    'WinDefend'
)

foreach ($serviceName in $servicesToDisable) {
    if (Test-Path "HKLM:\zSYSTEM\ControlSet001\Services\$serviceName") {
        Set-RegistryValue "HKLM\zSYSTEM\ControlSet001\Services\$serviceName" 'Start' 'REG_DWORD' '4'
    }
}

Write-Host "Deleting scheduled task definition files..."
$tasksPath = "$ScratchDisk\scratchdir\Windows\System32\Tasks"

# Application Compatibility Appraiser
Remove-Item -Path "$tasksPath\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser" -Force -ErrorAction SilentlyContinue

# Customer Experience Improvement Program (removes the entire folder and all tasks within it)
Remove-Item -Path "$tasksPath\Microsoft\Windows\Customer Experience Improvement Program" -Recurse -Force -ErrorAction SilentlyContinue

# Program Data Updater
Remove-Item -Path "$tasksPath\Microsoft\Windows\Application Experience\ProgramDataUpdater" -Force -ErrorAction SilentlyContinue

# Chkdsk Proxy
Remove-Item -Path "$tasksPath\Microsoft\Windows\Chkdsk\Proxy" -Force -ErrorAction SilentlyContinue

# Windows Error Reporting (QueueReporting)
Remove-Item -Path "$tasksPath\Microsoft\Windows\Windows Error Reporting\QueueReporting" -Force -ErrorAction SilentlyContinue

# Extra background noise in the Lotus profile
Remove-Item -Path "$tasksPath\Microsoft\Windows\Maps" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$tasksPath\Microsoft\Windows\Windows Defender" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$tasksPath\Microsoft\Windows\WindowsUpdate\Scheduled Start" -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$tasksPath\Microsoft\Windows\UpdateOrchestrator\Schedule Scan" -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$tasksPath\Microsoft\Windows\UpdateOrchestrator\USO_UxBroker" -Force -ErrorAction SilentlyContinue
Write-Host "Task files have been deleted."
Write-Host "Removing retail demo and default Edge/IE leftovers..."
Remove-Item -Path "$ScratchDisk\scratchdir\ProgramData\Microsoft\Windows\RetailDemo" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$ScratchDisk\scratchdir\Users\Default\AppData\Local\Microsoft\Windows\RetailDemo" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$ScratchDisk\scratchdir\Users\Default\Favorites\Microsoft Websites" -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "Unmounting Registry..."
Invoke-RegCritical -Action "Unload registry hive HKLM\zCOMPONENTS" -Arguments @('unload', 'HKLM\zCOMPONENTS')
Invoke-RegCritical -Action "Unload registry hive HKLM\zDEFAULT" -Arguments @('unload', 'HKLM\zDEFAULT')
Invoke-RegCritical -Action "Unload registry hive HKLM\zNTUSER" -Arguments @('unload', 'HKLM\zNTUSER')
Invoke-RegCritical -Action "Unload registry hive HKLM\zSOFTWARE" -Arguments @('unload', 'HKLM\zSOFTWARE')
Invoke-RegCritical -Action "Unload registry hive HKLM\zSYSTEM" -Arguments @('unload', 'HKLM\zSYSTEM')
Write-Output "Skipping component cleanup because this offline image has pending servicing changes after feature/package updates."
Write-Output "Export-Image with recovery compression will still compact the final install.wim."
Write-Output ' '
Write-Output "Unmounting image..."
Invoke-DismCritical -Action "Commit and unmount install.wim" -Arguments @('/English', '/Unmount-Image', "/MountDir:$ScratchDisk\scratchdir", '/Commit')
Assert-ImageUnmounted "$ScratchDisk\scratchdir"
Write-Host "Exporting image..."
Invoke-DismCritical -Action "Export install.wim" -Arguments @('/Export-Image', "/SourceImageFile:$ScratchDisk\tiny11\sources\install.wim", "/SourceIndex:$index", "/DestinationImageFile:$ScratchDisk\tiny11\sources\install2.wim", '/Compress:recovery')
Remove-Item -Path "$ScratchDisk\tiny11\sources\install.wim" -Force | Out-Null
Rename-Item -Path "$ScratchDisk\tiny11\sources\install2.wim" -NewName "install.wim" | Out-Null
Write-Output "Windows image completed. Continuing with boot.wim."
Start-Sleep -Seconds 2
Clear-Host
Write-Output "Mounting boot image:"
$wimFilePath = "$ScratchDisk\tiny11\sources\boot.wim"
& takeown "/F" $wimFilePath | Out-Null
& icacls $wimFilePath "/grant" "$($adminGroup.Value):(F)"
Set-ItemProperty -Path $wimFilePath -Name IsReadOnly -Value $false
Mount-WindowsImage -ImagePath $ScratchDisk\tiny11\sources\boot.wim -Index 2 -Path $ScratchDisk\scratchdir -ErrorAction Stop
Assert-MountedImage "$ScratchDisk\scratchdir"
Write-Output "Loading registry..."
Invoke-RegCritical -Action "Load registry hive HKLM\zCOMPONENTS" -Arguments @('load', 'HKLM\zCOMPONENTS', "$ScratchDisk\scratchdir\Windows\System32\config\COMPONENTS")
Invoke-RegCritical -Action "Load registry hive HKLM\zDEFAULT" -Arguments @('load', 'HKLM\zDEFAULT', "$ScratchDisk\scratchdir\Windows\System32\config\default")
Invoke-RegCritical -Action "Load registry hive HKLM\zNTUSER" -Arguments @('load', 'HKLM\zNTUSER', "$ScratchDisk\scratchdir\Users\Default\ntuser.dat")
Invoke-RegCritical -Action "Load registry hive HKLM\zSOFTWARE" -Arguments @('load', 'HKLM\zSOFTWARE', "$ScratchDisk\scratchdir\Windows\System32\config\SOFTWARE")
Invoke-RegCritical -Action "Load registry hive HKLM\zSYSTEM" -Arguments @('load', 'HKLM\zSYSTEM', "$ScratchDisk\scratchdir\Windows\System32\config\SYSTEM")

Write-Output "Bypassing system requirements(on the setup image):"
Set-RegistryValue 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' 'SV1' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' 'SV2' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' 'SV1' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' 'SV2' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassCPUCheck' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassRAMCheck' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassSecureBootCheck' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassStorageCheck' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassTPMCheck' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSYSTEM\Setup\MoSetup' 'AllowUpgradesWithUnsupportedTPMOrCPU' 'REG_DWORD' '1'
Write-Output "Tweaking complete!"

Write-Output "Unmounting Registry..."
Invoke-RegCritical -Action "Unload registry hive HKLM\zCOMPONENTS" -Arguments @('unload', 'HKLM\zCOMPONENTS')
Invoke-RegCritical -Action "Unload registry hive HKLM\zDEFAULT" -Arguments @('unload', 'HKLM\zDEFAULT')
Invoke-RegCritical -Action "Unload registry hive HKLM\zNTUSER" -Arguments @('unload', 'HKLM\zNTUSER')
Invoke-RegCritical -Action "Unload registry hive HKLM\zSOFTWARE" -Arguments @('unload', 'HKLM\zSOFTWARE')
Invoke-RegCritical -Action "Unload registry hive HKLM\zSYSTEM" -Arguments @('unload', 'HKLM\zSYSTEM')

Write-Output "Unmounting image..."
Invoke-DismCritical -Action "Commit and unmount boot.wim" -Arguments @('/English', '/Unmount-Image', "/MountDir:$ScratchDisk\scratchdir", '/Commit')
Assert-ImageUnmounted "$ScratchDisk\scratchdir"
Clear-Host
Write-Output "The tiny11 image is now completed. Proceeding with the making of the ISO..."
Write-Output "Copying unattended file for bypassing MS account on OOBE..."
Copy-Item -Path "$PSScriptRoot\autounattend.xml" -Destination "$ScratchDisk\tiny11\autounattend.xml" -Force | Out-Null
Write-Output "Creating ISO image..."
$ADKDepTools = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\$hostarchitecture\Oscdimg"
$localOSCDIMGPath = "$PSScriptRoot\oscdimg.exe"

if ([System.IO.Directory]::Exists($ADKDepTools)) {
    Write-Output "Will be using oscdimg.exe from system ADK."
    $OSCDIMG = "$ADKDepTools\oscdimg.exe"
} else {
    Write-Output "ADK folder not found. Will be using bundled oscdimg.exe."
    $url = "https://msdl.microsoft.com/download/symbols/oscdimg.exe/3D44737265000/oscdimg.exe"

    if (-not (Test-Path -Path $localOSCDIMGPath)) {
        Write-Output "Downloading oscdimg.exe..."
        Invoke-WebRequest -Uri $url -OutFile $localOSCDIMGPath

        if (Test-Path $localOSCDIMGPath) {
            Write-Output "oscdimg.exe downloaded successfully."
        } else {
            Write-Error "Failed to download oscdimg.exe."
            exit 1
        }
    } else {
        Write-Output "oscdimg.exe already exists locally."
    }

    $OSCDIMG = $localOSCDIMGPath
}

& "$OSCDIMG" '-m' '-o' '-u2' '-udfver102' "-bootdata:2#p0,e,b$ScratchDisk\tiny11\boot\etfsboot.com#pEF,e,b$ScratchDisk\tiny11\efi\microsoft\boot\efisys.bin" "$ScratchDisk\tiny11" "$PSScriptRoot\tiny11.iso"
Assert-LastExitCode "Create tiny11 ISO"

# Finishing up
Write-Output "Creation completed! Press any key to exit the script..."
Read-Host "Press Enter to continue"
Write-Output "Performing Cleanup..."
Remove-CleanupPath -Path "$ScratchDisk\tiny11"
Remove-CleanupPath -Path "$ScratchDisk\scratchdir"
Write-Output "Ejecting Iso drive"
Get-Volume -DriveLetter $DriveLetter[0] | Get-DiskImage | Dismount-DiskImage
Write-Output "Iso drive ejected"
Write-Output "Removing oscdimg.exe..."
Remove-Item -Path "$PSScriptRoot\oscdimg.exe" -Force -ErrorAction SilentlyContinue
if ($DownloadedAutounattend) {
    Write-Output "Removing downloaded autounattend.xml..."
    Remove-Item -Path "$PSScriptRoot\autounattend.xml" -Force -ErrorAction SilentlyContinue
} else {
    Write-Output "Keeping repository autounattend.xml."
}

Write-Output "Cleanup check :"
if (Test-Path -Path "$ScratchDisk\tiny11") {
    Write-Output "tiny11 folder still exists. Attempting to remove it again..."
    Remove-CleanupPath -Path "$ScratchDisk\tiny11"
    if (Test-Path -Path "$ScratchDisk\tiny11") {
        Write-Output "Failed to remove tiny11 folder."
    } else {
        Write-Output "tiny11 folder removed successfully."
    }
} else {
    Write-Output "tiny11 folder does not exist. No action needed."
}
if (Test-Path -Path "$ScratchDisk\scratchdir") {
    Write-Output "scratchdir folder still exists. Attempting to remove it again..."
    Remove-CleanupPath -Path "$ScratchDisk\scratchdir"
    if (Test-Path -Path "$ScratchDisk\scratchdir") {
        Write-Output "Failed to remove scratchdir folder."
    } else {
        Write-Output "scratchdir folder removed successfully."
    }
} else {
    Write-Output "scratchdir folder does not exist. No action needed."
}
if (Test-Path -Path "$PSScriptRoot\oscdimg.exe") {
    Write-Output "oscdimg.exe still exists. Attempting to remove it again..."
    Remove-Item -Path "$PSScriptRoot\oscdimg.exe" -Force -ErrorAction SilentlyContinue
    if (Test-Path -Path "$PSScriptRoot\oscdimg.exe") {
        Write-Output "Failed to remove oscdimg.exe."
    } else {
        Write-Output "oscdimg.exe removed successfully."
    }
} else {
    Write-Output "oscdimg.exe does not exist. No action needed."
}
if ($DownloadedAutounattend -and (Test-Path -Path "$PSScriptRoot\autounattend.xml")) {
    Write-Output "autounattend.xml still exists. Attempting to remove it again..."
    Remove-Item -Path "$PSScriptRoot\autounattend.xml" -Force -ErrorAction SilentlyContinue
    if (Test-Path -Path "$PSScriptRoot\autounattend.xml") {
        Write-Output "Failed to remove autounattend.xml."
    } else {
        Write-Output "autounattend.xml removed successfully."
    }
} else {
    Write-Output "autounattend.xml cleanup skipped or already complete."
}

# Stop the transcript
Stop-Transcript

exit

