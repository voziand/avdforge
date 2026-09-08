$errorActionPreference = 'Stop'
$appsUrl = "https://raw.githubusercontent.com/voziand/avdforge/main/artifacts/apps.$($imageType).json"
$imageType = $env:IMAGE_TYPE
$applicationsFile = Join-Path $env:TEMP 'apps.json'
$optimizationsUrl = "https://raw.githubusercontent.com/voziand/avdforge/main/artifacts/optimizations.$($imageType).json"
$logFile = 'C:\Windows\Temp\InstallApps.log'
$redirectionsFolder = "C:\ProgramData\FSLogix"
$redirectionsFilePath = "$redirectionsFolder\redirections.xml"
$redirectionsFileUrl = "https://raw.githubusercontent.com/voziand/avdforge/main/artifacts/redirections.xml"

function Write-Log {
    param([string]$Message)
    $Entry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $Message"
    Write-Host $Entry
    Add-Content -Path $logFile -Value $Entry
}

function Install-Chocolatey {
    Write-Log 'Checking for Chocolatey...'
    $ChocoCmd = Get-Command choco.exe -ErrorAction SilentlyContinue
    if ($ChocoCmd) {
        Write-Log "Chocolatey already installed at: $($ChocoCmd.Source)"
        return
    }
    Write-Log 'Installing Chocolatey...'
    Set-ExecutionPolicy Bypass -Scope Process -Force
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
    $ChocoCmd = Get-Command choco.exe -ErrorAction SilentlyContinue
    if (-not $ChocoCmd) {
        throw 'Chocolatey installation completed but choco.exe was not found.'
    }
    choco feature enable -n allowGlobalConfirmation
    Write-Log "Chocolatey installed at: $($ChocoCmd.Source)"
}

try {
    Install-Chocolatey
}
catch {
    Write-Log "FATAL: Failed to install Chocolatey. $_"
    throw
}
# APPLICATIONS INSTALLATION
try {
    Write-Log '========== Starting Application Installation =========='
    Write-Log 'Downloading application manifest...'
    Invoke-WebRequest -Uri $appsUrl -OutFile $applicationsFile -UseBasicParsing
    $Manifest = Get-Content $applicationsFile -Raw | ConvertFrom-Json
    Write-Log "Packages to install: $($Manifest.packages.Count)"

    foreach ($App in $Manifest.packages) {
        try {
            Write-Log "Installing: $($App.name) (source: $($App.source))"

            switch ($App.source) {
                'chocolatey' { if($app.switches){ choco install $app.name --no-progress --params $app.switches } else { choco install $app.name --no-progress } }
                'custom' {
                    if ($App.detectPath -and (Test-Path $App.detectPath)) {
                        Write-Log "  Already installed: $($App.detectPath)"
                        continue
                    }
                    $extension = [System.IO.Path]::GetExtension($App.installerUrl)
                    $installerPath = Join-Path $env:TEMP "$($App.name)-installer$extension"
                    Invoke-WebRequest -Uri $App.installerUrl -OutFile $installerPath -UseBasicParsing
                    if ($extension -eq '.msi') {
                        Start-Process -FilePath 'msiexec.exe' -ArgumentList "/i `"$installerPath`" $($App.switches)" -Wait
                    }
                    else {
                        Start-Process -FilePath $installerPath -ArgumentList $App.switches -Wait
                    }
                }
                default {
                    Write-Log "ERROR: Unknown source '$($App.source)' for $($App.name)."
                    continue
                }
            }

            if ($LASTEXITCODE -eq 0) {
                Write-Log "Installed: $($App.name)"
            }
            elseif ($LASTEXITCODE -eq 1641 -or $LASTEXITCODE -eq 3010) {
                Write-Log "Installed (reboot pending): $($App.name)"
            }
            else {
                Write-Log "WARNING: Exit code [$LASTEXITCODE]: $($App.name)"
            }
        }
        catch {
            Write-Log "ERROR: Failed to install [$($App.name)]: $_"
        }
    }
    Write-Log '========== Application Installation Complete =========='
}
catch {
    Write-Log "FATAL ERROR: $_"
    throw
}
# IMAGE OPTIMIZATIONS
 
try {
    Write-Log '========== Starting Image Optimizations =========='
    $OptFile = Join-Path $env:TEMP 'optimizations.json'
    Write-Log 'Downloading optimization configuration...'
    Invoke-WebRequest -Uri $optimizationsUrl -OutFile $OptFile -UseBasicParsing
    $Opt = Get-Content $OptFile -Raw | ConvertFrom-Json
 
    Write-Log "Disabling $($Opt.services.Count) services..."
    foreach ($Svc in $Opt.services) {
        try {
            $existing = Get-Service -Name $Svc.name -ErrorAction SilentlyContinue
            if ($existing) {
                Set-Service -Name $Svc.name -StartupType Disabled -ErrorAction Stop
                Write-Log "  Disabled: $($Svc.name) ($($Svc.description))"
            }
        }
        catch {
            Write-Log "  WARNING: Could not disable $($Svc.name): $_"
        }
    }
 
    Write-Log "Disabling $($Opt.scheduledTasks.Count) scheduled tasks..."
    foreach ($Task in $Opt.scheduledTasks) {
        try {
            $taskObj = Get-ScheduledTask -TaskPath $Task.path -TaskName $Task.name -ErrorAction SilentlyContinue
            if ($taskObj -and $taskObj.State -ne 'Disabled') {
                Disable-ScheduledTask -InputObject $taskObj | Out-Null
                Write-Log "  Disabled: $($Task.path)\$($Task.name)"
            }
        }
        catch {
            Write-Log "  WARNING: Could not disable task $($Task.name): $_"
        }
    }
    # DEBLOAT
    Write-Log "Removing $($Opt.appxPackages.Count) AppX packages..."
    foreach ($Pkg in $Opt.appxPackages) {
        try {
            Get-AppxProvisionedPackage -Online | Where-Object { $_.PackageName -like "*$Pkg*" } | Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Out-Null
            Get-AppxPackage -AllUsers -Name "*$Pkg*" -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
            Write-Log "  Removed: $Pkg"
        }
        catch {
            Write-Log "  WARNING: Could not remove $Pkg`: $_"
        }
    }
 
    Write-Log "Applying $($Opt.registrySettings.Count) registry settings..."
    foreach ($Reg in $Opt.registrySettings) {
        try {
            if (-not (Test-Path $Reg.path)) {
                New-Item -Path $Reg.path -Force | Out-Null
            }
            New-ItemProperty -Path $Reg.path -Name $Reg.name -PropertyType $Reg.type -Value $Reg.value -Force | Out-Null
            Write-Log "  Set: $($Reg.path)\$($Reg.name) = $($Reg.value)"
        }
        catch {
            Write-Log "  WARNING: Could not set $($Reg.path)\$($Reg.name): $_"
        }
    }
 
    Write-Log "Disabling $($Opt.autologgers.Count) autologgers..."
    foreach ($Logger in $Opt.autologgers) {
        try {
            if (Test-Path $Logger) {
                New-ItemProperty -Path $Logger -Name 'Start' -PropertyType DWORD -Value 0 -Force | Out-Null
                Write-Log "  Disabled: $Logger"
            }
        }
        catch {
            Write-Log "  WARNING: Could not disable autologger $Logger`: $_"
        }
    }
 
    if ($Opt.diskCleanup -eq $true) {
        Write-Log 'Running disk cleanup...'
        Get-ChildItem -Path C:\ -Include *.tmp, *.dmp, *.etl, *.evtx, thumbcache*.db, *.log -File -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -ErrorAction SilentlyContinue
        Remove-Item -Path $env:windir\Temp\* -Recurse -Force -ErrorAction SilentlyContinue -Exclude packer*.ps1
        Remove-Item -Path $env:TEMP\* -Recurse -Force -ErrorAction SilentlyContinue -Exclude packer*.ps1
        Remove-Item -Path $env:ProgramData\Microsoft\Windows\WER\Temp\* -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $env:ProgramData\Microsoft\Windows\WER\ReportArchive\* -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $env:ProgramData\Microsoft\Windows\WER\ReportQueue\* -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $env:ProgramData\Microsoft\Windows\RetailDemo\* -Recurse -Force -ErrorAction SilentlyContinue
        Clear-RecycleBin -Force -ErrorAction SilentlyContinue
        Clear-BCCache -Force -ErrorAction SilentlyContinue
        Dism /Online /Cleanup-Image /StartComponentCleanup /ResetBase /Quiet
        Write-Log 'Disk cleanup complete.'
    }
 
    Write-Log '========== Image Optimizations Complete =========='
}
catch {
    Write-Log "FATAL ERROR during optimizations: $_"
    throw
}

# FsLogix configuration - Only applies if the image is multisession version, ie pooled deployment
if ($imageType -eq 'pooled') {
    Write-Log "Configureing FSLogix..."
    $storageAccount = "$($env:USR_PROFILE_SA_NAME).file.core.windows.net"
    $profileShare = "\\$($storageAccount)\$($env:USR_PROFILE_FS_NAME)"

    New-Item -Path "HKLM:\SOFTWARE" -Name "FSLogix" -ErrorAction Ignore
    New-Item -Path "HKLM:\SOFTWARE\FSLogix" -Name "Profiles" -ErrorAction Ignore
    New-ItemProperty -Path "HKLM:\SOFTWARE\FSLogix\Profiles" -Name "Enabled" -PropertyType dword -Value 1 -Force
    New-ItemProperty -Path "HKLM:\SOFTWARE\FSLogix\Profiles" -Name "ConcurrentUserSessions" -PropertyType dword -Value 1 -Force
    New-ItemProperty -Path "HKLM:\SOFTWARE\FSLogix\Profiles" -Name "DeleteLocalProfileWhenVHDShouldApply" -PropertyType dword -Value 1 -Force
    New-ItemProperty -Path "HKLM:\SOFTWARE\FSLogix\Profiles" -Name "FlipFlopProfileDirectoryName" -PropertyType dword -Value 1 -Force
    New-ItemProperty -Path "HKLM:\SOFTWARE\FSLogix\Profiles" -Name "LockedRetryCount" -PropertyType dword -Value 3 -Force
    New-ItemProperty -Path "HKLM:\SOFTWARE\FSLogix\Profiles" -Name "LockedRetryInterval" -PropertyType dword -Value 15 -Force
    New-ItemProperty -Path "HKLM:\SOFTWARE\FSLogix\Profiles" -Name "PreventLoginWithTempProfile" -PropertyType dword -Value 1
    New-ItemProperty -Path "HKLM:\SOFTWARE\FSLogix\Profiles" -Name "ProfileType" -PropertyType dword -Value 0 -Force
    New-ItemProperty -Path "HKLM:\SOFTWARE\FSLogix\Profiles" -Name "ReAttachIntervalSeconds" -PropertyType dword -Value 15 -Force
    New-ItemProperty -Path "HKLM:\SOFTWARE\FSLogix\Profiles" -Name "ReAttachRetryCount" -PropertyType dword -Value 3 -Force
    New-ItemProperty -Path "HKLM:\SOFTWARE\FSLogix\Profiles" -Name "RemoveOrphanedOSTFilesOnLogoff" -PropertyType dword -Value 1 -Force
    New-ItemProperty -Path "HKLM:\SOFTWARE\FSLogix\Profiles" -Name "SizeInMBs" -PropertyType dword -Value 30000 -Force
    New-ItemProperty -Path "HKLM:\SOFTWARE\FSLogix\Profiles" -Name "VHDLocations" -PropertyType string -Value $profileShare -Force
    New-ItemProperty -Path "HKLM:\SOFTWARE\FSLogix\Profiles" -Name "VolumeType" -PropertyType string -Value "VHDX" -Force
    New-ItemProperty -Path "HKLM:\SOFTWARE\FSLogix\Apps" -Name "CleanupInvalidSessions" -PropertyType dword -Value 1 -Force

    # Configure credentials to roam with the profile
    New-ItemProperty -Path "HKLM:\Software\Policies\Microsoft\AzureADAccount" -Name "LoadCredKeyFromProfile" -Value 1 -PropertyType DWord -Force

    # Configure cloud kerberos tiket retrieval
    New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\Kerberos\Parameters" -Name "CloudKerberosTicketRetrievalEnabled" -PropertyType DWord -Value 1 -Force

    # Exclude fslogix processes and profiles from Microsoft Defender
    Add-MpPreference -ExclusionProcess "frxsvc.exe"
    Add-MpPreference -ExclusionProcess "frxccds.exe"

    # Driver files
    Add-MpPreference -ExclusionProcess "frxdrv.sys"
    Add-MpPreference -ExclusionProcess "frxdrvvt.sys"
    Add-MpPreference -ExclusionProcess "frxccd.sys"

    # Directories
    Add-MpPreference -ExclusionPath "$($env:ProgramFiles)\FSLogix\Apps"
    Add-MpPreference -ExclusionPath "$($env:ProgramData)\FSLogix"
    Add-MpPreference -ExclusionPath "C:\Users\*\AppData\Local\FSLogix"

    # Cloud Cache folders
    Add-MpPreference -ExclusionPath "$($env:ProgramData)\FSLogix\Cache"
    Add-MpPreference -ExclusionPath "$($env:ProgramData)\FSLogix\Proxy"

    # Temporary VHD/VHDX files
    Add-MpPreference -ExclusionPath "C:\Users\*\AppData\Local\Temp\*\*.VHD"
    Add-MpPreference -ExclusionPath "C:\Users\*\AppData\Local\Temp\*\*.VHDX"
    Add-MpPreference -ExclusionPath "$($env:WINDIR)\TEMP\*\*.VHD"
    Add-MpPreference -ExclusionPath "$($env:WINDIR)\TEMP\*\*.VHDX"

    # SMB file share
    Add-MpPreference -ExclusionPath "$profileShare\*\*.VHD*"

    # Redirections file
    Write-Log 'Downloading redirections file...'
    Invoke-WebRequest -Uri $redirectionsFileUrl -OutFile $redirectionsFilePath -UseBasicParsing
    New-ItemProperty -Path "HKLM:\SOFTWARE\FSLogix\Profiles" -Name "RedirXMLSourceFolder" -PropertyType string -Value $redirectionsFolder -Force

}
