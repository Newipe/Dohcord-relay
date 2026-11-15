#!/usr/bin/env bash
# Dohcord-relay management console.
#
# Installed as /usr/local/bin/dohcord-relay-manager by install.sh. It is a
# front-end for the components that already exist: the systemd units, the
# dohcord-relay binary and its -policy-apply/-policy-check commands, certbot,
# and deploy/verify.sh (installed at /usr/local/lib/dohcord-relay/verify.sh).
#
# It never re-implements networking logic and never edits Squid or coturn
# configuration itself: policy changes go through the binary, which validates
# the whole Squid configuration before anything is reloaded.
set -Eeuo pipefail

MANAGER_VERSION="1.0.0"

# --- Paths (overridable for testing) ---------------------------------------
ETC_DIR="${DOHCORD_RELAY_ETC_DIR:-/etc/dohcord-relay}"
TLS_DIR="${ETC_DIR}/tls"
CONFIG_FILE="${ETC_DIR}/config.env"
INFO_FILE="${ETC_DIR}/install-info"
DOMAINS_FILE="${ETC_DIR}/allowed-domains.txt"
POLICY_FILE="${ETC_DIR}/destination-policy.conf"
ALLOW_FILE="${ETC_DIR}/squid-allow.conf"
SQUID_CONF="${ETC_DIR}/squid.conf"
TURNSERVER_CONF="${ETC_DIR}/turnserver.conf"
LOG_DIR="/var/log/dohcord-relay"
LIB_DIR="${DOHCORD_RELAY_LIB_DIR:-/usr/local/lib/dohcord-relay}"
BIN="${DOHCORD_RELAY_BIN:-/usr/local/bin/dohcord-relay}"
HOOK="/usr/local/bin/dohcord-relay-tls-deploy"
CERTBOT="/opt/dohcord-relay-certbot/bin/certbot"
CERT_NAME="dohcord-relay"

API_UNIT="dohcord-relay-api.service"
SQUID_UNIT="dohcord-relay-squid.service"
COTURN_UNIT="dohcord-relay-coturn.service"
RENEW_TIMER="dohcord-relay-certbot-renew.timer"
UNITS=("${API_UNIT}" "${SQUID_UNIT}" "${COTURN_UNIT}")
REPO_SLUG="Newipe/Dohcord-relay"
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
	local s="${1#dohcord-relay-}"
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
	installed || die "Dohcord-relay is not installed on this server (missing ${BIN} or ${CONFIG_FILE})"
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
		default=8443
	else
		url="$(proxy_url)"
		default=443
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

# --- Dashboard --------------------------------------------------------------
dashboard() {
	local state days host mode version
	heading "Dashboard"

	# Installation
	if installed; then
		version="$(info_value INSTALLER_VERSION)"
		local installed_at
		installed_at="$(info_value INSTALLED_AT)"
		printf '  %-22s %s\n' "Installation" "$( [[ -n "${version}" ]] && echo "v${version} installed ${installed_at}" || echo "present" )"
	else
		printf '  %-22s %snot installed%s\n' "Installation" "${C_RED}" "${C_RESET}"
		printf '\n  Run the one-line installer from the README, or `dohcord-relay-manager repair`.\n'
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
		warn "Dohcord-relay is not installed yet"
		return 0
	fi
	printf '  %-24s %s\n' "Mode" "$(info_value MODE)"
	printf '  %-24s %s\n' "Public host" "$(info_value PUBLIC_HOST)"
	printf '  %-24s %s\n' "Public IPv4" "$(info_value PUBLIC_IP)"
	say ""
	printf '  %-24s %s\n' "HTTPS CONNECT proxy" "$(proxy_url)"
	printf '  %-24s %s\n' "Network config URL" "$(api_url)"
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
	[[ -t 0 ]] || die "adding a domain is interactive; run dohcord-relay-manager policy add in a terminal"

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

policy_backup_dir() { printf '%s' "${POLICY_BACKUP_DIR:-/var/backups/dohcord-relay}"; }

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

	# Firewall
	if have ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
		local port missing=0
		for port in 80/tcp 443/tcp 8443/tcp 3478/udp 5349/tcp; do
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

	if [[ -x "${LIB_DIR}/verify.sh" || -x "${PWD}/deploy/verify.sh" ]]; then
		say ""
		if confirm "Run the full verification suite now (about a minute)?"; then
			local script="${LIB_DIR}/verify.sh"
			[[ -x "${script}" ]] || script="${PWD}/deploy/verify.sh"
			say ""
			DOHCORD_RELAY_SKIP_RENEW=1 bash "${script}" || true
		fi
	fi
}

# --- Update -----------------------------------------------------------------
update_menu() {
	need_root
	require_install
	heading "Update Dohcord-relay"
	local current
	current="$(info_value INSTALLER_VERSION)"
	printf '  %-18s %s\n' "Installed" "${current:-unknown}"
	printf '  %-18s %s\n' "Source" "github.com/${REPO_SLUG} ($(info_value REPO_REF || echo main))"
	say ""

	local workdir
	workdir="$(mktemp -d "${TMPDIR:-/tmp}/dohcord-relay-update.XXXXXX")"
	# shellcheck disable=SC2064
	trap "rm -rf -- '${workdir}'" RETURN

	local ref url
	ref="$(info_value REPO_REF)"
	ref="${ref:-main}"
	url="https://codeload.github.com/${REPO_SLUG}/tar.gz/refs/heads/${ref}"

	dim "downloading ${url}"
	if ! curl -fsSL --proto '=https' --tlsv1.2 --max-time 120 -o "${workdir}/repo.tar.gz" "${url}"; then
		die "cannot download the update; nothing was changed"
	fi
	tar -xzf "${workdir}/repo.tar.gz" -C "${workdir}" --strip-components=1 ||
		die "cannot extract the update; nothing was changed"
	[[ -f "${workdir}/deploy/install.sh" ]] || die "the downloaded archive does not look like Dohcord-relay"

	local remote
	remote="$(grep -m1 '^readonly INSTALLER_VERSION=' "${workdir}/deploy/install.sh" | cut -d'"' -f2 || true)"
	printf '  %-18s %s\n' "Available" "${remote:-unknown}"
	say ""

	if [[ -n "${remote}" && "${remote}" == "${current}" ]] &&
		! confirm "Already on ${current}. Re-run the installer to repair it?"; then
		return 0
	fi

	say "  This will:"
	info "back up ${ETC_DIR} to $(policy_backup_dir)/config-\$(date)"
	info "keep your configuration, policy and certificates (the installer preserves them)"
	info "rebuild the binary, re-render unit files and configuration, restart services"
	info "verify the result"
	say ""
	confirm "Continue?" || die "cancelled; nothing was changed"

	local backup
	backup="$(policy_backup_dir)/config-$(date +%Y%m%d-%H%M%S)"
	mkdir -p "$(dirname "${backup}")"
	chmod 0700 "$(dirname "${backup}")"
	if cp -a "${ETC_DIR}" "${backup}" 2>/dev/null; then
		ok "configuration backed up to ${backup}"
	else
		warn "could not back up ${ETC_DIR}; continuing anyway"
		backup=""
	fi

	local -a args=(--yes)
	local mode host ip
	mode="$(info_value MODE)"
	host="$(info_value PUBLIC_HOST)"
	ip="$(info_value PUBLIC_IP)"
	[[ -n "${mode}" ]] && args+=(--mode "${mode}")
	[[ -n "${host}" && "${mode}" == "domain" ]] && args+=(--domain "${host}")
	[[ -n "${ip}" ]] && args+=(--ip "${ip}")

	say ""
	if bash "${workdir}/deploy/install.sh" "${args[@]}"; then
		ok "update finished and the installer reported success"
		return 0
	fi

	say ""
	bad "the update did not complete"
	if [[ -n "${backup}" && -d "${backup}" ]]; then
		if confirm "Restore the configuration backup from ${backup}?" yes; then
			rm -rf -- "${ETC_DIR}"
			cp -a "${backup}" "${ETC_DIR}"
			ok "configuration restored"
			info "Services may need a restart: dohcord-relay-manager services"
		fi
	fi
	return 1
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
				chown root:dohcord-relay "${TLS_DIR}/privkey.pem" 2>/dev/null || true
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
	heading "Uninstall Dohcord-relay"
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
	box_center "Dohcord-relay"
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
		box_row "0. Exit" ""
		box_bottom
		printf '\n'
		printf '  Select an option: '
		local choice
		read -r choice || exit 0
		case "${choice}" in
		1) dashboard ;;
		2) service_menu ;;
		3) network_info ;;
		4) policy_menu ;;
		5) firewall_info ;;
		6) cert_menu ;;
		7) diagnostics ;;
		8) update_menu ;;
		9) repair_menu ;;
		10) uninstall_menu ;;
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
	local missing=0 port
	if have ufw; then
		ufw status verbose 2>/dev/null | sed 's/^/  /' || true
	fi
	if have ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
		for port in 80 443 8443 3478 5349; do
			if ! ufw status | grep -qE "(^|[^0-9])${port}([/ ]|$)"; then
				warn "port ${port} does not appear in the ufw rules"
				missing=1
			fi
		done
		((missing)) || ok "the relay ports are allowed in ufw"
		return 0
	fi
	if have firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
		say ""
		firewall-cmd --list-all 2>/dev/null | sed 's/^/  /' || true
		return 0
	fi
	warn "no active ufw or firewalld found"
	say "  If your provider has a firewall (EC2 security groups, Hetzner, OVH), open:"
	say "    80/tcp, 443/tcp, 8443/tcp, 3478/udp, 5349/tcp, 49152-65535/udp"
	say ""
	dim "The host firewall cannot open ports in a cloud security group for you."
}

# --- Dispatch ---------------------------------------------------------------
usage() {
	cat <<EOF
Dohcord-relay management console ${MANAGER_VERSION}

Usage: dohcord-relay-manager [command]

  (no command)          Interactive menu
  dashboard             Status of services, certificate, endpoints and resources
  services status       Unit states for the relay services
  services start|stop|restart|reload UNIT
  services logs UNIT    Recent journal entries (add -f via 'services follow UNIT')
  services validate UNIT
  network               Endpoints, files and the document clients receive
  policy show           Current destinations with matching and ports
  policy add|remove     Edit the policy files (validated, then optionally applied)
  policy check|apply    Validate, or validate and reload Squid
  cert status|renew     Certificate details, manual renewal
  diagnostics           Health checks (optionally runs verify.sh)
  update                Download and install the newest version
  repair                Fix permissions, directories, stopped services
  uninstall             Remove Dohcord-relay (as uninstall.sh)
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
			[[ -n "${unit}" ]] || die "usage: dohcord-relay-manager services ${action} UNIT"
			service_action "${unit}" "${action}"
			[[ "${action}" == "follow" ]] || true
			;;
		*) die "usage: dohcord-relay-manager services status|start|stop|restart|reload|logs|follow|validate [UNIT]" ;;
		esac
		;;
	network) network_info ;;
	policy)
		shift
		case "${1:-show}" in
		show | list) policy_show ;;
		add) policy_add ;;
		remove | rm) policy_remove ;;
		check | validate) policy_check ;;
		apply) policy_apply ;;
		*) die "usage: dohcord-relay-manager policy show|add|remove|check|apply" ;;
		esac
		;;
	cert | certificate)
		shift
		case "${1:-status}" in
		status) cert_status ;;
		renew) cert_renew ;;
		*) die "usage: dohcord-relay-manager cert status|renew" ;;
		esac
		;;
	diagnostics | doctor) diagnostics ;;
	update) update_menu ;;
	repair) repair_menu ;;
	uninstall) uninstall_menu ;;
	firewall) firewall_info ;;
	version | --version) printf 'dohcord-relay-manager %s\n' "${MANAGER_VERSION}" ;;
	help | -h | --help) usage ;;
	*) usage; exit 1 ;;
	esac
}

# -policy-apply/renew/uninstall are the only things that need to be root, and
# they check for it themselves; everything else is safe to run read-only.
main "$@"
