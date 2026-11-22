#!/usr/bin/env bash
# Integration tests for the configurable network and performance limits.
#
# Covers: the shipped defaults, the interactive section (Enter keeps a value,
# custom values, invalid answers), non-interactive installs, upgrades that must
# not overwrite an administrator's settings, the rendered config.env, and the
# traffic-shaping helper's command generation (per-IP classes for both
# directions, both services, IPv6, disabled limits, pruning and bounds).
#
# Everything runs in a temporary directory: no installation, root access or
# network is required.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dohcord-relay-limits-test.XXXXXX")"
trap 'rm -rf -- "${TMP}"' EXIT

fail=0
ok() { printf 'PASS  %s\n' "$*"; }
bad() {
	printf 'FAIL  %s\n' "$*"
	fail=1
}

# --- installer harness --------------------------------------------------------
sed -e "s|readonly ETC_DIR=\"/etc/dohcord-relay\"|readonly ETC_DIR=\"${TMP}/etc\"|" \
	-e '$d' "${REPO}/deploy/install.sh" >"${TMP}/install-lib.sh"
mkdir -p "${TMP}/etc"

run() {
	bash -c "set -Eeuo pipefail
source '${TMP}/install-lib.sh'
${1}" 2>&1
}

fresh_etc() {
	rm -f "${TMP}/etc/config.env"
}

# --- 1. fresh non-interactive defaults ---------------------------------------
fresh_etc
out="$(run 'ASSUME_YES=1
select_performance_settings
for k in "${PERF_KEYS[@]}"; do printf "%s=%s\n" "${k}" "${!k}"; done')"
expect="PROXY_UPLOAD_LIMIT_MBIT=8
PROXY_DOWNLOAD_LIMIT_MBIT=8
TURN_UPLOAD_LIMIT_MBIT=16
TURN_DOWNLOAD_LIMIT_MBIT=16
PER_IP_RATE_PER_MINUTE=60
PER_IP_BURST=30
GLOBAL_RATE_PER_MINUTE=1200
GLOBAL_BURST=300
TC_REFRESH_SECONDS=5
TC_MAX_CLIENTS=512"
if [[ "$(grep -E '^[A-Z_]+=' <<<"${out}")" == "${expect}" ]]; then
	ok "a fresh non-interactive install uses the documented defaults"
else
	bad "fresh defaults: $(grep -E '^[A-Z_]+=' <<<"${out}" | tr '\n' ' ')"
fi

# --- 2. an existing installation keeps its configured values ------------------
cat >"${TMP}/etc/config.env" <<'EOF'
HTTPS_PROXY_URL=https://relay.example.test:443
PROXY_UPLOAD_LIMIT_MBIT=3
PROXY_DOWNLOAD_LIMIT_MBIT=4
TURN_UPLOAD_LIMIT_MBIT=5
TURN_DOWNLOAD_LIMIT_MBIT=6
PER_IP_RATE_PER_MINUTE=7
PER_IP_BURST=8
GLOBAL_RATE_PER_MINUTE=9
GLOBAL_BURST=10
TC_MAX_CLIENTS=64
TC_REFRESH_SECONDS=2
EOF
out="$(run 'ASSUME_YES=1
select_performance_settings
for k in "${PERF_KEYS[@]}"; do printf "%s=%s\n" "${k}" "${!k}"; done')"
if grep -qx 'PROXY_UPLOAD_LIMIT_MBIT=3' <<<"${out}" &&
	grep -qx 'TURN_DOWNLOAD_LIMIT_MBIT=6' <<<"${out}" &&
	grep -qx 'GLOBAL_BURST=10' <<<"${out}" &&
	grep -qx 'TC_MAX_CLIENTS=64' <<<"${out}"; then
	ok "re-running the installer preserves the configured limits"
else
	bad "upgrade preservation: ${out}"
fi

# --- 3. an explicit option changes an existing installation -------------------
out="$(run 'PROXY_UPLOAD_LIMIT_MBIT=42
PERF_EXPLICIT[PROXY_UPLOAD_LIMIT_MBIT]=1
ASSUME_YES=1
select_performance_settings
printf "UP=%s\n" "${PROXY_UPLOAD_LIMIT_MBIT}"
printf "TURN=%s\n" "${TURN_UPLOAD_LIMIT_MBIT}"')"
if grep -qx 'UP=42' <<<"${out}" && grep -qx 'TURN=5' <<<"${out}"; then
	ok "an explicit option wins while every other setting is preserved"
else
	bad "explicit option: ${out}"
fi

# --- 4. invalid explicit values are rejected ---------------------------------
for spec in "PROXY_UPLOAD_LIMIT_MBIT 100001" "PROXY_DOWNLOAD_LIMIT_MBIT -1" "PER_IP_RATE_PER_MINUTE 0" "GLOBAL_BURST 0" "TC_MAX_CLIENTS 4000" "TC_REFRESH_SECONDS 0"; do
	set -- ${spec}
	if run "$1='$2'
PERF_EXPLICIT[$1]=1
ASSUME_YES=1
select_performance_settings" >/dev/null; then
		bad "installer accepted $1=$2"
	else
		ok "installer rejects $1=$2"
	fi
done

# --- 5. interactive section --------------------------------------------------
if command -v script >/dev/null 2>&1; then
	cat >"${TMP}/perf-prompt.sh" <<EOF
set -Eeuo pipefail
source "${TMP}/install-lib.sh"
select_performance_settings
for k in "\${PERF_KEYS[@]}"; do printf '%s=%s\n' "\${k}" "\${!k}"; done
EOF
	fresh_etc
	out="$(printf '\n\n\n\n\n\n\n\n\n\n' | script -qec "bash '${TMP}/perf-prompt.sh'" /dev/null 2>&1 | tr -d '\r')"
	if grep -q 'Proxy upload limit per client IP Mbps \[8\]' <<<"${out}" &&
		grep -q 'API request burst per client IP \[30\]' <<<"${out}" &&
		grep -qx 'PROXY_UPLOAD_LIMIT_MBIT=8' <<<"${out}" &&
		grep -qx 'TURN_DOWNLOAD_LIMIT_MBIT=16' <<<"${out}"; then
		ok "interactive install shows every setting with its unit and default; Enter keeps it"
	else
		bad "interactive defaults: ${out}"
	fi

	out="$(printf '20\n\n6\n\n90\n50\n1800\n400\n3\n\n' | script -qec "bash '${TMP}/perf-prompt.sh'" /dev/null 2>&1 | tr -d '\r')"
	if grep -qx 'PROXY_UPLOAD_LIMIT_MBIT=20' <<<"${out}" &&
		grep -qx 'PROXY_DOWNLOAD_LIMIT_MBIT=8' <<<"${out}" &&
		grep -qx 'PER_IP_BURST=50' <<<"${out}" &&
		grep -qx 'GLOBAL_RATE_PER_MINUTE=1800' <<<"${out}" &&
		grep -qx 'TC_REFRESH_SECONDS=3' <<<"${out}" &&
		grep -qx 'TURN_UPLOAD_LIMIT_MBIT=6' <<<"${out}" &&
		grep -qx 'TURN_DOWNLOAD_LIMIT_MBIT=16' <<<"${out}"; then
		ok "interactive install accepts custom values and keeps defaults for empty answers"
	else
		bad "interactive custom values: ${out}"
	fi

	out="$(printf 'lots\n\n\n\n\n\n\n\n\n\n\n' | script -qec "bash '${TMP}/perf-prompt.sh'" /dev/null 2>&1 | tr -d '\r')"
	if grep -q 'must be a whole number' <<<"${out}" && grep -qx 'PROXY_UPLOAD_LIMIT_MBIT=8' <<<"${out}"; then
		ok "an invalid interactive answer is explained and asked again"
	else
		bad "interactive validation: ${out}"
	fi
else
	printf 'SKIP  script(1) is required for the interactive tests\n'
fi

# --- 6. rendered config.env carries every setting ----------------------------
fresh_etc
out="$(run "install() { :; }
chown() { :; }
chmod() { :; }
REPO_DIR='${REPO}'
PUBLIC_HOST=relay.example.test
PUBLIC_IP=203.0.113.10
PROXY_PORT=443
API_PORT=8443
SQUID_BINARY=/usr/sbin/squid
ASSUME_YES=1
select_performance_settings
render_config_env" )"
rendered="${TMP}/etc/config.env"
if [[ -r "${rendered}" ]] &&
	grep -qx 'PROXY_DOWNLOAD_LIMIT_MBIT=8' "${rendered}" &&
	grep -qx 'PER_IP_BURST=30' "${rendered}" &&
	grep -qx 'TC_MAX_CLIENTS=512' "${rendered}" &&
	! grep -q '@[A-Z_]*@' "${rendered}"; then
	ok "a fresh install renders every limit into config.env with no placeholders left"
else
	bad "rendered config.env: $(grep -E 'LIMIT|BURST|TC_' "${rendered}" 2>/dev/null | tr '\n' ' ')"
fi

# --- 7. an upgrade adds the new keys without losing custom values ------------
cat >"${TMP}/etc/config.env" <<'EOF'
HTTPS_PROXY_URL=https://relay.example.test:443
NETWORK_CONFIG_PORT=8443
NETWORK_CONFIG_URL=https://relay.example.test:8443/network-config
HTTPS_LISTEN=:8443
TURN_URLS=turn:relay.example.test:3478?transport=udp
PER_IP_RATE_PER_MINUTE=12
PER_IP_BURST=9
EOF
out="$(run "install() { :; }
chown() { :; }
chmod() { :; }
REPO_DIR='${REPO}'
PUBLIC_HOST=relay.example.test
PUBLIC_IP=203.0.113.10
PROXY_PORT=443
API_PORT=8443
SQUID_BINARY=/usr/sbin/squid
ASSUME_YES=1
select_performance_settings
render_config_env" )"
if grep -qx 'PER_IP_RATE_PER_MINUTE=12' "${rendered}" &&
	grep -qx 'PER_IP_BURST=9' "${rendered}" &&
	grep -qx 'PROXY_UPLOAD_LIMIT_MBIT=8' "${rendered}" &&
	grep -qx 'TURN_UPLOAD_LIMIT_MBIT=16' "${rendered}" &&
	grep -qx 'GLOBAL_RATE_PER_MINUTE=1200' "${rendered}"; then
	ok "an upgrade keeps custom API limits and adds the new bandwidth settings"
else
	bad "upgrade config: $(grep -E 'PER_IP|LIMIT|GLOBAL' "${rendered}" | tr '\n' ' ')"
fi

# --- 8. traffic shaping: the generated rules --------------------------------
TC="${REPO}/deploy/scripts/dohcord-relay-tc"
cat >"${TMP}/tc.env" <<'EOF'
HTTPS_PROXY_URL=https://relay.example.test:443
PROXY_UPLOAD_LIMIT_MBIT=8
PROXY_DOWNLOAD_LIMIT_MBIT=8
TURN_UPLOAD_LIMIT_MBIT=16
TURN_DOWNLOAD_LIMIT_MBIT=16
TC_MAX_CLIENTS=512
TC_IDLE_SECONDS=60
TC_REFRESH_SECONDS=5
EOF
tc_render() { # [clients] [config]
	DOHCORD_RELAY_TC_STATE="${TMP}/tcstate" \
		DOHCORD_RELAY_TC_FAKE_CLIENTS="${1:-203.0.113.5}" \
		bash "${TC}" apply --dry-run --interface eth0 --config "${2:-${TMP}/tc.env}" 2>&1
}

out="$(tc_render)"
if grep -q 'tc qdisc replace dev eth0 root handle 1: htb default 999' <<<"${out}" &&
	grep -q 'ip link add dohcord-ifb type ifb' <<<"${out}" &&
	grep -q 'tc qdisc replace dev dohcord-ifb root handle 2: htb default 999' <<<"${out}"; then
	ok "shaping builds an HTB tree for download and an IFB tree for upload"
else
	bad "shaping roots: ${out}"
fi

if grep -q 'classid 1:.*htb rate 8mbit ceil 8mbit' <<<"${out}" &&
	grep -q 'classid .* htb rate 16mbit ceil 16mbit' <<<"${out}" &&
	[[ "$(grep -c 'htb rate 8mbit' <<<"${out}")" == "2" ]] &&
	[[ "$(grep -c 'htb rate 16mbit' <<<"${out}")" == "2" ]]; then
	ok "each client IP gets one proxy class (8 Mbps) and one TURN class (16 Mbps) per direction"
else
	bad "shaping class rates: ${out}"
fi

if grep -q 'filter add dev eth0 parent 1: protocol ip prio 1 u32 match ip dst 203.0.113.5/32 match ip sport 443 0xffff flowid 1:' <<<"${out}" &&
	grep -q 'filter add dev dohcord-ifb parent 2: protocol ip prio 1 u32 match ip src 203.0.113.5/32 match ip dport 443 0xffff flowid 2:' <<<"${out}"; then
	ok "proxy download and upload are classified by the client address and port 443"
else
	bad "proxy filters: ${out}"
fi

if grep -q 'match ip sport 3478 0xffff' <<<"${out}" &&
	grep -q 'match ip sport 5349 0xffff' <<<"${out}" &&
	grep -q 'match ip sport 0xc000 0xc000' <<<"${out}" &&
	grep -q 'match ip dport 0xc000 0xc000' <<<"${out}"; then
	ok "TURN upload/download covers 3478, 5349 and the whole relay port range"
else
	bad "turn filters: ${out}"
fi

if grep -q 'filter add dev eth0 parent ffff:.*mirror\|filter add dev eth0 parent ffff:.*redirect dev dohcord-ifb' <<<"${out}" &&
	grep -q 'match ip dport 3478 0xffff action mirred egress redirect dev dohcord-ifb' <<<"${out}" &&
	! grep -q 'match ip dport 22 ' <<<"${out}"; then
	ok "only relay traffic is mirrored for upload shaping; unrelated traffic is untouched"
else
	bad "ingress mirroring: ${out}"
fi

out="$(tc_render '2001:db8::7')"
if grep -q 'protocol ipv6' <<<"${out}" && grep -q 'match ip6 dst 2001:db8::7/128 match ip6 sport 443' <<<"${out}" &&
	grep -q 'match ip6 src 2001:db8::7/128 match ip6 dport 443' <<<"${out}"; then
	ok "IPv6 clients are shaped with their own filters"
else
	bad "ipv6 filtering: ${out}"
fi

sed -e 's/^PROXY_UPLOAD_LIMIT_MBIT=.*/PROXY_UPLOAD_LIMIT_MBIT=0/' \
	-e 's/^PROXY_DOWNLOAD_LIMIT_MBIT=.*/PROXY_DOWNLOAD_LIMIT_MBIT=0/' "${TMP}/tc.env" >"${TMP}/tc-noproxy.env"
out="$(tc_render 203.0.113.5 "${TMP}/tc-noproxy.env")"
if grep -q 'htb rate 16mbit' <<<"${out}" && ! grep -q 'htb rate 8mbit' <<<"${out}" &&
	! grep -q 'match ip sport 443' <<<"${out}"; then
	ok "setting a limit to 0 disables exactly that limit (proxy classes disappear, TURN stays)"
else
	bad "disabled proxy limit: ${out}"
fi

sed -e 's/^PROXY_UPLOAD_LIMIT_MBIT=.*/PROXY_UPLOAD_LIMIT_MBIT=0/' \
	-e 's/^PROXY_DOWNLOAD_LIMIT_MBIT=.*/PROXY_DOWNLOAD_LIMIT_MBIT=0/' \
	-e 's/^TURN_UPLOAD_LIMIT_MBIT=.*/TURN_UPLOAD_LIMIT_MBIT=0/' \
	-e 's/^TURN_DOWNLOAD_LIMIT_MBIT=.*/TURN_DOWNLOAD_LIMIT_MBIT=0/' "${TMP}/tc.env" >"${TMP}/tc-off.env"
out="$(tc_render 203.0.113.5 "${TMP}/tc-off.env")"
if grep -q 'qdisc del dev eth0 handle ffff: ingress' <<<"${out}" && ! grep -q 'htb rate' <<<"${out}"; then
	ok "all four limits at 0 removes the shaping rules instead of enforcing 0 Mbps"
else
	bad "disabled shaping: ${out}"
fi

# --- 9. traffic shaping: validation -----------------------------------------
for value in abc -1 100001 1.5; do
	sed -e "s/^PROXY_UPLOAD_LIMIT_MBIT=.*/PROXY_UPLOAD_LIMIT_MBIT=${value}/" "${TMP}/tc.env" >"${TMP}/tc-bad.env"
	if bash "${TC}" validate --config "${TMP}/tc-bad.env" >/dev/null 2>&1; then
		bad "the shaper accepted PROXY_UPLOAD_LIMIT_MBIT=${value}"
	else
		ok "the shaper rejects PROXY_UPLOAD_LIMIT_MBIT=${value}"
	fi
done

# --- 10. traffic shaping: state, pruning and bounds -------------------------
# A stale class (last seen a minute ago) must be removed on the next refresh.
mkdir -p "${TMP}/state-stale"
printf 'download proxy 5 198.51.100.9 1\n' >"${TMP}/state-stale/classes"
out="$(DOHCORD_RELAY_TC_STATE="${TMP}/state-stale" DOHCORD_RELAY_TC_FAKE_CLIENTS=203.0.113.5 \
	bash "${TC}" apply --dry-run --interface eth0 --config "${TMP}/tc.env" 2>&1)"
if grep -q 'tc class del dev eth0 classid 1:5' <<<"${out}"; then
	ok "an address with no traffic is removed from the shaper"
else
	bad "stale pruning: ${out}"
fi

# A capped table refuses to track more addresses than TC_MAX_CLIENTS.
sed -e 's/^TC_MAX_CLIENTS=.*/TC_MAX_CLIENTS=2/' "${TMP}/tc.env" >"${TMP}/tc-max.env"
out="$(DOHCORD_RELAY_TC_STATE="${TMP}/state-max" DOHCORD_RELAY_TC_FAKE_CLIENTS='203.0.113.1,203.0.113.2,203.0.113.3' \
	bash "${TC}" apply --dry-run --interface eth0 --config "${TMP}/tc-max.env" 2>&1)"
if grep -q '203.0.113.3 is not limited' <<<"${out}"; then
	ok "the class table is bounded: extra addresses are reported as not limited"
else
	bad "bounded table: ${out}"
fi

# --- 11. traffic shaping: status reporting ----------------------------------
out="$(bash "${TC}" status --interface eth0 --config "${TMP}/tc.env" 2>&1)"
rc=$?
if grep -q '^shaping=inactive' <<<"${out}" && ((rc != 0)); then
	ok "status reports that configured limits are not enforced"
else
	bad "status (inactive): rc=${rc} ${out}"
fi
if grep -q '^proxy_download_mbit=8' <<<"${out}" && grep -q '^turn_upload_mbit=16' <<<"${out}"; then
	ok "status lists the configured per-IP limits"
else
	bad "status limits: ${out}"
fi
out="$(bash "${TC}" status --interface eth0 --config "${TMP}/tc-off.env" 2>&1)"
if grep -q '^shaping=disabled' <<<"${out}"; then
	ok "status reports shaping as disabled when every limit is 0"
else
	bad "status (disabled): ${out}"
fi

# --- 12. manager console: limits validation ----------------------------------
sed -e "s|^ETC_DIR=.*|ETC_DIR=\"${TMP}/mgr\"|" -e '$d' \
	"${REPO}/deploy/scripts/dohcord-relay-manager.sh" >"${TMP}/manager-lib.sh"
mkdir -p "${TMP}/mgr"
cat >"${TMP}/mgr/config.env" <<'EOF'
PROXY_UPLOAD_LIMIT_MBIT=8
PROXY_DOWNLOAD_LIMIT_MBIT=8
TURN_UPLOAD_LIMIT_MBIT=16
TURN_DOWNLOAD_LIMIT_MBIT=16
PER_IP_RATE_PER_MINUTE=60
PER_IP_BURST=30
GLOBAL_RATE_PER_MINUTE=1200
GLOBAL_BURST=300
TC_MAX_CLIENTS=512
TC_REFRESH_SECONDS=5
EOF
printf 'client_ip_max_connections 100\nmax_filedescriptors 8192\n' >"${TMP}/mgr/squid.conf"
printf 'user-quota=12\ntotal-quota=1200\nmax-bps=2000000\nbps-capacity=250000000\n' >"${TMP}/mgr/turnserver.conf"

mgr_run() {
	bash -c "set -Eeuo pipefail
source '${TMP}/manager-lib.sh'
${1}" 2>&1
}

if mgr_run 'limits_validate' >/dev/null; then
	ok "the manager accepts a valid limits configuration"
else
	bad "manager rejected a valid limits configuration"
fi

sed -i 's/^total-quota=.*/total-quota=2/' "${TMP}/mgr/turnserver.conf"
if mgr_run 'limits_validate' >/dev/null; then
	bad "the manager accepted total-quota below user-quota"
else
	ok "the manager rejects TURN quotas that would break allocations"
fi
printf 'user-quota=12\ntotal-quota=1200\nmax-bps=2000000\nbps-capacity=250000000\n' >"${TMP}/mgr/turnserver.conf"

mgr_run 'limits_stage
limits_set_pending PROXY_DOWNLOAD_LIMIT_MBIT 0
printf "PENDING=%s\n" "$(limits_read PROXY_DOWNLOAD_LIMIT_MBIT)"' >"${TMP}/mgr-out"
if grep -qx 'PENDING=0' "${TMP}/mgr-out" && grep -qx 'PROXY_DOWNLOAD_LIMIT_MBIT=8' "${TMP}/mgr/config.env"; then
	ok "manager changes are staged and do not touch the live configuration until applied"
else
	bad "manager staging: $(cat "${TMP}/mgr-out")"
fi
mgr_run 'limits_stage; limits_discard'

if mgr_run 'usage' | grep -q 'limits *Limits and performance'; then
	ok "the manager help lists the limits section"
else
	bad "manager help"
fi

printf '\nNetwork and performance limit tests: %s\n' "$( ((fail == 0)) && echo 'passed' || echo 'FAILED' )"
exit "${fail}"
