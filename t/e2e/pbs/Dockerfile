# syntax=docker/dockerfile:1
#
# A real Proxmox Backup Server for t/e2e/device-proxmox.sh: the Debian
# packages of the no-subscription repository on debian:trixie, as in
# docs/real-node-trial.md, with the version pinned. No kernel, no firmware,
# no systemd: pbs-start.sh starts the two daemons the way their units do.
#
#   docker build --label sick=1 -t sick-pmx-pbs:4 t/e2e/pbs

FROM debian:trixie
LABEL sick=1
ARG PBS_VERSION=4.2.8-1
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl openssl procps \
 && curl -fsSL https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg \
      -o /usr/share/keyrings/proxmox-archive-keyring.gpg \
 && printf 'Types: deb\nURIs: http://download.proxmox.com/debian/pbs\nSuites: trixie\nComponents: pbs-no-subscription\nSigned-By: /usr/share/keyrings/proxmox-archive-keyring.gpg\n' \
      >/etc/apt/sources.list.d/pbs.sources \
 && printf 'Package: proxmox-kernel* proxmox-default-kernel* pve-firmware* proxmox-firmware*\nPin: release *\nPin-Priority: -1\n' \
      >/etc/apt/preferences.d/no-kernel \
 && apt-get update \
 && apt-get install -y --no-install-recommends "proxmox-backup-server=${PBS_VERSION}" \
 && rm -rf /var/lib/apt/lists/* \
 && dpkg-query -W proxmox-backup-server
COPY --chmod=0755 pbs-start.sh /usr/local/sbin/pbs-start
CMD ["/usr/local/sbin/pbs-start"]
