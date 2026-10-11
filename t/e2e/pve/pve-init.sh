#!/bin/sh
# PID 1 of the PVE container of t/e2e/device-proxmox.sh (docs/real-node-trial.md).
# PVE::Daemon starts in the background only when getppid() == 1, as under
# systemd; otherwise "start" calls systemctl. So this loop runs control
# commands as its direct children: "ID command args" written into
# /run/sick-ctl (ctl.sh does that and waits for the result).
[ -e /dev/fuse ] || mknod -m 666 /dev/fuse c 10 229
rm -f /run/sick-ctl
mkfifo -m 600 /run/sick-ctl
trap 'exit 0' TERM INT
while :; do
  if read -r id cmd </run/sick-ctl; then
    ( exec $cmd ) >"/run/sick-ctl-$id.out" 2>&1
    echo $? >"/run/sick-ctl-$id.rc"
  fi
done
