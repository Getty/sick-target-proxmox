# syntax=docker/dockerfile:1
#
# The sick image of ../sick (sick:local, built from its docker/Dockerfile)
# with what SICK-Target-Proxmox needs on top: IO::Socket::SSL, HTTP::Tiny
# and Net::SSLeay as Debian trixie packages, and lib/ of this distribution
# beside SICK in site_perl. For t/e2e/device-proxmox.sh.
#
# Build context: the directory that holds the checkouts side by side
# (<context>/sick, <context>/sick-target-proxmox), as for ../sick:
#
#   docker build --label sick=1 -f sick-target-proxmox/t/e2e/sick/Dockerfile \
#     -t sick-pmx-sick:local <context>
#
# Dockerfile.dockerignore next to this file lets in lib/ of this
# distribution and nothing else.

ARG SICK_IMAGE=sick:local
FROM ${SICK_IMAGE}
LABEL sick=1
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates libhttp-tiny-perl libio-socket-ssl-perl libnet-ssleay-perl \
 && rm -rf /var/lib/apt/lists/*
COPY sick-target-proxmox/lib/ /usr/local/lib/site_perl/
RUN perl -MSICK::Target::ProxmoxVE -MSICK::Target::ProxmoxBS -MIO::Socket::SSL -MHTTP::Tiny -MNet::SSLeay \
      -e 'printf "SICK::Target::ProxmoxVE %s, IO::Socket::SSL %s, HTTP::Tiny %s, Net::SSLeay %s\n", SICK::Target::ProxmoxVE->VERSION, IO::Socket::SSL->VERSION, HTTP::Tiny->VERSION, Net::SSLeay->VERSION' \
 && dpkg-query -W libhttp-tiny-perl libio-socket-ssl-perl libnet-ssleay-perl perl openssl
