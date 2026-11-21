# Installs or updates VAMP Tools (shared clipboard + clock sync with the Mac). No downloads: compiles
# VAMPTools.cs with the C# compiler built into Windows. The VAMP channel only opens for elevated
# processes, so VAMP Tools starts at every sign-in from a scheduled task with highest privileges
# (no UAC prompt each time). Safe to run again: it compiles first and changes nothing if that fails.
param([switch]$NoStart)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
  # One UAC prompt for a manual install; VAMP's automatic setup and self-updates already run elevated.
  $p = Start-Process powershell -Verb RunAs -Wait -PassThru -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$($MyInvocation.MyCommand.Path)`"")
  exit $p.ExitCode
}
$dest = Join-Path $env:ProgramFiles 'VAMP Tools'
$exe = Join-Path $dest 'VAMPTools.exe'
$task = 'VAMP Tools'

# 1. Compile to a temporary file. If this fails, the installed agent is untouched.
$new = Join-Path $env:TEMP ("VAMPTools-" + [guid]::NewGuid().ToString('N') + ".exe")
Add-Type -TypeDefinition (Get-Content -Raw -LiteralPath (Join-Path $here 'VAMPTools.cs')) `
  -ReferencedAssemblies System, System.Drawing, System.Windows.Forms, System.Management `
  -OutputAssembly $new -OutputType WindowsApplication

# 2. Stop the running agent. Stop the task first: an instance it still counts as running (e.g. one that
#    crashed) would make the next start a no-op.
Stop-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
for ($i = 0; $i -lt 30 -and (Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue).State -eq 'Running'; $i++) { Start-Sleep -Milliseconds 500 }
Get-Process VAMPTools -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
for ($i = 0; $i -lt 20 -and (Get-Process VAMPTools -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 250 }
# Earlier per-user builds of VAMP Tools.
Remove-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'VAMP Tools' -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $env:LOCALAPPDATA 'VAMP Tools\VAMPTools.exe') -Force -ErrorAction SilentlyContinue

# 3. Swap in the new build and its source (the agent compares that source with CD 2 to self-update).
New-Item -ItemType Directory -Force -Path $dest | Out-Null
Move-Item -LiteralPath $new -Destination $exe -Force
Copy-Item -LiteralPath (Join-Path $here 'VAMPTools.cs') -Destination $dest -Force

# 4. Start at every sign-in, for whoever signs in, elevated; restart if it ever exits unexpectedly.
$action = New-ScheduledTaskAction -Execute $exe
$trigger = New-ScheduledTaskTrigger -AtLogOn
$principal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Highest   # BUILTIN\Users, each in their own session
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances Parallel -Priority 4 -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName $task -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null

# 5. Start it in the signed-in session now, and make sure it's really up.
if (-not $NoStart) {
  for ($try = 0; $try -lt 4 -and -not (Get-Process VAMPTools -ErrorAction SilentlyContinue); $try++) {
    Start-ScheduledTask -TaskName $task
    for ($i = 0; $i -lt 20 -and -not (Get-Process VAMPTools -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 500 }
  }
}
Write-Output "VAMP Tools installed: $exe"
