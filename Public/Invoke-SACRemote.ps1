function Invoke-SACRemote {
    <#
    .SYNOPSIS
        Dispatches Surgical Autodesk Cleaner tasks to one or more remote endpoints.
    .DESCRIPTION
        Uses PowerShell Remoting (WinRM) to execute SAC commands on remote machines. 
        It can automatically ensure the SAC module is installed on the target 
        via the PowerShell Gallery if missing.
    .PARAMETER ComputerName
        One or more computer names to target.
    .PARAMETER Command
        The SAC command string to execute (e.g., "Start-SACCleanup -TargetYears 2021 -Silent").
    .PARAMETER Credential
        Optional PSCredential for the remote connection.
    .PARAMETER AsJob
        If specified, the remote tasks will run as background jobs.
    .PARAMETER AutoInstall
        If specified, the script will attempt to install the SurgicalAutodeskCleaner 
        module on the remote host if it is not already present.
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

    $ScriptBlock = {
        param($SACCommand, $DoInstall)
        
        if ($DoInstall) {
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
            # Support older PowerShellGet versions that don't have -AcceptLicense
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

    $Params = @{
        ComputerName = $ComputerName
        ScriptBlock  = $ScriptBlock
        ArgumentList = @($Command, [bool]$AutoInstall)
    }

    if ($Credential) { $Params["Credential"] = $Credential }
    if ($AsJob) { $Params["AsJob"] = $true }

    Invoke-Command @Params
}
