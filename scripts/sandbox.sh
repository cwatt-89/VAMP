#!/bin/bash
# VAMP Windows sandbox: drive the "Windows 11" VM from the Mac to test FloydNet Windows apps.
#
#   sandbox.sh status                 VM running? SSH up? who is signed in?
#   sandbox.sh ssh [command…]         PowerShell over SSH (interactive with no command)
#   sandbox.sh push <local> [remote]  copy a file or folder in (default C:\Sandbox\<name>)
#   sandbox.sh pull <remote> <local>  copy back out
#   sandbox.sh launch <exe> [args…]   start a GUI app on the signed-in desktop (not in the SSH session)
#   sandbox.sh kill <name>            stop a process by name
#   sandbox.sh shot <file.png>        screenshot the VM's screen
#   sandbox.sh snapshot <name>        save a live snapshot (RAM + disk)
#   sandbox.sh revert <name>          go back to a snapshot
#
# Env: VAMP_SANDBOX_VM (default 59c5595a), VAMP_SANDBOX_USER (default carterwatt), VAMP_SANDBOX_PORT (2222).
# SSH uses ~/.ssh/vamp_sandbox_ed25519 (key-only; the guest has it in administrators_authorized_keys).
set -euo pipefail

VM="${VAMP_SANDBOX_VM:-59c5595a}"
USER_="${VAMP_SANDBOX_USER:-carterwatt}"
PORT="${VAMP_SANDBOX_PORT:-2222}"
KEY="$HOME/.ssh/vamp_sandbox_ed25519"
RUN="/tmp/vamp-$VM"
VAMP_BIN="/Applications/VAMP.app/Contents/MacOS/VAMP"
SSH_OPTS=(-i "$KEY" -p "$PORT" -o BatchMode=yes -o ConnectTimeout=8 -o LogLevel=ERROR
          -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$HOME/.ssh/vamp_known_hosts")

die() { echo "sandbox: $*" >&2; exit 1; }
ps1() { ssh "${SSH_OPTS[@]}" "$USER_@127.0.0.1" "$@"; }

qmp() { # one HMP command over the VM's script control socket
  local sock="$RUN/ctl.sock"; [ -S "$sock" ] || sock="$RUN/qmp.sock" # ctl.sock: VMs started by newer VAMP builds
  python3 -I - "$sock" "$1" <<'EOF'
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.settimeout(120); s.connect(sys.argv[1]); f = s.makefile("rw")
f.readline(); f.write('{"execute":"qmp_capabilities"}\n'); f.flush(); f.readline()
f.write(json.dumps({"execute": "human-monitor-command", "arguments": {"command-line": sys.argv[2]}}) + "\n"); f.flush()
while True:
    r = json.loads(f.readline())
    if "return" in r or "error" in r: break
out = r.get("return", r.get("error"))
print(out if isinstance(out, str) else json.dumps(out))
sys.exit(1 if "error" in r or "rror" in str(out) else 0)
EOF
}

guest() { # run a --guest-script (screen/keyboard) against the VM's VNC socket
  local script; script=$(mktemp); printf '%s\n' "$1" > "$script"
  "$VAMP_BIN" --guest-script "$RUN/vnc.sock" "$script" "$2" >/dev/null; rm -f "$script"
}

cmd="${1:-status}"; shift || true
case "$cmd" in
  status)
    [ -S "$RUN/vnc.sock" ] && pgrep -f "qemu-system.*vamp-$VM" >/dev/null && echo "VM: running" || { echo "VM: stopped"; exit 1; }
    if ps1 'Write-Output "SSH: up ($env:COMPUTERNAME)"; $u = (query user 2>$null | Select-Object -Skip 1) -join "; "; Write-Output ("Desktop: " + ($(if ($u) { $u.Trim() } else { "nobody signed in" })))'; then :; else echo "SSH: down"; fi ;;
  ssh)
    if [ $# -eq 0 ]; then ssh -t "${SSH_OPTS[@]}" "$USER_@127.0.0.1"; else ps1 "$*"; fi ;;
  push)
    [ $# -ge 1 ] || die "push <local> [remote]"
    src="$1"; dst="${2:-C:/Sandbox/$(basename "$src")}"
    ps1 "New-Item -ItemType Directory -Force -Path (Split-Path '$dst') | Out-Null"
    scp -r -q -i "$KEY" -P "$PORT" -o BatchMode=yes -o LogLevel=ERROR -o UserKnownHostsFile="$HOME/.ssh/vamp_known_hosts" "$src" "$USER_@127.0.0.1:$dst"
    echo "pushed → $dst" ;;
  pull)
    [ $# -eq 2 ] || die "pull <remote> <local>"
    scp -r -q -i "$KEY" -P "$PORT" -o BatchMode=yes -o LogLevel=ERROR -o UserKnownHostsFile="$HOME/.ssh/vamp_known_hosts" "$USER_@127.0.0.1:$1" "$2" ;;
  launch)
    [ $# -ge 1 ] || die "launch <exe> [args…]"
    exe="$1"; shift; args="$*"
    # SSH runs in a hidden service session; an interactive scheduled task puts the window on the user's desktop.
    ps1 "\$a = New-ScheduledTaskAction -Execute '$exe' $( [ -n "$args" ] && echo "-Argument '$args'" );
         \$p = New-ScheduledTaskPrincipal -UserId '$USER_' -LogonType Interactive -RunLevel Highest;
         Register-ScheduledTask -TaskName VAMPSandboxLaunch -Action \$a -Principal \$p -Force | Out-Null;
         Start-ScheduledTask -TaskName VAMPSandboxLaunch; Start-Sleep 1;
         Unregister-ScheduledTask -TaskName VAMPSandboxLaunch -Confirm:\$false; 'launched $exe'" ;;
  kill)
    [ $# -eq 1 ] || die "kill <process name>"
    ps1 "Stop-Process -Name '$1' -Force -ErrorAction SilentlyContinue; 'stopped $1'" ;;
  shot)
    [ $# -eq 1 ] || die "shot <file.png>"
    out="$(cd "$(dirname "$1")" && pwd)"; name="$(basename "$1" .png)"
    guest "shot $name" "$out"; echo "$out/$name.png" ;;
  snapshot)
    [ $# -eq 1 ] || die "snapshot <name>"
    qmp "savevm $1" || die "snapshot failed (quit the VAMP app or use its Snapshots tab)"; echo "saved $1" ;;
  revert)
    [ $# -eq 1 ] || die "revert <name>"
    qmp "loadvm $1" || die "revert failed (quit the VAMP app or use its Snapshots tab)"; echo "reverted to $1" ;;
  *) sed -n '2,16p' "$0"; exit 1 ;;
esac
