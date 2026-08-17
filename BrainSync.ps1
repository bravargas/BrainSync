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

$LogName = "BrainSync_$ComputerName.log"
$Script:LogFile = Join-Path $LogDirectory $LogName

Write-Log "------------------------------------------------------------"
Write-Log "BrainSync started - $ComputerName"
Write-Log "Config: $($ResolvedConfigPath.Path)"


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

    Write-Log "Failed to resolve LocalRepository: $($_.Exception.Message)" "ERROR"
    Write-Log "BrainSync completed with errors." "ERROR"
    Write-Log "------------------------------------------------------------"
    exit 1
}


# ------------------------------------------------------------
# Resolve optional DestinationRoot override
# ------------------------------------------------------------

$DestinationRoot = $null

if ($ComputerConfig.DestinationRoot) {

    try {

        $DestinationRoot = Resolve-ConfiguredPath `
            -PathValue $ComputerConfig.DestinationRoot `
            -BasePath $ConfigDirectory
    }
    catch {

        Write-Log "Failed to resolve DestinationRoot: $($_.Exception.Message)" "ERROR"
        Write-Log "BrainSync completed with errors." "ERROR"
        Write-Log "------------------------------------------------------------"
        exit 1
    }
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

        foreach ($Tool in $config.Tools) {

            $ToolName = $Tool.Name

            if ([string]::IsNullOrWhiteSpace($ToolName)) {
                Write-Log "Tool entry is missing Name." "ERROR"
                continue
            }

            $Source = Join-Path $UpstreamSource $ToolName
            $Destination = Join-Path $LocalRepository $ToolName

            Update-VersionedFolder `
                -Name "$ToolName source" `
                -Source $Source `
                -Destination $Destination
        }
    }
    catch {

        Write-Log "Failed while refreshing local repository: $($_.Exception.Message)" "ERROR"
    }
}
else {

    Write-Log "No upstream source configured. Using local repository."
}


# ------------------------------------------------------------
# STEP 2
# Update operational tools from local repository
# ------------------------------------------------------------

Write-Log "Updating local tools from: $LocalRepository"

foreach ($Tool in $config.Tools) {

    $ToolName = $Tool.Name

    if ([string]::IsNullOrWhiteSpace($ToolName)) {
        Write-Log "Tool entry is missing Name." "ERROR"
        continue
    }

    try {

        $Source = Join-Path $LocalRepository $ToolName

        if ($DestinationRoot) {

            $Destination = Join-Path $DestinationRoot $ToolName
        }
        else {

            if ([string]::IsNullOrWhiteSpace($Tool.Destination)) {
                Write-Log "Destination is missing for tool: $ToolName" "ERROR"
                continue
            }

            $Destination = Resolve-ConfiguredPath `
                -PathValue $Tool.Destination `
                -BasePath $ConfigDirectory
        }

        Update-VersionedFolder `
            -Name $ToolName `
            -Source $Source `
            -Destination $Destination
    }
    catch {

        Write-Log "Failed to process $ToolName`: $($_.Exception.Message)" "ERROR"
    }
}


# ------------------------------------------------------------
# Finish
# ------------------------------------------------------------

if ($Script:HadErrors) {

    Write-Log "BrainSync completed with errors." "ERROR"
    Write-Log "------------------------------------------------------------"
    exit 1
}

Write-Log "BrainSync completed successfully."
Write-Log "------------------------------------------------------------"
exit 0