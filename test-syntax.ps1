$errs = @()
Get-ChildItem -Filter *.ps1 -Recurse | ForEach-Object {
    $tok = $null
    $err = $null
    [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tok, [ref]$err)
    if ($err) {
        $errs += @{File=$_.FullName; Errors=$err}
    }
}
if ($errs.Count -gt 0) {
    foreach ($e in $errs) {
        Write-Host "File: $($e.File)"
        foreach ($er in $e.Errors) {
            Write-Host "  $($er.Message) at line $($er.Extent.StartLineNumber)"
        }
    }
} else {
    Write-Host "No syntax errors found."
}
