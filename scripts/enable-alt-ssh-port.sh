#!/usr/bin/env bash
# Enable SSH on an extra port (keeps port 22). Run ONCE on the VPS when your
# laptop WiFi blocks outbound port 22 — use DigitalOcean Droplet Console if
# you cannot SSH in from your machine.
#
# Usage (on the server as root):
#   bash enable-alt-ssh-port.sh          # default port 2222
#   bash enable-alt-ssh-port.sh 4433
#
# Afterward, on your laptop:
#   1. Add PATET_SSH_PORT=<port> to profiles/patet-am.env
#   2. Test: ssh -p <port> -i ~/.ssh/id_rsa root@207.154.224.28 "echo ok"
#   3. Deploy: ./deploy-patet.sh frontend
#
# Also open the port in DigitalOcean → Networking → Firewalls (if you use one).

set -euo pipefail

ALT_PORT="${1:-2222}"

if ! [[ "$ALT_PORT" =~ ^[0-9]+$ ]] || (( ALT_PORT < 1024 || ALT_PORT > 65535 )); then
  echo "Error: port must be 1024–65535 (got: $ALT_PORT)" >&2
  exit 1
fi

if [[ "$ALT_PORT" == "443" ]]; then
  echo "Error: port 443 is used by nginx/HTTPS on patet.am. Pick another port (e.g. 2222)." >&2
  exit 1
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Error: run as root on the VPS." >&2
  exit 1
fi

DROP_IN="/etc/ssh/sshd_config.d/99-patet-alt-port.conf"

echo "==> Adding SSH listener on port $ALT_PORT (port 22 stays enabled)"
mkdir -p /etc/ssh/sshd_config.d
cat >"$DROP_IN" <<EOF
# Added by patet-deployment/scripts/enable-alt-ssh-port.sh — do not edit by hand
Port 22
Port $ALT_PORT
EOF

echo "==> Validating sshd config"
sshd -t

# Ubuntu 22.04+ often uses ssh.socket (systemd) — sshd_config Port alone is not enough.
if systemctl is-active --quiet ssh.socket 2>/dev/null; then
  echo "==> Configuring ssh.socket for ports 22 and $ALT_PORT"
  mkdir -p /etc/systemd/system/ssh.socket.d
  cat >/etc/systemd/system/ssh.socket.d/patet-alt-port.conf <<EOF
[Socket]
ListenStream=
ListenStream=22
ListenStream=$ALT_PORT
EOF
  systemctl daemon-reload
  systemctl restart ssh.socket
fi

echo "==> Reloading SSH"
if systemctl is-active --quiet ssh; then
  systemctl restart ssh
elif systemctl is-active --quiet sshd; then
  systemctl restart sshd
else
  echo "Error: could not find active ssh/sshd service" >&2
  exit 1
fi

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi 'Status: active'; then
  echo "==> Opening port $ALT_PORT in ufw"
  ufw allow "${ALT_PORT}/tcp"
fi

if ss -ltn "sport = :$ALT_PORT" 2>/dev/null | grep -q LISTEN; then
  echo ""
  echo "OK: sshd is listening on port $ALT_PORT (and 22)."
else
  echo ""
  echo "WARNING: port $ALT_PORT does not appear to be listening yet."
  echo "Check: ss -ltn | grep $ALT_PORT"
fi

echo ""
echo "Next steps:"
echo "  1. DigitalOcean cloud firewall (if any): allow inbound TCP $ALT_PORT"
echo "  2. Laptop profiles/patet-am.env:  PATET_SSH_PORT=$ALT_PORT"
echo "  3. Test from laptop: ssh -p $ALT_PORT -i ~/.ssh/id_rsa root@$(hostname -I | awk '{print $1}') \"echo ok\""
echo ""
echo "If your WiFi only allows outbound HTTPS (port 443), this port may still be blocked."
echo "Use mobile hotspot, or ask for sslh setup on 443 (advanced)."
