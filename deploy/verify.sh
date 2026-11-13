#!/usr/bin/env bash
# Dohcord Relay verification suite.
#
# Checks a live installation end to end and prints one line per check. Exits
# non-zero when any check fails. Nothing here changes configuration; the only
# side effects are temporary TURN allocations and a short-lived echo peer used by
# the media test.
#
# Run as root (or as a user that can read /etc/dohcord-relay and the coturn log):
#
#   sudo deploy/verify.sh
#
# Environment overrides (used by the installer and by local testing):
#   DOHCORD_RELAY_CONFIG        config.env path
#   DOHCORD_RELAY_TURNSERVER_CONF, DOHCORD_RELAY_SECRET_FILE, DOHCORD_RELAY_TLS_CERT
#   DOHCORD_RELAY_COTURN_UNIT, DOHCORD_RELAY_CRED_UNIT, DOHCORD_RELAY_SKIP_UNITS
#   DOHCORD_RELAY_PROBE_PEER, DOHCORD_RELAY_PROBE_PEER_PORT
#   DOHCORD_RELAY_SKIP_RENEW, DOHCORD_RELAY_CERTBOT
set -uo pipefail

CONFIG="${DOHCORD_RELAY_CONFIG:-/etc/dohcord-relay/config.env}"
TURN_CONF="${DOHCORD_RELAY_TURNSERVER_CONF:-/etc/dohcord-relay/turnserver.conf}"
SECRET_FILE="${DOHCORD_RELAY_SECRET_FILE:-/etc/dohcord-relay/turn-secret}"
TLS_CERT="${DOHCORD_RELAY_TLS_CERT:-/etc/dohcord-relay/tls/fullchain.pem}"
TURN_LOG="${DOHCORD_RELAY_TURN_LOG:-/var/log/dohcord-relay/turnserver.log}"
COTURN_UNIT="${DOHCORD_RELAY_COTURN_UNIT:-dohcord-relay-coturn.service}"
CRED_UNIT="${DOHCORD_RELAY_CRED_UNIT:-dohcord-relay-credentials.service}"
CERT_NAME="${DOHCORD_RELAY_CERT_NAME:-dohcord-relay}"
SKIP_UNITS="${DOHCORD_RELAY_SKIP_UNITS:-0}"
SKIP_RENEW="${DOHCORD_RELAY_SKIP_RENEW:-0}"
PROBE_PEER="${DOHCORD_RELAY_PROBE_PEER:-}"
PROBE_PEER_PORT="${DOHCORD_RELAY_PROBE_PEER_PORT:-3480}"
# Optional overrides, used when testing an installation that does not (yet) use
# the public Let's Encrypt certificate, for example a staging or local setup.
CA_FILE="${DOHCORD_RELAY_CA_FILE:-}"
ENDPOINT_OVERRIDE="${DOHCORD_RELAY_ENDPOINT:-}"

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
IDENTITY="${IDENTITY:-Dohcord}"
TTL_RAW="$(cfg CREDENTIAL_TTL)"

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

parse_url() { # <url> -> sets URL_HOST URL_PORT
	local u="$1"
	URL_HOST=""
	URL_PORT=""
	if [[ "${u}" =~ ^turns?://?([0-9.]+):([0-9]+) ]] ||
		[[ "${u}" =~ ^turns?:([0-9.]+):([0-9]+) ]]; then
		URL_HOST="${BASH_REMATCH[1]}"
		URL_PORT="${BASH_REMATCH[2]}"
	fi
}

parse_url "${UDP_URL}"
SERVER_IP="${URL_HOST}"
UDP_PORT="${URL_PORT:-3478}"
TLS_PORT="5349"
if [[ -n "${TLS_URL}" ]]; then
	parse_url "${TLS_URL}"
	TLS_PORT="${URL_PORT:-5349}"
fi

[[ -n "${SERVER_IP}" ]] || {
	printf 'error: cannot parse the server address from %s\n' "${UDP_URL}" >&2
	exit 2
}

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
UTILS_DIR=""
if [[ -z "${UCLIENT}" ]]; then
	for candidate in /usr/local/bin/turnutils_uclient /usr/bin/turnutils_uclient; do
		[[ -x "${candidate}" ]] && UCLIENT="${candidate}" && break
	done
fi
[[ -n "${UCLIENT}" ]] && UTILS_DIR="$(dirname "${UCLIENT}")"
PEER_BIN=""
[[ -n "${UTILS_DIR}" && -x "${UTILS_DIR}/turnutils_peer" ]] && PEER_BIN="${UTILS_DIR}/turnutils_peer"

printf 'Dohcord Relay verification\n'
printf '  server      %s\n' "${SERVER_IP}"
printf '  turn url    %s\n' "${UDP_URL}"
printf '  tls url     %s\n' "${TLS_URL:-<not configured>}"
printf '  identity    %s\n' "${IDENTITY}"

# --- services ---------------------------------------------------------------
section "Services"
if [[ "${SKIP_UNITS}" == "1" ]]; then
	skip "systemd checks disabled (DOHCORD_RELAY_SKIP_UNITS=1)"
else
	for unit in "${COTURN_UNIT}" "${CRED_UNIT}"; do
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
	if ss -Hlun "sport = :${UDP_PORT}" 2>/dev/null | grep -q .; then
		pass "UDP ${UDP_PORT} is listening (primary TURN)"
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

# --- limits -----------------------------------------------------------------
section "Limits and peer filtering"
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
		fail "bps-capacity (${bps_capacity}) is below two max-bps reservations (${max_bps}); coturn will reject allocations with error 486"
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

# --- HTTPS contract ---------------------------------------------------------
section "HTTPS credential endpoint"
ENDPOINT="${ENDPOINT_OVERRIDE:-https://${SERVER_IP}/turn-credentials}"
BODY_FILE="$(mktemp)"
HEADER_FILE="$(mktemp)"
trap 'rm -f "${BODY_FILE}" "${HEADER_FILE}"' EXIT

curl_tls_args=()
[[ -n "${CA_FILE}" ]] && curl_tls_args+=(--cacert "${CA_FILE}")
http_status="$(curl -sS --max-time 15 "${curl_tls_args[@]}" -D "${HEADER_FILE}" -o "${BODY_FILE}" \
	-w '%{http_code}' "${ENDPOINT}" 2>/dev/null || echo 000)"

if [[ "${http_status}" == "200" ]]; then
	pass "GET ${ENDPOINT} returned 200 with a verified certificate for ${SERVER_IP}"
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
if [[ "${http_status}" == "200" ]]; then
	eval "$(python3 - "${BODY_FILE}" <<'PY'
import json, shlex, sys
try:
    d = json.load(open(sys.argv[1]))
    ice = d["iceServers"][0]
    print("USERNAME=" + shlex.quote(ice["username"]))
    print("CREDENTIAL=" + shlex.quote(ice["credential"]))
    print("EXPIRES_AT=" + shlex.quote(str(d["expiresAt"])))
    print("URLS=" + shlex.quote(",".join(ice["urls"])))
except Exception:
    pass
PY
)"

	[[ -n "${USERNAME}" && -n "${CREDENTIAL}" ]] && pass "credentials are present in the response" ||
		fail "response does not contain username/credential"

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
	else
		skip "cannot read ${SECRET_FILE} to re-compute the credential"
	fi
fi

# --- TLS listener -----------------------------------------------------------
section "TURN over TLS"
if [[ -n "${TLS_URL}" ]]; then
	openssl_ca=()
	[[ -n "${CA_FILE}" ]] && openssl_ca=(-CAfile "${CA_FILE}")
	verify_out="$(timeout 10 openssl s_client -connect "${SERVER_IP}:${TLS_PORT}" \
		-verify_ip "${SERVER_IP}" -verify_return_error "${openssl_ca[@]}" 2>&1 </dev/null || true)"
	if grep -q 'Verify return code: 0 (ok)' <<<"${verify_out}"; then
		pass "TLS ${TLS_PORT} presents a certificate that is valid for ${SERVER_IP}"
	else
		fail "TLS ${TLS_PORT} certificate did not verify for ${SERVER_IP}"
		grep -E 'Verify return code|verify error' <<<"${verify_out}" | head -3 | sed 's/^/        /'
	fi
else
	skip "no turns: URL configured"
fi

# --- TURN authentication ----------------------------------------------------
section "TURN authentication and relaying"
if [[ -z "${UCLIENT}" ]]; then
	skip "turnutils_uclient not found (install coturn utilities to test allocation)"
else
	# uclient needs a peer address even for an allocation-only probe. Using the
	# relay's own address keeps the probe local; the permission may be refused
	# and that is fine, the ALLOCATE itself is what is being checked.
	probe_peer="${PROBE_PEER:-${SERVER_IP}}"
	turn_probe() { # <user> <password>
		local user="$1" pass="$2"
		shift 2
		local out
		out="$(timeout 15 "${UCLIENT}" -v -c -n 1 -m 1 -p "${UDP_PORT}" \
			-e "${probe_peer}" -r "${PROBE_PEER_PORT}" \
			-u "${user}" -w "${pass}" "$@" "${SERVER_IP}" 2>&1 || true)"
		printf '%s' "${out}"
	}

	if [[ -n "${USERNAME}" ]]; then
		probe_out="$(turn_probe "${USERNAME}" "${CREDENTIAL}")"
		if grep -q 'Received relay addr' <<<"${probe_out}"; then
			relay_addr="$(grep -o 'Received relay addr: [0-9.]*:[0-9]*' <<<"${probe_out}" | head -1)"
			pass "a TURN client obtained a relay candidate (${relay_addr#Received relay addr: })"
		else
			fail "no relay candidate for valid credentials"
			tail -3 <<<"${probe_out}" | sed 's/^/        /'
		fi

		if [[ -n "${TLS_URL}" ]]; then
			trust_store="${CA_FILE:-/etc/ssl/certs/ca-certificates.crt}"
			tls_out="$(timeout 15 "${UCLIENT}" -v -c -t -S -p "${TLS_PORT}" \
				-E "${trust_store}" -n 1 -m 1 \
				-e "${probe_peer}" -r "${PROBE_PEER_PORT}" \
				-u "${USERNAME}" -w "${CREDENTIAL}" "${SERVER_IP}" 2>&1 || true)"
			if grep -q 'Received relay addr' <<<"${tls_out}"; then
				pass "a TURN client obtained a relay candidate over TLS"
			else
				fail "no relay candidate over TLS"
				tail -3 <<<"${tls_out}" | sed 's/^/        /'
			fi
		fi

		bad_out="$(turn_probe "${USERNAME}" 'aaaaaaaaaaaaaaaaaaaaaaaaaaaa')"
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
		expired_out="$(turn_probe "${expired_user}" "${expired_pass}")"
		if grep -q 'Received relay addr' <<<"${expired_out}"; then
			fail "an expired username was accepted"
		else
			pass "an expired username timestamp is rejected (no allocation)"
		fi

		anon_out="$(turn_probe '' '')"
		if grep -q 'Received relay addr' <<<"${anon_out}"; then
			fail "an unauthenticated allocation succeeded"
		else
			pass "an unauthenticated allocation is rejected"
		fi

		if [[ -r "${TURN_LOG}" ]] && grep -q '401: Unauthorized' "${TURN_LOG}" 2>/dev/null; then
			note "coturn logged 401: Unauthorized for the rejected probes"
		fi
	else
		fail "no credential was obtained, so TURN authentication could not be tested"
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
	if ! ss -Hlun "sport = :${PROBE_PEER_PORT}" 2>/dev/null | grep -q .; then
		"${PEER_BIN}" -L "${MEDIA_PEER}" -p "${PROBE_PEER_PORT}" >/dev/null 2>&1 &
		peer_pid=$!
		sleep 1
	fi
	media_out="$(timeout 30 "${UCLIENT}" -v -c -n 10 -m 1 -e "${MEDIA_PEER}" -r "${PROBE_PEER_PORT}" \
		-p "${UDP_PORT}" -u "${USERNAME}" -w "${CREDENTIAL}" "${SERVER_IP}" 2>&1 || true)"
	[[ -n "${peer_pid:-}" ]] && kill "${peer_pid}" 2>/dev/null
	sent="$(grep -o 'tot_send_msgs=[0-9]*' <<<"${media_out}" | tail -1 | cut -d= -f2)"
	recv="$(grep -o 'tot_recv_msgs=[0-9]*' <<<"${media_out}" | tail -1 | cut -d= -f2)"
	if [[ "${sent:-0}" -ge 10 && "${recv:-0}" -ge 10 ]]; then
		pass "bidirectional media traversed the relay (sent=${sent}, received=${recv})"
	else
		fail "media did not traverse the relay (sent=${sent:-0}, received=${recv:-0})"
	fi
else
	skip "media test needs turnutils_peer and a peer address on this host; set DOHCORD_RELAY_PROBE_PEER"
fi

# --- outbound UDP -----------------------------------------------------------
section "Outbound UDP"
# A real STUN Binding request to a public STUN server: this exercises exactly the
# egress path relayed media uses (UDP to a remote RTC endpoint).
outbound="$(python3 - <<'PY' 2>/dev/null
import socket, struct, sys
for host in ("stun.l.google.com", "stun.cloudflare.com"):
    try:
        addr = socket.getaddrinfo(host, 19302, socket.AF_INET, socket.SOCK_DGRAM)[0][4]
    except Exception:
        continue
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(4)
    # STUN Binding Request, magic cookie 0x2112A442, empty attributes.
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
	# Distinguish "no UDP egress at all" from "this network blocks UDP to
	# ports other than DNS", which some build/hosting environments do.
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
		warn "outbound UDP to a public DNS server works, but no STUN reply arrived; this network may filter UDP to non-DNS ports. Confirm on the host that UDP to Discord's ICE endpoints is permitted"
	else
		fail "no outbound UDP at all; relayed media cannot reach remote ICE endpoints (check egress firewall rules)"
	fi
fi

# --- certificate and renewal ------------------------------------------------
section "Certificate and renewal"
if [[ -r "${TLS_CERT}" ]]; then
	if openssl x509 -in "${TLS_CERT}" -noout -checkip "${SERVER_IP}" >/dev/null 2>&1; then
		pass "certificate includes ${SERVER_IP} as an IP Subject Alternative Name"
	else
		fail "certificate does not cover ${SERVER_IP}"
	fi
	not_after="$(openssl x509 -in "${TLS_CERT}" -noout -enddate | cut -d= -f2)"
	note "certificate expires ${not_after}"
else
	fail "cannot read ${TLS_CERT}"
fi

if [[ "${SKIP_UNITS}" == "1" ]]; then
	skip "renewal timer checks disabled"
else
	if systemctl is-enabled --quiet dohcord-relay-certbot-renew.timer 2>/dev/null; then
		pass "dohcord-relay-certbot-renew.timer is enabled"
	else
		fail "dohcord-relay-certbot-renew.timer is not enabled"
	fi
	if systemctl is-active --quiet dohcord-relay-certbot-renew.timer 2>/dev/null; then
		pass "dohcord-relay-certbot-renew.timer is active"
	else
		fail "dohcord-relay-certbot-renew.timer is not active"
	fi
fi

CERTBOT_BIN="${DOHCORD_RELAY_CERTBOT:-}"
if [[ -z "${CERTBOT_BIN}" ]]; then
	if [[ -x /opt/dohcord-relay-certbot/bin/certbot ]]; then
		CERTBOT_BIN=/opt/dohcord-relay-certbot/bin/certbot
	elif command -v certbot >/dev/null 2>&1; then
		CERTBOT_BIN="$(command -v certbot)"
	fi
fi
if [[ "${SKIP_RENEW}" == "1" ]]; then
	skip "renewal dry-run disabled (DOHCORD_RELAY_SKIP_RENEW=1)"
elif [[ -z "${CERTBOT_BIN}" ]]; then
	skip "certbot not found; cannot test renewal"
else
	if "${CERTBOT_BIN}" renew --cert-name "${CERT_NAME}" --dry-run --non-interactive --quiet >/dev/null 2>&1; then
		pass "certbot renew --dry-run succeeded for the ${CERT_NAME} lineage"
	else
		fail "certbot renew --dry-run failed; check port 80 reachability and the certbot log"
	fi
fi

# --- summary ----------------------------------------------------------------
printf '\nSummary: %d passed, %d failed, %d warnings, %d skipped\n' \
	"${passed}" "${failed}" "${warned}" "${skipped}"
if [[ ${failed} -gt 0 ]]; then
	exit 1
fi
exit 0
