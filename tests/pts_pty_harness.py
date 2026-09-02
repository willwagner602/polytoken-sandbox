#!/usr/bin/env python3
"""Provider-free end-to-end test of the real PTS/Podman lifecycle."""
import json
import os
import pathlib
import re
import select
import shutil
import subprocess
import sys
import tempfile
import time
import uuid


class PtyProcess:
    def __init__(self, command, cwd, env):
        master, slave = os.openpty()
        self.master = master
        self.output = b""
        self.process = subprocess.Popen(
            command,
            cwd=cwd,
            env=env,
            stdin=slave,
            stdout=slave,
            stderr=slave,
            start_new_session=True,
        )
        os.close(slave)

    def wait_for(self, pattern, timeout=30):
        deadline = time.monotonic() + timeout
        regex = re.compile(pattern)
        while time.monotonic() < deadline:
            match = regex.search(self.output.decode(errors="replace"))
            if match:
                return match
            ready, _, _ = select.select([self.master], [], [], 0.2)
            if ready:
                try:
                    chunk = os.read(self.master, 4096)
                except OSError:
                    chunk = b""
                self.output += chunk
            elif self.process.poll() is not None:
                break
        raise AssertionError(
            f"timed out waiting for {pattern!r}; output:\n{self.output.decode(errors='replace')}"
        )

    def write(self, value):
        os.write(self.master, value)

    def wait(self, timeout=30):
        status = self.process.wait(timeout=timeout)
        while True:
            ready, _, _ = select.select([self.master], [], [], 0)
            if not ready:
                break
            try:
                self.output += os.read(self.master, 4096)
            except OSError:
                break
        os.close(self.master)
        return status


def run(*args, check=True):
    return subprocess.run(args, check=check, text=True, capture_output=True)


def inspect(container_id):
    return json.loads(run("podman", "inspect", container_id).stdout)[0]


def main():
    if not shutil.which("podman") or run("podman", "info", check=False).returncode:
        print("BLOCKED: Podman unavailable; provider-free PTS lifecycle not exercised")
        return 2

    image = os.environ.get("PTS_E2E_IMAGE", "docker.io/library/debian:12-slim")
    if run("podman", "image", "exists", image, check=False).returncode:
        print(f"BLOCKED: local PTS E2E image {image} is unavailable")
        return 2

    root = pathlib.Path(__file__).resolve().parents[1]
    volume = f"pts-e2e-{uuid.uuid4().hex}"
    container_id = None
    processes = []
    with tempfile.TemporaryDirectory(prefix="pts-e2e-") as td:
        project = pathlib.Path(td) / "project"
        project.mkdir()
        fake = pathlib.Path(td) / "fake-polytoken"
        fake.write_text(
            """#!/bin/sh
if [ "$*" = "auth provider status --provider codex" ]; then
    echo "authenticated"
    exit 0
fi
printf 'FAKE_READY pid=%s args=%s\\n' "$$" "$*"
trap 'echo FAKE_TERM; exit 143' HUP TERM INT
while IFS= read -r command; do
    case "$command" in
        ping) printf 'PONG pid=%s\\n' "$$" ;;
        quit) echo FAKE_QUIT; exit 0 ;;
    esac
done
"""
        )
        fake.chmod(0o755)

        env = os.environ.copy()
        env.update(
            {
                "PTS_BASE_IMAGE": image,
                "PTS_BIN_VOLUME": volume,
                "PTS_POLYTOKEN_SEED": str(fake),
                "PTS_MEMORY": "256m",
                "PTS_MEMORY_SWAP": "512m",
                "PTS_PIDS_LIMIT": "128",
                "TERM": "xterm-256color",
            }
        )
        launch = [
            "bash",
            "--noprofile",
            "--norc",
            "-c",
            'source "$1"; pts -- e2e',
            "pts-e2e",
            str(root / "polytoken-sandbox.sh"),
        ]
        reconnect = [
            "bash",
            "--noprofile",
            "--norc",
            "-c",
            'source "$1"; pts',
            "pts-e2e",
            str(root / "polytoken-sandbox.sh"),
        ]

        try:
            first = PtyProcess(launch, project, env)
            processes.append(first)
            ready = first.wait_for(r"FAKE_READY pid=(\d+) args=e2e")
            fake_pid = ready.group(1)
            id_match = first.wait_for(r"id=([0-9a-f]{12})")
            container_id = id_match.group(1)

            data = inspect(container_id)
            config = data["Config"]
            host = data["HostConfig"]
            assert data["State"]["Status"] == "running"
            assert config["Labels"]["pts.owner"] == "polytoken.pts"
            assert config["Labels"]["pts.project"] == str(project)
            assert config["WorkingDir"] == str(project)
            assert f"HOME={project}/.polytoken" in config["Env"]
            assert host["Memory"] == 256 * 1024 * 1024
            assert host["MemorySwap"] == 512 * 1024 * 1024
            assert host["PidsLimit"] == 128
            assert host["Init"] is True
            assert host["NetworkMode"] == "host"
            assert any(
                mount["Destination"] == "/opt/polytoken-bin" and mount["Name"] == volume
                for mount in data["Mounts"]
            )

            # Detach causation: with start -ai, a clean client exit while
            # the container is still running can only be the detach control
            # sequence; the reconnect below (same fake pid answering PONG,
            # container still running) then proves the workload survived the
            # detach rather than dying with the client.
            first.write(b"\x10")
            time.sleep(0.1)
            first.write(b"\x11")
            first.wait_for(r"retained running container")
            assert first.wait() == 0
            assert inspect(container_id)["State"]["Status"] == "running"

            second = PtyProcess(reconnect, project, env)
            processes.append(second)
            second.wait_for(r"reconnecting to the existing managed container")
            second.write(b"ping\n")
            second.wait_for(rf"PONG pid={fake_pid}")
            # Reconnect must have attached to the same live container, not
            # replaced it.
            assert inspect(container_id)["State"]["Status"] == "running"
            second.write(b"quit\n")
            second.wait_for(r"FAKE_QUIT")
            assert second.wait() == 0

            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                if run("podman", "inspect", container_id, check=False).returncode:
                    break
                time.sleep(0.2)
            else:
                raise AssertionError("PTS did not remove the container after reattached workload exit")
        finally:
            for process in processes:
                if process.process.poll() is None:
                    process.process.terminate()
                    try:
                        process.process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.process.kill()
            if container_id:
                run("podman", "rm", "-f", container_id, check=False)
            run("podman", "volume", "rm", "-f", volume, check=False)

    print("Provider-free PTS launch/detach/reconnect/cleanup checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
