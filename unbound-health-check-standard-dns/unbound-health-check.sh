#!/usr/bin/env bash
# unbound-health-check — keep Technitium's forwarders pointed at healthy Unbound upstreams.
#
# Ubuntu port of the RouterOS dns-fallback-check pattern:
#   - probe with a REAL DNS query, never ping (a resolver can answer ICMP with DNS wedged)
#   - forwarders are set by IP, never hostname
#   - flip automatically on failure, flip back on recovery
#
# Runs as a systemd oneshot every 30s (see unbound-health-check.timer).

set -u

CONFIG="${CONFIG:-/etc/unbound-health-check/config}"
# shellcheck source=/dev/null
. "$CONFIG" || { echo "cannot read $CONFIG" >&2; exit 1; }

STATE_DIR="${STATE_DIR:-/run/unbound-health-check}"
FAIL_THRESHOLD="${FAIL_THRESHOLD:-2}"
OK_THRESHOLD="${OK_THRESHOLD:-2}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-2}"
declare -A LABEL 2>/dev/null || true   # guard set -u if config omits the label map
SLOW_PROBE_INTERVAL="${SLOW_PROBE_INTERVAL:-600}"
declare -A SLOW=(); for a in ${SLOW_UPSTREAMS:-}; do SLOW["$a"]=1; done   # metered (cloud) upstreams
mkdir -p "$STATE_DIR"

TOKEN="$(cat "$TOKEN_FILE")" || { echo "cannot read token file $TOKEN_FILE" >&2; exit 1; }

log() { logger -t unbound-health-check -p "daemon.$1" -- "$2"; }

# Healthy = the probe name returns actual answer data (+short empty on
# SERVFAIL/timeout — catches the dead-upstream case, not just dead transport).
probe() {
    [ -n "$(dig +time="$PROBE_TIMEOUT" +tries=1 @"$1" "$PROBE_NAME" A +short 2>/dev/null)" ]
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
# -L follows the console's HTTP->HTTPS redirect (307, method+body preserved);
# CURL_OPTS (config, optional) carries "-k" for the loopback HTTPS cert.
api() {
    local endpoint="$1"; shift
    # shellcheck disable=SC2086
    curl -sfL --max-time 5 ${CURL_OPTS:-} -X POST "$TECHNITIUM_URL/api/$endpoint" \
        --data-urlencode "token=$TOKEN" "$@"
}

# Normalize one forwarder token to its bare address, so membership tests and the
# change-compare ignore whatever Technitium adds on read-back (v6 [brackets], a
# ":port" suffix, or a "name (ip)" wrapper). Idempotent on plain hostnames.
norm() {
    printf '%s' "$1" | sed -E '
        s/.*\(([^)]+)\).*/\1/;
        s/^[[:space:]]+//; s/[[:space:]]+$//;
        s/^\[([^]]+)\](:[0-9]+)?$/\1/;
        s/^([0-9.]+):[0-9]+$/\1/;
    '
}

# The addresses this script MANAGES (health-checked upstreams). Any OTHER forwarder
# Technitium has is left untouched. We also register each LABEL hostname as managed
# so an old bare-hostname entry (e.g. "ns1.example.com") is recognized as ours
# and REPLACED by the pinned "ns1.example.com (ip)" form, not preserved alongside.
declare -A MANAGED=()
for ip in $UPSTREAMS; do MANAGED["$(norm "$ip")"]=1; done
for ip in "${!LABEL[@]}"; do MANAGED["${LABEL[$ip]}"]=1; done

# Health-check every upstream (v4 and v6 independently — an address-family failure
# like unreachable v6 egress only drops that family) and collect the healthy ones,
# written as "label (ip)" when a LABEL is set, else the bare IP.
healthy=()
for ip in $UPSTREAMS; do
    [ "$(health "$ip")" = up ] || continue
    lbl="${LABEL[$ip]:-}"
    if [ -n "$lbl" ]; then healthy+=("$lbl ($ip)"); else healthy+=("$ip"); fi
done

if [ ${#healthy[@]} -eq 0 ]; then
    # No healthy Unbound to point at — leave the whole list (down upstreams AND
    # ns1/ns2) untouched rather than collapsing onto the authoritative-only pair.
    log crit "ALL DMZ upstreams down ($UPSTREAMS); forwarders left unchanged"
    exit 0
fi

settings="$(api settings/get)" \
    || { log err "Technitium API unreachable at $TECHNITIUM_URL"; exit 1; }
mapfile -t curlist < <(jq -r '.response.forwarders // [] | .[]' <<<"$settings")

# Keep every forwarder that isn't one of our managed upstreams, verbatim.
other=()
for f in "${curlist[@]}"; do
    [ -n "${MANAGED[$(norm "$f")]:-}" ] || other+=("$f")
done

# Desired list = preserved others (ns1/ns2, …) + healthy managed upstreams.
newlist=("${other[@]}" "${healthy[@]}")
want="$(IFS=,; printf '%s' "${newlist[*]}")"
current="$(IFS=,; printf '%s' "${curlist[*]}")"

# Compare as a normalized, order-insensitive set so reformatting/order never thrash.
# (printf %s\n per token — norm() itself is newline-free for the membership tests.)
setify() { tr ',' '\n' <<<"$1" | while IFS= read -r t; do [ -n "$t" ] && printf '%s\n' "$(norm "$t")"; done | sort | paste -sd, -; }

if [ "$(setify "$current")" != "$(setify "$want")" ]; then
    resp="$(api settings/set --data-urlencode "forwarders=$want")"
    if [ "$(jq -r '.status' <<<"$resp" 2>/dev/null)" = "ok" ]; then
        log notice "forwarders updated: '${current:-none}' -> '$want' (managed IPs only; others preserved)"
    else
        log err "failed to set forwarders to '$want': ${resp:-no response}"
    fi
fi
