#!/usr/bin/env python3
"""Reproduce the macOS x64 Julia 1.14-alpha2 crash in its full-suite context.

Run explicitly on macOS with Python 3.8+, git, curl, and tar available. On an
Apple Silicon Mac, the x64 Julia binary requires Rosetta already installed.
Everything downloaded or generated stays in the printed temporary directory;
the user's Julia depot, startup file, git configuration, and checkouts are unused.
The directory is retained for inspecting the resolved manifests after a failure.
The full coverage suite has a 45-minute limit within a 60-minute overall limit.
"""

import hashlib
import os
from pathlib import Path
import platform
import shlex
import signal
import subprocess
import sys
import tempfile
import time


JULIA_URL = "https://julialang-s3.julialang.org/bin/mac/x64/1.14/julia-1.14.0-alpha2-mac64.tar.gz"
JULIA_SHA256 = "6b3b359d68887ce8051eef47f013684b23b4e8db449782191c47f7e828d500a9"
SOURCE_SHA = "47c0198f920ecb1f94d9a73f2536dc25101c03b9"
TREEBARS_SHA = "e03f2c7be5579fafce38d8759b531a6e22996ba5"


def stop_group(pid):
    # The group can outlive its leader, so signal it even if Julia exited.
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(pid, sig)
        except ProcessLookupError:
            break
        if sig == signal.SIGTERM:
            time.sleep(2)


def run(command, *, cwd, env, seconds, deadline, capture=False):
    """Bound the whole subprocess group, including Pkg.test's Julia children."""
    remaining = min(seconds, deadline - time.monotonic())
    if remaining <= 0:
        raise TimeoutError("60-minute diagnostic deadline reached")
    started = time.monotonic()
    print(f"+ [limit {remaining:.0f}s] " + shlex.join(map(str, command)), flush=True)
    process = subprocess.Popen(
        command, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.STDOUT if capture else None,
        text=True, start_new_session=True,
    )
    try:
        output, _ = process.communicate(timeout=remaining)
    except BaseException:
        stop_group(process.pid)
        process.communicate()
        raise
    finally:
        print(f"Command finished after {time.monotonic() - started:.1f}s; "
              f"child status: {process.returncode}", flush=True)
    if output:
        print(output, end="", flush=True)
    if process.returncode:
        stop_group(process.pid)
        raise subprocess.CalledProcessError(process.returncode, command)
    return output


def main():
    if platform.system() != "Darwin":
        raise SystemExit("This diagnostic requires native macOS; nothing was downloaded.")
    root = Path(tempfile.mkdtemp(prefix="do-requester-logger-"))
    deadline = time.monotonic() + 60 * 60
    print("Diagnostic scratch directory:", root, flush=True)
    print("Host architecture:", platform.machine(), "Julia target: x86_64", flush=True)
    env = {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "TMPDIR": str(root), "LANG": "en_US.UTF-8",
        "JULIA_DEPOT_PATH": str(root / "depot"),
        "JULIA_LOAD_PATH": "@:@stdlib",
        "JULIA_NUM_PRECOMPILE_TASKS": "2",
        "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_TERMINAL_PROMPT": "0",
    }

    def execute(command, seconds=300, capture=False, cwd=root):
        return run(command, cwd=cwd, env=env, seconds=seconds,
                   deadline=deadline, capture=capture)

    archive = root / "julia.tar.gz"
    execute(["curl", "--disable", "--fail", "--silent", "--show-error", "--location",
             "--max-time", "300", JULIA_URL, "--output", str(archive)])
    digest = hashlib.sha256()
    with archive.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    if digest.hexdigest() != JULIA_SHA256:
        raise RuntimeError("Julia archive SHA-256 mismatch; refusing extraction")
    execute(["tar", "-xzf", str(archive), "-C", str(root)])
    binaries = list(root.glob("*/Contents/Resources/julia/bin/julia"))
    binaries += list(root.glob("julia-*/bin/julia"))
    if len(binaries) != 1:
        raise RuntimeError("Expected exactly one Julia application in the verified archive")
    julia = str(binaries[0])
    execute([julia, "--startup-file=no", "-e",
             'using InteractiveUtils; versioninfo(); '
             '@assert Sys.isapple() && Sys.ARCH === :x86_64; '
             '@assert VERSION == v"1.14.0-alpha2"'])

    source = root / "DynamicObjects.jl"
    execute(["git", "init", "--quiet", str(source)])
    execute(["git", "-C", str(source), "fetch", "--depth=1",
             "https://github.com/nsiccha/DynamicObjects.jl.git", SOURCE_SHA])
    execute(["git", "-C", str(source), "checkout", "--quiet", "--detach", "FETCH_HEAD"])
    observed = execute(["git", "-C", str(source), "rev-parse", "HEAD"], capture=True)
    if observed.strip() != SOURCE_SHA:
        raise RuntimeError("Source checkout does not match the pinned revision")

    julia_project = [julia, "--startup-file=no", "--project=" + str(source), "-e"]
    execute(julia_project + [
        'using Pkg; Pkg.add(PackageSpec(name="Treebars", '
        'url="https://github.com/nsiccha/Treebars.jl", rev="' + TREEBARS_SHA + '")); '
        'Pkg.instantiate(); Pkg.status(; mode=Pkg.PKGMODE_MANIFEST)'
    ], seconds=900, cwd=source)
    # CI crashes occurred late in the full suite. A preliminary focused run in a
    # cold depot spent 508 of its 600 seconds precompiling, then failed readiness
    # checks and timed out before this full-suite context could run at all.
    print("BEGIN: full CI suite", flush=True)
    execute(julia_project + ['using Pkg; Pkg.test(; coverage=true)'],
            seconds=45 * 60, cwd=source)
    print("PASS: full CI suite; the crash was not reproduced in this run.", flush=True)


if __name__ == "__main__":
    def interrupted(signum, frame):
        raise SystemExit(128 + signum)

    for sig in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, interrupted)
    try:
        main()
    except (subprocess.TimeoutExpired, TimeoutError) as error:
        print("DIAGNOSTIC TIMEOUT:", error, file=sys.stderr, flush=True)
        raise SystemExit(124)
