#!/usr/bin/env python3

"""
Remote System Manager - Execute commands and compare files/directories on remote systems
Using Fabric library for simplified SSH operations
"""

import argparse, sys, os, logging, getpass, difflib
from concurrent.futures import ThreadPoolExecutor, as_completed
from fabric import Connection, Config
from invoke import UnexpectedExit

class RemoteSystem:
    """Manages connection to a remote system using Fabric"""

    def __init__(self, hostname, ip, user, password):
        self.hostname = hostname
        self.ip = ip
        self.user = user
        self.password = password
        self.connection = None

    def connect(self):
        """Establish SSH connection"""
        try:
            logger.info(f"Connecting to {self.hostname} ({self.ip}) as user '{self.user}'...")

            connect_kwargs = {'password': self.password}
            config = Config(overrides={'run': {'warn': True}})

            self.connection = Connection(
                host=self.ip,
                user=self.user,
                connect_kwargs=connect_kwargs,
                config=config
            )

            # Test connection
            self.connection.run('echo "Connection test"', hide=True)

            logger.info(f"Successfully connected to {self.hostname}")
            return True

        except Exception as e:
            logger.error(f"Failed to connect to {self.hostname}: {str(e)}")
            return False

    def disconnect(self):
        """Close SSH connection"""
        if self.connection:
            self.connection.close()
            logger.info(f"Disconnected from {self.hostname}")

    def execute_command(self, command):
        """Execute command on remote system"""
        try:
            logger.info(f"[{self.hostname}] Executing: {command}")
            result = self.connection.run(command, hide=False, warn=True)

            if result.ok:
                logger.info(f"[{self.hostname}] Command successful")
            else:
                logger.warning(f"[{self.hostname}] Command failed with exit code {result.return_code}")

            return result.return_code, result.stdout, result.stderr

        except UnexpectedExit as e:
            logger.error(f"[{self.hostname}] Command failed: {str(e)}")
            return e.result.return_code, e.result.stdout, e.result.stderr
        except Exception as e:
            logger.error(f"[{self.hostname}] Error executing command: {str(e)}")
            return -1, "", str(e)

    def remote_exists(self, path):
        """Check if remote path exists"""
        try:
            result = self.connection.run(f'test -e "{path}"', hide=True, warn=True)
            return result.ok
        except:
            return False

    def is_remote_dir(self, path):
        """Check if remote path is a directory"""
        try:
            result = self.connection.run(f'test -d "{path}"', hide=True, warn=True)
            return result.ok
        except:
            return False

    def read_remote_file(self, remote_path):
        """Read remote file content"""
        try:
            result = self.connection.run(f'cat "{remote_path}"', hide=True, warn=True)
            if result.ok:
                return result.stdout
            else:
                logger.error(f"[{self.hostname}] Cannot read {remote_path}")
                return None
        except Exception as e:
            logger.error(f"[{self.hostname}] Cannot read {remote_path}: {str(e)}")
            return None

    def list_remote_dir(self, remote_path):
        """List remote directory contents"""
        try:
            result = self.connection.run(f'ls -1 "{remote_path}"', hide=True, warn=True)
            if result.ok:
                return [item for item in result.stdout.strip().split('\n') if item]
            else:
                logger.error(f"[{self.hostname}] Cannot list directory {remote_path}")
                return []
        except Exception as e:
            logger.error(f"[{self.hostname}] Cannot list directory {remote_path}: {str(e)}")
            return []

    def copy_to_remote(self, local_path, remote_path):
        """Copy local file/directory to remote system"""
        try:
            if os.path.isfile(local_path):
                logger.info(f"[{self.hostname}] Copying {local_path} to {remote_path}")
                self.connection.put(local_path, remote=remote_path)
                logger.info(f"[{self.hostname}] File copied successfully")
                return True

            elif os.path.isdir(local_path):
                logger.info(f"[{self.hostname}] Copying directory {local_path} to {remote_path}")
                # Create remote directory
                self.connection.run(f'mkdir -p "{remote_path}"', hide=True, warn=True)

                # Copy all files recursively
                for root, dirs, files in os.walk(local_path):
                    # Calculate relative path
                    rel_path = os.path.relpath(root, local_path)
                    if rel_path == '.':
                        remote_dir = remote_path
                    else:
                        remote_dir = os.path.join(remote_path, rel_path).replace('\\', '/')

                    # Create directories
                    for dir_name in dirs:
                        remote_subdir = os.path.join(remote_dir, dir_name).replace('\\', '/')
                        self.connection.run(f'mkdir -p "{remote_subdir}"', hide=True, warn=True)

                    # Copy files
                    for file_name in files:
                        local_file = os.path.join(root, file_name)
                        remote_file = os.path.join(remote_dir, file_name).replace('\\', '/')
                        self.connection.put(local_file, remote=remote_file)

                logger.info(f"[{self.hostname}] Directory copied successfully")
                return True
            else:
                logger.error(f"[{self.hostname}] Local path does not exist: {local_path}")
                return False

        except Exception as e:
            logger.error(f"[{self.hostname}] Error copying to remote: {str(e)}")
            return False


def print_usage():
    """Print usage information"""
    usage = """
Remote System Manager - Usage Guide (Fabric Version)
=====================================================

BASIC USAGE:
    python remote_manager.py [OPTIONS]

OPTIONS:
    --diff                  Enable diff mode to compare local and remote files/directories
    -L, --local <path>      Local file or directory path (used with --diff)
    -R, --remote <path>     Remote file or directory path (used with --diff)
    --user <username>       SSH username (required)
    --exec <file>           Execute commands from specified file on remote systems
    --systems <file>        Path to remote systems file (default: /tmp/remoteSystems.in)
    --parallel <n>          Number of parallel connections (default: 5)
    -h, --help             Show this help message

REMOTE SYSTEMS FILE FORMAT:
    File: /tmp/remoteSystems.in (or specified with --systems)
    Format: hostname,ip_address

    Example:
        server1,192.168.1.10
        server2,192.168.1.11
        webserver,10.0.0.5

EXAMPLES:

1. Compare local and remote files:
    python remote_manager.py --diff -L /etc/hosts -R /etc/hosts --user myuser

2. Compare directories:
    python remote_manager.py --diff -L /local/scripts -R /remote/scripts --user root

3. Execute commands from file:
    python remote_manager.py --exec commands.txt --user admin

4. Execute with more parallel connections:
    python remote_manager.py --exec commands.txt --user root --parallel 10

COMMAND FILE FORMAT (for --exec):
    - One command per line
    - Lines starting with # are comments
    - Special command: COPY <local_path> <remote_path>

    Example commands.txt:
        # System updates
        systemctl status apache2
        COPY /local/script.sh /tmp/script.sh
        chmod +x /tmp/script.sh
        /tmp/script.sh

DANGEROUS COMMANDS:
    The script will automatically skip dangerous commands like:
    - rm -rf /
    - shutdown, reboot, halt
    - mkfs, dd
    - chmod -R 777 /

NOTES:
    - Logs are saved to remote_oper.log
    - Password will be prompted (not stored in command line)
    - Use --parallel to control concurrent connections (default: 5)
    - Binary files in diff mode will be skipped
    - Fabric library provides simplified SSH operations

INSTALLATION:
    pip install fabric
"""
    print(usage)
    sys.exit(0)


def is_dangerous_command(command):
    """Check if command is potentially dangerous"""
    cmd_lower = command.lower().strip()
    
    for dangerous in DANGEROUS_COMMANDS:
        if dangerous in cmd_lower:
            return True
            
    return False


def compare_files(local_path, remote_system, remote_path):
    """Compare local and remote files/directories"""
    logger.info(f"Comparing local '{local_path}' with remote '{remote_path}' on {remote_system.hostname}")

    # Check local existence
    local_exists = os.path.exists(local_path)
    remote_exists = remote_system.remote_exists(remote_path)

    if not local_exists and not remote_exists:
        print(f"\n[{remote_system.hostname}] Both local and remote paths do not exist")
        return

    if not local_exists:
        print(f"\n[{remote_system.hostname}] Local path '{local_path}' does not exist")
        print(f"Remote path '{remote_path}' exists")
        return

    if not remote_exists:
        print(f"\n[{remote_system.hostname}] Remote path '{remote_path}' does not exist")
        print(f"Local path '{local_path}' exists")
        return

    # Check if paths are files or directories
    local_is_dir = os.path.isdir(local_path)
    remote_is_dir = remote_system.is_remote_dir(remote_path)

    if local_is_dir != remote_is_dir:
        print(f"\n[{remote_system.hostname}] Type mismatch:")
        print(f"  Local: {'directory' if local_is_dir else 'file'}")
        print(f"  Remote: {'directory' if remote_is_dir else 'file'}")
        return

    if local_is_dir:
        compare_directories(local_path, remote_system, remote_path)
    else:
        compare_file_content(local_path, remote_system, remote_path)


def compare_file_content(local_file, remote_system, remote_file):
    """Compare content of local and remote files"""
    try:
        with open(local_file, 'r', encoding='utf-8', errors='ignore') as f:
            local_content = f.readlines()
    except Exception as e:
        logger.error(f"Cannot read local file {local_file}: {str(e)}")
        print(f"\n[{remote_system.hostname}] Cannot read local file: {str(e)}")
        return

    remote_content = remote_system.read_remote_file(remote_file)
    if remote_content is None:
        print(f"\n[{remote_system.hostname}] Cannot read remote file (might be binary or permission denied)")
        return

    remote_lines = remote_content.splitlines(keepends=True)

    # Generate diff
    diff = list(difflib.unified_diff(
        local_content,
        remote_lines,
        fromfile=f'local: {local_file}',
        tofile=f'remote: {remote_file}',
        lineterm=''
    ))

    if diff:
        print(f"\n[{remote_system.hostname}] Differences found:")
        print('=' * 80)
        for line in diff:
            print(line)
        print('=' * 80)
    else:
        print(f"\n[{remote_system.hostname}] Files are identical")


def compare_directories(local_dir, remote_system, remote_dir):
    """Compare local and remote directories"""
    local_items = set(os.listdir(local_dir))
    remote_items = set(remote_system.list_remote_dir(remote_dir))

    only_local = local_items - remote_items
    only_remote = remote_items - local_items
    common = local_items & remote_items

    print(f"\n[{remote_system.hostname}] Directory comparison:")
    print('=' * 80)

    if only_local:
        print(f"\nOnly in local directory:")
        for item in sorted(only_local):
            print(f"  - {item}")

    if only_remote:
        print(f"\nOnly in remote directory:")
        for item in sorted(only_remote):
            print(f"  - {item}")

    if common:
        print(f"\nCommon items: {len(common)}")
        print("(Use file comparison for detailed diff of individual files)")

    print('=' * 80)


def execute_commands_from_file(command_file, remote_systems, user, password, max_workers):
    """Execute commands from file on remote systems"""
    try:
        with open(command_file, 'r') as f:
            commands = [line.strip() for line in f if line.strip() and not line.startswith('#')]
    except Exception as e:
        logger.error(f"Failed to read command file: {str(e)}")
        return

    logger.info(f"Loaded {len(commands)} commands from {command_file}")

    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        futures = {}

        for hostname, ip in remote_systems:
            future = executor.submit(
                execute_commands_on_system,
                hostname, ip, commands, user, password
            )
            futures[future] = hostname

        for future in as_completed(futures):
            hostname = futures[future]
            try:
                future.result()
            except Exception as e:
                logger.error(f"Error processing {hostname}: {str(e)}")


def execute_commands_on_system(hostname, ip, commands, user, password):
    """Execute list of commands on a single system"""
    remote = RemoteSystem(hostname, ip, user, password)

    if not remote.connect():
        return

    try:
        for cmd in commands:
            # Check for COPY command
            if cmd.startswith('COPY '):
                parts = cmd.split()
                if len(parts) == 3:
                    local_path = parts[1]
                    remote_path = parts[2]
                    remote.copy_to_remote(local_path, remote_path)
                else:
                    logger.error(f"[{hostname}] Invalid COPY syntax: {cmd}")
                continue

            # Check for dangerous commands
            if is_dangerous_command(cmd):
                logger.warning(f"[{hostname}] SKIPPING DANGEROUS COMMAND: {cmd}")
                print(f"\n⚠️  WARNING: Skipping dangerous command on {hostname}: {cmd}")
                continue

            remote.execute_command(cmd)

    finally:
        remote.disconnect()


def process_diff(remote_system, local_path, remote_path):
    """Process diff for a single remote system"""
    if remote_system.connect():
        try:
            compare_files(local_path, remote_system, remote_path)
        finally:
            remote_system.disconnect()


def load_remote_systems(file_path):
    """Load remote systems from a file"""
    systems = []

    if not os.path.exists(file_path):
        logger.error(f"Remote systems file not found: {file_path}")
        print(f"\nERROR: File '{file_path}' does not exist!")
        print("\nPlease create the file with the following format:")
        print("  hostname1,ip_address1")
        print("  hostname2,ip_address2")
        print("\nExample:")
        print("  server1,192.168.1.10")
        print("  server2,192.168.1.20")
        sys.exit(1)

    try:
        with open(file_path, 'r') as f:
            for line in f:
                line = line.strip()

                if line != "" and not line.startswith('#'):
                    parts = line.split(',')

                    if len(parts) == 2:
                        hostname, ip = parts
                        systems.append((hostname.strip(), ip.strip()))
                    else:
                        logger.warning(f"Invalid line format: {line}")

        if not systems:
            logger.error(f"No valid systems found in {file_path}")
            print(f"\nERROR: No valid systems found in '{file_path}'")
            sys.exit(1)

        logger.info(f"Loaded {len(systems)} remote systems")
    except Exception as e:
        logger.error(f"Failed to load remote systems file: {str(e)}")
        sys.exit(1)

    return systems


def main():
    parser = argparse.ArgumentParser(description='Linux remote operations (Python module used: Fabric)', add_help=False)
    parser.add_argument('--diff', action='store_true', help='Compare local and remote files/directories')
    parser.add_argument('-L', '--local', type=str, help='Local file or directory path')
    parser.add_argument('-R', '--remote', type=str, help='Remote file or directory path')
    parser.add_argument('--user', type=str, required=True, help='SSH username (REQUIRED)')
    parser.add_argument('--exec', type=str, dest='exec_file', help='Execute commands from file')
    parser.add_argument('--systems', type=str, default='/tmp/remoteSystems.in', help='Path to remote systems file')
    parser.add_argument('--parallel', type=int, default=5, help='Number of parallel connections')
    parser.add_argument('-h', '--help', action='store_true', help='Show help message')
    args = parser.parse_args()

    if args.help:
        print_usage()

    # Load remote systems
    remote_systems_list = load_remote_systems(args.systems)

    # Prompt for password
    password = getpass.getpass(f"Enter SSH password for user '{args.user}': ")

    # Diff mode
    if args.diff:
        if not args.local or not args.remote:
            logger.error("Both -L and -R options are required with --diff")
            sys.exit(1)

        with ThreadPoolExecutor(max_workers=args.parallel) as executor:
            futures = {}

            for hostname, ip in remote_systems_list:
                remote = RemoteSystem(hostname, ip, args.user, password)
                future = executor.submit(process_diff, remote, args.local, args.remote)
                futures[future] = hostname

            for future in as_completed(futures):
                try:
                    future.result()
                except Exception as e:
                    logger.error(f"Error: {str(e)}")

    # Execute commands mode
    elif args.exec_file:
        execute_commands_from_file(
            args.exec_file,
            remote_systems_list,
            args.user,
            password,
            args.parallel
        )

    else:
        print("No operation specified. Use --help for usage information.")
        sys.exit(1)


if __name__ == '__main__':
    # Dangerous commands to avoid
    DANGEROUS_COMMANDS = ['rm -rf', 'rm -f', 'shutdown', 'reboot', 'init', 'halt', 'poweroff', 'mkfs', 'dd', ':(){:|:&};:', 'mv / ', 'chmod -R 777', 'chmod -R 000', 'fdisk', 'parted', 'wipefs', 'mkswap', 'swapon', 'swapoff', 'kill', 'pkill', 'userdel', 'groupdel', '> /etc', 'mount', 'umount']
    
    # Configure logging
    logging.basicConfig(
        level=logging.INFO, 
        format='%(asctime)s - %(levelname)s: %(message)s', 
        handlers=[
            logging.FileHandler('remote_oper.log'), 
            logging.StreamHandler()
        ]
    )
    logger = logging.getLogger(__name__)
    
    main()
