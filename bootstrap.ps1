<#
  bootstrap.ps1 - installer / uninstaller for the SYSTEM elevation channel. Pure PowerShell,
  no dependencies (the runner is PowerShell too - nothing to install).

  THE CATCH-22 THIS SOLVES: the runner registers itself to run as SYSTEM, which itself needs
  admin. An AI agent runs as your normal user and can't clear a UAC prompt - so the FIRST
  install must be done by a human, once. After that the agent has a standing SYSTEM channel
  and never needs UAC again.

  RUN IT:
    - Double-click / "Run with PowerShell"            -> interactive menu
    - powershell -ExecutionPolicy Bypass -File bootstrap.ps1 -Mode task|service|uninstall
    Not elevated? It offers to relaunch itself as Administrator (accept the UAC prompt).

  >>> SECURITY: this grants an automated agent UNATTENDED SYSTEM (full admin) access to this
      machine with no further prompts. Install it only where you intend that. It is the point.
#>
param(
  [ValidateSet('task','service','uninstall')]
  [string]$Mode,
  [switch]$SkipTest   # skip the post-install self-test (for silent/scripted installs)
)
$ErrorActionPreference = 'Stop'

$Dest     = 'C:\services\admin-hook-runner'
$Runner   = "$Dest\admin_hook_runner.ps1"
$TaskName = 'AdminHookRunner'
$TaskPath = '\Monitor\'
$SvcName  = 'AdminHookRunner'

function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Say-NeedAdmin {
  Write-Host ""
  Write-Host "  [!] PERMISSION DENIED - this needs Administrator rights." -ForegroundColor Red
  Write-Host "      Close this window, RIGHT-CLICK PowerShell (or this script), choose" -ForegroundColor Yellow
  Write-Host "      'Run as administrator', and run it again." -ForegroundColor Yellow
  Write-Host ""
}

function Lay-Files {
  New-Item -ItemType Directory -Force -Path $Dest, "$Dest\logs" | Out-Null
  if ($PSScriptRoot -and ($PSScriptRoot -ne $Dest)) {
    foreach ($f in 'admin_hook_runner.ps1','run_elevated.py') {
      if (Test-Path "$PSScriptRoot\$f") { Copy-Item "$PSScriptRoot\$f" $Dest -Force }
    }
  }
  if (-not (Test-Path $Runner)) {
    throw "admin_hook_runner.ps1 not found in $Dest (run bootstrap.ps1 from the repo folder)."
  }
}

function Self-Test {
  $q = "$Dest\_sysfix.ps1"; $r = "$Dest\logs\_bootstrap_test.txt"
  Remove-Item $r -ErrorAction SilentlyContinue
  Set-Content -Path $q -Encoding utf8 -Value "`"whoami: `$(whoami)`" | Out-File -Encoding utf8 '$r'"
  Write-Host "  Self-test queued; waiting for the SYSTEM runner to execute it..."
  for ($i=0; $i -lt 45; $i++) { Start-Sleep 2; if ((Test-Path $r) -and -not (Test-Path $q)) { break } }
  if (Test-Path $r) {
    Write-Host ("  SELF-TEST OK -> " + (Get-Content $r -Raw).Trim()) -ForegroundColor Green
    Write-Host "  Elevation channel is LIVE. The agent's client now works with no UAC." -ForegroundColor Green
  } else {
    Write-Warning "  Self-test did not finish in time. Check the runner is installed and running."
  }
}

function Install-Task {
  Lay-Files
  $tr = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $Runner + '"'
  schtasks.exe /create /tn "$TaskPath$TaskName" /tr $tr /sc minute /mo 1 /ru SYSTEM /rl HIGHEST /f | Out-Null
  $t = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
  if (-not $t) { throw "Task did not register." }
  Write-Host ("  INSTALLED (scheduled task): {0}{1}  RunAs={2}  RunLevel={3}" -f `
    $t.TaskPath,$t.TaskName,$t.Principal.UserId,$t.Principal.RunLevel) -ForegroundColor Green
  if (-not $SkipTest) { Self-Test }
}

function Install-Service {
  $nssm = (Get-Command nssm.exe -ErrorAction SilentlyContinue).Source
  if (-not $nssm) {
    Write-Host "  Service mode uses NSSM (a service wrapper) and nssm.exe was not found." -ForegroundColor Yellow
    Write-Host "  Install it ( winget install NSSM  or  choco install nssm ) and re-run," -ForegroundColor Yellow
    Write-Host "  or choose the scheduled-task option instead (recommended, no extra deps)." -ForegroundColor Yellow
    return
  }
  Lay-Files
  & $nssm install $SvcName powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$Runner`" -Loop -Interval 3" | Out-Null
  & $nssm set $SvcName AppDirectory $Dest | Out-Null
  & $nssm set $SvcName Start SERVICE_AUTO_START | Out-Null
  & $nssm set $SvcName ObjectName LocalSystem | Out-Null   # LocalSystem == SYSTEM
  & $nssm start $SvcName | Out-Null
  Start-Sleep 2
  $s = Get-Service $SvcName -ErrorAction SilentlyContinue
  Write-Host ("  INSTALLED (service): {0}  Status={1}  RunAs=LocalSystem(SYSTEM)  loop@3s" -f `
    $SvcName, $s.Status) -ForegroundColor Green
  if (-not $SkipTest) { Self-Test }
}

function Uninstall-All {
  $removed = @()
  if (Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue) {
    schtasks.exe /delete /tn "$TaskPath$TaskName" /f | Out-Null
    $removed += "scheduled task $TaskPath$TaskName"
  }
  if (Get-Service $SvcName -ErrorAction SilentlyContinue) {
    $nssm = (Get-Command nssm.exe -ErrorAction SilentlyContinue).Source
    if ($nssm) { & $nssm stop $SvcName 2>$null | Out-Null; & $nssm remove $SvcName confirm 2>$null | Out-Null }
    else       { sc.exe stop $SvcName | Out-Null; sc.exe delete $SvcName | Out-Null }
    $removed += "service $SvcName"
  }
  Remove-Item "$Dest\_sysfix.ps1" -ErrorAction SilentlyContinue
  if ($removed.Count) {
    Write-Host ("  UNINSTALLED: " + ($removed -join ", ")) -ForegroundColor Green
    Write-Host "  (files in $Dest were left in place; delete the folder to remove them too.)"
  } else {
    Write-Host "  Nothing to uninstall - no AdminHookRunner task or service was found." -ForegroundColor Yellow
  }
}

function Show-Menu {
  Write-Host ""
  Write-Host "  AdminHookRunner - SYSTEM elevation channel installer" -ForegroundColor Cyan
  Write-Host "  ----------------------------------------------------"
  Write-Host "   1) Install as a SCHEDULED TASK   (recommended - runs SYSTEM every 60s, no deps)"
  Write-Host "   2) Install as a WINDOWS SERVICE  (instant-ish, ~3s; needs NSSM)"
  Write-Host "   3) UNINSTALL                     (removes the task and/or service)"
  Write-Host "   Q) Quit"
  Write-Host ""
  return (Read-Host "  Choose 1/2/3/Q")
}

# ---- entry ----
if (-not (Test-Admin)) {
  Write-Host ""
  Write-Host "  This installer needs Administrator rights (it registers a SYSTEM task/service)." -ForegroundColor Yellow
  Write-Host "  Relaunching elevated - please accept the UAC prompt..." -ForegroundColor Yellow
  try {
    $passArgs = @("-NoProfile","-ExecutionPolicy","Bypass","-File","`"$PSCommandPath`"")
    if ($Mode) { $passArgs += @("-Mode",$Mode) }
    Start-Process powershell -Verb RunAs -ArgumentList $passArgs
  } catch {
    Say-NeedAdmin
  }
  return
}

try {
  if (-not $Mode) {
    switch (Show-Menu) {
      '1' { $Mode = 'task' }
      '2' { $Mode = 'service' }
      '3' { $Mode = 'uninstall' }
      default { Write-Host "  Bye."; return }
    }
  }
  switch ($Mode) {
    'task'      { Install-Task }
    'service'   { Install-Service }
    'uninstall' { Uninstall-All }
  }
} catch {
  $msg = "$($_.Exception.Message)"
  if ($msg -match 'denied|Administrator|elevat|0x80070005') { Say-NeedAdmin }
  else { Write-Host "  ERROR: $msg" -ForegroundColor Red }
}
