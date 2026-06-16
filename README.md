# Remote System Operations

Collection of scripts for executing remote operations on Linux and Windows systems.

This repository contains utilities designed to support system administration, file deployment, remote command execution and infrastructure maintenance tasks.

## Included Tools

### Linux Remote Operations

Python script based on Fabric for managing remote Linux systems over SSH.

Main features:

- Execute commands on multiple remote Linux systems
- Run operations in parallel
- Compare local and remote files
- Compare local and remote directories
- Copy files or directories to remote systems
- Skip potentially dangerous commands
- Generate operation logs

### Windows Remote Operations

PowerShell script used to copy or update files and directories from a local Windows machine to multiple remote Windows systems.

Main features:

- Copy specific files
- Copy files using wildcard patterns
- Copy directories recursively
- Exclude specific files or folders
- Read target systems from an input file
- Generate operation logs

## Repository Structure

```text
Remote-System-Operations/
├── linux/
│   └── Lnx_remote_oper.py
├── windows/
│   └── WS_remote_oper.ps1
├── examples/
│   ├── remoteSystems.in
│   ├── commands.txt
│   └── objects_to_update.txt
└── README.md
