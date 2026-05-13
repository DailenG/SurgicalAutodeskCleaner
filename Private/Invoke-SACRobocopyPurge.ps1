<#
.SYNOPSIS
    Utilizes Robocopy to perform an ultra-fast, scorched-earth directory purge.

.DESCRIPTION
    PowerShell's native Remove-Item is susceptible to MAX_PATH (260 char) limitations
    and can halt prematurely on locked files. This helper creates a temporary empty
    directory and uses robocopy /MIR to mirror the empty state to the target directory.
    This forces Windows to bypass path limits and rapidly delete all contents.

    Robocopy flags used:
      /A-:R  - Strip read-only attribute from extra files before deletion
      /XJ    - Exclude NTFS junction points (handled separately to avoid recursing into them)
      /LOG   - Capture robocopy output for diagnostics

    It returns an object indicating success and any files that were actively locked.

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

    $emptyDir    = Join-Path $env:TEMP ([Guid]::NewGuid().ToString())
    $logFile     = Join-Path $env:TEMP ("RCLog_" + [Guid]::NewGuid().ToString() + ".log")
    $lockedItems = @()
    $TargetPath  = $TargetPath.TrimEnd('\')

    try {
        # Create the temporary empty directory
        New-Item -ItemType Directory -Path $emptyDir -Force | Out-Null

        # Execute robocopy mirror to bypass MAX_PATH and bulk-delete standard files.
        # /A-:R strips read-only bits so they don't survive the mirror.
        # /XJ   excludes NTFS junction points (handled explicitly below).
        # /LOG  captures robocopy output to the temp log for post-mortem diagnostics.
        $roboArgs = "`"$emptyDir`" `"$TargetPath`" /MIR /A-:R /R:0 /W:0 /NP /NFL /NDL /NJH /NJS /XJ /LOG:`"$logFile`""
        Start-Process -FilePath "robocopy.exe" -ArgumentList $roboArgs -Wait -NoNewWindow -ErrorAction Stop

        # Robocopy /XJ skips junction points entirely. Explicitly delete them now,
        # sorted deepest-first so parent junctions are removed after their children.
        if (Test-Path $TargetPath) {
            Get-ChildItem -Path $TargetPath -Recurse -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint } |
                Sort-Object FullName -Descending |
                ForEach-Object {
                    try { [System.IO.Directory]::Delete($_.FullName, $false) } catch {}
                }
        }

        # Final sweep: catch any remaining read-only/hidden files and empty directories
        # that slipped past robocopy (e.g. files locked briefly then released).
        if (Test-Path $TargetPath) {
            Start-Process -FilePath "cmd.exe" -ArgumentList "/c del /f /a /q /s `"$TargetPath\*`" >nul 2>&1" -Wait -NoNewWindow
            Start-Process -FilePath "cmd.exe" -ArgumentList "/c rmdir /s /q `"$TargetPath`" >nul 2>&1"        -Wait -NoNewWindow
        }

    } catch {
        # Fallback if Robocopy fails to execute (e.g. binary not found in minimal environments)
        Write-Warning "Robocopy purge exception ($($_.Exception.Message)). Falling back to cmd.exe deletion..."
        if (Test-Path $TargetPath) {
            Start-Process -FilePath "cmd.exe" -ArgumentList "/c del /f /a /q /s `"$TargetPath\*`" >nul 2>&1" -Wait -NoNewWindow
            Start-Process -FilePath "cmd.exe" -ArgumentList "/c rmdir /s /q `"$TargetPath`" >nul 2>&1"        -Wait -NoNewWindow
        }
    } finally {
        if (Test-Path $emptyDir) { Remove-Item -Path $emptyDir -Force -Recurse -ErrorAction SilentlyContinue }
        if (Test-Path $logFile)  { Remove-Item -Path $logFile  -Force -ErrorAction SilentlyContinue }
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
        Success     = (-not $stillExists)
        LockedItems = $lockedItems
    }
}
