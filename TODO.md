# Surgical Autodesk Cleaner - Roadmap & TODO

## Future Enhancements
- [x] **Implementation of "Supervisor" Process Monitoring Pattern**
    - [x] Replace blocking `Wait-Process` or basic `while` loops with a non-blocking supervisor loop.
    - [x] Monitor the entire process tree (child processes) of an uninstaller to ensure nested `msiexec` or ODIS tasks are truly finished before moving on.
    - [x] Implement live UI feedback (elapsed time, status indicators) in the primary console while child processes are running.
    - [x] Add logic to detect and potentially handle hidden modal dialogs or "zombie" processes that are no longer consuming resources but haven't exited. (Completed: Idle CPU + Static Mem detection)
- [ ] **Parallel Execution for Non-MSI Tasks**
    - Explore using `ForEach-Object -Parallel` for independent file system and registry wiping once all uninstallers have finished.
- [x] **Enhanced Logging**
    - [x] Real-time log tailing within the supervisor loop to surface uninstaller errors directly to the main console.
- [ ] **Unit Testing Improvements**
    - Increase coverage for `Get-SACTier` classification logic.
    - Add mock-based testing for registry parsing and uninstaller launch logic.
- [x] **Remote Task Firing Architecture**
    - [x] Implement a mechanism to dispatch `Start-SAC` scripts to remote endpoints via `Invoke-Command -AsJob`. (Completed: `Invoke-SACRemote`)
    - [x] Enhance `Watch-SACProcessTree` to use `Get-CimInstance -ComputerName` for remote, disconnected process tree monitoring that is resilient to VPN/network drops. (Completed)
- [ ] **Encoding & Standards Compliance**
    - Perform a project-wide encoding check to ensure all `.ps1`, `.psm1`, and `.psd1` files are saved as UTF-8 with BOM for consistent rendering of ASCII box-drawing characters across different host environments.
    - Centralize redundant helper functions (Logging, Interactive tests) to improve module maintainability. (Completed: Centralized in `Private\Invoke-SACLogger.ps1`)

