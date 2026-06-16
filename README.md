# Remote-System-Operations

Collection of scripts for executing remote operations on Linux and Windows systems.

## Purpose

This repository provides utilities designed to simplify remote administration and operational tasks across Linux and Windows environments.

The included tools focus on automation, file deployment, command execution and infrastructure maintenance.

---

### Linux Remote Operations

Python script based on Fabric for managing remote Linux systems over SSH.

#### Main features

- Execute commands on multiple remote Linux systems
- Run operations in parallel
- Compare local and remote files
- Compare local and remote directories
- Copy files or directories to remote systems
- Skip potentially dangerous commands (such as `shutdown, reboot, mkfs, dd and recursive destructive commands`)
- Generate operation logs

#### Requirements

- Python 3
- Fabric
- SSH access to remote Linux systems

#### Install requirements

``` python
pip install fabric
```

## Configuration Files

### Linux target systems file

File used by `Lnx_remote_oper.py` to identify the remote Linux systems.

Example: `examples/remoteSystems.in`

``` text
server01,192.168.1.10
server02,192.168.1.11
```

### Linux command file

File used to define the commands executed on remote Linux systems.

Example: `examples/commands.txt`

``` test
# Check service status
systemctl status apache2

# Copy a local script to the remote system
COPY /local/script.sh /tmp/script.sh

# Execute the copied script
chmod +x /tmp/script.sh
/tmp/script.sh
```

#### Example

``` python
python Lnx_remote_oper.py --exec commands.txt --user root
python Lnx_remote_oper.py --diff -L /etc/hosts -R /etc/hosts --user root
```

---

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

- Windows PowerShell
- Network access to remote Windows systems
- Permissions to copy or update files on target systems

## Configuration Files

### Windows objects file

File used by WS_remote_oper.ps1 to define files or directories to copy/update.

Example: `examples/objects_to_update.txt`

``` text
file:C:\temp\prova
file:\local\config.ini;C$\App\config.ini
C:\local\folder;C$\Temp\folder
```

#### Example

``` powershell
.\WS_remote_oper.ps1
```

## Repository Structure

``` text
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
