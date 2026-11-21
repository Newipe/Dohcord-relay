#!/usr/bin/env bash
# Integration tests for the configurable per-client connection limit.
#
# Covers: the 100 default, --max-connections, the interactive prompt on a fresh
# install and on a re-run, reading the limit back from squid.conf, invalid
# values, and the chosen value actually reaching the rendered Squid
# configuration.
#
# Everything runs in a temporary directory, so no installation or root access is
# required.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dohcord-relay-conn-test.XXXXXX")"
trap 'rm -rf -- "${TMP}"' EXIT

fail=0
ok() { printf 'PASS  %s\n' "$*"; }
bad() {
	printf 'FAIL  %s\n' "$*"
	fail=1
}

# Installer function library: the real script with ETC_DIR pointed at the
# fixture and the final main call dropped.
sed -e "s|readonly ETC_DIR=\"/etc/dohcord-relay\"|readonly ETC_DIR=\"${TMP}/etc\"|" \
	-e '$d' "${REPO}/deploy/install.sh" >"${TMP}/install-lib.sh"
mkdir -p "${TMP}/etc"

printf '#!/bin/sh\necho "Squid Cache: Version 6.14 --with-openssl"\n' >"${TMP}/fake-squid"
chmod +x "${TMP}/fake-squid"

# run executes SNIPPET with the installer functions sourced.
run() {
	bash -c "set -Eeuo pipefail
source '${TMP}/install-lib.sh'
${1}" 2>&1
}

# --- fresh install: non-interactive default -----------------------------------
out="$(run 'ASSUME_YES=1
select_max_connections
printf "LIMIT=%s\n" "${MAX_CONN_PER_IP}"')"
if grep -q '^LIMIT=100$' <<<"${out}" && grep -q 'default' <<<"${out}"; then
	ok "fresh non-interactive install defaults to 100"
else
	bad "fresh default: ${out}"
fi

# --- the chosen value reaches squid.conf --------------------------------------
out="$(run "chown() { :; }
chmod() { :; }
REPO_DIR='${REPO}'
SQUID_BINARY='${TMP}/fake-squid'
MAX_CONN_PER_IP=250
render_squid_conf")" || bad "render_squid_conf failed: ${out}"
if grep -q '^client_ip_max_connections 250$' "${TMP}/etc/squid.conf"; then
	ok "the selected limit is rendered into squid.conf"
else
	bad "squid.conf limit: $(grep client_ip_max_connections "${TMP}/etc/squid.conf")"
fi

# --- re-run: the recorded limit is kept ---------------------------------------
out="$(run 'select_max_connections
printf "LIMIT=%s\n" "${MAX_CONN_PER_IP}"')"
if grep -q '^LIMIT=250$' <<<"${out}" && grep -q 'keeping it' <<<"${out}"; then
	ok "a re-run keeps the limit recorded in squid.conf"
else
	bad "re-run keep: ${out}"
fi

# --- re-run: the prompt shows the recorded limit and can change it -------------
if command -v script >/dev/null 2>&1; then
	cat >"${TMP}/prompt.sh" <<EOF
set -Eeuo pipefail
source "${TMP}/install-lib.sh"
select_max_connections
printf 'LIMIT=%s\n' "\${MAX_CONN_PER_IP}"
EOF
	out="$(printf '\n' | script -qec "bash '${TMP}/prompt.sh'" /dev/null 2>&1 | tr -d '\r')"
	if grep -q '^LIMIT=250$' <<<"${out}" &&
		grep -q 'Concurrent connections per client \[250\]' <<<"${out}"; then
		ok "interactive re-run asks for the limit, keeping the configured one on Enter"
	else
		bad "interactive prompt (keep): ${out}"
	fi
	out="$(printf '400\n' | script -qec "bash '${TMP}/prompt.sh'" /dev/null 2>&1 | tr -d '\r')"
	if grep -q '^LIMIT=400$' <<<"${out}" &&
		grep -q 'may hold 400 concurrent proxy connections' <<<"${out}"; then
		ok "interactive re-run can raise the limit"
	else
		bad "interactive prompt (change): ${out}"
	fi
	out="$(printf 'nope\n400\n' | script -qec "bash '${TMP}/prompt.sh'" /dev/null 2>&1 | tr -d '\r')"
	if grep -q '^LIMIT=400$' <<<"${out}" && grep -q 'is not a whole number' <<<"${out}"; then
		ok "interactive prompt rejects a non-numeric answer and asks again"
	else
		bad "interactive prompt (invalid then valid): ${out}"
	fi
else
	printf 'SKIP  script(1) is required for the interactive prompt tests\n'
fi

# --- explicit --max-connections changes an existing installation --------------
printf 'client_ip_max_connections 250\nmax_filedescriptors 8192\n' >"${TMP}/etc/squid.conf"
out="$(run 'MAX_CONN_PER_IP=150
MAX_CONN_PER_IP_EXPLICIT=1
select_max_connections
printf "LIMIT=%s\n" "${MAX_CONN_PER_IP}"')"
if grep -q '^LIMIT=150$' <<<"${out}" && grep -q 'from 250 to 150' <<<"${out}"; then
	ok "explicit --max-connections changes an existing installation"
else
	bad "explicit change: ${out}"
fi

# --- invalid explicit values are rejected ------------------------------------
for v in 0 abc -5 12.5 9999999; do
	if run "MAX_CONN_PER_IP='${v}'
MAX_CONN_PER_IP_EXPLICIT=1
select_max_connections" >/dev/null; then
		bad "installer accepted --max-connections ${v}"
	else
		ok "installer rejects --max-connections ${v}"
	fi
done

printf '\nPer-client connection limit tests: %s\n' "$( ((fail == 0)) && echo 'passed' || echo 'FAILED' )"
exit "${fail}"
