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
        if ($Script:RelevantActivity) {
            Write-BrainSyncEventLog `
                -Message "BrainSync completed successfully on $ComputerName with packages updated or installed." `
                -EntryType "Information" `
                -EventId 100
        }
    }
    else {
        Write-Log "BrainSync completed with errors." "ERROR"
        Write-BrainSyncEventLog `
            -Message "BrainSync completed with errors on $ComputerName. Check log file for details." `
            -EntryType "Error" `
            -EventId 101
    }

    Write-Log "------------------------------------------------------------"

    Save-Log
    Remove-OldBrainSyncLogs
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
    # Initialize default logging
    $LogDirectory = Join-Path $ScriptDirectory "logs"
    Initialize-BrainSyncLogging `
        -LogDirectory $LogDirectory `
        -ComputerName $ComputerName

    # Load and validate environment/computer configuration
    $ConfigContext = Get-BrainSyncConfig `
        -ConfigFile $ConfigFile `
        -ComputerName $ComputerName `
        -ScriptDirectory $ScriptDirectory

    # Apply configuration options to logging
    Initialize-BrainSyncLogging `
        -LogDirectory $LogDirectory `
        -ComputerName $ComputerName `
        -LogMode $ConfigContext.LogMode `
        -LogRetentionDays $ConfigContext.LogRetentionDays `
        -EnableEventLog $ConfigContext.EnableEventLog

    Write-Log "------------------------------------------------------------"
    Write-Log "BrainSync started - $ComputerName"
    Write-Log "Config: $($ConfigContext.ResolvedConfigPath)"
    Write-Log "Log mode: $($ConfigContext.LogMode)"
    Write-Log "Robocopy enabled: $($ConfigContext.UseRobocopy)"
    Write-Log "Log retention: $($ConfigContext.LogRetentionDays) days"

    # --------------------------------------------------------
    # STEP 1: Refresh local repository from upstream
    # --------------------------------------------------------
    if ($ConfigContext.UpstreamSource) {
        Write-Log "Refreshing local repository from: $($ConfigContext.UpstreamSource)"

        Sync-BrainSyncRepository `
            -SourceRepository $ConfigContext.UpstreamSource `
            -DestinationRoot $ConfigContext.LocalRepository `
            -NameSuffix " source" `
            -UseRobocopy $ConfigContext.UseRobocopy
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
        -DestinationRoot $ConfigContext.DestinationRoot `
        -UseRobocopy $ConfigContext.UseRobocopy

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