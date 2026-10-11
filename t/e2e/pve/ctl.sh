#!/bin/sh
# ctl.sh command args... (inside the PVE container): runs it as a child of
# PID 1 (pve-init.sh), waits, prints its output, exits with its code.
id=$$.$(date +%s%N)
echo "$id $*" >/run/sick-ctl
while [ ! -e "/run/sick-ctl-$id.rc" ]; do sleep 0.05; done
cat "/run/sick-ctl-$id.out"
rc=$(cat "/run/sick-ctl-$id.rc")
rm -f "/run/sick-ctl-$id".*
exit "$rc"
