function Invoke-SACPendingDelete {
    <#
    .SYNOPSIS
        Queues files or directories for deletion on the next system reboot.
    .DESCRIPTION
        Writes to HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations.
        This is the standard Windows mechanism for handling locked files that cannot be deleted
        while the OS or a service is running.
    .PARAMETER Path
        The absolute path to the file or directory to be deleted on reboot.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Paths
    )

    $RegPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager"
    $ValueName = "PendingFileRenameOperations"

    foreach ($path in $Paths) {
        if (-not (Test-Path $path)) { continue }

        # Windows requires the \??\ prefix for kernel-mode file operations
        $nativePath = "\??\$path"
        
        Write-SACQuietLog "Queueing for reboot deletion: $path"

        try {
            $existing = Get-ItemProperty -Path $RegPath -Name $ValueName -ErrorAction SilentlyContinue
            $newList = if ($existing) { [System.Collections.Generic.List[string]]::new([string[]]$existing.$ValueName) }
                       else { [System.Collections.Generic.List[string]]::new() }

            # Format for deletion: [SourcePath], [EmptyString]
            $newList.Add($nativePath)
            $newList.Add("")

            Set-ItemProperty -Path $RegPath -Name $ValueName -Value $newList.ToArray() -Type MultiString -Force -ErrorAction Stop
        }
        catch {
            Write-SACQuietLog "Failed to queue $path for reboot deletion: $($_.Exception.Message)"
        }
    }
}
