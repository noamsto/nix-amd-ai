import argparse
import ctypes
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time

SETTINGS = "@settings@"
SERVER = "@server@"

# The engine parses last-wins and has file-writing flags, so only these pass through.
TUNING_FLAGS = {"--prefill", "--spec", "--spec-min-p", "--mtp-q4", "--kv", "--lookup-chain", "--vram-reserve-mib"}

PR_SET_PDEATHSIG = 1
PR_SET_CHILD_SUBREAPER = 36

libc = ctypes.CDLL(None, use_errno=True)


def die(msg):
    print(f"strata-lemond-shim: {msg}", file=sys.stderr)
    sys.exit(2)


def parse_args(settings):
    p = argparse.ArgumentParser(allow_abbrev=False)
    p.add_argument("-m", "--model")
    p.add_argument("--host")
    p.add_argument("--port")
    p.add_argument("-c", "--ctx", type=int)
    p.add_argument("--ssd-streaming", action="store_true")
    args, extra = p.parse_known_args()
    for flag in ("model", "host", "port"):
        if getattr(args, flag) is None:
            die(f"missing required --{flag}")
    if os.path.realpath(args.model) != os.path.realpath(settings["model"]):
        die(f"model {args.model} does not match the configured model {settings['model']}")
    for e in extra:
        if e.startswith("-") and e not in TUNING_FLAGS:
            die(f"{e} is not allowed: engine arguments from lemond are limited to tuning flags")
    return args, extra


def reap(state, pid):
    while True:
        try:
            p, status = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            return False
        if p == 0:
            return True
        if p == pid:
            state["status"] = status


def main():
    with open(SETTINGS) as f:
        settings = json.load(f)
    args, extra = parse_args(settings)
    ctx = args.ctx if args.ctx and args.ctx > 0 else settings["context"]

    config = dict(settings["config"])
    config["args"] = list(config["args"]) + ["--max-context", str(ctx)] + extra
    tmpdir = tempfile.mkdtemp(dir=os.environ.get("RUNTIME_DIRECTORY") or None)
    cfg = os.path.join(tmpdir, "strata.json")
    with open(cfg, "w") as f:
        json.dump(config, f)

    stopped = []
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, lambda *_: stopped.append(1))

    # Orphaned grandchildren reparent to the shim, so the final reap sees them.
    libc.prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0)
    env = {k: v for k, v in os.environ.items() if k != "LD_LIBRARY_PATH"}
    proc = subprocess.Popen(
        [SERVER, "--engine", "strata", "--config", cfg, "--host", args.host, "--port", args.port],
        start_new_session=True,
        preexec_fn=lambda: libc.prctl(PR_SET_PDEATHSIG, int(signal.SIGKILL), 0, 0, 0),
        env=env,
        stdin=subprocess.DEVNULL,
    )
    pgid = proc.pid
    state = {}

    while not stopped and "status" not in state:
        reap(state, pgid)
        time.sleep(0.1)

    def killpg(sig):
        try:
            os.killpg(pgid, sig)
        except ProcessLookupError:
            pass

    # lemond SIGKILLs the shim 5 s after SIGTERM, so finish inside 4.5 s.
    begin = time.monotonic()
    killpg(signal.SIGTERM)
    alive = True
    while alive and time.monotonic() - begin < 3:
        alive = reap(state, pgid)
        if alive:
            time.sleep(0.1)
    if alive:
        killpg(signal.SIGKILL)
    while alive and time.monotonic() - begin < 4.5:
        alive = reap(state, pgid)
        if alive:
            time.sleep(0.05)

    shutil.rmtree(tmpdir, ignore_errors=True)
    if stopped or "status" not in state:
        return 0
    status = state["status"]
    if os.WIFSIGNALED(status):
        return 128 + os.WTERMSIG(status)
    return os.WEXITSTATUS(status)


sys.exit(main())
