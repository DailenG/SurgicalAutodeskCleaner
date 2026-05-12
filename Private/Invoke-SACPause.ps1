function Invoke-SACPause {
    <#
    .SYNOPSIS
        Waits for user input in a way that is safe for both local and remote PowerShell sessions.
    #>
    param(
        [string]$Message = "Press Enter to continue..."
    )

    if (Get-Command Test-SACRemoteSession -ErrorAction SilentlyContinue) {
        $isRemote = Test-SACRemoteSession
    } else {
        $isRemote = ($null -ne $PSSenderInfo) -or ($Host.Name -eq "ServerRemoteHost") -or ($Host.Name -match "RemoteHost")
    }

    if ($isRemote) {
         # Read-Host is PSRemoting safe; ReadKey is not.
         $null = Read-Host "`n$Message"
    } else {
         Write-Host "`n$Message" -ForegroundColor DarkGray
         try {
             $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
         } catch {
             $null = Read-Host
         }
    }
}
