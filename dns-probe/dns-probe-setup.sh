# dns-probe-setup.sh -- run as root on the Homepage container (192.168.99.8). Safe to re-run.
# Copy it over first, e.g. from PowerShell:
#   scp "C:\Users\labadmin\Nextcloud\Documents\.claude workspace\dns-probe-setup.sh" root@192.168.99.8:/tmp/
# then: bash /tmp/dns-probe-setup.sh
#
# Installs:
#   /usr/local/sbin/dns-probe       queries secnodetls/tertnodetls (DoT, cert-validated) and bunode1/2 (DNS 53)
#   dns-probe.service + .timer      runs it every minute as user dnsprobe
#   /var/lib/dns-probe/dns.json     results + 24 h uptime, also served at http://192.168.99.8:8090/dns.json
#   /usr/local/sbin/dns-layout.py   rebuilds Homepage's DNS group: LAN | DMZ columns with the Unbound tiles
# Then runs the probe once, rebuilds the DNS group and restarts Homepage.

apt-get install -y knot-dnsutils python3-yaml
id dnsprobe >/dev/null 2>&1 || useradd -r -M -d /nonexistent -s /usr/sbin/nologin dnsprobe

cat > /usr/local/sbin/dns-probe <<'PROBE'
#!/usr/bin/env python3
"""dns-probe: query each Unbound resolver directly and publish the results for Homepage and the agents.

Runs every minute from dns-probe.timer on the Homepage container (192.168.99.8) as user dnsprobe.
Writes /var/lib/dns-probe/dns.json (served by digest-viewer at http://192.168.99.8:8090/dns.json)
and keeps 24 hours of results in /var/lib/dns-probe/history.json for the uptime figure.

A probe only counts as OK when the resolver returns NOERROR with at least one answer, so a resolver
that is up but failing upstream (SERVFAIL) shows as down. DoT nodes are checked with full certificate
and hostname validation. Edit NODES below if an address changes.
"""
import json, os, re, subprocess, time
from concurrent.futures import ThreadPoolExecutor

NODES = [
    # name,         ip,              mode,  TLS hostname (DoT only),       Technitium server it backs
    ("secnodetls",  "192.168.15.10", "dot", "secnodetls.example.com",   "primenodetls"),
    ("tertnodetls", "192.168.15.11", "dot", "tertnodetls.example.com",  "primenodetls"),
    ("bunode1",     "10.20.0.13",    "udp", "",                            "buauth"),
    ("bunode2",     "10.20.0.14",    "udp", "",                            "buauth"),
]
QNAME = "example.com"
TIMEOUT = 3
STATE = os.environ.get("STATE_DIRECTORY", "/var/lib/dns-probe")
OUT = os.path.join(STATE, "dns.json")
HIST = os.path.join(STATE, "history.json")
KEEP = 24 * 3600


def probe(node):
    name, ip, mode, host, parent = node
    cmd = ["kdig", f"@{ip}", QNAME, "A", f"+time={TIMEOUT}", "+retry=0"]
    if mode == "dot":
        cmd += ["-p", "853", "+tls-ca", f"+tls-hostname={host}"]
    res = {"ip": ip, "transport": "DoT 853" if mode == "dot" else "DNS 53", "parent": parent}
    t0 = time.monotonic()
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=TIMEOUT + 5)
        out = p.stdout + p.stderr
    except subprocess.TimeoutExpired:
        out = "timeout"
    took = (time.monotonic() - t0) * 1000
    rcode = re.search(r"status: (\w+)", out)
    answers = re.search(r"ANSWER: (\d+)", out)
    rtt = re.search(r" in ([\d.]+) ms", out)
    res["rcode"] = rcode.group(1) if rcode else ""
    res["answers"] = int(answers.group(1)) if answers else 0
    res["ms"] = round(float(rtt.group(1))) if rtt else round(took)
    if res["rcode"] == "NOERROR" and res["answers"] > 0:
        res["status"] = "OK"
    elif res["rcode"] == "REFUSED":
        res["status"] = "REFUSED"
    elif res["rcode"]:
        res["status"] = res["rcode"]
    else:
        res["status"] = "DOWN"
    if res["status"] != "OK":
        if res["rcode"]:
            res["error"] = f'answered {res["rcode"]}' + (" with no answer records" if res["rcode"] == "NOERROR" else "")
        else:
            err = [l.strip(";; ").strip() for l in out.splitlines() if "WARNING" in l or "error" in l.lower()]
            res["error"] = (err[0] if err else "no response")[:160]
    res["time"] = f'{res["ms"]} ms' if res["status"] == "OK" else "-"
    return name, res


def main():
    now = time.time()
    with ThreadPoolExecutor(len(NODES)) as ex:
        results = dict(ex.map(probe, NODES))
    try:
        hist = json.load(open(HIST))
    except Exception:
        hist = {}
    for name, r in results.items():
        h = [e for e in hist.get(name, []) if now - e[0] < KEEP]
        h.append([round(now), 1 if r["status"] == "OK" else 0])
        hist[name] = h
        ok = sum(e[1] for e in h)
        pct = 100 * ok / len(h)
        r["uptime_24h"] = f"{pct:.1f}%" if pct < 99.95 else "100%"
        r["samples_24h"] = len(h)
        lastok = max((e[0] for e in h if e[1]), default=None)
        r["last_ok"] = time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(lastok)) if lastok else "none in 24h"
    up = sum(1 for r in results.values() if r["status"] == "OK")
    data = {
        "checked": time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(now)),
        "checked_hm": time.strftime("%H:%M", time.localtime(now)),
        "query": f"{QNAME} A",
        "summary": f"{up}/{len(results)} OK",
        "nodes": results,
    }
    for path, obj in ((HIST, hist), (OUT, data)):
        tmp = path + ".new"
        with open(tmp, "w") as f:
            json.dump(obj, f, indent=1)
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)


if __name__ == "__main__":
    main()
PROBE
chmod 755 /usr/local/sbin/dns-probe

cat > /usr/local/sbin/dns-layout.py <<'LAYOUT'
#!/usr/bin/env python3
"""dns-layout.py: rebuild Homepage's DNS group as two half-width columns.

  DNS
  ├── LAN:  primenodetls (existing tile), secnodetls, tertnodetls
  └── DMZ:  buauth (existing tile), bunode1, bunode2

The existing Technitium tiles are moved as-is (widget settings and {{HOMEPAGE_VAR_*}} keys untouched).
The Unbound tiles read /dns.json from the dns-probe. settings.yaml gets DNS as a full-width row with
2 columns, placed after Network. Backups: *.pre-dns-layout. Safe to re-run.

Usage: python3 dns-layout.py [config_dir]   (default /opt/homepage/app/config)
"""
import os, shutil, sys
import yaml

CFG = sys.argv[1] if len(sys.argv) > 1 else "/opt/homepage/app/config"
SVC, SET = os.path.join(CFG, "services.yaml"), os.path.join(CFG, "settings.yaml")
URL = "http://127.0.0.1:8090/dns.json"

UNBOUND = {
    "LAN": [("secnodetls", "Unbound, DoT 853, 192.168.15.10"),
            ("tertnodetls", "Unbound, DoT 853, 192.168.15.11")],
    "DMZ": [("bunode1", "Unbound, DNS 53, 10.20.0.13"),
            ("bunode2", "Unbound, DNS 53, 10.20.0.14")],
}
TECHNITIUM = {"LAN": "primenodetls", "DMZ": "buauth"}


def unbound_tile(name, desc):
    return {name: {
        "description": desc,
        "widget": {
            "type": "customapi",
            "url": URL,
            "refreshInterval": 30000,
            "mappings": [
                {"field": f"nodes.{name}.status", "label": "Status"},
                {"field": f"nodes.{name}.time", "label": "Response"},
                {"field": f"nodes.{name}.uptime_24h", "label": "24h"},
            ],
        },
    }}


def name_of(item):
    return next(iter(item)) if isinstance(item, dict) and len(item) == 1 else None


def find_service(items, wanted):
    """Find a service tile by name anywhere inside a group's (possibly nested) list."""
    for it in items or []:
        n = name_of(it)
        if n == wanted and isinstance(it[n], dict):
            return it
        if n and isinstance(it[n], list):
            hit = find_service(it[n], wanted)
            if hit:
                return hit
    return None


class Dumper(yaml.SafeDumper):
    def increase_indent(self, flow=False, indentless=False):
        return super().increase_indent(flow, False)


def dump(path, data):
    if not os.path.exists(path + ".pre-dns-layout"):
        shutil.copy2(path, path + ".pre-dns-layout")
    with open(path + ".new", "w") as f:
        yaml.dump(data, f, Dumper=Dumper, sort_keys=False, allow_unicode=True, width=200, indent=2)
    os.replace(path + ".new", path)


services = yaml.safe_load(open(SVC)) or []
dns = next((g for g in services if name_of(g) == "DNS"), None)
if dns is None:
    sys.exit("No top-level 'DNS' group in services.yaml -- nothing changed.")

new_dns = []
for col, tech in TECHNITIUM.items():
    tile = find_service(dns["DNS"], tech)
    if tile is None:
        sys.exit(f"Couldn't find the '{tech}' tile inside the DNS group -- nothing changed.")
    new_dns.append({col: [tile] + [unbound_tile(n, d) for n, d in UNBOUND[col]]})
dns["DNS"] = new_dns
dump(SVC, services)

settings = yaml.safe_load(open(SET)) or {}
layout = settings.get("layout") or {}
order = ["Monitoring", "Infrastructure", "Network", "DNS"]
dns_layout = {"style": "row", "columns": 2}
new_layout = {k: layout.get(k) for k in order if k != "DNS"}
new_layout["DNS"] = dns_layout
for k, v in layout.items():
    if k not in new_layout:
        new_layout[k] = v
settings["layout"] = new_layout
dump(SET, settings)

print("DNS group rebuilt: LAN (primenodetls, secnodetls, tertnodetls) | DMZ (buauth, bunode1, bunode2)")
print("Layout order:", ", ".join(new_layout))
LAYOUT
chmod 755 /usr/local/sbin/dns-layout.py

cat > /etc/systemd/system/dns-probe.service <<'UNIT'
[Unit]
Description=Probe the Unbound resolvers for Homepage and the agents
After=network-online.target

[Service]
Type=oneshot
User=dnsprobe
Group=dnsprobe
StateDirectory=dns-probe
StateDirectoryMode=0755
ExecStart=/usr/local/sbin/dns-probe
NoNewPrivileges=yes
UNIT

cat > /etc/systemd/system/dns-probe.timer <<'UNIT'
[Unit]
Description=Run dns-probe every minute

[Timer]
OnCalendar=*-*-* *:*:00
AccuracySec=1s

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now dns-probe.timer
systemctl start dns-probe.service
ln -sfn /var/lib/dns-probe/dns.json /srv/digest/www/dns.json

echo
echo "--- probe results (DOWN everywhere = router rules not in yet; REFUSED = Unbound access-control):"
python3 - <<'SHOW'
import json
d = json.load(open("/var/lib/dns-probe/dns.json"))
for k, v in d["nodes"].items():
    print(f'{k:12} {v["ip"]:14} {v["transport"]:8} {v["status"]:9} {v.get("time", "")} {v.get("error", "")}')
SHOW

echo
python3 /usr/local/sbin/dns-layout.py && systemctl restart homepage && echo "Homepage restarted."
