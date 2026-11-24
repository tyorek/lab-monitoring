#!/usr/bin/env bash
# Install unbound-health-check on the Technitium server (192.168.15.9).
# Run from this directory as root: sudo bash install.sh
set -euo pipefail
cd "$(dirname "$0")"

apt-get install -y --no-install-recommends dnsutils curl jq

install -D -m 755 unbound-health-check.sh /usr/local/sbin/unbound-health-check.sh
install -D -m 644 config /etc/unbound-health-check/config
install -m 644 unbound-health-check.service /etc/systemd/system/
install -m 644 unbound-health-check.timer   /etc/systemd/system/

if [ ! -f /etc/unbound-health-check/token ]; then
    echo "MISSING: /etc/unbound-health-check/token"
    echo "Create an API token in Technitium (Administration -> Sessions -> Create Token), then:"
    echo "  echo 'TOKEN_VALUE' > /etc/unbound-health-check/token"
    echo "  chmod 600 /etc/unbound-health-check/token"
    echo "Then run: systemctl daemon-reload && systemctl enable --now unbound-health-check.timer"
    exit 1
fi
chmod 600 /etc/unbound-health-check/token

systemctl daemon-reload
systemctl enable --now unbound-health-check.timer
echo "Installed. Watch it: journalctl -t unbound-health-check -f"
