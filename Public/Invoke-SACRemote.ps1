function Sync-SACModule {
    <#
    .SYNOPSIS
        Force-syncs the local module code to a remote target session if versions differ.
    #>
    param(
        [Parameter(Mandatory=$true)]
        [System.Management.Automation.Runspaces.PSSession]$Session
    )

    $localModule = Get-Module SurgicalAutodeskCleaner -ListAvailable | Select-Object -First 1
    if (-not $localModule) { return }

    $localVersion = $localModule.Version.ToString()
    $ModuleRoot = Resolve-Path (Join-Path $PSScriptRoot "..")

    $RemoteStatus = Invoke-Command -Session $Session -ScriptBlock {
        $m = Get-Module SurgicalAutodeskCleaner -ListAvailable | Select-Object -First 1
        $path = Join-Path $HOME "Documents\PowerShell\Modules\SurgicalAutodeskCleaner"
        return [PSCustomObject]@{
            Version = if ($m) { $m.Version.ToString() } else { $null }
            Path    = $path
            Exists  = Test-Path $path
        }
    }

    if ($RemoteStatus.Version -eq $localVersion) {
        Write-Host "[SAC] Remote module version ($localVersion) is already up to date." -ForegroundColor Gray
        return
    }

    Write-Host "[SAC] Version mismatch (Local: $localVersion | Remote: $($RemoteStatus.Version)). Synchronizing..." -ForegroundColor Cyan

    Invoke-Command -Session $Session -ScriptBlock {
        param($path)
        # If the module is already loaded in the remote session, try to remove it to release file locks
        if (Get-Module SurgicalAutodeskCleaner) {
            Remove-Module SurgicalAutodeskCleaner -ErrorAction SilentlyContinue
        }
        # Force a clean directory for the push
        if (Test-Path $path) {
            Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue
        }
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    } -ArgumentList $RemoteStatus.Path

    Write-Host "[SAC] Pushing local module code to remote target..." -ForegroundColor Cyan
    try {
        Copy-Item -Path "$ModuleRoot\*" -Destination $RemoteStatus.Path -Recurse -ToSession $Session -Force -ErrorAction Stop
        Write-Host "[SAC] Sync complete." -ForegroundColor Green
    } catch {
        Write-Host "[SAC] Warning: Failed to sync some module files (likely in-use by another process)." -ForegroundColor Yellow
        Write-Host "      Detailed Error: $($_.Exception.Message)" -ForegroundColor DarkGray
    }
}

function Invoke-SACRemote {
    <#
    .SYNOPSIS
        Dispatches Surgical Autodesk Cleaner tasks to one or more remote endpoints.
    .DESCRIPTION
        Uses PowerShell Remoting (WinRM) to execute SAC commands on remote machines. 
        It can automatically ensure the SAC module is installed on the target 
        via the PowerShell Gallery or by side-loading the local development version.
    .PARAMETER ComputerName
        One or more computer names to target.
    .PARAMETER Command
        The SAC command string to execute (e.g., "Start-SACCleanup -TargetYears 2021 -Silent").
    .PARAMETER Credential
        Optional PSCredential for the remote connection.
    .PARAMETER AsJob
        If specified, the remote tasks will run as background jobs.
    .PARAMETER AutoInstall
        If specified, the script will attempt to install/update the SurgicalAutodeskCleaner 
        module on the remote host. If the local module was imported directly (Dev Mode),
        it will side-load the local code via WinRM instead of using the PSGallery.
    .EXAMPLE
        Invoke-SACRemote -ComputerName "LAB-PC01" -Command "Start-SACCleanup -TargetYears 2022 -Silent" -AutoInstall
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, ValueFromPipeline=$true)]
        [string[]]$ComputerName,

        [Parameter(Mandatory=$true)]
        [string]$Command,

        [System.Management.Automation.PSCredential]$Credential,

        [switch]$AsJob,

        [switch]$AutoInstall
    )

    # Detect if the local module is a "Dev Version" (imported from disk, not PSGallery)
    $localModule = Get-Module SurgicalAutodeskCleaner
    $isDevVersion = $false
    if ($localModule -and $localModule.Path -notmatch 'WindowsPowerShell\\Modules|PowerShell\\7\\Modules') {
        $isDevVersion = $true
    }

    $ScriptBlock = {
        param($SACCommand, $DoInstall, $UseSideLoad)
        
        if ($DoInstall -and -not $UseSideLoad) {
            $hasModule = Get-Module -ListAvailable -Name SurgicalAutodeskCleaner
            if (-not $hasModule) {
                Write-Host "[SAC] Installing module from PSGallery..." -ForegroundColor Cyan
            } else {
                Write-Host "[SAC] Ensuring latest module version is installed..." -ForegroundColor Cyan
            }

            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            
            $installParams = @{
                Name         = 'SurgicalAutodeskCleaner'
                Force        = $true
                AllowClobber = $true
                Scope        = 'CurrentUser'
                ErrorAction  = 'SilentlyContinue'
            }
            if ((Get-Command Install-Module).Parameters.Keys -contains 'AcceptLicense') {
                $installParams['AcceptLicense'] = $true
            }
            
            Install-Module @installParams
        }

        if (Get-Module -ListAvailable -Name SurgicalAutodeskCleaner) {
            Import-Module SurgicalAutodeskCleaner -Force
            Invoke-Expression $SACCommand
        } else {
            Write-Error "SurgicalAutodeskCleaner module not found on remote host. Use -AutoInstall to attempt automated installation."
        }
    }

    foreach ($computer in $ComputerName) {
        $sessionParams = @{ ComputerName = $computer }
        if ($Credential) { $sessionParams["Credential"] = $Credential }
        
        $session = New-PSSession @sessionParams
        try {
            if ($AutoInstall -and $isDevVersion) {
                Sync-SACModule -Session $session
            }

            $cmdParams = @{
                Session      = $session
                ScriptBlock  = $ScriptBlock
                ArgumentList = @($Command, [bool]$AutoInstall, $isDevVersion)
            }
            if ($AsJob) { $cmdParams["AsJob"] = $true }

            Invoke-Command @cmdParams
        } finally {
            Remove-PSSession $session
        }
    }
}
