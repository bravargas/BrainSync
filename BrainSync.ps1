param (
    [string]$ConfigFile = ".\BrainSync.json"
)

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

    $expandedPath = [System.Environment]::ExpandEnvironmentVariables($PathValue)

    if ([System.IO.Path]::IsPathRooted($expandedPath)) {
        return $expandedPath
    }

    return [System.IO.Path]::GetFullPath(
        (Join-Path $BasePath $expandedPath)
    )
}


# Resolve script directory
$ScriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path


# Resolve config file
$ResolvedConfigPath = $null

try {
    $ResolvedConfigPath = Resolve-Path -LiteralPath $ConfigFile -ErrorAction Stop
}
catch {

    $RelativeConfigPath = Join-Path $ScriptDirectory $ConfigFile

    try {
        $ResolvedConfigPath = Resolve-Path -LiteralPath $RelativeConfigPath -ErrorAction Stop
    }
    catch {
        throw "Config file not found: $ConfigFile"
    }
}


# Load config
$config = Get-Content -LiteralPath $ResolvedConfigPath.Path -Raw |
    ConvertFrom-Json

$configDirectory = Split-Path -Parent $ResolvedConfigPath.Path


# Process configured tools
foreach ($Tool in $config.Tools) {

    $Source = Resolve-ConfiguredPath `
        -PathValue $Tool.Source `
        -BasePath $configDirectory

    $Destination = Resolve-ConfiguredPath `
        -PathValue $Tool.Destination `
        -BasePath $configDirectory

    $Backup = "$Destination.backup"

    Write-Host ""
    Write-Host "Checking $($Tool.Name)..."

    # Validate source folder
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        Write-Warning "Source folder not found: $Source"
        continue
    }

    $SourceVersionFile = Join-Path $Source "version.txt"
    $LocalVersionFile  = Join-Path $Destination "version.txt"

    # Validate source version file
    if (-not (Test-Path -LiteralPath $SourceVersionFile -PathType Leaf)) {
        Write-Warning "Source version.txt not found: $SourceVersionFile"
        continue
    }

    $SourceVersion = (
        Get-Content -LiteralPath $SourceVersionFile -Raw
    ).Trim()

    # Read local version
    if (Test-Path -LiteralPath $LocalVersionFile -PathType Leaf) {

        $LocalVersion = (
            Get-Content -LiteralPath $LocalVersionFile -Raw
        ).Trim()
    }
    else {
        $LocalVersion = ""
    }

    # Nothing to do
    if ($SourceVersion -eq $LocalVersion) {
        Write-Host "$($Tool.Name) is already version $SourceVersion"
        continue
    }

    Write-Host "Updating $($Tool.Name): $LocalVersion -> $SourceVersion"

    # Remove previous temporary backup if present
    Remove-Item `
        -LiteralPath $Backup `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue

    try {

        # Backup current installation
        if (Test-Path -LiteralPath $Destination -PathType Container) {

            Rename-Item `
                -LiteralPath $Destination `
                -NewName $Backup `
                -ErrorAction Stop
        }

        # Copy new version
        Copy-Item `
            -LiteralPath $Source `
            -Destination $Destination `
            -Recurse `
            -Force `
            -ErrorAction Stop

        # Validate copied version file
        if (-not (
            Test-Path `
                -LiteralPath $LocalVersionFile `
                -PathType Leaf
        )) {
            throw "version.txt was not found after copy."
        }

        $InstalledVersion = (
            Get-Content `
                -LiteralPath $LocalVersionFile `
                -Raw
        ).Trim()

        if ($InstalledVersion -ne $SourceVersion) {
            throw "Installed version does not match source version."
        }

        # Update successful, remove backup
        Remove-Item `
            -LiteralPath $Backup `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue

        Write-Host "$($Tool.Name) updated successfully to $SourceVersion"
    }
    catch {

        Write-Warning "Update failed for $($Tool.Name): $($_.Exception.Message)"

        # Remove failed destination
        Remove-Item `
            -LiteralPath $Destination `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue

        # Restore previous version
        if (Test-Path -LiteralPath $Backup -PathType Container) {

            Rename-Item `
                -LiteralPath $Backup `
                -NewName $Destination `
                -ErrorAction SilentlyContinue

            Write-Host "Previous version restored."
        }
    }
}