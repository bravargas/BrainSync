# ------------------------------------------------------------
# BrainSync - Configuration Module
# ------------------------------------------------------------

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

function Get-BrainSyncConfig {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigFile,

        [Parameter(Mandatory = $true)]
        [string]$ComputerName,

        [Parameter(Mandatory = $true)]
        [string]$ScriptDirectory
    )

    if ([string]::IsNullOrWhiteSpace($ConfigFile)) {
        throw "ConfigFile is required. Example: -ConfigFile .\configs\DEV.json"
    }

    if ([string]::IsNullOrWhiteSpace($ComputerName)) {
        throw "ComputerName could not be determined."
    }

    $NormalizedComputerName = $ComputerName.ToUpper()

    # --------------------------------------------------------
    # Resolve config file path
    # --------------------------------------------------------
    try {
        $ResolvedConfig = Resolve-Path `
            -LiteralPath $ConfigFile `
            -ErrorAction Stop
    }
    catch {
        $RelativeConfigPath = Join-Path $ScriptDirectory $ConfigFile

        try {
            $ResolvedConfig = Resolve-Path `
                -LiteralPath $RelativeConfigPath `
                -ErrorAction Stop
        }
        catch {
            throw "Config file not found: $ConfigFile"
        }
    }

    $ResolvedConfigPath = $ResolvedConfig.Path
    $ConfigDirectory = Split-Path -Parent $ResolvedConfigPath

    # --------------------------------------------------------
    # Load and parse JSON
    # --------------------------------------------------------
    try {
        $rawConfig = Get-Content `
            -LiteralPath $ResolvedConfigPath `
            -Raw `
            -ErrorAction Stop |
            ConvertFrom-Json `
            -ErrorAction Stop
    }
    catch {
        throw "Failed to load config file: $($_.Exception.Message)"
    }

    # --------------------------------------------------------
    # Validate LogMode
    # --------------------------------------------------------
    $LogMode = "ChangesOnly"
    if ($rawConfig.LogMode) {
        if ($rawConfig.LogMode -notin @("All", "ChangesOnly")) {
            throw "Invalid LogMode '$($rawConfig.LogMode)'. Valid values: All, ChangesOnly."
        }
        $LogMode = $rawConfig.LogMode
    }

    # --------------------------------------------------------
    # Validate Computer Configuration
    # --------------------------------------------------------
    $ComputerConfig = $rawConfig.Computers.$NormalizedComputerName
    if ($null -eq $ComputerConfig) {
        throw "No BrainSync configuration found for computer: $NormalizedComputerName"
    }

    # --------------------------------------------------------
    # Resolve LocalRepository
    # --------------------------------------------------------
    $LocalRepositoryValue = $rawConfig.LocalRepository
    if ($ComputerConfig.LocalRepository) {
        $LocalRepositoryValue = $ComputerConfig.LocalRepository
    }

    if ([string]::IsNullOrWhiteSpace($LocalRepositoryValue)) {
        throw "LocalRepository is not defined for computer '$NormalizedComputerName' or in global config."
    }

    $LocalRepository = Resolve-ConfiguredPath `
        -PathValue $LocalRepositoryValue `
        -BasePath $ConfigDirectory

    # --------------------------------------------------------
    # Resolve DestinationRoot
    # --------------------------------------------------------
    $DestinationRootValue = $rawConfig.DestinationRoot
    if ($ComputerConfig.DestinationRoot) {
        $DestinationRootValue = $ComputerConfig.DestinationRoot
    }

    if ([string]::IsNullOrWhiteSpace($DestinationRootValue)) {
        throw "DestinationRoot is not defined for computer '$NormalizedComputerName' or in global config."
    }

    $DestinationRoot = Resolve-ConfiguredPath `
        -PathValue $DestinationRootValue `
        -BasePath $ConfigDirectory

    # --------------------------------------------------------
    # Resolve UpstreamSource (optional)
    # --------------------------------------------------------
    $UpstreamSource = $null
    if ($ComputerConfig.UpstreamSource) {
        $UpstreamSource = Resolve-ConfiguredPath `
            -PathValue $ComputerConfig.UpstreamSource `
            -BasePath $ConfigDirectory
    }

    return [PSCustomObject]@{
        ResolvedConfigPath = $ResolvedConfigPath
        ConfigDirectory    = $ConfigDirectory
        LogMode            = $LogMode
        ComputerName       = $NormalizedComputerName
        ComputerConfig     = $ComputerConfig
        LocalRepository    = $LocalRepository
        DestinationRoot    = $DestinationRoot
        UpstreamSource     = $UpstreamSource
        RawConfig          = $rawConfig
    }
}
