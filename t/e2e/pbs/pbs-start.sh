#!/bin/sh
# PID 1 (behind docker's --init) of the PBS container of
# t/e2e/device-proxmox.sh: proxmox-backup-api as root, then
# proxmox-backup-proxy as "backup", as their units start them (Type=notify,
# User=backup for the proxy); docs/real-node-trial.md. /run/proxmox-backup
# is a tmpfs owned by backup (the run-proxmox\x2dbackup.mount of the
# package), given with --tmpfs.
B=/usr/lib/x86_64-linux-gnu/proxmox-backup
mkdir -p /var/log/proxmox-backup
"$B/proxmox-backup-api" >>/var/log/pbs-api.log 2>&1 &
api=$!
# the api makes proxy.pem and proxy.key at its first start; the proxy needs them
for _ in $(seq 1 100); do
  [ -s /etc/proxmox-backup/proxy.pem ] && [ -s /etc/proxmox-backup/proxy.key ] && break
  sleep 0.2
done
sleep 1
setpriv --reuid=backup --regid=backup --init-groups "$B/proxmox-backup-proxy" >>/var/log/pbs-proxy.log 2>&1 &
trap 'kill $api $! 2>/dev/null; exit 0' TERM INT
wait
