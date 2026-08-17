# Changelog

## Unreleased
- Fixed path resolution in [BrainSync.ps1](BrainSync.ps1) so configured paths are resolved relative to the config file location instead of the current working directory.
- Added validation for missing source folders and missing source `version.txt` files before attempting any copy or update.
- Added timestamped logging with a separate log file for each BrainSync run under the `logs` folder.
- Added exit codes to indicate successful (`0`) or failed (`1`) BrainSync executions.
- Added support for multiple environment configuration files, such as LAB, DEV, QA, and PROD.
- Added support for computer-specific configuration using the `ComputerName` parameter, defaulting to the local machine name.
- Added upstream synchronization, allowing each server to refresh its local repository from an accessible upstream server before updating its operational tools.
- Added a shared `LocalRepository` configuration to define the local software repository used by all tools in an environment.
- Added support for computer-specific `LocalRepository` overrides, primarily for local lab simulation.
- Changed tool configuration to support individual `Destination` paths instead of repeating a common destination configuration for every computer.
- Added optional computer-specific `DestinationRoot` overrides to simulate multiple servers on a single machine in the local lab.
- Added support for tiered synchronization, allowing software to propagate through WEB → APP → TP servers while each server updates its tools from its own local repository.
- Added safer versioned folder handling with backup/restore logic and explicit validation that the installed `version.txt` matches the source version.
- Improved restore behavior to preserve the previous version when an update fails during the copy operation.
- Added [Install-BrainSyncTask.ps1](Install-BrainSyncTask.ps1) to install BrainSync as a recurring Windows Scheduled Task using specified service account credentials.
- Configured the Scheduled Task installer to run BrainSync every minute by default, with a configurable interval.
- Excluded runtime logs from Git tracking.