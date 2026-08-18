# ------------------------------------------------------------
# BrainSync - Bootstrap Launcher with Self-Update Support
# ------------------------------------------------------------

param (
    [Parameter(Mandatory = $true)]
    [string]$ConfigFile,

    [string]$ComputerName = $env:COMPUTERNAME,

    [switch]$NoSelfUpdate
)

$ScriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path

# ------------------------------------------------------------
# Parameter Normalization & Path Resolution
# ------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($ConfigFile)) {
    throw "ConfigFile is required. Example: -ConfigFile .\configs\DEV.json"
}

if ([string]::IsNullOrWhiteSpace($ComputerName)) {
    throw "ComputerName could not be determined."
}

$ComputerName = $ComputerName.ToUpper()

try {
    $ResolvedConfig = Resolve-Path -LiteralPath $ConfigFile -ErrorAction Stop
}
catch {
    $RelativeConfig = Join-Path $ScriptDirectory $ConfigFile
    try {
        $ResolvedConfig = Resolve-Path -LiteralPath $RelativeConfig -ErrorAction Stop
    }
    catch {
        throw "Config file not found: $ConfigFile"
    }
}

$ResolvedConfigPath = $ResolvedConfig.Path
$ConfigDirectory = Split-Path -Parent $ResolvedConfigPath

# ------------------------------------------------------------
# Self-Update Pre-Flight Check
# ------------------------------------------------------------
if (-not $NoSelfUpdate) {
    try {
        $rawConfig = Get-Content -LiteralPath $ResolvedConfigPath -Raw -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop

        $ComputerConfig = $rawConfig.Computers.$ComputerName

        # Determine potential source for BrainSync package
        $SourceRepoCandidates = @()

        if ($ComputerConfig -and $ComputerConfig.UpstreamSource) {
            $SourceRepoCandidates += $ComputerConfig.UpstreamSource
        }
        if ($ComputerConfig -and $ComputerConfig.LocalRepository) {
            $SourceRepoCandidates += $ComputerConfig.LocalRepository
        }
        elseif ($rawConfig.LocalRepository) {
            $SourceRepoCandidates += $rawConfig.LocalRepository
        }

        foreach ($CandidateRepo in $SourceRepoCandidates) {
            $Expanded = [System.Environment]::ExpandEnvironmentVariables($CandidateRepo)
            if (-not [System.IO.Path]::IsPathRooted($Expanded)) {
                $Expanded = [System.IO.Path]::GetFullPath((Join-Path $ConfigDirectory $Expanded))
            }

            $BrainSyncSource = Join-Path $Expanded "BrainSync"
            $SourceVersionFile = Join-Path $BrainSyncSource "version.txt"

            if (Test-Path -LiteralPath $SourceVersionFile -PathType Leaf) {
                $SourceVersion = (Get-Content -LiteralPath $SourceVersionFile -Raw).Trim()

                $CurrentVersionFile = Join-Path $ScriptDirectory "version.txt"
                $CurrentVersion = ""
                if (Test-Path -LiteralPath $CurrentVersionFile -PathType Leaf) {
                    $CurrentVersion = (Get-Content -LiteralPath $CurrentVersionFile -Raw).Trim()
                }

                if (-not [string]::IsNullOrWhiteSpace($SourceVersion) -and $SourceVersion -ne $CurrentVersion) {
                    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                    $Msg = "$Timestamp [INFO] BrainSync Launcher: Self-update detected: $CurrentVersion -> $SourceVersion"
                    Write-Host $Msg

                    # Ensure log directory exists to record self-update
                    $LogDir = Join-Path $ScriptDirectory "logs"
                    if (-not (Test-Path -LiteralPath $LogDir -PathType Container)) {
                        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
                    }
                    $LogFile = Join-Path $LogDir "BrainSync_$ComputerName.log"
                    Add-Content -LiteralPath $LogFile -Value "$Timestamp [INFO] ------------------------------------------------------------"
                    Add-Content -LiteralPath $LogFile -Value $Msg

                    # Perform self-update copy
                    $RobocopyCmd = Get-Command "robocopy.exe" -ErrorAction SilentlyContinue
                    if ($RobocopyCmd) {
                        $RoboArgs = @(
                            $BrainSyncSource,
                            $ScriptDirectory,
                            "/E",
                            "/Z",
                            "/FFT",
                            "/R:3",
                            "/W:2",
                            "/XD", "logs", ".git",
                            "/XF", "version.txt", "*.log", "*.backup",
                            "/NP", "/NFL", "/NDL", "/NJH", "/NJS"
                        )
                        $proc = Start-Process -FilePath "robocopy.exe" -ArgumentList $RoboArgs -NoNewWindow -Wait -PassThru
                        if ($proc.ExitCode -ge 8) {
                            throw "Robocopy self-update failed with code $($proc.ExitCode)"
                        }
                    }
                    else {
                        Get-ChildItem -LiteralPath $BrainSyncSource -Force |
                            Where-Object { $_.Name -notin @("version.txt", "logs", ".git") } |
                            ForEach-Object {
                                Copy-Item -LiteralPath $_.FullName -Destination $ScriptDirectory -Recurse -Force
                            }
                    }

                    # Copy version.txt last as the release marker
                    Copy-Item -LiteralPath $SourceVersionFile -Destination $CurrentVersionFile -Force

                    $SuccessMsg = "$((Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) [INFO] BrainSync Launcher: Self-update completed successfully to $SourceVersion"
                    Write-Host $SuccessMsg
                    Add-Content -LiteralPath $LogFile -Value $SuccessMsg
                    break
                }
            }
        }
    }
    catch {
        $WarnMsg = "$((Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) [WARNING] BrainSync Launcher: Self-update check failed: $($_.Exception.Message)"
        Write-Host $WarnMsg
    }
}

# ------------------------------------------------------------
# Invoke Main BrainSync Engine
# ------------------------------------------------------------
$BrainSyncScript = Join-Path $ScriptDirectory "BrainSync.ps1"

if (-not (Test-Path -LiteralPath $BrainSyncScript -PathType Leaf)) {
    throw "BrainSync.ps1 not found at: $BrainSyncScript"
}

$ProcessArgs = @(
    "-NoProfile",
    "-NonInteractive",
    "-ExecutionPolicy", "Bypass",
    "-File", "`"$BrainSyncScript`"",
    "-ConfigFile", "`"$ResolvedConfigPath`"",
    "-ComputerName", "`"$ComputerName`""
)

$EngineProcess = Start-Process `
    -FilePath "powershell.exe" `
    -ArgumentList $ProcessArgs `
    -NoNewWindow `
    -Wait `
    -PassThru

exit $EngineProcess.ExitCode
