# ------------------------------------------------------------
# BrainSync - Synchronization & Package Management Module
# ------------------------------------------------------------

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
            Remove-Item `
                -LiteralPath $Backup `
                -Recurse `
                -Force `
                -ErrorAction Stop

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
                Remove-Item `
                    -LiteralPath $Destination `
                    -Recurse `
                    -Force `
                    -ErrorAction Stop
            }

            Move-Item `
                -LiteralPath $Backup `
                -Destination $Destination `
                -Force `
                -ErrorAction Stop

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
        [string]$Destination
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
        # Remove any old backup.
        # At this point Recover-InterruptedUpdate has already
        # evaluated any backup left from a previous execution.
        Remove-Item `
            -LiteralPath $Backup `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue

        # Move current installation to backup
        if (Test-Path -LiteralPath $Destination -PathType Container) {
            Move-Item `
                -LiteralPath $Destination `
                -Destination $Backup `
                -Force `
                -ErrorAction Stop
        }

        # Create empty destination
        New-Item `
            -ItemType Directory `
            -Path $Destination `
            -Force `
            -ErrorAction Stop |
            Out-Null

        # Copy package content (excluding version.txt)
        Get-ChildItem `
            -LiteralPath $Source `
            -Force `
            -ErrorAction Stop |
        Where-Object {
            $_.Name -ne $VersionFileName
        } |
        ForEach-Object {
            Copy-Item `
                -LiteralPath $_.FullName `
                -Destination $Destination `
                -Recurse `
                -Force `
                -ErrorAction Stop
        }

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

        # Commit update
        Remove-Item `
            -LiteralPath $Backup `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue

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
                Move-Item `
                    -LiteralPath $Backup `
                    -Destination $Destination `
                    -Force `
                    -ErrorAction Stop

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

        [string]$NameSuffix = ""
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
                -Destination $Destination
        }
    }
    catch {
        Write-Log `
            "Failed while synchronizing repository: $($_.Exception.Message)" `
            "ERROR"
    }
}
