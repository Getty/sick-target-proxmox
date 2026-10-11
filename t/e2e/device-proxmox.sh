#!/bin/bash
#
# SICK-Target-Proxmox end to end: the device types proxmox-ve and proxmox-bs
# in the sick image, against a REAL Proxmox VE API (pve-manager 9.2.21) and
# a REAL Proxmox Backup Server (4.2.8-1) in containers, with the lab CA of
# ../sick (step-ca and its init-ca.sh). The nodes are built and started as
# in docs/real-node-trial.md: Debian trixie, the no-subscription packages,
# no kernel, no systemd. PVE runs pmxcfs (local mode), pvedaemon and
# pveproxy as children of a small PID 1 (t/e2e/pve/pve-init.sh), and
# systemctl is a shim that does what the unit's ExecReload does (HUP to the
# pveproxy master): restart behaviour is "with the shim", not "under
# systemd". PBS runs proxmox-backup-api and -proxy as packaged.
#
# Plain docker, no Compose: network, volumes and containers are named
# sick-pmx-* and labelled sick=1; nothing is published. The PVE container
# gets --cap-add SYS_ADMIN and --device-cgroup-rule 'c 10:229 rwm' and makes
# /dev/fuse itself (pmxcfs mounts /etc/pve with FUSE; the lab host has no
# /dev/fuse to hand in) - the grant --device /dev/fuse would give, nothing
# more: no --privileged, no host network, no published port.
#
# What it proves, each with PASS/FAIL lines; the first FAIL ends it with 1:
#
#   1. images: sick:local from ../sick, sick-pmx-sick:local on top of it
#      (trixie IO::Socket::SSL, HTTP::Tiny, this lib/), sick-pmx-pbs:4 and
#      sick-pmx-pve:9 from t/e2e/{pbs,pve}; versions recorded
#   2. the unit suite of this distribution passes inside sick-pmx-sick:local
#      (Debian's Perl modules, not the ones of the developer machine)
#   3. up: the lab CA is healthy; PBS and PVE answer on 8007/8006 with their
#      own certificates; tokens made with the commands of decision 4, the
#      secrets parsed from the JSON of the CLI straight into 0600 files;
#      the PVE cluster CA copied out with docker cp, the PBS fingerprint
#      read with proxmox-backup-manager cert info - the out-of-band anchors
#   4. sick check before: both foreign-ca; no POST in the access logs
#   5. sick run: both renewed, exit 0; while it runs, no /proc/*/cmdline or
#      /proc/*/environ in the sick container holds a secret (counted)
#   6. 8006 and 8007 present the issued certificate (device record), and it
#      verifies with the lab root under the host name; PVE settles on it
#      (sampled after the restart); exactly one POST per node, status 200
#   7. a second sick run: unchanged, no new POST
#   8. wrong token: failed with 401, the port unchanged
#   9. wrong pin (fingerprint only): failed before any request, the message
#      names the fingerprint the node presents; no new line in the access log
#  10. the way back: DELETE with curl -H @file --cacert; PVE presents its
#      pve-ssl.pem again, PBS a new self-signed one; sick check: foreign-ca;
#      the stale PBS pin fails without a request, PVE (cluster CA) renews
#  11. no secret in the output of sick, the device records, the logs of the
#      nodes and the CA, or docker inspect of any container
#  12. teardown, also after a failure or Ctrl-C: containers, volumes and the
#      network with sick=1 AND a name sick-pmx-* are removed and checked to
#      be gone; images stay as a cache; nothing else is touched, no prune
#
# Prerequisites: Docker with BuildKit, perl and openssl on this machine; the
# checkouts side by side: <dir>/sick, <dir>/sick-target-ciscosb (for the
# sick image) and <dir>/sick-target-proxmox (this one); the internet for the
# images and the Proxmox packages at the first build (PVE: about 3 minutes).
#
# Parameters, all from the environment:
#
#   SICK_PMX_DIR    private working directory, mode 0700
#                   ($HOME/.local/share/sick-lab/pmx-e2e)
#   SICK_PMX_KEEP   "yes": keep the working directory at the end        (no)
#
# Secrets: the API tokens are made on the nodes at run time; the CLI's JSON
# goes through a pipe into a parser that writes the secret into a 0600 file,
# which reaches the sick container through a root-owned volume. Never on a
# command line, never printed; checks count hits and print the count only.

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
context=$(cd "$repo/.." && pwd)
sick_repo=$context/sick

work=${SICK_PMX_DIR:-$HOME/.local/share/sick-lab/pmx-e2e}
keep=${SICK_PMX_KEEP:-no}

p=sick-pmx
net=$p-net
pve=pve1.example.internal
pbs=pbs1.example.internal
step_image=smallstep/step-ca:0.30.2
pve_access=/var/log/pveproxy/access.log
pbs_access=/var/log/proxmox-backup/api/access.log

started=$SECONDS
passes=0
step_no=0
step() { step_no=$((step_no + 1)); printf '\n=== %s. %s (t+%ss)\n' "$step_no" "$*" "$((SECONDS - started))"; }
note() { printf -- '--- %s\n' "$*"; }
pass() { passes=$((passes + 1)); printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*" >&2; exit 1; }
show() { sed 's/^/    /'; }
# expect <what> <extended regular expression> <text>
expect() {
  if grep -Eq -- "$2" <<<"$3"; then pass "$1"; else
    printf '%s\n' "$3" | sed 's/^/      | /' >&2
    fail "$1 (expected /$2/)"
  fi
}
# same <what> <expected> <observed>
same() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }

umask 077
mkdir -p "$work"
chmod 700 "$work"
work=$(cd "$work" && pwd)
case $work/ in "$context"/*) fail "SICK_PMX_DIR $work lies inside the build context $context" ;; esac

#### teardown, armed before anything exists

# ours: label sick=1 and a name sick-pmx-*; nothing else is ever removed
ours() { # <container|volume|network>
  case $1 in
    container) docker ps -a --filter label=sick=1 --format '{{.Names}}' ;;
    volume) docker volume ls --filter label=sick=1 --format '{{.Name}}' ;;
    network) docker network ls --filter label=sick=1 --format '{{.Name}}' ;;
  esac | grep -E "^$p-" || true
}
remove_ours() {
  local names
  names=$(ours container)
  [ -z "$names" ] || docker rm -f $names >/dev/null 2>&1
  names=$(ours volume)
  [ -z "$names" ] || docker volume rm $names >/dev/null 2>&1
  names=$(ours network)
  [ -z "$names" ] || docker network rm $names >/dev/null 2>&1
  return 0
}
cleanup() {
  local rc=$? left
  trap - EXIT INT TERM
  set +e
  printf '\n=== teardown\n'
  remove_ours
  left=$(for kind in container volume network; do ours $kind | sed "s/^/$kind /"; done)
  if [ -n "$left" ]; then
    printf '%s\n' "$left" | sed 's/^/      | /' >&2
    printf 'FAIL  left behind (listed above)\n' >&2
    rc=1
  else
    pass "no container, volume or network sick-pmx-* with sick=1 is left"
  fi
  if [ "$keep" = yes ]; then
    note "working directory $work kept (SICK_PMX_KEEP=yes)"
  else
    rm -rf "${work:?}"/{secrets,anchors,sick.yml,build,logs}
    rmdir "$work" 2>/dev/null
  fi
  printf '\n%s PASS lines, %ss\n' "$passes" "$((SECONDS - started))"
  if [ "$rc" -eq 0 ]; then printf 'ALL PASSED\n'; else printf 'FAILED (exit %s)\n' "$rc" >&2; fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for program in docker perl openssl; do command -v "$program" >/dev/null || fail "$program is not installed"; done
for dir in sick/lib sick-target-ciscosb/lib sick-target-proxmox/lib; do
  [ -d "$context/$dir" ] || fail "no $dir in $context: the checkouts belong side by side"
done
# what an interrupted run left behind goes first
remove_ours
rm -rf "${work:?}"/{secrets,anchors,sick.yml,build,logs}
mkdir -p "$work/build" "$work/logs" "$work/secrets" "$work/anchors"

#### helpers that need the containers

# sick <arguments>: one run of sick, as the sick service of ../sick runs
# (read-only, no capability, /tmp in memory); output in $out, exit in $code
all_out=
sick_args=(--label sick=1 --network "$net" --init --read-only --cap-drop ALL
  --security-opt no-new-privileges:true --tmpfs /tmp:mode=0700,size=16m
  -v "$p-state:/var/lib/sick" -v "$p-handover:/etc/sick/ca:ro" -v "$p-secrets:/etc/sick/secrets:ro"
  -v "$work/sick.yml:/etc/sick/sick.yml:ro" -v "$work/anchors:/etc/sick/anchors:ro")
sick() {
  set +e
  out=$(docker run --rm --name "$p-run" "${sick_args[@]}" "$p-sick:local" sick "$@" 2>&1)
  code=$?
  set -e
  all_out+=$out$'\n'
  note "sick $* (exit $code)"
  show <<<"$out"
}
in_client() { docker exec "$p-client" sh -c "$1"; }
# fingerprint <host> <port>: SHA-256 of the leaf presented there, lower-case hex
fingerprint() {
  in_client "openssl s_client -connect $1:$2 -servername $1 </dev/null 2>/dev/null | openssl x509 -noout -fingerprint -sha256" 2>/dev/null \
    | sed -n 's/^sha256 Fingerprint=//Ip' | tr -d ':' | tr 'A-F' 'a-f'
}
# verified <host> <port>: the verify result against the lab root under the host name
verified() {
  in_client "openssl s_client -connect $1:$2 -servername $1 -CAfile /etc/sick/ca/root_ca.crt -verify_hostname $1 -verify_return_error </dev/null 2>&1" \
    | sed -n 's/^ *Verify return code: //p' | head -n 1
}
# sample <host> <port> <seconds>: "ms fingerprint" per new TLS connection, every 0.2 s
sample() {
  in_client "start=\$(date +%s%N); while :; do now=\$(date +%s%N); ms=\$(( (now - start) / 1000000 )); [ \$ms -gt $(($3 * 1000)) ] && break;
    f=\$(openssl s_client -connect $1:$2 -servername $1 </dev/null 2>/dev/null | openssl x509 -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//; s/://g' | tr A-F a-f);
    echo \"\$ms \${f:-none}\"; sleep 0.2; done"
}
# settled <expected> <samples> <last ms>: every sample of the last <ms> is <expected>
settled() {
  awk -v want="$1" -v last="$3" '{ ms[NR] = $1; fp[NR] = $2 } END {
      if (NR == 0) exit 1; end = ms[NR]; for (i = 1; i <= NR; i++) if (ms[i] >= end - last && fp[i] != want) exit 1 }' <<<"$2"
}
transitions() { awk '{ if ($2 != last) { printf "t+%sms %s  ", $1, substr($2, 1, 8); last = $2 } } END { print "(" NR " samples)" }' <<<"$1"; }
# posts <pve|pbs> [status]: POSTs to .../certificates/custom in the access log of the node
posts() {
  local log=$pve_access
  [ "$1" = pbs ] && log=$pbs_access
  docker exec "$p-$1" cat "$log" | grep -E '"POST /api2/json/nodes/[^/ ]+/certificates/custom[ "]' \
    | { if [ -n "${2:-}" ]; then grep -E "\" $2 "; else cat; fi; } | grep -c . || true
}
issued() {
  docker run --rm --label sick=1 --name "$p-read" -v "$p-state:/var/lib/sick:ro" --entrypoint cat "$p-sick:local" "/var/lib/sick/devices/$1.json" 2>/dev/null \
    | perl -MJSON::PP -0777 -ne 'my $r = eval { decode_json($_) } or exit; print lc( ( ( $r->{last_issue} || {} )->{fingerprint_sha256} // q{} ) =~ s/://gr )'
}
# secret_from_json <file>: reads the output of a token command on stdin, writes
# its "value" into <file> (mode 0600) and nothing anywhere else
secret_from_json() {
  perl -MJSON::PP -0777 -e '
    my $text = <STDIN>; $text =~ s/\A[^{]*//;
    my $v = eval { decode_json($text)->{value} };
    exit 3 unless defined $v && $v =~ /\A[\x21-\x7e]+\z/;
    open my $fh, ">", $ARGV[0] or exit 4; print {$fh} $v, "\n"; close $fh or exit 4;' "$1"
}
# put_secret <name>: the 0600 file of the work dir into the root-owned secrets volume
put_secret() {
  docker run --rm -i --label sick=1 --name "$p-put" --network none -v "$p-secrets:/s" --entrypoint sh "$p-sick:local" \
    -c 'umask 077; cat >"/s/$1"' sh "$1" <"$work/secrets/$1"
}
# hits <text>: how many of the secrets occur in it (count only)
hits() { grep -cFf <(cat "$work"/secrets/*.token) <<<"$1" || true; }

#### 1. images

step 'images: sick:local, sick-pmx-sick:local, sick-pmx-pbs:4, sick-pmx-pve:9'
build() { # <log> <docker build arguments>
  local log=$work/build/$1
  shift
  docker build --label sick=1 "$@" >"$log" 2>&1 || { tail -30 "$log" >&2; fail "docker build $*"; }
}
build sick.log --build-arg STEP_VERSION=0.30.2 --build-arg SICK_FROM=local -f "$sick_repo/docker/Dockerfile" -t sick:local "$context"
pass 'sick:local is built from ../sick (and ../sick-target-ciscosb)'
build pmx-sick.log -f "$here/sick/Dockerfile" -t "$p-sick:local" "$context"
pass "$p-sick:local adds the trixie packages and lib/ of this distribution"
build pbs.log -t "$p-pbs:4" "$here/pbs"
pass "$p-pbs:4 is built"
build pve.log -t "$p-pve:9" "$here/pve"
pass "$p-pve:9 is built"
docker image inspect "$step_image" >/dev/null 2>&1 || docker pull -q "$step_image" >/dev/null || fail "cannot pull $step_image"
note 'versions'
{
  for image in sick:local "$p-sick:local" "$p-pbs:4" "$p-pve:9"; do
    printf '%s %s\n' "$image" "$(docker image inspect -f '{{.Id}}' "$image")"
  done
  printf '%s %s\n' "$step_image" "$(docker image inspect -f '{{join .RepoDigests " "}}' "$step_image")"
  docker run --rm --label sick=1 --name "$p-ver" --network none --entrypoint step-ca "$step_image" version | head -n 1
  docker run --rm --label sick=1 --name "$p-ver" --network none --entrypoint sh "$p-sick:local" -c '
    sick --version; openssl version
    perl -MIO::Socket::SSL -MHTTP::Tiny -MNet::SSLeay -e "printf qq{perl %vd, IO::Socket::SSL %s, HTTP::Tiny %s, Net::SSLeay %s\n}, \$^V, IO::Socket::SSL->VERSION, HTTP::Tiny->VERSION, Net::SSLeay->VERSION"
    dpkg-query -W libio-socket-ssl-perl libhttp-tiny-perl libnet-ssleay-perl'
  docker run --rm --label sick=1 --name "$p-ver" --network none --entrypoint dpkg-query "$p-pbs:4" -W proxmox-backup-server
  docker run --rm --label sick=1 --name "$p-ver" --network none --entrypoint dpkg-query "$p-pve:9" -W \
    pve-manager pve-cluster libpve-access-control libpve-common-perl libpve-http-server-perl libnet-ssleay-perl
} 2>&1 | show

#### 2. the unit suite in the trixie image

step "the unit suite inside $p-sick:local"
set +e
unit=$(docker run --rm --label sick=1 --name "$p-unit" --network none --entrypoint sh -e PERL5LIB=/src/sick/lib \
  --tmpfs /tmp:mode=1777 -v "$sick_repo/lib:/src/sick/lib:ro" -v "$repo/lib:/src/pmx/lib:ro" -v "$repo/t:/src/pmx/t:ro" \
  -w /src/pmx "$p-sick:local" -c 'prove -lr t' 2>&1)
unit_rc=$?
set -e
show <<<"$unit"
same 'prove -lr t passes with the Perl modules of Debian trixie' 0 "$unit_rc"

#### 3. up

step 'up: lab CA, PBS, PVE, a client'
docker network create --label sick=1 "$net" >/dev/null
for v in ca handover state secrets; do docker volume create --label sick=1 "$p-$v" >/dev/null; done
# the ca service of ../sick/docker/compose.yml, without the published port
docker run -d --name "$p-ca" --label sick=1 --network "$net" --network-alias ca --user 0:0 \
  --entrypoint /bin/bash \
  -e 'SICK_CA_NAME=SICK Proxmox Test CA' -e SICK_CA_DNS= -e SICK_CA_MAX_LIFETIME=19800h \
  -e SICK_CA_ACME_LIFETIME=720h -e SICK_CA_ACME_MAX_LIFETIME=2160h -e SICK_CA_ACME_MIN_LIFETIME=5m \
  -e SICK_CA_ACME_CHALLENGES= -e 'SICK_CA_ALLOW_DNS=*.example.internal' -e SICK_CA_ALLOW_IP= \
  -e SICK_CA_ALLOW_EMAIL= -e SICK_CA_ALLOW_URI= \
  -v "$p-ca:/home/step" -v "$p-handover:/handover" -v "$sick_repo/docker/init-ca.sh:/usr/local/bin/init-ca.sh:ro" \
  "$step_image" /usr/local/bin/init-ca.sh >/dev/null
docker run -d --name "$p-pbs" --label sick=1 --init --network "$net" \
  --hostname pbs1 --domainname example.internal --dns-search example.internal --network-alias "$pbs" \
  --tmpfs /run/proxmox-backup:rw,nosuid,nodev,mode=755,uid=34,gid=34 "$p-pbs:4" >/dev/null
docker run -d --name "$p-pve" --label sick=1 --network "$net" \
  --hostname pve1 --domainname example.internal --dns-search example.internal --network-alias "$pve" \
  --cap-add SYS_ADMIN --device-cgroup-rule 'c 10:229 rwm' "$p-pve:9" >/dev/null
docker run -d --name "$p-client" --label sick=1 --network "$net" --init --read-only --cap-drop ALL \
  --security-opt no-new-privileges:true --tmpfs /tmp:mode=0700,size=1m \
  -v "$p-handover:/etc/sick/ca:ro" -v "$p-secrets:/etc/sick/secrets:ro" \
  --entrypoint sleep "$p-sick:local" infinity >/dev/null

# PVE: what the units would start, as children of PID 1 (docs/real-node-trial.md)
for _ in $(seq 1 50); do docker exec "$p-pve" test -p /run/sick-ctl 2>/dev/null && break; sleep 0.2; done
docker exec "$p-pve" ctl.sh pmxcfs >"$work/logs/pve-boot.log" 2>&1 || fail 'pmxcfs did not start'
# its ssh part fails (no ssh in the image); the certificates are what counts
docker exec "$p-pve" ctl.sh pvecm updatecerts --force >>"$work/logs/pve-boot.log" 2>&1 || true
docker exec "$p-pve" test -s /etc/pve/local/pve-ssl.pem || fail 'pvecm updatecerts made no pve-ssl.pem'
docker exec "$p-pve" ctl.sh pvedaemon start >>"$work/logs/pve-boot.log" 2>&1 || fail 'pvedaemon did not start'
docker exec "$p-pve" ctl.sh pveproxy start >>"$work/logs/pve-boot.log" 2>&1 || fail 'pveproxy did not start'

wait_for() { # <seconds> <what> <command ...>
  local seconds=$1 what=$2 start=$SECONDS
  shift 2
  until "$@" >/dev/null 2>&1; do
    [ $((SECONDS - start)) -lt "$seconds" ] || fail "waited ${seconds}s for $what"
    sleep 1
  done
}
wait_for 90 'the lab CA' in_client 'test -s /etc/sick/ca/root_ca.crt && curl -fsS -o /dev/null --cacert /etc/sick/ca/root_ca.crt https://ca:9000/health'
pass 'the lab CA is healthy and handed over its root'
wait_for 60 'PBS on 8007' in_client "openssl s_client -connect $pbs:8007 </dev/null"
pass 'PBS answers TLS on 8007'
wait_for 60 'PVE on 8006' in_client "openssl s_client -connect $pve:8006 </dev/null"
pass 'PVE answers TLS on 8006'
published=$(docker ps --format '{{.Names}} {{.Ports}}' | grep -E "^$p-" | grep -E '(->|0\.0\.0\.0|::)' || true)
[ -z "$published" ] || fail "published ports: $published"
pass 'no port is published'

# the out-of-band anchors: the cluster CA of PVE (docker cp; pmxcfs is a
# FUSE mount docker cp cannot see, so it is copied to a plain file first),
# the fingerprint of PBS as its CLI shows it
docker exec "$p-pve" cp /etc/pve/pve-root-ca.pem /root/pve-root-ca.pem
docker cp "$p-pve:/root/pve-root-ca.pem" "$work/anchors/pve-root-ca.pem" >/dev/null
chmod 755 "$work/anchors"
chmod 644 "$work/anchors/pve-root-ca.pem"
openssl x509 -in "$work/anchors/pve-root-ca.pem" -noout -subject | grep -q 'PVE Cluster Manager CA' \
  || fail 'the copied pve-root-ca.pem is not the cluster CA'
pass 'the cluster CA of PVE is copied out with docker cp'
pbs_pin=$(docker exec "$p-pbs" proxmox-backup-manager cert info | sed -n 's/^Fingerprint (sha256): *//p')
[[ $pbs_pin =~ ^([0-9a-f]{2}:){31}[0-9a-f]{2}$ ]] || fail "no fingerprint in proxmox-backup-manager cert info"
pbs_self=$(tr -d : <<<"$pbs_pin")
same 'PBS presents the self-signed certificate cert info shows' "$pbs_self" "$(fingerprint "$pbs" 8007)"
pve_self=$(docker exec "$p-pve" openssl x509 -in /etc/pve/local/pve-ssl.pem -noout -fingerprint -sha256 | sed 's/.*=//; s/://g' | tr A-F a-f)
same 'PVE presents its pve-ssl.pem' "$pve_self" "$(fingerprint "$pve" 8006)"

# tokens, with the commands of decision 4; the CLI's JSON into the parser
expire=$(($(date +%s) + 86400))
docker exec "$p-pve" sh -c "
  pveum user add sick@pve --comment 'SICK certificate upload' &&
  pveum role add SICKCertificate --privs Sys.Modify &&
  pveum acl modify /nodes/pve1 --roles SICKCertificate --users sick@pve" >>"$work/logs/pve-boot.log" 2>&1 \
  || fail 'pveum user/role/acl'
docker exec "$p-pve" pveum user token add sick@pve sick --privsep 1 --expire "$expire" --comment SICK --output-format json 2>/dev/null \
  | secret_from_json "$work/secrets/pve.token" || fail 'pveum user token add: no secret in its output'
docker exec "$p-pve" pveum acl modify /nodes/pve1 --roles SICKCertificate --tokens 'sick@pve!sick' >>"$work/logs/pve-boot.log" 2>&1 \
  || fail 'pveum acl modify --tokens'
docker exec "$p-pbs" proxmox-backup-manager user create sick@pbs --comment 'SICK certificate upload' >/dev/null 2>&1 \
  || fail 'proxmox-backup-manager user create'
docker exec "$p-pbs" proxmox-backup-manager user generate-token sick@pbs sick --expire "$expire" --comment SICK 2>/dev/null \
  | secret_from_json "$work/secrets/pbs.token" || fail 'proxmox-backup-manager user generate-token: no secret in its output'
docker exec "$p-pbs" sh -c "
  proxmox-backup-manager acl update /system/certificates Admin --auth-id sick@pbs &&
  proxmox-backup-manager acl update /system/certificates Admin --auth-id 'sick@pbs!sick'" >/dev/null 2>&1 \
  || fail 'proxmox-backup-manager acl update'
cat /proc/sys/kernel/random/uuid >"$work/secrets/wrong.token"
for f in pve pbs wrong; do
  [ "$(stat -c %a "$work/secrets/$f.token")" = 600 ] || fail "$f.token is not mode 0600"
  put_secret "$f.token"
done
pass 'tokens made on the nodes; secrets in 0600 files and the secrets volume, never printed'

zero=$(printf '0%.0s' $(seq 1 64))
cat >"$work/sick.yml" <<EOF
# Generated by t/e2e/device-proxmox.sh. Neutral names only.
ca:
  name: SICK Proxmox Test CA
  url: https://ca:9000
  root: /etc/sick/ca/root_ca.crt
  intermediates: /etc/sick/ca/intermediate_ca.crt
  provisioner: sick
  password_file: /etc/sick/ca/provisioner.pw
defaults:
  lifetime: 397d
  renew_before: 30d
  key: rsa2048
devices:
  pve:
    type: proxmox-ve
    host: $pve
    port: 8006
    names: [$pve]
    node: pve1
    token_id: sick@pve!sick
    token_file: /etc/sick/secrets/pve.token
    ca: [/etc/sick/anchors/pve-root-ca.pem, /etc/sick/ca/root_ca.crt]
  pbs:
    type: proxmox-bs
    host: $pbs
    port: 8007
    names: [$pbs]
    token_id: sick@pbs!sick
    token_file: /etc/sick/secrets/pbs.token
    fingerprint: '$pbs_pin'
    ca: /etc/sick/ca/root_ca.crt
  # the same nodes with what goes wrong
  pve-badtoken:
    type: proxmox-ve
    host: $pve
    port: 8006
    names: [$pve]
    node: pve1
    token_id: sick@pve!sick
    token_file: /etc/sick/secrets/wrong.token
    ca: /etc/sick/ca/root_ca.crt
  pbs-badtoken:
    type: proxmox-bs
    host: $pbs
    port: 8007
    names: [$pbs]
    token_id: sick@pbs!sick
    token_file: /etc/sick/secrets/wrong.token
    ca: /etc/sick/ca/root_ca.crt
  pve-badpin:
    type: proxmox-ve
    host: $pve
    port: 8006
    names: [$pve]
    node: pve1
    token_id: sick@pve!sick
    token_file: /etc/sick/secrets/pve.token
    fingerprint: '$zero'
  pbs-badpin:
    type: proxmox-bs
    host: $pbs
    port: 8007
    names: [$pbs]
    token_id: sick@pbs!sick
    token_file: /etc/sick/secrets/pbs.token
    fingerprint: '$zero'
EOF
chmod 644 "$work/sick.yml"

#### 4. before

step 'sick check before: the nodes present their own certificates'
sick check pve pbs
expect 'pve is foreign-ca' '^pve +.*foreign-ca' "$out"
expect 'pbs is foreign-ca' '^pbs +.*foreign-ca' "$out"
same 'no POST in the access log of PVE' 0 "$(posts pve)"
same 'no POST in the access log of PBS' 0 "$(posts pbs)"

#### 5. the first run, watched from inside

step 'sick run: both devices; /proc of the sick container watched meanwhile'
docker run -d --name "$p-run1" "${sick_args[@]}" "$p-sick:local" sick run --verbose pve pbs >/dev/null
# every 0.1 s: each cmdline and environ of every process of the container,
# searched for the secrets (the patterns come from the files, -f); counts only
probe='h=0; n=0; for f in /proc/[0-9]*/cmdline /proc/[0-9]*/environ; do
  [ -r "$f" ] || continue; n=$((n + 1))
  if grep -qaFf /etc/sick/secrets/pve.token -f /etc/sick/secrets/pbs.token "$f" 2>/dev/null; then h=$((h + 1)); fi
done; s=$(grep -l "bin/[s]ick" /proc/[0-9]*/cmdline 2>/dev/null | wc -l); echo "$h $n $s"'
scans=0 files=0 found=0 with_sick=0
while [ "$(docker inspect -f '{{.State.Running}}' "$p-run1" 2>/dev/null)" = true ]; do
  r=$(docker exec "$p-run1" sh -c "$probe" 2>/dev/null) || break
  read -r h n s <<<"$r"
  scans=$((scans + 1)) files=$((files + n)) found=$((found + h))
  [ "${s:-0}" -gt 0 ] && with_sick=$((with_sick + 1))
  sleep 0.1
done
code=$(docker wait "$p-run1")
out=$(docker logs "$p-run1" 2>&1)
all_out+=$out$'\n'
inspect_run=$(docker inspect "$p-run1")
docker rm -f "$p-run1" >/dev/null
note "sick run --verbose pve pbs (exit $code)"
show <<<"$out"
same 'sick run ends with 0' 0 "$code"
expect 'pve is renewed' '^pve +renewed +' "$out"
expect 'pbs is renewed' '^pbs +renewed +' "$out"
[ "$with_sick" -gt 0 ] || fail "/proc was never scanned while sick ran ($scans scans)"
same "no secret in /proc/*/cmdline or environ of the sick container ($scans scans, $files files, $with_sick while sick ran)" 0 "$found"

#### 6. what the ports present

step 'the ports present the issued certificates'
issued_pve=$(issued pve)
issued_pbs=$(issued pbs)
[[ $issued_pve =~ ^[0-9a-f]{64}$ && $issued_pbs =~ ^[0-9a-f]{64}$ ]] || fail 'no issued fingerprint in the records of pve and pbs'
samples=$(sample "$pve" 8006 12)
note "8006 after the run: $(transitions "$samples")"
settled "$issued_pve" "$samples" 4000 || fail 'PVE did not settle on the issued certificate within 12 s'
pass 'PVE settles on the issued certificate (the last 4 s of 12 s sampled)'
same 'port 8006 presents the issued certificate' "$issued_pve" "$(fingerprint "$pve" 8006)"
same 'port 8007 presents the issued certificate' "$issued_pbs" "$(fingerprint "$pbs" 8007)"
same '8006 verifies with the lab root under its host name' '0 (ok)' "$(verified "$pve" 8006)"
same '8007 verifies with the lab root under its host name' '0 (ok)' "$(verified "$pbs" 8007)"
same 'exactly one POST in the access log of PVE' 1 "$(posts pve)"
same '... with status 200' 1 "$(posts pve 200)"
same 'exactly one POST in the access log of PBS' 1 "$(posts pbs)"
same '... with status 200' 1 "$(posts pbs 200)"

#### 7. the second run

step 'a second sick run changes nothing'
sick run pve pbs
same 'sick run ends with 0' 0 "$code"
expect 'pve unchanged' '^pve +unchanged +' "$out"
expect 'pbs unchanged' '^pbs +unchanged +' "$out"
same 'no new POST on PVE' 1 "$(posts pve)"
same 'no new POST on PBS' 1 "$(posts pbs)"

#### 8. wrong token

step 'a wrong token: 401, the port unchanged'
sick run --force pve-badtoken pbs-badtoken
same 'sick run ends with 1' 1 "$code"
expect 'pve-badtoken failed with 401' '^pve-badtoken +failed +.*401' "$out"
expect 'pbs-badtoken failed with 401' '^pbs-badtoken +failed +.*401' "$out"
same 'PVE logged the attempt with 401' 1 "$(posts pve 401)"
same 'PBS logged the attempt with 401' 1 "$(posts pbs 401)"
same 'port 8006 still presents the certificate of before' "$issued_pve" "$(fingerprint "$pve" 8006)"
same 'port 8007 still presents the certificate of before' "$issued_pbs" "$(fingerprint "$pbs" 8007)"

#### 9. wrong pin

step 'a wrong pin: no request, the presented fingerprint in the message'
before_pve=$(posts pve)
before_pbs=$(posts pbs)
sick run --force pve-badpin pbs-badpin
same 'sick run ends with 1' 1 "$code"
pin_text() { sed 's/../&:/g; s/:$//' <<<"$1"; }
expect 'pve-badpin failed, naming the fingerprint 8006 presents' "^pve-badpin +failed .*$(pin_text "$issued_pve")" "$out"
expect 'pbs-badpin failed, naming the fingerprint 8007 presents' "^pbs-badpin +failed .*$(pin_text "$issued_pbs")" "$out"
same 'no new line in the access log of PVE' "$before_pve" "$(posts pve)"
same 'no new line in the access log of PBS' "$before_pbs" "$(posts pbs)"
same 'port 8006 unchanged' "$issued_pve" "$(fingerprint "$pve" 8006)"
same 'port 8007 unchanged' "$issued_pbs" "$(fingerprint "$pbs" 8007)"

#### 10. the way back

step 'the way back: DELETE of the custom certificate (curl -H @file --cacert)'
# the header is put together by the shell's printf into a 0600 file of the
# client's tmpfs; curl reads it from there
delete() { # <pve|pbs> <url>
  local scheme=PVEAPIToken= sep==
  [ "$1" = pbs ] && scheme=PBSAPIToken= sep=:
  in_client "umask 077; printf 'Authorization: ${scheme}sick@$1!sick${sep}%s\n' \"\$(head -n 1 /etc/sick/secrets/$1.token)\" >/tmp/h
    curl -sS -o /dev/null -w '%{http_code}' -X DELETE --cacert /etc/sick/ca/root_ca.crt -H @/tmp/h '$2'; rc=\$?; rm -f /tmp/h; exit \$rc"
}
same 'PVE: DELETE ...?restart=1 answers 200' 200 "$(delete pve "https://$pve:8006/api2/json/nodes/pve1/certificates/custom?restart=1")"
same 'PBS: DELETE answers 200' 200 "$(delete pbs "https://$pbs:8007/api2/json/nodes/localhost/certificates/custom")"
samples=$(sample "$pve" 8006 12)
note "8006 after the DELETE: $(transitions "$samples")"
settled "$pve_self" "$samples" 4000 || fail 'PVE did not settle on pve-ssl.pem within 12 s'
pass 'PVE presents its pve-ssl.pem again (the same as before the upload)'
pbs_new=$(fingerprint "$pbs" 8007)
pbs_new_info=$(docker exec "$p-pbs" proxmox-backup-manager cert info | sed -n 's/^Fingerprint (sha256): *//p' | tr -d :)
[[ $pbs_new =~ ^[0-9a-f]{64}$ && $pbs_new != "$pbs_self" && $pbs_new != "$issued_pbs" ]] \
  || fail "PBS presents $pbs_new, not a new certificate"
same 'PBS presents a new self-signed certificate (the one cert info shows)' "$pbs_new_info" "$pbs_new"
sick check pve pbs
expect 'sick check: pve is foreign-ca again' '^pve +.*foreign-ca' "$out"
expect 'sick check: pbs is foreign-ca again' '^pbs +.*foreign-ca' "$out"
before_pbs=$(posts pbs)
before_pve=$(posts pve 200)
sick run pve pbs
same 'sick run ends with 1 (pbs)' 1 "$code"
expect 'pbs fails on its stale pin, naming the new certificate' "^pbs +failed .*$(pin_text "$pbs_new")" "$out"
same '... without a request to PBS' "$before_pbs" "$(posts pbs)"
expect 'pve, trusted through the cluster CA, is renewed again' '^pve +renewed +' "$out"
same '... with one more upload' "$((before_pve + 1))" "$(posts pve 200)"

#### 11. the secrets

step 'the secrets appear nowhere'
records=$(docker run --rm --label sick=1 --name "$p-read" -v "$p-state:/var/lib/sick:ro" --entrypoint sh "$p-sick:local" -c 'cat /var/lib/sick/devices/*.json')
node_logs=$(
  docker exec "$p-pve" sh -c "cat $pve_access /var/log/systemctl-shim.log 2>/dev/null"
  docker exec "$p-pbs" sh -c 'cat /var/log/proxmox-backup/api/*.log /var/log/pbs-*.log 2>/dev/null'
  for c in pve pbs ca; do docker logs "$p-$c" 2>&1; done
  cat "$work/logs/pve-boot.log"
)
config=$(for c in $(ours container); do docker inspect "$c"; done; printf '%s\n' "$inspect_run")
for where in 'the output of sick' 'the device records' 'the logs of the nodes and the CA' 'docker inspect of the containers'; do
  case $where in
    'the output of sick') text=$all_out ;;
    'the device records') text=$records ;;
    'the logs of the nodes and the CA') text=$node_logs ;;
    *) text=$config ;;
  esac
  [ -n "$text" ] || fail "$where: nothing to look at"
  same "$where: no secret in it" 0 "$(hits "$text")"
done
