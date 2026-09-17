# Remote System Operations

Utilities for performing operations across multiple remote Linux or Windows systems.

| Script | Target systems | Operations | Connection |
| --- | --- | --- | --- |
| [Lnx_remote_oper.py](Lnx_remote_oper.py) | Linux | Execute commands, upload files and directories, compare local and remote paths | SSH and SFTP through Fabric |
| [WS_remote_oper.ps1](WS_remote_oper.ps1) | Windows | Copy files and directories to the same path on remote systems | SMB through the `C$` administrative share |

Run the examples from this directory. Create the input files described below before running either script; they are not included in the project.

## Linux operations

### Requirements

- Python 3 and the `fabric` package on the local computer.
- SSH access to each remote Linux system, with SFTP available for uploads and comparisons.
- A remote account with permission to execute the requested commands and access the selected paths.

Install the Python dependency:

```sh
python -m pip install fabric
```

### System list

Create a file named `remoteSystems.in`, with one system per line:

```text
# hostname,connection_address
linux01,192.0.2.10
linux02,192.0.2.11
```

The first field labels the system in the output; the second is the address passed to Fabric. Both fields are required. Blank lines and lines beginning with `#` are ignored. Malformed rows are logged and skipped; a file with no valid systems is rejected.

Use `--systems` to select this file. The default location is `/tmp/remoteSystems.in`.

### Execute commands

Create a file, such as `commands.txt`:

```text
# One command per line
hostname
uptime
df -h
```

Run the commands on every listed system:

```sh
python Lnx_remote_oper.py --exec commands.txt --systems remoteSystems.in --user admin
```

The script prompts once for the SSH password and reuses the credentials across hosts. Hosts run concurrently, with five workers by default. Commands run in file order on each host, and subsequent commands are still attempted after a command fails or is skipped.

Each line is a separate remote command: shell state such as `cd` does not persist between lines. Put dependent operations on the same line, for example `cd /opt/app && ls`.

To use an SSH key or the SSH agent/configuration without the script's password prompt:

```sh
python Lnx_remote_oper.py --exec commands.txt --systems remoteSystems.in --user admin --key /home/operator/.ssh/id_ed25519
python Lnx_remote_oper.py --exec commands.txt --systems remoteSystems.in --user admin --no-password
```

`--key` and `--no-password` cannot be used together.

### Upload files and directories

Use the `COPY` pseudo-command in a command file:

```text
COPY "./config/app.conf" "/tmp/app.conf"
COPY "./config" "/tmp/app-config"
```

`COPY <local_path> <remote_path>` uploads through SFTP. A directory upload copies its contents recursively into the specified remote directory, creating directories as needed. A single-file upload requires the remote parent directory to exist. Existing destination files may be overwritten; extra remote files are not deleted.

Local relative paths are resolved from the directory where you launch the script. The parser uses POSIX shell quoting; when running on Windows, use quoted paths with forward slashes, such as `"C:/temp/app.conf"`.

### Compare paths

Compare a local file with its remote counterpart:

```sh
python Lnx_remote_oper.py --diff --local ./config/app.conf --remote /etc/app/app.conf --systems remoteSystems.in --user admin
```

Compare directories recursively:

```sh
python Lnx_remote_oper.py --diff -L ./config -R /etc/app --systems remoteSystems.in --user admin --parallel 3
```

Comparison reports identical files, entries found on only one side, and file-type differences. UTF-8 text differences are shown as unified diffs. Files containing NUL bytes or invalid UTF-8 are reported as binary when their contents differ.

Comparisons do not modify either path. They compare file contents and directory entries, not permissions, ownership, or timestamps. Remote directory scans do not follow symbolic links, and matching symlink entries are not compared by target. Files are read fully into memory.

**Detected differences do not cause a failure exit code.** A comparison succeeds when it completes, even if the paths differ; inaccessible or unreadable paths cause failures.

### Command-line options

| Option | Description | Default |
| --- | --- | --- |
| `--exec FILE` | Execute commands from a file; mutually exclusive with `--diff` | One mode is required |
| `--diff` | Compare local and remote paths; requires `--local` and `--remote` | One mode is required |
| `-L`, `--local` | Local path for comparison | None |
| `-R`, `--remote` | Remote path for comparison | None |
| `--user` | SSH username | Required |
| `--systems` | System list path | `/tmp/remoteSystems.in` |
| `--parallel` | Maximum concurrent host workers; positive integer | `5` |
| `--key` | SSH private key path; suppresses the password prompt | None |
| `--no-password` | Use SSH agent/configuration; suppresses the password prompt | Disabled |
| `--connect-timeout` | Connection timeout in seconds; positive integer | `10` |
| `--command-timeout` | Remote command timeout in seconds; positive integer | No explicit limit |
| `--allow-dangerous` | Disable the built-in destructive-command guard | Disabled |
| `-h`, `--help` | Show command-line help | |

Command files are trusted input. The script has a best-effort guard for selected destructive commands, including shutdown/reboot commands and certain disk or root-directory operations. It is not a complete shell-command validator. A blocked command is reported as `SKIPPED` and makes the run unsuccessful unless the guard is explicitly disabled with `--allow-dangerous`.

### Output and exit codes

Console output is grouped by host and includes command status, standard output, and standard error. Host blocks appear in completion order. Connection and operation events are appended to `remote_oper.log` in the current working directory.

| Exit code | Meaning |
| --- | --- |
| `0` | All host operations completed successfully; comparisons may still report differences |
| `1` | At least one host operation failed, a command returned a nonzero status, or a command was blocked |
| `2` | Argument or input-file validation error reported by the argument parser |

## Windows operations

### Requirements

- Windows with PowerShell and the `Test-NetConnection` cmdlet available.
- Network access to TCP port `445` on each target.
- The remote `C$` administrative share enabled and accessible with the supplied credentials.
- Local source files and directories on drive `C:`.

The Windows script copies content over SMB. It does not execute remote commands or require a WinRM session.

### System list

Create `C:\temp\system.txt`:

```text
# hostname,ip_address
windows01,192.0.2.20
windows02,192.0.2.21
```

The script first checks port `445` using the hostname. It tries the supplied IP address only if that check fails. An empty IP field is allowed (`windows01,`), but the hostname and comma are required. Blank lines and comment lines are ignored. Invalid rows count as failures, while valid hosts are still processed.

### Object list

Create `C:\temp\object.txt` containing the local paths to copy:

```text
# Copy one file
file:C:\temp\app.conf

# Copy matching files, excluding specific names
file:C:\temp\*.txt:notes.txt,private.txt

# Copy a directory recursively, excluding names at every level
dir:C:\temp\app:logs,backup

# Without a prefix, file mode is used
C:\temp\settings.ini
```

The syntax is `file:<local_path_or_pattern>[:excluded_name,...]` or `dir:<local_path_or_pattern>[:excluded_name,...]`.

- Wildcards are supported only in the final path component, not intermediate directories.
- Exclusions match exact file or directory names, case-insensitively; they are not wildcard patterns.
- Directory exclusions apply recursively and prevent excluded directories from being traversed.
- Blank lines and lines beginning with `#` are ignored.
- Paths containing spaces can be written directly in the object list, without surrounding quotes.

### Run the copy

Use the default configuration directory:

```powershell
.\WS_remote_oper.ps1
```

Or specify configuration and log paths:

```powershell
.\WS_remote_oper.ps1 -PathOper 'C:\operations'

.\WS_remote_oper.ps1 -SystemList 'C:\operations\hosts.txt' -ObjectList 'C:\operations\objects.txt' -LogPath 'C:\operations\copy.log'
```

The script requests credentials once with `Get-Credential`, then processes hosts sequentially. Each remote share is mapped to a temporary PSDrive, which the script attempts to remove after processing that host.

| Parameter | Description | Default |
| --- | --- | --- |
| `-PathOper` | Working directory and base for default input/log paths | `C:\temp` |
| `-SystemList` | System list file | `system.txt` under `-PathOper` |
| `-ObjectList` | Object specification file | `object.txt` under `-PathOper` |
| `-LogPath` | Log file | `log-yyyy-MM-dd_HH-mm-ss.log` under `-PathOper` |

### Copy behavior and results

The destination preserves the source's absolute path on every target. For example:

```text
C:\temp\app.conf -> \\windows01\C$\temp\app.conf
```

There is no separate destination-path option. Sources outside drive `C:` and unsupported source path formats are skipped. Missing destination directories are created, existing files are overwritten with `Copy-Item -Force`, and extra destination files are retained. This is a copy operation, not a content comparison or mirror synchronization.

During recursive traversal, child directories marked as reparse points, such as junctions and directory symlinks, are skipped. Per-directory, per-host, and overall summaries report copied files, skipped items, and failures. A source pattern matching no items counts as a failure; intentionally skipped items alone do not.

Status messages and copy details are written to the selected log. The script exits with `0` when no failures occurred and logging remained healthy, or `1` on failure, including credential cancellation and logging errors.

## Troubleshooting

| Problem | What to check |
| --- | --- |
| Python cannot import `fabric` | Install Fabric into the same Python environment used to run the script |
| Linux SSH connection fails | Check the connection address, SSH access, username, authentication, and `remote_oper.log` |
| Linux upload or comparison fails | Check local and remote paths, permissions, and SFTP availability; create the parent directory for single-file uploads |
| A Linux command is skipped | Inspect the command and the destructive-command guard message |
| Windows port `445` is unreachable | Check name resolution, routing, firewall rules, and SMB availability |
| Windows share mapping fails | Check access to `\\host\C$` and the supplied credentials |
| Windows source is skipped or missing | Check that it is on `C:`, matches the selected `file`/`dir` mode, and is not excluded |
| Log writing fails | Check that the log directory is writable and the file is accessible |
