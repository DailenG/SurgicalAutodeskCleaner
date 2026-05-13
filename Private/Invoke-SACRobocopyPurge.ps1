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

        # Execute robocopy mirror
        # /MIR: Mirror a directory tree (equivalent to /E plus /PURGE)
        # /R:0: 0 retries on failed files (skip locked immediately)
        # /W:0: 0 wait time between retries
        # /NP: No progress (reduces log noise)
        # /UNILOG: Output log as Unicode to handle special characters
        $roboArgs = "`"$emptyDir`" `"$TargetPath`" /MIR /R:0 /W:0 /NP /UNILOG:`"$logFile`""
        $process = Start-Process -FilePath "robocopy.exe" -ArgumentList $roboArgs -Wait -NoNewWindow -PassThru

        # Parse log for failures (e.g. ERROR 32 Sharing Violation)
        if (Test-Path $logFile) {
            # UNILOG writes UTF-16 LE
            $logContent = Get-Content -Path $logFile -Encoding Unicode -ErrorAction SilentlyContinue
            if ($logContent) {
                foreach ($line in $logContent) {
                    # Typical error format:
                    # 2026/05/13 10:10:10 ERROR 32 (0x00000020) Deleting File C:\Target\locked.dll
                    if ($line -match 'ERROR \d+ .* Deleting (?:File|Dir) (.+)') {
                        $lockedItems += $matches[1].Trim()
                    }
                }
            }
        }

        # Robocopy /MIR empties the folder but leaves the top-level directory intact.
        # Use native rmdir to destroy the root target directory.
        if (Test-Path $TargetPath) {
            Start-Process -FilePath "cmd.exe" -ArgumentList "/c rmdir /s /q `"$TargetPath`" >nul 2>&1" -Wait -NoNewWindow
        }

    } catch {
        # Fallback if Robocopy fails to execute (e.g., missing from PATH)
        Write-Warning "Robocopy purge exception ($($_.Exception.Message)). Falling back to cmd.exe deletion..."
        if (Test-Path $TargetPath) {
            Start-Process -FilePath "cmd.exe" -ArgumentList "/c del /f /s /q `"$TargetPath\*`" >nul 2>&1" -Wait -NoNewWindow
            Start-Process -FilePath "cmd.exe" -ArgumentList "/c rmdir /s /q `"$TargetPath`" >nul 2>&1" -Wait -NoNewWindow
        }
    } finally {
        # Cleanup temp items
        if (Test-Path $emptyDir) { Remove-Item -Path $emptyDir -Force -Recurse -ErrorAction SilentlyContinue }
        if (Test-Path $logFile) { Remove-Item -Path $logFile -Force -ErrorAction SilentlyContinue }
    }

    $stillExists = Test-Path $TargetPath
    return [PSCustomObject]@{
        Success = (-not $stillExists)
        LockedItems = $lockedItems
    }
}
