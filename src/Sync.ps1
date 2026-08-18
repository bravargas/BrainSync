# ------------------------------------------------------------
# BrainSync - Synchronization & Package Management Module
# ------------------------------------------------------------

function Invoke-WithRetry {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock,

        [int]$MaxAttempts = 3,
        [int]$DelaySeconds = 1,
        [string]$ErrorMessage = "Operation failed"
    )

    $Attempt = 0
    while ($Attempt -lt $MaxAttempts) {
        $Attempt++
        try {
            return (& $ScriptBlock)
        }
        catch {
            if ($Attempt -ge $MaxAttempts) {
                throw "$ErrorMessage`: $($_.Exception.Message)"
            }
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}


function Copy-PackageContent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$Destination,

        [string]$ExcludeFile = "version.txt",
        [bool]$UseRobocopy = $true
    )

    $RobocopyCmd = Get-Command "robocopy.exe" -ErrorAction SilentlyContinue

    if ($UseRobocopy -and $RobocopyCmd) {
        $RobocopyArgs = @(
            $Source,
            $Destination,
            "/E",
            "/Z",
            "/FFT",
            "/R:3",
            "/W:2",
            "/XF", $ExcludeFile,
            "/NP",
            "/NFL",
            "/NDL",
            "/NJH",
            "/NJS"
        )

        $Process = Start-Process `
            -FilePath "robocopy.exe" `
            -ArgumentList $RobocopyArgs `
            -NoNewWindow `
            -Wait `
            -PassThru

        $ExitCode = $Process.ExitCode

        # Robocopy exit codes:
        # 0: No changes
        # 1: Files copied successfully
        # 2: Extra files present in destination
        # 3: 1 + 2
        # 4: Mismatches detected
        # 5: 1 + 4
        # 6: 2 + 4
        # 7: 1 + 2 + 4
        # >= 8: Fatal error occurred during copy
        if ($ExitCode -ge 8) {
            throw "Robocopy failed with exit code $ExitCode while copying from '$Source' to '$Destination'."
        }

        return
    }

    # Fallback to PowerShell Copy-Item
    Get-ChildItem -LiteralPath $Source -Force -ErrorAction Stop |
        Where-Object { $_.Name -ne $ExcludeFile } |
        ForEach-Object {
            Copy-Item `
                -LiteralPath $_.FullName `
                -Destination $Destination `
                -Recurse `
                -Force `
                -ErrorAction Stop
        }
}


function Get-ToolVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $VersionFile = Join-Path $Path "version.txt"

    if (-not (Test-Path -LiteralPath $VersionFile -PathType Leaf)) {
        return $null
    }

    return (
        Get-Content -LiteralPath $VersionFile -Raw
    ).Trim()
}


function Get-VersionedFolders {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Repository
    )

    if (-not (Test-Path -LiteralPath $Repository -PathType Container)) {
        Write-Log "Repository not found: $Repository" "ERROR"
        return @()
    }

    return @(
        Get-ChildItem `
            -LiteralPath $Repository `
            -Directory `
            -Force `
            -ErrorAction Stop |
        Where-Object {
            Test-Path `
                -LiteralPath (Join-Path $_.FullName "version.txt") `
                -PathType Leaf
        }
    )
}


function Recover-InterruptedUpdate {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    $Backup = "$Destination.backup"

    if (-not (Test-Path -LiteralPath $Backup -PathType Container)) {
        return $true
    }

    $DestinationVersion = Get-ToolVersion -Path $Destination
    $BackupVersion = Get-ToolVersion -Path $Backup

    # Destination contains a valid release marker.
    # The previous update completed, but BrainSync terminated
    # before it could remove the backup.
    if (-not [string]::IsNullOrWhiteSpace($DestinationVersion)) {

        Write-Log `
            "Stale backup detected for $Name. Destination version $DestinationVersion is complete." `
            "WARNING"

        try {
            Invoke-WithRetry -ScriptBlock {
                Remove-Item `
                    -LiteralPath $Backup `
                    -Recurse `
                    -Force `
                    -ErrorAction Stop
            } -MaxAttempts 3 -DelaySeconds 1 -ErrorMessage "Failed to remove stale backup"

            Write-Log `
                "Stale backup removed for $Name." `
                -Relevant

            return $true
        }
        catch {
            Write-Log `
                "Failed to remove stale backup for $Name`: $($_.Exception.Message)" `
                "ERROR"

            return $false
        }
    }

    # Destination is incomplete. Restore the previous valid version.
    if (-not [string]::IsNullOrWhiteSpace($BackupVersion)) {

        Write-Log `
            "Interrupted update detected for $Name. Restoring previous version $BackupVersion." `
            "WARNING"

        try {
            if (Test-Path -LiteralPath $Destination) {
                Invoke-WithRetry -ScriptBlock {
                    Remove-Item `
                        -LiteralPath $Destination `
                        -Recurse `
                        -Force `
                        -ErrorAction Stop
                } -MaxAttempts 3 -DelaySeconds 1 -ErrorMessage "Failed to clean incomplete destination"
            }

            Invoke-WithRetry -ScriptBlock {
                Move-Item `
                    -LiteralPath $Backup `
                    -Destination $Destination `
                    -Force `
                    -ErrorAction Stop
            } -MaxAttempts 3 -DelaySeconds 1 -ErrorMessage "Failed to restore previous version from backup"

            Write-Log `
                "Previous version of $Name restored successfully." `
                -Relevant

            return $true
        }
        catch {
            Write-Log `
                "Failed to recover interrupted update for $Name`: $($_.Exception.Message)" `
                "ERROR"

            return $false
        }
    }

    # Neither destination nor backup contains a valid release marker.
    # Do not remove either one automatically.
    Write-Log `
        "Unable to recover $Name. Both destination and backup are missing a valid version.txt." `
        "ERROR"

    return $false
}


function Update-VersionedFolder {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$Destination,

        [bool]$UseRobocopy = $true
    )

    $VersionFileName = "version.txt"

    # --------------------------------------------------------
    # Recover any interrupted previous update first
    # --------------------------------------------------------
    $RecoverySucceeded = Recover-InterruptedUpdate `
        -Name $Name `
        -Destination $Destination

    if (-not $RecoverySucceeded) {
        return
    }

    # --------------------------------------------------------
    # Validate source
    # --------------------------------------------------------
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        Write-Log "Source folder not found: $Source" "ERROR"
        return
    }

    $SourceVersionFile = Join-Path $Source $VersionFileName

    if (-not (Test-Path -LiteralPath $SourceVersionFile -PathType Leaf)) {
        Write-Log "version.txt not found in source: $Source" "ERROR"
        return
    }

    $SourceVersion = Get-ToolVersion -Path $Source

    if ([string]::IsNullOrWhiteSpace($SourceVersion)) {
        Write-Log "version.txt is empty in source: $Source" "ERROR"
        return
    }

    $DestinationVersion = Get-ToolVersion -Path $Destination

    if ($SourceVersion -eq $DestinationVersion) {
        Write-Log "$Name is already version $SourceVersion"
        return
    }

    # --------------------------------------------------------
    # Validate source/destination paths
    # --------------------------------------------------------
    $SourceFullPath = [System.IO.Path]::GetFullPath($Source)
    $DestinationFullPath = [System.IO.Path]::GetFullPath($Destination)

    if (
        $SourceFullPath.TrimEnd('\') -eq
        $DestinationFullPath.TrimEnd('\')
    ) {
        Write-Log `
            "Source and destination are the same path for $Name`: $Source" `
            "ERROR"

        return
    }

    # --------------------------------------------------------
    # Begin update
    # --------------------------------------------------------
    if ([string]::IsNullOrWhiteSpace($DestinationVersion)) {
        Write-Log `
            "Installing $Name version $SourceVersion" `
            -Relevant
    }
    else {
        Write-Log `
            "Updating $Name`: $DestinationVersion -> $SourceVersion" `
            -Relevant
    }

    $Backup = "$Destination.backup"

    try {
        # Remove any old backup with retry
        if (Test-Path -LiteralPath $Backup -PathType Container) {
            Invoke-WithRetry -ScriptBlock {
                Remove-Item `
                    -LiteralPath $Backup `
                    -Recurse `
                    -Force `
                    -ErrorAction Stop
            } -MaxAttempts 3 -DelaySeconds 1 -ErrorMessage "Failed to clean old backup"
        }

        # Move current installation to backup with retry
        if (Test-Path -LiteralPath $Destination -PathType Container) {
            Invoke-WithRetry -ScriptBlock {
                Move-Item `
                    -LiteralPath $Destination `
                    -Destination $Backup `
                    -Force `
                    -ErrorAction Stop
            } -MaxAttempts 3 -DelaySeconds 1 -ErrorMessage "Failed to backup current version"
        }

        # Create empty destination
        New-Item `
            -ItemType Directory `
            -Path $Destination `
            -Force `
            -ErrorAction Stop |
            Out-Null

        # Copy package content (excluding version.txt) using Robocopy / Fallback
        Copy-PackageContent `
            -Source $Source `
            -Destination $Destination `
            -ExcludeFile $VersionFileName `
            -UseRobocopy $UseRobocopy

        # Copy version.txt LAST (acts as release marker)
        Copy-Item `
            -LiteralPath $SourceVersionFile `
            -Destination (Join-Path $Destination $VersionFileName) `
            -Force `
            -ErrorAction Stop

        # Validate installed release
        $InstalledVersion = Get-ToolVersion -Path $Destination

        if ($InstalledVersion -ne $SourceVersion) {
            throw "Installed version does not match source version."
        }

        # Commit update: remove backup
        if (Test-Path -LiteralPath $Backup -PathType Container) {
            try {
                Remove-Item `
                    -LiteralPath $Backup `
                    -Recurse `
                    -Force `
                    -ErrorAction SilentlyContinue
            }
            catch {
                # Will be cleaned on subsequent runs
            }
        }

        Write-Log `
            "$Name updated successfully to $SourceVersion" `
            -Relevant
    }
    catch {
        Write-Log `
            "Update failed for $Name`: $($_.Exception.Message)" `
            "ERROR"

        # Immediate rollback
        Remove-Item `
            -LiteralPath $Destination `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue

        if (Test-Path -LiteralPath $Backup -PathType Container) {
            try {
                Invoke-WithRetry -ScriptBlock {
                    Move-Item `
                        -LiteralPath $Backup `
                        -Destination $Destination `
                        -Force `
                        -ErrorAction Stop
                } -MaxAttempts 3 -DelaySeconds 1 -ErrorMessage "Failed to restore backup"

                Write-Log `
                    "Previous version of $Name restored." `
                    -Relevant
            }
            catch {
                Write-Log `
                    "Failed to restore previous version of $Name`: $($_.Exception.Message)" `
                    "ERROR"
            }
        }
    }
}


function Sync-BrainSyncRepository {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceRepository,

        [Parameter(Mandatory = $true)]
        [string]$DestinationRoot,

        [string]$NameSuffix = "",

        [bool]$UseRobocopy = $true
    )

    try {
        $Tools = Get-VersionedFolders -Repository $SourceRepository

        if ($Tools.Count -eq 0) {
            Write-Log `
                "No versioned folders found in repository: $SourceRepository" `
                "WARNING"
            return
        }

        foreach ($Tool in $Tools) {
            $ToolName = $Tool.Name
            $Destination = Join-Path $DestinationRoot $ToolName

            Update-VersionedFolder `
                -Name "$ToolName$NameSuffix" `
                -Source $Tool.FullName `
                -Destination $Destination `
                -UseRobocopy $UseRobocopy
        }
    }
    catch {
        Write-Log `
            "Failed while synchronizing repository: $($_.Exception.Message)" `
            "ERROR"
    }
}
