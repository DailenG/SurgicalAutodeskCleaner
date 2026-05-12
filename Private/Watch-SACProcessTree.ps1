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
        [int]$RootPID,
        
        [string]$DisplayName = "Process",
        [int]$TimeoutMinutes = 20,
        [int]$IdleTimeoutMinutes = 5
    )

    $StartTime = Get-Date
    $ZeroCpuTime = $null
    $LastTotalCpu = $null
    
    # Capture root creation time to prevent monitoring recycled PIDs
    $RootCreationTime = $null
    try {
        $rootCim = Get-CimInstance Win32_Process -Filter "ProcessId = $RootPID" -ErrorAction Stop
        if ($rootCim) { $RootCreationTime = $rootCim.CreationDate }
    } catch {
        # If we can't get the root creation time (e.g. process exited too fast), we just continue.
    }

    # Helper function to recursively find all descendant processes
    function Get-ProcessTree {
        param([int]$RootId, [datetime]$RootTime)
        
        # Fetch all processes once per loop iteration to minimize WMI overhead
        $allProcs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue
        if (-not $allProcs) { return @{} }
        
        $tree = @{}
        $queue = [System.Collections.Generic.Queue[int]]::new()
        $queue.Enqueue($RootId)
        
        while ($queue.Count -gt 0) {
            $currentId = $queue.Dequeue()
            
            # Find direct children of the current ID
            $children = $allProcs | Where-Object { $_.ParentProcessId -eq $currentId }
            
            foreach ($child in $children) {
                # Safeguard: PID Recycling. A child cannot be older than the root process.
                if ($null -ne $RootTime -and $child.CreationDate -lt $RootTime) {
                    continue
                }
                
                # Prevent infinite loops in case of bizarre circular PID relationships
                if (-not $tree.ContainsKey($child.ProcessId)) {
                    $tree[$child.ProcessId] = $child
                    $queue.Enqueue($child.ProcessId)
                }
            }
        }
        
        return $tree
    }

    $isRemote = $false
    if (Get-Command Test-SACRemoteSession -ErrorAction SilentlyContinue) {
        $isRemote = Test-SACRemoteSession
    }

    Write-Host "`n  Monitoring process tree for $DisplayName..." -ForegroundColor Cyan

    while ($true) {
        $elapsed = (Get-Date) - $StartTime

        # 1. Check Hard Timeout
        if ($elapsed.TotalMinutes -ge $TimeoutMinutes) {
            Write-Host "`n  [!] Hard timeout ($TimeoutMinutes m) reached for $DisplayName. Terminating tree." -ForegroundColor Red
            try { Stop-Process -Id $RootPID -Force -ErrorAction SilentlyContinue } catch {}
            
            $currentTree = Get-ProcessTree -RootId $RootPID -RootTime $RootCreationTime
            foreach ($childId in $currentTree.Keys) {
                try { Stop-Process -Id $childId -Force -ErrorAction SilentlyContinue } catch {}
            }
            break
        }

        # 2. Check if processes are alive
        $rootAlive = [bool](Get-Process -Id $RootPID -ErrorAction SilentlyContinue)
        $currentTree = Get-ProcessTree -RootId $RootPID -RootTime $RootCreationTime
        
        if (-not $rootAlive -and $currentTree.Count -eq 0) {
            Write-Host "`n  [*] Process tree for $DisplayName has exited cleanly." -ForegroundColor Green
            break
        }

        # 3. Calculate Aggregate Resource Usage
        $totalCpu = 0
        $totalMemMB = 0
        $activeCount = 0

        if ($rootAlive) {
            try {
                $p = Get-Process -Id $RootPID -ErrorAction Stop
                $totalCpu += $p.CPU
                $totalMemMB += ($p.WorkingSet64 / 1MB)
                $activeCount++
            } catch {}
        }

        foreach ($childId in $currentTree.Keys) {
            try {
                $p = Get-Process -Id $childId -ErrorAction Stop
                $totalCpu += $p.CPU
                $totalMemMB += ($p.WorkingSet64 / 1MB)
                $activeCount++
            } catch {}
        }

        # 4. Check Idle Timeout
        if ($null -ne $LastTotalCpu -and $totalCpu -eq $LastTotalCpu) {
            if ($null -eq $ZeroCpuTime) { $ZeroCpuTime = Get-Date }
            elseif (((Get-Date) - $ZeroCpuTime).TotalMinutes -ge $IdleTimeoutMinutes) {
                Write-Host "`n  [!] Process tree idle timeout ($IdleTimeoutMinutes m) reached for $DisplayName. Terminating tree." -ForegroundColor Yellow
                try { Stop-Process -Id $RootPID -Force -ErrorAction SilentlyContinue } catch {}
                foreach ($childId in $currentTree.Keys) {
                    try { Stop-Process -Id $childId -Force -ErrorAction SilentlyContinue } catch {}
                }
                break
            }
        } else {
            $ZeroCpuTime = $null
            $LastTotalCpu = $totalCpu
        }

        # 5. UI Feedback
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
