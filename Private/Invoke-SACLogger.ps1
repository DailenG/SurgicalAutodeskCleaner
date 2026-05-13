function Write-SACMsg {
    <#
    .SYNOPSIS
        Writes a color-coded message to the console with a timestamp.
    #>
    param (
        [Parameter(Mandatory=$true)]
        [string]$Message,

        [ValidateSet("Info", "Success", "Warning", "Error")]
        [string]$Type = "Info"
    )
    $TimeStamp = "[$(Get-Date -Format 'HH:mm:ss')]"
    $Colors = @{
        "Info"    = "Cyan"
        "Success" = "Green"
        "Warning" = "Yellow"
        "Error"   = "Red"
    }
    Write-Host "$($TimeStamp) $($Message)" -ForegroundColor $Colors[$Type]
}

function Write-SACQuietLog {
    <#
    .SYNOPSIS
        Writes a debug message to a log file.
    #>
    param (
        [Parameter(Mandatory=$true)]
        [string]$Message,

        [string]$LogPath
    )
    # Fallback to $DebugLog from caller's scope via dynamic scoping if LogPath is not provided
    $targetPath = if ([string]::IsNullOrWhiteSpace($LogPath)) { Get-Variable -Name "DebugLog" -ValueOnly -ErrorAction SilentlyContinue } else { $LogPath }

    if (-not [string]::IsNullOrWhiteSpace($targetPath)) {
        $TimeStamp = "[$(Get-Date -Format 'HH:mm:ss')]"
        $logValue = "$($TimeStamp) [DEBUG] $($Message)"
        Add-Content -Path $targetPath -Value $logValue -ErrorAction SilentlyContinue
    }
}

function Test-SACInteractive {
    <#
    .SYNOPSIS
        Determines if the current session is interactive and not in silent mode.
    #>
    param (
        [switch]$Silent
    )
    if ($Silent) { return $false }
    
    # We check if there's a UI host.
    # We also check for a non-zero window handle or a standard host name as a fallback.
    $hasUI = ($null -ne $Host.UI -and $Host.UI.GetType().Name -ne "InternalHostUserInterface")
    $isConsole = ($Host.Name -match "ConsoleHost|Code|App" -or [Environment]::UserInteractive)
    
    return $hasUI -and $isConsole
}
