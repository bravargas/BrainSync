param (
    [Parameter(Mandatory = $true)]
    [string]$ConfigFile,

    [ValidateRange(1, 1440)]
    [int]$IntervalMinutes = 1,

    [string]$TaskName = "BrainSync"
)

$ScriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$BrainSyncScript = Join-Path $ScriptDirectory "BrainSync.ps1"

if (-not (Test-Path -LiteralPath $BrainSyncScript -PathType Leaf)) {
    throw "BrainSync.ps1 not found: $BrainSyncScript"
}

# Resolve config file
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

$ConfigPath = $ResolvedConfig.Path

$Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$BrainSyncScript`" -ConfigFile `"$ConfigPath`""

$Action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument $Arguments `
    -WorkingDirectory $ScriptDirectory

$Trigger = New-ScheduledTaskTrigger `
    -Once `
    -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)

$Settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $Action `
    -Trigger $Trigger `
    -Settings $Settings `
    -User "SYSTEM" `
    -RunLevel Highest `
    -Force | Out-Null

Write-Host ""
Write-Host "Scheduled Task created successfully."
Write-Host "Task:     $TaskName"
Write-Host "Account:  SYSTEM"
Write-Host "Config:   $ConfigPath"
Write-Host "Interval: every $IntervalMinutes minute(s)"