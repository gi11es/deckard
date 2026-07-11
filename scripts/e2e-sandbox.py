#!/usr/bin/env python3
"""Isolated end-to-end test for Deckard's control-socket behavior.

Launches the built app binary with HOME and TMPDIR pointed at a throwaway
sandbox directory, then drives it through the control socket:

  1. ping/pong sanity check
  2. session hijack scenario: hook.session-start reporting a cwd outside the
     tab's workspace must not overwrite the tab's session id (PR #95)
  3. SIGPIPE hammer: clients that send a message and close before the app
     replies must not kill the app (PR #94)

Expectations are parameterized so an unfixed build can serve as the control
(proving the harness actually triggers each bug).

usage: e2e-sandbox.py <app_binary> <label> <expect_sigpipe_survive:0|1> <expect_hijack_reject:0|1>
"""
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import time
import uuid

APP, LABEL = os.path.abspath(sys.argv[1]), sys.argv[2]
EXPECT_SURVIVE = sys.argv[3] == "1"
EXPECT_REJECT = sys.argv[4] == "1"

SANDBOX = os.path.join(os.environ.get("RUNNER_TEMP", "/tmp"), f"deckard-e2e-{LABEL}")
HOME = os.path.join(SANDBOX, "home")
TMP = os.path.join(SANDBOX, "tmp") + "/"
WORKDIR = os.path.join(SANDBOX, "work", "proj")
SOCK = os.path.join(TMP, f"deckard-{os.getuid()}.sock")
DIAG_CANDIDATES = [
    os.path.join(HOME, "Library/Application Support/Deckard/diagnostic.log"),
    os.path.expanduser("~/Library/Application Support/Deckard/diagnostic.log"),
]
def diag_path():
    return next((p for p in DIAG_CANDIDATES if os.path.exists(p)), None)
APP_OUT = os.path.join(SANDBOX, "app-stdout.log")
APP_ERR = os.path.join(SANDBOX, "app-stderr.log")

results = []


def check(name, ok, detail=""):
    results.append((name, ok, detail))
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}" + (f" — {detail}" if detail else ""), flush=True)


def send(msg, read_reply=True, timeout=5):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(SOCK)
    s.sendall((json.dumps(msg) + "\n").encode())
    if not read_reply:
        s.close()
        return None
    data = s.recv(65536)
    s.close()
    return json.loads(data) if data else None


def alive(p):
    return p.poll() is None


def dump_logs():
    for path in (APP_ERR, APP_OUT, diag_path()):
        if path and os.path.exists(path) and os.path.getsize(path):
            print(f"--- tail {path} ---", flush=True)
            with open(path, errors="replace") as f:
                print("".join(f.readlines()[-30:]), flush=True)


shutil.rmtree(SANDBOX, ignore_errors=True)
for d in (HOME, TMP, WORKDIR):
    os.makedirs(d, exist_ok=True)

env = dict(os.environ, HOME=HOME, TMPDIR=TMP)
env.pop("DECKARD_SOCKET_PATH", None)
env.pop("DECKARD_SURFACE_ID", None)

print(f"== {LABEL}: launching sandboxed app ==", flush=True)
proc = subprocess.Popen(
    [APP], env=env, cwd=SANDBOX,
    stdout=open(APP_OUT, "w"), stderr=open(APP_ERR, "w"))
try:
    for _ in range(120):
        if os.path.exists(SOCK) or not alive(proc):
            break
        time.sleep(0.25)
    check("app started, control socket created",
          os.path.exists(SOCK) and alive(proc),
          f"exit={proc.poll()}")
    if not os.path.exists(SOCK):
        dump_logs()
        raise SystemExit(1)

    resp = send({"command": "ping"})
    check("ping -> pong", bool(resp and resp.get("ok") and resp.get("message") == "pong"))

    # FileManager's app-support path ignores $HOME, so on a runner the log
    # may land in the runner user's home — acceptable on a disposable VM.
    time.sleep(1)
    check("diagnostic.log found", diag_path() is not None, str(diag_path()))

    # --- Hijack scenario ---
    send({"command": "create-tab", "workingDirectory": WORKDIR})
    time.sleep(3)
    tabs = (send({"command": "list-tabs"}) or {}).get("tabs") or []
    check("workspace tab created", len(tabs) >= 1, f"{len(tabs)} tab(s)")
    if tabs:
        tab = tabs[0]
        sid = str(uuid.uuid4())
        # Nested-claude imitation: session-start from a foreign temp checkout
        send({"command": "hook.session-start", "surfaceId": tab["id"],
              "sessionId": sid,
              "workingDirectory": "/private/var/folders/9z/T/reviewer-fake-pr123"})
        time.sleep(1)
        tabs2 = (send({"command": "list-tabs"}) or {}).get("tabs") or []
        got = next((t for t in tabs2 if t["id"] == tab["id"]), {})
        hijacked = got.get("sessionId") == sid
        if EXPECT_REJECT:
            check("foreign-cwd session-start rejected", not hijacked,
                  f"sessionId={got.get('sessionId')}")
            logged = False
            if diag_path():
                with open(diag_path(), errors="replace") as f:
                    logged = "Ignoring session-start from nested claude" in f.read()
            check("rejection logged in diagnostic.log", logged)
            # Legit session-start from inside the workspace must be accepted
            legit = str(uuid.uuid4())
            send({"command": "hook.session-start", "surfaceId": tab["id"],
                  "sessionId": legit, "workingDirectory": WORKDIR})
            time.sleep(1)
            tabs3 = (send({"command": "list-tabs"}) or {}).get("tabs") or []
            got3 = next((t for t in tabs3 if t["id"] == tab["id"]), {})
            check("workspace-cwd session-start accepted",
                  got3.get("sessionId") == legit,
                  f"sessionId={got3.get('sessionId')}")
        else:
            check("control: unfixed build adopts foreign session id", hijacked,
                  f"sessionId={got.get('sessionId')}")

    # --- SIGPIPE hammer: send and close before the app replies ---
    died_at = None
    for i in range(80):
        try:
            send({"command": "hook.stop", "surfaceId": str(uuid.uuid4())},
                 read_reply=False)
        except (ConnectionRefusedError, FileNotFoundError, OSError):
            died_at = i
            break
        if i % 10 == 9:
            time.sleep(0.3)
            if not alive(proc):
                died_at = i
                break
    time.sleep(1.5)
    survived = alive(proc)
    if EXPECT_SURVIVE:
        ok = survived
        if ok:
            resp = send({"command": "ping"})
            ok = bool(resp and resp.get("ok"))
        check("survived 80 close-early clients, still responsive", ok,
              f"exit={proc.poll()}")
    else:
        detail = f"died at iteration {died_at}" if not survived else "survived (race not hit)"
        check("control: unfixed build killed by close-early client",
              not survived, detail)
        if survived:
            print("  NOTE: control inconclusive — the SIGPIPE race was not hit this run",
                  flush=True)

finally:
    if alive(proc):
        proc.send_signal(signal.SIGKILL)
    if shutil.which("tmux"):
        subprocess.run(["tmux", "-L", "deckard", "kill-server"],
                       env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(0.5)

failed = [r for r in results if not r[1]]
if failed:
    dump_logs()
print(f"== {LABEL}: {len(results) - len(failed)}/{len(results)} checks passed ==")
sys.exit(1 if failed else 0)
