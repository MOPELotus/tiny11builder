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
        $output = & 'reg' 'add' $path '/v' $name '/t' $type '/d' $value '/f' 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "reg add failed for $path\$name ($LASTEXITCODE): $($output -join ' ')"
        }
        Write-Output "Set registry value: $path\$name"
    } catch {
        throw "Error setting registry value: $_"
    }
}

function Set-RegistryValueIfPossible {
    param (
        [string]$path,
        [string]$name,
        [string]$type,
        [string]$value
    )

    try {
        Set-RegistryValue $path $name $type $value
    } catch {
        Write-Output "Skipped optional registry value: $path\$name ($_)"
    }
}

function Remove-RegistryValue {
    param (
		[string]$path
	)
	try {
        $queryOutput = & 'reg' 'query' $path 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Output "Registry value/key already absent: $path"
            return
        }

		$output = & 'reg' 'delete' $path '/f' 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Output "Registry value/key already absent: $path"
            return
        }
		Write-Output "Removed registry value: $path"
	} catch {
		throw "Error removing registry value: $_"
	}
}

function Remove-RegistryNamedValue {
    param (
        [string]$path,
        [string]$name
    )
    try {
        $queryOutput = & 'reg' 'query' $path '/v' $name 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Output "Registry value already absent: $path\$name"
            return
        }

        $output = & 'reg' 'delete' $path '/v' $name '/f' 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Output "Registry value already absent: $path\$name"
            return
        }
        Write-Output "Removed registry value: $path\$name"
    } catch {
        throw "Error removing registry value: $_"
    }
}

function Set-RegistryDefaultValue {
    param (
        [string]$path,
        [string]$value
    )
    try {
        if ($value -eq '') {
            $output = & 'reg' 'add' $path '/ve' '/f' 2>&1
        } else {
            $output = & 'reg' 'add' $path '/ve' '/d' $value '/f' 2>&1
        }
        if ($LASTEXITCODE -ne 0) {
            throw "reg add default failed for $path ($LASTEXITCODE): $($output -join ' ')"
        }
        Write-Output "Set default registry value: $path"
    } catch {
        throw "Error setting default registry value: $_"
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

    $safeWallpaperRoot = Join-Path $MountPath 'Windows\Web\Wallpaper\Lotus'
    New-Item -ItemType Directory -Force -Path $safeWallpaperRoot | Out-Null
    Copy-Item -LiteralPath $wallpaperSource.FullName -Destination (Join-Path $safeWallpaperRoot 'LotusDefault.jpg') -Force -ErrorAction Stop

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
        Get-ChildItem -LiteralPath $lotusRoot -Recurse -File -ErrorAction SilentlyContinue |
            ForEach-Object {
                Unblock-File -LiteralPath $_.FullName -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $_.FullName -Stream Zone.Identifier -ErrorAction SilentlyContinue
            }
    } else {
        Write-Output "No payload folder found at $PayloadSource. Runtime, font, Store/Xbox, and PowerShell installers will be skipped unless added later."
    }

    $postInstallScript = @'
param (
    [string]$Stage = 'SetupComplete'
)

$ErrorActionPreference = 'SilentlyContinue'
$env:SEE_MASK_NOZONECHECKS = '1'
$root = Join-Path $env:WINDIR 'Setup\Lotus'
$lotusLowRiskFileTypes = '.exe;.msi;.msp;.msu;.cmd;.bat;.ps1;.psm1;.vbs;.js;.jse;.wsf;.reg;.scr;.com;.cpl;.dll;.hta;.chm;.jar;.zip;.7z;.rar;.iso;'

if (Test-Path $root) {
    Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
        ForEach-Object {
            Unblock-File -LiteralPath $_.FullName -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $_.FullName -Stream Zone.Identifier -ErrorAction SilentlyContinue
        }
}

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

function Write-LotusFileLog {
    param (
        [string]$Path,
        [string]$Message
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$timestamp] $Message"
    Add-Content -Path $Path -Value $line -Encoding ASCII
    Write-Output $line
}

function Get-LotusAppxPackagePriority {
    param ([string]$Name)

    switch -Regex ($Name) {
        'Microsoft\.NET\.Native\.Framework' { return 10 }
        'Microsoft\.NET\.Native\.Runtime' { return 11 }
        'Microsoft\.VCLibs' { return 12 }
        'Microsoft\.UI\.Xaml' { return 13 }
        'Microsoft\.WindowsAppRuntime' { return 14 }
        'Microsoft\.Services\.Store\.Engagement' { return 15 }
        'Microsoft\.WindowsStore' { return 30 }
        'Microsoft\.StorePurchaseApp' { return 31 }
        'Microsoft\.DesktopAppInstaller' { return 32 }
        'Microsoft\.XboxIdentityProvider' { return 40 }
        'Microsoft\.GamingServices' { return 41 }
        'Microsoft\.XboxGamingOverlay' { return 42 }
        'Microsoft\.GamingApp' { return 43 }
        default { return 90 }
    }
}

function Get-LotusAppxPayloadPackages {
    param ([string]$StoreRoot)

    if (-not (Test-Path $StoreRoot)) {
        return @()
    }

    return @(
        Get-ChildItem -Path $StoreRoot -Recurse -File |
            Where-Object { $_.Extension.ToLowerInvariant() -in @('.appx', '.appxbundle', '.msix', '.msixbundle') } |
            Sort-Object @{ Expression = { Get-LotusAppxPackagePriority $_.Name } }, Name
    )
}

function Get-LotusAppxDependencyPaths {
    param (
        [object[]]$Packages,
        [System.IO.FileInfo]$Package
    )

    $dependencyPattern = 'Microsoft\.(NET\.Native|VCLibs|UI\.Xaml|WindowsAppRuntime|Services\.Store\.Engagement)'
    if ($Package.Name -match $dependencyPattern) {
        return @()
    }

    return @(
        $Packages |
            Where-Object { $_.Name -match $dependencyPattern } |
            Select-Object -ExpandProperty FullName
    )
}

function Get-LotusAppxLicensePath {
    param (
        [string]$StoreRoot,
        [System.IO.FileInfo]$Package
    )

    $baseName = $Package.Name -replace '\.(appx|appxbundle|msix|msixbundle)$', ''
    $packageFamily = $null
    if ($baseName -match '^(Microsoft\.[^_]+)_.*_([A-Za-z0-9]+)$') {
        $packageFamily = "$($matches[1])_$($matches[2])"
    }

    if ($packageFamily) {
        $license = Get-ChildItem -Path $StoreRoot -Recurse -File -Filter "$packageFamily.xml" |
            Select-Object -First 1
        if ($license) {
            return $license.FullName
        }
    }

    return $null
}

function Write-LotusAppxState {
    param (
        [string]$LogPath,
        [string]$Scope
    )

    Write-LotusFileLog $LogPath "Current AppX state: $Scope"
    try {
        Get-AppxPackage -AllUsers |
            Where-Object { $_.Name -match 'Microsoft.WindowsStore|Microsoft.StorePurchaseApp|Microsoft.DesktopAppInstaller|Microsoft.GamingApp|Microsoft.GamingServices|Microsoft.XboxIdentityProvider|Microsoft.XboxGamingOverlay' } |
            Format-List Name,PackageFullName,Status |
            Out-String |
            Add-Content -Path $LogPath -Encoding ASCII
    } catch {
        Write-LotusFileLog $LogPath "AppX state query failed: $($_.Exception.Message)"
    }
}

function Test-LotusLtscStorePayload {
    $ltscRoot = Join-Path $root 'Store\LTSC-Add-MicrosoftStore'
    return (Test-Path (Join-Path $ltscRoot 'Add-Store.cmd')) -and
        (Test-Path (Join-Path $ltscRoot '*WindowsStore*.appxbundle')) -and
        (Test-Path (Join-Path $ltscRoot '*WindowsStore*.xml'))
}

function Invoke-LotusLtscStoreScript {
    param ([string]$Stage)

    $storeLog = Join-Path $root 'LtscStoreInstall.log'
    $ltscRoot = Join-Path $root 'Store\LTSC-Add-MicrosoftStore'
    $addStoreCmd = Join-Path $ltscRoot 'Add-Store.cmd'

    if (-not (Test-LotusLtscStorePayload)) {
        Write-LotusFileLog $storeLog "LTSC Store payload not found or incomplete at $ltscRoot."
        return
    }

    Write-LotusFileLog $storeLog "Running LTSC Store script during $Stage from $addStoreCmd."
    Write-LotusAppxState -LogPath $storeLog -Scope "before LTSC Store script ($Stage)"

    $stdout = Join-Path $root "LtscStoreInstall-$Stage.out.log"
    $stderr = Join-Path $root "LtscStoreInstall-$Stage.err.log"
    Remove-Item -LiteralPath $stdout, $stderr -Force -ErrorAction SilentlyContinue

    $command = "cd /d `"$ltscRoot`" && echo. | `"$addStoreCmd`""
    if ($Stage -match 'FirstLogon') {
        try {
            & cmd.exe /d /c $command 2>&1 |
                ForEach-Object {
                    $line = $_.ToString()
                    if ($line.Trim().Length -gt 0) {
                        Write-LotusFileLog $storeLog $line
                    } else {
                        Write-Output ''
                    }
                }
            Write-LotusFileLog $storeLog "LTSC Store script exit code: $LASTEXITCODE ($Stage)"
        } catch {
            Write-LotusFileLog $storeLog "LTSC Store script failed to start: $($_.Exception.Message)"
        }
    } else {
        try {
            $process = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/d', '/c', $command) -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
            if ($process.WaitForExit(600000)) {
                Write-LotusFileLog $storeLog "LTSC Store script exit code: $($process.ExitCode) ($Stage)"
            } else {
                Write-LotusFileLog $storeLog "LTSC Store script timed out after 10 minutes; stopping process."
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            }
        } catch {
            Write-LotusFileLog $storeLog "LTSC Store script failed to start: $($_.Exception.Message)"
        }

        foreach ($logFile in @($stdout, $stderr)) {
            if (Test-Path $logFile) {
                Add-Content -Path $storeLog -Value "---- $([System.IO.Path]::GetFileName($logFile)) ----" -Encoding ASCII
                Get-Content -Path $logFile -ErrorAction SilentlyContinue | Add-Content -Path $storeLog -Encoding ASCII
                Remove-Item -LiteralPath $logFile -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Write-LotusAppxState -LogPath $storeLog -Scope "after LTSC Store script ($Stage)"
    return
}

function Install-LotusProvisionedAppxPayload {
    $storeRoot = Join-Path $root 'Store'
    $storeLog = Join-Path $root 'StorePayloadInstall.log'

    if (-not (Test-Path $storeRoot)) {
        Write-LotusFileLog $storeLog "No Store payload folder found at $storeRoot."
        return
    }

    $packages = @(Get-LotusAppxPayloadPackages $storeRoot)
    if (Test-LotusLtscStorePayload) {
        $ltscRoot = Join-Path $storeRoot 'LTSC-Add-MicrosoftStore'
        $packages = @($packages | Where-Object { -not $_.FullName.StartsWith($ltscRoot, [System.StringComparison]::OrdinalIgnoreCase) })
        Write-LotusFileLog $storeLog "LTSC Store payload detected; provisioning it through Add-Store.cmd instead of the generic AppX loop."
    }

    if ($packages.Count -eq 0) {
        Write-LotusFileLog $storeLog "No Store AppX/MSIX payload packages found at $storeRoot."
        return
    }

    Write-LotusFileLog $storeLog "Provisioning $($packages.Count) Store AppX/MSIX payload package(s)."
    foreach ($package in $packages) {
        $dependencyPaths = @(Get-LotusAppxDependencyPaths -Packages $packages -Package $package)
        $licensePath = Get-LotusAppxLicensePath -StoreRoot $storeRoot -Package $package
        $params = @{
            Online = $true
            PackagePath = $package.FullName
            ErrorAction = 'Stop'
        }

        if ($dependencyPaths.Count -gt 0) {
            $params['DependencyPackagePath'] = $dependencyPaths
        }

        if ($licensePath) {
            $params['LicensePath'] = $licensePath
            Write-LotusFileLog $storeLog "Provisioning $($package.Name) with license $([System.IO.Path]::GetFileName($licensePath))."
        } else {
            $params['SkipLicense'] = $true
            Write-LotusFileLog $storeLog "Provisioning $($package.Name) with SkipLicense."
        }

        try {
            Add-AppxProvisionedPackage @params 2>&1 |
                Out-String |
                Add-Content -Path $storeLog -Encoding ASCII
            Write-LotusFileLog $storeLog "Provisioned $($package.Name)."
        } catch {
            Write-LotusFileLog $storeLog "Provisioning failed for $($package.Name): $($_.Exception.Message)"
        }
    }

    Write-LotusAppxState -LogPath $storeLog -Scope 'after provisioned Store payload install'
}

function Start-LotusMicrosoftStoreInstaller {
    param ([switch]$AllUsers)

    $storeLog = Join-Path $root 'MicrosoftStoreInstaller.log'
    $storeInstaller = Join-Path $root 'Store\MicrosoftStoreInstaller.exe'

    if (-not (Test-Path $storeInstaller)) {
        Write-LotusFileLog $storeLog "No Microsoft Store installer found at $storeInstaller."
        return
    }

    Write-LotusFileLog $storeLog "Starting Microsoft Store installer from $storeInstaller."
    try {
        $signature = Get-AuthenticodeSignature -FilePath $storeInstaller
        Write-LotusFileLog $storeLog "Microsoft Store installer signature: $($signature.Status), signer: $($signature.SignerCertificate.Subject)"
    } catch {
        Write-LotusFileLog $storeLog "Microsoft Store installer signature check failed: $($_.Exception.Message)"
    }

    $arguments = '--silent'
    if ($AllUsers) {
        $arguments = '--silent --allusers'
    }

    try {
        $process = Start-Process -FilePath $storeInstaller -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden
        Write-LotusFileLog $storeLog "Microsoft Store installer exit code: $($process.ExitCode) ($arguments)"
    } catch {
        Write-LotusFileLog $storeLog "Microsoft Store installer failed: $($_.Exception.Message)"
    }

    Write-LotusAppxState -LogPath $storeLog -Scope 'after Microsoft Store installer'
}

function Install-LotusCurrentUserAppxPayload {
    $storeRoot = Join-Path $root 'Store'
    $storeLog = Join-Path $root 'StorePayloadUserInstall.log'

    if (-not (Test-Path $storeRoot)) {
        Write-LotusFileLog $storeLog "No Store payload folder found at $storeRoot."
        return
    }

    $packages = @(Get-LotusAppxPayloadPackages $storeRoot)
    if (Test-LotusLtscStorePayload) {
        $ltscRoot = Join-Path $storeRoot 'LTSC-Add-MicrosoftStore'
        $packages = @($packages | Where-Object { -not $_.FullName.StartsWith($ltscRoot, [System.StringComparison]::OrdinalIgnoreCase) })
        Write-LotusFileLog $storeLog "LTSC Store payload detected; current-user Store install will be handled by Add-Store.cmd."
    }

    if ($packages.Count -eq 0) {
        Write-LotusFileLog $storeLog "No Store AppX/MSIX payload packages found at $storeRoot."
        return
    }

    Write-LotusFileLog $storeLog "Installing $($packages.Count) Store AppX/MSIX payload package(s) for $env:USERNAME."
    foreach ($package in $packages) {
        try {
            Write-LotusFileLog $storeLog "Installing $($package.Name) for current user."
            Add-AppxPackage -Path $package.FullName -ErrorAction Stop 2>&1 |
                Out-String |
                Add-Content -Path $storeLog -Encoding ASCII
            Write-LotusFileLog $storeLog "Installed $($package.Name) for current user."
        } catch {
            Write-LotusFileLog $storeLog "Current-user install failed for $($package.Name): $($_.Exception.Message)"
        }
    }

    Write-LotusAppxState -LogPath $storeLog -Scope 'after current-user Store payload install'
}

function Repair-LotusMicrosoftStore {
    $storeLog = Join-Path $root 'MicrosoftStoreRepair.log'

    Write-LotusFileLog $storeLog 'Starting Microsoft Store repair.'
    Write-LotusAppxState -LogPath $storeLog -Scope 'before Store repair'

    try {
        $process = Start-Process -FilePath 'wsreset.exe' -ArgumentList '-i' -Wait -PassThru -WindowStyle Hidden
        Write-LotusFileLog $storeLog "wsreset -i exit code: $($process.ExitCode)"
    } catch {
        Write-LotusFileLog $storeLog "wsreset -i failed: $($_.Exception.Message)"
    }

    try {
        $storePackage = Get-AppxPackage -Name 'Microsoft.WindowsStore' -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($storePackage) {
            $manifest = Join-Path $storePackage.InstallLocation 'AppxManifest.xml'
            if (Test-Path $manifest) {
                Add-AppxPackage -DisableDevelopmentMode -Register $manifest -ErrorAction Stop
                Write-LotusFileLog $storeLog 'Re-registered Microsoft Store manifest.'
            }
        }
    } catch {
        Write-LotusFileLog $storeLog "Microsoft Store manifest registration failed: $($_.Exception.Message)"
    }

    Write-LotusAppxState -LogPath $storeLog -Scope 'after Store repair'
}

function Start-LotusXboxInstaller {
    $xboxLog = Join-Path $root 'XboxInstaller.log'
    $xboxInstaller = Join-Path $root 'XboxInstaller\XboxInstaller.exe'

    if (-not (Test-Path $xboxInstaller)) {
        Write-LotusFileLog $xboxLog "No Xbox installer found at $xboxInstaller."
        return
    }

    Write-LotusFileLog $xboxLog "Starting Xbox installer from $xboxInstaller."
    try {
        $signature = Get-AuthenticodeSignature -FilePath $xboxInstaller
        Write-LotusFileLog $xboxLog "Xbox installer signature: $($signature.Status), signer: $($signature.SignerCertificate.Subject)"
    } catch {
        Write-LotusFileLog $xboxLog "Xbox installer signature check failed: $($_.Exception.Message)"
    }

    Write-LotusAppxState -LogPath $xboxLog -Scope 'before Xbox installer'

    try {
        $process = Start-Process -FilePath $xboxInstaller -ArgumentList '-startpage AppInstall' -PassThru
        Write-LotusFileLog $xboxLog "Xbox installer started with PID $($process.Id)."
        if ($process.WaitForExit(600000)) {
            Write-LotusFileLog $xboxLog "Xbox installer exit code: $($process.ExitCode)"
        } else {
            Write-LotusFileLog $xboxLog 'Xbox installer is still running after 10 minutes; leaving it open for user-context install.'
        }
    } catch {
        Write-LotusFileLog $xboxLog "Xbox installer failed to start: $($_.Exception.Message)"
    }

    Write-LotusAppxState -LogPath $xboxLog -Scope 'after Xbox installer'
}

function Set-LotusCurrentUserRegValue {
    param (
        [string]$Path,
        [string]$Name,
        [string]$PropertyType,
        $Value
    )

    New-Item -Path $Path -Force | Out-Null
    New-ItemProperty -Path $Path -Name $Name -PropertyType $PropertyType -Value $Value -Force | Out-Null
}

function Set-LotusCurrentUserDefaults {
    param ([switch]$RestartExplorer)

    Write-Output "Applying Lotus current-user defaults for $env:USERNAME"

    try {
        Set-WinHomeLocation -GeoId 244
    } catch {
        Write-Output "Set-WinHomeLocation failed: $_"
    }
    Set-LotusCurrentUserRegValue 'HKCU:\Control Panel\International\Geo' 'Name' 'String' 'US'
    Set-LotusCurrentUserRegValue 'HKCU:\Control Panel\International\Geo' 'Nation' 'String' '244'

    Set-LotusCurrentUserRegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'AppsUseLightTheme' 'DWord' 1
    Set-LotusCurrentUserRegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'SystemUsesLightTheme' 'DWord' 1
    Set-LotusCurrentUserRegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 'DWord' 1
    Set-LotusCurrentUserRegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes' 'CurrentTheme' 'String' 'C:\Windows\Resources\Themes\aero.theme'

    Set-LotusCurrentUserRegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'LaunchTo' 'DWord' 1
    Set-LotusCurrentUserRegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'HideFileExt' 'DWord' 0
    Set-LotusCurrentUserRegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ShowSecondsInSystemClock' 'DWord' 1
    Set-LotusCurrentUserRegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAl' 'DWord' 0
    Set-LotusCurrentUserRegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarDa' 'DWord' 0
    Set-LotusCurrentUserRegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarGlomLevel' 'DWord' 0
    Set-LotusCurrentUserRegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'MMTaskbarGlomLevel' 'DWord' 0
    Set-LotusCurrentUserRegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'SearchboxTaskbarMode' 'DWord' 1
    Set-LotusCurrentUserRegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ShowTaskViewButton' 'DWord' 0
    Set-LotusCurrentUserRegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Start_Layout' 'DWord' 1
    Set-LotusCurrentUserRegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarMn' 'DWord' 0
    Set-LotusCurrentUserRegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' 'link' 'Binary' ([byte[]](0, 0, 0, 0))

    Set-LotusCurrentUserRegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 'DWord' 0
    Set-LotusCurrentUserRegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 'DWord' 0
    Set-LotusCurrentUserRegValue 'HKCU:\SOFTWARE\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' 'HasAccepted' 'DWord' 0
    Set-LotusCurrentUserRegValue 'HKCU:\SOFTWARE\Microsoft\Input\TIPC' 'Enabled' 'DWord' 0
    Set-LotusCurrentUserRegValue 'HKCU:\SOFTWARE\Microsoft\InputPersonalization' 'RestrictImplicitInkCollection' 'DWord' 1
    Set-LotusCurrentUserRegValue 'HKCU:\SOFTWARE\Microsoft\InputPersonalization' 'RestrictImplicitTextCollection' 'DWord' 1
    Set-LotusCurrentUserRegValue 'HKCU:\SOFTWARE\Microsoft\InputPersonalization\TrainedDataStore' 'HarvestContacts' 'DWord' 0
    Set-LotusCurrentUserRegValue 'HKCU:\SOFTWARE\Microsoft\Personalization\Settings' 'AcceptedPrivacyPolicy' 'DWord' 0
    Set-LotusCurrentUserRegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\PersonalDataExport' 'PDEShown' 'DWord' 2
    Set-LotusCurrentUserRegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Attachments' 'SaveZoneInformation' 'DWord' 1
    Set-LotusCurrentUserRegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Associations' 'LowRiskFileTypes' 'String' $lotusLowRiskFileTypes
    Set-LotusCurrentUserRegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\Zones\0' '1806' 'DWord' 0
    Set-LotusCurrentUserRegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\Zones\1' '1806' 'DWord' 0
    Set-LotusCurrentUserRegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\Zones\2' '1806' 'DWord' 0
    Set-LotusCurrentUserRegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\Zones\3' '1806' 'DWord' 0
    Set-LotusCurrentUserRegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\Zones\4' '1806' 'DWord' 0

    Set-LotusCurrentUserRegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers' 'DisableAutoplay' 'DWord' 1
    Set-LotusCurrentUserRegValue 'HKCU:\Control Panel\Desktop' 'AutoEndTasks' 'String' '1'
    Set-LotusCurrentUserRegValue 'HKCU:\Control Panel\Desktop' 'HungAppTimeout' 'String' '2000'
    Set-LotusCurrentUserRegValue 'HKCU:\Control Panel\Desktop' 'WaitToKillAppTimeout' 'String' '2000'
    Set-LotusCurrentUserRegValue 'HKCU:\Control Panel\Desktop' 'MenuShowDelay' 'String' '0'
    Set-LotusCurrentUserRegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\PushNotifications' 'ToastEnabled' 'DWord' 0
    Set-LotusCurrentUserRegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings' 'NOC_GLOBAL_SETTING_ALLOW_TOASTS_ABOVE_LOCK' 'DWord' 0
    Set-LotusCurrentUserRegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings' 'NOC_GLOBAL_SETTING_ALLOW_CRITICAL_TOASTS_ABOVE_LOCK' 'DWord' 0
    Set-LotusCurrentUserRegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy' '01' 'DWord' 1
    Set-LotusCurrentUserRegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy' '04' 'DWord' 1
    Set-LotusCurrentUserRegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy' '08' 'DWord' 1
    Set-LotusCurrentUserRegValue 'HKCU:\SOFTWARE\Microsoft\InputMethod\Settings\CHS' 'Default Mode' 'DWord' 1
    Set-LotusCurrentUserRegValue 'HKCU:\Keyboard Layout\Preload' '1' 'String' '00000804'
    Set-LotusCurrentUserRegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'DontUsePowerShellOnWinX' 'DWord' 0

    Set-LotusCurrentUserRegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'RotatingLockScreenEnabled' 'DWord' 0
    Set-LotusCurrentUserRegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'RotatingLockScreenOverlayEnabled' 'DWord' 0
    Set-LotusCurrentUserRegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'OemPreInstalledAppsEnabled' 'DWord' 0
    Set-LotusCurrentUserRegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'PreInstalledAppsEnabled' 'DWord' 0
    Set-LotusCurrentUserRegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SilentInstalledAppsEnabled' 'DWord' 0
    Set-LotusCurrentUserRegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'ContentDeliveryAllowed' 'DWord' 0
    Set-LotusCurrentUserRegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'FeatureManagementEnabled' 'DWord' 0
    Set-LotusCurrentUserRegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'PreInstalledAppsEverEnabled' 'DWord' 0
    Set-LotusCurrentUserRegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SoftLandingEnabled' 'DWord' 0
    Set-LotusCurrentUserRegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContentEnabled' 'DWord' 0
    Set-LotusCurrentUserRegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-310093Enabled' 'DWord' 0
    Set-LotusCurrentUserRegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338387Enabled' 'DWord' 0
    Set-LotusCurrentUserRegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338388Enabled' 'DWord' 0
    Set-LotusCurrentUserRegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338389Enabled' 'DWord' 0
    Set-LotusCurrentUserRegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338393Enabled' 'DWord' 0
    Set-LotusCurrentUserRegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-353694Enabled' 'DWord' 0
    Set-LotusCurrentUserRegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-353696Enabled' 'DWord' 0
    Set-LotusCurrentUserRegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SystemPaneSuggestionsEnabled' 'DWord' 0
    Remove-Item -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\Subscriptions' -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\SuggestedApps' -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CloudStore\Store\Cache\DefaultAccount' -Recurse -Force -ErrorAction SilentlyContinue

    $lotusDefaultWallpaper = 'C:\Windows\Web\Wallpaper\Lotus\LotusDefault.jpg'
    if (-not (Test-Path $lotusDefaultWallpaper)) {
        $lotusDefaultWallpaper = Join-Path $root 'Wallpapers\LotusDefault.jpg'
    }
    if (Test-Path $lotusDefaultWallpaper) {
        Set-LotusCurrentUserRegValue 'HKCU:\Control Panel\Desktop' 'WallPaper' 'String' $lotusDefaultWallpaper
        Set-LotusCurrentUserRegValue 'HKCU:\Control Panel\Desktop' 'WallpaperStyle' 'String' '10'
        Set-LotusCurrentUserRegValue 'HKCU:\Control Panel\Desktop' 'TileWallpaper' 'String' '0'
    }

    & reg.exe add 'HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32' '/ve' '/f' | Out-Null
    if ($RestartExplorer) {
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
        Start-Process -FilePath explorer.exe -ErrorAction SilentlyContinue
    }
}

function Test-LotusAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Start-LotusElevatedStage {
    param ([string]$StageName)

    $argumentList = "-NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Stage $StageName"
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argumentList -Verb RunAs -WindowStyle Normal
}

function Invoke-LotusRestartCountdown {
    param (
        [string]$LogPath,
        [int]$Seconds = 20
    )

    Write-LotusFileLog $LogPath "Lotus first-logon setup is complete. Windows will restart in $Seconds seconds."
    Write-LotusFileLog $LogPath 'Press Ctrl+C in this window before the countdown ends if you need to cancel the restart.'
    for ($remaining = $Seconds; $remaining -gt 0; $remaining--) {
        Write-Host ("Restarting in {0} second(s)..." -f $remaining)
        Start-Sleep -Seconds 1
    }

    & shutdown.exe /r /t 5 /f /c "Lotus setup finished; restarting to apply settings."
}

function Invoke-LotusFirstLogonSetup {
    param ([switch]$RestartAfterComplete)

    $logPath = Join-Path $root 'LotusFirstLogon.log'
    $transcriptPath = Join-Path $root 'LotusFirstLogonTranscript.log'
    New-Item -ItemType Directory -Force -Path $root | Out-Null

    try {
        $Host.UI.RawUI.WindowTitle = 'Lotus First-Logon Setup'
    } catch {
    }

    Write-Host ''
    Write-Host '============================================================'
    Write-Host ' Lotus first-logon setup'
    Write-Host '============================================================'
    Write-Host ''
    Write-LotusFileLog $logPath "Visible first-logon setup started for $env:USERNAME."
    Write-LotusFileLog $logPath "Main log: $logPath"
    Write-LotusFileLog $logPath "Transcript: $transcriptPath"

    $transcriptStarted = $false
    try {
        Start-Transcript -Path $transcriptPath -Append | Out-Null
        $transcriptStarted = $true
    } catch {
        Write-LotusFileLog $logPath "Transcript start failed: $($_.Exception.Message)"
    }

    try {
        Write-LotusFileLog $logPath 'Waiting 60 seconds for Explorer and Windows shell personalization to settle.'
        Start-Sleep -Seconds 60

        Write-LotusFileLog $logPath '[1/6] Applying current-user defaults.'
        Set-LotusCurrentUserDefaults -RestartExplorer

        Write-LotusFileLog $logPath '[2/6] Restoring Microsoft Store components.'
        if (Test-LotusLtscStorePayload) {
            Invoke-LotusLtscStoreScript -Stage 'FirstLogonVisible'
        } else {
            Install-LotusCurrentUserAppxPayload
            Start-LotusMicrosoftStoreInstaller
        }

        Write-LotusFileLog $logPath '[3/6] Repairing Microsoft Store registration.'
        Repair-LotusMicrosoftStore

        Write-LotusFileLog $logPath '[4/6] Starting Xbox installer.'
        Start-LotusXboxInstaller

        Write-LotusFileLog $logPath '[5/6] Reapplying current-user defaults after app registration.'
        Set-LotusCurrentUserDefaults -RestartExplorer

        Write-LotusFileLog $logPath '[6/6] Capturing final Store/Xbox AppX state.'
        Write-LotusAppxState -LogPath $logPath -Scope 'after visible first-logon setup'

        New-Item -Path 'HKLM:\SOFTWARE\Lotus\FirstLogon' -Force | Out-Null
        New-ItemProperty -Path 'HKLM:\SOFTWARE\Lotus\FirstLogon' -Name 'Completed' -PropertyType DWord -Value 1 -Force | Out-Null
        New-ItemProperty -Path 'HKLM:\SOFTWARE\Lotus\FirstLogon' -Name 'CompletedAt' -PropertyType String -Value (Get-Date -Format s) -Force | Out-Null
        Write-LotusFileLog $logPath 'Visible first-logon setup finished.'
    } catch {
        Write-LotusFileLog $logPath "Visible first-logon setup hit an unhandled error: $($_.Exception.Message)"
    } finally {
        if ($transcriptStarted) {
            try {
                Stop-Transcript | Out-Null
            } catch {
            }
        }
    }

    if ($RestartAfterComplete) {
        Invoke-LotusRestartCountdown -LogPath $logPath -Seconds 20
    }
}

function Invoke-LotusUserDefaultsVisible {
    $logPath = Join-Path $root 'LotusUserDefaults.log'
    try {
        $Host.UI.RawUI.WindowTitle = 'Lotus User Defaults'
    } catch {
    }

    Write-LotusFileLog $logPath "Applying visible user defaults for $env:USERNAME."
    Start-Sleep -Seconds 10
    Set-LotusCurrentUserDefaults -RestartExplorer
    Write-LotusFileLog $logPath "Visible user defaults finished for $env:USERNAME."
}

if ($Stage -eq 'FirstLogonVisible') {
    if (-not (Test-LotusAdministrator)) {
        Start-LotusElevatedStage -StageName $Stage
        exit 0
    }

    Invoke-LotusFirstLogonSetup -RestartAfterComplete
    exit 0
}

if ($Stage -eq 'FirstLogon') {
    Invoke-LotusFirstLogonSetup
    exit 0
}

if ($Stage -eq 'UserDefaultsVisible') {
    Invoke-LotusUserDefaultsVisible
    exit 0
}

if ($Stage -eq 'UserDefaults') {
    Set-LotusCurrentUserDefaults
    exit 0
}

if ($Stage -eq 'UserDefaultsDelayed') {
    Start-Sleep -Seconds 25
    Set-LotusCurrentUserDefaults -RestartExplorer
    exit 0
}

reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v EnableLUA /t REG_DWORD /d 1 /f | Out-Null
reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v ConsentPromptBehaviorAdmin /t REG_DWORD /d 0 /f | Out-Null
reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v PromptOnSecureDesktop /t REG_DWORD /d 0 /f | Out-Null

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
            if ($_.Name -match '2005') {
                Write-Output "Skipping unsupported VC++ 2005 installer: $($_.Name)"
            } else {
                Start-LotusProcess $_.FullName (Get-VCRedistArguments $_.Name)
            }
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

Install-LotusProvisionedAppxPayload
if (Test-LotusLtscStorePayload) {
    Invoke-LotusLtscStoreScript -Stage 'SetupComplete' | Out-Null
} else {
    Start-LotusMicrosoftStoreInstaller -AllUsers
}
'@

    $firstLogonCmd = @'
@echo off
set SEE_MASK_NOZONECHECKS=1
title Lotus First-Logon Setup
cd /d "%WINDIR%\Setup\Lotus"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%WINDIR%\Setup\Lotus\LotusPostInstall.ps1" -Stage FirstLogonVisible
exit /b %ERRORLEVEL%
'@

    $userDefaultsCmd = @'
@echo off
set SEE_MASK_NOZONECHECKS=1
title Lotus User Defaults
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%WINDIR%\Setup\Lotus\LotusPostInstall.ps1" -Stage UserDefaultsVisible
exit /b %ERRORLEVEL%
'@

    $setupComplete = @'
@echo off
set SEE_MASK_NOZONECHECKS=1
set LOG=%WINDIR%\Setup\Lotus\LotusPostInstall.log
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%WINDIR%\Setup\Lotus\LotusPostInstall.ps1" >> "%LOG%" 2>&1
exit /b 0
'@

    Set-Content -Path (Join-Path $lotusRoot 'LotusPostInstall.ps1') -Value $postInstallScript -Encoding ASCII
    Set-Content -Path (Join-Path $lotusRoot 'LotusFirstLogon.cmd') -Value $firstLogonCmd -Encoding ASCII
    Set-Content -Path (Join-Path $lotusRoot 'LotusUserDefaults.cmd') -Value $userDefaultsCmd -Encoding ASCII
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
Copy-Item -Path "$DriveLetter\*" -Destination "$ScratchDisk\tiny11" -Recurse -Force -ErrorAction Stop | Out-Null
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
Write-Output "Keeping Microsoft Edge WebView runtime for Store, Xbox, and OOBE compatibility."
Write-Output "Removing OneDrive:"
if (Test-Path -Path "$ScratchDisk\scratchdir\Windows\System32\OneDriveSetup.exe") {
    & takeown.exe '/f' "$ScratchDisk\scratchdir\Windows\System32\OneDriveSetup.exe" 2>&1 | Out-Null
    & icacls.exe "$ScratchDisk\scratchdir\Windows\System32\OneDriveSetup.exe" '/grant' '*S-1-5-32-544:F' '/C' 2>&1 | Out-Null
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
Write-Output "Taskbar current-user defaults are applied at first logon."
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
Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' 'ProfilesDirectory' 'REG_EXPAND_SZ' '%SystemDrive%\Users'
Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' 'Default' 'REG_EXPAND_SZ' '%SystemDrive%\Users\Default'
Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' 'Public' 'REG_EXPAND_SZ' '%SystemDrive%\Users\Public'
foreach ($geoHive in @('HKLM\zNTUSER', 'HKLM\zDEFAULT')) {
    Set-RegistryValue "$geoHive\Control Panel\International\Geo" 'Name' 'REG_SZ' 'US'
    Set-RegistryValue "$geoHive\Control Panel\International\Geo" 'Nation' 'REG_SZ' '244'
}
Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\Nls\Geo' 'Name' 'REG_SZ' 'US'
Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\Nls\Geo' 'Nation' 'REG_SZ' '244'
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
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Feeds' 'EnableFeeds' 'REG_DWORD' '0'

Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'EnableLUA' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'ConsentPromptBehaviorAdmin' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'PromptOnSecureDesktop' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'EnableFirstLogonAnimation' 'REG_DWORD' '0'

Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'LaunchTo' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'HideFileExt' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ShowSecondsInSystemClock' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAl' 'REG_DWORD' '0'
Set-RegistryValueIfPossible 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarDa' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarGlomLevel' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'MMTaskbarGlomLevel' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'SearchboxTaskbarMode' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ShowTaskViewButton' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Start_Layout' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarMn' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer' 'link' 'REG_BINARY' '00000000'
Remove-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\Cache\DefaultAccount'
foreach ($themeHive in @('HKLM\zNTUSER', 'HKLM\zDEFAULT')) {
    Set-RegistryValue "$themeHive\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" 'AppsUseLightTheme' 'REG_DWORD' '1'
    Set-RegistryValue "$themeHive\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" 'SystemUsesLightTheme' 'REG_DWORD' '1'
    Set-RegistryValue "$themeHive\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" 'EnableTransparency' 'REG_DWORD' '1'
    Set-RegistryValue "$themeHive\Software\Microsoft\Windows\CurrentVersion\Themes" 'CurrentTheme' 'REG_SZ' 'C:\Windows\Resources\Themes\aero.theme'
}
$classicContextMenuKey = 'Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32'
foreach ($userHive in @('HKLM\zNTUSER', 'HKLM\zDEFAULT')) {
    Set-RegistryDefaultValue "$userHive\$classicContextMenuKey" ''
}
$classicContextActiveSetup = 'HKLM\zSOFTWARE\Microsoft\Active Setup\Installed Components\LotusClassicContextMenu'
Set-RegistryDefaultValue $classicContextActiveSetup 'Lotus Classic Context Menu'
Set-RegistryValue $classicContextActiveSetup 'IsInstalled' 'REG_DWORD' '1'
Set-RegistryValue $classicContextActiveSetup 'Version' 'REG_SZ' '1,0,0,0'
Set-RegistryValue $classicContextActiveSetup 'StubPath' 'REG_EXPAND_SZ' 'cmd.exe /d /c reg add "HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32" /ve /f'
Remove-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Active Setup\Installed Components\LotusUserDefaults'
Remove-RegistryNamedValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' 'LotusFirstLogonStoreXbox'
Remove-RegistryNamedValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' '000LotusUserDefaults'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\RunOnce' 'LotusFirstLogonStoreXbox' 'REG_SZ' 'cmd.exe /d /c ""C:\Windows\Setup\Lotus\LotusFirstLogon.cmd""'
$lotusDefaultWallpaper = 'C:\Windows\Web\Wallpaper\Lotus\LotusDefault.jpg'
foreach ($desktopHive in @('HKLM\zDEFAULT\Control Panel\Desktop', 'HKLM\zNTUSER\Control Panel\Desktop')) {
    Set-RegistryValue $desktopHive 'WallPaper' 'REG_SZ' $lotusDefaultWallpaper
    Set-RegistryValue $desktopHive 'WallpaperStyle' 'REG_SZ' '10'
    Set-RegistryValue $desktopHive 'TileWallpaper' 'REG_SZ' '0'
}

Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Shell Icons' '29' 'REG_EXPAND_SZ' '%windir%\System32\imageres.dll,-17'
Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'NoDriveTypeAutoRun' 'REG_DWORD' '255'
$lotusLowRiskFileTypes = '.exe;.msi;.msp;.msu;.cmd;.bat;.ps1;.psm1;.vbs;.js;.jse;.wsf;.reg;.scr;.com;.cpl;.dll;.hta;.chm;.jar;.zip;.7z;.rar;.iso;'
Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Attachments' 'SaveZoneInformation' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Associations' 'LowRiskFileTypes' 'REG_SZ' $lotusLowRiskFileTypes
foreach ($attachmentHive in @('HKLM\zNTUSER', 'HKLM\zDEFAULT')) {
    Set-RegistryValue "$attachmentHive\Software\Microsoft\Windows\CurrentVersion\Policies\Attachments" 'SaveZoneInformation' 'REG_DWORD' '1'
    Set-RegistryValue "$attachmentHive\Software\Microsoft\Windows\CurrentVersion\Policies\Associations" 'LowRiskFileTypes' 'REG_SZ' $lotusLowRiskFileTypes
    foreach ($zone in 0..4) {
        Set-RegistryValue "$attachmentHive\Software\Microsoft\Windows\CurrentVersion\Internet Settings\Zones\$zone" '1806' 'REG_DWORD' '0'
    }
}
foreach ($zone in 0..4) {
    Set-RegistryValue "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\Zones\$zone" '1806' 'REG_DWORD' '0'
}
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

Set-RegistryDefaultValue 'HKLM\zSOFTWARE\Classes\.txt' 'txtfile'
Set-RegistryValue 'HKLM\zSOFTWARE\Classes\.txt' 'Content Type' 'REG_SZ' 'text/plain'
Set-RegistryValue 'HKLM\zSOFTWARE\Classes\.txt' 'PerceivedType' 'REG_SZ' 'text'
Set-RegistryValue 'HKLM\zSOFTWARE\Classes\.txt\ShellNew' 'NullFile' 'REG_SZ' ''
Set-RegistryValue 'HKLM\zSOFTWARE\Classes\.txt\ShellNew' 'ItemName' 'REG_EXPAND_SZ' '@%SystemRoot%\system32\notepad.exe,-470'
Set-RegistryDefaultValue 'HKLM\zSOFTWARE\Classes\txtfile' 'Text Document'
Set-RegistryDefaultValue 'HKLM\zSOFTWARE\Classes\txtfile\DefaultIcon' '%SystemRoot%\system32\imageres.dll,-102'
Set-RegistryDefaultValue 'HKLM\zSOFTWARE\Classes\txtfile\shell\open\command' '%SystemRoot%\system32\notepad.exe "%1"'

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

