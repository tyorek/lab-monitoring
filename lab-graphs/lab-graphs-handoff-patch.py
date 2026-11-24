# lab-graphs-handoff-patch.py -- run as root on the Homepage container (CT 111). Applied 2026-11-02 00:45,
# revised 00:55 (as deployed now): the "Public handoff" graph is the RB5009 <-> OPNsense link, VLAN 100
# 172.16.255.0/30, interface vlan100-public-handoff (renamed from vlan100-transit; OPNsense calls it
# PUBLIC_HANDOFF), read from the router's REST API with the same read-only `homepage` account as the
# WAN graph. The first version read OPNsense's WAN NIC from Proxmox instead. "WAN traffic" (ether1) unchanged.
# Backups: lab-graphs.pre-handoff, graphs.html.pre-handoff, services.yaml.pre-handoff.
# Patches /usr/local/sbin/lab-graphs and /srv/digest/www/graphs.html as installed by lab-graphs-setup.sh,
# and adds the tile under "WAN traffic" in services.yaml.
import shutil
def patch(path, subs):
    s = open(path).read()
    if "handoff" in s:
        print("already patched:", path); return
    shutil.copy2(path, path + ".pre-handoff")
    for old, new in subs:
        assert s.count(old) == 1, (path, old[:50])
        s = s.replace(old, new, 1)
    open(path, "w").write(s)
    print("patched:", path)

patch("/usr/local/sbin/lab-graphs", [
("""STATE = os.environ.get("STATE_DIRECTORY", "/var/lib/lab-graphs")""",
"""# Public handoff = the RB5009 <-> OPNsense link (VLAN 100, 172.16.255.0/30), read on the router like WAN_IF
HANDOFF_IF = os.environ.get("LG_HANDOFF_IF", "vlan100-public-handoff")
STATE = os.environ.get("STATE_DIRECTORY", "/var/lib/lab-graphs")"""),
("""        assert "wan" in d and "dns" in d
        return d""",
"""        assert "wan" in d and "dns" in d
        d.setdefault("handoff", {"iface": HANDOFF_IF, "t": [], "down": [], "up": []})
        return d"""),
("""                "dns": {"t": [], "lan": [], "dmz": []}, "errors": {}}""",
"""                "dns": {"t": [], "lan": [], "dmz": []},
                "handoff": {"iface": HANDOFF_IF, "t": [], "down": [], "up": []},
                "errors": {}}"""),
("""def parse_label(s):""",
"""def handoff_counters():
    # On the router: rx on the handoff VLAN = coming from OPNsense (download), tx = upload.
    rows = get_json(f"{ROUTER}/rest/interface?name={HANDOFF_IF}&.proplist=name,rx-byte,tx-byte",
                    auth=f"{ROUTER_USER}:{ROUTER_PASS}")
    row = rows[0] if isinstance(rows, list) and rows else rows
    return int(row["rx-byte"]), int(row["tx-byte"])


def parse_label(s):"""),
("""    prev = None          # (time, rx, tx)""",
"""    prev = None          # (time, rx, tx)
    prev_h = None        # (time, down bytes, up bytes) for the public handoff"""),
("""        # --- DNS
""",
"""        # --- Public handoff (OPNsense WAN NIC)
        try:
            dn, upb = handoff_counters()
            if prev_h and dn >= prev_h[1] and upb >= prev_h[2] and now > prev_h[0]:
                dt = now - prev_h[0]
                h = data["handoff"]
                h["t"].append(int(now))
                h["down"].append(round((dn - prev_h[1]) * 8 / dt / 1e6, 2))
                h["up"].append(round((upb - prev_h[2]) * 8 / dt / 1e6, 2))
            prev_h = (now, dn, upb)
            data["errors"].pop("handoff", None)
        except Exception as e:
            prev_h = None
            data["errors"]["handoff"] = str(e)[:200]
            h = data["handoff"]
            h["t"].append(int(now)); h["down"].append(None); h["up"].append(None)
        data["handoff"]["iface"] = HANDOFF_IF
        trim(data["handoff"], ["down", "up"], now)
        # --- DNS
"""),
])

patch("/srv/digest/www/graphs.html", [
("""const which = new URLSearchParams(location.search).get("g") === "dns" ? "dns" : "wan";""",
"""const gq = new URLSearchParams(location.search).get("g");
const which = ["dns", "handoff"].includes(gq) ? gq : "wan";   // ?g=handoff added 2026-11-02"""),
("""  dns: { title: "queries / min",""",
"""  handoff: { title: "Mbps", unit: "Mbps", fmt: mbps, spanMin: 60, ref: { value: 35, label: "upload cap 35 (CAKE)" },
         series: [{ key: "down", label: "Down", color: "#6fa300", area: true }, { key: "up", label: "Up", color: "#9466ea" }] },
  dns: { title: "queries / min","""),
("""setInterval(load, which === "wan" ? 10000 : 60000);""",
"""setInterval(load, which === "dns" ? 60000 : 10000);"""),
])

patch("/opt/homepage/app/config/services.yaml", [
("""          name: graphwan
          src: https://digest.example.com/graphs.html?g=wan
""",
"""          name: graphwan
          src: https://digest.example.com/graphs.html?g=wan
    - Public handoff:
        description: Router <-> OPNsense 172.16.255.0/30 (VLAN 100), last 60 min
        widget:
          type: iframe
          name: graphhandoff
          src: https://digest.example.com/graphs.html?g=handoff
"""),
])
