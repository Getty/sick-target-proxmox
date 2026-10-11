# syntax=docker/dockerfile:1
#
# A real Proxmox VE API for t/e2e/device-proxmox.sh: the Debian packages of
# the no-subscription repository on debian:trixie, as in
# docs/real-node-trial.md, with pve-manager and the libraries the notes cite
# pinned. No kernel, no firmware, no systemd: pve-init.sh is PID 1 and runs
# the daemons as its children (PVE::Daemon backgrounds only when its parent
# is PID 1), and systemctl is a shim that does what the units' ExecReload
# does (pveproxy restart: HUP to the master).
#
#   docker build --label sick=1 -t sick-pmx-pve:9 t/e2e/pve
#
# Needs at run time: --cap-add SYS_ADMIN --device-cgroup-rule 'c 10:229 rwm'
# (pmxcfs mounts /etc/pve with FUSE; pve-init.sh makes /dev/fuse).

FROM debian:trixie
LABEL sick=1
ARG PVE_MANAGER=9.2.21
ARG PVE_CLUSTER=9.1.6
ARG PVE_ACCESS_CONTROL=9.1.2
ARG PVE_COMMON=9.2.3
ARG PVE_HTTP_SERVER=6.0.5
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl openssl procps \
 && curl -fsSL https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg \
      -o /usr/share/keyrings/proxmox-archive-keyring.gpg \
 && printf 'Types: deb\nURIs: http://download.proxmox.com/debian/pve\nSuites: trixie\nComponents: pve-no-subscription\nSigned-By: /usr/share/keyrings/proxmox-archive-keyring.gpg\n' \
      >/etc/apt/sources.list.d/pve.sources \
 && printf 'Package: proxmox-kernel* proxmox-default-kernel* pve-firmware* proxmox-firmware*\nPin: release *\nPin-Priority: -1\n' \
      >/etc/apt/preferences.d/no-kernel \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      "pve-manager=${PVE_MANAGER}" "pve-cluster=${PVE_CLUSTER}" "libpve-cluster-perl=${PVE_CLUSTER}" \
      "libpve-access-control=${PVE_ACCESS_CONTROL}" "libpve-common-perl=${PVE_COMMON}" \
      "libpve-http-server-perl=${PVE_HTTP_SERVER}" \
 && rm -rf /var/lib/apt/lists/* \
 && dpkg-query -W pve-manager pve-cluster libpve-access-control libpve-common-perl libpve-http-server-perl libnet-ssleay-perl
COPY --chmod=0755 pve-init.sh /usr/local/sbin/pve-init
COPY --chmod=0755 ctl.sh /usr/local/sbin/ctl.sh
COPY --chmod=0755 systemctl-shim.sh /usr/local/sbin/systemctl-shim
RUN dpkg-divert --local --rename --add /usr/bin/systemctl \
 && ln -s /usr/local/sbin/systemctl-shim /usr/bin/systemctl
CMD ["/usr/local/sbin/pve-init"]
