#!/bin/bash
# First-boot generator for the KubeStellar kiosk TLS certificate and key.
#
# Run by k0s-kiosk-tls.service before k0scontroller.service. Writes key.pem
# (0600) and cert.pem (0644) into /var/lib/k0s/kiosk with the host's DNS name
# and IP addresses in the SAN. Idempotent: host-generated material is kept
# across boots so the certificate browsers have trusted stays stable.
#
# Earlier sysext releases generated cert.pem/key.pem at build time and shipped
# them inside the public release image, so those private keys are public
# knowledge. Build-time certificates carry exactly the SAN below (10.0.2.15 is
# the QEMU user-net guest address that was hardcoded at build time) and lack
# the OU=host-generated subject marker this script adds. When one is found on
# disk (seeded by the old directory-level tmpfiles rule on upgraded hosts), it
# is treated as compromised and regenerated in place. The marker keeps a QEMU
# user-net host whose own SAN legitimately matches from regenerating on every
# boot.
set -euo pipefail
umask 077

kiosk_dir="${KIOSK_TLS_DIR:-/var/lib/k0s/kiosk}"
key="$kiosk_dir/key.pem"
cert="$kiosk_dir/cert.pem"

leaked_build_san="DNS:localhost,DNS:*.local,IPAddress:127.0.0.1,IPAddress:10.0.2.15"

if [ -s "$key" ] && [ -s "$cert" ]; then
  subject="$(openssl x509 -in "$cert" -noout -subject 2>/dev/null || true)"
  existing_san="$(openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null | sed 1d | tr -d '[:space:]' || true)"
  if [[ "$subject" == *host-generated* ]] || [ "$existing_san" != "$leaked_build_san" ]; then
    exit 0
  fi
  echo "k0s-kiosk-tls: replacing compromised build-time certificate (private key was published in the release image)" >&2
  rm -f "$key" "$cert"
fi

mkdir -p "$kiosk_dir"
# tmpfiles.d owns this dir as 0755; keep that under our restrictive umask so
# the kiosk proxy can still read the static assets seeded next to the certs.
chmod 0755 "$kiosk_dir"

SAN="DNS:localhost,DNS:*.local,IP:127.0.0.1"
if command -v hostname >/dev/null 2>&1; then
  HN="$(hostname 2>/dev/null || true)"
  if [ -n "$HN" ] && [ "$HN" != "localhost" ]; then
    SAN="${SAN},DNS:${HN}"
  fi
else
  echo "k0s-kiosk-tls: hostname command not found, SAN has no host DNS name" >&2
fi
if command -v ip >/dev/null 2>&1; then
  for addr in $(ip -o addr show scope global 2>/dev/null | tr -s ' ' | cut -d ' ' -f4 | cut -d/ -f1); do
    SAN="${SAN},IP:${addr}"
  done
else
  echo "k0s-kiosk-tls: ip command not found, SAN has no host IP address" >&2
fi

openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
  -keyout "$key" -out "$cert" \
  -subj "/CN=KubeStellar Console/OU=host-generated" \
  -addext "subjectAltName=${SAN}"
chmod 0600 "$key"
chmod 0644 "$cert"
