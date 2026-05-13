<#
.SYNOPSIS
    Utilizes Robocopy to perform an ultra-fast, scorched-earth directory purge.

.DESCRIPTION
    PowerShell's native Remove-Item is susceptible to MAX_PATH (260 char) limitations
    and can halt prematurely on locked files. This helper creates a temporary empty
    directory and uses robocopy /MIR to mirror the empty state to the target directory.
    This forces Windows to bypass path limits and rapidly delete all contents.
    It returns an array of any files that were actively locked and could not be purged.

.PARAMETER TargetPath
    The absolute path of the directory to be purged.

.EXAMPLE
    $results = Invoke-SACRobocopyPurge -TargetPath "C:\ProgramData\Autodesk"
    if (-not $results.Success) {
        Write-Warning "Locked files: $($results.LockedItems -join ', ')"
    }
#>
function Invoke-SACRobocopyPurge {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetPath
    )

    if (-not (Test-Path $TargetPath)) {
        return [PSCustomObject]@{ Success = $true; LockedItems = @() }
    }

    $emptyDir = Join-Path $env:TEMP ([Guid]::NewGuid().ToString())
    $logFile = Join-Path $env:TEMP ("RCLog_" + [Guid]::NewGuid().ToString() + ".log")
    $lockedItems = @()

    try {
        # Create the temporary empty directory
        New-Item -ItemType Directory -Path $emptyDir -Force | Out-Null

        # Execute robocopy mirror to bypass MAX_PATH and bulk-delete standard files
        $roboArgs = "`"$emptyDir`" `"$TargetPath`" /MIR /R:0 /W:0 /NP /NFL /NDL /NJH /NJS"
        Start-Process -FilePath "robocopy.exe" -ArgumentList $roboArgs -Wait -NoNewWindow -ErrorAction SilentlyContinue

        # Robocopy /MIR ignores Read-Only extra files. We must explicitly obliterate them.
        if (Test-Path $TargetPath) {
            Start-Process -FilePath "cmd.exe" -ArgumentList "/c del /f /a /q /s `"$TargetPath\*`" >nul 2>&1" -Wait -NoNewWindow
            Start-Process -FilePath "cmd.exe" -ArgumentList "/c rmdir /s /q `"$TargetPath`" >nul 2>&1" -Wait -NoNewWindow
        }

    } catch {
        # Fallback if Robocopy fails to execute
        Write-Warning "Robocopy purge exception ($($_.Exception.Message)). Falling back to cmd.exe deletion..."
        if (Test-Path $TargetPath) {
            Start-Process -FilePath "cmd.exe" -ArgumentList "/c del /f /a /q /s `"$TargetPath\*`" >nul 2>&1" -Wait -NoNewWindow
            Start-Process -FilePath "cmd.exe" -ArgumentList "/c rmdir /s /q `"$TargetPath`" >nul 2>&1" -Wait -NoNewWindow
        }
    } finally {
        # Cleanup temp empty dir
        if (Test-Path $emptyDir) { Remove-Item -Path $emptyDir -Force -Recurse -ErrorAction SilentlyContinue }
    }

    $stillExists = Test-Path $TargetPath
    
    if ($stillExists) {
        # Gather all files that survived the scorched-earth purge (meaning they are actively locked by the OS)
        $survivors = Get-ChildItem -Path $TargetPath -Recurse -File -Force -ErrorAction SilentlyContinue
        if ($survivors) {
            $lockedItems = $survivors | Select-Object -ExpandProperty FullName
        }
    }

    return [PSCustomObject]@{
        Success = (-not $stillExists)
        LockedItems = $lockedItems
    }
}
