#!/usr/bin/env bash
# unbound-health-check — keep Technitium's forwarders pointed at healthy Unbound upstreams.
#
# Ubuntu port of the RouterOS dns-fallback-check pattern:
#   - probe with a REAL DNS query, never ping (a resolver can answer ICMP with DNS wedged)
#   - probe over DoT (TLS/853) with cert validation, because the Unbounds listen
#     ONLY on 853 with real Let's Encrypt certs — a plaintext :53 probe always fails
#   - forwarders are set by IP, never hostname (cert name is pinned separately)
#   - flip automatically on failure, flip back on recovery
#
# Requires kdig (knot-dnsutils); dig cannot speak DoT.
#
# Runs as a systemd oneshot every 30s (see unbound-health-check.timer).

set -u -o pipefail

CONFIG="${CONFIG:-/etc/unbound-health-check/config}"
# shellcheck source=/dev/null
. "$CONFIG" || { echo "cannot read $CONFIG" >&2; exit 1; }

STATE_DIR="${STATE_DIR:-/run/unbound-health-check}"
FAIL_THRESHOLD="${FAIL_THRESHOLD:-2}"
OK_THRESHOLD="${OK_THRESHOLD:-2}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-2}"
DOT_PORT="${DOT_PORT:-853}"
declare -A DOT_TLS_NAME 2>/dev/null || true   # guard set -u if config omits the map
SLOW_PROBE_INTERVAL="${SLOW_PROBE_INTERVAL:-600}"
declare -A SLOW=(); for a in ${SLOW_UPSTREAMS:-}; do SLOW["$a"]=1; done   # metered (cloud) upstreams
mkdir -p "$STATE_DIR"

TOKEN="$(cat "$TOKEN_FILE")" || { echo "cannot read token file $TOKEN_FILE" >&2; exit 1; }

log() { logger -t unbound-health-check -p "daemon.$1" -- "$2"; }

# Healthy = the probe name returns actual answer data over a validated DoT session.
# +short is empty on SERVFAIL/timeout AND on TLS/cert failure, so this catches a
# dead upstream, an expired cert, and a dead socket alike — not just dead transport.
# Cert name is pinned per-address via DOT_TLS_NAME (an LE cert never has the IP in
# its SAN, so validation needs the hostname); if unset, falls back to opportunistic
# TLS with no validation rather than failing the box outright.
probe() {
    local ip="$1" name="${DOT_TLS_NAME[$ip]:-}" out
    if [ -n "$name" ]; then
        out="$(kdig +tls +tls-ca +tls-hostname="$name" +tls-sni="$name" \
                    +timeout="$PROBE_TIMEOUT" +retry=0 \
                    @"$ip" -p "$DOT_PORT" "$PROBE_NAME" A +short 2>/dev/null)"
    else
        out="$(kdig +tls +timeout="$PROBE_TIMEOUT" +retry=0 \
                    @"$ip" -p "$DOT_PORT" "$PROBE_NAME" A +short 2>/dev/null)"
    fi
    [ -n "$out" ]
}

# Hysteresis: flip up<->down only after N consecutive contrary probes.
# Prints "up" or "down" for resolver $1.
health() {
    local ip="$1" state count now last
    state="$(cat "$STATE_DIR/$ip.state" 2>/dev/null || echo up)"
    count="$(cat "$STATE_DIR/$ip.count" 2>/dev/null || echo 0)"
    # Metered (cloud) upstreams: actually probe at most once per SLOW_PROBE_INTERVAL
    # to limit paid egress. Between probes, reuse the cached state — no query sent.
    if [ -n "${SLOW[$ip]:-}" ]; then
        now="$(date +%s)"; last="$(cat "$STATE_DIR/$ip.probed" 2>/dev/null || echo 0)"
        if [ "$((now - last))" -lt "$SLOW_PROBE_INTERVAL" ]; then echo "$state"; return; fi
        echo "$now" > "$STATE_DIR/$ip.probed"
    fi
    if probe "$ip"; then
        if [ "$state" = down ]; then
            count=$((count + 1))
            if [ "$count" -ge "$OK_THRESHOLD" ]; then
                state=up; count=0
                log notice "$ip recovered ($OK_THRESHOLD consecutive good probes)"
            fi
        else
            count=0
        fi
    else
        if [ "$state" = up ]; then
            count=$((count + 1))
            if [ "$count" -ge "$FAIL_THRESHOLD" ]; then
                state=down; count=0
                log warning "$ip marked DOWN ($FAIL_THRESHOLD consecutive failed probes)"
            fi
        else
            count=0
        fi
    fi
    echo "$state" > "$STATE_DIR/$ip.state"
    echo "$count" > "$STATE_DIR/$ip.count"
    echo "$state"
}

# Technitium API helper. POST keeps the token out of URLs/proc listings.
# CURL_OPTS (config, optional): extra flags, e.g. "-k" for a self-signed console cert.
api() {
    local endpoint="$1"; shift
    # shellcheck disable=SC2086
    curl -sf --max-time 5 ${CURL_OPTS:-} -X POST "$TECHNITIUM_URL/api/$endpoint" \
        --data-urlencode "token=$TOKEN" "$@"
}

# order-insensitive canonical IP set of a comma-separated forwarder list.
# Normalizes every cosmetic thing Technitium does on read-back so it never
# triggers a needless rewrite (these mismatches were the every-cycle thrash):
#   - "hostname (ip)" DoT form vs bare "ip"      -> keep the parenthetical address
#   - ":853" appended to the hostname            -> ignored (it's outside the parens)
#   - v6 wrapped in [brackets] on read-back       -> strip [ and ]
ips_of() {
    tr ',' '\n' <<<"$1" \
      | sed -E 's/.*\(([^)]+)\).*/\1/' \
      | tr -d '[]' \
      | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
      | sed '/^$/d' | sort | paste -sd, -
}

# Probe every upstream address independently (v4 and v6 checked separately —
# an address-family failure like a re-delegated prefix only drops that family).
# Build the forwarder list in Technitium's DoT form: "certname (ip)". The
# hostname supplies TLS SNI + cert validation; the pinned IP means Technitium
# connects directly and never has to RESOLVE the forwarder (no bootstrap loop —
# postmortem lesson). Bare IP only if no cert name is mapped (unvalidated TLS).
want=""
for ip in $UPSTREAMS; do
    [ "$(health "$ip")" = up ] || continue
    name="${DOT_TLS_NAME[$ip]:-}"
    entry="$ip"; [ -n "$name" ] && entry="$name ($ip)"
    want="${want:+$want,}$entry"
done

if [ -z "$want" ]; then
    # Nothing healthy to point at — leaving forwarders alone beats pointing at nothing.
    log crit "ALL upstream addresses down ($UPSTREAMS); forwarders left unchanged"
    exit 0
fi

settings="$(api settings/get)" \
    || { log err "Technitium API unreachable at $TECHNITIUM_URL"; exit 1; }
current="$(jq -r '.response.forwarders // [] | join(",")' <<<"$settings")"
proto="$(jq -r '.response.forwarderProtocol // "Udp"' <<<"$settings")"

# Change only when the healthy-IP set differs OR the transport isn't DoT.
# Setting forwarderProtocol=Tls is what was missing: without it Technitium was
# forwarding to the 853-only Unbounds over plain UDP/53 and getting nothing.
if [ "$(ips_of "$current")" != "$(ips_of "$want")" ] || [ "$proto" != "Tls" ]; then
    resp="$(api settings/set \
        --data-urlencode "forwarders=$want" \
        --data-urlencode "forwarderProtocol=Tls")"
    if [ "$(jq -r '.status' <<<"$resp" 2>/dev/null)" = "ok" ]; then
        log notice "forwarders set (DoT): '${current:-none}'/$proto -> '$want'/Tls"
    else
        log err "failed to set forwarders '$want' (Tls): ${resp:-no response}"
    fi
fi
