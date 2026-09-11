$errorActionPreference = 'Stop'
$appsUrl = "https://raw.githubusercontent.com/voziand/avdforge/main/artifacts/apps.$($env:IMAGE_TYPE).json"
$optimizationsUrl = "https://raw.githubusercontent.com/voziand/avdforge/main/artifacts/optimizations.$($env:IMAGE_TYPE).json"
$logFile = 'C:\ProgramData\ImageBuilder\customizer.log'
New-Item -Path 'C:\ProgramData\ImageBuilder' -ItemType Directory -Force | Out-Null
$redirectionsFolder = "C:\ProgramData\FSLogix"
$redirectionsFilePath = "$redirectionsFolder\redirections.xml"
$redirectionsFileUrl = "https://raw.githubusercontent.com/voziand/avdforge/main/artifacts/redirections.xml"

function Write-Log {
    param([string]$Message)
    $Entry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $Message"
    Write-Host $Entry
    Add-Content -Path $logFile -Value $Entry
}
# Install cholocatey
try {
    Write-Log 'Checking for Chocolatey...'
    $chocoCmd = Get-Command choco.exe -ErrorAction SilentlyContinue
    if ($chocoCmd) {
        Write-Log "Chocolatey already installed at: $($chocoCmd.Source)"
    }
    else {
        Write-Log 'Installing Chocolatey...'
        Set-ExecutionPolicy Bypass -Scope Process -Force
        Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
        $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
        $chocoCmd = Get-Command choco.exe -ErrorAction SilentlyContinue
        if (-not $chocoCmd) {
            throw 'Chocolatey installation completed but choco.exe was not found.'
        }
        choco feature enable -n allowGlobalConfirmation
        Write-Log "Chocolatey installed at: $($chocoCmd.Source)"
    }
}
catch {
    Write-Log "FATAL: Failed to install Chocolatey. $_"
    throw
}

# INSTALL APPLICATIONS
try {
    Write-Log '========== Starting Application Installation =========='
    $manifest = Invoke-RestMethod -Uri $appsUrl
    Write-Log "Packages to install: $($manifest.packages.Count)"
}
catch {
    Write-Log "FATAL: Failed to get application manifest: $_"
    throw
}

foreach ($app in $manifest.packages) {
    try {
        Write-Log "Installing: $($app.name) (source: $($app.source))"
        switch ($app.source) {
            'chocolatey' { if ($app.switches) { choco install $app.name --no-progress --params $app.switches --execution-timeout=600 } else { choco install $app.name --no-progress --execution-timeout=600} }
            'custom'     {
                if ($app.detectPath -and (Test-Path $app.detectPath)) { Write-Log "  Already installed: $($app.detectPath)"; continue}

                $extension = if ($app.installerType) { ".$($app.installerType)" } else { [System.IO.Path]::GetExtension($app.installerUrl) }
                $installerPath = Join-Path $env:TEMP "$($app.name)-installer$extension"
                Invoke-WebRequest -Uri $app.installerUrl -OutFile $installerPath -UseBasicParsing

                if ($extension -eq '.msi') { Start-Process -FilePath 'msiexec.exe' -ArgumentList "/i `"$installerPath`" $($app.switches)" -Wait }
                else { Start-Process -FilePath $installerPath -ArgumentList $App.switches -Wait }
                # clean up
                Remove-Item -Path $installerPath -Force -ErrorAction SilentlyContinue
            }
            default     { Write-Log "ERROR: Unknown source '$($app.source)' for $($app.name)."; continue }
        }

        Write-Log "Installed: $($app.name)"
    }
    catch {
        Write-Log "ERROR: Failed to install [$($app.name)]: $_"
    }
}

Write-Log '========== Application Installation Complete =========='

# IMAGE OPTIMIZATIONS
try {
    Write-Log '========== Starting Image Optimizations =========='
    $optimizations = Invoke-RestMethod -Uri $optimizationsUrl
 
    Write-Log "Disabling $($optimizations.services.Count) services..."
    foreach ($service in $optimizations.services) {
        try {
            $existing = Get-Service -Name $service.name -ErrorAction SilentlyContinue
            if ($existing) {
                Set-Service -Name $service.name -StartupType Disabled -ErrorAction Stop
                Write-Log "  Disabled: $($service.name) ($($service.description))"
            }
        }
        catch {
            Write-Log "  WARNING: Could not disable $($service.name): $_"
        }
    }
 
    Write-Log "Disabling $($optimizations.scheduledTasks.Count) scheduled tasks..."
    foreach ($task in $optimizations.scheduledTasks) {
        try {
            $taskObj = Get-ScheduledTask -TaskPath $task.path -TaskName $task.name -ErrorAction SilentlyContinue
            if ($taskObj -and $taskObj.State -ne 'Disabled') {
                Disable-ScheduledTask -InputObject $taskObj | Out-Null
                Write-Log "  Disabled: $($task.path)\$($task.name)"
            }
        }
        catch {
            Write-Log "  WARNING: Could not disable task $($task.name): $_"
        }
    }
    # DEBLOAT
    Write-Log "Removing $($optimizations.appxPackages.Count) AppX packages..."
    foreach ($package in $optimizations.appxPackages) {
        try {
            Get-AppxProvisionedPackage -Online | Where-Object { $_.PackageName -like "*$package*" } | Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Out-Null
            Get-AppxPackage -AllUsers -Name "*$package*" -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
            Write-Log "  Removed: $package"
        }
        catch {
            Write-Log "  WARNING: Could not remove $package`: $_"
        }
    }
 
    Write-Log "Applying $($optimizations.registrySettings.Count) registry settings..."
    foreach ($registrySetting in $optimizations.registrySettings) {
        try {
            if (-not (Test-Path $registrySetting.path)) {
                New-Item -Path $registrySetting.path -Force | Out-Null
            }
            New-ItemProperty -Path $registrySetting.path -Name $registrySetting.name -PropertyType $registrySetting.type -Value $registrySetting.value -Force | Out-Null
            Write-Log "  Set: $($registrySetting.path)\$($registrySetting.name) = $($registrySetting.value)"
        }
        catch {
            Write-Log "  WARNING: Could not set $($registrySetting.path)\$($registrySetting.name): $_"
        }
    }
 
    Write-Log "Disabling $($optimizations.autologgers.Count) autologgers..."
    foreach ($logger in $optimizations.autologgers) {
        try {
            if (Test-Path $logger) {
                New-ItemProperty -Path $logger -Name 'Start' -PropertyType DWORD -Value 0 -Force | Out-Null
                Write-Log "  Disabled: $logger"
            }
        }
        catch {
            Write-Log "  WARNING: Could not disable autologger $logger`: $_"
        }
    }
    Write-Log '========== Image Optimizations Complete =========='
}
catch {
    Write-Log "FATAL ERROR during optimizations: $_"
    throw
}

# FsLogix configuration - Only applies if the image is multisession version, ie pooled deployment
if ($env:IMAGE_TYPE -eq 'Pooled') {
    Write-Log "Configuring FSLogix..."
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
    New-ItemProperty -Path "HKLM:\SOFTWARE\FSLogix\Profiles" -Name "PreventLoginWithTempProfile" -PropertyType dword -Value 1 -Force
    New-ItemProperty -Path "HKLM:\SOFTWARE\FSLogix\Profiles" -Name "ProfileType" -PropertyType dword -Value 0 -Force
    New-ItemProperty -Path "HKLM:\SOFTWARE\FSLogix\Profiles" -Name "ReAttachIntervalSeconds" -PropertyType dword -Value 15 -Force
    New-ItemProperty -Path "HKLM:\SOFTWARE\FSLogix\Profiles" -Name "ReAttachRetryCount" -PropertyType dword -Value 3 -Force
    New-ItemProperty -Path "HKLM:\SOFTWARE\FSLogix\Profiles" -Name "RemoveOrphanedOSTFilesOnLogoff" -PropertyType dword -Value 1 -Force
    New-ItemProperty -Path "HKLM:\SOFTWARE\FSLogix\Profiles" -Name "SizeInMBs" -PropertyType dword -Value 30000 -Force
    New-ItemProperty -Path "HKLM:\SOFTWARE\FSLogix\Profiles" -Name "VHDLocations" -PropertyType string -Value $profileShare -Force
    New-ItemProperty -Path "HKLM:\SOFTWARE\FSLogix\Profiles" -Name "VolumeType" -PropertyType string -Value "VHDX" -Force
    New-ItemProperty -Path "HKLM:\SOFTWARE\FSLogix\Apps" -Name "CleanupInvalidSessions" -PropertyType dword -Value 1 -Force

    # Configure credentials to roam with the profile
    New-Item -Path "HKLM:\Software\Policies\Microsoft" -Name "AzureADAccount" -ErrorAction Ignore
    New-ItemProperty -Path "HKLM:\Software\Policies\Microsoft\AzureADAccount" -Name "LoadCredKeyFromProfile" -Value 1 -PropertyType DWord -Force

    # Configure cloud kerberos ticket retrieval
    New-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\Kerberos" -Name "Parameters" -ErrorAction Ignore
    New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\Kerberos\Parameters" -Name "CloudKerberosTicketRetrievalEnabled" -PropertyType DWord -Value 1 -Force

    # Exclude local administrator from FsLogix profiles
    Add-LocalGroupMember -Group "FSLogix Profile Exclude List" -Member "Administrators" -ErrorAction Ignore
    
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
