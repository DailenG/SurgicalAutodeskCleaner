# Surgical Autodesk Cleaner - Roadmap & TODO

## Future Enhancements
- [ ] **Implementation of "Supervisor" Process Monitoring Pattern**
    - Replace blocking `Wait-Process` or basic `while` loops with a non-blocking supervisor loop.
    - Monitor the entire process tree (child processes) of an uninstaller to ensure nested `msiexec` or ODIS tasks are truly finished before moving on.
    - Implement live UI feedback (elapsed time, status indicators) in the primary console while child processes are running.
    - Add logic to detect and potentially handle hidden modal dialogs or "zombie" processes that are no longer consuming resources but haven't exited.
- [ ] **Parallel Execution for Non-MSI Tasks**
    - Explore using `ForEach-Object -Parallel` for independent file system and registry wiping once all uninstallers have finished.
- [ ] **Enhanced Logging**
    - Real-time log tailing within the supervisor loop to surface uninstaller errors directly to the main console.
