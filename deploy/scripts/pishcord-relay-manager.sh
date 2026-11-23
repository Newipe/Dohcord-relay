#!/usr/bin/env bash
# Pishcord-relay management console.
#
# Installed as /usr/local/lib/pishcord-relay/manager.sh and started by the
# pishcord-relay binary, the command users run. /usr/local/bin/pishcord-relay-manager
# remains as a compatibility alias for the previous name. It is a front-end for
# the components that already exist: the systemd units, the pishcord-relayd daemon
# and its -policy-apply/-policy-check commands, certbot, and verify.sh (installed
# at /usr/local/lib/pishcord-relay/verify.sh).
#
# It never re-implements networking logic and never edits Squid or coturn
# configuration itself: policy changes go through the binary, which validates
# the whole Squid configuration before anything is reloaded.
set -Eeuo pipefail

MANAGER_VERSION="1.0.0"

# --- Paths (overridable for testing) ---------------------------------------
ETC_DIR="${PISHCORD_RELAY_ETC_DIR:-/etc/pishcord-relay}"
TLS_DIR="${ETC_DIR}/tls"
CONFIG_FILE="${ETC_DIR}/config.env"
INFO_FILE="${ETC_DIR}/install-info"
DOMAINS_FILE="${ETC_DIR}/allowed-domains.txt"
POLICY_FILE="${ETC_DIR}/destination-policy.conf"
ALLOW_FILE="${ETC_DIR}/squid-allow.conf"
SQUID_CONF="${ETC_DIR}/squid.conf"
TURNSERVER_CONF="${ETC_DIR}/turnserver.conf"
LOG_DIR="/var/log/pishcord-relay"
LIB_DIR="${PISHCORD_RELAY_LIB_DIR:-/usr/local/lib/pishcord-relay}"
BIN="${PISHCORD_RELAY_BIN:-/usr/local/bin/pishcord-relayd}"
CONSOLE_BIN="${PISHCORD_RELAY_CONSOLE_BIN:-/usr/local/bin/pishcord-relay}"
# The name shown in help and errors. The binary is called pishcord-relay; the
# previous pishcord-relay-manager name stays valid as an alias.
PROGRAM="${PISHCORD_RELAY_PROGRAM:-pishcord-relay}"
HOOK="/usr/local/bin/pishcord-relay-tls-deploy"
CERTBOT="/opt/pishcord-relay-certbot/bin/certbot"
CERT_NAME="pishcord-relay"

API_UNIT="pishcord-relay-api.service"
SQUID_UNIT="pishcord-relay-squid.service"
COTURN_UNIT="pishcord-relay-coturn.service"
RENEW_TIMER="pishcord-relay-certbot-renew.timer"
UNITS=("${API_UNIT}" "${SQUID_UNIT}" "${COTURN_UNIT}")
REPO_SLUG="Newipe/Pishcord-relay"
TC_SCRIPT="${PISHCORD_RELAY_TC:-${LIB_DIR}/pishcord-relay-tc}"
SQUID_BIN="${PISHCORD_RELAY_SQUID_BIN:-/usr/sbin/squid}"
LIMITS_PENDING="${ETC_DIR}/pending"
LIMITS_BACKUP_ROOT="${PISHCORD_RELAY_BACKUP_DIR:-/var/backups/pishcord-relay}"
readonly LIMIT_KEYS=(PROXY_UPLOAD_LIMIT_MBIT PROXY_DOWNLOAD_LIMIT_MBIT TURN_UPLOAD_LIMIT_MBIT TURN_DOWNLOAD_LIMIT_MBIT PER_IP_RATE_PER_MINUTE PER_IP_BURST GLOBAL_RATE_PER_MINUTE GLOBAL_BURST TC_MAX_CLIENTS TC_REFRESH_SECONDS)
LAST_POLICY_BACKUP=""

# --- Output -----------------------------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
	C_RESET=$'\033[0m' C_BOLD=$'\033[1m' C_DIM=$'\033[2m'
	C_CYAN=$'\033[36m' C_GREEN=$'\033[32m' C_RED=$'\033[31m' C_YELLOW=$'\033[33m'
else
	C_RESET="" C_BOLD="" C_DIM="" C_CYAN="" C_GREEN="" C_RED="" C_YELLOW=""
fi

say() { printf '%s\n' "$*"; }
info() { printf '  %s\n' "$*"; }
dim() { printf '  %s%s%s\n' "${C_DIM}" "$*" "${C_RESET}"; }
ok() { printf '  %s✓%s %s\n' "${C_GREEN}" "${C_RESET}" "$*"; }
warn() { printf '  %s!%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
bad() { printf '  %s✗%s %s\n' "${C_RED}" "${C_RESET}" "$*" >&2; }
die() {
	printf '\n  %s✗ %s%s\n\n' "${C_RED}" "$*" "${C_RESET}" >&2
	exit 1
}

hr() { printf '  %s\n' "────────────────────────────────────────────────────────"; }
heading() {
	say ""
	printf '  %s%s%s\n' "${C_BOLD}${C_CYAN}" "$*" "${C_RESET}"
	hr
}

need_root() {
	[[ ${EUID} -eq 0 ]] || die "this action changes the system; run it with sudo"
}

have() { command -v "$1" >/dev/null 2>&1; }

unit_exists() { systemctl cat "$1" >/dev/null 2>&1; }

unit_state() { # unit_state UNIT -> active|inactive|failed|unknown
	local u="$1"
	if ! unit_exists "${u}"; then
		printf 'unknown'
		return
	fi
	systemctl is-active "${u}" 2>/dev/null || true
}

unit_short() { # unit_short UNIT -> api|squid|coturn|timer
	local s="${1#pishcord-relay-}"
	printf '%s' "${s%.service}"
}

state_glyph() { # state_glyph STATE -> coloured short status
	case "$1" in
	active) printf '%s● running%s' "${C_GREEN}" "${C_RESET}" ;;
	failed) printf '%s● failed%s' "${C_RED}" "${C_RESET}" ;;
	inactive) printf '%s● stopped%s' "${C_YELLOW}" "${C_RESET}" ;;
	*) printf '%s● not installed%s' "${C_DIM}" "${C_RESET}" ;;
	esac
}

# config_value KEY prints a value from config.env without sourcing it, so a
# value containing shell metacharacters can never execute.
config_value() {
	[[ -r "${CONFIG_FILE}" ]] || return 0
	local line
	line="$(grep -m1 -E "^$1=" "${CONFIG_FILE}" 2>/dev/null || true)"
	printf '%s' "${line#*=}"
}

info_value() {
	[[ -r "${INFO_FILE}" ]] || return 0
	local line
	line="$(grep -m1 -E "^$1=" "${INFO_FILE}" 2>/dev/null || true)"
	printf '%s' "${line#*=}"
}

proxy_url() { config_value HTTPS_PROXY_URL; }
api_url() { config_value NETWORK_CONFIG_URL; }
turn_urls() { config_value TURN_URLS; }

installed() { [[ -x "${BIN}" && -r "${CONFIG_FILE}" ]]; }

require_install() {
	installed || die "Pishcord-relay is not installed on this server (missing ${BIN} or ${CONFIG_FILE})"
}

confirm() { # confirm PROMPT [default-yes]
	local prompt="$1" default="${2:-no}" answer
	[[ -t 0 ]] || return 1
	if [[ "${default}" == "yes" ]]; then
		printf '  %s [Y/n]: ' "${prompt}"
	else
		printf '  %s [y/N]: ' "${prompt}"
	fi
	read -r answer
	case "${answer}" in
	"") [[ "${default}" == "yes" ]] ;;
	y | Y | yes | YES) return 0 ;;
	*) return 1 ;;
	esac
}

pause() {
	[[ -t 0 ]] || return 0
	printf '\n  Press Enter to return to the menu... '
	read -r _
}

cert_field() { # cert_field <openssl option>
	openssl x509 -in "${TLS_DIR}/fullchain.pem" -noout "$@" 2>/dev/null || true
}

cert_days_left() {
	[[ -r "${TLS_DIR}/fullchain.pem" ]] || return 1
	local end epoch now
	end="$(openssl x509 -in "${TLS_DIR}/fullchain.pem" -noout -enddate 2>/dev/null | cut -d= -f2)"
	[[ -n "${end}" ]] || return 1
	epoch="$(date -d "${end}" +%s 2>/dev/null)" || return 1
	now="$(date +%s)"
	printf '%s' $(((epoch - now) / 86400))
}

url_port() { # url_port PROXY|API -> the port in that URL, defaulting sensibly
	local url default hostport port
	if [[ "$1" == "API" ]]; then
		url="$(api_url)"
		default="$(config_value NETWORK_CONFIG_PORT)"
		[[ "${default}" =~ ^[0-9]+$ ]] || default=""
		default="${default:-8443}"
	else
		url="$(proxy_url)"
		default="${PROXY_PORT:-443}"
	fi
	hostport="${url#*://}"
	hostport="${hostport%%/*}"
	port="${hostport##*:}"
	if [[ "${hostport}" == *:* && "${port}" =~ ^[0-9]+$ ]]; then
		printf '%s' "${port}"
	else
		printf '%s' "${default}"
	fi
}

# api_port prints the authoritative Network Configuration API port: the
# configured NETWORK_CONFIG_PORT, or the port in NETWORK_CONFIG_URL for
# configurations written by older releases, or 8443.
api_port() { url_port API; }

# api_listen_addr prints the address the endpoint binds, with a sensible
# fallback for a configuration that predates the setting.
api_listen_addr() {
	local addr
	addr="$(config_value HTTPS_LISTEN)"
	if [[ -z "${addr}" ]]; then
		printf ':%s' "$(api_port)"
	else
		printf '%s' "${addr}"
	fi
}

port_listening() { ss -Hltn "( sport = :$1 )" 2>/dev/null | grep -q .; }

port_free() { # succeeds when this host could bind the TCP port
	have python3 || return 1
	python3 - "$1" <<'PY' 2>/dev/null
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
}

# api_port_conflict prints why PORT cannot be used by the API and returns 0.
# It returns 1 with no output when the port is usable.
api_port_conflict() {
	local port="$1" owner
	if [[ ! "${port}" =~ ^[0-9]+$ ]]; then
		printf '%s is not a number' "${port}"
		return 0
	fi
	port=$((10#${port}))
	if ((port < 1024 || port > 65535)); then
		printf '%d is outside the usable range 1024-65535 (ports below 1024 are reserved for system services)' "${port}"
		return 0
	fi
	case "${port}" in
	80) printf '80 is used for ACME HTTP-01 certificate validation'; return 0 ;;
	443) printf '443 is used by the HTTPS CONNECT proxy'; return 0 ;;
	3478) printf '3478 is used by the TURN relay'; return 0 ;;
	5349) printf '5349 is used by TURN over TLS'; return 0 ;;
	esac
	if port_listening "${port}"; then
		owner="$(ss -Hltnp "( sport = :${port} )" 2>/dev/null | sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | head -1)"
		[[ "${owner}" == *pishcord-relay* ]] && return 1
		printf 'port %d is already in use%s' "${port}" "${owner:+ by ${owner}}"
		return 0
	fi
	return 1
}

# --- Dashboard --------------------------------------------------------------
dashboard() {
	local state days host mode version release
	heading "Dashboard"

	# Installation
	if installed; then
		version="$(info_value INSTALLER_VERSION)"
		release="$(info_value RELEASE_VERSION)"
		local installed_at label
		installed_at="$(info_value INSTALLED_AT)"
		if [[ -n "${release}" && "${release}" != "unknown" ]]; then
			label="release ${release} (installer ${version:-unknown}) installed ${installed_at}"
		elif [[ -n "${version}" ]]; then
			label="v${version} installed ${installed_at}"
		else
			label="present"
		fi
		printf '  %-22s %s\n' "Installation" "${label}"
	else
		printf '  %-22s %snot installed%s\n' "Installation" "${C_RED}" "${C_RESET}"
		printf '\n  Run the one-line installer from the README, or `%s repair`.\n' "${PROGRAM}"
		return 0
	fi

	mode="$(info_value MODE)"
	host="$(info_value PUBLIC_HOST)"
	[[ -n "${host}" ]] || host="$(config_value HTTPS_PROXY_URL | sed -E 's#^https?://##; s#:[0-9]+$##')"
	printf '  %-22s %s\n' "Mode" "${mode:-unknown}"
	printf '  %-22s %s\n' "Public address" "${host:-unknown}"

	say ""
	printf '  %-22s ' "Services"
	local first=1 u
	for u in "${UNITS[@]}"; do
		state="$(unit_state "${u}")"
		((first)) || printf '   '
		first=0
		printf '%s %s' "$(state_glyph "${state}")" "$(unit_short "${u}")"
	done
	printf '\n'
	printf '  %-22s %s %s\n' "Renewal timer" "$(state_glyph "$(unit_state "${RENEW_TIMER}")")" "${RENEW_TIMER}"

	# Certificate
	say ""
	if [[ -r "${TLS_DIR}/fullchain.pem" ]]; then
		days="$(cert_days_left || echo "?")"
		printf '  %-22s %s\n' "Certificate" "$(cert_field -subject | sed 's/^subject=//')"
		printf '  %-22s %s\n' "Issuer" "$(cert_field -issuer | sed 's/^issuer=//')"
		printf '  %-22s %s\n' "Expires" "$(cert_field -enddate | cut -d= -f2) (${days} days)"
	else
		printf '  %-22s %smissing%s\n' "Certificate" "${C_RED}" "${C_RESET}"
	fi

	# Network endpoints
	say ""
	printf '  %-22s %s\n' "HTTPS proxy" "$(proxy_url)"
	printf '  %-22s %s\n' "Network config" "$(api_url)"
	printf '  %-22s %s\n' "Network config port" "$(api_port)"
	local turn
	turn="$(turn_urls)"
	printf '  %-22s %s\n' "TURN" "${turn:-unknown}"

	# Listeners
	say ""
	printf '  %-22s ' "Listening"
	local ports="" p
	for p in "$(url_port PROXY)" "$(url_port API)" 3478 5349; do
		if ss -Hltn "( sport = :${p} )" 2>/dev/null | grep -q . || ss -Hlun "( sport = :${p} )" 2>/dev/null | grep -q .; then
			ports+="${p} "
		fi
	done
	printf '%s\n' "${ports:-none found}"
	printf '  %-22s %s\n' "Open tunnels" "$(active_tunnels)"

	# Resources
	say ""
	printf '  %-22s %s\n' "Load (1m/5m/15m)" "$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo n/a)"
	printf '  %-22s %s\n' "Memory" "$(free -h 2>/dev/null | awk '/^Mem:/{printf "%s used of %s", $3, $2}' || echo n/a)"
	printf '  %-22s %s\n' "Disk (/)" "$(df -h / 2>/dev/null | awk 'NR==2{printf "%s used of %s (%s)", $3, $2, $5}' || echo n/a)"
	printf '  %-22s %s\n' "Policy" "$(policy_sentence)"
}

active_tunnels() {
	# Established TCP connections on the proxy port, excluding the local test
	# connections the API itself makes.
	local n
	n="$(ss -Htn state established "( sport = :443 )" 2>/dev/null | wc -l | tr -d ' ')" || n=""
	if [[ -z "${n}" ]]; then
		printf 'n/a'
	elif [[ "${n}" == "0" ]]; then
		printf 'none right now'
	else
		printf '%s' "${n}"
	fi
}

policy_sentence() {
	[[ -r "${DOMAINS_FILE}" && -r "${POLICY_FILE}" ]] || {
		printf 'policy files missing'
		return
	}
	local domains
	domains="$(grep -vcE '^\s*(#|$)' "${DOMAINS_FILE}" 2>/dev/null || echo 0)"
	printf '%s destinations, applied %s' "${domains}" \
		"$( [[ -r "${ALLOW_FILE}" ]] && stat -c '%y' "${ALLOW_FILE}" 2>/dev/null | cut -d. -f1 || echo 'never' )"
}

# --- Services ---------------------------------------------------------------
service_status() {
	local u
	for u in "${UNITS[@]}" "${RENEW_TIMER}"; do
		local state desc
		state="$(unit_state "${u}")"
		desc="$(systemctl show -p Description --value "${u}" 2>/dev/null || true)"
		if ! unit_exists "${u}"; then
			printf '  %-28s %s\n' "${u}" "not installed"
			continue
		fi
		printf '  %-28s %-18s %s\n' "${u}" "$(state_glyph "${state}")" "${desc}"
	done
	if [[ "$(unit_state "${RENEW_TIMER}")" == "active" ]]; then
		printf '\n  Next renewal check: %s\n' "$(systemctl list-timers --all "${RENEW_TIMER}" --no-pager 2>/dev/null | awk 'NR==2{print $1, $2, $3}')"
	fi
}

choose_unit() {
	local i=1 u
	say ""
	for u in "${UNITS[@]}"; do
		printf '  %d. %-28s %s\n' "${i}" "${u}" "$(state_glyph "$(unit_state "${u}")")"
		i=$((i + 1))
	done
	printf '  0. Back\n\n  Select a service: '
	local choice
	read -r choice
	[[ "${choice}" == "0" ]] && return 1
	[[ "${choice}" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#UNITS[@]})) || {
		warn "invalid selection"
		return 1
	}
	printf '%s' "${UNITS[$((choice - 1))]}"
}

service_action() { # service_action UNIT ACTION
	local u="$1" action="$2"
	need_root
	require_install
	unit_exists "${u}" || die "${u} is not installed"
	case "${action}" in
	status)
		systemctl status "${u}" --no-pager -l 2>&1 | sed 's/^/  /'
		;;
	start | stop | restart | reload)
		say ""
		if systemctl "${action}" "${u}"; then
			sleep 1
			ok "${action} ${u}: $(unit_state "${u}")"
		else
			bad "${action} ${u} failed"
			journalctl -u "${u}" -n 20 --no-pager 2>/dev/null | sed 's/^/  /' || true
			return 1
		fi
		;;
	logs)
		journalctl -u "${u}" -n 60 --no-pager 2>/dev/null | sed 's/^/  /'
		;;
	follow)
		say "  Following ${u}. Press Ctrl+C to stop."
		journalctl -u "${u}" -f -n 20
		;;
	validate)
		validate_unit "${u}"
		;;
	*)
		die "unknown action ${action}"
		;;
	esac
}

validate_unit() {
	local u="$1"
	say ""
	dim "systemd-analyze verify ${u}"
	if systemd-analyze verify "${u}" 2>&1 | sed 's/^/  /'; then
		ok "${u} is a valid unit"
	fi
	case "${u}" in
	"${SQUID_UNIT}")
		if [[ -n "${SQUID_BINARY_PATH:-}" ]]; then
			dim "squid -k parse"
			"${SQUID_BINARY_PATH}" -k parse -f "${SQUID_CONF}" >/dev/null 2>&1 &&
				ok "Squid accepts ${SQUID_CONF}" || bad "Squid rejects ${SQUID_CONF}"
		fi
		;;
	esac
}

service_menu() {
	heading "Service management"
	service_status
	local u
	if ! u="$(choose_unit)"; then
		return 0
	fi
	say ""
	printf '  1. status    2. start    3. stop    4. restart\n'
	printf '  5. reload    6. logs     7. follow  8. validate\n  0. Back\n\n  Action: '
	local action
	read -r action
	case "${action}" in
	1) service_action "${u}" status ;;
	2) service_action "${u}" start ;;
	3) service_action "${u}" stop ;;
	4) service_action "${u}" restart ;;
	5) service_action "${u}" reload ;;
	6) service_action "${u}" logs ;;
	7) service_action "${u}" follow ;;
	8) service_action "${u}" validate ;;
	*) return 0 ;;
	esac
}

# --- Network configuration --------------------------------------------------
network_info() {
	heading "Network configuration"
	if ! installed; then
		warn "Pishcord-relay is not installed yet"
		return 0
	fi
	printf '  %-24s %s\n' "Mode" "$(info_value MODE)"
	printf '  %-24s %s\n' "Public host" "$(info_value PUBLIC_HOST)"
	printf '  %-24s %s\n' "Public IPv4" "$(info_value PUBLIC_IP)"
	say ""
	printf '  %-24s %s\n' "HTTPS CONNECT proxy" "$(proxy_url)"
	printf '  %-24s %s\n' "Network config URL" "$(api_url)"
	printf '  %-24s %s\n' "Network config port" "$(api_port)"
	printf '  %-24s %s\n' "API listen address" "$(api_listen_addr)"
	local turn
	turn="$(turn_urls)"
	printf '  %-24s %s\n' "TURN endpoints" "${turn%%,*}"
	[[ "${turn}" == *,* ]] && printf '  %-24s %s\n' "" "${turn#*,}"
	say ""
	printf '  %-24s %s\n' "Squid config" "${SQUID_CONF}"
	printf '  %-24s %s\n' "Policy files" "${DOMAINS_FILE}, ${POLICY_FILE}"
	printf '  %-24s %s\n' "Generated ACLs" "${ALLOW_FILE}"
	printf '  %-24s %s\n' "TURN config" "${TURNSERVER_CONF}"
	printf '  %-24s %s\n' "TLS certificate" "${TLS_DIR}/fullchain.pem"
	say ""
	printf '  %-24s %s\n' "Policy valid" "$(policy_valid_sentence)"
	printf '  %-24s %s\n' "Certificate covers host" "$(cert_covers_sentence)"
	say ""
	dim "Document returned to clients:"
	if curl -fsS --max-time 5 "$(api_url)" 2>/dev/null | head -c 400 | sed 's/^/  /'; then
		say ""
	else
		warn "the configuration endpoint did not answer (is ${API_UNIT} running?)"
	fi
}

policy_valid_sentence() {
	if [[ ! -x "${BIN}" ]]; then
		printf 'cannot check (binary missing)'
		return
	fi
	if "${BIN}" -config "${CONFIG_FILE}" -policy-check >/dev/null 2>&1; then
		printf '%syes%s' "${C_GREEN}" "${C_RESET}"
	else
		printf '%sno — run Domain policy → Validate%s' "${C_RED}" "${C_RESET}"
	fi
}

cert_covers_sentence() {
	local host check
	host="$(info_value PUBLIC_HOST)"
	[[ -n "${host}" && -r "${TLS_DIR}/fullchain.pem" ]] || {
		printf 'unknown'
		return
	}
	if [[ "${host}" =~ ^[0-9.]+$ ]]; then
		check=(openssl x509 -in "${TLS_DIR}/fullchain.pem" -noout -checkip "${host}")
	else
		check=(openssl x509 -in "${TLS_DIR}/fullchain.pem" -noout -checkhost "${host}")
	fi
	if "${check[@]}" >/dev/null 2>&1; then
		printf '%syes%s' "${C_GREEN}" "${C_RESET}"
	else
		printf '%sno%s' "${C_RED}" "${C_RESET}"
	fi
}

# --- Domain policy ----------------------------------------------------------
policy_show() {
	heading "Domain policy"
	if [[ ! -r "${DOMAINS_FILE}" || ! -r "${POLICY_FILE}" ]]; then
		warn "policy files are missing: ${DOMAINS_FILE} and ${POLICY_FILE}"
		return 0
	fi
	printf '  %-58s %-8s %s\n' "HOST" "MATCH" "PORTS"
	hr
	local host ports match entry
	while IFS= read -r entry; do
		[[ "${entry}" =~ ^[[:space:]]*(#|$) ]] && continue
		entry="${entry%%#*}"
		entry="${entry//[[:space:]]/}"
		[[ -n "${entry}" ]] || continue
		if [[ "${entry}" == =* ]]; then
			match="exact"
			host="${entry#=}"
		else
			match="suffix"
			host="${entry}"
		fi
		ports="$(awk -v h="${entry}" '$1 == h { $1=""; sub(/^ +/, ""); print }' "${POLICY_FILE}" 2>/dev/null)"
		printf '  %-58s %-8s %s\n' "${host}" "${match}" "${ports:-<missing>}"
	done <"${DOMAINS_FILE}"
	hr
	say "  exact  = that host name only"
	say "  suffix = that host and its subdomains, on DNS label boundaries"
	say ""
	printf '  Squid ACLs written %s\n' "$( [[ -r "${ALLOW_FILE}" ]] && stat -c '%y' "${ALLOW_FILE}" || echo 'never' )"
}

policy_add() {
	need_root
	require_install
	[[ -t 0 ]] || die "adding a domain is interactive; run ${PROGRAM} policy add in a terminal"

	heading "Add a destination"
	say "  A destination is a host name plus the TCP ports clients may reach."
	say "  Use exact matching for hosts where a subdomain would belong to someone else."
	say ""
	printf '  Host name (for example cdn.example.com): '
	local host
	read -r host
	host="${host,,}"
	host="${host%.}"
	[[ "${host}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] ||
		die "'${host}' is not a valid host name"
	[[ "${host}" != "="* ]] || die "do not type '='; choose the match type below"

	say ""
	printf '  Matching: 1. exact (this host only)  2. suffix (host and subdomains) [2]: '
	local pick type="suffix"
	read -r pick
	[[ "${pick}" == "1" ]] && type="exact"

	printf '  Ports (comma separated, for example 443 or 443,1024-65535) [443]: '
	local ports
	read -r ports
	ports="${ports:-443}"
	ports="${ports// /}"

	if ! validate_ports "${ports}"; then
		die "invalid port list '${ports}': use 1-65535, and ranges as LOW-HIGH with LOW <= HIGH"
	fi

	local entry="${host}"
	[[ "${type}" == "exact" ]] && entry="=${host}"

	if grep -qE "^[[:space:]]*=?$host([[:space:]]|$)" "${DOMAINS_FILE}" 2>/dev/null ||
		grep -qE "^=?${host}([[:space:]]|$)" "${POLICY_FILE}" 2>/dev/null; then
		die "${host} is already in the policy; remove it first to change its ports"
	fi

	say ""
	info "will add: ${entry} with ports ${ports} (${type} matching)"
	confirm "Write the policy files?" || die "cancelled; nothing was changed"

	backup_policy_files
	printf '%s  %s\n' "${entry}" "${ports}" >>"${POLICY_FILE}"
	printf '%s\n' "${entry}" >>"${DOMAINS_FILE}"

	if ! "${BIN}" -config "${CONFIG_FILE}" -policy-check >/dev/null 2>&1; then
		restore_policy_files
		die "the new policy was rejected by the validator; the previous policy is back in place"
	fi
	ok "policy files updated and validated"

	if confirm "Apply it now (rewrites the Squid ACLs and reloads Squid)?" yes; then
		policy_apply
	else
		info "not applied yet: run Domain policy → Apply when ready"
	fi
}

validate_ports() {
	local spec="$1" item lo hi
	[[ -n "${spec}" ]] || return 1
	IFS=',' read -ra items <<<"${spec}"
	for item in "${items[@]}"; do
		if [[ "${item}" =~ ^([0-9]+)-([0-9]+)$ ]]; then
			lo="${BASH_REMATCH[1]}"
			hi="${BASH_REMATCH[2]}"
			((lo >= 1 && lo <= 65535 && hi >= 1 && hi <= 65535 && lo <= hi)) || return 1
		elif [[ "${item}" =~ ^[0-9]+$ ]]; then
			((item >= 1 && item <= 65535)) || return 1
		else
			return 1
		fi
	done
	return 0
}

policy_backup_dir() { printf '%s' "${POLICY_BACKUP_DIR:-/var/backups/pishcord-relay}"; }

backup_policy_files() {
	local dir
	dir="$(policy_backup_dir)"
	mkdir -p "${dir}"
	chmod 0700 "${dir}"
	local stamp
	stamp="$(date +%Y%m%d-%H%M%S)"
	cp -a "${DOMAINS_FILE}" "${dir}/allowed-domains.txt.${stamp}"
	cp -a "${POLICY_FILE}" "${dir}/destination-policy.conf.${stamp}"
	LAST_POLICY_BACKUP="${stamp}"
	dim "backup: ${dir}/*.${stamp}"
}

restore_policy_files() {
	local dir stamp
	dir="$(policy_backup_dir)"
	stamp="${LAST_POLICY_BACKUP:-}"
	if [[ -n "${stamp}" && -r "${dir}/allowed-domains.txt.${stamp}" ]]; then
		cp -a "${dir}/allowed-domains.txt.${stamp}" "${DOMAINS_FILE}"
		cp -a "${dir}/destination-policy.conf.${stamp}" "${POLICY_FILE}"
		warn "restored the previous policy files"
	else
		warn "no backup to restore; fix the files by hand and run domain policy → validate"
	fi
}

policy_remove() {
	need_root
	require_install
	[[ -t 0 ]] || die "removing a domain is interactive"

	local -a entries=()
	local line
	while IFS= read -r line; do
		[[ "${line}" =~ ^[[:space:]]*(#|$) ]] && continue
		line="${line%%#*}"
		line="${line//[[:space:]]/}"
		[[ -n "${line}" ]] && entries+=("${line}")
	done <"${DOMAINS_FILE}"

	(( ${#entries[@]} > 0 )) || die "the policy is empty"

	heading "Remove a destination"
	local i
	for i in "${!entries[@]}"; do
		printf '  %2d. %s\n' "$((i + 1))" "${entries[$i]#=}"
	done
	printf '   0. Back\n\n  Select a destination: '
	local choice
	read -r choice
	[[ "${choice}" == "0" ]] && return 0
	[[ "${choice}" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#entries[@]})) || die "invalid selection"
	local target="${entries[$((choice - 1))]}"

	say ""
	info "will remove ${target#=} from the allowlist and its port policy"
	confirm "Remove it?" || die "cancelled; nothing was changed"
	[[ ${#entries[@]} -gt 1 ]] || die "that is the last destination; removing it would deny everything"

	backup_policy_files
	local tmp
	tmp="$(mktemp)"
	# Keep comments and blank lines; drop just the selected entry.
	awk -v t="${target}" '{
		line=$0; sub(/#.*/, "", line); gsub(/[[:space:]]/, "", line)
		if (line == t) next
		print $0
	}' "${DOMAINS_FILE}" >"${tmp}" && cat "${tmp}" >"${DOMAINS_FILE}"
	awk -v t="${target}" '{
		if ($1 == t) next
		print $0
	}' "${POLICY_FILE}" >"${tmp}" && cat "${tmp}" >"${POLICY_FILE}"
	rm -f "${tmp}"

	if ! "${BIN}" -config "${CONFIG_FILE}" -policy-check >/dev/null 2>&1; then
		restore_policy_files
		die "the edited policy was rejected; the previous policy is back in place"
	fi
	ok "removed ${target#=} and validated the policy"
	if confirm "Apply it now?" yes; then
		policy_apply
	fi
}

policy_check() {
	heading "Validate the destination policy"
	require_install
	local out rc=0
	out="$("${BIN}" -config "${CONFIG_FILE}" -policy-check 2>&1)" || rc=$?
	if [[ ${rc} -eq 0 ]]; then
		printf '%s\n' "${out}" | sed 's/^/  /'
		ok "policy is valid"
	else
		printf '%s\n' "${out}" | sed 's/^/  /'
		bad "policy is invalid (nothing was applied)"
		dim "Fix ${DOMAINS_FILE} and ${POLICY_FILE}; every host needs a port line and vice versa."
	fi
}

policy_apply() {
	need_root
	require_install
	heading "Apply the destination policy"
	dim "This validates the whole Squid configuration before reloading. If anything"
	dim "is wrong, the command changes nothing and Squid keeps its current policy."
	local out rc=0
	out="$("${BIN}" -config "${CONFIG_FILE}" -policy-apply 2>&1)" || rc=$?
	printf '%s\n' "${out}" | sed 's/^/  /'
	if [[ ${rc} -eq 0 ]]; then
		ok "policy applied; the configuration endpoint now serves it too"
	else
		bad "apply failed; the previous policy is still in force"
		return 1
	fi
}

# --- Certificates -----------------------------------------------------------
cert_status() {
	heading "TLS certificate"
	if [[ ! -r "${TLS_DIR}/fullchain.pem" ]]; then
		warn "no certificate at ${TLS_DIR}/fullchain.pem"
		dim "Run repair, or re-run the installer to request one."
		return 0
	fi
	local days
	days="$(cert_days_left || echo "?")"
	printf '  %-20s %s\n' "Subject" "$(cert_field -subject | sed 's/^subject=//')"
	printf '  %-20s %s\n' "Issuer" "$(cert_field -issuer | sed 's/^issuer=//')"
	printf '  %-20s %s\n' "Valid from" "$(cert_field -startdate | cut -d= -f2)"
	printf '  %-20s %s\n' "Valid until" "$(cert_field -enddate | cut -d= -f2)"
	printf '  %-20s %s\n' "Days remaining" "${days}"
	printf '  %-20s %s\n' "Names" "$(cert_field -ext subjectAltName | tail -n +2 | tr -d ' ')"
	printf '  %-20s %s\n' "Renewal timer" "$(unit_state "${RENEW_TIMER}")"
	local cb
	cb="$(certbot_path)"
	if [[ -x "${cb}" ]] || have "${cb}"; then
		printf '  %-20s %s\n' "certbot" "$( "${cb}" --version 2>/dev/null | head -1 )"
	fi
	if [[ "${days}" =~ ^[0-9-]+$ ]] && ((days < 14)); then
		say ""
		warn "the certificate expires in ${days} days; run 'certificate → renew' or check the timer"
	fi
	say ""
	dim "Chain sent to clients:"
	openssl s_client -connect "127.0.0.1:${PROXY_PORT:-443}" -servername "$(info_value PUBLIC_HOST)" -showcerts </dev/null 2>/dev/null |
		grep -E '^ *[0-9]+ s:' | sed 's/^ */  /' | head -3 || true
}

certbot_path() {
	if [[ -x "${CERTBOT}" ]]; then
		printf '%s' "${CERTBOT}"
	elif have certbot; then
		command -v certbot
	else
		printf 'certbot'
	fi
}

cert_renew() {
	need_root
	heading "Renew the TLS certificate"
	say "  A valid certificate with more than 30 days left is reused, not replaced."
	say "  Replacement is only requested when the current one is missing, expiring,"
	say "  or does not cover this relay's address."
	say ""

	if [[ -r "${TLS_DIR}/fullchain.pem" ]]; then
		local days
		days="$(cert_days_left || echo "")"
		if [[ "${days}" =~ ^[0-9]+$ ]] && ((days > 30)) && ! confirm "The certificate has ${days} days left. Replace it anyway?"; then
			ok "kept the existing certificate"
			return 0
		fi
	fi

	local cb out rc=0
	cb="$(certbot_path)"
	have "${cb}" || [[ -x "${cb}" ]] || die "certbot is not installed; re-run the installer (it installs a private copy)"
	out="$("${cb}" renew --cert-name "${CERT_NAME}" --deploy-hook "${HOOK}" --non-interactive 2>&1)" || rc=$?
	printf '%s\n' "${out}" | sed 's/^/  /'

	if [[ ${rc} -eq 0 ]]; then
		ok "renewal command finished; the deploy hook reloaded the services"
		return 0
	fi

	if grep -qiE 'rate ?limit|too many (certificates|failed|new orders)|retry after' <<<"${out}"; then
		say ""
		bad "Let's Encrypt refused the request because of a rate limit"
		local retry
		retry="$(grep -oiE 'retry after[: ]+[0-9T:.Z+-]+' <<<"${out}" | head -1 || true)"
		[[ -n "${retry}" ]] && info "${retry}"
		info "The existing certificate was kept and is still being served."
		info "Rate limits reset over hours or days; do not retry in a loop."
		info "Details: https://letsencrypt.org/docs/rate-limits/"
	elif grep -qiE 'port 80|connection refused|timeout|dns|unauthorized' <<<"${out}"; then
		say ""
		bad "HTTP-01 validation failed: Let's Encrypt could not fetch the challenge"
		info "Check that port 80 is open in the firewall, the cloud security group,"
		info "and that $(info_value PUBLIC_HOST) still points at this server."
		info "The existing certificate was kept."
	else
		say ""
		bad "renewal failed (see the output above); the existing certificate was kept"
	fi
	return 1
}

# --- Diagnostics ------------------------------------------------------------
diagnostics() {
	heading "Diagnostics"
	local problems=0

	# Configuration and policy
	if [[ -x "${BIN}" ]]; then
		if "${BIN}" -config "${CONFIG_FILE}" -policy-check >/dev/null 2>&1; then
			ok "destination policy is valid"
		else
			bad "destination policy is invalid"
			problems=$((problems + 1))
		fi
	fi

	# Permissions
	if [[ -r "${CONFIG_FILE}" ]]; then
		local mode
		mode="$(stat -c '%a' "${CONFIG_FILE}")"
		if (( (8#${mode} & 8#007) != 0 )); then
			bad "${CONFIG_FILE} is readable by other users (mode ${mode})"
			problems=$((problems + 1))
		else
			ok "${CONFIG_FILE} permissions (${mode})"
		fi
	fi
	if [[ -r "${TLS_DIR}/privkey.pem" ]]; then
		local keymode
		keymode="$(stat -c '%a' "${TLS_DIR}/privkey.pem")"
		if (( (8#${keymode} & 8#007) != 0 )); then
			bad "${TLS_DIR}/privkey.pem is world-accessible (mode ${keymode})"
			problems=$((problems + 1))
		else
			ok "private key permissions (${keymode})"
		fi
	fi

	# Services
	local u state
	for u in "${UNITS[@]}"; do
		state="$(unit_state "${u}")"
		if [[ "${state}" == "active" ]]; then
			ok "${u} is running"
		else
			bad "${u} is ${state}"
			problems=$((problems + 1))
		fi
	done

	# Endpoint
	if [[ -n "$(api_url)" ]]; then
		local code
		code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 8 "$(api_url)" 2>/dev/null)" || code=000
		[[ -n "${code}" ]] || code=000
		if [[ "${code}" == "200" ]]; then
			ok "configuration endpoint answers 200"
		else
			bad "configuration endpoint answered ${code}"
			problems=$((problems + 1))
		fi
	fi

	# Limits and performance
	local key bw_configured=0 tc_out shaping_state
	for key in PROXY_UPLOAD_LIMIT_MBIT PROXY_DOWNLOAD_LIMIT_MBIT TURN_UPLOAD_LIMIT_MBIT TURN_DOWNLOAD_LIMIT_MBIT; do
		local v
		v="$(limits_read "${key}")"
		if [[ "${v}" =~ ^[0-9]+$ ]] && ((10#${v} > 0)); then
			bw_configured=1
		fi
	done
	printf '  %-24s proxy %s/%s Mbps, TURN %s/%s Mbps (down/up per IP)\n' \
		"Bandwidth limits" \
		"$(limits_read PROXY_DOWNLOAD_LIMIT_MBIT)" "$(limits_read PROXY_UPLOAD_LIMIT_MBIT)" \
		"$(limits_read TURN_DOWNLOAD_LIMIT_MBIT)" "$(limits_read TURN_UPLOAD_LIMIT_MBIT)"
	printf '  %-24s %s/min per IP (burst %s), %s/min global (burst %s)\n' \
		"API rate limits" \
		"$(limits_read PER_IP_RATE_PER_MINUTE)" "$(limits_read PER_IP_BURST)" \
		"$(limits_read GLOBAL_RATE_PER_MINUTE)" "$(limits_read GLOBAL_BURST)"
	if ((bw_configured)); then
		shaping_state=""
		if [[ -x "${TC_SCRIPT}" ]]; then
			tc_out="$("${TC_SCRIPT}" status 2>&1)" || true
			shaping_state="$(printf '%s\n' "${tc_out}" | sed -n 's/^shaping=//p' | tail -1)"
		fi
		case "${shaping_state}" in
		active)
			ok "per-client-IP bandwidth limits are enforced"
			printf '%s\n' "${tc_out}" | sed -n 's/^interface=/        interface /p;s/^shaped_addresses=/        shaped addresses /p'
			if printf '%s\n' "${tc_out}" | grep -q '^rate_mismatch='; then
				bad "the active shaping rules do not carry the configured rates"
				problems=$((problems + 1))
			fi
			;;
		*)
			bad "bandwidth limits are configured but NOT enforced (shaping ${shaping_state:-unavailable})"
			info "the relay is running, but clients are not limited; run: ${TC_SCRIPT} apply"
			problems=$((problems + 1))
			;;
		esac
	else
		ok "bandwidth limits are disabled by configuration (0 = unlimited)"
	fi

	# API response time is what a profile load waits for.
	if [[ -n "$(api_url)" ]] && have curl; then
		local total=0 ok_samples=0 one
		for _ in 1 2 3 4 5; do
			one="$(curl -sS -o /dev/null --max-time 8 -w '%{time_total}' "$(api_url)" 2>/dev/null)" || continue
			[[ "${one}" =~ ^[0-9.]+$ ]] || continue
			total="$(awk -v a="${total}" -v b="${one}" 'BEGIN { printf "%.4f", a + b }')"
			ok_samples=$((ok_samples + 1))
		done
		if ((ok_samples > 0)); then
			local avg_ms
			avg_ms="$(awk -v t="${total}" -v n="${ok_samples}" 'BEGIN { printf "%.0f", t / n * 1000 }')"
			if ((avg_ms < 1000)); then
				ok "profile load takes ${avg_ms} ms on average"
			else
				bad "profile load takes ${avg_ms} ms on average: slower than a profile should wait"
				problems=$((problems + 1))
			fi
		fi
	fi
	if command -v journalctl >/dev/null 2>&1; then
		local limited_count
		limited_count="$(journalctl -u "${API_UNIT}" --since '-1 hour' --no-pager 2>/dev/null | grep -c 'rate limited' || true)"
		if [[ "${limited_count:-0}" != "0" ]]; then
			warn "${limited_count} API request(s) were rate limited in the last hour (per-IP burst is $(limits_read PER_IP_BURST))"
		fi
	fi

	# Certificate
	if [[ -r "${TLS_DIR}/fullchain.pem" ]]; then
		local days
		days="$(cert_days_left || echo 0)"
		if [[ "${days}" =~ ^[0-9]+$ ]] && ((days >= 7)); then
			ok "certificate valid for ${days} more days"
		else
			bad "certificate expires in ${days} days"
			problems=$((problems + 1))
		fi
	fi

	# Network Configuration API port, its listener and its firewall rule
	local api_p listen_addr state
	api_p="$(api_port)"
	listen_addr="$(api_listen_addr)"
	printf '  %-24s %s\n' "API port (configured)" "${api_p}"
	printf '  %-24s %s\n' "API listen address" "${listen_addr}"
	if [[ "${listen_addr##*:}" != "${api_p}" ]]; then
		bad "HTTPS_LISTEN (${listen_addr}) and NETWORK_CONFIG_PORT (${api_p}) disagree: configuration error"
		problems=$((problems + 1))
	fi
	if port_listening "${api_p}"; then
		ok "TCP ${api_p} is listening (network configuration endpoint)"
	elif port_free "${api_p}"; then
		warn "TCP ${api_p} is free but nothing is listening: the API did not start on the configured port"
		problems=$((problems + 1))
	else
		bad "TCP ${api_p} is in use by another process: port conflict"
		problems=$((problems + 1))
	fi
	state="$(firewall_api_state "${api_p}")"
	case "${state}" in
	allowed) ok "firewall allows TCP ${api_p}" ;;
	missing)
		bad "the firewall does not allow TCP ${api_p}"
		problems=$((problems + 1))
		;;
	*)
		dim "no active ufw/firewalld; allow TCP ${api_p} in your provider firewall"
		;;
	esac

	# General firewall presence for the other relay ports
	if have ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
		local port missing=0
		for port in 80/tcp "$(url_port PROXY)/tcp" 3478/udp 5349/tcp; do
			ufw status | grep -q "${port%%/*}" || missing=1
		done
		if ((missing)); then
			warn "ufw is active but not all relay ports are allowed (see Network → firewall)"
		else
			ok "ufw allows the relay ports"
		fi
	fi

	say ""
	if ((problems == 0)); then
		ok "no problems found"
	else
		warn "${problems} problem(s) found — use Repair to fix what can be fixed automatically"
	fi

	if [[ -x "${LIB_DIR}/verify.sh" || -x "${PWD}/deploy/scripts/verify.sh" ]]; then
		say ""
		if confirm "Run the full verification suite now (about a minute)?"; then
			local script="${LIB_DIR}/verify.sh"
			[[ -x "${script}" ]] || script="${PWD}/deploy/scripts/verify.sh"
			say ""
			PISHCORD_RELAY_SKIP_RENEW=1 bash "${script}" || true
		fi
	fi
}

# --- Limits and performance -------------------------------------------------
# Every limit lives in a file the installer writes, so this section edits those
# files. Changes are staged in a pending copy, validated as a whole, backed up,
# written, applied and verified; a failure restores the previous configuration
# and restarts the services that were touched.

limits_pending_config() { printf '%s/config.env' "${LIMITS_PENDING}"; }
limits_pending_squid() { printf '%s/squid.conf' "${LIMITS_PENDING}"; }
limits_pending_turn() { printf '%s/turnserver.conf' "${LIMITS_PENDING}"; }

limits_default() {
	case "$1" in
	PROXY_UPLOAD_LIMIT_MBIT | PROXY_DOWNLOAD_LIMIT_MBIT) printf '8' ;;
	TURN_UPLOAD_LIMIT_MBIT | TURN_DOWNLOAD_LIMIT_MBIT) printf '16' ;;
	PER_IP_RATE_PER_MINUTE) printf '60' ;;
	PER_IP_BURST) printf '30' ;;
	GLOBAL_RATE_PER_MINUTE) printf '1200' ;;
	GLOBAL_BURST) printf '300' ;;
	TC_MAX_CLIENTS) printf '512' ;;
	TC_REFRESH_SECONDS) printf '5' ;;
	esac
}

limits_label() {
	case "$1" in
	PROXY_UPLOAD_LIMIT_MBIT) printf 'Proxy upload per client IP' ;;
	PROXY_DOWNLOAD_LIMIT_MBIT) printf 'Proxy download per client IP' ;;
	TURN_UPLOAD_LIMIT_MBIT) printf 'TURN upload per client IP' ;;
	TURN_DOWNLOAD_LIMIT_MBIT) printf 'TURN download per client IP' ;;
	PER_IP_RATE_PER_MINUTE) printf 'API requests per IP per minute' ;;
	PER_IP_BURST) printf 'API request burst per IP' ;;
	GLOBAL_RATE_PER_MINUTE) printf 'API requests per minute (global)' ;;
	GLOBAL_BURST) printf 'API request burst (global)' ;;
	TC_MAX_CLIENTS) printf 'Client addresses shaped per service' ;;
	TC_REFRESH_SECONDS) printf 'Seconds between shaping refreshes' ;;
	esac
}

limits_unit() {
	case "$1" in
	*_MBIT) printf ' Mbps' ;;
	*_RATE_PER_MINUTE) printf '/min' ;;
	TC_REFRESH_SECONDS) printf 's' ;;
	esac
}

limits_value_from() { # FILE KEY PENDING
	local file="$1" key="$2" source="$1"
	if [[ -n "${3:-}" && -r "$3" ]]; then
		source="$3"
	fi
	sed -n "s/^${key}=//p" "${source}" 2>/dev/null | tail -1
}

# limits_read prints one setting from the pending copy, falling back to the live
# configuration and then to the shipped default.
limits_read() {
	local key="$1" value=""
	value="$(limits_value_from "${CONFIG_FILE}" "${key}" "$(limits_pending_config)")"
	[[ -n "${value}" ]] || value="$(limits_default "${key}")"
	printf '%s' "${value}"
}

limits_set_pending() { # KEY VALUE
	local key="$1" value="$2"
	limits_set_file "$(limits_pending_config)" "${key}" "${value}"
}

limits_set_file() { # FILE KEY VALUE
	local file="$1" key="$2" value="$3"
	if grep -q "^${key}=" "${file}" 2>/dev/null; then
		sed -i "s|^${key}=.*|${key}=${value}|" "${file}"
	else
		printf '%s=%s\n' "${key}" "${value}" >>"${file}"
	fi
}

# limits_number_problem prints why VALUE is unusable and returns 0; returns 1
# when it is inside MIN..MAX.
limits_number_problem() { # LABEL VALUE MIN MAX
	local label="$1" value="$2" min="$3" max="$4"
	if [[ ! "${value}" =~ ^[0-9]{1,11}$ ]]; then
		printf '%s must be a whole number, got %q' "${label}" "${value}"
		return 0
	fi
	if ((10#${value} < min || 10#${value} > max)); then
		printf '%s must be between %d and %d, got %s' "${label}" "${min}" "${max}" "${value}"
		return 0
	fi
	return 1
}

limits_stage() {
	if [[ ! -d "${LIMITS_PENDING}" ]]; then
		install -d -m 0700 -o root -g root "${LIMITS_PENDING}" 2>/dev/null || mkdir -p "${LIMITS_PENDING}" || return 1
	fi
	local file
	for file in config.env squid.conf turnserver.conf; do
		[[ -r "${LIMITS_PENDING}/${file}" ]] && continue
		if [[ -r "${ETC_DIR}/${file}" ]]; then
			cp -p "${ETC_DIR}/${file}" "${LIMITS_PENDING}/${file}"
		fi
	done
}

limits_discard() { rm -rf "${LIMITS_PENDING}"; }

limits_squid_connections() {
	local source="${SQUID_CONF}"
	[[ -r "$(limits_pending_squid)" ]] && source="$(limits_pending_squid)"
	sed -n 's/^[[:space:]]*client_ip_max_connections[[:space:]]\{1,\}\([0-9][0-9]*\).*/\1/p' "${source}" 2>/dev/null | tail -1
}

limits_turn_value() { # KEY
	local source="${TURNSERVER_CONF}"
	[[ -r "$(limits_pending_turn)" ]] && source="$(limits_pending_turn)"
	sed -n "s/^${1}=//p" "${source}" 2>/dev/null | tail -1
}

limits_shaping_summary() {
	if [[ -x "${TC_SCRIPT}" ]]; then
		local out
		out="$("${TC_SCRIPT}" status 2>/dev/null || true)"
		printf '%s\n' "${out}" | sed -n 's/^shaping=/    shaping status       /p;s/^interface=/    interface            /p;s/^egress_qdisc=/    egress qdisc         /p;s/^ingress_qdisc=/    ingress qdisc        /p;s/^shaped_addresses=/    shaped addresses     /p'
	else
		dim "traffic-shaping helper not installed (${TC_SCRIPT})"
	fi
}

limits_show() {
	heading "Limits and performance"
	local key
	say "  Bandwidth limits are per client IP, not per connection; 0 means unlimited."
	say "  Proxy and TURN are accounted separately."
	say ""
	say "  Bandwidth (Mbit/s)"
	for key in PROXY_UPLOAD_LIMIT_MBIT PROXY_DOWNLOAD_LIMIT_MBIT TURN_UPLOAD_LIMIT_MBIT TURN_DOWNLOAD_LIMIT_MBIT; do
		printf '    %-38s %s\n' "$(limits_label "${key}")" "$(limits_read "${key}")$(limits_unit "${key}")"
	done
	say ""
	say "  API request limits"
	for key in PER_IP_RATE_PER_MINUTE PER_IP_BURST GLOBAL_RATE_PER_MINUTE GLOBAL_BURST; do
		printf '    %-38s %s\n' "$(limits_label "${key}")" "$(limits_read "${key}")$(limits_unit "${key}")"
	done
	say ""
	say "  Proxy and TURN"
	printf '    %-38s %s\n' "Concurrent proxy connections per IP" "$(limits_squid_connections)"
	printf '    %-38s %s\n' "TURN allocations per credential" "$(limits_turn_value user-quota)"
	printf '    %-38s %s\n' "TURN allocations in total" "$(limits_turn_value total-quota)"
	printf '    %-38s %s\n' "TURN per-session ceiling (bytes/s)" "$(limits_turn_value max-bps)"
	printf '    %-38s %s\n' "TURN relay capacity (bytes/s)" "$(limits_turn_value bps-capacity)"
	say ""
	say "  Traffic shaping"
	printf '    %-38s %s\n' "$(limits_label TC_MAX_CLIENTS)" "$(limits_read TC_MAX_CLIENTS)"
	printf '    %-38s %s\n' "$(limits_label TC_REFRESH_SECONDS)" "$(limits_read TC_REFRESH_SECONDS)s"
	limits_shaping_summary
	if [[ -d "${LIMITS_PENDING}" ]]; then
		say ""
		warn "unapplied changes are staged; choose Apply staged changes to activate them"
	fi
}

limits_prompt() { # KEY MIN MAX
	local key="$1" min="$2" max="$3" current answer reason
	current="$(limits_read "${key}")"
	while true; do
		printf '  %s [%s]: ' "$(limits_label "${key}")" "${current}"
		read -r answer || return 1
		answer="${answer:-${current}}"
		answer="${answer//[[:space:]]/}"
		if reason="$(limits_number_problem "$(limits_label "${key}")" "${answer}" "${min}" "${max}")"; then
			warn "${reason}"
			continue
		fi
		limits_set_pending "${key}" "$((10#${answer}))"
		ok "$(limits_label "${key}") set to $((10#${answer}))$(limits_unit "${key}")"
		return 0
	done
}

limits_edit_api() {
	limits_prompt PER_IP_RATE_PER_MINUTE 1 1000000 || return 0
	limits_prompt PER_IP_BURST 1 1000000 || return 0
	limits_prompt GLOBAL_RATE_PER_MINUTE 1 1000000 || return 0
	limits_prompt GLOBAL_BURST 1 1000000 || return 0
}

limits_edit_connections() {
	local current answer reason max
	max="$(sed -n 's/^max_filedescriptors[[:space:]]\{1,\}\([0-9][0-9]*\).*/\1/p' "${SQUID_CONF}" 2>/dev/null | tail -1)"
	max="${max:-8192}"
	current="$(limits_squid_connections)"
	current="${current:-100}"
	limits_stage
	while true; do
		printf '  Concurrent proxy connections per client IP [%s]: ' "${current}"
		read -r answer || return 0
		answer="${answer:-${current}}"
		answer="${answer//[[:space:]]/}"
		if reason="$(limits_number_problem "connections per client IP" "${answer}" 1 "${max}")"; then
			warn "${reason} (max_filedescriptors is ${max})"
			continue
		fi
		limits_set_file "$(limits_pending_squid)" client_ip_max_connections "$((10#${answer}))"
		ok "each client IP may hold $((10#${answer})) concurrent proxy connections"
		return 0
	done
}

limits_edit_turn() {
	local key current answer reason user total
	limits_stage
	for key in user-quota total-quota; do
		current="$(limits_turn_value "${key}")"
		current="${current:-12}"
		while true; do
			printf '  %s [%s]: ' "${key}" "${current}"
			read -r answer || return 0
			answer="${answer:-${current}}"
			answer="${answer//[[:space:]]/}"
			if reason="$(limits_number_problem "${key}" "${answer}" 1 100000)"; then
				warn "${reason}"
				continue
			fi
			limits_set_file "$(limits_pending_turn)" "${key}" "$((10#${answer}))"
			ok "${key} set to $((10#${answer}))"
			break
		done
	done
	user="$(limits_turn_value user-quota)"
	total="$(limits_turn_value total-quota)"
	if [[ "${user}" =~ ^[0-9]+$ && "${total}" =~ ^[0-9]+$ ]] && ((total < user)); then
		warn "total-quota (${total}) is below user-quota (${user}); allocations may be refused"
	fi
	for key in max-bps bps-capacity; do
		current="$(limits_turn_value "${key}")"
		current="${current:-2000000}"
		while true; do
			printf '  %s (bytes/s) [%s]: ' "${key}" "${current}"
			read -r answer || return 0
			answer="${answer:-${current}}"
			answer="${answer//[[:space:]]/}"
			if reason="$(limits_number_problem "${key}" "${answer}" 1000 10000000000)"; then
				warn "${reason}"
				continue
			fi
			limits_set_file "$(limits_pending_turn)" "${key}" "$((10#${answer}))"
			ok "${key} set to $((10#${answer})) bytes/s"
			break
		done
	done
}

limits_validate() {
	local problems=0 key value reason min max connections user total bps cap
	local -A ranges=(
		[PROXY_UPLOAD_LIMIT_MBIT]="0 100000"
		[PROXY_DOWNLOAD_LIMIT_MBIT]="0 100000"
		[TURN_UPLOAD_LIMIT_MBIT]="0 100000"
		[TURN_DOWNLOAD_LIMIT_MBIT]="0 100000"
		[PER_IP_RATE_PER_MINUTE]="1 1000000"
		[PER_IP_BURST]="1 1000000"
		[GLOBAL_RATE_PER_MINUTE]="1 1000000"
		[GLOBAL_BURST]="1 1000000"
		[TC_MAX_CLIENTS]="1 2047"
		[TC_REFRESH_SECONDS]="1 60"
	)
	for key in "${LIMIT_KEYS[@]}"; do
		value="$(limits_read "${key}")"
		read -r min max <<<"${ranges[${key}]}"
		if reason="$(limits_number_problem "$(limits_label "${key}")" "${value}" "${min}" "${max}")"; then
			bad "${reason}"
			problems=$((problems + 1))
		fi
	done
	connections="$(limits_squid_connections)"
	if [[ -z "${connections}" ]]; then
		bad "squid.conf has no client_ip_max_connections line"
		problems=$((problems + 1))
	fi
	user="$(limits_turn_value user-quota)"
	total="$(limits_turn_value total-quota)"
	bps="$(limits_turn_value max-bps)"
	cap="$(limits_turn_value bps-capacity)"
	for pair in "user-quota:${user}:1:100000" "total-quota:${total}:1:100000" "max-bps:${bps}:1000:10000000000" "bps-capacity:${cap}:1000:10000000000"; do
		IFS=':' read -r key value min max <<<"${pair}"
		if reason="$(limits_number_problem "${key}" "${value}" "${min}" "${max}")"; then
			bad "${reason}"
			problems=$((problems + 1))
		fi
	done
	if [[ "${user}" =~ ^[0-9]+$ && "${total}" =~ ^[0-9]+$ ]] && ((total < user)); then
		bad "total-quota (${total}) must be at least user-quota (${user})"
		problems=$((problems + 1))
	fi
	if [[ "${bps}" =~ ^[0-9]+$ && "${cap}" =~ ^[0-9]+$ ]] && ((cap < bps)); then
		bad "bps-capacity (${cap}) must be at least max-bps (${bps}); coturn would refuse allocations"
		problems=$((problems + 1))
	fi
	((problems == 0))
}

limits_restore_from() { # DIR
	local dir="$1" file
	for file in config.env squid.conf turnserver.conf; do
		[[ -r "${dir}/${file}" ]] && cp -p "${dir}/${file}" "${ETC_DIR}/${file}"
	done
}

# limits_apply writes the staged configuration, applies it and verifies it. Any
# failure restores the previous files and restarts what was restarted.
limits_apply() {
	need_root
	require_install
	if [[ ! -d "${LIMITS_PENDING}" ]]; then
		info "no staged changes; nothing to apply"
		return 0
	fi
	if ! limits_validate; then
		bad "the staged configuration is not valid; nothing was changed"
		return 1
	fi
	if [[ -r "$(limits_pending_squid)" ]]; then
		if ! "${SQUID_BIN}" -k parse -f "$(limits_pending_squid)" >/dev/null 2>&1; then
			bad "Squid rejected the new configuration; nothing was changed"
			"${SQUID_BIN}" -k parse -f "$(limits_pending_squid)" 2>&1 | tail -5 | sed 's/^/        /'
			return 1
		fi
	fi

	local stamp backup file failed=0 config_changed=0 squid_changed=0 turn_changed=0
	stamp="$(date -u +%Y%m%dT%H%M%SZ)"
	backup="${LIMITS_BACKUP_ROOT}/limits-${stamp}"
	install -d -m 0700 -o root -g root "${backup}"
	for file in config.env squid.conf turnserver.conf; do
		[[ -r "${ETC_DIR}/${file}" ]] && cp -p "${ETC_DIR}/${file}" "${backup}/${file}"
	done
	info "backup written to ${backup}"

	if [[ -r "$(limits_pending_config)" ]] && ! cmp -s "$(limits_pending_config)" "${CONFIG_FILE}"; then
		config_changed=1
	fi
	if [[ -r "$(limits_pending_squid)" ]] && ! cmp -s "$(limits_pending_squid)" "${SQUID_CONF}"; then
		squid_changed=1
	fi
	if [[ -r "$(limits_pending_turn)" ]] && ! cmp -s "$(limits_pending_turn)" "${TURNSERVER_CONF}"; then
		turn_changed=1
	fi

	((config_changed)) && cp -p "$(limits_pending_config)" "${CONFIG_FILE}"
	((squid_changed)) && cp -p "$(limits_pending_squid)" "${SQUID_CONF}"
	((turn_changed)) && cp -p "$(limits_pending_turn)" "${TURNSERVER_CONF}"

	if ((config_changed)) && [[ -x "${TC_SCRIPT}" ]]; then
		"${TC_SCRIPT}" apply >/dev/null 2>&1 || {
			bad "the new bandwidth limits could not be applied"
			failed=1
		}
	fi
	if ((squid_changed)); then
		systemctl reload "${SQUID_UNIT}" >/dev/null 2>&1 || systemctl restart "${SQUID_UNIT}" >/dev/null 2>&1 || failed=1
	fi
	if ((turn_changed)); then
		systemctl restart "${COTURN_UNIT}" >/dev/null 2>&1 || failed=1
	fi
	if ((config_changed)); then
		systemctl restart "${API_UNIT}" >/dev/null 2>&1 || failed=1
	fi

	if ((failed == 0)); then
		sleep 1
		local u
		for u in "${UNITS[@]}"; do
			if [[ "${u}" == "${SQUID_UNIT}" ]] && ((squid_changed == 0)); then
				continue
			fi
			if [[ "${u}" == "${COTURN_UNIT}" ]] && ((turn_changed == 0)); then
				continue
			fi
			if [[ "${u}" == "${API_UNIT}" ]] && ((config_changed == 0)); then
				continue
			fi
			if [[ "$(unit_state "${u}")" != "active" ]]; then
				bad "${u} did not stay running after applying the new limits"
				failed=1
			fi
		done
	fi
	if ((failed == 0)) && ((config_changed)) && [[ -x "${TC_SCRIPT}" ]]; then
		if ! "${TC_SCRIPT}" status >/dev/null 2>&1; then
			bad "the shaper is not enforcing the new bandwidth limits"
			"${TC_SCRIPT}" status 2>&1 | sed 's/^/        /' || true
			failed=1
		fi
	fi

	if ((failed)); then
		limits_restore_from "${backup}"
		warn "restored the previous configuration from ${backup}"
		if ((squid_changed)); then
			systemctl reload "${SQUID_UNIT}" >/dev/null 2>&1 || systemctl restart "${SQUID_UNIT}" >/dev/null 2>&1 || true
		fi
		if ((turn_changed)); then
			systemctl restart "${COTURN_UNIT}" >/dev/null 2>&1 || true
		fi
		if ((config_changed)); then
			systemctl restart "${API_UNIT}" >/dev/null 2>&1 || true
			if [[ -x "${TC_SCRIPT}" ]]; then
				"${TC_SCRIPT}" apply >/dev/null 2>&1 || true
			fi
		fi
		bad "the new limits were not applied; the previous configuration is back in place"
		return 1
	fi

	limits_discard
	ok "limits applied and verified"
	return 0
}

limits_menu() {
	need_root
	require_install
	while true; do
		limits_show
		say ""
		printf '  1. Change proxy bandwidth limits\n'
		printf '  2. Change TURN bandwidth limits\n'
		printf '  3. Change API request limits\n'
		printf '  4. Change proxy connection limit\n'
		printf '  5. Change TURN quotas and capacity\n'
		printf '  6. Disable all bandwidth limits (0 = unlimited)\n'
		printf '  7. Apply staged changes\n'
		printf '  8. Discard staged changes\n'
		printf '  0. Back\n\n  Select an option: '
		local choice key
		read -r choice || return 0
		case "${choice}" in
		1)
			limits_stage
			limits_prompt PROXY_UPLOAD_LIMIT_MBIT 0 100000 || :
			limits_prompt PROXY_DOWNLOAD_LIMIT_MBIT 0 100000 || :
			;;
		2)
			limits_stage
			limits_prompt TURN_UPLOAD_LIMIT_MBIT 0 100000 || :
			limits_prompt TURN_DOWNLOAD_LIMIT_MBIT 0 100000 || :
			;;
		3) limits_stage && limits_edit_api ;;
		4) limits_edit_connections ;;
		5) limits_edit_turn ;;
		6)
			limits_stage
			for key in PROXY_UPLOAD_LIMIT_MBIT PROXY_DOWNLOAD_LIMIT_MBIT TURN_UPLOAD_LIMIT_MBIT TURN_DOWNLOAD_LIMIT_MBIT; do
				limits_set_pending "${key}" 0
			done
			warn "all four bandwidth limits are staged as 0; choose Apply staged changes to remove the shaping rules"
			;;
		7) limits_apply || : ;;
		8)
			if [[ -d "${LIMITS_PENDING}" ]] && confirm "Discard the staged changes?"; then
				limits_discard
				ok "staged changes discarded"
			fi
			;;
		0 | q | Q) return 0 ;;
		*) warn "invalid option" ;;
		esac
		pause
	done
}

# --- Update -----------------------------------------------------------------
# Updates download the published release archive for this architecture and
# verify it against checksums.txt. Only the two executables are replaced:
# configuration, certificates, policies and runtime data are never touched.
release_arch() {
	case "${1:-$(uname -m)}" in
	x86_64 | amd64) printf 'amd64' ;;
	aarch64 | arm64) printf 'arm64' ;;
	*) return 1 ;;
	esac
}

release_api_url() {
	printf '%s' "${PISHCORD_RELAY_LATEST_API:-https://api.github.com/repos/${REPO_SLUG}/releases/latest}"
}

release_download_base() {
	printf '%s' "${PISHCORD_RELAY_RELEASE_BASE_URL:-https://github.com/${REPO_SLUG}/releases/download}"
}

# release_fetch URL DEST accepts HTTPS, plus file:// and loopback HTTP for tests.
release_fetch() {
	local url="$1" dest="$2"
	case "${url}" in
	https://*)
		curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 \
			--max-time 180 --retry 2 --retry-delay 2 -o "${dest}" "${url}"
		;;
	file://* | http://127.0.0.1:* | http://localhost:*)
		curl -fsSL --max-time 180 -o "${dest}" "${url}"
		;;
	*)
		return 1
		;;
	esac
}

normalize_release_version() {
	local v="$1"
	[[ -n "${v}" && "${v}" != latest ]] || return 1
	[[ "${v}" == v* ]] || v="v${v}"
	[[ "${v}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
	printf '%s' "${v}"
}

release_latest_tag() {
	local json tag
	json="$(mktemp)"
	if ! release_fetch "$(release_api_url)" "${json}"; then
		rm -f "${json}"
		return 1
	fi
	if have jq; then
		tag="$(jq -r '.tag_name // empty' "${json}" 2>/dev/null || true)"
	else
		tag="$(python3 - "${json}" <<'PY' 2>/dev/null || true
import json, sys
try:
    print(json.load(open(sys.argv[1])).get("tag_name", ""))
except Exception:
    pass
PY
)"
	fi
	rm -f "${json}"
	normalize_release_version "${tag}"
}

installed_release_version() {
	local v
	v="$(info_value RELEASE_VERSION)"
	if [[ -z "${v}" || "${v}" == "unknown" ]] && [[ -x "${BIN}" ]]; then
		v="$("${BIN}" -version 2>/dev/null | awk '{print $2}' || true)"
	fi
	printf '%s' "${v:-unknown}"
}

record_release_version() { # VERSION ARCH
	[[ -r "${INFO_FILE}" ]] || return 0
	local tmp
	tmp="$(mktemp)" || return 0
	awk -v v="$1" -v a="$2" '
		/^RELEASE_VERSION=/ { print "RELEASE_VERSION=" v; seen = 1; next }
		/^RELEASE_ARCH=/ { print "RELEASE_ARCH=" a; seen_arch = 1; next }
		{ print }
		END {
			if (!seen) print "RELEASE_VERSION=" v
			if (!seen_arch) print "RELEASE_ARCH=" a
		}' "${INFO_FILE}" >"${tmp}" || {
		rm -f "${tmp}"
		return 0
	}
	mv "${tmp}" "${INFO_FILE}"
}

# release_download_archive TAG DIR downloads, verifies and extracts an archive.
# On success RELEASE_UNPACK and RELEASE_ASSET describe it. On failure every
# installed file is untouched.
release_download_archive() {
	local tag="$1" dir="$2" arch asset base checksums file magic
	arch="$(release_arch "$(uname -m)")" || {
		bad "unsupported architecture '$(uname -m)': releases exist for linux/amd64 and linux/arm64"
		return 1
	}
	asset="pishcord-relay_linux_${arch}.tar.gz"
	base="$(release_download_base)"
	base="${base%/}"
	mkdir -p "${dir}"
	dim "downloading ${base}/${tag}/${asset}"
	if ! release_fetch "${base}/${tag}/${asset}" "${dir}/${asset}"; then
		bad "cannot download ${asset}; the installed binaries were not changed"
		return 1
	fi
	if ! release_fetch "${base}/${tag}/checksums.txt" "${dir}/checksums.txt"; then
		bad "cannot download checksums.txt; refusing to install unverified binaries"
		return 1
	fi
	checksums="${dir}/checksums.txt"
	if ! grep -qE "^[0-9a-fA-F]{64}[[:space:]]+\*?${asset}$" "${checksums}"; then
		bad "checksums.txt has no SHA256 entry for ${asset}; refusing to install unverified binaries"
		return 1
	fi
	if ! (cd "${dir}" && sha256sum -c --ignore-missing checksums.txt >/dev/null); then
		bad "SHA256 verification failed for ${asset}; the installed binaries were not changed"
		return 1
	fi
	ok "SHA256 verified ${asset}"
	mkdir -p "${dir}/unpacked"
	if ! tar -xzf "${dir}/${asset}" -C "${dir}/unpacked" --no-same-owner; then
		bad "cannot extract ${asset}; the installed binaries were not changed"
		return 1
	fi
	for file in pishcord-relayd pishcord-relay; do
		if [[ ! -f "${dir}/unpacked/${file}" || -L "${dir}/unpacked/${file}" ]]; then
			bad "${asset} does not contain a regular ${file} file"
			return 1
		fi
		magic="$(od -An -tx1 -N4 "${dir}/unpacked/${file}" | tr -d ' \n')"
		if [[ "${magic}" != "7f454c46" ]]; then
			bad "${asset} contains ${file} that is not a Linux executable"
			return 1
		fi
	done
	if [[ "${arch}" == "$(release_arch "$(uname -m)")" ]]; then
		if ! "${dir}/unpacked/pishcord-relayd" -version 2>/dev/null | grep -Fq " ${tag} "; then
			bad "the downloaded pishcord-relayd does not report ${tag}; refusing a mismatched release"
			return 1
		fi
	fi
	RELEASE_UNPACK="${dir}/unpacked"
	RELEASE_ASSET="${asset}"
	dim "extracted ${RELEASE_ASSET}"
}

update_menu() {
	need_root
	require_install
	heading "Update Pishcord-relay"

	local current latest requested target arch dir backup
	current="$(installed_release_version)"
	latest="$(release_latest_tag 2>/dev/null || true)"
	arch="$(release_arch "$(uname -m)" || true)"
	[[ -n "${arch}" ]] ||
		die "unsupported architecture '$(uname -m)': releases exist for linux/amd64 and linux/arm64"

	printf '  %-18s %s\n' "Installed" "${current}"
	printf '  %-18s linux/%s\n' "Architecture" "${arch}"
	printf '  %-18s %s\n' "Latest release" "${latest:-unavailable}"
	say ""
	printf '  Version to install [%s]: ' "${latest:-vX.Y.Z}"
	read -r requested || die "cancelled"
	if [[ -n "${requested}" ]]; then
		target="$(normalize_release_version "${requested}")" ||
			die "'${requested}' is not a semantic version tag (expected vX.Y.Z)"
	elif [[ -n "${latest}" ]]; then
		target="${latest}"
	else
		die "cannot determine the latest release; enter a version such as v1.1.0"
	fi

	if [[ "${target}" == "${current}" ]] &&
		! confirm "${current} is already installed. Reinstall it anyway?"; then
		return 0
	fi

	say ""
	say "  This will:"
	info "download pishcord-relay_linux_${arch}.tar.gz for ${target}"
	info "verify it against the release's checksums.txt"
	info "back up the current executables"
	info "replace ${BIN} and ${CONSOLE_BIN}, then restart ${API_UNIT}"
	info "keep configuration, certificates, policies and runtime data unchanged"
	info "restore the previous executables if the service does not come back"
	say ""
	confirm "Install ${target}?" || die "cancelled; nothing was changed"

	dir="$(mktemp -d "${TMPDIR:-/tmp}/pishcord-relay-update.XXXXXX")"
	# shellcheck disable=SC2064
	trap "rm -rf -- '${dir}'" RETURN
	if ! release_download_archive "${target}" "${dir}"; then
		trap - RETURN
		rm -rf -- "${dir}"
		return 1
	fi

	backup="$(policy_backup_dir)/binaries-$(date +%Y%m%d-%H%M%S)"
	mkdir -p "${backup}"
	chmod 0700 "${backup}"
	[[ -e "${BIN}" ]] && cp -a "${BIN}" "${backup}/"
	[[ -e "${CONSOLE_BIN}" ]] && cp -a "${CONSOLE_BIN}" "${backup}/"
	ok "current executables backed up to ${backup}"

	rollback_update() {
		local restored=0
		if [[ -f "${backup}/pishcord-relayd" ]]; then
			install -m 0755 "${backup}/pishcord-relayd" "${BIN}"
			restored=1
		fi
		if [[ -f "${backup}/pishcord-relay" ]]; then
			install -m 0755 "${backup}/pishcord-relay" "${CONSOLE_BIN}"
			restored=1
		fi
		((restored)) || return 1
		systemctl restart "${API_UNIT}" >/dev/null 2>&1 || true
		if api_reachable "$(api_port)"; then
			ok "rolled back to the previous executables; the API is answering again"
		else
			bad "rolled back, but the API is not answering; check journalctl -u ${API_UNIT}"
		fi
	}

	install -m 0755 "${RELEASE_UNPACK}/pishcord-relayd" "${BIN}.new" || {
		rollback_update
		die "cannot stage the new daemon; the previous executables were kept"
	}
	install -m 0755 "${RELEASE_UNPACK}/pishcord-relay" "${CONSOLE_BIN}.new" || {
		rm -f "${BIN}.new"
		rollback_update
		die "cannot stage the new console; the previous executables were kept"
	}
	mv -f "${BIN}.new" "${BIN}"
	mv -f "${CONSOLE_BIN}.new" "${CONSOLE_BIN}"

	if unit_exists "${API_UNIT}"; then
		info "restarting ${API_UNIT}"
		systemctl restart "${API_UNIT}" || true
	else
		warn "${API_UNIT} is not installed; start the daemon yourself"
	fi

	local ready=0 i
	for i in $(seq 1 15); do
		if ! unit_exists "${API_UNIT}" || systemctl is-active --quiet "${API_UNIT}"; then
			if api_reachable "$(api_port)"; then
				ready=1
				break
			fi
		fi
		sleep 1
	done

	if [[ ${ready} -eq 0 ]]; then
		bad "${target} did not start cleanly"
		journalctl -u "${API_UNIT}" -n 20 --no-pager 2>/dev/null | sed 's/^/  /' || true
		rollback_update
		trap - RETURN
		rm -rf -- "${dir}"
		return 1
	fi

	record_release_version "${target}" "${arch}"
	ok "updated ${current} -> ${target} (linux/${arch}); the API is answering"
	info "configuration, certificates and policies were not touched"
	trap - RETURN
	rm -rf -- "${dir}"
}

# --- Repair -----------------------------------------------------------------
repair_menu() {
	need_root
	require_install
	heading "Repair"
	say "  Only the checks that fail below are repaired."

	local fixed=0
	# Directories
	local dir
	for dir in "${ETC_DIR}" "${TLS_DIR}" "${LOG_DIR}"; do
		if [[ ! -d "${dir}" ]]; then
			if confirm "${dir} is missing. Create it?" yes; then
				mkdir -p "${dir}"
				ok "created ${dir}"
				fixed=1
			fi
		fi
	done

	# Permissions
	if [[ -e "${CONFIG_FILE}" ]]; then
		local mode
		mode="$(stat -c '%a' "${CONFIG_FILE}")"
		if (( (8#${mode} & 8#007) != 0 )); then
			if confirm "${CONFIG_FILE} is mode ${mode}. Restrict it to 0640?" yes; then
				chmod 0640 "${CONFIG_FILE}"
				ok "fixed permissions on ${CONFIG_FILE}"
				fixed=1
			fi
		fi
	fi
	if [[ -e "${TLS_DIR}/privkey.pem" ]]; then
		local keymode
		keymode="$(stat -c '%a' "${TLS_DIR}/privkey.pem")"
		if (( (8#${keymode} & 8#007) != 0 )); then
			if confirm "${TLS_DIR}/privkey.pem is mode ${keymode}. Restrict it to 0640?" yes; then
				chown root:pishcord-relay "${TLS_DIR}/privkey.pem" 2>/dev/null || true
				chmod 0640 "${TLS_DIR}/privkey.pem"
				ok "fixed permissions on the private key"
				fixed=1
			fi
		fi
	fi

	# Policy
	if ! "${BIN}" -config "${CONFIG_FILE}" -policy-check >/dev/null 2>&1; then
		say ""
		warn "the destination policy does not validate"
		policy_check
	fi

	# Services
	local u state
	for u in "${UNITS[@]}"; do
		state="$(unit_state "${u}")"
		if [[ "${state}" != "active" ]] && unit_exists "${u}"; then
			if confirm "${u} is ${state}. Restart it?" yes; then
				if systemctl restart "${u}"; then
					sleep 1
					ok "${u} is now $(unit_state "${u}")"
					fixed=1
				else
					bad "${u} still failing; recent log:"
					journalctl -u "${u}" -n 15 --no-pager 2>/dev/null | sed 's/^/  /' || true
				fi
			fi
		fi
	done

	# Units missing entirely: offer a full re-install with the saved settings.
	local missing=0
	for u in "${UNITS[@]}"; do
		unit_exists "${u}" || missing=1
	done
	if ((missing)); then
		say ""
		warn "one or more systemd units are missing"
		if confirm "Re-run the installer to recreate them (keeps configuration and certificates)?" yes; then
			local -a args=(--yes)
			local mode host ip
			mode="$(info_value MODE)"
			host="$(info_value PUBLIC_HOST)"
			ip="$(info_value PUBLIC_IP)"
			[[ -n "${mode}" ]] && args+=(--mode "${mode}")
			[[ -n "${host}" && "${mode}" == "domain" ]] && args+=(--domain "${host}")
			[[ -n "${ip}" ]] && args+=(--ip "${ip}")
			local installer="${LIB_DIR}/bootstrap.sh"
			[[ -f "${installer}" ]] || installer="${PWD}/deploy/install.sh"
			[[ -f "${installer}" ]] || die "the installer is not available; re-run the one-line installer from the README"
			bash "${installer}" "${args[@]}" && fixed=1
		fi
	fi

	say ""
	if ((fixed)); then
		ok "repair finished"
	else
		info "nothing needed changing"
	fi
}

# --- Uninstall --------------------------------------------------------------
uninstall_menu() {
	need_root
	heading "Uninstall Pishcord-relay"
	local script="${LIB_DIR}/uninstall.sh"
	[[ -f "${script}" ]] || script="${PWD}/uninstall.sh"
	if [[ ! -f "${script}" ]]; then
		die "the uninstaller was not found; re-download it from the repository README"
	fi
	bash "${script}"
}

# --- Interactive menu -------------------------------------------------------
# The box is drawn from a width, not from hand-counted spaces, so adding or
# renaming a menu entry cannot push a border out of line.
BOX_W=54
box_rule() { printf '%s' "$(printf '─%.0s' $(seq 1 "${BOX_W}"))"; }
box_top() { printf '  ╭%s╮\n' "$(box_rule)"; }
box_sep() { printf '  ├%s┤\n' "$(box_rule)"; }
box_bottom() { printf '  ╰%s╯\n' "$(box_rule)"; }
box_line() { printf '  │%-*s│\n' "${BOX_W}" "$1"; }
box_center() {
	local text="$1" pad
	pad=$(((BOX_W - ${#text}) / 2))
	((pad < 0)) && pad=0
	printf '  │%*s%s%*s│\n' "${pad}" "" "${text}" "$((BOX_W - pad - ${#text}))" ""
}
box_row() { box_line "$(printf '  %-22s%s' "$1" "$2")"; }

banner() {
	printf '\n%s' "${C_CYAN}${C_BOLD}"
	box_top
	box_line ""
	box_center "Pishcord-relay"
	box_center "Management"
	box_line ""
	printf '  ├%s┤%s\n' "$(box_rule)" "${C_RESET}"
}

menu() {
	while true; do
		banner
		box_line ""
		box_row "1. Dashboard" "6. TLS certificates"
		box_row "2. Services" "7. Diagnostics"
		box_row "3. Network" "8. Update"
		box_row "4. Domain policy" "9. Repair"
		box_row "5. Firewall" "10. Uninstall"
		box_line ""
		box_row "11. Limits & performance" ""
		box_row "0. Exit" ""
		box_bottom
		printf '\n'
		printf '  Select an option: '
		local choice
		read -r choice || exit 0
		case "${choice}" in
		1) dashboard ;;
		2) service_menu ;;
		3) network_menu ;;
		4) policy_menu ;;
		5) firewall_info ;;
		6) cert_menu ;;
		7) diagnostics ;;
		8) update_menu ;;
		9) repair_menu ;;
		10) uninstall_menu ;;
		11) limits_menu ;;
		0 | q | Q | exit) exit 0 ;;
		*) warn "invalid option" ;;
		esac
		pause
	done
}

policy_menu() {
	heading "Domain policy"
	policy_show
	say ""
	printf '  1. Add a destination\n  2. Remove a destination\n  3. Validate changes\n  4. Apply changes\n  0. Back\n\n  Select an option: '
	local choice
	read -r choice
	case "${choice}" in
	1) policy_add ;;
	2) policy_remove ;;
	3) policy_check ;;
	4) policy_apply ;;
	*) return 0 ;;
	esac
}

cert_menu() {
	cert_status
	say ""
	printf '  1. Renew now\n  2. Show renewal timer\n  0. Back\n\n  Select an option: '
	local choice
	read -r choice
	case "${choice}" in
	1) cert_renew ;;
	2)
		systemctl list-timers --all "${RENEW_TIMER}" --no-pager 2>/dev/null | sed 's/^/  /' || warn "timer not installed"
		;;
	*) return 0 ;;
	esac
}

firewall_info() {
	heading "Firewall"
	local missing=0 port api_p
	api_p="$(api_port)"
	if have ufw; then
		ufw status verbose 2>/dev/null | sed 's/^/  /' || true
	fi
	if have ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
		for port in 80 "$(url_port PROXY)" "${api_p}" 3478 5349; do
			if ! ufw status | grep -qE "(^|[^0-9])${port}([/ ]|$)"; then
				warn "port ${port} does not appear in the ufw rules"
				missing=1
			fi
		done
		((missing)) || ok "the relay ports are allowed in ufw (API port ${api_p})"
		return 0
	fi
	if have firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
		say ""
		firewall-cmd --list-all 2>/dev/null | sed 's/^/  /' || true
		if [[ "$(firewall_api_state "${api_p}")" == "allowed" ]]; then
			ok "firewalld allows the API port ${api_p}"
		else
			warn "firewalld does not allow the API port ${api_p}"
		fi
		return 0
	fi
	warn "no active ufw or firewalld found"
	say "  If your provider has a firewall (EC2 security groups, Hetzner, OVH), open:"
	say "    80/tcp, $(url_port PROXY)/tcp, ${api_p}/tcp, 3478/udp, 5349/tcp, 49152-65535/udp"
	say ""
	dim "The host firewall cannot open ports in a cloud security group for you."
}

# firewall_api_state prints allowed, missing or unmanaged for a TCP port.
firewall_api_state() {
	local port="$1"
	if have ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
		if ufw status | grep -qE "^${port}/tcp[[:space:]]+ALLOW"; then
			printf 'allowed'
		else
			printf 'missing'
		fi
	elif have firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
		if firewall-cmd --query-port="${port}/tcp" >/dev/null 2>&1; then
			printf 'allowed'
		else
			printf 'missing'
		fi
	else
		printf 'unmanaged'
	fi
}

# ufw_api_rule_numbers lists the numbered ufw rules this project added for a
# port, newest first. The comment tag means unrelated rules are never removed.
ufw_api_rule_numbers() {
	local port="$1"
	ufw status numbered 2>/dev/null |
		awk -v want="${port}/tcp" -v tag="pishcord-relay network config" '
			index($0, want) && index($0, tag) {
				line = $0
				sub(/^\[[[:space:]]*/, "", line)
				sub(/\].*/, "", line)
				print line
			}' | sort -rn
}

# firewall_set_api_port replaces the API port rule, leaving every unrelated rule
# (including Squid's and coturn's) alone. Returns non-zero if the new port is not
# allowed afterwards.
firewall_set_api_port() { # OLD NEW
	local old="$1" new="$2" n
	if have ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
		if [[ "${old}" != "${new}" ]]; then
			while read -r n; do
				[[ -n "${n}" ]] || continue
				ufw --force delete "${n}" >/dev/null || warn "could not remove the old ufw rule for ${old}/tcp"
			done < <(ufw_api_rule_numbers "${old}")
		fi
		ufw allow "${new}/tcp" comment 'pishcord-relay network config' >/dev/null || return 1
		[[ "$(firewall_api_state "${new}")" == "allowed" ]]
		return
	fi
	if have firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
		firewall-cmd --permanent --add-port="${new}/tcp" >/dev/null || return 1
		if [[ "${old}" != "${new}" ]]; then
			firewall-cmd --permanent --remove-port="${old}/tcp" >/dev/null 2>&1 || true
		fi
		firewall-cmd --reload >/dev/null || return 1
		[[ "$(firewall_api_state "${new}")" == "allowed" ]]
		return
	fi
	warn "no active ufw/firewalld; open TCP ${new} in your provider firewall yourself"
	return 0
}

# api_reachable succeeds when the configured endpoint answers on PORT. The
# public host name is resolved locally, so no DNS lookup or external round trip
# is needed and the certificate is still verified for the real host name.
api_reachable() {
	local port="$1" url host
	url="$(api_url)"
	[[ "${url}" == *://* ]] || return 1
	host="${url#*://}"
	host="${host%%/*}"
	host="${host%%:*}"
	[[ -n "${host}" ]] || return 1
	curl -fsS --max-time 10 --resolve "${host}:${port}:127.0.0.1" -o /dev/null "${url}" 2>/dev/null
}

# write_api_port_config records PORT in config.env as the authoritative value
# and keeps the public URL and listen address on the same port.
write_api_port_config() {
	local port="$1" tmp url scheme rest host path listen owner mode
	url="$(api_url)"
	[[ -n "${url}" ]] || url="https://$(info_value PUBLIC_HOST)"
	scheme="${url%%://*}"
	rest="${url#*://}"
	host="${rest%%/*}"
	host="${host%%:*}"
	if [[ "${rest}" == */* ]]; then path="/${rest#*/}"; else path="/network-config"; fi
	url="${scheme}://${host}:${port}${path}"

	listen="$(api_listen_addr)"
	listen="${listen%:*}:${port}"

	tmp="$(mktemp)" || return 1
	awk -v port="${port}" -v url="${url}" -v listen="${listen}" '
		BEGIN { p = 0; u = 0; l = 0 }
		/^NETWORK_CONFIG_PORT=/ { print "NETWORK_CONFIG_PORT=" port; p = 1; next }
		/^NETWORK_CONFIG_URL=/ { print "NETWORK_CONFIG_URL=" url; u = 1; next }
		/^HTTPS_LISTEN=/ { print "HTTPS_LISTEN=" listen; l = 1; next }
		{ print }
		END {
			if (!p) print "NETWORK_CONFIG_PORT=" port
			if (!u) print "NETWORK_CONFIG_URL=" url
			if (!l) print "HTTPS_LISTEN=" listen
		}' "${CONFIG_FILE}" >"${tmp}" || {
		rm -f "${tmp}"
		return 1
	}
	owner="$(stat -c '%U:%G' "${CONFIG_FILE}" 2>/dev/null || printf 'root:root')"
	mode="$(stat -c '%a' "${CONFIG_FILE}" 2>/dev/null || printf '640')"
	chown "${owner}" "${tmp}" 2>/dev/null || true
	chmod "${mode}" "${tmp}" 2>/dev/null || true
	mv "${tmp}" "${CONFIG_FILE}"

	# install-info is informational, but its API_PORT should not disagree with
	# the configuration it describes.
	if [[ -r "${INFO_FILE}" ]]; then
		local itmp
		itmp="$(mktemp)" || return 0
		awk -v port="${port}" '
			/^API_PORT=/ { print "API_PORT=" port; seen = 1; next }
			{ print }
			END { if (!seen) print "API_PORT=" port }
		' "${INFO_FILE}" >"${itmp}" || {
			rm -f "${itmp}"
			return 0
		}
		mv "${itmp}" "${INFO_FILE}"
	fi
}

# network_change_port changes the API port in one guarded transaction: config,
# firewall, service restart and an end-to-end request. Any failure restores the
# previous configuration and listening state.
network_change_port() {
	need_root
	require_install
	[[ -t 0 ]] || die "changing the API port is interactive; run ${PROGRAM} in a terminal"

	local current port reason backup dir stamp
	current="$(api_port)"
	heading "Network Configuration API port"
	printf '  %-24s %s\n' "Configured port" "${current}"
	printf '  %-24s %s\n' "Listen address" "$(api_listen_addr)"
	say ""
	printf '  New port [%s]: ' "${current}"
	read -r port || die "cancelled"
	port="${port:-${current}}"
	port="${port//[[:space:]]/}"

	if reason="$(api_port_conflict "${port}")"; then
		warn "${reason}"
		return 1
	fi
	if [[ "${port}" == "${current}" ]]; then
		ok "the Network Configuration API already uses port ${current}"
		return 0
	fi

	say ""
	warn "the API will be briefly unavailable while its port changes"
	info "Pishcord profiles using https://$(info_value PUBLIC_HOST):${current}/network-config"
	info "must be updated to port ${port}; remote management also uses this port"
	confirm "Change the Network Configuration API port from ${current} to ${port}?" ||
		die "cancelled; nothing was changed"

	dir="$(policy_backup_dir)"
	mkdir -p "${dir}"
	chmod 0700 "${dir}"
	stamp="$(date +%Y%m%d-%H%M%S)"
	backup="${dir}/config.env.${stamp}"
	cp -a "${CONFIG_FILE}" "${backup}" || die "cannot back up ${CONFIG_FILE}; nothing was changed"
	dim "configuration backup: ${backup}"

	rollback_port() { # rollback_port OLD NEW
		cp -a "${backup}" "${CONFIG_FILE}" || warn "could not restore ${backup}"
		firewall_set_api_port "$2" "$1" || warn "could not restore the firewall rule for ${1}/tcp"
		systemctl restart "${API_UNIT}" >/dev/null 2>&1 || warn "could not restart ${API_UNIT}"
		if api_reachable "$1"; then
			ok "the previous configuration was restored; the API answers on ${1} again"
		else
			bad "the previous configuration was restored, but the API does not answer on ${1}"
			info "check: journalctl -u ${API_UNIT} -n 40 --no-pager"
		fi
		die "the port change failed and was rolled back"
	}

	info "updating ${CONFIG_FILE}"
	write_api_port_config "${port}" || rollback_port "${current}" "${port}"

	info "updating the firewall for TCP ${port}"
	firewall_set_api_port "${current}" "${port}" || rollback_port "${current}" "${port}"

	info "restarting ${API_UNIT}"
	if ! systemctl restart "${API_UNIT}"; then
		bad "${API_UNIT} failed to restart; recent log:"
		journalctl -u "${API_UNIT}" -n 20 --no-pager 2>/dev/null | sed 's/^/  /' || true
		rollback_port "${current}" "${port}"
	fi

	local ready=0
	for _ in $(seq 1 30); do
		if api_reachable "${port}"; then
			ready=1
			break
		fi
		sleep 1
	done
	if [[ ${ready} -eq 0 ]]; then
		bad "the API did not answer on https://$(info_value PUBLIC_HOST):${port}/network-config"
		journalctl -u "${API_UNIT}" -n 20 --no-pager 2>/dev/null | sed 's/^/  /' || true
		rollback_port "${current}" "${port}"
	fi

	say ""
	ok "the Network Configuration API now listens on port ${port}"
	info "update the Network Configuration URL in Pishcord to https://$(info_value PUBLIC_HOST):${port}/network-config"
}

network_menu() {
	network_info
	say ""
	printf '  1. Change the Network Configuration API port\n  0. Back\n\n  Select an option: '
	local choice
	read -r choice || return 0
	case "${choice}" in
	1) network_change_port ;;
	esac
}

# --- Dispatch ---------------------------------------------------------------
usage() {
	cat <<EOF
Pishcord-relay management console ${MANAGER_VERSION}

Usage: ${PROGRAM} [command]

  (no command)          Interactive menu
  dashboard             Status of services, certificate, endpoints and resources
  services status       Unit states for the relay services
  services start|stop|restart|reload UNIT
  services logs UNIT    Recent journal entries (add -f via 'services follow UNIT')
  services validate UNIT
  network               Endpoints, files and the document clients receive
  network port          Change the Network Configuration API port
  policy show           Current destinations with matching and ports
  policy add|remove     Edit the policy files (validated, then optionally applied)
  policy check|apply    Validate, or validate and reload Squid
  cert status|renew     Certificate details, manual renewal
  limits                Limits and performance (bandwidth, API rate, quotas)
  diagnostics           Health checks (optionally runs verify.sh)
  update                Download and install the newest version
  repair                Fix permissions, directories, stopped services
  uninstall             Remove Pishcord-relay (as uninstall.sh)
  version               Print the version
  help                  This text

Environment: NO_COLOR disables colour. Read-only commands work as any user;
changing commands need root.
EOF
}

main() {
	local cmd="${1:-}"
	case "${cmd}" in
	"") menu ;;
	dashboard | status) dashboard ;;
	services)
		shift
		local action="${1:-status}" unit="${2:-}"
		case "${action}" in
		status) service_status ;;
		start | stop | restart | reload | logs | follow | validate)
			[[ -n "${unit}" ]] || die "usage: ${PROGRAM} services ${action} UNIT"
			service_action "${unit}" "${action}"
			[[ "${action}" == "follow" ]] || true
			;;
		*) die "usage: ${PROGRAM} services status|start|stop|restart|reload|logs|follow|validate [UNIT]" ;;
		esac
		;;
	network)
		shift
		case "${1:-}" in
		"") network_info ;;
		port) network_change_port ;;
		*) die "usage: ${PROGRAM} network [port]" ;;
		esac
		;;
	policy)
		shift
		case "${1:-show}" in
		show | list) policy_show ;;
		add) policy_add ;;
		remove | rm) policy_remove ;;
		check | validate) policy_check ;;
		apply) policy_apply ;;
		*) die "usage: ${PROGRAM} policy show|add|remove|check|apply" ;;
		esac
		;;
	cert | certificate)
		shift
		case "${1:-status}" in
		status) cert_status ;;
		renew) cert_renew ;;
		*) die "usage: ${PROGRAM} cert status|renew" ;;
		esac
		;;
	limits | performance) limits_menu ;;
	diagnostics | doctor) diagnostics ;;
	update) update_menu ;;
	repair) repair_menu ;;
	uninstall) uninstall_menu ;;
	firewall) firewall_info ;;
	version | --version) printf '%s %s\n' "${PROGRAM}" "${MANAGER_VERSION}" ;;
	help | -h | --help) usage ;;
	*) usage; exit 1 ;;
	esac
}

# -policy-apply/renew/uninstall are the only things that need to be root, and
# they check for it themselves; everything else is safe to run read-only.
main "$@"
