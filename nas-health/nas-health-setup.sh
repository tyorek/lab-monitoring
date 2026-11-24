# nas-health-setup.sh -- run as root (sudo -i first) on each OMV NAS (pibox, nas). Copy the whole file and paste it.
# Safe to re-run; re-running upgrades an earlier install. Sets up:
#   - /usr/local/sbin/nas-health: root-run health snapshot (AD trust, time sync, Samba/winbind, disks, RAID, SMART,
#     plus OMV's own service and SMART status via omv-rpc -- the same data Homepage's OMV widget shows)
#   - /etc/cron.d/nas-health: refreshes it every 5 minutes
#       /var/lib/nas-health/status.txt   text snapshot, read by the daily-digest agent over SSH
#       /var/lib/nas-health/status.json  summary for the Homepage tile
#   - local system user "agent" whose SSH key can only `cat` status.txt (no shell, no forwarding)
#   - /nas-health.json on OMV's web UI port, readable only from Homepage (192.168.99.8) and localhost

apt-get install -y smartmontools

mkdir -p /var/lib/nas-health
chmod 755 /var/lib/nas-health

cat > /usr/local/sbin/nas-health <<'SCRIPT'
#!/bin/bash
# nas-health: read-only health snapshot of this OMV box.
# Runs as root from /etc/cron.d/nas-health every 5 minutes. Writes:
#   - text snapshot to stdout (saved as status.txt; the daily-digest agent reads it over SSH)
#   - JSON summary to $NAS_HEALTH_JSON if set (served by OMV's nginx at /nas-health.json for the Homepage tile)
export LC_ALL=C PATH=/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin

line() { tr '\n' ' ' | tr -s ' ' | cut -c1-240; }

echo "host: $(hostname -f 2>/dev/null || hostname)"
echo "collected: $(date -Is)"
echo "uptime: $(uptime -p 2>/dev/null)  load: $(cut -d' ' -f1-3 /proc/loadavg)"

echo
echo "## Domain (winbind / AD trust)"
DOMAIN=OK
for c in "wbinfo -t" "wbinfo -P" "net ads testjoin"; do
    if command -v "${c%% *}" >/dev/null; then
        out=$(timeout 20 $c 2>&1); rc=$?
        echo "$c: rc=$rc $(line <<<"$out")"
        [ "$rc" -eq 0 ] || DOMAIN=FAIL
    else
        echo "$c: not installed"
        [ "$DOMAIN" = OK ] && DOMAIN=n/a
    fi
done
echo "ntp_synchronized: $(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo unknown)"
if command -v chronyc >/dev/null; then
    echo "chrony: $(chronyc tracking 2>/dev/null | grep -E '^(Reference ID|System time)' | line)"
fi

echo
echo "## Services"
SAMBA_DOWN=""
for s in smbd winbind nmbd ssh docker; do
    systemctl list-unit-files "$s.service" >/dev/null 2>&1 || continue
    st=$(systemctl is-active "$s" 2>/dev/null); en=$(systemctl is-enabled "$s" 2>/dev/null)
    [ "$en" = "disabled" ] && [ "$st" != "active" ] && continue
    echo "$s: $st"
    case "$s" in smbd|winbind) [ "$st" = "active" ] || SAMBA_DOWN="${SAMBA_DOWN:+$SAMBA_DOWN,}$s" ;; esac
done
echo "smbd/winbind errors in last 24h: $(journalctl -q -u smbd -u winbind --since -24h -p err --no-pager 2>/dev/null | wc -l)"
journalctl -q -u smbd -u winbind --since -24h -p err --no-pager -o short-iso 2>/dev/null | tail -n 3 | cut -c1-240

echo
echo "## Filesystems"
df -hPT -x tmpfs -x devtmpfs -x overlay -x squashfs -x efivarfs 2>/dev/null

if [ -r /proc/mdstat ] && grep -q '^md' /proc/mdstat; then
    echo
    echo "## RAID (/proc/mdstat)"
    grep -A2 '^md' /proc/mdstat
fi

echo
echo "## SMART"
if ! command -v smartctl >/dev/null; then
    echo "smartctl not installed"
else
    for d in $(lsblk -dno NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}'); do
        dev=/dev/$d
        out=$(timeout 30 smartctl -H -A "$dev" 2>&1)
        if grep -qiE 'unknown usb bridge|specify device type' <<<"$out"; then
            out=$(timeout 30 smartctl -d sat -H -A "$dev" 2>&1)
        fi
        health=$(grep -iE 'overall-health|SMART Health Status' <<<"$out" | sed 's/.*: *//' | head -n1)
        if [ -z "$health" ]; then
            echo "$dev: SMART unavailable ($(grep -iE 'unavailable|not supported|error|unknown' <<<"$out" | head -n1 | cut -c1-120))"
            continue
        fi
        attrs=$(awk '$1==5||$1==187||$1==197||$1==198{printf "%s=%s ", $2, $10} $1==194{printf "Temp=%sC ", $10}' <<<"$out")
        nvme=$(grep -E '^(Critical Warning|Temperature|Percentage Used|Media and Data Integrity Errors):' <<<"$out" | sed 's/  */ /g' | line)
        model=$(lsblk -dno MODEL,SIZE "$dev" 2>/dev/null | tr -s ' ')
        echo "$dev ($model): health=$health $attrs$nvme"
    done
fi

# ---- JSON summary for the Homepage tile ----
# Service and SMART counts come from OMV's own RPC (the same calls Homepage's built-in OMV widget makes),
# run locally as root, so no OMV login is stored anywhere.
[ -n "${NAS_HEALTH_JSON:-}" ] || exit 0
DISK_MAX=$(df -P 2>/dev/null | awk '$6 ~ /^\/srv\// {u=$5; sub("%","",u); if (u+0 > m) m=u+0; n++} END {if (n) print m}')
DOMAIN="$DOMAIN" SAMBA_DOWN="$SAMBA_DOWN" DISK_MAX="$DISK_MAX" python3 - "$NAS_HEALTH_JSON" <<'PYJSON'
import json, os, subprocess, sys, time

def rpc(service, method, params=None):
    cmd = ["omv-rpc", "-u", "admin", service, method]
    if params is not None:
        cmd.append(json.dumps(params))
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=90)
        return json.loads(r.stdout) if r.returncode == 0 else None
    except Exception:
        return None

def rows(resp):
    if isinstance(resp, dict):
        return resp.get("data") or []
    return resp if isinstance(resp, list) else []

out = {"host": os.uname().nodename,
       "collected": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
       "updated": time.strftime("%H:%M")}

out["domain"] = os.environ.get("DOMAIN", "n/a")
down = os.environ.get("SAMBA_DOWN", "")
out["samba"] = ("DOWN " + down) if down else "OK"

svc = rpc("Services", "getStatus")
if svc is None:
    out["services"] = "n/a"
else:
    enabled = [s for s in rows(svc) if s.get("enabled")]
    running = [s for s in enabled if s.get("running")]
    out["services_running"] = len(running)
    out["services_enabled"] = len(enabled)
    out["services_down"] = sorted(str(s.get("name", "?")) for s in enabled if not s.get("running"))
    out["services"] = f"{len(running)}/{len(enabled)}"

smart = rpc("Smart", "getList", {"start": 0, "limit": -1})
if smart is None:
    out["smart"] = "n/a"
else:
    mon = [d for d in rows(smart) if d.get("monitor")]
    bad = [d for d in mon if d.get("overallstatus") != "GOOD"]
    out["smart_passed"] = len(mon) - len(bad)
    out["smart_failed"] = len(bad)
    out["smart"] = "off" if not mon else (f"{len(bad)} FAIL" if bad else f"{len(mon)} OK")

disk = os.environ.get("DISK_MAX", "")
out["disk"] = f"{disk}%" if disk else "n/a"

issues = []
if out["domain"] == "FAIL": issues.append("domain trust failing")
if down: issues.append("samba down: " + down)
if out.get("services_down"): issues.append("services down: " + ",".join(out["services_down"]))
if out.get("smart_failed"): issues.append("SMART failing")
if disk and int(disk) >= 85: issues.append("disk " + disk + "%")
out["issues"] = "; ".join(issues) or "none"
out["status"] = "ATTENTION" if issues else "OK"

tmp = sys.argv[1] + ".new"
with open(tmp, "w") as f:
    json.dump(out, f, indent=1)
os.chmod(tmp, 0o644)
os.replace(tmp, sys.argv[1])
PYJSON
SCRIPT
chmod 755 /usr/local/sbin/nas-health

cat > /etc/cron.d/nas-health <<'CRON'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin
*/5 * * * * root NAS_HEALTH_JSON=/var/lib/nas-health/status.json /usr/local/sbin/nas-health > /var/lib/nas-health/status.new 2>&1; chmod 644 /var/lib/nas-health/status.new; mv -f /var/lib/nas-health/status.new /var/lib/nas-health/status.txt
CRON
chmod 644 /etc/cron.d/nas-health

id agent >/dev/null 2>&1 || useradd -r -m -d /home/agent -s /bin/sh agent
usermod -p '*' agent
# OMV only lets members of _ssh (and root) log in over SSH
getent group _ssh >/dev/null && usermod -aG _ssh agent
mkdir -p /home/agent/.ssh
echo 'command="cat /var/lib/nas-health/status.txt",restrict ssh-ed25519 AAAA...REPLACE_WITH_YOUR_PUBLIC_KEY agent@claude-noc-lxc' > /home/agent/.ssh/authorized_keys
chown root:root /home/agent/.ssh /home/agent/.ssh/authorized_keys
chmod 755 /home/agent/.ssh
chmod 644 /home/agent/.ssh/authorized_keys

# Serve status.json from OMV's own nginx (the openmediavault-webgui.d folder is OMV's place for extra config)
mkdir -p /etc/nginx/openmediavault-webgui.d
cat > /etc/nginx/openmediavault-webgui.d/nas-health.conf <<'NGINX'
location = /nas-health.json {
    allow 127.0.0.1;
    allow 192.168.99.8;
    deny all;
    alias /var/lib/nas-health/status.json;
    default_type application/json;
    add_header Cache-Control "no-store" always;
}
NGINX
grep -q 'openmediavault-webgui.d' /etc/nginx/sites-enabled/openmediavault-webgui || echo "WARNING: OMV's nginx site doesn't include openmediavault-webgui.d -- tell Claude"
nginx -t && systemctl reload nginx

NAS_HEALTH_JSON=/var/lib/nas-health/status.json /usr/local/sbin/nas-health > /var/lib/nas-health/status.new 2>&1; chmod 644 /var/lib/nas-health/status.new; mv -f /var/lib/nas-health/status.new /var/lib/nas-health/status.txt
PORT=$(grep -hoE 'listen \*:[0-9]+' /etc/nginx/sites-enabled/openmediavault-webgui | head -n1 | grep -oE '[0-9]+$')
echo
echo "--- /nas-health.json as served on port ${PORT:-80}:"
curl -s "http://127.0.0.1:${PORT:-80}/nas-health.json"
echo
