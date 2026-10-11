#!/bin/sh
# /usr/bin/systemctl in the PVE container (no systemd). Logs every call and
# maps the pveproxy/pvedaemon jobs to what the Exec* lines of their units
# run, as children of PID 1. Everything else fails, as systemctl without
# systemd does.
echo "$(date +%T.%N) systemctl $*" >>/var/log/systemctl-shim.log
case "$1 $2" in
  "reload-or-restart pveproxy" | "reload pveproxy") exec /usr/local/sbin/ctl.sh /usr/bin/pveproxy restart ;;
  "reload-or-restart pvedaemon" | "reload pvedaemon") exec /usr/local/sbin/ctl.sh /usr/bin/pvedaemon restart ;;
  "start pveproxy" | "start pvedaemon") exec /usr/local/sbin/ctl.sh "/usr/bin/$2" start ;;
  *) echo "systemctl shim: not handled: $*" >&2; exit 1 ;;
esac
