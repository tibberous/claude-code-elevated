# AdminHookPlunger

**The thing you grab when the elevation channel is clogged.**

Ships with [admin-hook-runner](../) and installs automatically when you install the runner as a
service. You normally never touch it — it's here so a wedged runner can always be recovered.

| | |
|---|---|
| kind | Windows SERVICE (NSSM, `LocalSystem`, Automatic) |
| endpoint | `http://127.0.0.1:5052` — loopback only |
| API | `GET /health` · `GET\|POST /unclog` (aliases `/plunger` `/plunge` `/un-clog`) |
| language | PowerShell, **zero dependencies** |
| sibling | `admin-hook-runner` — the thing this unclogs |

## Use it

```powershell
Invoke-RestMethod http://127.0.0.1:5052/unclog   # unclog: blank the queue + restart the runner
Invoke-RestMethod http://127.0.0.1:5052/health   # is the runner alive? anything stuck?
```

**Nothing is automatic.** You notice elevation is stuck, you grab the plunger, you use it.

## Why it exists

`AdminHookRunner` runs queued commands **synchronously, with no timeout**. So one hung command
wedges elevation for the whole machine — while NSSM still reports the service `Running` and the
heartbeat silently stops. Presence, not function.

This happened twice in one day while building it: a queued `Restart-Service` hit a service stuck in
`StopPending` and blocked — **elevation was dead for 3.5 hours** and nothing said so; the client
just timed out and quietly fell back to a limited token, which reads like a routing choice rather
than a failure. Later the same evening an MSI uninstall queued with `-Wait` did it again.

Both times the fix was `Stop-Process` as admin — **which needed the elevation that was broken** — so
a human had to run it by hand. This service exists to break that circle.

## >>> The one rule: it NEVER executes caller input <<<

> *"it's not a second drain, it's a plunger."*

Two fixed actions, no command / script / argument from any caller:

1. **blank the queue** — a file write, cannot hang
2. **restart the runner** — bounded by a timeout. *Never inherit the bug you exist to fix.*

If it could run commands it would **be** a second `AdminHookRunner`, would wedge identically, and
would need a plunger of its own. The asymmetry is the safety.

**And the real danger is the temptation, not the technique:**

> *"you are tempted to just clog AdminHookRunner and use the 'backup admin hook runner' to do
> anything besides fix the other one."*

A second executor turns *"the runner is clogged"* from a **failure you fix** into a **state you
route around**. The work still gets done, so nobody feels the outage, and the clog becomes
permanent and invisible — a fallback's worst cost is that it hides the broken thing. **If you are
ever tempted to add an endpoint here, that impulse is the bug.**

## Install / reinstall

The runner's `bootstrap.ps1` installs this for you in service mode. To (re)install or remove it on
its own:

```powershell
powershell -ExecutionPolicy Bypass -File bootstrap_plunger.ps1            # install
powershell -ExecutionPolicy Bypass -File bootstrap_plunger.ps1 -Uninstall # remove
```

Idempotent — it removes any existing registration first, so re-running is safe. It verifies by
**asking the service for `/health`**, not by trusting an exit code. Needs
[NSSM](https://nssm.cc) (`winget install NSSM.NSSM`), same as the runner.

## Two bugs found by testing it rather than trusting it

* `/health` called a **blanked** queue "stuck": `Set-Content -Encoding utf8` writes a 5-byte BOM, so
  `Length -gt 0` is true for an empty file. Test **content**, not length.
* `/unclog` reported *"restarted AdminHookRunner"* when the restart had been **denied** —
  `Receive-Job | Out-Null` swallowed the error. A plunger that lies about unclogging is worse than
  no plunger. It now proves the restart by requiring the **heartbeat timestamp to advance**.
