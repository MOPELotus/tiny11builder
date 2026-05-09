param(
    [string]$SourceIso = 'C:\Users\Lotus\Downloads\26200.8328_amd64_zh-cn_professional_2de8f468_convert_virtual\Lotus_tiny11_26100_ProWorkstation_zh-cn.iso',
    [string]$RepoRoot = 'C:\Users\Lotus\tiny11builder',
    [string]$UupRoot = 'C:\Users\Lotus\Downloads\26200.8328_amd64_zh-cn_professional_2de8f468_convert_virtual',
    [string]$OutputIso = ''
)

$ErrorActionPreference = 'Stop'

$buildRoot = Join-Path $UupRoot 'LotusQuickPatch'
$logPath = Join-Path $buildRoot 'quickpatch.log'
$statusPath = Join-Path $buildRoot 'status.json'
$isoRoot = Join-Path $buildRoot 'iso'
$mountDir = Join-Path $buildRoot 'mount'
$mountedIso = $false
$mountedWim = $false
$loadedHives = New-Object System.Collections.Generic.List[string]

function Write-Log {
    param([string]$Message)

    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -Path $logPath -Value $line -Encoding UTF8
    Write-Host $line
}

function Write-Status {
    param(
        [string]$Status,
        [string]$Step,
        [string]$FinalIso = '',
        [string]$ErrorMessage = ''
    )

    [pscustomobject]@{
        status = $Status
        step = $Step
        sourceIso = $SourceIso
        finalIso = $FinalIso
        log = $logPath
        error = $ErrorMessage
        updated = (Get-Date).ToString('s')
    } | ConvertTo-Json | Set-Content -Path $statusPath -Encoding UTF8
}

function Invoke-Logged {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList,
        [int]$AllowedExitCodeMax = 0
    )

    Write-Log ("RUN {0} {1}" -f $FilePath, ($ArgumentList -join ' '))
    $previousErrorActionPreference = $ErrorActionPreference
    $hadNativeErrorActionPreference = Test-Path variable:PSNativeCommandUseErrorActionPreference
    if ($hadNativeErrorActionPreference) {
        $previousNativeErrorActionPreference = $PSNativeCommandUseErrorActionPreference
    }

    try {
        $ErrorActionPreference = 'Continue'
        if ($hadNativeErrorActionPreference) {
            $PSNativeCommandUseErrorActionPreference = $false
        }

        & $FilePath @ArgumentList 2>&1 | ForEach-Object { Write-Log ($_ | Out-String).TrimEnd() }
        $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
        Write-Log "EXIT $exitCode"
        if ($exitCode -gt $AllowedExitCodeMax) {
            throw "$FilePath exited with code $exitCode"
        }
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
        if ($hadNativeErrorActionPreference) {
            $PSNativeCommandUseErrorActionPreference = $previousNativeErrorActionPreference
        }
    }
}

function Assert-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Quick patch must run elevated.'
    }
    Write-Log "Running elevated as $($identity.Name)"
}

function Get-IsoDriveLetter {
    param([string]$ImagePath)

    $disk = Get-DiskImage -ImagePath $ImagePath
    $volume = $disk | Get-Volume | Where-Object DriveLetter | Select-Object -First 1
    if (-not $volume) {
        throw "No drive letter found for mounted ISO: $ImagePath"
    }
    return [string]$volume.DriveLetter
}

function Get-HereStringVariable {
    param(
        [string]$Text,
        [string]$Name
    )

    $pattern = '(?s)\$' + [regex]::Escape($Name) + '\s*=\s*@''\r?\n(?<value>.*?)\r?\n''@'
    $match = [regex]::Match($Text, $pattern)
    if (-not $match.Success) {
        throw "Could not find here-string variable: $Name"
    }
    return $match.Groups['value'].Value
}

function Set-RegValue {
    param(
        [string]$Path,
        [string]$Name,
        [string]$Type,
        [string]$Value
    )

    Invoke-Logged -FilePath reg.exe -ArgumentList @('add', $Path, '/v', $Name, '/t', $Type, '/d', $Value, '/f')
}

function Set-RegValueIfPossible {
    param(
        [string]$Path,
        [string]$Name,
        [string]$Type,
        [string]$Value
    )

    try {
        Set-RegValue $Path $Name $Type $Value
    } catch {
        Write-Log "Skipped optional registry value: $Path\$Name ($($_.Exception.Message))"
    }
}

function Set-RegDefaultValue {
    param(
        [string]$Path,
        [string]$Value = ''
    )

    if ($Value -eq '') {
        Invoke-Logged -FilePath reg.exe -ArgumentList @('add', $Path, '/ve', '/f')
    } else {
        Invoke-Logged -FilePath reg.exe -ArgumentList @('add', $Path, '/ve', '/d', $Value, '/f')
    }
}

function Remove-RegKey {
    param([string]$Path)

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & reg.exe query $Path *> $null
    $queryExitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorActionPreference
    if ($queryExitCode -ne 0) {
        Write-Log "Registry key already absent: $Path"
        return
    }
    Invoke-Logged -FilePath reg.exe -ArgumentList @('delete', $Path, '/f')
}

function Remove-RegNamedValue {
    param(
        [string]$Path,
        [string]$Name
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & reg.exe query $Path /v $Name *> $null
    $queryExitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorActionPreference
    if ($queryExitCode -ne 0) {
        Write-Log "Registry value already absent: $Path\$Name"
        return
    }
    Invoke-Logged -FilePath reg.exe -ArgumentList @('delete', $Path, '/v', $Name, '/f')
}

function Load-Hive {
    param(
        [string]$Name,
        [string]$Path
    )

    $hivePath = "HKLM\$Name"
    if (Test-Path -LiteralPath "Registry::HKEY_LOCAL_MACHINE\$Name") {
        Write-Log "Unloading stale hive before reload: $hivePath" | Out-Null
        Invoke-Logged -FilePath reg.exe -ArgumentList @('unload', $hivePath) | Out-Null
    } else {
        Write-Log "No stale hive loaded for $hivePath." | Out-Null
    }

    Invoke-Logged -FilePath reg.exe -ArgumentList @('load', $hivePath, $Path) | Out-Null
    $loadedHives.Add($hivePath)
    return $hivePath
}

function Unload-Hives {
    foreach ($hive in @($loadedHives.ToArray() | Sort-Object -Descending)) {
        Write-Log "Unloading hive: $hive"
        & reg.exe unload $hive 2>&1 | ForEach-Object { Write-Log ($_ | Out-String).TrimEnd() }
    }
    $loadedHives.Clear()
}

function Set-LotusOfflineUserDefaults {
    param(
        [string]$NtUserHive,
        [string]$DefaultHive,
        [string]$SoftwareHive
    )

    $advanced = "$NtUserHive\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
    Set-RegValue $advanced 'LaunchTo' 'REG_DWORD' '1'
    Set-RegValue $advanced 'HideFileExt' 'REG_DWORD' '0'
    Set-RegValue $advanced 'ShowSecondsInSystemClock' 'REG_DWORD' '1'
    Set-RegValue $advanced 'TaskbarAl' 'REG_DWORD' '0'
    Set-RegValueIfPossible $advanced 'TaskbarDa' 'REG_DWORD' '0'
    Set-RegValue $advanced 'TaskbarGlomLevel' 'REG_DWORD' '0'
    Set-RegValue $advanced 'MMTaskbarGlomLevel' 'REG_DWORD' '0'
    Set-RegValue $advanced 'SearchboxTaskbarMode' 'REG_DWORD' '1'
    Set-RegValue $advanced 'ShowTaskViewButton' 'REG_DWORD' '0'
    Set-RegValue $advanced 'Start_Layout' 'REG_DWORD' '1'
    Set-RegValue $advanced 'TaskbarMn' 'REG_DWORD' '0'
    Set-RegValue "$NtUserHive\Software\Microsoft\Windows\CurrentVersion\Explorer" 'link' 'REG_BINARY' '00000000'

    foreach ($themeHive in @($NtUserHive, $DefaultHive)) {
        Set-RegValue "$themeHive\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" 'AppsUseLightTheme' 'REG_DWORD' '1'
        Set-RegValue "$themeHive\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" 'SystemUsesLightTheme' 'REG_DWORD' '1'
        Set-RegValue "$themeHive\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" 'EnableTransparency' 'REG_DWORD' '1'
        Set-RegValue "$themeHive\Software\Microsoft\Windows\CurrentVersion\Themes" 'CurrentTheme' 'REG_SZ' 'C:\Windows\Resources\Themes\aero.theme'
        Set-RegValue "$themeHive\Control Panel\Desktop" 'WallPaper' 'REG_SZ' 'C:\Windows\Web\Wallpaper\Lotus\LotusDefault.jpg'
        Set-RegValue "$themeHive\Control Panel\Desktop" 'WallpaperStyle' 'REG_SZ' '10'
        Set-RegValue "$themeHive\Control Panel\Desktop" 'TileWallpaper' 'REG_SZ' '0'
    }

    Remove-RegKey "$NtUserHive\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\Cache\DefaultAccount"

    $classicContextKey = 'Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32'
    Set-RegDefaultValue "$NtUserHive\$classicContextKey"
    Set-RegDefaultValue "$DefaultHive\$classicContextKey"

    Remove-RegKey "$SoftwareHive\Microsoft\Active Setup\Installed Components\LotusUserDefaults"
    Remove-RegNamedValue "$SoftwareHive\Microsoft\Windows\CurrentVersion\RunOnce" 'LotusFirstLogonStoreXbox'
    Remove-RegNamedValue "$SoftwareHive\Microsoft\Windows\CurrentVersion\RunOnce" '000LotusUserDefaults'

    Set-RegValue "$NtUserHive\Software\Microsoft\Windows\CurrentVersion\RunOnce" 'LotusFirstLogonStoreXbox' 'REG_SZ' 'cmd.exe /d /c ""C:\Windows\Setup\Lotus\LotusFirstLogon.cmd""'
}

try {
    New-Item -ItemType Directory -Force -Path $buildRoot | Out-Null
    Set-Content -Path $logPath -Value "Lotus quick patch started: $(Get-Date -Format s)" -Encoding UTF8
    Write-Status -Status 'running' -Step 'preflight'
    Assert-Admin

    if (-not (Test-Path -LiteralPath $SourceIso)) {
        throw "Source ISO not found: $SourceIso"
    }

    if ([string]::IsNullOrWhiteSpace($OutputIso)) {
        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $OutputIso = Join-Path (Split-Path -Parent $SourceIso) "Lotus_tiny11_26100_ProWorkstation_zh-cn_quick_$timestamp.iso"
    }

    $resolvedBuildRoot = [System.IO.Path]::GetFullPath($buildRoot)
    $resolvedExpectedRoot = [System.IO.Path]::GetFullPath((Join-Path $UupRoot 'LotusQuickPatch'))
    if ($resolvedBuildRoot -ne $resolvedExpectedRoot) {
        throw "Refusing to clean unexpected work root: $resolvedBuildRoot"
    }

    foreach ($path in @($isoRoot, $mountDir)) {
        if (Test-Path -LiteralPath $path) {
            Write-Log "Removing stale quick-patch path: $path"
            Remove-Item -LiteralPath $path -Recurse -Force
        }
        New-Item -ItemType Directory -Force -Path $path | Out-Null
    }

    Write-Status -Status 'running' -Step 'copy iso'
    $existingSourceMount = Get-DiskImage -ImagePath $SourceIso -ErrorAction SilentlyContinue
    if ($existingSourceMount -and $existingSourceMount.Attached) {
        Write-Log "Dismounting previously mounted source ISO: $SourceIso"
        Dismount-DiskImage -ImagePath $SourceIso | Out-Null
        Start-Sleep -Seconds 1
    }
    $disk = Mount-DiskImage -ImagePath $SourceIso -PassThru
    $mountedIso = $true
    Start-Sleep -Seconds 2
    $drive = Get-IsoDriveLetter -ImagePath $SourceIso
    Write-Log "Mounted source ISO as $drive`:"
    Invoke-Logged -FilePath robocopy.exe -ArgumentList @("$drive`:\", $isoRoot, '/E', '/COPY:DAT', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NP') -AllowedExitCodeMax 7
    Dismount-DiskImage -ImagePath $SourceIso | Out-Null
    $mountedIso = $false

    Get-ChildItem -LiteralPath $isoRoot -Recurse -Force |
        ForEach-Object { $_.Attributes = $_.Attributes -band (-bnot [IO.FileAttributes]::ReadOnly) }

    $wimPath = Join-Path $isoRoot 'sources\install.wim'
    if (-not (Test-Path -LiteralPath $wimPath)) {
        throw "install.wim not found in copied ISO: $wimPath"
    }

    Write-Status -Status 'running' -Step 'mount wim'
    Invoke-Logged -FilePath dism.exe -ArgumentList @('/English', '/Mount-Image', "/ImageFile:$wimPath", '/Index:1', "/MountDir:$mountDir")
    $mountedWim = $true

    Write-Status -Status 'running' -Step 'patch scripts'
    Write-Log 'Patching Lotus first-logon scripts.'
    $makerText = Get-Content -LiteralPath (Join-Path $RepoRoot 'tiny11maker.ps1') -Raw
    $lotusRoot = Join-Path $mountDir 'Windows\Setup\Lotus'
    $scriptsRoot = Join-Path $mountDir 'Windows\Setup\Scripts'
    New-Item -ItemType Directory -Force -Path $lotusRoot, $scriptsRoot | Out-Null
    Set-Content -Path (Join-Path $lotusRoot 'LotusPostInstall.ps1') -Value (Get-HereStringVariable -Text $makerText -Name 'postInstallScript') -Encoding ASCII
    Set-Content -Path (Join-Path $lotusRoot 'LotusFirstLogon.cmd') -Value (Get-HereStringVariable -Text $makerText -Name 'firstLogonCmd') -Encoding ASCII
    Set-Content -Path (Join-Path $lotusRoot 'LotusUserDefaults.cmd') -Value (Get-HereStringVariable -Text $makerText -Name 'userDefaultsCmd') -Encoding ASCII
    Set-Content -Path (Join-Path $scriptsRoot 'SetupComplete.cmd') -Value (Get-HereStringVariable -Text $makerText -Name 'setupComplete') -Encoding ASCII
    Remove-Item -LiteralPath (Join-Path $lotusRoot 'LotusFirstLogon.vbs'), (Join-Path $lotusRoot 'LotusUserDefaults.vbs') -Force -ErrorAction SilentlyContinue

    Write-Status -Status 'running' -Step 'patch store payload'
    $repoStorePayload = Join-Path $RepoRoot 'payload\Store'
    $imageStorePayload = Join-Path $lotusRoot 'Store'
    if (Test-Path -LiteralPath $repoStorePayload) {
        Write-Log "Replacing Store payload from $repoStorePayload."
        Remove-Item -LiteralPath $imageStorePayload -Recurse -Force -ErrorAction SilentlyContinue
        Copy-Item -LiteralPath $repoStorePayload -Destination $imageStorePayload -Recurse -Force
    } else {
        Write-Log "No repository Store payload found at $repoStorePayload."
    }

    Write-Status -Status 'running' -Step 'patch registry'
    Write-Log 'Patching offline Default User registry.'
    $ntUser = Load-Hive -Name 'LotusQuick_NTUSER' -Path (Join-Path $mountDir 'Users\Default\ntuser.dat')
    $defaultHive = Load-Hive -Name 'LotusQuick_DEFAULT' -Path (Join-Path $mountDir 'Windows\System32\config\default')
    $softwareHive = Load-Hive -Name 'LotusQuick_SOFTWARE' -Path (Join-Path $mountDir 'Windows\System32\config\SOFTWARE')
    Set-LotusOfflineUserDefaults -NtUserHive $ntUser -DefaultHive $defaultHive -SoftwareHive $softwareHive
    Unload-Hives

    Write-Status -Status 'running' -Step 'commit wim'
    Invoke-Logged -FilePath dism.exe -ArgumentList @('/English', '/Unmount-Image', "/MountDir:$mountDir", '/Commit')
    $mountedWim = $false

    Write-Status -Status 'running' -Step 'create iso'
    $cdimage = Join-Path $UupRoot 'bin\cdimage.exe'
    if (-not (Test-Path -LiteralPath $cdimage)) {
        $cdimage = Join-Path $RepoRoot 'oscdimg.exe'
    }
    if (-not (Test-Path -LiteralPath $cdimage)) {
        throw "cdimage/oscdimg not found."
    }

    if (Test-Path -LiteralPath $OutputIso) {
        Remove-Item -LiteralPath $OutputIso -Force
    }
    Invoke-Logged -FilePath $cdimage -ArgumentList @('-m', '-o', '-u2', '-udfver102', "-bootdata:2#p0,e,b$isoRoot\boot\etfsboot.com#pEF,e,b$isoRoot\efi\microsoft\boot\efisys.bin", $isoRoot, $OutputIso)

    $item = Get-Item -LiteralPath $OutputIso
    Write-Log "Quick-patched ISO: $OutputIso"
    Write-Log "Final size bytes: $($item.Length)"
    Write-Status -Status 'completed' -Step 'done' -FinalIso $OutputIso
    exit 0
} catch {
    $message = $_.Exception.Message
    if ([string]::IsNullOrWhiteSpace($message)) {
        $message = ($_ | Out-String).Trim()
    }
    Write-Log "FAILED: $message"
    Write-Status -Status 'failed' -Step 'failed' -ErrorMessage $message
    exit 1
} finally {
    try {
        Unload-Hives
    } catch {
    }
    if ($mountedWim) {
        try {
            Write-Log "Discarding mounted WIM after failure."
            & dism.exe /English /Unmount-Image "/MountDir:$mountDir" /Discard 2>&1 |
                ForEach-Object { Write-Log ($_ | Out-String).TrimEnd() }
        } catch {
        }
    }
    if ($mountedIso) {
        try {
            Dismount-DiskImage -ImagePath $SourceIso | Out-Null
        } catch {
        }
    }
}
