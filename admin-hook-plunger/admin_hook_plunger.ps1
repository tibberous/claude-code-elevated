<#
  admin_hook_plunger.ps1 - the PLUNGER for AdminHookRunner. Pure PowerShell, ZERO dependencies.

  ============================================================================
  WHY THIS EXISTS - the circular dependency it breaks
  ============================================================================
  AdminHookRunner is the SYSTEM elevation primitive: you drop a script into
  _sysfix.ps1 and its drain loop executes it as SYSTEM every ~3 seconds.

  Its drain is a BLOCKING call with no timeout:
        & powershell.exe -File $Queue      # inside while($true)
  So ONE hung queued command wedges the whole loop forever. The service still
  reports Running (NSSM keeps the wrapper alive), the heartbeat silently stops,
  and every later command queues up behind a corpse.

  >>> AND THE RECOVERY REQUIRED ELEVATION, WHICH WAS THE THING THAT WAS BROKEN. <<<
  That happened TWICE on 2026-09-20:
    13:07  a queued `Restart-Service bthserv -Force` hit a StopPending Bluetooth
           service and blocked. Elevation was dead for 3.5 HOURS. Nobody noticed:
           run_elevated just timed out, and ps_hook quietly fell back to
           "[ran via: local (limited token)]", which reads like a routing choice.
    19:09  Claude queued an MSI uninstall with -Wait. Same wedge, same day.
  Both times the fix was `Stop-Process -Id <hung> -Force`, which needs admin,
  which needs the elevation channel, which was the thing that was broken. Trent
  had to run it by hand from his own shell. Both times.

  The plunger is the way out of that circle: a SEPARATE SYSTEM service whose only
  job is to unclog the first one.

  ============================================================================
  >>> THE ONE DESIGN RULE: IT NEVER EXECUTES CALLER INPUT. <<<
  ============================================================================
  Trent, 2026-09-20: *"the plunger is cool because it cant 'clog', unless the
  restart hangs. But its not a second drain, its a plunger."*

  That is the whole point and it must not erode. This service accepts NO command,
  NO script, NO path, NO argument from any caller. It does exactly two fixed,
  bounded things:
        1. BLANK the queue file  (a file write - cannot hang)
        2. RESTART AdminHookRunner  (bounded by a timeout, below)

  If it ever grew a "run this for me" endpoint it would BE a second
  AdminHookRunner, would wedge the identical way, and would need a plunger of its
  own. The asymmetry IS the safety: the general executor can clog; the thing that
  rescues it cannot, because it has nothing general to do.

  >>> AND THE REAL DANGER IS NOT TECHNICAL, IT IS THE TEMPTATION. <<<
  Trent, 2026-09-20: *"that way you are tempted to just clog AdminHookRunner and
  use the 'backup admin hook runner' to do anything besides fix the other one."*

  A second executor turns "AdminHookRunner is clogged" from a FAILURE YOU FIX into
  a STATE YOU ROUTE AROUND. The work still gets done, so nobody feels the outage -
  and the clog becomes permanent and invisible, because there is a working path.
  That is exactly rule 4e in how_to_write_hooks.md: NOT DYING IS A FALLBACK, and
  the worst cost of a fallback is that IT HIDES THE BROKEN THING. You do not have
  redundancy, you have one working path and a corpse you are still paying for.

  So the restriction is not caution about this service hanging. It is that a
  plunger which can do work WILL be used for work, and then the elevation channel
  quietly rots behind it. Keeping it unable to execute anything keeps "the runner
  is clogged" an event that must be RESOLVED rather than one that can be endured.
  **If you are ever tempted to add an endpoint here, that impulse is the bug.**

  ============================================================================
  API - loopback only
  ============================================================================
      GET  http://127.0.0.1:5052/health    is the plunger alive? is the drain alive?
      GET  http://127.0.0.1:5052/unclog    blank the queue + restart the runner
      POST http://127.0.0.1:5052/unclog    same

  /health reports on the RUNNER, which is the interesting part: heartbeat age,
  whether the queue has stuck content, and the service state. Heartbeat age > ~15s
  means the drain is wedged.

  Run:  powershell -ExecutionPolicy Bypass -File admin_hook_plunger.ps1 -Loop
  Installed as a Windows service by bootstrap_plunger.ps1 (NSSM, SYSTEM, Automatic).
#>
param(
  [switch]$Loop,
  [int]$Port = 5052,
  [int]$RestartTimeoutSec = 30
)

$RunnerDir     = 'C:\services\admin-hook-runner'
$RunnerQueue   = Join-Path $RunnerDir '_sysfix.ps1'
$RunnerBeat    = Join-Path $RunnerDir 'logs\heartbeat.txt'
$RunnerService = 'AdminHookRunner'
$LogPath       = Join-Path $PSScriptRoot 'logs\plunger.log'

function Write-PlungerLog($msg) {
  try {
    New-Item -ItemType Directory -Force -Path (Split-Path $LogPath) | Out-Null
    # truncate-on-start semantics are handled at startup; this only appends within a run
    Add-Content -Path $LogPath -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $msg)
  } catch {}
}

function Get-RunnerHealth {
  # Everything here is a READ. Nothing in /health can block.
  $beatAge = $null
  $beatTxt = ''
  try {
    if (Test-Path $RunnerBeat) {
      $beatTxt = (Get-Content $RunnerBeat -Raw -ErrorAction Stop).Trim()
      $beatAge = [int]((Get-Date) - (Get-Item $RunnerBeat).LastWriteTime).TotalSeconds
    }
  } catch {}

  # >>> TEST CONTENT, NOT LENGTH. <<< A BLANKED queue is not an empty FILE: Set-Content with
  # -Encoding utf8 writes a 5-byte BOM, so `Length -gt 0` reports a freshly-drained queue as
  # stuck. Caught on the plunger's very first live /health, 2026-09-20. The queue is "pending"
  # only if it holds non-whitespace TEXT - which is exactly what run_elevated.status() does
  # (bool(f.read().strip())). Same trap, same answer, two languages.
  $queueBytes = -1
  $queueText  = ''
  try {
    if (Test-Path $RunnerQueue) {
      $queueBytes = (Get-Item $RunnerQueue).Length
      $queueText  = (Get-Content $RunnerQueue -Raw -ErrorAction SilentlyContinue)
      if ($null -eq $queueText) { $queueText = '' }
    }
  } catch {}

  $svc = 'unknown'
  try { $svc = (Get-Service $RunnerService -ErrorAction Stop).Status.ToString() } catch {}

  # THE ACTUAL DIAGNOSIS. The service saying "Running" is worthless on its own - NSSM keeps the
  # wrapper alive while the loop inside it is dead. A stale heartbeat is the real signal.
  # $null on the LEFT on purpose - PowerShell's -ne unrolls arrays on the right, so
  # `$x -ne $null` can return a filtered collection instead of a boolean (PSScriptAnalyzer
  # PSPossibleIncorrectComparisonWithNull).
  $wedged = ($null -ne $beatAge -and $beatAge -gt 15)
  [pscustomobject]@{
    plunger_ok         = $true
    runner_service     = $svc
    heartbeat_age_s    = $beatAge
    heartbeat          = $beatTxt
    queue_bytes        = $queueBytes
    queue_has_stuck_cmd= (-not [string]::IsNullOrWhiteSpace($queueText))
    wedged             = $wedged
    verdict            = if ($wedged) { 'WEDGED - call /unclog' } else { 'healthy' }
  }
}

function Invoke-Unclog {
  $steps = @()

  # 1) BLANK THE QUEUE FIRST, and this order matters. If the runner restarts while a poisoned
  #    command still sits in the queue, the fresh loop picks it straight back up and wedges
  #    again - an unclog that re-clogs. Clear the cause, then restart.
  try {
    if (Test-Path $RunnerQueue) {
      $was = (Get-Item $RunnerQueue).Length
      Set-Content -Path $RunnerQueue -Value '' -Encoding utf8 -ErrorAction Stop
      $steps += "blanked queue (was $was bytes)"
    } else {
      # keep the invariant: the file must ALWAYS exist so a human can find and type into it
      Set-Content -Path $RunnerQueue -Value '' -Encoding utf8 -ErrorAction Stop
      $steps += 'queue file was missing - recreated blank'
    }
  } catch { $steps += "blank FAILED: $($_.Exception.Message)" }

  # 2) Kill any powershell the drain left hung. This is what actually frees the loop - the
  #    blocking `& powershell.exe -File $Queue` returns the moment its child dies.
  #    Narrow on purpose: only powershell whose command line names the runner's queue file.
  try {
    $killed = 0
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop |
      Where-Object { $_.CommandLine -and $_.CommandLine -like "*_sysfix.ps1*" } |
      ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop; $killed++ } catch {} }
    $steps += "killed $killed hung drain child(ren)"
  } catch { $steps += "child sweep FAILED: $($_.Exception.Message)" }

  # 3) Restart the runner - BOUNDED. This is the only step that can hang, which is why the
  #    plunger has a timeout where AdminHookRunner does not. Never inherit the bug you exist to fix.
  # >>> VERIFY THE RESTART BY EVIDENCE. DO NOT REPORT WHAT YOU DID NOT WATCH HAPPEN. <<<
  # The first version of this said `Receive-Job | Out-Null` and then appended "restarted
  # AdminHookRunner" unconditionally. Run as a non-admin it was DENIED and still reported
  # success - a plunger that lies about unclogging is worse than no plunger, because you stop
  # looking. Caught on its first live /unclog, 2026-09-20, by noticing the heartbeat timestamp
  # was IDENTICAL before and after.
  # The proof is the heartbeat: the runner writes it every ~3s, and a genuine restart makes the
  # process (and its heartbeat) start fresh. So capture it BEFORE, then require it to MOVE.
  $beatBefore = ''
  try { if (Test-Path $RunnerBeat) { $beatBefore = (Get-Item $RunnerBeat).LastWriteTime.ToString('o') } } catch {}
  try {
    $job = Start-Job -ScriptBlock { param($n) Restart-Service -Name $n -Force -ErrorAction Stop } -ArgumentList $RunnerService
    if (Wait-Job $job -Timeout $RestartTimeoutSec) {
      $jobErr = $job.ChildJobs[0].Error
      Receive-Job $job -ErrorAction SilentlyContinue | Out-Null
      if ($jobErr -and $jobErr.Count) {
        $steps += "restart FAILED: $($jobErr[0].ToString())"
      } else {
        # give the fresh loop one tick to write a new heartbeat, then CHECK it moved
        Start-Sleep -Seconds 5
        $beatAfter = ''
        try { if (Test-Path $RunnerBeat) { $beatAfter = (Get-Item $RunnerBeat).LastWriteTime.ToString('o') } } catch {}
        if ($beatAfter -and $beatAfter -ne $beatBefore) {
          $steps += 'restarted AdminHookRunner - VERIFIED (heartbeat advanced)'
        } else {
          $steps += 'restart reported OK but heartbeat did NOT advance - drain may still be dead'
        }
      }
    } else {
      Stop-Job $job -ErrorAction SilentlyContinue
      $steps += "restart TIMED OUT after ${RestartTimeoutSec}s - service may need manual attention"
    }
    Remove-Job $job -Force -ErrorAction SilentlyContinue
  } catch { $steps += "restart FAILED: $($_.Exception.Message)" }

  Write-PlungerLog ('unclog: ' + ($steps -join ' | '))
  [pscustomobject]@{ unclogged = $true; steps = $steps; after = (Get-RunnerHealth) }
}

function Send-Json($ctx, $obj, $code = 200) {
  $json  = $obj | ConvertTo-Json -Depth 6
  $bytes = [Text.Encoding]::UTF8.GetBytes($json)
  $ctx.Response.StatusCode  = $code
  $ctx.Response.ContentType = 'application/json'
  $ctx.Response.ContentLength64 = $bytes.Length
  $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
  $ctx.Response.OutputStream.Close()
}

# ---------------------------------------------------------------- serve
try { New-Item -ItemType Directory -Force -Path (Split-Path $LogPath) | Out-Null } catch {}
Set-Content -Path $LogPath -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  plunger starting') -ErrorAction SilentlyContinue

# >>> SINGLE INSTANCE, ENFORCED TWICE - and the second check is not redundant. <<<
# 1. SCM guarantees one instance OF THE SERVICE: a service name is unique, Windows will not
#    start a second. That is the real guarantee and it is why this runs as a service at all.
# 2. But nothing stops a human (or Claude) running this .ps1 BY HAND while the service is up,
#    and HttpListener does NOT fail on a port clash - HTTP.sys lets both register, then hands
#    each request to whichever it feels like. So two instances both "work", and half your
#    requests hit the old code.
#    That is exactly what happened on 2026-09-20: a fix was edited, the script relaunched, and
#    the OLD instance kept answering /health - so a correct fix looked broken and got
#    re-debugged. Silent, nondeterministic, and it wastes the time of whoever is chasing it.
# So: if anything already answers on this port, DIE LOUDLY rather than become the second one.
try {
  $probe = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/health" -UseBasicParsing -TimeoutSec 3
  if ($probe.StatusCode -eq 200) {
    Write-Error ("A plunger is ALREADY answering on port $Port. Refusing to start a second " +
      "instance - HttpListener would share the port and requests would hit either one at random. " +
      "If you meant to restart it:  Restart-Service AdminHookPlunger")
    exit 1
  }
} catch { }   # no answer = nothing there = good, carry on

$listener = New-Object System.Net.HttpListener
# LOOPBACK ONLY. This endpoint restarts a SYSTEM service; it must never be reachable off-box.
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Start()
Write-PlungerLog "listening on http://127.0.0.1:$Port/  (/health, /unclog)"

while ($true) {
  try {
    $ctx  = $listener.GetContext()
    $path = $ctx.Request.Url.AbsolutePath.ToLower().TrimEnd('/')
    switch ($path) {
      '/health'  { Send-Json $ctx (Get-RunnerHealth) }
      ''         { Send-Json $ctx (Get-RunnerHealth) }
      # all three spellings do the same thing - you are reaching for a plunger, not
      # remembering an API. Whichever word comes to mind should work.
      '/unclog'  { Send-Json $ctx (Invoke-Unclog) }
      '/un-clog' { Send-Json $ctx (Invoke-Unclog) }
      '/plunger' { Send-Json $ctx (Invoke-Unclog) }
      '/plunge'  { Send-Json $ctx (Invoke-Unclog) }
      default    { Send-Json $ctx @{ error = 'not found'; endpoints = @('/health','/unclog') } 404 }
    }
  } catch {
    # A single bad request must never take the plunger down - it is the last line of defence.
    Write-PlungerLog "request error: $($_.Exception.Message)"
  }
  if (-not $Loop) { break }
}
