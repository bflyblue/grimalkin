#!/usr/bin/env bash

set -euo pipefail

: "${GRIMALKIN_WINDOWS_VM_NAME:?Set the GRIMALKIN_WINDOWS_VM_NAME repository variable}"
: "${GRIMALKIN_WINDOWS_RUNNER_SERVICE:?Set the GRIMALKIN_WINDOWS_RUNNER_SERVICE repository variable}"

if [[ ! "$GRIMALKIN_WINDOWS_VM_NAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "GRIMALKIN_WINDOWS_VM_NAME contains unsupported characters" >&2
  exit 1
fi
if [[ ! "$GRIMALKIN_WINDOWS_RUNNER_SERVICE" =~ ^actions\.runner\.[A-Za-z0-9._-]+$ ]]; then
  echo "GRIMALKIN_WINDOWS_RUNNER_SERVICE is not a valid Actions runner service name" >&2
  exit 1
fi

connection=${GRIMALKIN_WINDOWS_VM_CONNECTION:-qemu:///system}
vm=$GRIMALKIN_WINDOWS_VM_NAME
runner_service=$GRIMALKIN_WINDOWS_RUNNER_SERVICE
lease=${GRIMALKIN_WINDOWS_VM_LEASE:-/run/user/$(id -u)/grimalkin-windows-vm-last-active}

command -v virsh >/dev/null || {
  echo "Required Windows runner command is missing: virsh" >&2
  exit 1
}

# Keep the host watchdog from racing startup or the assignment gap before the
# dependent Windows job begins.
touch "$lease"

state=$(virsh --connect "$connection" domstate "$vm")
case "$state" in
  running)
    ;;
  paused)
    virsh --connect "$connection" resume "$vm"
    ;;
  "shut off"|crashed)
    virsh --connect "$connection" start "$vm"
    ;;
  *)
    echo "Cannot start the Windows runner VM from unexpected state: $state" >&2
    exit 1
    ;;
esac

guest_ready=false
for _ in {1..90}; do
  if virsh --connect "$connection" qemu-agent-command \
      "$vm" '{"execute":"guest-ping"}' >/dev/null 2>&1; then
    guest_ready=true
    break
  fi
  sleep 2
done
[[ "$guest_ready" == true ]] || {
  echo "The Windows runner VM did not become ready within three minutes" >&2
  exit 1
}

# Restart while this prerequisite job still owns the VM. The dependent Windows
# job cannot be assigned until this command completes.
runner_command="\$service = '$runner_service'; Stop-Service -Name \$service -Force -ErrorAction SilentlyContinue; (Get-Service -Name \$service).WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(30)); Get-Process -Name Runner.Listener,Runner.Worker -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Service -Name \$service; (Get-Service -Name \$service).WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds(30))"
runner_request='{"execute":"guest-exec","arguments":{"path":"C:\\Program Files\\PowerShell\\7\\pwsh.exe","arg":["-NoProfile","-NonInteractive","-Command","'"$runner_command"'"],"capture-output":true}}'
runner_response=$(virsh --connect "$connection" qemu-agent-command \
  "$vm" "$runner_request")
runner_pid=$(printf '%s' "$runner_response" |
  sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p')
[[ -n "$runner_pid" ]] || {
  echo "The guest agent did not start the Windows runner service" >&2
  exit 1
}

for _ in {1..60}; do
  guest_result=$(virsh --connect "$connection" qemu-agent-command \
    "$vm" "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":$runner_pid}}")
  if [[ "$guest_result" == *'"exited":true'* ]]; then
    if [[ "$guest_result" != *'"exitcode":0'* ]]; then
      echo "Windows runner service restart failed: $guest_result" >&2
      exit 1
    fi
    touch "$lease"
    sleep 15
    exit 0
  fi
  sleep 1
done

echo "Windows runner service restart timed out" >&2
exit 1
