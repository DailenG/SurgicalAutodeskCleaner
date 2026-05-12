function Test-SACRemoteSession {
    <#
    .SYNOPSIS
        Detects if the current PowerShell session is running over a remote connection (WinRM/SSH/etc).
    #>
    return ($null -ne $PSSenderInfo) -or ($Host.Name -eq "ServerRemoteHost") -or ($Host.Name -match "RemoteHost")
}
