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

Execute the commands listed in commands.txt on the remote Linux systems using the root user:

``` python
python Lnx_remote_oper.py --exec commands.txt --user root
```

Compare the local /etc/hosts file with the remote /etc/hosts file on the target Linux systems using the root user:

``` python
python Lnx_remote_oper.py --diff -L /etc/hosts -R /etc/hosts --user root
```

---

### Windows Remote Operations

## Description

PowerShell script to copy or update files and directories from a **local Windows client** to one or more **remote Windows servers** using **WinRM (Windows Remote Management)**, without relying on administrative shares (`C$`).

The script reads a list of target machines and a list of objects to transfer, opens a PSSession to each remote host, and copies files or directories preserving the same absolute path on the destination.

## Requirements

### On the SERVER (remote machine) — run as Administrator

Enable WinRM and PowerShell Remoting:

```powershell
# Enable WinRM with default settings
Enable-PSRemoting -Force

# Verify the WinRM service is running
Get-Service WinRM

# (Optional) Allow connections from all hosts — useful in Workgroup environments
Set-Item WSMan:\localhost\Client\TrustedHosts -Value "*" -Force

# (Optional) Verify WinRM configuration
winrm quickconfig
```

> **Domain (Active Directory) environments:** `Enable-PSRemoting -Force` is sufficient. No need to modify `TrustedHosts`.

> **Workgroup environments:** You must add the client to the server's `TrustedHosts` (see above) and vice versa.

Verify that the firewall allows WinRM traffic (port **5985** HTTP or **5986** HTTPS):

```powershell
# Check existing WinRM firewall rules (already added by Enable-PSRemoting)
Get-NetFirewallRule -DisplayName "*Windows Remote Management*"
```

### On the CLIENT (local machine) — run as Administrator

Make sure WinRM is active on the client side as well (required for `New-PSSession`):

```powershell
# Start the WinRM service and set it to start automatically
Start-Service WinRM
Set-Service WinRM -StartupType Automatic

# Add remote servers to TrustedHosts (required outside of a domain)
# Replace with your actual hostnames or IP addresses, or use "*" for all
Set-Item WSMan:\localhost\Client\TrustedHosts -Value "server01,192.168.1.10,server02,192.168.1.11" -Force

# Verify
Get-Item WSMan:\localhost\Client\TrustedHosts
```

## Configuration Files

Both configuration files must be placed in `C:\temp\`.

### `C:\temp\system.txt` — list of remote servers

Format: `<hostname>,<ip_address>`

```
server01,192.168.1.10
server02,192.168.1.11
# this line is ignored
server03,192.168.1.12
```

**Rules:**
- One entry per line
- Each entry must contain exactly two comma-separated fields: hostname and IP address
- Lines starting with `#` are treated as comments and skipped
- Blank lines are ignored

### `C:\temp\object.txt` — list of objects to copy

| Format | Description |
|---|---|
| `file:C:\temp\test.txt` | Copy a specific file |
| `file:C:\temp\test*` | Copy all files whose name starts with `test` |
| `file:C:\temp\*` | Copy all files in the specified directory |
| `file:C:\temp\*.txt:skip.txt,old.txt` | Copy all `.txt` files, excluding `skip.txt` and `old.txt` |
| `dir:C:\temp\mydir` | Copy an entire directory recursively |
| `dir:C:\temp\test*` | Copy all directories whose name starts with `test` recursively |
| `dir:C:\temp\*:old,backup` | Copy all directories, excluding those named `old` and `backup` |
| `C:\temp\test.txt` | Equivalent to `file:C:\temp\test.txt` |
| `#file:C:\temp\skip.txt` | Commented line — skipped |

> **Important:** The destination path on the remote server is **identical to the local source path**.  
> For example, `C:\temp\file.txt` on the client will be copied to `C:\temp\file.txt` on the server.  
> Make sure the destination directories exist or that the remote user has permission to create them.

## Running the Script

Open PowerShell as **Administrator** on the client and run:

```powershell
.\WS_remote_oper.ps1
```

During execution, a **credential prompt will appear for each server** in `system.txt`. This is by design — different credentials can be used for each target machine.

## Output and Logging

| Output | Details |
|---|---|
| **Console** | Color-coded messages: green = success, yellow = warning, red = error, cyan = info |
| **Log file** | `C:\temp\log-YYYY-MM-DD_HH-mm-ss.log` — created automatically on each run |

## Troubleshooting

| Problem | Solution |
|---|---|
| `WinRM is not reachable` | Run `Enable-PSRemoting -Force` on the server and confirm port 5985 is open in the firewall |
| `Access Denied` | Verify credentials and confirm the user belongs to the `Remote Management Users` or `Administrators` group on the server |
| `TrustedHosts` error | Add the server to `TrustedHosts` on the client (see CLIENT section above) |
| Credential prompt appears N times | Expected behavior — one prompt per server in `system.txt` |
| Slow file transfer | Normal for large files over WinRM; consider splitting transfers into smaller batches |
| Source path not found | Verify that the paths in `object.txt` exist on the local machine before running |

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
│   ├── object.txt
│   └── system.txt
└── README.md
