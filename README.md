# admin-hook-runner — a SYSTEM elevation channel for Claude Code (Windows)

Claude Code (and agents like it) run as **your normal user** on Windows. They have **no
built-in way to run elevated** — no `sudo`, and they can't click a UAC prompt. So anything
needing admin (registry under HKLM, protected folders, scheduled tasks, killing protected
processes) is out of reach. See the open request: [anthropics/claude-code#29275 — "built-in
sudo watcher for privileged operations"](https://github.com/anthropics/claude-code/issues/29275).

This is a tiny, do-it-yourself fix: a **command queue drained by a SYSTEM task/service.**

- You install it **once, by hand, as Administrator** (that's the only human step).
- After that the agent drops a PowerShell one-shot into a queue file; a process running as
  **NT AUTHORITY\SYSTEM** picks it up, runs it, and returns the output. **No UAC ever again.**

> ### ⚠️ Security — read this
> This grants an **automated agent unattended SYSTEM (full admin) access** to the machine,
> with no further prompts. That is the entire point — and a real tradeoff. Install it **only**
> on a machine you control and where you intend the agent to have that power. Uninstall is one
> menu choice away (below).

## Install

Two ways to run it — pick either:

- **Double-click / "Run with PowerShell"** → you get a menu.
- **Command line:** `powershell -ExecutionPolicy Bypass -File bootstrap.ps1 -Mode task|service|uninstall`

If it isn't elevated it **offers to relaunch itself as Administrator** (accept the UAC prompt).
If a permission error slips through, it tells you plainly: *right-click PowerShell → Run as
administrator.*

The menu:

```
 1) Install as a SCHEDULED TASK   (recommended — runs as SYSTEM every 60s, no dependencies)
 2) Install as a WINDOWS SERVICE  (instant-ish, ~3s latency; needs NSSM)
 3) UNINSTALL                     (removes the task and/or service)
 Q) Quit
```

**Task vs service:** the scheduled task is the recommended default — it's the natural shape for
a periodic privileged executor, needs nothing extra, and minimal moving parts is a virtue for
your most-privileged component. Choose the service only if the ~60s task latency bothers you and
you have [NSSM](https://nssm.cc) installed; it runs `admin_hook_runner.py --loop` and reacts in
~3s. Both run as SYSTEM.

## Uninstall

Run `bootstrap.ps1` → **3**, or `-Mode uninstall`. It removes the scheduled task and/or the
service. Files in `C:\services\admin-hook-runner` are left in place; delete the folder to remove
them too.

## How the agent uses it

`run_elevated.py` is the client. It writes the queue, waits for the SYSTEM runner to consume it,
and hands back per-command `{command, output, exit_code}`:

```
py run_elevated.py "Remove-Item 'C:\ProgramData\SomeApp\telemetry.db' -Force"
py run_elevated.py "schtasks /query /fo LIST /v"        # sees SYSTEM-only tasks
py run_elevated.py status                                # is the channel installed / last run
```

## Files

| file | what |
|---|---|
| `admin_hook_runner.py` | the runner — drains the `_sysfix.ps1` queue as SYSTEM (one-shot, or `--loop` for service) |
| `run_elevated.py` | the client — the agent calls this |
| `bootstrap.ps1` | the human installer/uninstaller (menu; self-elevates) |
| `_sysfix.ps1` | *(runtime)* the queued one-shot; created by the client, deleted by the runner |
| `logs/heartbeat.txt` | *(runtime)* proves the runner is alive + running as SYSTEM |

## The runner in Python (our default language)

We build in **Python**. The runner ships as PowerShell here for one reason only: **zero
dependencies** — PowerShell is on every Windows box, so a random Claude Code user can install
this without first installing Python. That's the *only* reason; it's a deliberate call for a
tiny, must-run-anywhere component, not a language preference.

If you already have Python, `admin_hook_runner.py` (in this repo) is the identical runner — same
contract, same queue file, same SYSTEM behavior. Register it with the scheduled task pointing at
`pythonw.exe admin_hook_runner.py` instead of the `.ps1`, or just read it as the reference:

```python
import argparse, os, subprocess, time

BASE = os.path.dirname(os.path.abspath(__file__))
QUEUE = os.path.join(BASE, "_sysfix.ps1")
HEARTBEAT = os.path.join(BASE, "logs", "heartbeat.txt")
_NOWIN = getattr(subprocess, "CREATE_NO_WINDOW", 0)

def run_queued() -> bool:
    if not os.path.exists(QUEUE):
        return False
    try:
        subprocess.run(["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass",
                        "-File", QUEUE], creationflags=_NOWIN, timeout=300)
    finally:
        try: os.remove(QUEUE)
        except OSError: pass
    return True

def heartbeat(ran: bool) -> None:
    os.makedirs(os.path.dirname(HEARTBEAT), exist_ok=True)
    stamp = time.strftime("%Y-%m-%d %H:%M:%S")
    with open(HEARTBEAT, "w", encoding="utf-8") as f:
        f.write(f"{stamp}  ran_as={os.environ.get('USERNAME','?')}  drained_queue={ran}\n")

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--loop", action="store_true")     # service mode: poll forever
    ap.add_argument("--interval", type=float, default=3.0)
    a = ap.parse_args()
    if a.loop:
        while True:
            heartbeat(run_queued()); time.sleep(max(0.5, a.interval))
    else:
        heartbeat(run_queued())
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
```

The client (`run_elevated.py`) is Python already. The queue is just a file, so the client can be
any language — Python is simply what we reach for.

## How it works (one paragraph)

The runner runs as SYSTEM on a timer. Each tick it checks for `_sysfix.ps1` next to itself; if
present it executes it with `powershell -File` (already SYSTEM, so the commands inherit full
privilege) and deletes it. The client generates that one-shot to run your commands and append
their output to a results log it then reads back. That's the whole mechanism — a file-based
queue across a privilege boundary. Deliberately minimal, because everything here runs as SYSTEM.
