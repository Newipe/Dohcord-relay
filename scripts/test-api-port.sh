#!/usr/bin/env bash
# Integration tests for the configurable Network Configuration API port.
#
# Covers: the installer's default/custom/upgrade selection, invalid ports,
# configuration persistence (installer and management console), the management
# console's port resolution and the daemon actually serving /network-config on a
# custom port with an unchanged document.
#
# Everything runs in a temporary directory and against ports on 127.0.0.1, so no
# installation or root access is required. Skips (exit 0) when a required tool is
# missing.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/pishcord-relay-port-test.XXXXXX")"
trap 'rm -rf -- "${TMP}"' EXIT

for tool in go openssl curl python3; do
	if ! command -v "${tool}" >/dev/null 2>&1; then
		printf 'SKIP  %s is required for the API port tests\n' "${tool}"
		exit 0
	fi
done

fail=0
ok() { printf 'PASS  %s\n' "$*"; }
bad() {
	printf 'FAIL  %s\n' "$*"
	fail=1
}

pick_port() {
	python3 - <<'PY'
import socket
s = socket.socket()
try:
    s.bind(("0.0.0.0", 0))
    print(s.getsockname()[1])
finally:
    s.close()
PY
}

# Installer function library: the real script with its ETC_DIR/WEBROOT pointed at
# the fixture, the root-only directory creation removed and the final main call
# dropped.
sed -e "s|readonly ETC_DIR=\"/etc/pishcord-relay\"|readonly ETC_DIR=\"${TMP}/etc\"|" \
	-e "s|readonly WEBROOT=\"/var/www/pishcord-relay\"|readonly WEBROOT=\"${TMP}/webroot\"|" \
	-e '$d' "${REPO}/deploy/install.sh" >"${TMP}/install-lib.sh"
sed -i 's|^[[:space:]]*install -d -m 0755 -o root -g root "${WEBROOT}"$|:|' "${TMP}/install-lib.sh"
sed -e "s|^main \"\$@\"$||" "${REPO}/deploy/scripts/pishcord-relay-manager.sh" >"${TMP}/manager-lib.sh"
mkdir -p "${TMP}/etc"

# --- installer: fresh default -------------------------------------------------
out="$(bash -c '
set -Eeuo pipefail
source "'"${TMP}"'/install-lib.sh"
ASSUME_YES=1
select_api_port
printf "PORT=%s\n" "${API_PORT}"
' 2>&1)"
if grep -q '^PORT=8443$' <<<"${out}" && grep -q 'default' <<<"${out}"; then
	ok "fresh non-interactive install defaults to 8443"
else
	bad "fresh default: ${out}"
fi

# --- installer: upgrade keeps the configured port ----------------------------
cat >"${TMP}/etc/config.env" <<'EOF'
HTTPS_PROXY_URL=https://relay.example.test:443
NETWORK_CONFIG_PORT=9443
NETWORK_CONFIG_URL=https://relay.example.test:9443/network-config
HTTPS_LISTEN=:9443
TURN_URLS=turn:relay.example.test:3478
EOF
out="$(bash -c '
set -Eeuo pipefail
source "'"${TMP}"'/install-lib.sh"
select_api_port
printf "PORT=%s PREV=%s\n" "${API_PORT}" "${PREVIOUS_API_PORT}"
' 2>&1)"
if grep -q '^PORT=9443 PREV=9443$' <<<"${out}" && grep -q 'keeping it' <<<"${out}"; then
	ok "upgrade preserves NETWORK_CONFIG_PORT and does not prompt"
else
	bad "upgrade preserve: ${out}"
fi

# --- installer: interactive re-run shows and can change the port -------------
if command -v script >/dev/null 2>&1; then
	cat >"${TMP}/prompt-existing.sh" <<EOF
set -Eeuo pipefail
source "${TMP}/install-lib.sh"
select_api_port
printf 'PORT=%s PREV=%s\\n' "\${API_PORT}" "\${PREVIOUS_API_PORT}"
EOF
	out="$(printf '\n' | script -qec "bash '${TMP}/prompt-existing.sh'" /dev/null 2>&1 | tr -d '\r')"
	if grep -q '^PORT=9443 PREV=9443$' <<<"${out}" &&
		grep -q 'Network Configuration API port \[9443\]' <<<"${out}"; then
		ok "interactive re-run asks for the port, keeping the configured one on Enter"
	else
		bad "interactive prompt (keep): ${out}"
	fi
	out="$(printf '9666\n' | script -qec "bash '${TMP}/prompt-existing.sh'" /dev/null 2>&1 | tr -d '\r')"
	if grep -q '^PORT=9666 PREV=9443$' <<<"${out}" &&
		grep -q 'will listen on 9666/tcp' <<<"${out}"; then
		ok "interactive re-run can move the API to a custom port and records the old one"
	else
		bad "interactive prompt (change): ${out}"
	fi
else
	printf 'SKIP  script(1) is required for the interactive prompt tests\n'
fi

# --- installer: explicit --api-port changes an existing install --------------
out="$(bash -c '
set -Eeuo pipefail
source "'"${TMP}"'/install-lib.sh"
API_PORT=9555
API_PORT_EXPLICIT=1
select_api_port
printf "PORT=%s PREV=%s\n" "${API_PORT}" "${PREVIOUS_API_PORT}"
' 2>&1)"
if grep -q '^PORT=9555 PREV=9443$' <<<"${out}" && grep -q 'changing' <<<"${out}"; then
	ok "explicit --api-port changes an existing installation and records the old port"
else
	bad "explicit upgrade: ${out}"
fi

# --- installer: legacy upgrade with only HTTPS_LISTEN ------------------------
cat >"${TMP}/etc/config.env" <<'EOF'
HTTPS_PROXY_URL=https://relay.example.test:443
NETWORK_CONFIG_URL=https://relay.example.test:9555/network-config
HTTPS_LISTEN=:9555
TURN_URLS=turn:relay.example.test:3478
EOF
out="$(bash -c '
set -Eeuo pipefail
source "'"${TMP}"'/install-lib.sh"
select_api_port
printf "PORT=%s\n" "${API_PORT}"
' 2>&1)"
if grep -q '^PORT=9555$' <<<"${out}"; then
	ok "legacy configuration keeps the port from HTTPS_LISTEN"
else
	bad "legacy preserve: ${out}"
fi

# --- installer: invalid explicit ports --------------------------------------
rm -f "${TMP}/etc/config.env"
for p in 80 443 3478 5349 70000 abc; do
	if bash -c '
set -Eeuo pipefail
source "'"${TMP}"'/install-lib.sh"
API_PORT="'"${p}"'"
API_PORT_EXPLICIT=1
select_api_port
' >/dev/null 2>&1; then
		bad "installer accepted --api-port ${p}"
	else
		ok "installer rejects --api-port ${p}"
	fi
done

# --- installer: render_config_env updates one authoritative value ------------
cat >"${TMP}/etc/config.env" <<'EOF'
HTTPS_PROXY_URL=https://old.example:443
NETWORK_CONFIG_PORT=8443
NETWORK_CONFIG_URL=https://old.example:8443/network-config
HTTPS_LISTEN=127.0.0.1:8443
TURN_URLS=turn:old.example:3478
CUSTOM_TUNING=keep-me
EOF
out="$(bash -c '
set -Eeuo pipefail
source "'"${TMP}"'/install-lib.sh"
install() { :; }
chown() { :; }
chmod() { :; }
REPO_DIR="'"${REPO}"'"
PUBLIC_HOST=relay.example.test
PROXY_PORT=443
API_PORT=9443
SQUID_BINARY=/usr/sbin/squid
render_config_env
' 2>&1)" || bad "render_config_env failed: ${out}"
cfg="${TMP}/etc/config.env"
if [[ "$(grep -c '^NETWORK_CONFIG_PORT=' "${cfg}")" == "1" ]] &&
	[[ "$(grep -c '^NETWORK_CONFIG_PORT=9443$' "${cfg}")" == "1" ]] &&
	grep -q '^NETWORK_CONFIG_URL=https://relay.example.test:9443/network-config$' "${cfg}" &&
	grep -q '^HTTPS_LISTEN=127.0.0.1:9443$' "${cfg}" &&
	grep -q '^CUSTOM_TUNING=keep-me$' "${cfg}"; then
	ok "render_config_env keeps tuning and listener host while changing the port"
else
	bad "render_config_env did not update consistently: $(grep -E 'NETWORK_CONFIG_PORT|NETWORK_CONFIG_URL|HTTPS_LISTEN|CUSTOM' "${cfg}")"
fi

# --- manager: port resolution, dashboard and config rewrite ------------------
BIN="${TMP}/fake-pishcord-relayd"
printf '#!/bin/sh\nexit 0\n' >"${BIN}"
chmod +x "${BIN}"
mkdir -p "${TMP}/mgr/etc"
cat >"${TMP}/mgr/etc/config.env" <<'EOF'
HTTPS_PROXY_URL=https://relay.example.test:443
NETWORK_CONFIG_PORT=9443
NETWORK_CONFIG_URL=https://relay.example.test:9443/network-config
HTTPS_LISTEN=127.0.0.1:9443
TURN_URLS=turn:relay.example.test:3478
EOF
cat >"${TMP}/mgr/etc/install-info" <<'EOF'
INSTALLER_VERSION=1.0.0
MODE=domain
PUBLIC_HOST=relay.example.test
PUBLIC_IP=203.0.113.10
PROXY_PORT=443
API_PORT=9443
EOF
out="$(bash -c '
set -Eeuo pipefail
export PISHCORD_RELAY_ETC_DIR="'"${TMP}"'/mgr/etc"
export PISHCORD_RELAY_BIN="'"${BIN}"'"
export PISHCORD_RELAY_LIB_DIR="'"${TMP}"'/mgr/lib"
export NO_COLOR=1
source "'"${TMP}"'/manager-lib.sh"
printf "PORT=%s\n" "$(api_port)"
dashboard
write_api_port_config 9555
' 2>&1)"
if grep -q '^PORT=9443$' <<<"${out}" && grep -q 'Network config port.*9443' <<<"${out}"; then
	ok "manager resolves and displays the configured port"
else
	bad "manager port/dashboard: ${out}"
fi
cfg="${TMP}/mgr/etc/config.env"
if [[ "$(grep -c '^NETWORK_CONFIG_PORT=' "${cfg}")" == "1" ]] &&
	[[ "$(grep -c '^NETWORK_CONFIG_PORT=9555$' "${cfg}")" == "1" ]] &&
	grep -q '^NETWORK_CONFIG_URL=https://relay.example.test:9555/network-config$' "${cfg}" &&
	grep -q '^HTTPS_LISTEN=127.0.0.1:9555$' "${cfg}"; then
	ok "manager rewrite updates port, URL and listener together"
else
	bad "manager rewrite: $(grep -E 'NETWORK_CONFIG|HTTPS_LISTEN' "${cfg}")"
fi

# --- manager: validation -----------------------------------------------------
out="$(bash -c '
set -Eeuo pipefail
export PISHCORD_RELAY_ETC_DIR="'"${TMP}"'/mgr/etc"
export NO_COLOR=1
source "'"${TMP}"'/manager-lib.sh"
for p in 80 443 3478 5349 70000 abc; do
	if ! reason="$(api_port_conflict "${p}")"; then
		printf "ACCEPTED %s\n" "${p}"
	fi
done
printf "DONE\n"
' 2>&1)"
if grep -q '^ACCEPTED' <<<"${out}" || ! grep -q '^DONE$' <<<"${out}"; then
	bad "manager port validation: ${out}"
else
	ok "manager rejects invalid and reserved ports"
fi

# --- daemon: /network-config on the configured custom port -------------------
(
	cd "${REPO}" && CGO_ENABLED=0 go build -o "${TMP}/pishcord-relayd" ./cmd/pishcord-relayd
) || bad "daemon build failed"
PORT="$(pick_port)"
D="${TMP}/daemon"
mkdir -p "${D}/etc"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
	-keyout "${D}/key.pem" -out "${D}/cert.pem" -subj "/CN=relay.example.test" >/dev/null 2>&1
openssl rand -hex 32 >"${D}/secret"
cp "${REPO}/deploy/templates/allowed-domains.txt" "${D}/allowed-domains.txt"
cp "${REPO}/deploy/templates/destination-policy.conf" "${D}/destination-policy.conf"
cat >"${D}/etc/config.env" <<EOF
HTTPS_PROXY_URL=https://relay.example.test:443
NETWORK_CONFIG_PORT=${PORT}
NETWORK_CONFIG_URL=https://relay.example.test:${PORT}/network-config
HTTPS_LISTEN=:${PORT}
HTTP_LISTEN=
TURN_URLS=turn:relay.example.test:3478?transport=udp
SECRET_FILE=${D}/secret
TLS_CERT_FILE=${D}/cert.pem
TLS_KEY_FILE=${D}/key.pem
ALLOWED_DOMAINS_FILE=${D}/allowed-domains.txt
DESTINATION_POLICY_FILE=${D}/destination-policy.conf
POLICY_STATE_FILE=${D}/policy.json
SQUID_CONF=${D}/squid.conf
SQUID_ALLOW_FILE=${D}/squid-allow.conf
SQUID_BINARY=/usr/sbin/squid
EOF
"${TMP}/pishcord-relayd" -config "${D}/etc/config.env" >"${D}/daemon.log" 2>&1 &
pid=$!
ready=0
for _ in $(seq 1 40); do
	if code="$(curl -sk --max-time 2 -o "${D}/body.json" -w '%{http_code}' "https://127.0.0.1:${PORT}/network-config" 2>/dev/null)" &&
		[[ "${code}" == "200" ]]; then
		ready=1
		break
	fi
	sleep 0.25
done
if [[ ${ready} -eq 1 ]] && python3 - "${D}/body.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["schemaVersion"] == 1
assert d["httpsProxy"]["url"] == "https://relay.example.test:443"
assert d["proxy"]["port"] == 443
assert d["rtcRelay"]["iceServers"][0]["username"].endswith(":Pishcord")
PY
then
	ok "daemon serves the unchanged /network-config JSON on the configured port"
else
	bad "custom-port daemon did not serve /network-config (code=${code:-none}); log: $(tail -5 "${D}/daemon.log")"
fi
kill "${pid}" 2>/dev/null
wait "${pid}" 2>/dev/null

# --- daemon: legacy configuration without NETWORK_CONFIG_PORT ---------------
sed -i '/^NETWORK_CONFIG_PORT=/d' "${D}/etc/config.env"
"${TMP}/pishcord-relayd" -config "${D}/etc/config.env" -print-config >"${D}/printed" 2>&1
if grep -q "^NETWORK_CONFIG_PORT=${PORT}$" "${D}/printed"; then
	ok "-print-config derives the port from HTTPS_LISTEN for an older configuration"
else
	bad "legacy print-config: $(grep NETWORK_CONFIG_PORT "${D}/printed")"
fi

printf '\nAPI port tests: %s\n' "$( ((fail == 0)) && echo 'passed' || echo 'FAILED' )"
exit "${fail}"
