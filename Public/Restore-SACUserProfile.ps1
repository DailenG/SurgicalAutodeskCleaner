function Restore-SACUserProfile {
<#
.SYNOPSIS
    Lists, restores, or purges Roaming profile backups created by Reset-SACUserProfile.
.DESCRIPTION
    Reset-SACUserProfile renames Roaming profile folders with a _SAC_BACKUP_<timestamp>
    suffix instead of deleting them. This command lets you discover those backups,
    restore a specific one, or remove them all to free disk space.

.PARAMETER List
    Default behavior. Lists all SAC backup folders found across all user profiles.

.PARAMETER Restore
    Restores a specific backup by removing the _SAC_BACKUP_<timestamp> suffix.
    Requires -BackupPath to identify which backup to restore.
    Will fail if the original folder still exists (to prevent overwrite).

.PARAMETER BackupPath
    Full path to a specific _SAC_BACKUP_ folder to restore. Use with -Restore.

.PARAMETER Purge
    Removes ALL _SAC_BACKUP_ folders across all user profiles to free disk space.
    Requires confirmation unless -Silent is specified.

.PARAMETER Silent
    Switch. Bypasses the confirmation prompt for -Purge operations.

.EXAMPLE
    # List all backups on the machine
    Restore-SACUserProfile

.EXAMPLE
    # Restore a specific backup
    Restore-SACUserProfile -Restore -BackupPath "C:\Users\jsmith\AppData\Roaming\Autodesk\AutoCAD 2020_SAC_BACKUP_20250509_143000"

.EXAMPLE
    # Wipe all backups (free disk space)
    Restore-SACUserProfile -Purge -Silent
#>
    [CmdletBinding(DefaultParameterSetName="List")]
    param (
        [Parameter(ParameterSetName="List")][switch]$List,
        [Parameter(ParameterSetName="Restore", Mandatory=$true)][switch]$Restore,
        [Parameter(ParameterSetName="Restore", Mandatory=$true)][string]$BackupPath,
        [Parameter(ParameterSetName="Purge", Mandatory=$true)][switch]$Purge,
        [switch]$Silent
        )

        # --- Helper Functions (Centralized) ---

        $BackupSuffixPattern = "*_SAC_BACKUP_*"

    # --- Discover all backups ---
    $AllBackups = Get-ChildItem -Path "C:\Users\*\AppData\Roaming\Autodesk" -Filter $BackupPattern -Directory -ErrorAction SilentlyContinue

    if ($PSCmdlet.ParameterSetName -eq "List" -or $PSCmdlet.ParameterSetName -eq "") {
        Write-Host "`n--- SAC User Profile Backups ---" -ForegroundColor Cyan
        if ($AllBackups.Count -eq 0) {
            Write-Host "No SAC backup folders found on this machine." -ForegroundColor Yellow
        } else {
            $AllBackups | Select-Object @{N="User"; E={ ($_.FullName -split "\\")[2] }},
                                        @{N="Backup Folder"; E={ $_.Name }},
                                        @{N="Size (MB)"; E={ [math]::Round(((Get-ChildItem $_.FullName -Recurse -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1MB), 2) }},
                                        @{N="Created"; E={ $_.CreationTime }} |
                Format-Table -AutoSize
            Write-Host "Total backups found: $($AllBackups.Count)" -ForegroundColor Cyan
            Write-Host "Use -Restore -BackupPath '<path>' to restore one, or -Purge to remove all.`n" -ForegroundColor DarkGray
        }
        return
    }

    if ($Restore) {
        if (-not (Test-Path $BackupPath)) {
            Write-SACMsg "Backup path not found: $BackupPath" "Error"
            return
        }

        # Derive the original path by stripping the suffix
        $OriginalPath = $BackupPath -replace "_SAC_BACKUP_\d{8}_\d{6}$", ""

        if (Test-Path $OriginalPath) {
            Write-SACMsg "Cannot restore - original path already exists: $OriginalPath" "Error"
            Write-SACMsg "Remove or rename the existing folder first, then retry." "Warning"
            return
        }

        try {
            Rename-Item -Path $BackupPath -NewName $OriginalPath -ErrorAction Stop
            Write-SACMsg "Restored: $BackupPath -> $OriginalPath" "Success"
        } catch {
            Write-SACMsg "Restore failed: $($_.Exception.Message)" "Error"
        }
        return
    }

    if ($Purge) {
        if ($AllBackups.Count -eq 0) {
            Write-Host "No SAC backup folders found. Nothing to purge." -ForegroundColor Yellow
            return
        }

        if (-not $Silent) {
            Write-Host "`nFound $($AllBackups.Count) backup folder(s) to permanently remove:" -ForegroundColor Yellow
            $AllBackups | ForEach-Object { Write-Host "  $($_.FullName)" -ForegroundColor DarkGray }
            Write-Host ""
            $resp = Read-Host "Type 'YES' to permanently delete all backups"
            if ($resp -ne "YES") {
                Write-SACMsg "Purge aborted." "Warning"
                return
            }
        }

        foreach ($backup in $AllBackups) {
            try {
                Remove-Item $backup.FullName -Recurse -Force -ErrorAction Stop
                Write-SACMsg "Purged backup: $($backup.FullName)" "Success"
            } catch {
                Write-SACMsg "Failed to purge: $($backup.FullName) - $($_.Exception.Message)" "Error"
            }
        }
        Write-Host "`n[*] Backup purge complete.`n" -ForegroundColor Green
    }
}
