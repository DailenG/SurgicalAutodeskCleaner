function Start-SACScan {
    <#
    .SYNOPSIS
        Generates a pre-flight scan report of Autodesk components.
    .DESCRIPTION
        Launches the interactive Surgical Autodesk Cleaner menu in "Scan Only" mode.
        Instead of removing components, it generates a CSV detailing everything that 
        would be targeted.
    #>
    [CmdletBinding()]
    param()
    
    Start-SACInteractive -ScanOnly
}
