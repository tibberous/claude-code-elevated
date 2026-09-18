---
name: run-elevated
description: Run a command as NT AUTHORITY\SYSTEM (full admin) on this Windows box. Claude Code has NO native elevation - it runs as the normal user - but this machine has a standing SYSTEM channel you can use. REACH FOR THIS the instant a command needs admin: HKLM registry edits, protected folders (Program Files, ProgramData, Windows), scheduled-task create/delete, killing protected processes, service installs - OR the instant your normal shell returns "Access is denied" or a schtasks query gives a false "cannot find". Do not report a dead end; you can already do it.
---

# run-elevated - you CAN run as SYSTEM. Stop forgetting it.

**The failure this fixes:** you have a working SYSTEM channel, you forget it exists, you fall back
to your limited-token shell, it returns a false "Access is denied" / "task not found", and you
report "I can't / a human has to." Same shape as the Cloudflare/browse-web reflex. A permission
wall is the TRIGGER to switch tools, not an outcome to announce.

## Use it

```
C:\python314\pythonw.exe C:\hooks\run_elevated.py "<one command>"
C:\python314\pythonw.exe C:\hooks\run_elevated.py "cmd one" "cmd two"   # each = its own SYSTEM step
C:\python314\pythonw.exe C:\hooks\run_elevated.py status                # is the channel installed?
```

Returns JSON: `{ok, result:[{command, output, exit_code}]}`. The command runs as SYSTEM, so it
inherits full privilege. **Latency ~60s** (a scheduled task drains the queue once a minute; ~3s if
installed in service mode). Do NOT use `|` to separate commands - that's the PowerShell pipe; pass
a whole pipeline as ONE command.

## When to reach for it (non-exhaustive)

- Registry under **HKLM** (read or write), or another user's HKCU.
- **Protected paths**: `C:\Program Files*`, `C:\ProgramData`, `C:\Windows`, another user's profile.
- **Scheduled tasks**: create / delete / query. Your normal shell's limited token gives a FALSE
  "cannot find the file specified" on SYSTEM tasks - use run_elevated to see/manage them for real.
- **Killing protected processes**, installing/removing **services**, seizing file/registry ACLs.

## The mechanism (so you trust it)

`run_elevated.py` is a client. It writes a one-shot `_sysfix.ps1` into a queue folder; a runner
registered to run as **SYSTEM** (`\Services\AdminHookRunner`, a scheduled task, or an
NSSM service) executes it and deletes it, appending results to a log the client reads back.
The runner + installer live at **`C:\services\admin-hook-runner\`** (its own repo).

## If the channel is NOT installed

`run_elevated.py status` says `state: absent`, or every call times out with the queue never
drained -> the SYSTEM task isn't there. This is the one thing you CANNOT bootstrap yourself
(registering a SYSTEM task needs admin, which needs a UAC click you can't make). Ask the human to
run, ONCE, in an **Administrator** PowerShell:

```
powershell -ExecutionPolicy Bypass -File "C:\services\admin-hook-runner\bootstrap.ps1" -Mode task
```

After that, elevation is standing and unattended - no more UAC. To remove it later: same script,
`-Mode uninstall`.

## Doctrine

Before saying "I can't" or "you'll have to do this as admin," check whether you already have the
tool. On this machine you do. Reach for `run_elevated` reflexively; treat "needs admin" as
"call run_elevated", not as a dead end.
