# Remote System Operations

Collection of scripts for executing remote operations on Linux and Windows systems.

This repository contains utilities designed to support system administration, file deployment, remote command execution and infrastructure maintenance tasks.

## Included Tools

### Linux Remote Operations

Python script based on Fabric for managing remote Linux systems over SSH.

#### Main features

- Execute commands on multiple remote Linux systems
- Run operations in parallel
- Compare local and remote files
- Compare local and remote directories
- Copy files or directories to remote systems
- Skip potentially dangerous commands (such as shutdown, reboot, mkfs, dd and recursive destructive commands)
- Generate operation logs

#### Requirements

```
Python 3
Fabric
SSH access to remote Linux systems
```

#### Install requirements

```
pip install fabric
```

#### Example

```
python Lnx_remote_oper.py --exec commands.txt --user root
python Lnx_remote_oper.py --diff -L /etc/hosts -R /etc/hosts --user root
```

### Windows Remote Operations

PowerShell script used to copy or update files and directories from a local Windows machine to multiple remote Windows systems.

#### Main features

- Copy specific files
- Copy files using wildcard patterns
- Copy directories recursively
- Exclude specific files or folders
- Read target systems from an input file
- Generate operation logs

#### Use Cases

- Remote administration
- File deployment
- Configuration comparison
- Infrastructure operations
- Pre-monitoring and post-monitoring checks

#### Requirements

```
Windows PowerShell
Network access to remote Windows systems
Permissions to copy or update files on target systems
```

#### Example

```
.\WS_remote_oper.ps1
```

## Repository Structure

```text
Remote-System-Operations/
├── Linux/
│   └── Lnx_remote_oper.py
├── Windows/
│   └── WS_remote_oper.ps1
├── examples/
│   ├── remoteSystems.in
│   ├── commands.txt
│   └── objects_to_update.txt
└── README.md
