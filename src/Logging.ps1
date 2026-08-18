# ------------------------------------------------------------
# BrainSync - Logging Module
# ------------------------------------------------------------

$Script:HadErrors = $false
$Script:RelevantActivity = $false
$Script:LogFile = $null
$Script:LogMode = "ChangesOnly"
$Script:LogBuffer = [System.Collections.Generic.List[string]]::new()

function Initialize-BrainSyncLogging {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LogDirectory,

        [Parameter(Mandatory = $true)]
        [string]$ComputerName,

        [ValidateSet("All", "ChangesOnly")]
        [string]$LogMode = "ChangesOnly"
    )

    if (-not (Test-Path -LiteralPath $LogDirectory -PathType Container)) {
        New-Item `
            -ItemType Directory `
            -Path $LogDirectory `
            -Force |
            Out-Null
    }

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
