param(
    [string]$UupRoot = 'C:\Users\Lotus\Downloads\26200.8328_amd64_zh-cn_professional_2de8f468_convert_virtual',
    [string]$RepoRoot = 'C:\Users\Lotus\tiny11builder',
    [string]$ScratchDrive = 'C'
)

$ErrorActionPreference = 'Stop'

$buildRoot = Join-Path $UupRoot 'LotusTiny11Build'
$logPath = Join-Path $buildRoot 'lotus-workstation-build.log'
$statusPath = Join-Path $buildRoot 'status.json'
$transcriptPath = Join-Path $buildRoot 'transcript.log'
New-Item -ItemType Directory -Force -Path $buildRoot | Out-Null
Set-Content -Path $logPath -Value "Lotus tiny11 Pro Workstation build started: $(Get-Date -Format s)" -Encoding UTF8

function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -Path $logPath -Value $line -Encoding UTF8
    Write-Output $line
}

function Write-Status {
    param(
        [string]$Status,
        [string]$Step,
        [string]$FinalIso = '',
        [string]$WorkstationIso = '',
        [string]$ErrorMessage = ''
    )

    [pscustomobject]@{
        status = $Status
        step = $Step
        finalIso = $FinalIso
        workstationIso = $WorkstationIso
        log = $logPath
        error = $ErrorMessage
        updated = (Get-Date).ToString('s')
    } | ConvertTo-Json | Set-Content -Path $statusPath -Encoding UTF8
}

function Invoke-Logged {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList,
        [string]$WorkingDirectory,
        [switch]$AllowNonZero
    )

    Write-Log ("RUN {0} {1}" -f $FilePath, ($ArgumentList -join ' '))
    Push-Location $WorkingDirectory
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $FilePath @ArgumentList 2>&1 | ForEach-Object { Write-Log ($_ | Out-String).TrimEnd() }
        $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
        Write-Log "EXIT $exitCode"
        if ($exitCode -ne 0 -and -not $AllowNonZero) {
            throw "$FilePath exited with code $exitCode"
        }
    } finally {
        $ErrorActionPreference = $previousPreference
        Pop-Location
    }
}

function Invoke-CleanupCommand {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList,
        [string]$WorkingDirectory = $RepoRoot
    )

    Write-Log ("CLEANUP {0} {1}" -f $FilePath, ($ArgumentList -join ' '))
    Push-Location $WorkingDirectory
    try {
        & $FilePath @ArgumentList 2>&1 |
            ForEach-Object { Write-Log ($_ | Out-String).TrimEnd() }
        $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
        Write-Log "CLEANUP EXIT $exitCode"
        return $exitCode
    } finally {
        Pop-Location
    }
}

function Unload-StaleLotusRegistryHives {
    foreach ($hive in @('zCOMPONENTS', 'zNTUSER', 'zSOFTWARE', 'zSYSTEM', 'zDEFAULT')) {
        if (Test-Path -LiteralPath "Registry::HKEY_LOCAL_MACHINE\$hive") {
            Write-Log "Unloading stale registry hive: HKLM\$hive"
            & reg.exe unload "HKLM\$hive" 2>&1 |
                ForEach-Object { Write-Log ($_ | Out-String).TrimEnd() }
            Write-Log "Hive unload exit code for ${hive}: $LASTEXITCODE"
        }
    }
}

function Clear-StaleScratchMount {
    $scratchDir = Join-Path (Join-Path $RepoRoot 'build') 'scratchdir'
    if (Test-Path -LiteralPath $scratchDir) {
        Invoke-CleanupCommand -FilePath dism.exe -ArgumentList @('/English', '/Unmount-Image', "/MountDir:$scratchDir", '/Discard') | Out-Null
    }
    Unload-StaleLotusRegistryHives
    Invoke-CleanupCommand -FilePath dism.exe -ArgumentList @('/English', '/Cleanup-Mountpoints') | Out-Null
}

function Set-IniValue {
    param(
        [string]$Path,
        [string]$Key,
        [string]$Value
    )

    $content = Get-Content -LiteralPath $Path -Raw
    $pattern = "(?im)^$([regex]::Escape($Key))=.*$"
    if ($content -match $pattern) {
        $content = [regex]::Replace($content, $pattern, "$Key=$Value")
    } else {
        $content = $content.TrimEnd() + "`r`n$Key=$Value`r`n"
    }
    Set-Content -LiteralPath $Path -Value $content -Encoding ASCII
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

function Stop-StaleBuildProcesses {
    $ownPid = $PID
    $repoPattern = [regex]::Escape($RepoRoot)
    $staleProcesses = Get-CimInstance Win32_Process |
        Where-Object {
            ($_.ProcessId -ne $ownPid) -and (
                ($_.CommandLine -match $repoPattern) -or
                ($_.Name -in @('Dism.exe', 'dism.exe', 'oscdimg.exe'))
            )
        }

    foreach ($process in $staleProcesses) {
        Write-Log "Stopping stale build process: PID $($process.ProcessId) $($process.Name)"
        Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

$mountedImages = @()

try {
    Start-Transcript -Path $transcriptPath -Force | Out-Null
    Write-Status -Status 'running' -Step 'preflight'

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This build script must run elevated.'
    }
    Write-Log "Running elevated as $($identity.Name)"
    Stop-StaleBuildProcesses

    $sourceFolder = Join-Path $UupRoot '26100.1.240331-1435.GE_RELEASE_CLIENTMULTI_X64FRE_ZH-CN'
    $sourceWim = Join-Path $sourceFolder 'sources\install.wim'
    $createVirtual = Join-Path $UupRoot 'create_virtual_editions.cmd'
    $convertConfig = Join-Path $UupRoot 'ConvertConfig.ini'
    $cdimage = Join-Path $UupRoot 'bin\cdimage.exe'
    $tinyMaker = Join-Path $RepoRoot 'tiny11maker.ps1'

    foreach ($requiredPath in @($sourceWim, $createVirtual, $convertConfig, $cdimage, $tinyMaker)) {
        if (-not (Test-Path -LiteralPath $requiredPath)) {
            throw "Required path missing: $requiredPath"
        }
    }

    Write-Status -Status 'running' -Step 'cleanup stale mounts'
    Invoke-Logged -FilePath dism.exe -ArgumentList @('/English', '/Cleanup-Mountpoints') -WorkingDirectory $RepoRoot -AllowNonZero
    Invoke-Logged -FilePath dism.exe -ArgumentList @('/English', '/Cleanup-Wim') -WorkingDirectory $RepoRoot -AllowNonZero
    Clear-StaleScratchMount

    $scratchRoot = Join-Path $RepoRoot 'build'
    foreach ($scratchPath in @((Join-Path $scratchRoot 'scratchdir'), (Join-Path $scratchRoot 'tiny11'))) {
        $resolved = [System.IO.Path]::GetFullPath($scratchPath)
        if ($resolved -in @((Join-Path $scratchRoot 'scratchdir'), (Join-Path $scratchRoot 'tiny11'))) {
            if (Test-Path -LiteralPath $resolved) {
                Write-Log "Removing stale scratch path: $resolved"
                Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue 2>$null
                Start-Sleep -Seconds 1
                if (Test-Path -LiteralPath $resolved) {
                    throw "Failed to remove stale scratch path, likely locked by another process: $resolved"
                }
            }
        }
    }

    $workstationIso = Get-ChildItem -LiteralPath $UupRoot -Filter '*.iso' |
        Where-Object {
            ($_.Name -match 'CLIENTPROWORKSTATION|WORKSTATION|PROWORK') -and
            ($_.Name -notmatch 'tiny11|Lotus')
        } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if (-not $workstationIso) {
        Write-Status -Status 'running' -Step 'create pro workstation source iso'
        $configBackup = "$convertConfig.lotus-build.bak"
        Copy-Item -LiteralPath $convertConfig -Destination $configBackup -Force
        try {
            Set-IniValue -Path $convertConfig -Key 'vUseDism' -Value '0'
            Set-IniValue -Path $convertConfig -Key 'vAutoStart' -Value '1'
            Set-IniValue -Path $convertConfig -Key 'vDeleteSource' -Value '1'
            Set-IniValue -Path $convertConfig -Key 'vPreserve' -Value '1'
            Set-IniValue -Path $convertConfig -Key 'vwim2esd' -Value '0'
            Set-IniValue -Path $convertConfig -Key 'vwim2swm' -Value '0'
            Set-IniValue -Path $convertConfig -Key 'vSkipISO' -Value '0'
            Set-IniValue -Path $convertConfig -Key 'vAutoEditions' -Value 'ProfessionalWorkstation'
            Invoke-Logged -FilePath cmd.exe -ArgumentList @('/d', '/c', 'echo 0|create_virtual_editions.cmd') -WorkingDirectory $UupRoot -AllowNonZero
        } finally {
            Copy-Item -LiteralPath $configBackup -Destination $convertConfig -Force
        }

        $workstationIso = Get-ChildItem -LiteralPath $UupRoot -Filter '*.iso' |
            Where-Object {
                ($_.Name -match 'CLIENTPROWORKSTATION|WORKSTATION|PROWORK') -and
                ($_.Name -notmatch 'tiny11|Lotus')
            } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1

        if (-not $workstationIso) {
            throw 'ProfessionalWorkstation source ISO was not created.'
        }
    } else {
        Write-Log "Reusing existing ProfessionalWorkstation source ISO: $($workstationIso.FullName)"
    }
    Write-Log "ProfessionalWorkstation source ISO: $($workstationIso.FullName)"

    Write-Status -Status 'running' -Step 'verify pro workstation source' -WorkstationIso $workstationIso.FullName
    $sourceDisk = Mount-DiskImage -ImagePath $workstationIso.FullName -PassThru
    $mountedImages += $workstationIso.FullName
    Start-Sleep -Seconds 2
    $sourceDrive = Get-IsoDriveLetter -ImagePath $workstationIso.FullName
    Write-Log "Mounted ProfessionalWorkstation source ISO as $sourceDrive`:"
    Get-WindowsImage -ImagePath "$sourceDrive`:\sources\install.wim" |
        Format-Table ImageIndex, ImageName, ImageDescription, ImageSize -AutoSize |
        Out-String |
        ForEach-Object { Write-Log $_.TrimEnd() }

    Write-Status -Status 'running' -Step 'run tiny11 custom build' -WorkstationIso $workstationIso.FullName
    $oscdimg = Join-Path $RepoRoot 'oscdimg.exe'
    Copy-Item -LiteralPath $cdimage -Destination $oscdimg -Force

    $inputFile = Join-Path $buildRoot ("tiny11-input-{0}.txt" -f ([guid]::NewGuid().ToString('N')))
    Set-Content -LiteralPath $inputFile -Value "1`r`n`r`n" -Encoding ASCII

    $repoIso = Join-Path $RepoRoot 'tiny11.iso'
    if (Test-Path -LiteralPath $repoIso) {
        Remove-Item -LiteralPath $repoIso -Force
    }

    $tinyCommand = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" -ISO {1} < "{2}"' -f $tinyMaker, $sourceDrive, $inputFile
    Invoke-Logged -FilePath cmd.exe -ArgumentList @('/d', '/c', $tinyCommand) -WorkingDirectory $RepoRoot

    if (-not (Test-Path -LiteralPath $repoIso)) {
        throw "tiny11 output ISO was not created: $repoIso"
    }

    $finalIso = Join-Path $UupRoot 'Lotus_tiny11_26100_ProWorkstation_zh-cn.iso'
    if (Test-Path -LiteralPath $finalIso) {
        Remove-Item -LiteralPath $finalIso -Force
    }
    Move-Item -LiteralPath $repoIso -Destination $finalIso -Force
    Write-Log "Final tiny11 ISO: $finalIso"

    Write-Status -Status 'running' -Step 'verify final iso' -FinalIso $finalIso -WorkstationIso $workstationIso.FullName
    $finalDisk = Mount-DiskImage -ImagePath $finalIso -PassThru
    $mountedImages += $finalIso
    Start-Sleep -Seconds 2
    $finalDrive = Get-IsoDriveLetter -ImagePath $finalIso
    Write-Log "Mounted final ISO as $finalDrive`:"
    Get-WindowsImage -ImagePath "$finalDrive`:\sources\install.wim" |
        Format-Table ImageIndex, ImageName, ImageDescription, ImageSize -AutoSize |
        Out-String |
        ForEach-Object { Write-Log $_.TrimEnd() }

    $finalItem = Get-Item -LiteralPath $finalIso
    Write-Log "Final size bytes: $($finalItem.Length)"
    Write-Status -Status 'completed' -Step 'done' -FinalIso $finalIso -WorkstationIso $workstationIso.FullName
    exit 0
} catch {
    $message = $_.Exception.Message
    if ([string]::IsNullOrWhiteSpace($message)) {
        $message = ($_ | Out-String).Trim()
    }
    Write-Log "FAILED: $message"
    try {
        Clear-StaleScratchMount
    } catch {
        Write-Log "Post-failure scratch cleanup skipped: $($_.Exception.Message)"
    }
    Write-Status -Status 'failed' -Step 'failed' -ErrorMessage $message
    exit 1
} finally {
    foreach ($imagePath in ($mountedImages | Select-Object -Unique)) {
        try {
            $disk = Get-DiskImage -ImagePath $imagePath -ErrorAction Stop
            if ($disk.Attached) {
                Write-Log "Dismounting ISO: $imagePath"
                Dismount-DiskImage -ImagePath $imagePath -ErrorAction SilentlyContinue | Out-Null
            }
        } catch {
            Write-Log "Dismount skipped for ${imagePath}: $($_.Exception.Message)"
        }
    }
    try {
        Stop-Transcript | Out-Null
    } catch {
    }
}
