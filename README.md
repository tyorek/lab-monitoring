# lab-monitoring

Small monitoring pieces for the home lab dashboard (Homepage + Uptime Kuma).

| Folder | What it is |
|---|---|
| `lab-graphs/` | collector + chart page for live WAN throughput (router ether1, with the CAKE cap) and per-minute DNS queries (LAN vs DMZ Technitium); read-only credentials from an `EnvironmentFile` |
| `nas-health/` | root-run OMV NAS health snapshot (AD trust, time sync, Samba/winbind, RAID, SMART, OMV services) every 5 min, exposed as text to the digest agent over a `cat`-only SSH key and as JSON to Homepage |
| `dns-probe/` | per-minute DoT (cert-validated) and plain-DNS probes of the Unbound resolvers with 24 h uptime, plus a Homepage layout helper |
| `unbound-health-check/`, `unbound-health-check-standard-dns/` | systemd timer that health-checks the Unbound forwarders and pulls a failed one out of Technitium's forwarder list (DoT and plain-53 variants) |
| `wazuh/suricata-geoip.py` | adds GeoIP enrichment for Suricata `data.src_ip` to the Wazuh alerts ingest pipeline, with backfill and verify |

---

*Published from a home lab. Site identifiers are sanitized: public IPv4 uses the documentation ranges (203.0.113.0/24, 198.51.100.0/24), the delegated IPv6 prefix is `2001:db8::/32`, the ULA prefix is `fd12:3456:789a::/48`, domains are `example.com` / `home.arpa`, MAC addresses, Wi-Fi SSIDs, serials, keys and names are replaced. RFC 1918 addresses are left as they are so the layouts still read. Credentials are never in these files; scripts read them from `agent.env` or similar files that are not published.*
