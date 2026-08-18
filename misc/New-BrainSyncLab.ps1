$Lab = "D:\BrainSyncLab"

if (Test-Path -LiteralPath $Lab) {
    Remove-Item -LiteralPath $Lab -Recurse -Force
}

$Folders = @(
    "$Lab\WEB\source\Braintools",
    "$Lab\WEB\source\BrainPad",
    "$Lab\WEB\source\BrainTrace",
    "$Lab\WEB\source\BrainSync",

    "$Lab\WEB\tools",

    "$Lab\APP\source",
    "$Lab\APP\tools",

    "$Lab\TP\source",
    "$Lab\TP\tools"
)

foreach ($Folder in $Folders) {
    New-Item -ItemType Directory -Path $Folder -Force | Out-Null
}


# ------------------------------------------------------------
# Master WEB repository
# ------------------------------------------------------------

"20260817-210001" |
    Set-Content "$Lab\WEB\source\Braintools\version.txt"

"20260817-210002" |
    Set-Content "$Lab\WEB\source\BrainPad\version.txt"

"20260817-210003" |
    Set-Content "$Lab\WEB\source\BrainTrace\version.txt"

"20260818-100000" |
    Set-Content "$Lab\WEB\source\BrainSync\version.txt"


# ------------------------------------------------------------
# Fake package content
# ------------------------------------------------------------

"'Braintools LAB package'" |
    Set-Content "$Lab\WEB\source\Braintools\Braintools.ps1"

"'BrainPad LAB package'" |
    Set-Content "$Lab\WEB\source\BrainPad\BrainPad.ps1"

"'BrainTrace LAB package'" |
    Set-Content "$Lab\WEB\source\BrainTrace\BrainTrace.ps1"

# Copy real BrainSync files for authentic engine package
$WorkspaceRoot = Split-Path -Parent $PSScriptRoot
Copy-Item "$WorkspaceRoot\BrainSync.ps1" "$Lab\WEB\source\BrainSync\BrainSync.ps1" -Force
Copy-Item "$WorkspaceRoot\src" "$Lab\WEB\source\BrainSync\src" -Recurse -Force
Copy-Item "$WorkspaceRoot\configs" "$Lab\WEB\source\BrainSync\configs" -Recurse -Force


# Additional files/folders to verify recursive copying
New-Item `
    -ItemType Directory `
    -Path "$Lab\WEB\source\Braintools\modules" `
    -Force |
    Out-Null

"'Fake module'" |
    Set-Content "$Lab\WEB\source\Braintools\modules\TestModule.psm1"


Write-Host ""
Write-Host "BrainSync lab created:"
Write-Host $Lab
Write-Host ""
Write-Host "Discovered packages will be:"
Write-Host "  Braintools"
Write-Host "  BrainPad"
Write-Host "  BrainTrace"
Write-Host "  BrainSync"