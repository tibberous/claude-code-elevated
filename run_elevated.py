#!/usr/bin/env python3
r"""run_elevated.py - run shell commands elevated (as NT AUTHORITY\SYSTEM) with no UAC each time.

Wraps the SYSTEM command queue, which lives ENTIRELY under C:\services\admin-hook-runner:
you drop commands into `_sysfix.ps1`, the `\Services\AdminHookRunner` scheduled task (SYSTEM,
/RL HIGHEST, every minute, hidden in session 0) runs each one via Invoke-Expression and writes
the result to `logs\run_elevated_result.log`, then blanks the queue. This hook writes the queue,
waits for the task to consume it, parses the log, and hands back per-command
{command, output, exit_code}.

>>> CORRECTED 2026-09-18. This paragraph used to say the queue was "built in C:\monitor +
C:\hooks", with the queue at C:\admin_commands.ps1, the log at C:\admin_commands.log and the
task called `AdminCommandQueue`. **Every one of those was wrong**, and C:\monitor has since been
DELETED, so a reader following this docstring went looking in a directory that does not exist.
The constants below were repointed to C:\services on 2026-09-14; this prose was not. Trent,
2026-09-18: *"c:/moniter is deleted now. look in c:/services"*. The task folder was renamed
\Monitor\ -> \Services\ at the same time, which was free because the task was not registered. <<<

Because the runner is SYSTEM, queued commands inherit full privileges (registry seizes,
protected-path edits, service installs, killing protected processes, etc.). The only popup is
the ONE-TIME UAC when the task is first registered; per-minute runs are invisible (session 0).

CLI (JSON out, like the other hooks):
    python run_elevated.py "Remove-Item 'C:\Windows\Temp\x' -Recurse -Force"
    python run_elevated.py "cmd one" "cmd two" "cmd three"     # each = its own elevated step
    python run_elevated.py --sep ";" "cmd1 ; cmd2 ; cmd3"      # split ONE string on ';'
    python run_elevated.py status                              # is the SYSTEM task installed?
    python run_elevated.py register                            # (re)register the task (one UAC)

Python:
    from run_elevated import run_elevated
    res = run_elevated(["whoami", "Get-Date"])     # -> [{command, output, exit_code}, ...]
    res = run_elevated("whoami")                   # single command -> same list (len 1)

SEPARATOR NOTE: do NOT use '|' to separate commands -- it is the PowerShell pipe. Pass a whole
pipeline as ONE command (one arg / one line). For multiple commands use separate args, newlines,
or --sep ";". By default a single string is treated as ONE command so pipelines stay intact.
"""
import json
import os
import re
import subprocess
import sys
import time

# Live channel (2026-06-16): the SYSTEM AdminHookRunner task runs C:\home\admin_hook_runner.py
# every ~60s, which executes a one-shot C:\home\_sysfix.ps1 (as SYSTEM) and then DELETES it.
# We drop a generated _sysfix.ps1 that runs each command and appends results to RESULT_LOG in
# the legacy [cmd]/output/>> Exited with code N format, so _parse_log() still works.
# Repointed 2026-09-14 from #1 (C:\home\admin_hook_runner.py) to #2 (C:\services\admin-hook-runner).
# #2 is the clean elevation-only primitive; #1 is being torn down. Same contract, new location.
SYSFIX = r"C:\services\admin-hook-runner\_sysfix.ps1"  # one-shot script the SYSTEM runner executes + deletes
LOG = r"C:\services\admin-hook-runner\logs\run_elevated_result.log"  # our generated script writes results here
QUEUE = SYSFIX                            # back-compat alias (status() reports pending = file exists)
POLLER = r"C:\services\admin-hook-runner\admin_hook_runner.py"  # the script the SYSTEM task actually runs
# install.ps1 DOES NOT EXIST - the installer is bootstrap.ps1 (corrected 2026-09-18).
REG_SCRIPT = r"C:\services\admin-hook-runner\bootstrap.ps1"  # elevated (re)registration; -Mode task
# Task Scheduler FOLDER, not a filesystem path - but it was named after C:\monitor, which is now
# deleted. Renamed \Monitor\ -> \Services\ on 2026-09-18 to match where the code actually lives.
# MUST stay in step with $TaskPath in bootstrap.ps1 - if they disagree, status() reports "absent"
# for a task that is registered, which is the confusing failure this comment exists to prevent.
TASK = r"\Services\AdminHookRunner"      # the live SYSTEM scheduled task name (full path)

_NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)


def _ps(args, timeout=60):
    """Run a non-elevated powershell call, return (returncode, stdout+stderr)."""
    p = subprocess.run(
        ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass"] + args,
        capture_output=True, text=True, timeout=timeout, creationflags=_NO_WINDOW,
    )
    return p.returncode, (p.stdout or "") + (p.stderr or "")


def _norm_commands(commands, sep=None):
    """Turn the caller's input into a clean list of command strings.

    list/tuple -> each element is one command.
    str        -> split on newlines if present, else on `sep` if given, else ONE command
                  (so a pipeline with '|' is preserved intact).
    """
    if isinstance(commands, (list, tuple)):
        items = [str(c) for c in commands]
    else:
        s = str(commands)
        if "\n" in s:
            items = s.split("\n")
        elif sep:
            items = s.split(sep)
        else:
            items = [s]
    return [c.strip() for c in items if c and c.strip()]


def _task_state():
    """'installed' | 'absent' | 'unknown' - CHECKS BOTH INSTALL MODES.

    >>> FIXED 2026-09-18. This used to query ONLY `schtasks`, so it reported "absent" for a
    runner that was installed and RUNNING the whole time - because bootstrap.ps1 offers
    `-Mode task|service` and this machine took the SERVICE. A status check that reports a
    working system as missing is worse than no status check: on 2026-09-18 it led to telling
    Trent that elevation needed a UAC prompt when `run_elevated.py "whoami"` was already
    returning `nt authority\\system`. Check the service FIRST - it is the installed shape here. <<<
    """
    rc, out = _ps(["-Command",
                   "(Get-Service -Name 'AdminHookRunner' -ErrorAction SilentlyContinue).Status"])
    if "running" in out.lower():
        return "installed (service)"

    rc, out = _ps(["-Command", f'schtasks /Query /TN "{TASK}" 2>&1'])
    low = out.lower()
    if "access is denied" in low or TASK.lower() in low:
        return "installed (task)"
    if "cannot find" in low or "does not exist" in low:
        # The other two sisters (Daemon Manager, Relay) live under \Monitor\, so a task-mode
        # install may still be sitting in the old folder. Look there before declaring absence.
        rc, out = _ps(["-Command", 'schtasks /Query /TN "\\Monitor\\AdminHookRunner" 2>&1'])
        low2 = out.lower()
        if "access is denied" in low2 or "adminhookrunner" in low2:
            return "installed (task, legacy \\Monitor\\ folder)"
        return "absent"
    return "unknown"


def register(wait_seconds=8):
    """(Re)register the SYSTEM task by self-elevating _reg_adminq.ps1. Pops ONE UAC prompt.
    Returns the resulting task state."""
    if not os.path.isfile(REG_SCRIPT):
        raise FileNotFoundError(f"registration script missing: {REG_SCRIPT}")
    _ps(["-Command",
         "Start-Process powershell -Verb RunAs -ArgumentList "
         f"'-NoProfile','-ExecutionPolicy','Bypass','-File','{REG_SCRIPT}'"])
    # the elevated child registers asynchronously; give the user a moment to approve UAC
    for _ in range(max(1, wait_seconds)):
        time.sleep(1)
        if _task_state() == "installed":
            break
    return {"task": TASK, "state": _task_state()}


def status():
    """Report whether the elevated queue is usable + the last logged run."""
    st = _task_state()
    last = ""
    try:
        with open(LOG, encoding="utf-8", errors="replace") as f:
            last = f.read()[-600:]
    except OSError:
        last = ""
    pending = False
    try:
        with open(QUEUE, encoding="utf-8", errors="replace") as f:
            pending = bool(f.read().strip())
    except OSError:
        pending = False
    return {"task": TASK, "state": st, "queue": QUEUE, "queue_has_pending": pending,
            "log_tail": last}


def _write_queue(cmds):
    """Generate the one-shot C:\\home\\_sysfix.ps1 that the SYSTEM runner will execute (as SYSTEM)
    and then delete. It runs each command and appends results to RESULT_LOG in the same
    [cmd] / output / >> Exited with code N format _parse_log() expects, truncating the log first
    so we read back only this run."""
    res = LOG.replace("\\", "\\\\")
    lines = [
        "$ErrorActionPreference = 'Continue'",
        f"$res = '{res}'",
        "New-Item -ItemType Directory -Force -Path (Split-Path $res) | Out-Null",
        "Set-Content -Path $res -Value '' -Encoding utf8",
        "function RunOne($c) {",
        "  Add-Content -Path $res -Value ('[' + $c + ']')",
        "  $global:LASTEXITCODE = 0",
        "  try { $o = (Invoke-Expression $c 2>&1 | Out-String); $code = $LASTEXITCODE }",
        "  catch { $o = ($_ | Out-String); $code = 1 }",
        "  if ([string]::IsNullOrWhiteSpace($o)) { $o = '(no output)' }",
        "  Add-Content -Path $res -Value $o.TrimEnd()",
        "  Add-Content -Path $res -Value ('>> Exited with code ' + [int]$code)",
        "}",
    ]
    for c in cmds:
        lit = "'" + c.replace("'", "''") + "'"   # single-quoted PS literal, doubled quotes
        lines.append(f"RunOne {lit}")
    with open(SYSFIX, "w", encoding="utf-8", newline="\r\n") as f:
        f.write("\n".join(lines) + "\n")


def _parse_log():
    """Parse C:\\admin_commands.log into [{command, output, exit_code}]."""
    try:
        with open(LOG, encoding="utf-8", errors="replace") as f:
            text = f.read()
    except OSError:
        return []
    blocks = []
    pat = re.compile(r"\[(?P<cmd>.*?)\]\r?\n(?P<out>.*?)\r?\n>> Exited with code (?P<code>-?\d+)",
                     re.DOTALL)
    for m in pat.finditer(text):
        out = m.group("out")
        if out.strip() == "(no output)":
            out = ""
        blocks.append({"command": m.group("cmd"),
                       "output": out.rstrip("\r\n"),
                       "exit_code": int(m.group("code"))})
    return blocks


def run_elevated(commands, sep=None, timeout=180, wait=True, ensure=True, poll=2.0):
    """Run one or more commands elevated as SYSTEM and return their results.

    commands : str (single command, or split on `sep`/newlines) or list[str].
    sep      : separator to split a single string on (e.g. ';'). Never use '|' (PS pipe).
    timeout  : max seconds to wait for the SYSTEM task to pick up the queue (it fires every ~60s).
    wait     : if False, just enqueue and return immediately (no results).
    ensure   : if the SYSTEM task is missing, register it first (one UAC prompt).

    Returns list[dict] {command, output, exit_code}, or {"queued": [...]} when wait=False.
    """
    cmds = _norm_commands(commands, sep)
    if not cmds:
        raise ValueError("no commands given")

    # The live AdminHookRunner task consumes _sysfix.ps1 regardless of how the task is named,
    # so we do NOT hard-fail on task detection; we just write the one-shot and wait for the
    # runner to consume it (the file is deleted after it runs).
    write_mtime = time.time()
    _write_queue(cmds)

    if not wait:
        return {"queued": cmds, "note": "runs within ~60s as SYSTEM; see " + LOG}

    deadline = time.time() + timeout
    consumed = False
    while time.time() < deadline:
        time.sleep(poll)
        # Consumed when the SYSTEM runner has deleted _sysfix.ps1 AND written a fresh result log.
        sysfix_gone = not os.path.isfile(SYSFIX)
        log_fresh = os.path.isfile(LOG) and os.path.getmtime(LOG) >= write_mtime - 1
        if sysfix_gone and log_fresh:
            consumed = True
            break

    if not consumed:
        raise TimeoutError(
            f"wrote {SYSFIX} with {len(cmds)} command(s) but the SYSTEM runner did not consume it "
            f"within {timeout}s (is the AdminHookRunner task enabled? try: python run_elevated.py status)")

    time.sleep(0.5)  # let the poller finish flushing the log
    results = _parse_log()
    # best-effort align to the commands we sent (poller logs them in order)
    return results[-len(cmds):] if len(results) >= len(cmds) else results


OPERATIONS = {"status": status, "register": register}


def main():
    argv = sys.argv[1:]
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(json.dumps({
            "ok": True,
            "usage": 'python run_elevated.py "<cmd>" ["<cmd>" ...] | status | register',
            "flags": {"--sep SEP": "split a single string into multiple commands",
                      "--timeout N": "max seconds to wait (default 180)",
                      "--no-wait": "enqueue and return immediately"},
            "note": "do NOT use '|' as a separator -- it is the PowerShell pipe",
        }, indent=2))
        sys.exit(0)

    if argv[0] in OPERATIONS and len(argv) == 1:
        try:
            print(json.dumps({"ok": True, "operation": argv[0], "result": OPERATIONS[argv[0]]()},
                             indent=2))
            sys.exit(0)
        except Exception as e:
            print(json.dumps({"ok": False, "operation": argv[0],
                              "error": f"{type(e).__name__}: {e}"}, indent=2))
            sys.exit(2)

    # parse flags, collect positional commands
    sep = None
    timeout = 180
    wait = True
    cmds = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--sep" and i + 1 < len(argv):
            sep = argv[i + 1]; i += 2; continue
        if a == "--timeout" and i + 1 < len(argv):
            timeout = int(argv[i + 1]); i += 2; continue
        if a == "--no-wait":
            wait = False; i += 1; continue
        cmds.append(a); i += 1

    payload = cmds[0] if len(cmds) == 1 else cmds
    try:
        result = run_elevated(payload, sep=sep, timeout=timeout, wait=wait)
        print(json.dumps({"ok": True, "result": result}, indent=2))
    except Exception as e:
        print(json.dumps({"ok": False, "error": f"{type(e).__name__}: {e}"}, indent=2))
        sys.exit(2)


if __name__ == "__main__":
    main()
