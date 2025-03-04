# DSYNC - Drive Sync Automation Tool

DSYNC is a Bash script that automates the synchronization of data between a master drive and multiple backup drives. It provides a simple interface for managing drive associations and performing reliable data backups.

## Features

- **Drive Association**: Easily designate drives as master or backup
- **Multiple Backup Support**: Sync one master to multiple backup drives
- **Space Verification**: Checks available space before syncing
- **Intelligent Exclusions**: Automatically skips system directories and temporary files
- **Progress Tracking**: Shows real-time sync progress
- **Safe Operations**: Confirms actions before making changes

## Prerequisites

- Linux-based operating system
- `rsync` installed
- `bc` for calculations
- `uuidgen` for generating unique IDs

### Main Menu Options

1. **Sync Drives**: Start synchronization between master and backup drives
2. **Associate Drives**: Set up master and backup drive relationships
3. **Exit**: Close the application

### Drive Association Process

1. Select "Associate Drives" from the main menu
2. Use arrow keys to navigate through available drives
3. Press 'd' to toggle drive state (unassigned → master → backup)
4. Press Enter to confirm selections
5. Review and confirm changes

### Sync Process

1. Select "Sync Drives" from the main menu
2. Review space requirements for each backup
3. Confirm to proceed with sync
4. Review summary of changes
5. Confirm to start sync operations
6. Monitor progress until completion

## Excluded Items

The following items are automatically excluded from syncs:
- `.dsync` (configuration file)
- `.Trash*` (trash directories)
- `.trash*` (trash directories)
- `lost+found` (system directory)

## Configuration

DSYNC uses a `.dsync` file in the root of each drive to maintain sync relationships. This file contains:
- SET_ID: Unique identifier for sync group
- ROLE: Drive role (master/backup)
- TIMESTAMP: Last modification time

## Error Handling

- Checks for proper drive mounting
- Verifies sufficient space on backup drives
- Validates drive associations
- Handles permission errors gracefully

## Logging

Operations are logged with timestamps and severity levels:
- INFO: Normal operations
- WARNING: Non-critical issues
- ERROR: Critical problems
