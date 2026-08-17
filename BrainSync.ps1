param (
    [string]$ConfigFile,
    [string]$ComputerName = $env:COMPUTERNAME
)

$Script:HadErrors = $false
$Script:LogFile = $null


function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet("INFO", "WARNING", "ERROR")]
        [string]$Level = "INFO"
    )

    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $Line = "$Timestamp [$Level] $Message"

    Write-Host $Line

    if ($Script:LogFile) {
        Add-Content -LiteralPath $Script:LogFile -Value $Line
    }

    if ($Level -eq "ERROR") {
        $Script:HadErrors = $true
    }
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


function Update-VersionedFolder {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        Write-Log "Source folder not found: $Source" "ERROR"
        return
    }

    $SourceVersion = Get-ToolVersion -Path $Source

    if (-not $SourceVersion) {
        Write-Log "version.txt not found in source: $Source" "ERROR"
        return
    }

    $DestinationVersion = Get-ToolVersion -Path $Destination

    if ($SourceVersion -eq $DestinationVersion) {
        Write-Log "$Name is already version $SourceVersion"
        return
    }

    if ([string]::IsNullOrWhiteSpace($DestinationVersion)) {
        Write-Log "Installing $Name version $SourceVersion"
    }
    else {
        Write-Log "Updating $Name`: $DestinationVersion -> $SourceVersion"
    }

    $Backup = "$Destination.backup"

    Remove-Item `
        -LiteralPath $Backup `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue

    try {

        if (Test-Path -LiteralPath $Destination -PathType Container) {

            Rename-Item `
                -LiteralPath $Destination `
                -NewName $Backup `
                -ErrorAction Stop
        }

        Copy-Item `
            -LiteralPath $Source `
            -Destination $Destination `
            -Recurse `
            -Force `
            -ErrorAction Stop

        $InstalledVersion = Get-ToolVersion -Path $Destination

        if ($InstalledVersion -ne $SourceVersion) {
            throw "Installed version does not match source version."
        }

        Remove-Item `
            -LiteralPath $Backup `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue

        Write-Log "$Name updated successfully to $SourceVersion"
    }
    catch {

        Write-Log "Update failed for $Name`: $($_.Exception.Message)" "ERROR"

        Remove-Item `
            -LiteralPath $Destination `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue

        if (Test-Path -LiteralPath $Backup -PathType Container) {

            try {
                Rename-Item `
                    -LiteralPath $Backup `
                    -NewName $Destination `
                    -ErrorAction Stop

                Write-Log "Previous version of $Name restored."
            }
            catch {
                Write-Log "Failed to restore previous version of $Name`: $($_.Exception.Message)" "ERROR"
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
    throw "ConfigFile is required. Example: -ConfigFile .\configs\LAB.json"
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
# Resolve computer configuration
# ------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($ComputerName)) {
    throw "ComputerName could not be determined."
}

$ComputerName = $ComputerName.ToUpper()

$ComputerConfig = $config.Computers.$ComputerName

if (-not $ComputerConfig) {
    throw "No BrainSync configuration found for computer: $ComputerName"
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

$LogName = "BrainSync_{0}_{1}.log" -f `
    $ComputerName,
    (Get-Date -Format "yyyyMMdd_HHmmss")

$Script:LogFile = Join-Path $LogDirectory $LogName


Write-Log "BrainSync started - $ComputerName"
Write-Log "Config: $($ResolvedConfigPath.Path)"


# ------------------------------------------------------------
# Resolve paths
# ------------------------------------------------------------

try {

    $LocalSource = Resolve-ConfiguredPath `
        -PathValue $ComputerConfig.LocalSource `
        -BasePath $ConfigDirectory

    $LocalDestination = Resolve-ConfiguredPath `
        -PathValue $ComputerConfig.LocalDestination `
        -BasePath $ConfigDirectory
}
catch {

    Write-Log "Failed to resolve configured paths: $($_.Exception.Message)" "ERROR"
    exit 1
}


# ------------------------------------------------------------
# STEP 1
# Refresh local source from upstream when configured
# ------------------------------------------------------------

if ($ComputerConfig.UpstreamSource) {

    try {

        $UpstreamSource = Resolve-ConfiguredPath `
            -PathValue $ComputerConfig.UpstreamSource `
            -BasePath $ConfigDirectory

        Write-Log "Refreshing local source from: $UpstreamSource"

        foreach ($ToolName in $config.Tools) {

            $Source = Join-Path $UpstreamSource $ToolName
            $Destination = Join-Path $LocalSource $ToolName

            Update-VersionedFolder `
                -Name "$ToolName source" `
                -Source $Source `
                -Destination $Destination
        }
    }
    catch {

        Write-Log "Failed while refreshing local source: $($_.Exception.Message)" "ERROR"
    }
}
else {
    Write-Log "No upstream source configured. Using local source."
}


# ------------------------------------------------------------
# STEP 2
# Update operational tools from local source
# ------------------------------------------------------------

Write-Log "Updating local tools from: $LocalSource"

foreach ($ToolName in $config.Tools) {

    $Source = Join-Path $LocalSource $ToolName
    $Destination = Join-Path $LocalDestination $ToolName

    Update-VersionedFolder `
        -Name $ToolName `
        -Source $Source `
        -Destination $Destination
}


# ------------------------------------------------------------
# Finish
# ------------------------------------------------------------

if ($Script:HadErrors) {

    Write-Log "BrainSync completed with errors." "ERROR"
    exit 1
}

Write-Log "BrainSync completed successfully."
exit 0