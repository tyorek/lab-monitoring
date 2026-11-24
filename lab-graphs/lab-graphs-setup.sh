# lab-graphs-setup.sh -- run as root on the Homepage container (192.168.99.8). Safe to re-run.
# Adds two live graphs to Homepage, filling the space under Uptime Kuma and Proxmox:
#   WAN traffic  (router ether1, Mbps down/up, 10 s samples, last 60 min, CAKE upload cap line at 38)
#   DNS queries  (Technitium per-minute totals, LAN primenodetls vs DMZ buauth, last 60 min)
# Installs:
#   /usr/local/sbin/lab-graphs     collector (lab-graphs.service, user labgraphs; reads the router and Technitium
#                                  with the read-only credentials already in /etc/homepage/secrets.env)
#   /var/lib/lab-graphs/graphs.json
#   /srv/digest/www/graphs.html    the chart page, served by digest-viewer (and digest.example.com)
# and adds the two iframe tiles to services.yaml (backup: services.yaml.pre-graphs).

for v in HOMEPAGE_VAR_MIKROTIK_PASSWORD HOMEPAGE_VAR_TECHNITIUM_PRIMENODE_KEY HOMEPAGE_VAR_TECHNITIUM_BUAUTH_KEY; do
    grep -q "^$v=" /etc/homepage/secrets.env || echo "WARNING: $v is not in /etc/homepage/secrets.env -- tell Claude its actual name"
done

id labgraphs >/dev/null 2>&1 || useradd -r -M -d /nonexistent -s /usr/sbin/nologin labgraphs

cat > /usr/local/sbin/lab-graphs <<'COLLECTOR'
#!/usr/bin/env python3
"""lab-graphs: collect the data behind Homepage's two live graphs.

Runs as a long-lived service (lab-graphs.service, user labgraphs) on the Homepage container.
  - WAN traffic: every 10 s, reads the router's WAN interface byte counters over the RouterOS REST API
    (read-only `homepage` account) and turns the deltas into Mbps down/up.
  - DNS queries: every 60 s, reads Technitium's per-minute LastHour chart from primenodetls (LAN) and
    buauth (DMZ) with Homepage's view-only keys.
Writes /var/lib/lab-graphs/graphs.json (served by digest-viewer at /graphs.json), keeping 60 minutes.
Credentials come from /etc/homepage/secrets.env via systemd's EnvironmentFile; nothing is stored here.
"""
import base64, json, os, ssl, time, urllib.request
from datetime import datetime, timezone

ROUTER = os.environ.get("LG_ROUTER", "https://192.168.99.1:8443")
ROUTER_USER = os.environ.get("LG_ROUTER_USER", "homepage")
ROUTER_PASS = os.environ.get("HOMEPAGE_VAR_MIKROTIK_PASSWORD", "")
WAN_IF = os.environ.get("LG_WAN_IF", "ether1")
TECHNITIUM = [  # series key, url, env var holding the key
    ("lan", os.environ.get("LG_LAN_DNS", "http://192.168.15.9:5380"), "HOMEPAGE_VAR_TECHNITIUM_PRIMENODE_KEY"),
    ("dmz", os.environ.get("LG_DMZ_DNS", "http://10.20.0.9:5380"), "HOMEPAGE_VAR_TECHNITIUM_BUAUTH_KEY"),
]
STATE = os.environ.get("STATE_DIRECTORY", "/var/lib/lab-graphs")
OUT = os.path.join(STATE, "graphs.json")
SPAN = 3600
WAN_EVERY, DNS_EVERY = 10, 60

NOVERIFY = ssl.create_default_context()
NOVERIFY.check_hostname = False
NOVERIFY.verify_mode = ssl.CERT_NONE   # router uses its own self-signed cert, same as Homepage's tile


def get_json(url, auth=None, timeout=8):
    req = urllib.request.Request(url)
    if auth:
        req.add_header("Authorization", "Basic " + base64.b64encode(auth.encode()).decode())
    ctx = NOVERIFY if url.startswith("https") else None
    with urllib.request.urlopen(req, timeout=timeout, context=ctx) as r:
        return json.loads(r.read().decode())


def load():
    try:
        d = json.load(open(OUT))
        assert "wan" in d and "dns" in d
        return d
    except Exception:
        return {"wan": {"iface": WAN_IF, "t": [], "down": [], "up": []},
                "dns": {"t": [], "lan": [], "dmz": []}, "errors": {}}


def save(d):
    d["updated"] = datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")
    tmp = OUT + ".new"
    with open(tmp, "w") as f:
        json.dump(d, f, separators=(",", ":"))
    os.chmod(tmp, 0o644)
    os.replace(tmp, OUT)


def trim(series, keys, now):
    keep = [i for i, t in enumerate(series["t"]) if now - t <= SPAN]
    for k in ["t"] + keys:
        series[k] = [series[k][i] for i in keep]


def wan_counters():
    rows = get_json(f"{ROUTER}/rest/interface?name={WAN_IF}&.proplist=name,rx-byte,tx-byte",
                    auth=f"{ROUTER_USER}:{ROUTER_PASS}")
    row = rows[0] if isinstance(rows, list) and rows else rows
    return int(row["rx-byte"]), int(row["tx-byte"])


def parse_label(s):
    try:
        return int(datetime.fromisoformat(str(s).replace("Z", "+00:00")).timestamp())
    except Exception:
        return None


def dns_minutes(url, key):
    d = get_json(f"{url}/api/dashboard/stats/get?token={key}&type=LastHour&utc=true")
    if d.get("status") != "ok":
        raise RuntimeError(f"Technitium status {d.get('status')}")
    chart = d["response"]["mainChartData"]
    total = next((ds for ds in chart["datasets"] if ds.get("label", "").lower() == "total"), chart["datasets"][0])
    vals = total["data"]
    stamps = [parse_label(l) for l in chart.get("labels", [])]
    if len(stamps) != len(vals) or None in stamps:   # fall back to "one per minute, ending now"
        end = int(time.time()) // 60 * 60
        stamps = [end - 60 * (len(vals) - 1 - i) for i in range(len(vals))]
    return dict(zip(stamps, vals))


def main():
    data = load()
    prev = None          # (time, rx, tx)
    next_dns = 0
    while True:
        now = time.time()
        # --- WAN
        try:
            rx, tx = wan_counters()
            if prev and rx >= prev[1] and tx >= prev[2] and now > prev[0]:
                dt = now - prev[0]
                w = data["wan"]
                w["t"].append(int(now))
                w["down"].append(round((rx - prev[1]) * 8 / dt / 1e6, 2))
                w["up"].append(round((tx - prev[2]) * 8 / dt / 1e6, 2))
            prev = (now, rx, tx)
            data["errors"].pop("wan", None)
        except Exception as e:
            prev = None
            data["errors"]["wan"] = str(e)[:200]
            w = data["wan"]
            w["t"].append(int(now)); w["down"].append(None); w["up"].append(None)
        data["wan"]["iface"] = WAN_IF
        trim(data["wan"], ["down", "up"], now)
        # --- DNS
        if now >= next_dns:
            next_dns = now + DNS_EVERY
            merged = {}
            for key, url, env in TECHNITIUM:
                try:
                    for ts, v in dns_minutes(url, os.environ.get(env, "")).items():
                        merged.setdefault(ts, {})[key] = v
                    data["errors"].pop("dns_" + key, None)
                except Exception as e:
                    data["errors"]["dns_" + key] = str(e)[:200]
            if merged:
                ts = sorted(t for t in merged if now - t <= SPAN)
                data["dns"] = {"t": ts,
                               "lan": [merged[t].get("lan") for t in ts],
                               "dmz": [merged[t].get("dmz") for t in ts]}
        save(data)
        time.sleep(max(1, WAN_EVERY - (time.time() - now)))


if __name__ == "__main__":
    main()
COLLECTOR
chmod 755 /usr/local/sbin/lab-graphs

cat > /srv/digest/www/graphs.html <<'GRAPHS'
<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Lab graph</title>
<style>
html,body{margin:0;height:100%;background:transparent;overflow:hidden}
#g{position:absolute;inset:4px 6px 2px 6px}
#g.stale{opacity:.5}
.lg-note{position:absolute;right:8px;bottom:20px;color:#fbbf24;font:11px ui-sans-serif,system-ui,sans-serif}
.lg{display:flex;flex-direction:column;font:12px/1.35 ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;color:#f5f5f5}
.lg-head{display:flex;flex-wrap:wrap;align-items:baseline;gap:2px 12px;padding:2px 2px 4px}
.lg-title{color:#a3a3a3;font-size:11px;text-transform:uppercase;letter-spacing:.04em;margin-right:auto}
.lg-legend{display:flex;gap:12px;flex-wrap:wrap}
.lg-item{display:inline-flex;align-items:center;gap:5px;white-space:nowrap}
.lg-item i,.lg-tip-r i{display:inline-block;width:12px;height:2px;border-radius:1px}
.lg-lab{color:#a3a3a3}.lg-item b{font-weight:600;font-variant-numeric:tabular-nums}
.lg-plot{position:relative;flex:1;min-height:0}
.lg-plot svg{display:block;position:absolute;inset:0}
.lg-grid{stroke:#262626;stroke-width:1}
.lg-ref{stroke:#525252;stroke-width:1;stroke-dasharray:4 3}
.lg-axis{fill:#8a8a8a;font-size:10px;font-variant-numeric:tabular-nums}
.lg-muted{fill:#8a8a8a;font-size:12px}
.lg-hair{stroke:#737373;stroke-width:1}
.lg-tip{position:absolute;z-index:2;pointer-events:none;background:#0a0a0a;border:1px solid rgba(149,214,0,.35);border-radius:6px;padding:5px 8px;min-width:110px;box-shadow:0 4px 14px rgba(0,0,0,.5)}
.lg-tip-t{color:#a3a3a3;font-size:11px;margin-bottom:2px}
.lg-tip-r{display:flex;align-items:center;gap:6px;white-space:nowrap}
.lg-tip-r b{font-weight:600;font-variant-numeric:tabular-nums}.lg-tip-r span{color:#a3a3a3}
.lg-halo{paint-order:stroke;stroke:#141414;stroke-width:3px;stroke-linejoin:round}
</style></head><body><div id="g"></div><div class="lg-note" id="note" hidden></div>
<script>// Lab graph: a small, dependency-free SVG time-series chart with a crosshair tooltip.
// drawChart(host, cfg, data)
//   cfg  = {title, unit, fmt(v), series:[{key,label,color,area}], ref:{value,label}|null, spanMin}
//   data = {t:[epoch seconds], <key>:[numbers|null], ...}
(function () {
  const NS = "http://www.w3.org/2000/svg";
  const el = (tag, attrs, parent) => {
    const n = document.createElementNS(NS, tag);
    for (const k in attrs) n.setAttribute(k, attrs[k]);
    if (parent) parent.appendChild(n);
    return n;
  };
  // Clean tick step (1, 2, 2.5, 5 x 10^n) giving 3-4 gridlines up to at least v.
  const niceStep = (v) => {
    if (!(v > 0)) return 1;
    const raw = v / 3.5, p = Math.pow(10, Math.floor(Math.log10(raw)));
    for (const m of [1, 2, 2.5, 5, 10]) if (m * p >= raw) return m * p;
    return 10 * p;
  };
  const hhmm = (s) => { const d = new Date(s * 1000); return d.toTimeString().slice(0, 5); };

  window.drawChart = function (host, cfg, data) {
    host.innerHTML = "";
    host.classList.add("lg");
    const head = document.createElement("div"); head.className = "lg-head"; host.appendChild(head);
    const title = document.createElement("span"); title.className = "lg-title"; title.textContent = cfg.title; head.appendChild(title);
    const legend = document.createElement("span"); legend.className = "lg-legend"; head.appendChild(legend);
    const t = data.t || [];
    const last = (k) => { const a = data[k] || []; for (let i = a.length - 1; i >= 0; i--) if (a[i] != null) return a[i]; return null; };
    for (const s of cfg.series) {
      const item = document.createElement("span"); item.className = "lg-item";
      const key = document.createElement("i"); key.style.background = s.color; item.appendChild(key);
      const lab = document.createElement("span"); lab.className = "lg-lab"; lab.textContent = s.label; item.appendChild(lab);
      const val = document.createElement("b"); const v = last(s.key);
      val.textContent = v == null ? "-" : cfg.fmt(v) + " " + cfg.unit; item.appendChild(val);
      legend.appendChild(item);
    }
    const plot = document.createElement("div"); plot.className = "lg-plot"; host.appendChild(plot);
    const tip = document.createElement("div"); tip.className = "lg-tip"; tip.hidden = true; plot.appendChild(tip);

    const W = Math.max(200, plot.clientWidth), H = Math.max(80, plot.clientHeight);
    const m = { l: 34, r: 8, t: 6, b: 18 };
    const svg = el("svg", { width: W, height: H, viewBox: `0 0 ${W} ${H}`, role: "img",
      "aria-label": cfg.title + ": " + cfg.series.map(s => s.label + " " + (last(s.key) == null ? "no data" : cfg.fmt(last(s.key)) + " " + cfg.unit)).join(", ") }, null);
    plot.insertBefore(svg, tip);
    if (!t.length) {
      el("text", { x: W / 2, y: H / 2, "text-anchor": "middle", class: "lg-muted" }, svg).textContent = "Waiting for data";
      return;
    }
    const t1 = t[t.length - 1], t0 = t1 - cfg.spanMin * 60;
    let ymax = 0;
    for (const s of cfg.series) for (const v of data[s.key] || []) if (v != null && v > ymax) ymax = v;
    if (cfg.ref && cfg.ref.value > ymax * 0.6) ymax = Math.max(ymax, cfg.ref.value);
    const ystep = niceStep(ymax * 1.05);
    ymax = Math.max(ystep, Math.ceil((ymax * 1.05) / ystep) * ystep);
    const X = (s) => m.l + (W - m.l - m.r) * (s - t0) / (t1 - t0);
    const Y = (v) => H - m.b - (H - m.t - m.b) * v / ymax;

    // grid + y ticks (hairline, solid, recessive)
    for (let v = 0; v <= ymax + 1e-9; v += ystep) {
      const y = Y(v);
      el("line", { x1: m.l, x2: W - m.r, y1: y, y2: y, class: "lg-grid" }, svg);
      el("text", { x: m.l - 5, y: y + 3, "text-anchor": "end", class: "lg-axis" }, svg).textContent = cfg.fmt(v, true);
    }
    // x ticks every 15 minutes
    const step = 15 * 60;
    for (let s = Math.ceil(t0 / step) * step; s <= t1; s += step) {
      el("text", { x: X(s), y: H - 4, "text-anchor": "middle", class: "lg-axis" }, svg).textContent = hhmm(s);
    }
    if (cfg.ref) el("line", { x1: m.l, x2: W - m.r, y1: Y(cfg.ref.value), y2: Y(cfg.ref.value), class: "lg-ref" }, svg);
    // series: area wash first, then 2px lines on top
    const paths = cfg.series.map(s => {
      const a = data[s.key] || [];
      let d = "", pen = false;
      t.forEach((ts, i) => {
        if (ts < t0) return;
        const v = a[i];
        if (v == null) { pen = false; return; }
        d += (pen ? "L" : "M") + X(ts).toFixed(1) + " " + Y(v).toFixed(1);
        pen = true;
      });
      return { s, d };
    });
    for (const { s, d } of paths) if (s.area && d) {
      const segs = d.split("M").filter(Boolean);
      for (const seg of segs) {
        const pts = seg.split("L");
        const x0 = pts[0].split(" ")[0], xN = pts[pts.length - 1].split(" ")[0];
        el("path", { d: `M${x0} ${Y(0)}L${seg}L${xN} ${Y(0)}Z`, fill: s.color, "fill-opacity": 0.1, stroke: "none" }, svg);
      }
    }
    for (const { s, d } of paths) if (d) el("path", { d, fill: "none", stroke: s.color, "stroke-width": 2, "stroke-linejoin": "round", "stroke-linecap": "round" }, svg);

    if (cfg.ref) el("text", { x: m.l + 4, y: Y(cfg.ref.value) - 4, "text-anchor": "start", class: "lg-axis lg-halo" }, svg).textContent = cfg.ref.label;
    // crosshair + tooltip: snaps to the nearest sample, lists every series
    const hair = el("line", { y1: m.t, y2: H - m.b, class: "lg-hair", visibility: "hidden" }, svg);
    const dots = cfg.series.map(s => el("circle", { r: 4, fill: s.color, stroke: "#141414", "stroke-width": 2, visibility: "hidden" }, svg));
    const hit = el("rect", { x: m.l, y: 0, width: W - m.l - m.r, height: H, fill: "transparent" }, svg);
    const idxs = t.map((ts, i) => i).filter(i => t[i] >= t0);
    const show = (px) => {
      let best = idxs[0], bd = Infinity;
      for (const i of idxs) { const dd = Math.abs(X(t[i]) - px); if (dd < bd) { bd = dd; best = i; } }
      const x = X(t[best]);
      hair.setAttribute("x1", x); hair.setAttribute("x2", x); hair.setAttribute("visibility", "visible");
      tip.textContent = "";
      const h = document.createElement("div"); h.className = "lg-tip-t"; h.textContent = hhmm(t[best]); tip.appendChild(h);
      cfg.series.forEach((s, k) => {
        const v = (data[s.key] || [])[best];
        const row = document.createElement("div"); row.className = "lg-tip-r";
        const key = document.createElement("i"); key.style.background = s.color; row.appendChild(key);
        const b = document.createElement("b"); b.textContent = v == null ? "-" : cfg.fmt(v) + " " + cfg.unit; row.appendChild(b);
        const l = document.createElement("span"); l.textContent = s.label; row.appendChild(l);
        tip.appendChild(row);
        if (v == null) dots[k].setAttribute("visibility", "hidden");
        else { dots[k].setAttribute("cx", x); dots[k].setAttribute("cy", Y(v)); dots[k].setAttribute("visibility", "visible"); }
      });
      tip.hidden = false;
      const tw = tip.offsetWidth;
      tip.style.left = (x + 12 + tw > W ? x - 12 - tw : x + 12) + "px";
      tip.style.top = m.t + "px";
    };
    const hide = () => { hair.setAttribute("visibility", "hidden"); dots.forEach(d => d.setAttribute("visibility", "hidden")); tip.hidden = true; };
    hit.addEventListener("pointermove", (e) => show(e.offsetX));
    hit.addEventListener("pointerleave", hide);
  };
})();
</script>
<script>
// graphs.html?g=wan | ?g=dns  -- reads graphs.json written by lab-graphs on the Homepage container.
const which = new URLSearchParams(location.search).get("g") === "dns" ? "dns" : "wan";
const mbps = (v, axis) => axis ? String(Math.round(v)) : (v < 10 ? v.toFixed(1) : String(Math.round(v)));
const cnt = (v) => v >= 1000 ? (v / 1000).toFixed(1).replace(/\.0$/, "") + "K" : String(Math.round(v));
const CFG = {
  wan: { title: "Mbps", unit: "Mbps", fmt: mbps, spanMin: 60, ref: { value: 38, label: "upload cap 38 (CAKE)" },
         series: [{ key: "down", label: "Down", color: "#6fa300", area: true }, { key: "up", label: "Up", color: "#9466ea" }] },
  dns: { title: "queries / min", unit: "/min", fmt: cnt, spanMin: 60, ref: null,
         series: [{ key: "lan", label: "LAN", color: "#6fa300", area: true }, { key: "dmz", label: "DMZ", color: "#9466ea" }] },
}[which];
const host = document.getElementById("g"), note = document.getElementById("note");
let last = null;
function draw() { if (last) drawChart(host, CFG, last); }
async function load() {
  try {
    const r = await fetch("graphs.json", { cache: "no-store" });
    if (!r.ok) throw new Error("HTTP " + r.status);
    const d = await r.json();
    last = d[which];
    const errs = Object.entries(d.errors || {}).filter(([k]) => k.startsWith(which));
    const age = (Date.now() - Date.parse(d.updated)) / 1000;
    const stale = !(age < 90);
    host.classList.toggle("stale", stale);
    note.textContent = stale ? "collector stopped" : errs.length ? "source error: " + errs.map(([k]) => k).join(", ") : "";
    note.hidden = !note.textContent;
    draw();
  } catch (e) {
    host.classList.add("stale");
    note.textContent = "can't load graphs.json"; note.hidden = false;
    if (!last) drawChart(host, CFG, { t: [] });
  }
}
load();
setInterval(load, which === "wan" ? 10000 : 60000);
new ResizeObserver(draw).observe(host);
</script></body></html>
GRAPHS
chmod 644 /srv/digest/www/graphs.html
ln -sfn /var/lib/lab-graphs/graphs.json /srv/digest/www/graphs.json

cat > /etc/systemd/system/lab-graphs.service <<'UNIT'
[Unit]
Description=Collect WAN traffic and DNS query rates for Homepage's graphs
After=network-online.target
Wants=network-online.target

[Service]
User=labgraphs
Group=labgraphs
EnvironmentFile=/etc/homepage/secrets.env
StateDirectory=lab-graphs
StateDirectoryMode=0755
ExecStart=/usr/bin/python3 /usr/local/sbin/lab-graphs
Restart=always
RestartSec=10
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable lab-graphs >/dev/null 2>&1
systemctl restart lab-graphs

python3 - <<'TILES'
import os, shutil, yaml
p = "/opt/homepage/app/config/services.yaml"
class D(yaml.SafeDumper):
    def increase_indent(self, flow=False, indentless=False):
        return super().increase_indent(flow, False)
name_of = lambda i: next(iter(i)) if isinstance(i, dict) and len(i) == 1 else None
svc = yaml.safe_load(open(p))
adds = {"Monitoring": ("WAN traffic", "Router ether1, last 60 min", "wan"),
        "Infrastructure": ("DNS queries", "Technitium LAN vs DMZ, last 60 min", "dns")}
for g in svc:
    n = name_of(g)
    if n in adds:
        title, desc, key = adds[n]
        g[n] = [t for t in g[n] if name_of(t) != title]
        g[n].append({title: {"description": desc, "widget": {
            "type": "iframe", "name": "graph" + key,
            "src": f"https://digest.example.com/graphs.html?g={key}"}}})
if not os.path.exists(p + ".pre-graphs"):
    shutil.copy2(p, p + ".pre-graphs")
with open(p + ".new", "w") as f:
    yaml.dump(svc, f, Dumper=D, sort_keys=False, allow_unicode=True, width=200, indent=2)
os.replace(p + ".new", p)
print("Added 'WAN traffic' under Monitoring and 'DNS queries' under Infrastructure")
TILES
systemctl restart homepage

echo "Waiting 25 s for the first samples..."
sleep 25
python3 - <<'SHOW'
import json
d = json.load(open("/var/lib/lab-graphs/graphs.json"))
w, n = d["wan"], d["dns"]
print("updated:", d.get("updated"))
print(f'WAN {w["iface"]}: {len(w["t"])} samples, latest down {w["down"][-1] if w["down"] else "-"} Mbps, up {w["up"][-1] if w["up"] else "-"} Mbps')
print(f'DNS: {len(n["t"])} minutes, latest LAN {n["lan"][-1] if n["lan"] else "-"}/min, DMZ {n["dmz"][-1] if n["dmz"] else "-"}/min')
print("errors:", d.get("errors") or "none")
SHOW
