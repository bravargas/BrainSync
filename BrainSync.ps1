param (
    [string]$ConfigFile,
    [string]$ComputerName = $env:COMPUTERNAME
)

$Script:HadErrors = $false
$Script:RelevantActivity = $false
$Script:LogFile = $null
$Script:LogMode = "ChangesOnly"
$Script:LogBuffer = [System.Collections.Generic.List[string]]::new()
$Script:Mutex = $null
$Script:MutexAcquired = $false


function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet("INFO", "WARNING", "ERROR")]
        [string]$Level = "INFO",

        [switch]$Relevant
    )

    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $Line = "$Timestamp [$Level] $Message"

    Write-Host $Line

    $Script:LogBuffer.Add($Line)

    if ($Relevant -or $Level -in @("WARNING", "ERROR")) {
        $Script:RelevantActivity = $true
    }

    if ($Level -eq "ERROR") {
        $Script:HadErrors = $true
    }
}


function Save-Log {

    $ShouldWrite = (
        $Script:LogMode -eq "All" -or
        $Script:RelevantActivity
    )

    if (-not $ShouldWrite) {
        return
    }

    if (-not $Script:LogFile) {
        return
    }

    Add-Content `
        -LiteralPath $Script:LogFile `
        -Value $Script:LogBuffer
}


function Release-BrainSyncMutex {

    if ($Script:MutexAcquired -and $Script:Mutex) {

        try {
            $Script:Mutex.ReleaseMutex()
        }
        catch {
            # Nothing else to do here.
        }

        $Script:MutexAcquired = $false
    }

    if ($Script:Mutex) {

        $Script:Mutex.Dispose()
        $Script:Mutex = $null
    }
}


function Complete-BrainSync {
    param(
        [int]$ExitCode
    )

    if ($ExitCode -eq 0) {
        Write-Log "BrainSync completed successfully."
    }
    else {
        Write-Log "BrainSync completed with errors." "ERROR"
    }

    Write-Log "------------------------------------------------------------"

    Save-Log
    Release-BrainSyncMutex

    exit $ExitCode
}


function Resolve-ConfiguredPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PathValue,

        [Parameter(Mandatory = $true)]
        [string]$BasePath
    )

    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        throw "Path value is empty."
    }

    $ExpandedPath = [System.Environment]::ExpandEnvironmentVariables($PathValue)

    if ([System.IO.Path]::IsPathRooted($ExpandedPath)) {
        return $ExpandedPath
    }

    return [System.IO.Path]::GetFullPath(
        (Join-Path $BasePath $ExpandedPath)
    )
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


        # ----------------------------------------------------
        # Copy package content
        # version.txt is deliberately excluded
        # ----------------------------------------------------

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


        # ----------------------------------------------------
        # Copy version.txt LAST
        #
        # Once this file exists with the expected value,
        # the destination is considered a complete release.
        # ----------------------------------------------------

        Copy-Item `
            -LiteralPath $SourceVersionFile `
            -Destination (Join-Path $Destination $VersionFileName) `
            -Force `
            -ErrorAction Stop


        # ----------------------------------------------------
        # Validate installed release
        # ----------------------------------------------------

        $InstalledVersion = Get-ToolVersion -Path $Destination

        if ($InstalledVersion -ne $SourceVersion) {
            throw "Installed version does not match source version."
        }


        # ----------------------------------------------------
        # Commit update
        # ----------------------------------------------------

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


        # ----------------------------------------------------
        # Immediate rollback
        # ----------------------------------------------------

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


# ------------------------------------------------------------
# Resolve script directory
# ------------------------------------------------------------

$ScriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path


# ------------------------------------------------------------
# Validate config parameter
# ------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($ConfigFile)) {
    throw "ConfigFile is required. Example: -ConfigFile .\configs\DEV.json"
}


# ------------------------------------------------------------
# Resolve config file
# ------------------------------------------------------------

try {

    $ResolvedConfigPath = Resolve-Path `
        -LiteralPath $ConfigFile `
        -ErrorAction Stop
}
catch {

    $RelativeConfigPath = Join-Path $ScriptDirectory $ConfigFile

    try {

        $ResolvedConfigPath = Resolve-Path `
            -LiteralPath $RelativeConfigPath `
            -ErrorAction Stop
    }
    catch {

        throw "Config file not found: $ConfigFile"
    }
}


# ------------------------------------------------------------
# Load config
# ------------------------------------------------------------

try {

    $config = Get-Content `
        -LiteralPath $ResolvedConfigPath.Path `
        -Raw `
        -ErrorAction Stop |
        ConvertFrom-Json `
        -ErrorAction Stop
}
catch {

    throw "Failed to load config file: $($_.Exception.Message)"
}

$ConfigDirectory = Split-Path -Parent $ResolvedConfigPath.Path


# ------------------------------------------------------------
# Resolve LogMode
# ------------------------------------------------------------

if ($config.LogMode) {

    if ($config.LogMode -notin @("All", "ChangesOnly")) {
        throw "Invalid LogMode '$($config.LogMode)'. Valid values: All, ChangesOnly."
    }

    $Script:LogMode = $config.LogMode
}


# ------------------------------------------------------------
# Resolve computer configuration
# ------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($ComputerName)) {
    throw "ComputerName could not be determined."
}

$ComputerName = $ComputerName.ToUpper()

$ComputerConfig = $config.Computers.$ComputerName

if ($null -eq $ComputerConfig) {
    throw "No BrainSync configuration found for computer: $ComputerName"
}


# ------------------------------------------------------------
# Acquire single-instance mutex
# ------------------------------------------------------------

$MutexName = "Global\BrainSync_$ComputerName"

try {

    $Script:Mutex = [System.Threading.Mutex]::new(
        $false,
        $MutexName
    )

    try {

        $Script:MutexAcquired = $Script:Mutex.WaitOne(0)
    }
    catch [System.Threading.AbandonedMutexException] {

        # Previous BrainSync process terminated unexpectedly.
        # Windows grants this execution ownership of the mutex.
        $Script:MutexAcquired = $true
    }

    if (-not $Script:MutexAcquired) {

        Write-Host "BrainSync is already running on $ComputerName. Exiting."

        $Script:Mutex.Dispose()
        $Script:Mutex = $null

        exit 0
    }
}
catch {

    if ($Script:Mutex) {
        $Script:Mutex.Dispose()
    }

    throw "Failed to create BrainSync mutex: $($_.Exception.Message)"
}


# ------------------------------------------------------------
# Initialize logging
# ------------------------------------------------------------

$LogDirectory = Join-Path $ScriptDirectory "logs"

if (-not (Test-Path -LiteralPath $LogDirectory -PathType Container)) {

    New-Item `
        -ItemType Directory `
        -Path $LogDirectory `
        -Force |
        Out-Null
}

$LogName = "BrainSync_$ComputerName.log"
$Script:LogFile = Join-Path $LogDirectory $LogName

Write-Log "------------------------------------------------------------"
Write-Log "BrainSync started - $ComputerName"
Write-Log "Config: $($ResolvedConfigPath.Path)"
Write-Log "Log mode: $Script:LogMode"


# ------------------------------------------------------------
# Resolve local repository
# Computer-level value overrides global value
# ------------------------------------------------------------

$LocalRepositoryValue = $config.LocalRepository

if ($ComputerConfig.LocalRepository) {
    $LocalRepositoryValue = $ComputerConfig.LocalRepository
}

try {

    $LocalRepository = Resolve-ConfiguredPath `
        -PathValue $LocalRepositoryValue `
        -BasePath $ConfigDirectory
}
catch {

    Write-Log `
        "Failed to resolve LocalRepository: $($_.Exception.Message)" `
        "ERROR"

    Complete-BrainSync -ExitCode 1
}


# ------------------------------------------------------------
# Resolve destination root
# Computer-level value overrides global value
# ------------------------------------------------------------

$DestinationRootValue = $config.DestinationRoot

if ($ComputerConfig.DestinationRoot) {
    $DestinationRootValue = $ComputerConfig.DestinationRoot
}

try {

    $DestinationRoot = Resolve-ConfiguredPath `
        -PathValue $DestinationRootValue `
        -BasePath $ConfigDirectory
}
catch {

    Write-Log `
        "Failed to resolve DestinationRoot: $($_.Exception.Message)" `
        "ERROR"

    Complete-BrainSync -ExitCode 1
}


# ------------------------------------------------------------
# STEP 1
# Refresh local repository from upstream when configured
# ------------------------------------------------------------

if ($ComputerConfig.UpstreamSource) {

    try {

        $UpstreamSource = Resolve-ConfiguredPath `
            -PathValue $ComputerConfig.UpstreamSource `
            -BasePath $ConfigDirectory

        Write-Log "Refreshing local repository from: $UpstreamSource"

        $UpstreamTools = Get-VersionedFolders `
            -Repository $UpstreamSource

        if ($UpstreamTools.Count -eq 0) {

            Write-Log `
                "No versioned folders found in upstream source: $UpstreamSource" `
                "WARNING"
        }

        foreach ($Tool in $UpstreamTools) {

            $ToolName = $Tool.Name
            $Destination = Join-Path $LocalRepository $ToolName

            Update-VersionedFolder `
                -Name "$ToolName source" `
                -Source $Tool.FullName `
                -Destination $Destination
        }
    }
    catch {

        Write-Log `
            "Failed while refreshing local repository: $($_.Exception.Message)" `
            "ERROR"
    }
}
else {

    Write-Log "No upstream source configured. Using local repository."
}


# ------------------------------------------------------------
# STEP 2
# Discover and update operational tools from local repository
# ------------------------------------------------------------

Write-Log "Discovering tools in local repository: $LocalRepository"

try {

    $LocalTools = Get-VersionedFolders `
        -Repository $LocalRepository

    if ($LocalTools.Count -eq 0) {

        Write-Log `
            "No versioned folders found in local repository: $LocalRepository" `
            "WARNING"
    }

    foreach ($Tool in $LocalTools) {

        $ToolName = $Tool.Name
        $Destination = Join-Path $DestinationRoot $ToolName

        Update-VersionedFolder `
            -Name $ToolName `
            -Source $Tool.FullName `
            -Destination $Destination
    }
}
catch {

    Write-Log `
        "Failed while updating local tools: $($_.Exception.Message)" `
        "ERROR"
}


# ------------------------------------------------------------
# Finish
# ------------------------------------------------------------

if ($Script:HadErrors) {
    Complete-BrainSync -ExitCode 1
}

Complete-BrainSync -ExitCode 0