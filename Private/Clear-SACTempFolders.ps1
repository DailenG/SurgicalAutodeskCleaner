function Clear-SACTempFolders {
    <#
    .SYNOPSIS
        Clears the current user's Temp directory and C:\Windows\Temp.
    .DESCRIPTION
        Deletes all files and folders in the user's local Temp and Windows Temp,
        ignoring locked or inaccessible files.
    #>
    $TempDirs = @(
        $env:TEMP,
        "C:\Windows\Temp"
    )

    foreach ($dir in $TempDirs) {
        if (-not [string]::IsNullOrWhiteSpace($dir) -and (Test-Path $dir)) {
            Write-SACMsg "Clearing general temp folder: $dir" "Info"
            Get-ChildItem -Path $dir -ErrorAction SilentlyContinue | ForEach-Object {
                try {
                    Remove-Item $_.FullName -Recurse -Force -ErrorAction Stop
                }
                catch {
                    # Ignore errors for files that are currently locked
                    Write-SACQuietLog "Skipped locked/in-use temp file/folder: $($_.FullName)"
                }
            }
        }
    }
}
