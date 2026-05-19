function Test-SACPendingReboot {
    <#
    .SYNOPSIS
        Checks if there is a pending system reboot.
    .DESCRIPTION
        Inspects common registry keys for pending reboot flags.
    #>
    $RebootPending = $false

    # Key 1: Component Based Servicing reboot pending
    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending") {
        $RebootPending = $true
    }

    # Key 2: Windows Update auto update reboot required
    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired") {
        $RebootPending = $true
    }

    # Key 3: PendingFileRenameOperations
    $pfro = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name "PendingFileRenameOperations" -ErrorAction SilentlyContinue
    if ($pfro -and $pfro.PendingFileRenameOperations) {
        # Check if the array actually contains items
        if ($pfro.PendingFileRenameOperations.Count -gt 0) {
            $RebootPending = $true
        }
    }

    # Key 4: UpdateExeVolatile
    $volatile = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Updates" -Name "UpdateExeVolatile" -ErrorAction SilentlyContinue
    if ($volatile -and $volatile.UpdateExeVolatile -ne 0) {
        $RebootPending = $true
    }

    return $RebootPending
}
