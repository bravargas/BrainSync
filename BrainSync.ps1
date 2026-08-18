param (
    [string]$ConfigFile,
    [string]$ComputerName = $env:COMPUTERNAME
)

$ScriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path

# ------------------------------------------------------------
# Import Modules
# ------------------------------------------------------------
. (Join-Path $ScriptDirectory "src\Logging.ps1")
. (Join-Path $ScriptDirectory "src\Mutex.ps1")
. (Join-Path $ScriptDirectory "src\Config.ps1")
. (Join-Path $ScriptDirectory "src\Sync.ps1")


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


# ------------------------------------------------------------
# Parameter Validation
# ------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($ConfigFile)) {
    throw "ConfigFile is required. Example: -ConfigFile .\configs\DEV.json"
}

if ([string]::IsNullOrWhiteSpace($ComputerName)) {
    throw "ComputerName could not be determined."
}

$ComputerName = $ComputerName.ToUpper()


# ------------------------------------------------------------
# Single-Instance Concurrency Control
# ------------------------------------------------------------
$MutexAcquired = Acquire-BrainSyncMutex -ComputerName $ComputerName

if (-not $MutexAcquired) {
    Write-Host "BrainSync is already running on $ComputerName. Exiting."
    exit 0
}


# ------------------------------------------------------------
# Main Execution Orchestration
# ------------------------------------------------------------
try {
    # Initialize basic logging
    $LogDirectory = Join-Path $ScriptDirectory "logs"
    Initialize-BrainSyncLogging `
        -LogDirectory $LogDirectory `
        -ComputerName $ComputerName

    # Load and validate environment/computer configuration
    $ConfigContext = Get-BrainSyncConfig `
        -ConfigFile $ConfigFile `
        -ComputerName $ComputerName `
        -ScriptDirectory $ScriptDirectory

    # Apply configuration LogMode
    Set-BrainSyncLogMode -LogMode $ConfigContext.LogMode

    Write-Log "------------------------------------------------------------"
    Write-Log "BrainSync started - $ComputerName"
    Write-Log "Config: $($ConfigContext.ResolvedConfigPath)"
    Write-Log "Log mode: $($ConfigContext.LogMode)"

    # --------------------------------------------------------
    # STEP 1: Refresh local repository from upstream
    # --------------------------------------------------------
    if ($ConfigContext.UpstreamSource) {
        Write-Log "Refreshing local repository from: $($ConfigContext.UpstreamSource)"

        Sync-BrainSyncRepository `
            -SourceRepository $ConfigContext.UpstreamSource `
            -DestinationRoot $ConfigContext.LocalRepository `
            -NameSuffix " source"
    }
    else {
        Write-Log "No upstream source configured. Using local repository."
    }

    # --------------------------------------------------------
    # STEP 2: Discover and update operational tools
    # --------------------------------------------------------
    Write-Log "Discovering tools in local repository: $($ConfigContext.LocalRepository)"

    Sync-BrainSyncRepository `
        -SourceRepository $ConfigContext.LocalRepository `
        -DestinationRoot $ConfigContext.DestinationRoot

    # --------------------------------------------------------
    # Finish
    # --------------------------------------------------------
    if ($Script:HadErrors) {
        Complete-BrainSync -ExitCode 1
    }

    Complete-BrainSync -ExitCode 0
}
catch {
    Write-Log "Fatal error: $($_.Exception.Message)" "ERROR"
    Complete-BrainSync -ExitCode 1
}