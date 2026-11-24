#!/usr/bin/env python3
"""Add GeoIP enrichment for Suricata's data.src_ip to the Wazuh alerts ingest pipeline (siem, 2026-11-20).
usage: wz_geo.py show|apply|backfill-count|backfill|verify"""
import json, subprocess, sys, time, copy
BASE = "https://127.0.0.1:9200"
CERT = ["--cert", "/etc/wazuh-indexer/certs/admin.pem", "--key", "/etc/wazuh-indexer/certs/admin-key.pem"]
PIPE = "filebeat-7.10.2-wazuh-alerts-pipeline"
DISK = "/usr/share/filebeat/module/wazuh/alerts/ingest/pipeline.json"
BACKFILL = "wazuh-suricata-geoip-backfill"
MARK = "suricata src_ip geoip (added 2026-11-20)"

def es(method, path, body=None):
    cmd = ["curl", "-sk", "-X", method] + CERT + [BASE + path, "-H", "Content-Type: application/json"]
    if body is not None:
        cmd += ["-d", json.dumps(body)]
    out = subprocess.run(cmd, capture_output=True, text=True, timeout=600).stdout
    try:
        return json.loads(out)
    except Exception:
        return {"_raw": out[:400]}

def live():
    return es("GET", "/_ingest/pipeline/" + PIPE)[PIPE]

def geo_proc(base):
    props = list(base.get("properties") or ["city_name", "country_name", "region_name", "location"])
    if "ip" not in props:
        props.append("ip")
    return {"geoip": {"field": "data.src_ip", "target_field": base.get("target_field", "GeoLocation"),
                      "properties": props, "ignore_missing": True, "ignore_failure": True,
                      "if": "ctx.GeoLocation == null && ctx.data != null && ctx.data.src_ip != null",
                      "tag": MARK}}

def find_geo(procs):
    for i, p in enumerate(procs):
        if "geoip" in p and p["geoip"].get("tag") != MARK:
            return i, p["geoip"]
    return None, None

def has_mark(procs):
    return any("geoip" in p and p["geoip"].get("tag") == MARK for p in procs)

cmd = sys.argv[1] if len(sys.argv) > 1 else "show"
if cmd == "show":
    p = live()
    for i, x in enumerate(p["processors"]):
        k = list(x)[0]
        print(i, k, json.dumps(x[k])[:150])
    try:
        d = json.load(open(DISK))
        print("DISK==LIVE:", json.dumps(d, sort_keys=True) == json.dumps(p, sort_keys=True), "| disk processors:", len(d.get("processors", [])))
    except Exception as e:
        print("disk read error:", e)
elif cmd == "apply":
    ts = time.strftime("%Y%m%d-%H%M%S")
    p = live()
    json.dump(p, open("/root/pipeline-live-pre-suricata-geo-%s.json" % ts, "w"))
    if has_mark(p["processors"]):
        print("live: already has the suricata geoip processor")
    else:
        i, base = find_geo(p["processors"])
        if i is None:
            sys.exit("no existing geoip processor found; not changing anything")
        p["processors"].insert(i + 1, geo_proc(base))
        print("live PUT:", es("PUT", "/_ingest/pipeline/" + PIPE, p))
    try:
        raw = open(DISK).read()
        d = json.loads(raw)
        open(DISK + ".pre-suricata-geo-" + ts, "w").write(raw)
        if has_mark(d["processors"]):
            print("disk: already patched")
        else:
            j, b2 = find_geo(d["processors"])
            if j is None:
                print("disk: no geoip processor found, left unchanged")
            else:
                d["processors"].insert(j + 1, geo_proc(b2))
                open(DISK, "w").write(json.dumps(d, indent=2) + "\n")
                print("disk: patched (backup %s.pre-suricata-geo-%s)" % (DISK, ts))
    except Exception as e:
        print("disk: not patched:", e)
    # simulate on a sample suricata-like doc
    i, base = find_geo(live()["processors"])
    sim = es("POST", "/_ingest/pipeline/_simulate", {"pipeline": {"processors": [geo_proc(base)]},
          "docs": [{"_source": {"data": {"src_ip": "195.182.16.23"}}}, {"_source": {"data": {"src_ip": "192.168.30.58"}}}]})
    for doc in sim.get("docs", []):
        print("simulate:", json.dumps(doc.get("doc", {}).get("_source", {}))[:220])
elif cmd in ("backfill-count", "backfill"):
    i, base = find_geo(live()["processors"])
    es("PUT", "/_ingest/pipeline/" + BACKFILL, {"description": "one-off: geoip for suricata data.src_ip (2026-11-20)", "processors": [geo_proc(base)]})
    q = {"bool": {"filter": [{"exists": {"field": "data.src_ip"}}, {"term": {"rule.groups": "suricata"}}],
                  "must_not": [{"exists": {"field": "GeoLocation"}}]}}
    print("candidates:", es("POST", "/wazuh-alerts-*/_count", {"query": q}).get("count"))
    if cmd == "backfill":
        r = es("POST", "/wazuh-alerts-*/_update_by_query?pipeline=%s&conflicts=proceed&wait_for_completion=true&refresh=true" % BACKFILL, {"query": q})
        print("update_by_query:", {k: r.get(k) for k in ("total", "updated", "noops", "version_conflicts", "failures", "took")} if "total" in r else r)
elif cmd == "verify":
    q = {"bool": {"filter": [{"term": {"rule.groups": "suricata"}}, {"exists": {"field": "GeoLocation.location"}}]}}
    r = es("POST", "/wazuh-alerts-*/_search", {"size": 0, "query": q, "aggs": {"c": {"terms": {"field": "GeoLocation.country_name", "size": 8}}}})
    print("suricata with GeoLocation:", r.get("hits", {}).get("total"), [(b["key"], b["doc_count"]) for b in r.get("aggregations", {}).get("c", {}).get("buckets", [])])
