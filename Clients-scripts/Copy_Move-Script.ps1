function Invoke-FileCopyMove {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [ValidateSet("Copy", "Move")][string]$Operation = "Copy",
        [string]$Filter = "*",
        [switch]$Recurse,
        [switch]$DryRun,
        [string]$LogFile
    )

    # ── Logging helper ──────────────────────────────────────────────
    function Write-Log {
        param([string]$Message, [string]$Level = "INFO")
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $entry = "[$timestamp] [$Level] $Message"
        Write-Host $entry -ForegroundColor $(switch ($Level) {
            "INFO"    { "Cyan" }
            "SUCCESS" { "Green" }
            "WARN"    { "Yellow" }
            "ERROR"   { "Red" }
            default   { "White" }
        })
        if ($LogFile) { $entry | Out-File -FilePath $LogFile -Append -Encoding UTF8 }
    }

    # ── Validate source ─────────────────────────────────────────────
    if (-not (Test-Path $Source)) {
        Write-Log "Source path not found: '$Source'" "ERROR"
        return
    }

    # ── Ensure destination exists ───────────────────────────────────
    if (-not (Test-Path $Destination)) {
        if ($DryRun) {
            Write-Log "[DRY-RUN] Would create destination folder: '$Destination'" "WARN"
        } else {
            try {
                New-Item -ItemType Directory -Path $Destination -Force | Out-Null
                Write-Log "Created destination folder: '$Destination'"
            } catch {
                Write-Log "Failed to create destination: $_" "ERROR"
                return
            }
        }
    }

    # ── Gather files ────────────────────────────────────────────────
    $getParams = @{ Path = $Source; Filter = $Filter; File = $true }
    if ($Recurse) { $getParams.Recurse = $true }

    $files = Get-ChildItem @getParams
    $total = $files.Count
    $success = 0
    $failed  = 0

    Write-Log "Found $total file(s) to $Operation from '$Source' to '$Destination'"
    if ($DryRun) { Write-Log "DRY-RUN mode — no changes will be made." "WARN" }

    # ── Process each file ───────────────────────────────────────────
    foreach ($file in $files) {

        # Preserve subfolder structure when recursing
        $relativePath = $file.FullName.Substring($Source.TrimEnd('\','//').Length).TrimStart('\','/')
        $destPath     = Join-Path $Destination $relativePath
        $destDir      = Split-Path $destPath -Parent

        if ($DryRun) {
            Write-Log "[DRY-RUN] Would $Operation`: '$($file.FullName)' → '$destPath'" "INFO"
            $success++
            continue
        }

        try {
            # Create intermediate folders if needed
            if (-not (Test-Path $destDir)) {
                New-Item -ItemType Directory -Path $destDir -Force | Out-Null
            }

            if ($Operation -eq "Copy") {
                Copy-Item -Path $file.FullName -Destination $destPath -Force
            } else {
                Move-Item -Path $file.FullName -Destination $destPath -Force
            }

            Write-Log "$Operation success: '$($file.Name)' → '$destPath'" "SUCCESS"
            $success++

        } catch {
            Write-Log "Failed to $Operation '$($file.FullName)': $_" "ERROR"
            $failed++
        }
    }

    # ── Summary ─────────────────────────────────────────────────────
    Write-Log "─────────────────────────────────────────"
    Write-Log "Done. Total: $total | Success: $success | Failed: $failed" $(
        if ($failed -gt 0) { "WARN" } else { "SUCCESS" }
    )
    if ($LogFile) { Write-Log "Log saved to: $LogFile" }
}






# Copy all files (with subfolders), log to file
Invoke-FileCopyMove -Source "C:\Data" -Destination "D:\Backup" `
                    -Operation Copy -Recurse -LogFile "C:\logs\copy.log"

# Dry-run a move of only .txt files
Invoke-FileCopyMove -Source "C:\Docs" -Destination "D:\Archive" `
                    -Operation Move -Filter "*.txt" -Recurse -DryRun

# Move files without recursion, no log file
Invoke-FileCopyMove -Source "C:\Temp" -Destination "C:\Done" -Operation Move