<#
  bootstrap_plunger.ps1 - install AdminHookPlunger as a SYSTEM Windows service.

  Mirrors how AdminHookRunner is installed (NSSM, LocalSystem, Automatic) so the two behave
  identically and there is one pattern to remember, not two.

  WHY A SCRIPT AND NOT A ONE-LINER: the nssm install line needs nested quotes around the
  -File path, and that string has to survive bash -> run_elevated -> the queue file ->
  PowerShell. It does not. Putting it in a FILE and executing the file removes every layer
  of quoting at once. (Learned the hard way, 2026-09-20.)

  It is also what a bare-box restore needs: recreating this service has to be possible from
  "here is the script", not "here is a command someone has to retype correctly".

  RUN (elevated):
      powershell -ExecutionPolicy Bypass -File bootstrap_plunger.ps1
      powershell -ExecutionPolicy Bypass -File bootstrap_plunger.ps1 -Uninstall
#>
param([switch]$Uninstall)

$SvcName = 'AdminHookPlunger'
# NSSM location. winget installs nssm.exe to the per-user WinGet\Links shim dir; if it was
# installed some other way, fall back to whatever is on PATH. (No hardcoded user path - this
# must resolve under any profile name.)
$Nssm = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\nssm.exe'
if (-not (Test-Path $Nssm)) { $c = Get-Command nssm.exe -ErrorAction SilentlyContinue; if ($c) { $Nssm = $c.Source } }
$PsExe   = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
$Script  = 'C:\services\admin-hook-plunger\admin_hook_plunger.ps1'
$LogDir  = 'C:\services\admin-hook-plunger\logs'

function Say($m) { Write-Output ((Get-Date -Format 'HH:mm:ss') + '  ' + $m) }

if (-not (Test-Path $Nssm))   { Say "MISSING nssm: $Nssm"; exit 1 }
if (-not (Test-Path $Script)) { Say "MISSING script: $Script"; exit 1 }
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

# --- uninstall path -------------------------------------------------------
if ($Uninstall) {
  & sc.exe stop   $SvcName 2>&1 | Out-Null
  Start-Sleep 2
  & $Nssm remove  $SvcName confirm 2>&1 | Out-Null
  Say ("removed (state now: " + ((Get-Service $SvcName -ErrorAction SilentlyContinue).Status) + ")")
  exit 0
}

# --- install / reinstall --------------------------------------------------
# Remove first so this is idempotent - re-running must not fail or stack two registrations.
if (Get-Service $SvcName -ErrorAction SilentlyContinue) {
  Say 'existing service found - removing first so this is idempotent'
  & sc.exe stop  $SvcName 2>&1 | Out-Null
  Start-Sleep 2
  & $Nssm remove $SvcName confirm 2>&1 | Out-Null
  Start-Sleep 2
}

$appArgs = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Loop' -f $Script

& $Nssm install $SvcName $PsExe $appArgs      2>&1 | Out-Null
& $Nssm set $SvcName Start      SERVICE_AUTO_START   2>&1 | Out-Null
& $Nssm set $SvcName ObjectName LocalSystem          2>&1 | Out-Null
& $Nssm set $SvcName AppStdout  (Join-Path $LogDir 'nssm_out.log') 2>&1 | Out-Null
& $Nssm set $SvcName AppStderr  (Join-Path $LogDir 'nssm_err.log') 2>&1 | Out-Null
& $Nssm set $SvcName Description 'Unclogs AdminHookRunner. Blanks its queue and restarts it. Executes NOTHING a caller supplies.' 2>&1 | Out-Null

Start-Service $SvcName -ErrorAction SilentlyContinue
Start-Sleep 4

# >>> VERIFY BY EVIDENCE, not by exit code. <<< Report what is actually true.
$svc = Get-CimInstance Win32_Service -Filter "Name='$SvcName'" -ErrorAction SilentlyContinue
if (-not $svc) { Say 'INSTALL FAILED - no service registered'; exit 1 }
Say ("state   : " + $svc.State)
Say ("runs as : " + $svc.StartName)
Say ("start   : " + $svc.StartMode)

# The real proof is that it ANSWERS, not that Windows says Running.
try {
  $r = Invoke-WebRequest -Uri 'http://127.0.0.1:5052/health' -UseBasicParsing -TimeoutSec 8
  Say ('health  : HTTP ' + $r.StatusCode + '  ' + ($r.Content -replace '\s+', ' '))
} catch {
  Say ('health  : NO ANSWER - ' + $_.Exception.Message)
}
