# ------------------------------------------------------------
# BrainSync - Logging Module
# ------------------------------------------------------------

$Script:HadErrors = $false
$Script:RelevantActivity = $false
$Script:LogFile = $null
$Script:LogMode = "ChangesOnly"
$Script:LogRetentionDays = 30
$Script:EnableEventLog = $true
$Script:LogDirectory = $null
$Script:TargetComputerName = $null
$Script:LogBuffer = [System.Collections.Generic.List[string]]::new()

function Initialize-BrainSyncLogging {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LogDirectory,

        [Parameter(Mandatory = $true)]
        [string]$ComputerName,

        [ValidateSet("All", "ChangesOnly")]
        [string]$LogMode = "ChangesOnly",

        [int]$LogRetentionDays = 30,

        [bool]$EnableEventLog = $true
    )

    if (-not (Test-Path -LiteralPath $LogDirectory -PathType Container)) {
        New-Item `
            -ItemType Directory `
            -Path $LogDirectory `
            -Force |
            Out-Null
    }

    $Script:LogDirectory = $LogDirectory
    $Script:TargetComputerName = $ComputerName
    $Script:LogRetentionDays = $LogRetentionDays
    $Script:EnableEventLog = $EnableEventLog

    $LogName = "BrainSync_$ComputerName.log"
    $Script:LogFile = Join-Path $LogDirectory $LogName
    $Script:LogMode = $LogMode
    $Script:LogBuffer.Clear()
    $Script:HadErrors = $false
    $Script:RelevantActivity = $false
}

function Set-BrainSyncLogMode {
    param(
        [ValidateSet("All", "ChangesOnly")]
        [string]$LogMode
    )

    $Script:LogMode = $LogMode
}

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

function Remove-OldBrainSyncLogs {
    param(
        [string]$LogDirectory = $Script:LogDirectory,
        [string]$ComputerName = $Script:TargetComputerName,
        [int]$RetentionDays = $Script:LogRetentionDays
    )

    if ([string]::IsNullOrWhiteSpace($LogDirectory) -or -not (Test-Path -LiteralPath $LogDirectory -PathType Container)) {
        return
    }

    if ($RetentionDays -le 0) {
        return
    }

    $CutoffDate = (Get-Date).AddDays(-$RetentionDays)

    try {
        $Filter = "BrainSync_*.log"
        if (-not [string]::IsNullOrWhiteSpace($ComputerName)) {
            $Filter = "BrainSync_$ComputerName*.log"
        }

        Get-ChildItem -LiteralPath $LogDirectory -Filter $Filter -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $CutoffDate } |
            ForEach-Object {
                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
            }
    }
    catch {
        # Silently continue on cleanup errors
    }
}

function Write-BrainSyncEventLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet("Information", "Warning", "Error")]
        [string]$EntryType = "Information",

        [int]$EventId = 100
    )

    if (-not $Script:EnableEventLog) {
        return
    }

    $Source = "BrainSync"
    $LogName = "Application"

    try {
        if (-not [System.Diagnostics.EventLog]::SourceExists($Source)) {
            try {
                [System.Diagnostics.EventLog]::CreateEventSource($Source, $LogName)
            }
            catch {
                $Source = "Application"
            }
        }

        [System.Diagnostics.EventLog]::WriteEntry($Source, $Message, [System.Diagnostics.EventLogEntryType]::$EntryType, $EventId)
    }
    catch {
        # Silently ignore event log write failures on non-privileged environments
    }
}
