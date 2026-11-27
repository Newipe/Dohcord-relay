#!/usr/bin/env bash
# Pishcord Relay verification suite.
#
# Checks a live installation end to end and prints one line per check. Exits
# non-zero when any check fails. Nothing here changes configuration; the only
# side effects are temporary TURN allocations, a short-lived echo peer used by
# the media test, and TLS connections through the proxy.
#
# Run as root (or as a user that can read /etc/pishcord-relay):
#
#   sudo deploy/scripts/verify.sh
#
# Environment overrides (used by the installer and by local testing):
#   PISHCORD_RELAY_CONFIG        config.env path
#   PISHCORD_RELAY_TURNSERVER_CONF, PISHCORD_RELAY_SECRET_FILE, PISHCORD_RELAY_TLS_CERT
#   PISHCORD_RELAY_SQUID_CONF, PISHCORD_RELAY_SQUID_UNIT, PISHCORD_RELAY_API_UNIT
#   PISHCORD_RELAY_PROXY_URL, PISHCORD_RELAY_API_URL
#   PISHCORD_RELAY_SKIP_UNITS, PISHCORD_RELAY_SKIP_RENEW, PISHCORD_RELAY_CERTBOT
#   PISHCORD_RELAY_PROBE_PEER, PISHCORD_RELAY_PROBE_PEER_PORT
#   PISHCORD_RELAY_CA_FILE, PISHCORD_RELAY_ENDPOINT
set -uo pipefail

CONFIG="${PISHCORD_RELAY_CONFIG:-/etc/pishcord-relay/config.env}"
TURN_CONF="${PISHCORD_RELAY_TURNSERVER_CONF:-/etc/pishcord-relay/turnserver.conf}"
SQUID_CONF="${PISHCORD_RELAY_SQUID_CONF:-/etc/pishcord-relay/squid.conf}"
SQUID_UNIT="${PISHCORD_RELAY_SQUID_UNIT:-pishcord-relay-squid.service}"
API_UNIT="${PISHCORD_RELAY_API_UNIT:-pishcord-relay-api.service}"
SECRET_FILE="${PISHCORD_RELAY_SECRET_FILE:-/etc/pishcord-relay/turn-secret}"
TLS_CERT="${PISHCORD_RELAY_TLS_CERT:-/etc/pishcord-relay/tls/fullchain.pem}"
TURN_LOG="${PISHCORD_RELAY_TURN_LOG:-/var/log/pishcord-relay/turnserver/turnserver.log}"
COTURN_UNIT="${PISHCORD_RELAY_COTURN_UNIT:-pishcord-relay-coturn.service}"
CERT_NAME="${PISHCORD_RELAY_CERT_NAME:-pishcord-relay}"
SKIP_UNITS="${PISHCORD_RELAY_SKIP_UNITS:-0}"
SKIP_RENEW="${PISHCORD_RELAY_SKIP_RENEW:-0}"
PROBE_PEER="${PISHCORD_RELAY_PROBE_PEER:-}"
PROBE_PEER_PORT="${PISHCORD_RELAY_PROBE_PEER_PORT:-3480}"
CA_FILE="${PISHCORD_RELAY_CA_FILE:-}"
# Certificate authority for the proxy listener. Empty means the system trust
# store; set it only when testing against a staging certificate.
PROXY_CA="${PISHCORD_RELAY_PROXY_CA:-}"
ENDPOINT_OVERRIDE="${PISHCORD_RELAY_ENDPOINT:-}"
API_URL_OVERRIDE="${PISHCORD_RELAY_API_URL:-}"
PROXY_URL_OVERRIDE="${PISHCORD_RELAY_PROXY_URL:-}"
BINARY="${PISHCORD_RELAY_BINARY:-/usr/local/bin/pishcord-relayd}"

passed=0
failed=0
skipped=0
warned=0

section() { printf '\n%s\n' "$*"; }
pass() {
	passed=$((passed + 1))
	printf '  PASS  %s\n' "$*"
}
fail() {
	failed=$((failed + 1))
	printf '  FAIL  %s\n' "$*"
}
skip() {
	skipped=$((skipped + 1))
	printf '  SKIP  %s\n' "$*"
}
warn() {
	warned=$((warned + 1))
	printf '  WARN  %s\n' "$*"
}
note() { printf '        %s\n' "$*"; }

cfg() { sed -n "s/^$1=//p" "${CONFIG}" 2>/dev/null | tail -1; }

[[ -r "${CONFIG}" ]] || {
	printf 'error: cannot read %s\n' "${CONFIG}" >&2
	exit 2
}

TURN_URLS_RAW="$(cfg TURN_URLS)"
[ -n "${TURN_URLS_RAW}" ] || {
	printf 'error: TURN_URLS is not set in %s\n' "${CONFIG}" >&2
	exit 2
}
IFS=',' read -r -a TURN_URLS <<<"${TURN_URLS_RAW}"
IDENTITY="$(cfg TURN_IDENTITY)"
IDENTITY="${IDENTITY:-Pishcord}"
TTL_RAW="$(cfg CREDENTIAL_TTL)"

PROXY_URL="${PROXY_URL_OVERRIDE:-$(cfg HTTPS_PROXY_URL)}"
API_URL="${API_URL_OVERRIDE:-$(cfg NETWORK_CONFIG_URL)}"
ALLOWED_FILE="$(cfg ALLOWED_DOMAINS_FILE)"
ALLOWED_FILE="${ALLOWED_FILE:-/etc/pishcord-relay/allowed-domains.txt}"
POLICY_FILE="$(cfg DESTINATION_POLICY_FILE)"
POLICY_FILE="${POLICY_FILE:-/etc/pishcord-relay/destination-policy.conf}"
ALLOW_FILE="$(cfg SQUID_ALLOW_FILE)"
ALLOW_FILE="${ALLOW_FILE:-/etc/pishcord-relay/squid-allow.conf}"

# split_url URL -> sets URL_HOST URL_PORT
split_url() {
	local u="$1"
	local rest="${u#*://}"
	rest="${rest%%/*}"
	if [[ "${rest}" == *:* && "${rest##*:}" =~ ^[0-9]+$ ]]; then
		URL_HOST="${rest%:*}"
		URL_PORT="${rest##*:}"
	else
		URL_HOST="${rest}"
		URL_PORT=""
	fi
}

split_url "${PROXY_URL}"
PROXY_HOST="${URL_HOST}"
PROXY_PORT="${URL_PORT:-443}"
split_url "${API_URL}"
API_PORT="${URL_PORT:-8443}"
# NETWORK_CONFIG_PORT is authoritative. HTTPS_LISTEN and the public URL must
# name the same port; a disagreement is a configuration error, not something to
# guess around at verification time.
CONFIGURED_API_PORT="$(cfg NETWORK_CONFIG_PORT)"
API_LISTEN="$(cfg HTTPS_LISTEN)"
if [[ -n "${CONFIGURED_API_PORT}" ]]; then
	if [[ ! "${CONFIGURED_API_PORT}" =~ ^[0-9]+$ ]] ||
		((10#${CONFIGURED_API_PORT} < 1 || 10#${CONFIGURED_API_PORT} > 65535)); then
		printf 'error: NETWORK_CONFIG_PORT=%s is not a valid TCP port\n' "${CONFIGURED_API_PORT}" >&2
		exit 2
	fi
	if [[ -n "${URL_PORT}" && "${URL_PORT}" != "${CONFIGURED_API_PORT}" ]]; then
		printf 'error: NETWORK_CONFIG_URL uses port %s but NETWORK_CONFIG_PORT is %s\n' \
			"${URL_PORT}" "${CONFIGURED_API_PORT}" >&2
		exit 2
	fi
	API_PORT="${CONFIGURED_API_PORT}"
fi
if [[ -n "${API_LISTEN}" ]]; then
	API_LISTEN_PORT="${API_LISTEN##*:}"
	if [[ "${API_LISTEN_PORT}" != "${API_PORT}" ]]; then
		printf 'error: HTTPS_LISTEN (%s) does not use NETWORK_CONFIG_PORT (%s)\n' \
			"${API_LISTEN}" "${API_PORT}" >&2
		exit 2
	fi
fi

UDP_URL=""
TLS_URL=""
for u in "${TURN_URLS[@]}"; do
	case "${u}" in
	turn:*) [[ -z "${UDP_URL}" ]] && UDP_URL="${u}" ;;
	turns:*) [[ -z "${TLS_URL}" ]] && TLS_URL="${u}" ;;
	esac
done
[[ -n "${UDP_URL}" ]] || {
	printf 'error: no turn: (UDP) URL configured\n' >&2
	exit 2
}

turn_host_port() { # <url> -> TURN_HOST TURN_PORT
	local u="$1"
	u="${u#turns:}"
	u="${u#turn:}"
	u="${u#//}"
	u="${u%%\?*}"
	TURN_HOST="${u%:*}"
	TURN_PORT="${u##*:}"
	[[ "${TURN_PORT}" =~ ^[0-9]+$ ]] || TURN_PORT=""
}

turn_host_port "${UDP_URL}"
SERVER_HOST="${TURN_HOST:-${PROXY_HOST}}"
UDP_PORT="${TURN_PORT:-3478}"
TLS_PORT="5349"
if [[ -n "${TLS_URL}" ]]; then
	turn_host_port "${TLS_URL}"
	TLS_PORT="${TURN_PORT:-5349}"
fi

[[ -n "${SERVER_HOST}" ]] || {
	printf 'error: cannot determine the server host from the configuration\n' >&2
	exit 2
}

SERVER_IP="$(python3 - "${SERVER_HOST}" <<'PY' 2>/dev/null
import socket, sys
try:
    print(socket.getaddrinfo(sys.argv[1], None, socket.AF_INET, socket.SOCK_STREAM)[0][4][0])
except Exception:
    pass
PY
)"
SERVER_IP="${SERVER_IP:-${SERVER_HOST}}"

# CREDENTIAL_TTL is either a number of seconds or a Go duration such as 24h.
ttl_seconds() {
	local v="$1"
	case "${v}" in
	*[!0-9]*)
		python3 - "${v}" <<'PY' 2>/dev/null || echo 86400
import re, sys
s = sys.argv[1]
m = re.fullmatch(r'(\d+(?:\.\d+)?)(ns|us|ms|s|m|h)', s)
if not m:
    sys.exit(1)
print(int(float(m.group(1)) * {'ns': 1e-9, 'us': 1e-6, 'ms': 1e-3, 's': 1, 'm': 60, 'h': 3600}[m.group(2)]))
PY
		;;
	*) echo "${v}" ;;
	esac
}
TTL="$(ttl_seconds "${TTL_RAW:-24h}")"

UCLIENT="$(command -v turnutils_uclient || true)"
if [[ -z "${UCLIENT}" ]]; then
	for candidate in /usr/local/bin/turnutils_uclient /usr/bin/turnutils_uclient; do
		[[ -x "${candidate}" ]] && UCLIENT="${candidate}" && break
	done
fi
[[ -n "${UCLIENT}" ]] && UTILS_DIR="$(dirname "${UCLIENT}")"
PEER_BIN=""
[[ -n "${UTILS_DIR:-}" && -x "${UTILS_DIR}/turnutils_peer" ]] && PEER_BIN="${UTILS_DIR}/turnutils_peer"

printf 'Pishcord Relay verification\n'
printf '  proxy      %s\n' "${PROXY_URL}"
printf '  api        %s (configured port %s)\n' "${API_URL}" "${API_PORT}"
printf '  turn url   %s\n' "${UDP_URL}"
printf '  tls url    %s\n' "${TLS_URL:-<not configured>}"
printf '  identity   %s\n' "${IDENTITY}"

# --- services ---------------------------------------------------------------
section "Services"
if [[ "${SKIP_UNITS}" == "1" ]]; then
	skip "systemd checks disabled (PISHCORD_RELAY_SKIP_UNITS=1)"
else
	for unit in "${SQUID_UNIT}" "${COTURN_UNIT}" "${API_UNIT}"; do
		if systemctl is-active --quiet "${unit}"; then
			pass "${unit} is active"
		else
			fail "${unit} is not active"
		fi
	done
fi

# --- listeners --------------------------------------------------------------
section "Listeners"
if [[ "${SKIP_UNITS}" == "1" ]]; then
	skip "listener checks disabled"
else
	if ss -Hltn "sport = :${PROXY_PORT}" 2>/dev/null | grep -q .; then
		pass "TCP ${PROXY_PORT} is listening (HTTPS CONNECT proxy)"
	else
		fail "TCP ${PROXY_PORT} is not listening"
	fi
	if ss -Hltn "sport = :${API_PORT}" 2>/dev/null | grep -q .; then
		pass "TCP ${API_PORT} is listening (network configuration endpoint, configured port)"
	else
		fail "TCP ${API_PORT} is not listening (the configured Network Configuration API port)"
		# Tell a port conflict apart from an API that never bound its port.
		if command -v python3 >/dev/null 2>&1 && python3 - "${API_PORT}" <<'PY' >/dev/null 2>&1
try:
    import socket, sys
    s = socket.socket()
    try:
        s.bind(("0.0.0.0", int(sys.argv[1])))
    finally:
        s.close()
except OSError:
    sys.exit(1)
PY
		then
			note "the port is free: the service did not start on it (check ${API_UNIT})"
		else
			note "the port is in use by another process: port conflict"
		fi
	fi
	if ss -Hlun "sport = :${UDP_PORT}" 2>/dev/null | grep -q .; then
		pass "UDP ${UDP_PORT} is listening (TURN)"
	else
		fail "UDP ${UDP_PORT} is not listening"
	fi
	if ss -Hltn "sport = :${TLS_PORT}" 2>/dev/null | grep -q .; then
		pass "TCP ${TLS_PORT} is listening (TURN over TLS)"
	else
		fail "TCP ${TLS_PORT} is not listening"
	fi
fi

min_port="$(sed -n 's/^min-port=//p' "${TURN_CONF}" 2>/dev/null | tail -1)"
max_port="$(sed -n 's/^max-port=//p' "${TURN_CONF}" 2>/dev/null | tail -1)"
if [[ "${min_port}" == "49152" && "${max_port}" == "65535" ]]; then
	pass "relay allocation range is 49152-65535/udp"
elif [[ -n "${min_port}" && -n "${max_port}" ]]; then
	note "relay allocation range is ${min_port}-${max_port}/udp"
	pass "relay allocation range configured"
else
	fail "relay allocation range not found in ${TURN_CONF}"
fi

# --- API firewall -----------------------------------------------------------
section "Network configuration API firewall"
if [[ "${SKIP_UNITS}" == "1" ]]; then
	skip "firewall checks disabled"
elif command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
	if ufw status | grep -qE "^${API_PORT}/tcp[[:space:]]+ALLOW"; then
		pass "ufw allows the configured API port ${API_PORT}/tcp"
	else
		fail "ufw does not allow the configured API port ${API_PORT}/tcp"
	fi
	if [[ "${API_PORT}" != "8443" ]] &&
		ufw status | grep -qE '^8443/tcp[[:space:]]+ALLOW.*pishcord-relay network config'; then
		warn "an obsolete ufw rule still opens 8443/tcp for Pishcord-relay"
	else
		pass "no obsolete Pishcord-relay API rule for 8443/tcp is open"
	fi
elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
	if firewall-cmd --query-port="${API_PORT}/tcp" >/dev/null 2>&1; then
		pass "firewalld allows the configured API port ${API_PORT}/tcp"
	else
		fail "firewalld does not allow the configured API port ${API_PORT}/tcp"
	fi
else
	skip "no active ufw/firewalld; check the provider firewall for TCP ${API_PORT}"
fi

# --- TURN limits and peer filtering -----------------------------------------
section "TURN limits and peer filtering"
read_conf() { sed -n "s/^$1=//p" "${TURN_CONF}" 2>/dev/null | tail -1; }
user_quota="$(read_conf user-quota)"
total_quota="$(read_conf total-quota)"
max_bps="$(read_conf max-bps)"
bps_capacity="$(read_conf bps-capacity)"

if [[ -n "${user_quota}" && "${user_quota}" -gt 0 ]] && [[ -n "${total_quota}" && "${total_quota}" -gt 0 ]]; then
	pass "allocation quotas set (user-quota=${user_quota}, total-quota=${total_quota})"
else
	fail "allocation quotas missing (user-quota=${user_quota:-unset}, total-quota=${total_quota:-unset})"
fi
if [[ -n "${max_bps}" && -n "${bps_capacity}" ]] && [[ "${max_bps}" -gt 0 ]] && [[ "${bps_capacity}" -gt 0 ]]; then
	if [[ $((bps_capacity / max_bps)) -ge 2 ]]; then
		pass "bandwidth limits set (max-bps=${max_bps}, bps-capacity=${bps_capacity}, ~$((bps_capacity / max_bps)) concurrent sessions)"
	else
		fail "bps-capacity (${bps_capacity}) is below two max-bps reservations (${max_bps}); coturn will reject allocations with error 486. Set bps-capacity=0 for no ceiling, or raise it above total-quota x max-bps."
	fi
elif [[ "${bps_capacity}" == "0" ]]; then
	if [[ -z "${max_bps}" ]]; then
		fail "bps-capacity=0 (no ceiling) but max-bps is missing; coturn has no bandwidth backstop"
	else
		pass "no relay capacity reservation (bps-capacity=0); per-client-IP TURN limits are enforced by the shaper and max-bps=${max_bps} is the per-session backstop"
	fi
else
	note "max-bps/bps-capacity are unlimited; quotas alone bound usage"
fi

private_ranges=(
	"denied-peer-ip=10.0.0.0-10.255.255.255"
	"denied-peer-ip=172.16.0.0-172.31.255.255"
	"denied-peer-ip=192.168.0.0-192.168.255.255"
	"denied-peer-ip=169.254.0.0-169.254.255.255"
	"denied-peer-ip=127.0.0.0-127.255.255.255"
)
missing_ranges=0
for entry in "${private_ranges[@]}"; do
	grep -qxF "${entry}" "${TURN_CONF}" 2>/dev/null || missing_ranges=$((missing_ranges + 1))
done
if [[ ${missing_ranges} -eq 0 ]] && grep -qxF 'no-multicast-peers' "${TURN_CONF}"; then
	pass "private, loopback, link-local and multicast peer ranges are denied"
else
	fail "peer destination filtering is incomplete in ${TURN_CONF}"
fi
if grep -qxF 'no-tcp-relay' "${TURN_CONF}"; then
	pass "peers are reached over UDP only (no-tcp-relay)"
else
	note "no-tcp-relay is not set: clients may request TCP relays to peers"
fi

# --- Squid configuration ----------------------------------------------------
section "HTTPS CONNECT proxy configuration"
if [[ -r "${SQUID_CONF}" ]]; then
	if grep -qE "^https_port[[:space:]]+${PROXY_PORT}[[:space:]]" "${SQUID_CONF}"; then
		pass "https_port ${PROXY_PORT} is a TLS-enabled forward proxy listener"
	else
		fail "${SQUID_CONF} has no https_port ${PROXY_PORT} listener"
	fi
	# Match a directive, not the word inside a comment: the shipped configuration
	# mentions "no ssl_bump" in its header.
	if grep -qE '^[[:space:]]*ssl_bump([[:space:]]|$)' "${SQUID_CONF}"; then
		fail "ssl_bump is configured; this relay must never intercept TLS"
	else
		pass "no ssl_bump: the Discord TLS session stays end-to-end"
	fi
	if grep -qxF 'http_access deny !pishcord_connect' "${SQUID_CONF}" && grep -qxF 'http_access deny all' "${SQUID_CONF}"; then
		pass "CONNECT is the only method and the default action is deny"
	else
		fail "CONNECT-only deny rules are missing from ${SQUID_CONF}"
	fi
	if grep -q 'pishcord_blocked_dst' "${SQUID_CONF}" && grep -qE '10\.0\.0\.0/8' "${SQUID_CONF}"; then
		pass "resolved destination addresses are checked against private/special ranges"
	else
		fail "private destination address filtering is missing from ${SQUID_CONF}"
	fi
	if grep -qE '^client_ip_max_connections [0-9]+' "${SQUID_CONF}"; then
		pass "per-client connection limit set ($(sed -n 's/^client_ip_max_connections //p' "${SQUID_CONF}"))"
	else
		fail "client_ip_max_connections is not set in ${SQUID_CONF}"
	fi
	if grep -qxF "include ${ALLOW_FILE}" "${SQUID_CONF}"; then
		pass "the generated destination policy include is wired in"
	else
		fail "${SQUID_CONF} does not include ${ALLOW_FILE}"
	fi
	if [[ -x "${BINARY}" ]]; then
		if "${BINARY}" -config "${CONFIG}" -policy-check >/dev/null 2>&1; then
			pass "allowed-domains.txt and destination-policy.conf validate and agree"
		else
			fail "the destination policy files do not validate: ${BINARY} -config ${CONFIG} -policy-check"
		fi
	else
		skip "policy validation skipped: ${BINARY} not found"
	fi
	if [[ -r "${ALLOW_FILE}" ]]; then
		# The generated ACLs must cover exactly the configured policy.
		if python3 - "${ALLOWED_FILE}" "${POLICY_FILE}" "${ALLOW_FILE}" <<'PY'
import re, sys
domains_file, policy_file, allow_file = sys.argv[1:4]
def entries(path):
    out = []
    for raw in open(path):
        line = raw.split("#", 1)[0].strip()
        if line:
            out.append(line)
    return out
def portspec(spec):
    parts = []
    for p in spec.split(","):
        p = p.strip()
        if "-" in p:
            a, b = p.split("-", 1)
            parts.append(f"{int(a)}-{int(b)}")
        else:
            parts.append(str(int(p)))
    return " ".join(parts)
def name(entry):
    return entry.lower().rstrip(".").lstrip("=")

policy = {}
exact = set()
for line in entries(policy_file):
    f = line.split()
    policy[name(f[0])] = portspec(f[1])
    if f[0].startswith("="):
        exact.add(name(f[0]))
allow = open(allow_file).read()
if {name(e) for e in entries(domains_file)} != set(policy):
    print("allowlist and port policy disagree")
    sys.exit(1)
for domain, ports in policy.items():
    scope = domain if domain in exact else f".{domain}"
    if f"dstdomain {scope}" not in allow:
        print(f"missing dstdomain for {domain} (expected scope {scope})")
        sys.exit(1)
    if domain not in exact and f"dstdomain .{domain}" in allow and f"dstdomain {domain}" in allow:
        print(f"{domain} is listed with and without subdomain scope")
        sys.exit(1)
    if f"port {ports}" not in allow:
        print(f"missing port rule {ports} for {domain}")
        sys.exit(1)
for line in allow.splitlines():
    if line.startswith("http_access"):
        if "pishcord_domain_" not in line or "pishcord_ports_" not in line:
            print(f"access rule does not constrain domain and port: {line}")
            sys.exit(1)
sys.exit(0)
PY
		then
			pass "generated Squid ACLs match the policy files exactly"
		else
			fail "generated Squid ACLs do not match ${ALLOWED_FILE} / ${POLICY_FILE}; run the policy command"
		fi
	else
		fail "cannot read ${ALLOW_FILE}"
	fi
else
	fail "cannot read ${SQUID_CONF}"
fi

# --- proxy behaviour --------------------------------------------------------
section "HTTPS CONNECT proxy policy enforcement"

# proxy_probe URL prints one of: denied, tls, ok, other
#
# Probes always verify the proxy's TLS certificate: with the system trust store,
# or with PISHCORD_RELAY_PROXY_CA when the relay uses a staging certificate.
proxy_ca_args=()
[[ -n "${PROXY_CA}" ]] && proxy_ca_args+=(--proxy-cacert "${PROXY_CA}")
proxy_probe() {
	local url="$1" out rc
	out="$(curl -sS -o /dev/null --max-time 25 "${proxy_ca_args[@]}" --proxy "${PROXY_URL}" "$url" 2>&1)"
	rc=$?
	if grep -q 'CONNECT tunnel failed, response 403' <<<"${out}"; then
		echo denied
	elif grep -qiE 'SSL certificate problem|certificate verify' <<<"${out}"; then
		echo tls
	elif [[ ${rc} -eq 0 ]]; then
		echo ok
	else
		echo other
	fi
}

curl_features="$(curl --version 2>/dev/null)"
if ! grep -q 'HTTPS-proxy' <<<"${curl_features}"; then
	skip "this curl has no HTTPS-proxy support; proxy checks skipped"
else
	# The proxy's own certificate must be publicly trusted and valid for the
	# configured host: curl verifies it with the system trust store.
	probe_out="$(proxy_probe "https://discord.com/")"
	proxy_tls_ok=0
	case "${probe_out}" in
	tls)
		fail "the TLS certificate presented by the proxy did not verify for ${PROXY_HOST}"
		;;
	denied)
		fail "CONNECT discord.com:443 was denied"
		;;
	ok)
		proxy_tls_ok=1
		pass "proxy TLS verified, CONNECT discord.com:443 succeeded end to end"
		;;
	*)
		# The tunnel opened, so the certificate was accepted; the origin simply
		# did not answer. Policy probes are still meaningful.
		proxy_tls_ok=1
		warn "CONNECT discord.com:443 was permitted but the origin request did not complete (${probe_out}); check outbound HTTPS from this VPS"
		;;
	esac

	if ((!proxy_tls_ok)); then
		skip "policy probes skipped: fix the proxy certificate first, otherwise a denial cannot be told apart from a TLS failure"
	else
		if [[ "$(proxy_probe "https://gateway.discord.gg/?v=10&encoding=json")" == "denied" ]]; then
			fail "CONNECT gateway.discord.gg:443 (WebSocket gateway) was denied"
		else
			pass "CONNECT gateway.discord.gg:443 is permitted (the WSS transport path)"
		fi

		denied_cases=(
			"https://example.com/|unlisted domain"
			"https://discord.com.evil.example/|allowlist suffix trick"
			"https://evil-discord.com/|similar-looking domain"
			"https://1.1.1.1/|IP-literal destination"
			"https://discord.com:2053/|port outside discord.com's policy"
			"https://storage.googleapis.com/|shared Google infrastructure"
			"https://other-bucket.storage.googleapis.com/|an unrelated Cloud Storage bucket"
			"https://evil.discord-attachments-uploads-prd.storage.googleapis.com/|a subdomain of the exact upload host"
			"https://discord-attachments-uploads-prd.storage.googleapis.com:2053/|a port outside the upload host's policy"
		)
		for c in "${denied_cases[@]}"; do
			url="${c%%|*}"
			label="${c##*|}"
			case "$(proxy_probe "${url}")" in
			denied) pass "rejected: ${label} (${url})" ;;
			tls) fail "TLS verification failed while testing ${label}" ;;
			*) fail "${label} was not rejected with a policy denial (${url})" ;;
			esac
		done

		# Dynamic voice-signalling ports are allowed for discord.media only. The
		# exact port is supplied by Discord at call time; any permitted port must
		# pass the ACL (the origin may still refuse the connection).
		media_case="$(proxy_probe "https://sweetwater-12345.discord.media:2048/")"
		if [[ "${media_case}" == "denied" ]]; then
			fail "CONNECT to a dynamic discord.media port was denied"
		else
			pass "CONNECT to a dynamic discord.media port is permitted (${media_case})"
		fi
		case "$(proxy_probe "https://gateway.discord.com:2048/")" in
		denied) pass "the dynamic port range is not available to other Discord domains" ;;
		tls) skip "dynamic-port isolation not tested: the proxy certificate did not verify" ;;
		*) fail "a non-media Discord domain was allowed on a dynamic port" ;;
		esac

		# Discord uploads attachments (images, files) to this exact Cloud Storage
		# host on 443. The tunnel must open; Cloud Storage may still answer the
		# request with 403 of its own, which is not a proxy denial.
		upload_case="$(proxy_probe "https://discord-attachments-uploads-prd.storage.googleapis.com/")"
		if [[ "${upload_case}" == "denied" ]]; then
			fail "CONNECT to the attachment upload host was denied"
		else
			pass "CONNECT to the attachment upload host is permitted (${upload_case})"
		fi
	fi
fi

# --- HTTPS API --------------------------------------------------------------
section "Network configuration endpoint"
ENDPOINT="${ENDPOINT_OVERRIDE:-${API_URL}}"
BODY_FILE="$(mktemp)"
HEADER_FILE="$(mktemp)"
trap 'rm -f "${BODY_FILE}" "${HEADER_FILE}"' EXIT

curl_tls_args=()
[[ -n "${CA_FILE}" ]] && curl_tls_args+=(--cacert "${CA_FILE}")
http_status="$(curl -sS --max-time 15 "${curl_tls_args[@]}" -D "${HEADER_FILE}" -o "${BODY_FILE}" \
	-w '%{http_code}' "${ENDPOINT}" 2>/dev/null || echo 000)"

if [[ "${http_status}" == "200" ]]; then
	pass "GET ${ENDPOINT} returned 200 with a verified certificate"
else
	fail "GET ${ENDPOINT} returned ${http_status} (expected 200)"
	head -5 "${BODY_FILE}" 2>/dev/null | sed 's/^/        /'
fi

if grep -qi '^cache-control:.*no-store' "${HEADER_FILE}" 2>/dev/null; then
	pass "Cache-Control: no-store is set"
else
	fail "Cache-Control: no-store is missing"
fi
if grep -qi '^content-type: application/json' "${HEADER_FILE}" 2>/dev/null; then
	pass "response is JSON"
else
	fail "response content type is not JSON"
fi

USERNAME=""
CREDENTIAL=""
EXPIRES_AT=""
DOC_PROXY=""
if [[ "${http_status}" == "200" ]]; then
	eval "$(python3 - "${BODY_FILE}" "${POLICY_FILE}" "${ALLOWED_FILE}" "${ALLOW_FILE}" "${API_PORT}" <<'PY'
import json, re, shlex, sys, urllib.parse
body, policy_file, domains_file, allow_file, api_port = sys.argv[1:6]
try:
    d = json.load(open(body))
except Exception:
    print("SCHEMA=0")
    sys.exit(0)

def entries(path):
    out = []
    for raw in open(path):
        line = raw.split("#", 1)[0].strip()
        if line:
            out.append(line)
    return out

def portspec(spec):
    parts = []
    for p in spec.split(","):
        p = p.strip()
        if "-" in p:
            a, b = p.split("-", 1)
            parts.append(f"{int(a)}-{int(b)}")
        else:
            parts.append(str(int(p)))
    return " ".join(parts)

def name(entry):
    # A leading '=' marks an exact host; the published document carries the
    # plain name, so compare without the marker.
    return entry.lower().rstrip(".").lstrip("=")

want = {}
ranges = {}
for line in entries(policy_file):
    fields = line.split()
    want[name(fields[0])] = portspec(fields[1])
    pairs = []
    for p in fields[1].split(","):
        p = p.strip()
        if "-" in p:
            a, b = p.split("-", 1)
            pairs.append((int(a), int(b)))
        else:
            pairs.append((int(p), int(p)))
    ranges[name(fields[0])] = sorted(pairs)

got = {}
for dest in d.get("httpsProxy", {}).get("allowedDestinations", []):
    parts = [str(int(p)) for p in dest.get("ports", [])]
    parts += [f'{int(r["from"])}-{int(r["to"])}' for r in dest.get("portRanges", [])]
    got[name(dest["domain"])] = " ".join(parts)

# Routing rules must describe the same policy: exact/suffix from the '=' marker in
# the allowlist, ports from the policy file.
want_routing = {}
for line in entries(domains_file):
    want_routing[name(line)] = ("exact" if line.startswith("=") else "suffix",
                                ranges.get(name(line), []))

got_routing = {}
for rule in d.get("routing", {}).get("domains", []):
    host = name(str(rule.get("host", "")))
    ports = sorted((int(p["from"]), int(p["to"])) for p in rule.get("ports", []))
    got_routing[host] = (rule.get("match"), ports)

raw_routing = d.get("routing", {}).get("domains", [])
for rule in raw_routing:
    host = str(rule.get("host", ""))
    if host != host.lower().rstrip("."):
        got_routing["__unnormalized__"] = (host, [])

proxy = d.get("proxy", {})
try:
    url_port = urllib.parse.urlsplit(d.get("httpsProxy", {}).get("url", "")).port or 443
except ValueError:
    url_port = None
proxy_ok = (1 if proxy.get("scheme") == "https"
            and proxy.get("host")
            and proxy.get("port") == url_port
            and str(proxy.get("port")) != str(api_port)
            else 0)

# The published rules must match the Squid include that is installed.
acl_ok = 0
try:
    acl = open(allow_file).read()
    scopes = []
    for host, (match, _) in got_routing.items():
        if host == "__unnormalized__":
            continue
        scopes.append(("exact", host) if match == "exact" else ("suffix", "." + host))
    allows = len(re.findall(r"^http_access allow CONNECT", acl, re.M))
    acl_ok = (1 if allows == len(scopes) and all(
        re.search(r"^acl pishcord_domain_\d+ dstdomain " + re.escape(scope) + r"$", acl, re.M)
        for _, scope in scopes) else 0)
except OSError:
    acl_ok = 0

ice = d.get("rtcRelay", {}).get("iceServers", [{}])[0]
print("SCHEMA=" + shlex.quote(str(d.get("version"))))
print("SCHEMA_VERSION=" + shlex.quote(str(d.get("schemaVersion"))))
print("SCHEMA_VERSION_1=" + ("1" if d.get("schemaVersion") == 1 else "0"))
print("ROUTING_MATCH=" + ("1" if want_routing == got_routing else "0"))
print("PROXY_OK=" + str(proxy_ok))
print("ACL_MATCH=" + str(acl_ok))
print("DOC_PROXY=" + shlex.quote(d.get("httpsProxy", {}).get("url", "")))
print("USERNAME=" + shlex.quote(ice.get("username", "")))
print("CREDENTIAL=" + shlex.quote(ice.get("credential", "")))
print("EXPIRES_AT=" + shlex.quote(str(d.get("rtcRelay", {}).get("expiresAt", ""))))
print("POLICY_MATCH=" + ("1" if want == got else "0"))
PY
)"

	if [[ "${SCHEMA:-0}" == "1" ]]; then
		pass "response uses schema version 1"
	else
		fail "response schema version is '${SCHEMA:-missing}', expected 1"
	fi
	if [[ "${POLICY_MATCH:-0}" == "1" ]]; then
		pass "advertised domain-and-port policy matches the policy files exactly"
	else
		fail "advertised policy does not match ${POLICY_FILE}"
	fi
	if [[ "${SCHEMA_VERSION_1:-0}" == "1" ]]; then
		pass "response declares schemaVersion 1"
	else
		fail "schemaVersion is '${SCHEMA_VERSION:-missing}', expected 1"
	fi
	if [[ "${PROXY_OK:-0}" == "1" ]]; then
		pass "proxy object names the https proxy endpoint, distinct from the ${API_PORT} configuration endpoint"
	else
		fail "proxy object is missing, not https, or on the configuration port"
	fi
	if [[ "${ROUTING_MATCH:-0}" == "1" ]]; then
		pass "routing.domains matches the policy files (hosts, exact/suffix, ports)"
	else
		fail "routing.domains does not match ${POLICY_FILE}"
	fi
	if [[ "${ACL_MATCH:-0}" == "1" ]]; then
		pass "routing.domains agrees with the installed Squid authorization"
	else
		fail "routing.domains and ${ALLOW_FILE} disagree"
	fi

	if [[ -n "${DOC_PROXY}" ]]; then
		pass "document quotes an HTTPS proxy URL (${DOC_PROXY})"
		if [[ "${DOC_PROXY}" == "${PROXY_URL}" ]]; then
			pass "advertised proxy URL matches the configured proxy"
		else
			fail "advertised proxy URL ${DOC_PROXY} differs from ${PROXY_URL}"
		fi
	else
		fail "the response has no httpsProxy.url (or an unexpected schema version)"
	fi

	[[ -n "${USERNAME}" && -n "${CREDENTIAL}" ]] && pass "TURN credentials are present in the response" ||
		fail "response does not contain TURN username/credential"

	now="$(date +%s)"
	if [[ "${EXPIRES_AT}" =~ ^[0-9]+$ ]] && [[ $((EXPIRES_AT - now)) -ge $((TTL - 300)) ]] &&
		[[ $((EXPIRES_AT - now)) -le $((TTL + 300)) ]]; then
		pass "expiresAt is ${TTL}s ahead (credential lifetime)"
	else
		fail "expiresAt=${EXPIRES_AT} is not consistent with a ${TTL}s lifetime (now=${now})"
	fi

	uname_ts="${USERNAME%%:*}"
	uname_id="${USERNAME#*:}"
	if [[ "${uname_id}" == "${IDENTITY}" ]]; then
		pass "username identity is ${IDENTITY} (${USERNAME})"
	else
		fail "username identity is '${uname_id}', expected '${IDENTITY}'"
	fi
	if [[ "${uname_ts}" =~ ^[0-9]+$ ]] && [[ "${uname_ts}" == "${EXPIRES_AT}" ]]; then
		pass "username timestamp matches expiresAt"
	else
		fail "username timestamp '${uname_ts}' does not match expiresAt '${EXPIRES_AT}'"
	fi

	if [[ -r "${SECRET_FILE}" ]]; then
		if python3 - "${USERNAME}" "${CREDENTIAL}" "${SECRET_FILE}" <<'PY'
import base64, hashlib, hmac, sys
username, credential, secret_file = sys.argv[1], sys.argv[2], sys.argv[3]
secret = open(secret_file, "rb").read().strip()
expected = base64.b64encode(hmac.new(secret, username.encode(), hashlib.sha1).digest()).decode()
sys.exit(0 if hmac.compare_digest(expected, credential) else 1)
PY
		then
			pass "credential is base64(HMAC-SHA1(secret, username)) for the local shared secret"
		else
			fail "credential does not match the coturn shared secret"
		fi
		if grep -qF "$(cat "${SECRET_FILE}")" "${BODY_FILE}" 2>/dev/null; then
			fail "the response leaked the permanent TURN secret"
		else
			pass "the permanent TURN secret is not in the response"
		fi
	else
		skip "cannot read ${SECRET_FILE} to re-compute the credential"
	fi

	if [[ "${http_status}" == "200" ]]; then
		other="$(curl -sS --max-time 10 "${curl_tls_args[@]}" -o /dev/null -w '%{http_code}' \
			"${ENDPOINT%/network-config}/does-not-exist" 2>/dev/null || echo 000)"
		if [[ "${other}" == "404" ]]; then
			pass "unknown paths return 404"
		else
			fail "GET a non-API path returned ${other}, expected 404"
		fi
	fi
fi

# --- ACME HTTP-01 -----------------------------------------------------------
section "API request limits and response time"
# The defaults must let several profiles load at once; these checks prove the
# configured limits and the latency a profile load actually sees.
PER_IP_RATE_V="$(cfg PER_IP_RATE_PER_MINUTE)"
PER_IP_BURST_V="$(cfg PER_IP_BURST)"
GLOBAL_RATE_V="$(cfg GLOBAL_RATE_PER_MINUTE)"
GLOBAL_BURST_V="$(cfg GLOBAL_BURST)"
PER_IP_RATE_V="${PER_IP_RATE_V:-60}"
PER_IP_BURST_V="${PER_IP_BURST_V:-30}"
GLOBAL_RATE_V="${GLOBAL_RATE_V:-1200}"
GLOBAL_BURST_V="${GLOBAL_BURST_V:-300}"

if [[ "${PER_IP_RATE_V}" =~ ^[0-9]+$ && "${PER_IP_BURST_V}" =~ ^[0-9]+$ &&
	"${GLOBAL_RATE_V}" =~ ^[0-9]+$ && "${GLOBAL_BURST_V}" =~ ^[0-9]+$ ]] &&
	((PER_IP_RATE_V >= 1 && PER_IP_BURST_V >= 1 && GLOBAL_RATE_V >= 1 && GLOBAL_BURST_V >= 1)); then
	pass "request limits are valid (${PER_IP_RATE_V}/min per IP, burst ${PER_IP_BURST_V}; global ${GLOBAL_RATE_V}/min, burst ${GLOBAL_BURST_V})"
else
	fail "request limits in ${CONFIG} are missing or invalid"
	note "expected whole numbers of at least 1 for PER_IP_RATE_PER_MINUTE, PER_IP_BURST, GLOBAL_RATE_PER_MINUTE and GLOBAL_BURST"
fi
if ((PER_IP_BURST_V < 10)); then
	warn "per-IP burst ${PER_IP_BURST_V} is small: several profiles loading at once may receive 429"
fi

if [[ "${ENDPOINT}" == https://* ]] && command -v curl >/dev/null 2>&1; then
	# Ten sequential profile loads: the average is the per-profile latency.
	latency_total="0"
	latency_ok=1
	for _ in 1 2 3 4 5 6 7 8 9 10; do
		one="$(curl -sS -o /dev/null "${curl_tls_args[@]}" --max-time 10 -w '%{time_total}' "${ENDPOINT}" 2>/dev/null)" || latency_ok=0
		[[ "${one}" =~ ^[0-9.]+$ ]] || {
			latency_ok=0
			one=0
		}
		latency_total="$(awk -v a="${latency_total}" -v b="${one}" 'BEGIN { printf "%.3f", a + b }')"
	done
	if ((latency_ok)); then
		latency_avg="$(awk -v t="${latency_total}" 'BEGIN { printf "%.1f", t / 10 * 1000 }')"
		note "average /network-config response time: ${latency_avg} ms over 10 requests"
		if awk -v ms="${latency_avg}" 'BEGIN { exit !(ms < 1000) }'; then
			pass "profile loads complete in well under a second (${latency_avg} ms average)"
		else
			fail "average response time ${latency_avg} ms is too slow; a profile load should take far less than a second"
		fi
	else
		fail "could not measure the API response time"
	fi

	# Several profiles opening at the same moment must not be rate limited.
	burst_out="$(mktemp)"
	for _ in $(seq 1 15); do
		curl -sS -o /dev/null "${curl_tls_args[@]}" --max-time 10 -w '%{http_code}\n' "${ENDPOINT}" >>"${burst_out}" 2>/dev/null &
	done
	wait
	too_many="$(grep -c '^429$' "${burst_out}" 2>/dev/null || true)"
	errors="$(grep -vc '^200$' "${burst_out}" 2>/dev/null || true)"
	rm -f "${burst_out}"
	if [[ "${errors}" == "0" ]]; then
		pass "15 simultaneous profile loads all returned 200 (no 429)"
	elif [[ "${too_many}" != "0" ]]; then
		fail "${too_many} of 15 simultaneous profile loads were rate limited (429)"
		note "raise PER_IP_BURST (currently ${PER_IP_BURST_V}) so several profiles can load at once"
	else
		fail "some simultaneous profile loads did not return 200"
	fi
else
	skip "API response-time and burst checks (no HTTPS endpoint or curl available)"
fi

# Recent 429s are visible in the journal because the API logs each refusal.
if command -v journalctl >/dev/null 2>&1 && [[ "${SKIP_UNITS}" != "1" ]]; then
	limited_count="$(journalctl -u "${API_UNIT}" --since '-1 hour' --no-pager 2>/dev/null | grep -c 'rate limited' || true)"
	limited_count="${limited_count:-0}"
	if [[ "${limited_count}" == "0" ]]; then
		pass "the API answered no request with a rate limit in the last hour"
	else
		warn "${limited_count} request(s) were rate limited in the last hour"
	fi
fi

section "Per-client-IP bandwidth limits"
PROXY_UP_V="$(cfg PROXY_UPLOAD_LIMIT_MBIT)"
PROXY_DOWN_V="$(cfg PROXY_DOWNLOAD_LIMIT_MBIT)"
TURN_UP_V="$(cfg TURN_UPLOAD_LIMIT_MBIT)"
TURN_DOWN_V="$(cfg TURN_DOWNLOAD_LIMIT_MBIT)"
PROXY_UP_V="${PROXY_UP_V:-8}"
PROXY_DOWN_V="${PROXY_DOWN_V:-8}"
TURN_UP_V="${TURN_UP_V:-16}"
TURN_DOWN_V="${TURN_DOWN_V:-16}"
TC_IFACE_V="$(cfg TC_INTERFACE)"
TC_MAX_V="$(cfg TC_MAX_CLIENTS)"
TC_MAX_V="${TC_MAX_V:-512}"
TC_SCRIPT="${PISHCORD_RELAY_TC:-/usr/local/lib/pishcord-relay/pishcord-relay-tc}"

for v in "${PROXY_UP_V}" "${PROXY_DOWN_V}" "${TURN_UP_V}" "${TURN_DOWN_V}"; do
	if [[ ! "${v}" =~ ^[0-9]{1,6}$ ]]; then
		fail "a bandwidth limit in ${CONFIG} is not a whole number of Mbit/s (${v})"
	fi
done
note "configured per client IP: proxy ${PROXY_DOWN_V} Mbps down / ${PROXY_UP_V} Mbps up, TURN ${TURN_DOWN_V} Mbps down / ${TURN_UP_V} Mbps up (0 = unlimited)"
shaping_configured=0
((PROXY_UP_V + PROXY_DOWN_V + TURN_UP_V + TURN_DOWN_V > 0)) && shaping_configured=1

if ! command -v tc >/dev/null 2>&1; then
	if ((shaping_configured)); then
		fail "tc is not installed, so the configured bandwidth limits are NOT enforced"
		note "install iproute2 (apt-get install iproute2) and run: pishcord-relay diagnostics"
	else
		pass "no bandwidth limits configured and tc is not present"
	fi
else
	# The interface the relay actually uses decides where shaping must be.
	detected_iface="$(ip -o route get 1.1.1.1 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)"
	if [[ -z "${detected_iface}" ]]; then
		detected_iface="$(ip -o route show default 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)"
	fi
	shaped_iface="${TC_IFACE_V:-${detected_iface}}"
	if [[ -n "${shaped_iface}" ]]; then
		pass "network interface ${shaped_iface}$([[ -n "${TC_IFACE_V}" ]] && echo ' (pinned by TC_INTERFACE)' || echo ' (detected from the default route)')"
		if [[ -n "${TC_IFACE_V}" && -n "${detected_iface}" && "${TC_IFACE_V}" != "${detected_iface}" ]]; then
			warn "TC_INTERFACE is ${TC_IFACE_V} but the default route uses ${detected_iface}: client traffic may not be shaped"
		fi
	else
		fail "could not determine the network interface; bandwidth limits cannot be applied"
	fi

	if [[ -x "${TC_SCRIPT}" ]]; then
		tc_status="$("${TC_SCRIPT}" status 2>&1)"
		printf '%s\n' "${tc_status}" | sed -n 's/^/        /p'
		shaping_state="$(printf '%s\n' "${tc_status}" | sed -n 's/^shaping=//p' | tail -1)"
		shaped_count="$(printf '%s\n' "${tc_status}" | sed -n 's/^shaped_addresses=//p' | tail -1)"
		case "${shaping_state}" in
		active)
			pass "per-client-IP shaping is active on ${shaped_iface}${shaped_count:+ (${shaped_count} address classes)}"
			;;
		disabled)
			if ((shaping_configured)); then
				fail "bandwidth limits are configured but the shaper reports them disabled"
			else
				pass "bandwidth limits are disabled by configuration (all values 0)"
			fi
			;;
		partial)
			fail "upload limits are configured but the ingress shaper is not active: they are NOT enforced"
			;;
		*)
			if ((shaping_configured)); then
				fail "bandwidth limits are configured (proxy ${PROXY_DOWN_V}/${PROXY_UP_V} Mbps, TURN ${TURN_DOWN_V}/${TURN_UP_V} Mbps) but NOT enforced"
				if printf '%s\n' "${tc_status}" | grep -q '^missing_filter=\|^missing_fallback_filter='; then
					note "the classification filters are missing, so the classes shape nothing; the shaper's journal says why a rule was refused"
				fi
				note "run: sudo systemctl status pishcord-relay-tc.service; sudo journalctl -u pishcord-relay-tc -n 30"
				note "then: sudo ${TC_SCRIPT} apply"
			else
				pass "no bandwidth limits configured; shaping is inactive"
			fi
			;;
		esac
		if ((shaping_configured)) && [[ "${shaping_state}" == "active" ]]; then
			# The kernel's own class rate must equal the configured limit.
			if printf '%s\n' "${tc_status}" | grep -q '^rate_mismatch=\|^fallback_rate_mismatch='; then
				fail "the active shaper does not match the configured limits: $(printf '%s\n' "${tc_status}" | sed -n 's/^rate_mismatch=//p;s/^fallback_rate_mismatch=//p' | tr '\n' ' ')"
				note "re-apply with: sudo ${TC_SCRIPT} apply"
			elif printf '%s\n' "${tc_status}" | grep -q '^active_rate='; then
				pass "the active classes carry the configured rates ($(printf '%s\n' "${tc_status}" | sed -n 's/^active_rate=//p' | tr '\n' ' '))"
			else
				warn "no per-address class is active yet (no client connected since the shaper started)"
			fi
			if ((TC_MAX_V < 64)); then
				warn "TC_MAX_CLIENTS is ${TC_MAX_V}: only that many client addresses per service can be shaped at once"
			fi
		fi
	else
		if ((shaping_configured)); then
			fail "the traffic-shaping helper ${TC_SCRIPT} is missing, so bandwidth limits are NOT enforced"
			note "re-run the installer to restore it"
		else
			skip "traffic shaping is not installed (no bandwidth limits configured)"
		fi
	fi
fi

section "ACME HTTP-01 path"
ACME_WEBROOT="$(cfg ACME_WEBROOT)"
ACME_WEBROOT="${ACME_WEBROOT:-/var/www/pishcord-relay}"
ACME_DIR="${ACME_WEBROOT}/.well-known/acme-challenge"
ACME_URL="${PISHCORD_RELAY_ACME_URL:-http://${PROXY_HOST}/.well-known/acme-challenge}"
acme_token="pishcordverify${RANDOM}${RANDOM}"
if mkdir -p "${ACME_DIR}" 2>/dev/null && printf 'acme-ok\n' >"${ACME_DIR}/${acme_token}" 2>/dev/null; then
	acme_body="$(curl -sS --max-time 10 "${ACME_URL}/${acme_token}" 2>/dev/null || true)"
	rm -f "${ACME_DIR}/${acme_token}"
	if [[ "${acme_body}" == "acme-ok" ]]; then
		pass "port 80 serves certificate challenge files from ${ACME_WEBROOT}"
	else
		fail "port 80 did not serve a challenge file from ${ACME_WEBROOT}; certificate issuance and renewal would fail"
	fi
else
	skip "cannot write a probe challenge file to ${ACME_DIR} (run as root to test this)"
fi

# --- TLS listeners ----------------------------------------------------------
section "TLS certificates"
for target in "${PROXY_HOST}:${PROXY_PORT}|proxy endpoint" "${SERVER_HOST}:${TLS_PORT}|TURN over TLS"; do
	hostport="${target%%|*}"
	label="${target##*|}"
	host="${hostport%:*}"
	port="${hostport##*:}"
	# The proxy may be checked against its own CA (staging certificates), while the
	# TURN listener uses the general one.
	openssl_ca=()
	if [[ "${label}" == "proxy endpoint" && -n "${PROXY_CA}" ]]; then
		openssl_ca=(-CAfile "${PROXY_CA}")
	elif [[ -n "${CA_FILE}" ]]; then
		openssl_ca=(-CAfile "${CA_FILE}")
	fi
	if ! ss -Hltn "sport = :${port}" 2>/dev/null | grep -q .; then
		skip "${label}: TCP ${port} is not listening"
		continue
	fi
	verify_out="$(timeout 10 openssl s_client -connect "${hostport}" -servername "${host}" \
		-verify_hostname "${host}" -verify_return_error "${openssl_ca[@]}" 2>&1 </dev/null || true)"
	if grep -q 'Verify return code: 0 (ok)' <<<"${verify_out}"; then
		pass "${label}: certificate is publicly trusted and valid for ${host}"
	else
		# An IP certificate has no host name; verify it as an IP instead.
		verify_out_ip="$(timeout 10 openssl s_client -connect "${hostport}" \
			-verify_ip "${host}" -verify_return_error "${openssl_ca[@]}" 2>&1 </dev/null || true)"
		if grep -q 'Verify return code: 0 (ok)' <<<"${verify_out_ip}"; then
			pass "${label}: certificate is publicly trusted and valid for IP ${host}"
		else
			fail "${label}: certificate did not verify for ${host}"
			grep -E 'Verify return code|verify error' <<<"${verify_out}" | head -3 | sed 's/^/        /'
		fi
	fi
done

# A certificate from a public CA is only usable if its intermediate is sent as
# well. Squid's GnuTLS builds never do that, which is why the installer requires
# the OpenSSL flavour; this check catches a regression on either side.
if ss -Hltn "sport = :${PROXY_PORT}" 2>/dev/null | grep -q .; then
	chain_sent="$(timeout 10 openssl s_client -connect "${PROXY_HOST}:${PROXY_PORT}" \
		-servername "${PROXY_HOST}" -showcerts 2>/dev/null </dev/null | grep -c 'BEGIN CERTIFICATE' || true)"
	if [[ "${chain_sent:-0}" -ge 2 ]]; then
		pass "proxy sends the full certificate chain (${chain_sent} certificates)"
	elif [[ "${chain_sent:-0}" -eq 1 ]]; then
		fail "proxy sends only its leaf certificate, so clients cannot build a trusted chain; this needs the OpenSSL build of Squid (GnuTLS builds never send intermediates)"
	else
		warn "could not read the proxy certificate chain"
	fi
fi

if [[ -r "${TLS_CERT}" ]]; then
	not_after="$(openssl x509 -in "${TLS_CERT}" -noout -enddate | cut -d= -f2)"
	note "certificate expires ${not_after}"
	if openssl x509 -in "${TLS_CERT}" -noout -checkend 86400 >/dev/null 2>&1; then
		pass "certificate is valid for at least another 24 hours"
	else
		fail "certificate expires within 24 hours; renewal is not keeping up"
	fi
else
	fail "cannot read ${TLS_CERT}"
fi

if [[ "${SKIP_UNITS}" == "1" ]]; then
	skip "renewal timer checks disabled"
else
	for state in enabled active; do
		if systemctl is-${state} --quiet pishcord-relay-certbot-renew.timer 2>/dev/null; then
			pass "pishcord-relay-certbot-renew.timer is ${state}"
		else
			fail "pishcord-relay-certbot-renew.timer is not ${state}"
		fi
	done
fi

CERTBOT_BIN="${PISHCORD_RELAY_CERTBOT:-}"
if [[ -z "${CERTBOT_BIN}" ]]; then
	if [[ -x /opt/pishcord-relay-certbot/bin/certbot ]]; then
		CERTBOT_BIN=/opt/pishcord-relay-certbot/bin/certbot
	elif command -v certbot >/dev/null 2>&1; then
		CERTBOT_BIN="$(command -v certbot)"
	fi
fi
if [[ "${SKIP_RENEW}" == "1" ]]; then
	skip "renewal dry-run disabled (PISHCORD_RELAY_SKIP_RENEW=1)"
elif [[ -z "${CERTBOT_BIN}" ]]; then
	skip "certbot not found; cannot test renewal"
else
	if "${CERTBOT_BIN}" renew --cert-name "${CERT_NAME}" --dry-run --non-interactive --quiet >/dev/null 2>&1; then
		pass "certbot renew --dry-run succeeded for the ${CERT_NAME} lineage"
	else
		fail "certbot renew --dry-run failed; check port 80 reachability and the certbot log"
	fi
fi

# --- TURN authentication ----------------------------------------------------
section "TURN authentication and relaying"
if [[ -z "${UCLIENT}" ]]; then
	skip "turnutils_uclient not found (install coturn utilities to test allocation)"
elif [[ -z "${USERNAME}" ]]; then
	fail "no credential was obtained, so TURN authentication could not be tested"
else
	probe_peer="${PROBE_PEER:-${SERVER_IP}}"
	turn_probe() { # <server> <user> <password> [extra args...]
		local server="$1" user="$2" pass="$3"
		shift 3
		local out
		out="$(timeout 15 "${UCLIENT}" -v -c -n 1 -m 1 -p "${UDP_PORT}" \
			-e "${probe_peer}" -r "${PROBE_PEER_PORT}" \
			-u "${user}" -w "${pass}" "$@" "${server}" 2>&1 || true)"
		printf '%s' "${out}"
	}

	udp_out="$(turn_probe "${SERVER_IP}" "${USERNAME}" "${CREDENTIAL}")"
	if grep -q 'Received relay addr' <<<"${udp_out}"; then
		relay_addr="$(grep -o 'Received relay addr: [0-9.]*:[0-9]*' <<<"${udp_out}" | head -1)"
		pass "a TURN client obtained a relay candidate over UDP (${relay_addr#Received relay addr: })"
	else
		fail "no relay candidate for valid credentials over UDP"
		tail -3 <<<"${udp_out}" | sed 's/^/        /'
	fi

	if [[ -n "${TLS_URL}" ]]; then
		# The TLS listener is verified by name above; uclient is pointed at the
		# resolved address so its own name handling cannot mask a real failure.
		tls_out="$(timeout 20 "${UCLIENT}" -v -c -t -S -p "${TLS_PORT}" \
			-E "${CA_FILE:-/etc/ssl/certs/ca-certificates.crt}" -n 1 -m 1 \
			-e "${probe_peer}" -r "${PROBE_PEER_PORT}" \
			-u "${USERNAME}" -w "${CREDENTIAL}" "${SERVER_IP}" 2>&1 || true)"
		if grep -q 'Received relay addr' <<<"${tls_out}"; then
			pass "a TURN client obtained a relay candidate over TLS"
		else
			fail "no relay candidate over TLS"
			tail -3 <<<"${tls_out}" | sed 's/^/        /'
		fi
	fi

	bad_out="$(turn_probe "${SERVER_IP}" "${USERNAME}" 'aaaaaaaaaaaaaaaaaaaaaaaaaaaa')"
	if grep -q 'Received relay addr' <<<"${bad_out}"; then
		fail "an allocation succeeded with a wrong password"
	else
		pass "a wrong password is rejected (no allocation)"
	fi

	expired_user="1000000000:${IDENTITY}"
	expired_pass=""
	if [[ -r "${SECRET_FILE}" ]]; then
		expired_pass="$(python3 - "${expired_user}" "${SECRET_FILE}" <<'PY'
import base64, hashlib, hmac, sys
u, f = sys.argv[1], sys.argv[2]
print(base64.b64encode(hmac.new(open(f, "rb").read().strip(), u.encode(), hashlib.sha1).digest()).decode())
PY
)"
	fi
	expired_out="$(turn_probe "${SERVER_IP}" "${expired_user}" "${expired_pass}")"
	if grep -q 'Received relay addr' <<<"${expired_out}"; then
		fail "an expired username was accepted"
	else
		pass "an expired username timestamp is rejected (no allocation)"
	fi

	anon_out="$(turn_probe "${SERVER_IP}" "" "")"
	if grep -q 'Received relay addr' <<<"${anon_out}"; then
		fail "an unauthenticated allocation succeeded"
	else
		pass "an unauthenticated allocation is rejected"
	fi

	if [[ -r "${TURN_LOG}" ]] && grep -q '401: Unauthorized' "${TURN_LOG}" 2>/dev/null; then
		note "coturn logged 401: Unauthorized for the rejected probes"
	fi
fi

# --- media forwarding -------------------------------------------------------
section "Media forwarding"
MEDIA_PEER="${PROBE_PEER}"
if [[ -z "${MEDIA_PEER}" ]]; then
	if ip -o -4 addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -qx "${SERVER_IP}"; then
		MEDIA_PEER="${SERVER_IP}"
	fi
fi

if [[ -n "${UCLIENT}" && -n "${USERNAME}" && -n "${MEDIA_PEER}" && -n "${PEER_BIN}" ]]; then
	peer_pid=""
	if ! ss -Hlun "sport = :${PROBE_PEER_PORT}" 2>/dev/null | grep -q .; then
		"${PEER_BIN}" -L "${MEDIA_PEER}" -p "${PROBE_PEER_PORT}" >/dev/null 2>&1 &
		peer_pid=$!
		sleep 1
	fi
	media_out="$(timeout 30 "${UCLIENT}" -v -c -n 10 -m 1 -e "${MEDIA_PEER}" -r "${PROBE_PEER_PORT}" \
		-p "${UDP_PORT}" -u "${USERNAME}" -w "${CREDENTIAL}" "${SERVER_IP}" 2>&1 || true)"
	[[ -n "${peer_pid}" ]] && kill "${peer_pid}" 2>/dev/null
	sent="$(grep -o 'tot_send_msgs=[0-9]*' <<<"${media_out}" | tail -1 | cut -d= -f2)"
	recv="$(grep -o 'tot_recv_msgs=[0-9]*' <<<"${media_out}" | tail -1 | cut -d= -f2)"
	if [[ "${sent:-0}" -ge 10 && "${recv:-0}" -ge 10 ]]; then
		pass "bidirectional media traversed the relay (sent=${sent}, received=${recv})"
	else
		fail "media did not traverse the relay (sent=${sent:-0}, received=${recv:-0})"
	fi
else
	skip "media test needs turnutils_peer and a peer address on this host; set PISHCORD_RELAY_PROBE_PEER"
fi

# --- outbound connectivity --------------------------------------------------
section "Outbound connectivity"
outbound="$(python3 - <<'PY' 2>/dev/null
import socket, struct, sys
for host in ("stun.l.google.com", "stun.cloudflare.com"):
    try:
        addr = socket.getaddrinfo(host, 19302, socket.AF_INET, socket.SOCK_DGRAM)[0][4]
    except Exception:
        continue
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(4)
    request = struct.pack("!HHI", 0x0001, 0, 0x2112A442) + b"\x00" * 12
    try:
        sock.sendto(request, addr)
        data, _ = sock.recvfrom(1024)
        if len(data) >= 20 and data[0:2] == b"\x01\x01":
            print(host)
            sys.exit(0)
    except Exception:
        pass
    finally:
        sock.close()
sys.exit(1)
PY
)"
if [[ -n "${outbound}" ]]; then
	pass "STUN binding over outbound UDP works (echo from ${outbound})"
else
	udp_dns="$(python3 - <<'PY' 2>/dev/null
import socket, sys
query = (b'\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00'
         b'\x07example\x03com\x00\x00\x01\x00\x01')
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(4)
try:
    s.sendto(query, ('1.1.1.1', 53))
    data, _ = s.recvfrom(512)
    if len(data) > 12:
        print("ok")
        sys.exit(0)
except Exception:
    pass
sys.exit(1)
PY
)"
	if [[ -n "${udp_dns}" ]]; then
		warn "outbound UDP to a public DNS server works, but no STUN reply arrived; this network may filter UDP to non-DNS ports. Confirm that UDP to Discord's ICE endpoints is permitted"
	else
		fail "no outbound UDP at all; relayed media cannot reach remote ICE endpoints (check egress firewall rules)"
	fi
fi

# --- summary ----------------------------------------------------------------
printf '\nSummary: %d passed, %d failed, %d warnings, %d skipped\n' \
	"${passed}" "${failed}" "${warned}" "${skipped}"
if [[ ${failed} -gt 0 ]]; then
	exit 1
fi
exit 0
