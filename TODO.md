# Surgical Autodesk Cleaner - Roadmap & TODO

## Future Enhancements
- [/] **Implementation of "Supervisor" Process Monitoring Pattern**
    - [x] Replace blocking `Wait-Process` or basic `while` loops with a non-blocking supervisor loop.
    - [x] Monitor the entire process tree (child processes) of an uninstaller to ensure nested `msiexec` or ODIS tasks are truly finished before moving on.
    - [x] Implement live UI feedback (elapsed time, status indicators) in the primary console while child processes are running.
    - Add logic to detect and potentially handle hidden modal dialogs or "zombie" processes that are no longer consuming resources but haven't exited.
- [ ] **Parallel Execution for Non-MSI Tasks**
    - Explore using `ForEach-Object -Parallel` for independent file system and registry wiping once all uninstallers have finished.
- [x] **Enhanced Logging**
    - [x] Real-time log tailing within the supervisor loop to surface uninstaller errors directly to the main console.
- [ ] **Remote Task Firing Architecture**
    - Implement a mechanism to dispatch `Start-SAC` scripts to remote endpoints via `Invoke-Command -AsJob`.
    - Enhance `Watch-SACProcessTree` to use `Get-CimInstance -ComputerName` for remote, disconnected process tree monitoring that is resilient to VPN/network drops.
