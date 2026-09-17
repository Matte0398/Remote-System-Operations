#!/usr/bin/env python3
"""Execute commands and compare paths on remote Linux systems using Fabric."""

import argparse
import difflib
import getpass
import logging
import os
import posixpath
import shlex
import stat
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from threading import Lock

from fabric import Config, Connection

# Serializes console writes so output produced by parallel workers cannot
# become interleaved.
OUTPUT_LOCK = Lock()

# Reusable separator for the per-host output blocks.
SEP = "=" * 80

# Module-level logger; __name__ identifies this module in every log record.
logger = logging.getLogger(__name__)

# Commands that can stop or restart a remote system and therefore require the
# explicit --allow-dangerous option. SysV equivalents ("init 0" and "init 6")
# are handled separately because "init" alone is not necessarily destructive.
POWER_COMMANDS = {"shutdown", "reboot", "halt", "poweroff"}


def configure_logging():
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s - %(levelname)s: %(message)s",
        handlers=[logging.FileHandler("remote_oper.log", encoding="utf-8")],
    )


class RemoteSystem:
    def __init__(self, hostname, ip, user, password=None, key=None,
                 connect_timeout=10, command_timeout=None):
        self.hostname, self.ip, self.user = hostname, ip, user
        self.password, self.key = password, key
        self.connect_timeout, self.command_timeout = connect_timeout, command_timeout
        self.connection = None

    def connect(self):
        try:
            logger.info("Connecting to %s (%s) as '%s'", self.hostname, self.ip, self.user)
            kwargs = {"timeout": self.connect_timeout}
            if self.password is not None:
                kwargs["password"] = self.password
            if self.key:
                kwargs["key_filename"] = self.key
            # "warn" prevents Fabric from raising an exception for every non-zero
            # exit code, allowing us to collect it and include it in the summary.
            config = Config(overrides={"run": {"warn": True, "timeout": self.command_timeout}})
            self.connection = Connection(self.ip, user=self.user,
                                         connect_kwargs=kwargs, config=config)
            self.connection.open()
            result = self.connection.run("true", hide=True, warn=True)
            if not result.ok:
                raise RuntimeError(f"connection test exited {result.return_code}")
            return True
        except Exception as exc:
            logger.error("Connection to %s failed: %s", self.hostname, exc)
            self.disconnect()
            return False

    def disconnect(self):
        if self.connection:
            try:
                self.connection.close()
            finally:
                self.connection = None

    def sftp(self):
        if not self.connection:
            raise RuntimeError("SSH connection is not open")
        return self.connection.sftp()

    def execute(self, command):
        try:
            logger.info("[%s] Executing: %s", self.hostname, command)
            result = self.connection.run(command, hide=True, warn=True,
                                         timeout=self.command_timeout)
            return result.return_code, result.stdout, result.stderr
        except Exception as exc:
            logger.error("[%s] Command error: %s", self.hostname, exc)
            return -1, "", str(exc)

    def kind(self, path):
        try:
            # lstat does not follow symbolic links, so they can be distinguished
            # from the files or directories they point to.
            mode = self.sftp().lstat(path).st_mode
        except OSError:
            return None
        if stat.S_ISDIR(mode):
            return "directory"
        if stat.S_ISLNK(mode):
            return "symlink"
        return "file"

    def read_bytes(self, path):
        try:
            with self.sftp().open(path, "rb") as handle:
                return handle.read()
        except Exception as exc:
            logger.error("[%s] Cannot read %s: %s", self.hostname, path, exc)
            return None

    def manifest(self, root):
        result = {}
        # The manifest always uses relative POSIX paths. This makes it directly
        # comparable with the local manifest even when this script runs on Windows.
        def visit(current, relative=""):
            for item in self.sftp().listdir_attr(current):
                rel = posixpath.join(relative, item.filename)
                full = posixpath.join(current, item.filename)
                kind = ("directory" if stat.S_ISDIR(item.st_mode) else
                        "symlink" if stat.S_ISLNK(item.st_mode) else "file")
                result[rel] = kind
                # Do not follow symlinks: they could create cycles or make the
                # scan leave the requested directory tree.
                if kind == "directory":
                    visit(full, rel)
        visit(root)
        return result

    def mkdirs(self, path):
        path = posixpath.normpath(path)
        if path in ("", "."):
            return
        current = "/" if path.startswith("/") else ""
        # SFTP has no recursive equivalent of "mkdir -p", so build the path one
        # component at a time without invoking a remote shell.
        for part in path.split("/"):
            if not part:
                continue
            current = posixpath.join(current, part)
            try:
                self.sftp().stat(current)
            except OSError:
                self.sftp().mkdir(current)

    def copy(self, local, remote):
        try:
            if os.path.isfile(local):
                self.sftp().put(local, remote)
                return True
            if not os.path.isdir(local):
                logger.error("[%s] Local path not found: %s", self.hostname, local)
                return False
            self.mkdirs(remote)
            for root, dirs, files in os.walk(local):
                # os.walk returns native separators, whereas the remote Linux
                # server always requires '/'.
                rel = os.path.relpath(root, local)
                target = remote if rel == "." else posixpath.join(
                    remote, rel.replace(os.sep, "/"))
                self.mkdirs(target)
                for name in dirs:
                    self.mkdirs(posixpath.join(target, name))
                for name in files:
                    self.sftp().put(os.path.join(root, name), posixpath.join(target, name))
            return True
        except Exception as exc:
            logger.error("[%s] Copy failed: %s", self.hostname, exc)
            return False


def positive_int(value):
    try:
        value = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("must be an integer") from exc
    if value < 1:
        raise argparse.ArgumentTypeError("must be greater than zero")
    return value


def is_dangerous_command(command):
    """Best-effort guard only; command files must still be trusted."""
    # Normalize the fork bomb so variants containing extra whitespace are caught.
    if ":(){:|:&};:" in "".join(command.lower().split()):
        return True
    try:
        tokens = [x.lower() for x in shlex.split(command, posix=True)]
    except ValueError:
        return True
    # basename recognizes both a bare "rm" and paths such as "/bin/rm".
    names = [posixpath.basename(x) for x in tokens]
    if any(x in POWER_COMMANDS or x.startswith("mkfs") for x in names):
        return True
    if "dd" in names and any(x.startswith(("if=", "of=")) for x in tokens):
        return True
    for index, name in enumerate(names):
        tail = tokens[index + 1:]
        # Separate options from positional arguments to recognize equivalent
        # forms such as "rm -rf /" and "rm -r -f -- /".
        args = [x for x in tail if not x.startswith("-")]
        opts = "".join(x.lstrip("-") for x in tail if x.startswith("-"))
        if name == "init" and args and args[0] in {"0", "6"}:
            return True
        if name == "rm" and "r" in opts and "f" in opts and any(x in {"/", "/*"} for x in args):
            return True
        if name == "chmod" and "r" in opts and "/" in args and any(
                x in {"777", "a+rwx", "ugo+rwx"} for x in args):
            return True
        if name == "mv" and args and args[0] == "/":
            return True
    return False


def local_manifest(root):
    base, result = Path(root), {}
    for path in base.rglob("*"):
        # as_posix makes local Windows paths comparable with SFTP paths.
        rel = path.relative_to(base).as_posix()
        result[rel] = ("symlink" if path.is_symlink() else
                       "directory" if path.is_dir() else "file")
    return result


def compare_file(local, remote_system, remote, label=None):
    try:
        left = Path(local).read_bytes()
    except OSError as exc:
        return [f"Cannot read local file {local}: {exc}"], False
    right = remote_system.read_bytes(remote)
    if right is None:
        return [f"Cannot read remote file {remote}"], False
    name = label or local
    if left == right:
        return [f"Identical: {name}"], True
    # A NUL byte or failed UTF-8 decoding indicates binary content. Report the
    # difference without producing a corrupted textual diff.
    if b"\0" in left or b"\0" in right:
        return [f"Binary files differ: {name}"], True
    try:
        left_text, right_text = left.decode("utf-8"), right.decode("utf-8")
    except UnicodeDecodeError:
        return [f"Binary files differ: {name}"], True
    diff = difflib.unified_diff(
        left_text.splitlines(keepends=True), right_text.splitlines(keepends=True),
        fromfile=f"local: {local}", tofile=f"remote: {remote}", lineterm="\n")
    return [f"Differences found: {name}", "".join(diff).rstrip()], True


def compare_directories(local, remote_system, remote):
    try:
        left, right = local_manifest(local), remote_system.manifest(remote)
    except Exception as exc:
        return [f"Directory comparison failed: {exc}"], False
    # Set differences find entries present on only one side; the intersection
    # contains entries that must be compared in detail.
    lp, rp = set(left), set(right)
    lines, unchanged, success = ["Directory comparison:"], 0, True
    lines += [f"Only local:  {p} ({left[p]})" for p in sorted(lp - rp)]
    lines += [f"Only remote: {p} ({right[p]})" for p in sorted(rp - lp)]
    for rel in sorted(lp & rp):
        if left[rel] != right[rel]:
            lines.append(f"Type differs: {rel} (local={left[rel]}, remote={right[rel]})")
        elif left[rel] == "file":
            # Directories and symlinks are already described by the manifest;
            # only regular files require a byte-by-byte comparison.
            detail, ok = compare_file(os.path.join(local, *rel.split("/")),
                                      remote_system, posixpath.join(remote, rel), rel)
            success &= ok
            if detail[0].startswith("Identical:"):
                unchanged += 1
            else:
                lines += [""] + detail
    if len(lines) == 1:
        lines.append("Directories are identical")
    elif unchanged:
        lines.append(f"\nIdentical common files: {unchanged}")
    return lines, success


def host_block(host, ip, lines):
    return "\n".join(["", SEP, f"HOST: {host} ({ip})", SEP, *lines, SEP])


def compare_paths(local, remote_system, remote):
    local_kind = "directory" if os.path.isdir(local) else "file" if os.path.isfile(local) else None
    remote_kind = remote_system.kind(remote)
    if not local_kind or not remote_kind:
        missing = "local" if not local_kind else "remote"
        return host_block(remote_system.hostname, remote_system.ip,
                          [f"{missing.title()} path missing or inaccessible"]), False
    if local_kind != remote_kind:
        return host_block(remote_system.hostname, remote_system.ip,
                          [f"Type mismatch: local={local_kind}, remote={remote_kind}"]), True
    if local_kind == "directory":
        lines, ok = compare_directories(local, remote_system, remote)
    else:
        lines, ok = compare_file(local, remote_system, remote)
    return host_block(remote_system.hostname, remote_system.ip, lines), ok


def format_commands(remote, entries):
    lines = []
    for item in entries:
        lines += ["", f'$ {item["command"]}', f'status: {item["status"]}']
        if item.get("stdout"):
            lines += ["--- stdout ---", item["stdout"].rstrip()]
        if item.get("stderr"):
            lines += ["--- stderr ---", item["stderr"].rstrip()]
        if not item.get("stdout") and not item.get("stderr"):
            lines.append("(no output)")
    return host_block(remote.hostname, remote.ip, lines)


def parse_copy(command):
    try:
        parts = shlex.split(command, posix=True)
    except ValueError as exc:
        if command.lstrip().upper().startswith("COPY"):
            raise ValueError(f"invalid COPY quoting: {exc}") from exc
        return None
    if not parts or parts[0].upper() != "COPY":
        return None
    if len(parts) != 3:
        raise ValueError("expected COPY <local_path> <remote_path>")
    return parts[1:]


def run_commands(remote, commands, allow_dangerous=False):
    entries, success = [], True
    if not remote.connect():
        return format_commands(remote, [{"command": "connect", "status": "FAILED",
                                         "stderr": "Unable to establish SSH connection"}]), False
    try:
        for command in commands:
            try:
                operands = parse_copy(command)
            except ValueError as exc:
                entries.append({"command": command, "status": "FAILED", "stderr": str(exc)})
                success = False
                continue
            if operands:
                # COPY is a local pseudo-command: it transfers data through SFTP
                # and is never forwarded to the remote shell.
                ok = remote.copy(*operands)
                entries.append({"command": command, "status": "OK" if ok else "FAILED",
                                "stdout": "Copy completed" if ok else "",
                                "stderr": "" if ok else "See remote_oper.log"})
            elif not allow_dangerous and is_dangerous_command(command):
                ok = False
                entries.append({"command": command, "status": "SKIPPED",
                                "stderr": "Potentially destructive; use --allow-dangerous"})
            else:
                code, stdout, stderr = remote.execute(command)
                ok = code == 0
                entries.append({"command": command, "status": f"EXIT {code}",
                                "stdout": stdout, "stderr": stderr})
            success &= ok
    finally:
        remote.disconnect()
    return format_commands(remote, entries), success


def connected_diff(remote, local, remote_path):
    if not remote.connect():
        return format_commands(remote, [{"command": "connect", "status": "FAILED",
                                         "stderr": "Unable to establish SSH connection"}]), False
    try:
        return compare_paths(local, remote, remote_path)
    finally:
        # Always close the connection, even if comparison raises an exception.
        remote.disconnect()


def run_parallel(remotes, worker, max_workers):
    success = True
    with ThreadPoolExecutor(max_workers=max_workers) as pool:
        # Keep the future-to-host mapping so unhandled worker exceptions can
        # still be attributed to the correct remote system.
        futures = {pool.submit(worker, remote): remote for remote in remotes}
        for future in as_completed(futures):
            remote = futures[future]
            try:
                output, ok = future.result()
            except Exception as exc:
                logger.exception("Unhandled error for %s", remote.hostname)
                output, ok = host_block(remote.hostname, remote.ip, [f"FAILED: {exc}"]), False
            with OUTPUT_LOCK:
                # Print each block while holding the lock so concurrent output
                # cannot become interleaved line by line.
                print(output)
            # A failure on any host is enough to produce final exit code 1.
            success &= ok
    return success


def load_systems(path):
    systems = []
    try:
        with open(path, encoding="utf-8") as handle:
            for number, raw in enumerate(handle, 1):
                line = raw.strip()
                if not line or line.startswith("#"):
                    continue
                parts = [x.strip() for x in line.split(",")]
                if len(parts) == 2 and all(parts):
                    systems.append(tuple(parts))
                else:
                    logger.warning("Invalid line %s in %s", number, path)
    except OSError as exc:
        raise ValueError(f"cannot read systems file '{path}': {exc}") from exc
    if not systems:
        raise ValueError(f"no valid systems found in '{path}'")
    return systems


def build_parser():
    parser = argparse.ArgumentParser(
        description="Execute commands or recursively compare paths on remote Linux systems",
        epilog="Command files are trusted input; the destructive-command guard is best-effort only.")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--diff", action="store_true")
    mode.add_argument("--exec", dest="exec_file", metavar="FILE")
    parser.add_argument("-L", "--local")
    parser.add_argument("-R", "--remote")
    parser.add_argument("--user", required=True)
    parser.add_argument("--systems", default="/tmp/remoteSystems.in")
    parser.add_argument("--parallel", type=positive_int, default=5)
    parser.add_argument("--key", help="SSH private key (no password prompt)")
    parser.add_argument("--no-password", action="store_true", help="use SSH agent/config")
    parser.add_argument("--connect-timeout", type=positive_int, default=10)
    parser.add_argument("--command-timeout", type=positive_int)
    parser.add_argument("--allow-dangerous", action="store_true")
    return parser


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.diff and (not args.local or not args.remote):
        parser.error("--diff requires --local and --remote")
    if args.key and args.no_password:
        parser.error("--key and --no-password are mutually exclusive")
    try:
        systems = load_systems(args.systems)
    except ValueError as exc:
        parser.error(str(exc))
    password = None if args.key or args.no_password else getpass.getpass(
        f"Enter SSH password for user '{args.user}': ")
    remotes = [RemoteSystem(host, ip, args.user, password, args.key,
                            args.connect_timeout, args.command_timeout)
               for host, ip in systems]
    if args.diff:
        # run_parallel expects a single-argument worker; the lambda binds the CLI
        # options shared by all remote systems to that worker.
        worker = lambda remote: connected_diff(remote, args.local, args.remote)
    else:
        try:
            with open(args.exec_file, encoding="utf-8") as handle:
                commands = [x.strip() for x in handle if x.strip() and not x.lstrip().startswith("#")]
        except OSError as exc:
            parser.error(f"cannot read command file '{args.exec_file}': {exc}")
        worker = lambda remote: run_commands(remote, commands, args.allow_dangerous)
    return 0 if run_parallel(remotes, worker, args.parallel) else 1


if __name__ == "__main__":
    configure_logging()
    sys.exit(main())
