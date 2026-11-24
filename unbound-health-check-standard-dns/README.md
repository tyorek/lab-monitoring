# unbound-health-check

Ubuntu port of the RouterOS `dns-fallback-check` pattern, running on the Technitium
server (192.168.15.9 / 2001:db8:4a00:1f85:be24:11ff:fe6a:93b0). Every 30s it probes
every Unbound upstream address — v4 and v6 independently — with a **real DNS query**,
never ping, and keeps Technitium's forwarder list pointed only at the healthy
addresses via the Technitium HTTP API.

Upstream addresses (4 independent probe targets):

| Instance | IPv4 | IPv6 |
|---|---|---|
| unbound1 | 192.168.15.10 | fd12:3456:789a:15:be24:11ff:fe4d:4c62 |
| unbound2 | 192.168.15.11 | fd12:3456:789a:15:be24:11ff:fe15:71fa |

Behavior: forwarders = all healthy addresses. An instance dying drops both its
addresses; a v6-only failure (e.g., ISP re-delegates the prefix) drops just the v6
forwarders while v4 keeps serving. All four down → forwarders left unchanged,
logged `crit`. Recovery restores addresses automatically.

Hysteresis: 2 consecutive failed probes to mark down, 2 good to mark up
(~60s each way at the 30s interval) — no flapping on a single lost packet.
The probe requires actual answer data, so a resolver returning SERVFAIL from a
dead upstream counts as down (the postmortem case), not just a dead socket.

## Install (on the Technitium box)

1. Copy this folder to the server, e.g. `scp -r unbound-health-check labadmin@192.168.15.9:~/`
2. Create an API token in Technitium: **Administration → Sessions → Create Token**
   (use an account with Settings permission; token is non-expiring).
3. ```
   sudo mkdir -p /etc/unbound-health-check
   echo 'YOUR_TOKEN' | sudo tee /etc/unbound-health-check/token
   sudo chmod 600 /etc/unbound-health-check/token
   sudo bash install.sh
   ```

## Verify

```
journalctl -t unbound-health-check -f        # watch decisions
systemctl list-timers unbound-health-check*  # timer firing
sudo systemctl stop unbound   # on 192.168.15.10 — within ~60s forwarders drop to .11
sudo systemctl start unbound  # within ~60s both restored
```

Settings live in `/etc/unbound-health-check/config` (probe name, thresholds, IPs).

## Notes

- Forwarders are set as raw IPs only — never hostnames (see postmortem: bootstrap deadlock).
- `settings/set` only touches the `forwarders` parameter; everything else in Technitium is untouched.
- State lives in `/run` (tmpfs) — resets to "assume up" on reboot, which self-corrects within one cycle.
- This complements the router script: the router handles *client → Technitium* failover; this handles *Technitium → Unbound* failover.
