#!/usr/bin/env python3
"""Exercise host locking and shutdown with harmless temporary child processes."""
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time


def wait_until(predicate, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.05)
    raise AssertionError("Timed out waiting for the host")


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def check_environment(executable):
    baseline = f"{Path.home()}/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    with tempfile.TemporaryDirectory(prefix="runner-environment-test-") as temporary:
        root = Path(temporary)
        script = root / "run.sh"
        script.write_text('''#!/bin/sh
printf '%s' "$PATH" > child-path
umask > child-umask
echo child-started
[ "${GITHUB_TOKEN+set}" = "" ] || exit 10
[ "${GH_TOKEN+set}" = "" ] || exit 11
[ "${CUSTOM_SECRET+set}" = "" ] || exit 12
''')
        script.chmod(0o700)
        environment = dict(os.environ, PATH="/untrusted", GITHUB_TOKEN="synthetic-token",
                           GH_TOKEN="synthetic-token", CUSTOM_SECRET="synthetic-secret")
        host = subprocess.run([executable, "--runner-host", temporary], env=environment, timeout=8)
        assert host.returncode == 0, "Workflow inherited a private variable"
        assert (root / "child-path").read_text() == baseline
        assert int((root / "child-umask").read_text().strip(), 8) == 0o022
        assert (root / "runner.log").stat().st_mode & 0o777 == 0o600
        assert (root / ".host.lock").stat().st_mode & 0o777 == 0o600
    print("PASS: filtered environment, runner PATH, job umask and private helper files")


def check_once_exits(executable):
    for child_exit, expected in ((0, 0), (7, 1), (None, 4)):
        with tempfile.TemporaryDirectory(prefix="runner-once-exit-test-") as temporary:
            root = Path(temporary)
            (root / ".host-exit").write_text("0\n")
            if child_exit is not None:
                script = root / "run.sh"
                script.write_text('#!/bin/sh\n[ ! -e .host-exit ] || exit 66\nprintf \'%s\\n\' "$@" > child-args\necho once-started\n'
                                  + f"exit {child_exit}\n")
                script.chmod(0o700)
            host = subprocess.run([executable, "--runner-host-once", temporary],
                                  capture_output=True, text=True, timeout=8)
            assert host.returncode == expected, host.stderr
            assert (root / ".host-exit").read_text().strip() == str(expected)
            assert (root / ".host-exit").stat().st_mode & 0o777 == 0o600
            if child_exit is not None:
                assert (root / "child-args").read_text().splitlines() == ["--once"]
            assert not (root / ".host.json").exists()
            with (root / ".host.lock").open("r+") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            snapshot = subprocess.run([executable, "--runner-snapshot", temporary],
                                      capture_output=True, text=True, check=True, timeout=8)
            state = json.loads(snapshot.stdout)
            assert not state["running"] and state["exitCode"] == expected
    print("PASS: once argv, stale marker removal, exit markers 0/1/4 and natural lock release")


def check_shutdown(executable, flag):
    with tempfile.TemporaryDirectory(prefix="runner-host-test-") as temporary:
        root = Path(temporary)
        script = root / "run.sh"
        script.write_text('#!/bin/sh\necho $$ > child.pid\necho host-started\ntrap "exit 0" INT TERM\nwhile :; do sleep 1; done\n')
        script.chmod(0o700)
        host = subprocess.Popen([executable, flag, temporary])
        child = None
        try:
            wait_until(lambda: (root / "child.pid").exists() and (root / ".host.json").exists())
            child = int((root / "child.pid").read_text())
            record = json.loads((root / ".host.json").read_text())
            assert record["pid"] == host.pid
            assert os.getpgid(host.pid) == host.pid
            with (root / ".host.lock").open("r+") as lock:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    raise AssertionError("Host failed to retain its lock")
                except BlockingIOError:
                    pass
            duplicate = subprocess.run([executable, "--runner-host", temporary], timeout=5)
            assert duplicate.returncode == 2, "Duplicate host was allowed"
            snapshot = subprocess.run([executable, "--runner-snapshot", temporary],
                                      capture_output=True, text=True, check=True, timeout=8)
            assert json.loads(snapshot.stdout)["running"], "Host identity was not verified"
            print(f"Host group: {os.getpgid(host.pid)}; child group: {os.getpgid(child)}")
            subprocess.run([executable, "--runner-stop", temporary], check=True, timeout=20)
            host.wait(timeout=8)
            wait_until(lambda: not alive(child))
            assert "host-started" in (root / "runner.log").read_text()
            assert not (root / ".host.json").exists()
            with (root / ".host.lock").open("r+") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            print(f"PASS: {flag} identity, bounded output, duplicate rejection, lock release, and child shutdown")
        finally:
            for pid in (child, host.pid):
                if pid and alive(pid):
                    try:
                        os.killpg(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        try:
                            os.kill(pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
            host.wait(timeout=5)


def main():
    executable = str(Path(sys.argv[1]).resolve())
    check_environment(executable)
    check_once_exits(executable)
    for flag in ("--runner-host", "--runner-host-once"):
        check_shutdown(executable, flag)
    # A symlink gives Bundle a stale/different launch path, as moving a running app does.
    with tempfile.TemporaryDirectory(prefix="runner-helper-alias-test-") as temporary:
        alias = Path(temporary) / "Comet"
        alias.symlink_to(executable)
        check_shutdown(str(alias), "--runner-host")


if __name__ == "__main__":
    main()
