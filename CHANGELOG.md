# Changelog

## Unreleased
- Fixed path resolution in [BrainSync.ps1](BrainSync.ps1) so configured paths are resolved relative to the config file location instead of the current working directory.
- Added validation for missing source folders, missing source `version.txt` files, and empty version markers before attempting an update.
- Added timestamped incremental logging with one log file per computer under the `logs` folder.
- Added exit codes to indicate successful (`0`) or failed (`1`) BrainSync executions.
- Added support for multiple environment configuration files such as LAB, DEV, QA, and PROD.
- Added support for computer-specific configuration using the `ComputerName` parameter, defaulting to the local machine name.
- Added upstream synchronization so each server can refresh its local repository from an accessible upstream server before updating its operational tools.
- Added a shared `LocalRepository` configuration that defines the local package repository used by BrainSync.
- Added support for computer-specific `LocalRepository` overrides for local lab simulation.
- Added a shared `DestinationRoot` configuration that defines where operational tools are installed.
- Added support for computer-specific `DestinationRoot` overrides for local lab simulation.
- Removed the explicit `Tools` list from environment configuration.
- Added automatic package discovery: any direct subfolder of the repository containing a `version.txt` file is treated as a BrainSync-managed package.
- Added automatic propagation of newly published packages without requiring configuration changes.
- Added support for tiered synchronization, allowing packages to propagate through WEB → APP → TP servers while each server installs tools from its own local repository.
- Added safer versioned folder handling with backup and rollback support.
- Changed package copy behavior so `version.txt` is always copied last and acts as the completed-release marker.
- Added validation that the installed `version.txt` matches the source release after a successful copy.
- Added protection against configurations where source and destination resolve to the same path.
- Improved restore behavior to preserve the previous version when an update fails during the copy operation.
- Added [Install-BrainSyncTask.ps1](Install-BrainSyncTask.ps1) to install BrainSync as a recurring Windows Scheduled Task.
- Configured the Scheduled Task installer to run BrainSync every minute by default, with a configurable interval.
- Added support for running the BrainSync Scheduled Task under the local SYSTEM account without storing service account credentials.
- Excluded runtime logs from Git tracking.