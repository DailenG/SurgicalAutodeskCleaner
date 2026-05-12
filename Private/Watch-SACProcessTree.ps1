function Watch-SACProcessTree {
    <#
    .SYNOPSIS
        Monitors a process and its entire descendant process tree until all processes have exited.
    .DESCRIPTION
        Acts as a "Supervisor" for uninstallation tasks. It tracks a root Process ID and recursively
        finds all child processes. It monitors the aggregate CPU and Memory usage of the entire tree.
        Includes safeguards against PID recycling and enforces hard/idle timeouts.
    .PARAMETER RootPID
        The Process ID of the root process to monitor.
    .PARAMETER DisplayName
        A friendly name for the process being monitored, used in UI feedback.
    .PARAMETER TimeoutMinutes
        The maximum total time (in minutes) the process tree is allowed to run before being force-killed.
    .PARAMETER IdleTimeoutMinutes
        The maximum time (in minutes) the aggregate CPU time can remain unchanged before the tree is considered hung and force-killed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [System.Diagnostics.Process]$RootProcess,
        
        [string]$DisplayName = "Process",
        [int]$TimeoutMinutes = 20,
        [int]$IdleTimeoutMinutes = 5
    )

    $StartTime = Get-Date
    $ZeroCpuTime = $null
    $LastTotalCpu = $null
    
    # We maintain a stateful dictionary of known processes: PID -> CreationDate
    # This completely eliminates PID recycling vulnerabilities.
    $KnownProcs = @{}
    
    $RootPID = $RootProcess.Id
    
    try {
        $rootCim = Get-CimInstance Win32_Process -Filter "ProcessId = $RootPID" -ErrorAction Stop
        if ($rootCim) { 
            $KnownProcs[$RootPID] = $rootCim.CreationDate 
        }
    } catch {
        # If it exited before we could grab WMI info, we still add it so we can at least try to find children 
        # spawned in the same second, though it's less reliable.
        $KnownProcs[$RootPID] = $StartTime
    }

    # Helper function to update the known process tree
    function Update-KnownTree {
        $allProcs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue
        if (-not $allProcs) { return }

        # Build a quick lookup dictionary for this loop
        $currentProcs = @{}
        foreach ($p in $allProcs) {
            $currentProcs[$p.ProcessId] = $p
        }

        $addedNew = $true
        while ($addedNew) {
            $addedNew = $false
            foreach ($p in $allProcs) {
                # If this process is NOT known, but its parent IS known...
                if (-not $KnownProcs.ContainsKey($p.ProcessId) -and $KnownProcs.ContainsKey($p.ParentProcessId)) {
                    $parentCreationTime = $KnownProcs[$p.ParentProcessId]
                    # PID Recycling Defense: The child must be created at or after the parent's creation time.
                    if ($p.CreationDate -ge $parentCreationTime) {
                        $KnownProcs[$p.ProcessId] = $p.CreationDate
                        $addedNew = $true
                    }
                }
            }
        }
        return $currentProcs
    }

    $isRemote = $false
    if (Get-Command Test-SACRemoteSession -ErrorAction SilentlyContinue) {
        $isRemote = Test-SACRemoteSession
    }

    Write-Host "`n  Monitoring process tree for $DisplayName..." -ForegroundColor Cyan

    while ($true) {
        $elapsed = (Get-Date) - $StartTime

        # Update our stateful tree with any new descendants
        $currentCimProcs = Update-KnownTree

        # 1. Check Hard Timeout
        if ($elapsed.TotalMinutes -ge $TimeoutMinutes) {
            Write-Host "`n  [!] Hard timeout ($TimeoutMinutes m) reached for $DisplayName. Terminating tree." -ForegroundColor Red
            foreach ($pidToKill in $KnownProcs.Keys) {
                try { Stop-Process -Id $pidToKill -Force -ErrorAction SilentlyContinue } catch {}
            }
            break
        }

        # 2. Evaluate active processes from our known list
        $activeCount = 0
        $totalCpu = 0
        $totalMemMB = 0

        foreach ($knownPid in $KnownProcs.Keys) {
            # Ensure the PID hasn't been recycled by checking CreationDate against our state
            $cimProc = $currentCimProcs[$knownPid]
            if ($null -ne $cimProc -and $cimProc.CreationDate -eq $KnownProcs[$knownPid]) {
                $activeCount++
                try {
                    # Get-Process is needed for accurate CPU/Memory
                    $p = Get-Process -Id $knownPid -ErrorAction Stop
                    $totalCpu += $p.CPU
                    $totalMemMB += ($p.WorkingSet64 / 1MB)
                } catch {}
            }
        }

        # Root logic: The root process must be truly dead (using the .NET object) 
        # and no valid known children can be active.
        if ($RootProcess.HasExited -and $activeCount -eq 0) {
            Write-Host "`n  [*] Process tree for $DisplayName has exited cleanly." -ForegroundColor Green
            break
        }

        # 3. Check Idle Timeout
        if ($null -ne $LastTotalCpu -and $totalCpu -eq $LastTotalCpu) {
            if ($null -eq $ZeroCpuTime) { $ZeroCpuTime = Get-Date }
            elseif (((Get-Date) - $ZeroCpuTime).TotalMinutes -ge $IdleTimeoutMinutes) {
                Write-Host "`n  [!] Process tree idle timeout ($IdleTimeoutMinutes m) reached for $DisplayName. Terminating tree." -ForegroundColor Yellow
                foreach ($pidToKill in $KnownProcs.Keys) {
                    try { Stop-Process -Id $pidToKill -Force -ErrorAction SilentlyContinue } catch {}
                }
                break
            }
        } else {
            $ZeroCpuTime = $null
            $LastTotalCpu = $totalCpu
        }

        # 4. UI Feedback
        if (-not $isRemote) {
            $elapsedStr = "{0:mm\:ss}" -f $elapsed
            $memStr = [math]::Round($totalMemMB, 1)
            $statusLine = "    [Elapsed: $elapsedStr] | [Active Procs: $activeCount] | [Tree Mem: ${memStr}MB]"
            # Pad with spaces to overwrite previous line completely
            $statusLine = $statusLine.PadRight(80)
            Write-Host "`r$statusLine" -NoNewline -ForegroundColor DarkGray
        }

        Start-Sleep -Milliseconds 1500
    }
    
    if (-not $isRemote) { Write-Host "" } # Newline cleanup
}
