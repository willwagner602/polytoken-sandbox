#!/usr/bin/env python3
"""Provider-free Polytoken capability probe for the PTS lifecycle suite.

This intentionally does not fake a daemon or session. It creates an isolated
HOME and asks the installed CLI for live sessions, so an unavailable provider
or missing fixture is reported as a blocker rather than a false pass.
"""
import json
import os
import pathlib
import pty
import shutil
import subprocess
import sys
import tempfile


def main():
    binary = shutil.which("polytoken") or os.path.expanduser("~/.local/bin/polytoken")
    if not binary or not os.path.exists(binary):
        print("BLOCKED: compatible Polytoken binary unavailable")
        return 2
    with tempfile.TemporaryDirectory(prefix="pts-pty-") as td:
        home = pathlib.Path(td) / "home"
        home.mkdir(mode=0o700)
        env = os.environ.copy()
        env.update({"HOME": str(home), "TERM": "xterm-256color"})
        result = subprocess.run(
            [binary, "sessions", "--format", "json"],
            env=env, text=True, capture_output=True, timeout=10,
        )
        if result.returncode != 0:
            print("BLOCKED: provider-free session registry query failed")
            print(result.stderr.strip())
            return 2
        try:
            sessions = json.loads(result.stdout)
        except json.JSONDecodeError:
            print("BLOCKED: Polytoken sessions output was not JSON")
            return 2
        if sessions not in ([], {}):
            print("BLOCKED: isolated HOME unexpectedly contains live sessions")
            return 2
        print("BLOCKED: no provider-free disposable session fixture is available; detach/reconnect proof not exercised")
        return 2


if __name__ == "__main__":
    sys.exit(main())
