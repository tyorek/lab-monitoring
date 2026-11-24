# lab-graphs-three-links-patch.py -- run as root on the Homepage container (CT 111). Applied 2026-11-02 ~01:05.
# Three graphs along the path, to correlate traffic shifts between the links:
#   DMZ uplink      RB5009 ether1 (trunk to OPNsense: VLAN 10 DMZ + VLAN 100 handoff)   [new]
#   Public handoff  RB5009 vlan100-public-handoff (172.16.255.0/30)                      [unchanged]
#   WAN traffic     OPNsense WAN port = VM 109 net1, from the Proxmox node netstat API   [repointed from ether1]
# Applies on top of lab-graphs-handoff-patch.py. Backups: *.pre-three-links.
import shutil
def patch(path, subs):
    s = open(path).read()
    if "dmzup" in s:
        print("already patched:", path); return
    shutil.copy2(path, path + ".pre-three-links")
    for old, new in subs:
        assert s.count(old) == 1, (path, old[:60])
        s = s.replace(old, new, 1)
    open(path, "w").write(s)
    print("patched:", path)

patch("/usr/local/sbin/lab-graphs", [
("""HANDOFF_IF = os.environ.get("LG_HANDOFF_IF", "vlan100-public-handoff")
""",
"""HANDOFF_IF = os.environ.get("LG_HANDOFF_IF", "vlan100-public-handoff")
# DMZ uplink = the router's ether1 trunk to OPNsense (VLAN 10 DMZ + VLAN 100 handoff)
DMZUP_IF = os.environ.get("LG_DMZUP_IF", "ether1")
# WAN = OPNsense's WAN port (VM 109 net1, modem side), from Proxmox with Homepage's read-only token
PVE = os.environ.get("LG_PVE", "https://192.168.99.2:8006")
PVE_AUTH = "PVEAPIToken={}={}".format(os.environ.get("HOMEPAGE_VAR_PROXMOX_TOKEN_ID", ""),
                                      os.environ.get("HOMEPAGE_VAR_PROXMOX_TOKEN_SECRET", ""))
WAN_VMID = os.environ.get("LG_WAN_VMID", "109")
WAN_NET = os.environ.get("LG_WAN_NET", "net1")
WAN_LABEL = f"fw-edge vm{WAN_VMID} {WAN_NET}"
"""),
("""        assert "wan" in d and "dns" in d
""",
"""        assert "wan" in d and "dns" in d
        if d["wan"].get("iface") != WAN_LABEL:   # source changed: start the WAN series fresh
            d["wan"] = {"iface": WAN_LABEL, "t": [], "down": [], "up": []}
        d.setdefault("dmzup", {"iface": DMZUP_IF, "t": [], "down": [], "up": []})
"""),
("""def wan_counters():
    rows = get_json(f"{ROUTER}/rest/interface?name={WAN_IF}&.proplist=name,rx-byte,tx-byte",
                    auth=f"{ROUTER_USER}:{ROUTER_PASS}")
    row = rows[0] if isinstance(rows, list) and rows else rows
    return int(row["rx-byte"]), int(row["tx-byte"])""",
"""def wan_counters():
    # Proxmox counts from the VM's side: "in" = received by OPNsense's WAN port (download), "out" = upload.
    rows = get_json(f"{PVE}/api2/json/nodes/pve/netstat", headers={"Authorization": PVE_AUTH})["data"]
    row = next(r for r in rows if str(r.get("vmid")) == WAN_VMID and r.get("dev") == WAN_NET)
    return int(row["in"]), int(row["out"])


def dmzup_counters():
    # On the router: rx on ether1 = coming from OPNsense (download), tx = upload.
    rows = get_json(f"{ROUTER}/rest/interface?name={DMZUP_IF}&.proplist=name,rx-byte,tx-byte",
                    auth=f"{ROUTER_USER}:{ROUTER_PASS}")
    row = rows[0] if isinstance(rows, list) and rows else rows
    return int(row["rx-byte"]), int(row["tx-byte"])"""),
("""        data["wan"]["iface"] = WAN_IF""",
"""        data["wan"]["iface"] = WAN_LABEL"""),
("""    prev_h = None        # (time, down bytes, up bytes) for the public handoff""",
"""    prev_h = None        # (time, down bytes, up bytes) for the public handoff
    prev_d = None        # same for the DMZ uplink (ether1)"""),
("""        # --- DNS
""",
"""        # --- DMZ uplink (router ether1)
        try:
            dn, upb = dmzup_counters()
            if prev_d and dn >= prev_d[1] and upb >= prev_d[2] and now > prev_d[0]:
                dt = now - prev_d[0]
                u = data["dmzup"]
                u["t"].append(int(now))
                u["down"].append(round((dn - prev_d[1]) * 8 / dt / 1e6, 2))
                u["up"].append(round((upb - prev_d[2]) * 8 / dt / 1e6, 2))
            prev_d = (now, dn, upb)
            data["errors"].pop("dmzup", None)
        except Exception as e:
            prev_d = None
            data["errors"]["dmzup"] = str(e)[:200]
            u = data["dmzup"]
            u["t"].append(int(now)); u["down"].append(None); u["up"].append(None)
        data["dmzup"]["iface"] = DMZUP_IF
        trim(data["dmzup"], ["down", "up"], now)
        # --- DNS
"""),
])

patch("/srv/digest/www/graphs.html", [
("""const which = ["dns", "handoff"].includes(gq) ? gq : "wan";""",
"""const which = ["dns", "handoff", "dmzup"].includes(gq) ? gq : "wan";   // ?g=dmzup added 2026-11-02"""),
("""  wan: { title: "Mbps", unit: "Mbps", fmt: mbps, spanMin: 60, ref: { value: 38, label: "upload cap 38 (CAKE)" },""",
"""  wan: { title: "Mbps", unit: "Mbps", fmt: mbps, spanMin: 60, ref: { value: 38, label: "upload cap 38 (OPNsense)" },"""),
("""  dns: { title: "queries / min",""",
"""  dmzup: { title: "Mbps", unit: "Mbps", fmt: mbps, spanMin: 60, ref: null,
         series: [{ key: "down", label: "Down", color: "#6fa300", area: true }, { key: "up", label: "Up", color: "#9466ea" }] },
  dns: { title: "queries / min","""),
])

patch("/opt/homepage/app/config/services.yaml", [
("""        description: Router ether1, last 60 min""",
"""        description: OPNsense WAN port (modem side), last 60 min"""),
("""          src: https://digest.example.com/graphs.html?g=handoff
""",
"""          src: https://digest.example.com/graphs.html?g=handoff
    - DMZ uplink:
        description: Router ether1 (trunk to OPNsense, VLAN 10 + 100), last 60 min
        widget:
          type: iframe
          name: graphdmzup
          src: https://digest.example.com/graphs.html?g=dmzup
"""),
])
