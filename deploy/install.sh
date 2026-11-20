#!/usr/bin/env bash
# Dohcord Relay installer.
#
# Sets up two networking services on one VPS:
#
#   Dohcord --TLS--> Squid :443 --CONNECT host:port--> Discord HTTPS/WSS
#   Dohcord --TURN--> coturn :3478/udp, :5349/tcp --> Discord RTC media
#
# plus a small HTTPS endpoint (8443 by default, or the port chosen at install
# time) that publishes the proxy address, the destination policy and temporary
# TURN credentials:
#
#   https://<your host>:8443/network-config
#
# Tested on Ubuntu 24.04 and Debian 12; targets Ubuntu 22.04+/Debian 12+.
# Run from a checkout of the repository:
#
#   sudo deploy/install.sh                 # interactive: domain or IP
#   sudo deploy/install.sh --mode domain --domain relay.example.com --ip 203.0.113.10
#   sudo deploy/install.sh --mode ip --ip 203.0.113.10
#
# The installer is idempotent: it keeps an existing TURN secret, an existing
# valid certificate, and only rewrites files it owns.
set -Eeuo pipefail

readonly INSTALLER_VERSION="1.0.0"

# --- Defaults ---------------------------------------------------------------
MODE=""            # "domain" or "ip"; asked interactively when empty
PUBLIC_IP=""
DOMAIN=""
EMAIL=""
ASSUME_YES=0
STAGING=0
DISTRO_COTURN=0
COTURN_VERSION="4.18.0"
# SHA-256 of the official GitHub release archive for ${COTURN_VERSION}.
COTURN_SHA256="28d55294ac596fbd129b293a85e7bb1c5dc4bd15b7fb55c500f355149e5f4e28"
USER_QUOTA=12
TOTAL_QUOTA=1200
# Per-session ceiling (~16 Mbit/s) and total relay capacity (~2 Gbit/s of
# reservations, i.e. room for roughly 125 simultaneous sessions).
MAX_BPS=2000000
BPS_CAPACITY=250000000
PROXY_PORT=443
# Port of the Network Configuration API. 8443 is the default; an interactive
# installation shows it and may choose another one (--api-port for automation).
API_PORT=8443
API_PORT_EXPLICIT=0
# Port used before this run, so its firewall rule can be retired safely.
PREVIOUS_API_PORT=""
MAX_CONN_PER_IP=40
MAX_FDS=8192
READ_TIMEOUT="10 minutes"
CLIENT_LIFETIME="4 hours"
SKIP_RENEW_TEST=0
SKIP_VERIFY=0

readonly ETC_DIR="/etc/dohcord-relay"
readonly TLS_DIR="${ETC_DIR}/tls"
# Each service gets its own log and runtime directory: they run as different
# unprivileged users, so a single shared directory would lock one of them out.
readonly LOG_DIR="/var/log/dohcord-relay"
readonly SQUID_LOG_DIR="${LOG_DIR}/squid"
readonly TURN_LOG_DIR="${LOG_DIR}/turnserver"
readonly SQUID_RUN_DIR="/run/dohcord-relay-squid"
readonly TURN_RUN_DIR="/run/dohcord-relay-coturn"
readonly WEBROOT="/var/www/dohcord-relay"
readonly DAEMON="/usr/local/bin/dohcord-relayd"
readonly CLI="/usr/local/bin/dohcord-relay"
readonly HOOK="/usr/local/bin/dohcord-relay-tls-deploy"
readonly MANAGER_ALIAS="/usr/local/bin/dohcord-relay-manager"
readonly LIB_DIR="/usr/local/lib/dohcord-relay"
readonly MANAGER_SCRIPT="${LIB_DIR}/manager.sh"
readonly INFO_FILE="${ETC_DIR}/install-info"
readonly CERT_NAME="dohcord-relay"
readonly API_UNIT="dohcord-relay-api.service"
readonly SQUID_UNIT="dohcord-relay-squid.service"
readonly COTURN_UNIT="dohcord-relay-coturn.service"
readonly RENEW_SERVICE="dohcord-relay-certbot-renew.service"
readonly RENEW_TIMER="dohcord-relay-certbot-renew.timer"

REPO_DIR=""
# Release selection. An explicit tag (or DOHCORD_RELAY_VERSION) wins; otherwise
# the latest stable GitHub Release is used. DOHCORD_RELAY_RELEASE_BASE_URL and
# DOHCORD_RELAY_LATEST_API exist so the download path can be tested against a
# local mirror; they are not needed in normal use.
RELEASE_REQUEST="${DOHCORD_RELAY_VERSION:-}"
RELEASE_TAG=""
RELEASE_ARCH=""
RELEASE_BASE_URL="${DOHCORD_RELAY_RELEASE_BASE_URL:-https://github.com/Newipe/Dohcord-relay/releases/download}"
LATEST_RELEASE_API="${DOHCORD_RELAY_LATEST_API:-https://api.github.com/repos/Newipe/Dohcord-relay/releases/latest}"
RELEASE_WORKDIR=""
RELEASE_ARCHIVE_DIR=""
BIN_BACKUP_DIR=""
TURN_BINARY=""
SQUID_BINARY=""
CERTBOT=""
PRIVATE_IP=""
LISTENING_IP="0.0.0.0"
RELAY_IP=""
EXTERNAL_IP=""
PUBLIC_HOST=""
TURN_REALM=""
BOOTSTRAP_PID=""
SQUID_INSTALLED_VERSION=""
COTURN_INSTALLED_VERSION=""

# --- Output helpers ---------------------------------------------------------
# Colour is used only when standard output is a terminal that can show it; the
# plain fallback is the same text without escape codes, so logs and
# non-interactive runs stay readable.
if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
	C_RESET=$'\033[0m' C_BOLD=$'\033[1m' C_DIM=$'\033[2m'
	C_CYAN=$'\033[36m' C_GREEN=$'\033[32m' C_RED=$'\033[31m' C_YELLOW=$'\033[33m'
else
	C_RESET="" C_BOLD="" C_DIM="" C_CYAN="" C_GREEN="" C_RED="" C_YELLOW=""
fi

step=0
stage_names=()
stage_done=()

banner() {
	cat <<EOF

${C_CYAN}${C_BOLD}  ╭──────────────────────────────────────────────────────╮
  │                                                      │
  │                   Dohcord-relay                      │
  │                   Installation                       │
  │                                                      │
  ╰──────────────────────────────────────────────────────╯${C_RESET}

  Welcome to Dohcord-relay ${INSTALLER_VERSION}.

  This server will host two services for Dohcord:

    · an HTTPS proxy on 443, limited to the destinations in the policy
    · a TURN relay on 3478/udp and 5349/tcp for voice and video

  plus a small HTTPS endpoint that tells Dohcord how to reach them. It
  listens on port 8443 by default; the settings below show the port and let
  you change it. Nothing on this server is decrypted; the proxy forwards
  encrypted connections and only decides where they may go.

  Nothing has been changed yet. The steps below are shown as they run,
  and the summary at the end lists what is reachable and how to manage it.
EOF
}

step_msg() {
	if ((step > 0)); then
		stage_done[step - 1]=1
	fi
	step=$((step + 1))
	stage_names+=("$*")
	printf '\n  %s%02d%s  %s%s%s\n' "${C_DIM}" "${step}" "${C_RESET}" "${C_BOLD}" "$*" "${C_RESET}"
}
info() { printf '      %s\n' "$*"; }
ok() { printf '      %s✓%s %s\n' "${C_GREEN}" "${C_RESET}" "$*"; }
warn() { printf '      %s!%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
die() {
	printf '\n  %s✗ %s%s\n' "${C_RED}" "$*" "${C_RESET}" >&2
	printf '  Nothing was left half-configured: this installer stops before it\n  would leave a service on an unvalidated configuration.\n\n' >&2
	exit 1
}

# repeat_char prints $2 $1 times, so rules are drawn from a width instead of a
# hand-counted run of box characters.
repeat_char() {
	local n=$1 ch=$2 out=""
	while ((n-- > 0)); do
		out+=$ch
	done
	printf '%s' "${out}"
}

# print_progress draws the stage list. A stage is shown as OK only when the
# script actually reached the next one; a failure exits before this runs, so a
# failed installation can never print a success list.
#
# The box is sized from the longest stage name, so adding or renaming a step can
# never push a border out of line: 54 is the inner width that lines the box up
# with the banner, and a longer name widens every line together.
print_progress() {
	if ((step > 0)); then
		stage_done[step - 1]=1
	fi
	local i name inner=54 label_width title="Installation progress" pad
	for name in "${stage_names[@]}"; do
		(( ${#name} + 7 > inner )) && inner=$(( ${#name} + 7 ))
	done
	# Inner width is " [OK] " (6) plus the padded name (label_width) plus " ".
	label_width=$((inner - 7))
	pad=$((inner - ${#title} - 3))
	((pad < 1)) && pad=1
	printf '\n  %s╭─ %s %s╮%s\n' "${C_CYAN}" "${title}" "$(repeat_char "${pad}" '─')" "${C_RESET}"
	for i in "${!stage_names[@]}"; do
		if [[ "${stage_done[i]:-0}" == "1" ]]; then
			printf '  │ %s[OK]%s %-*s │\n' "${C_GREEN}" "${C_RESET}" "${label_width}" "${stage_names[i]}"
		else
			printf '  │ %s[--]%s %-*s │\n' "${C_DIM}" "${C_RESET}" "${label_width}" "${stage_names[i]}"
		fi
	done
	printf '  %s╰%s╯%s\n' "${C_CYAN}" "$(repeat_char "${inner}" '─')" "${C_RESET}"
}
on_error() {
	local rc=$?
	printf '\n  %s✗ The installer stopped at line %s (exit %s)%s\n' "${C_RED}" "${BASH_LINENO[0]}" "${rc}" "${C_RESET}" >&2
	printf '    while running: %s\n' "${BASH_COMMAND}" >&2
	printf '    Re-run the same command to retry: completed steps are safe to repeat,\n    and existing configuration and certificates are kept.\n' >&2
	stop_acme_bootstrap
	cleanup_release_workdir
	exit "${rc}"
}
trap on_error ERR
trap 'stop_acme_bootstrap; exit 130' INT TERM

usage() {
	cat <<'EOF'
Usage: sudo deploy/install.sh [options]

Normally you do not run this file directly. Use the one-line installer:

  bash <(curl -fsSL https://raw.githubusercontent.com/Newipe/Dohcord-relay/main/install.sh)

or, in a checkout of this repository, `bash install.sh` at the top level.
Both end up here and accept the options below.

How clients connect (choose one):
  --mode domain            Clients use a domain name (recommended).
  --mode ip                Clients use the public IPv4 address.
  --domain NAME            Fully qualified domain name (with --mode domain).
  --ip ADDRESS             Public IPv4 of this relay. Detected when omitted.

Certificates:
  --email ADDRESS          Optional contact address for Let's Encrypt expiry
                           notices. Without it the ACME account has no email.
  --staging                Use the Let's Encrypt staging CA (test installs).

Service sizes:
  --realm NAME             TURN realm (default: the domain, or dohcord.relay).
  --distro-coturn          Use the distribution coturn package instead of
                           building the pinned upstream release.
  --coturn-version VERSION Upstream coturn release to build (default: 4.18.0).
  --user-quota N           Concurrent allocations per credential (default: 12).
  --total-quota N          Concurrent allocations for the relay (default: 1200).
  --max-bps N              Per-session bandwidth ceiling, bytes/s (default: 2000000).
  --bps-capacity N         Total relay bandwidth reservation, bytes/s
                           (default: 250000000).
  --max-connections N      Concurrent proxy connections per client IP (default: 40).

Network Configuration API:
  --api-port N             Port for the Network Configuration API (default: 8443).
                           Interactive installs always show the port and let you
                           change it (Enter keeps the configured one). Use this
                           option with --yes for automated deployments.
  --version VERSION        Release tag to install, for example v1.1.0
                           (default: the latest stable GitHub Release).

Release binaries: this installer downloads precompiled, checksum-verified
binaries from GitHub Releases. It never runs a Go compiler on this server.
  --yes                    Do not ask for confirmation (still needs --mode).
  --skip-renew-test        Do not run `certbot renew --dry-run` at the end.
  --skip-verify            Do not run deploy/scripts/verify.sh at the end.
  -h, --help               Show this help.

Ports used: 80/tcp (certificate validation), 443/tcp (HTTPS CONNECT proxy),
8443/tcp by default (network configuration endpoint, configurable with
--api-port), 3478/udp and 5349/tcp (TURN), 49152-65535/udp (TURN relay media).
EOF
}

version_ge() { # version_ge HAVE WANT
	[[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" == "$2" ]]
}

# --- Arguments --------------------------------------------------------------
parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--mode)
			MODE="${2:-}"
			shift 2
			;;
		--domain)
			DOMAIN="${2:-}"
			shift 2
			;;
		--email)
			EMAIL="${2:-}"
			shift 2
			;;
		--ip)
			PUBLIC_IP="${2:-}"
			shift 2
			;;
		--realm)
			TURN_REALM="${2:-}"
			shift 2
			;;
		--staging)
			STAGING=1
			shift
			;;
		--distro-coturn)
			DISTRO_COTURN=1
			shift
			;;
		--coturn-version)
			COTURN_VERSION="${2:-}"
			shift 2
			;;
		--user-quota)
			USER_QUOTA="${2:-}"
			shift 2
			;;
		--total-quota)
			TOTAL_QUOTA="${2:-}"
			shift 2
			;;
		--max-bps)
			MAX_BPS="${2:-}"
			shift 2
			;;
		--bps-capacity)
			BPS_CAPACITY="${2:-}"
			shift 2
			;;
		--max-connections)
			MAX_CONN_PER_IP="${2:-}"
			shift 2
			;;
		--api-port)
			API_PORT="${2:-}"
			API_PORT_EXPLICIT=1
			shift 2
			;;
		--version)
			RELEASE_REQUEST="${2:-}"
			shift 2
			;;
		--yes)
			ASSUME_YES=1
			shift
			;;
		--skip-renew-test)
			SKIP_RENEW_TEST=1
			shift
			;;
		--skip-verify)
			SKIP_VERIFY=1
			shift
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			die "unknown option: $1 (see --help)"
			;;
		esac
	done

	if [[ -n "${MODE}" && "${MODE}" != "domain" && "${MODE}" != "ip" ]]; then
		die "--mode must be 'domain' or 'ip'"
	fi
	if [[ -n "${EMAIL}" ]] && [[ ! "${EMAIL}" =~ ^[^@[:space:]]+@[^@[:space:]]+$ ]]; then
		die "--email does not look like an address"
	fi

	local o
	for o in USER_QUOTA TOTAL_QUOTA MAX_BPS BPS_CAPACITY MAX_CONN_PER_IP PROXY_PORT API_PORT MAX_FDS; do
		[[ "${!o}" =~ ^[0-9]+$ ]] || die "--${o,,} must be numeric"
	done
	if [[ ${API_PORT_EXPLICIT} -eq 1 ]]; then
		((API_PORT >= 1024 && API_PORT <= 65535)) ||
			die "--api-port must be between 1024 and 65535 (ports below 1024 are reserved for system services)"
		case "${API_PORT}" in
		80 | "${PROXY_PORT}" | 3478 | 5349)
			die "--api-port ${API_PORT} is already used by another Dohcord-relay service"
			;;
		esac
	fi
}

# existing_api_port prints the Network Configuration API port recorded by a
# previous installation, or nothing on a fresh machine. HTTPS_LISTEN is the
# fallback for configurations written before NETWORK_CONFIG_PORT existed.
existing_api_port() {
	local port=""
	if [[ -r "${ETC_DIR}/config.env" ]]; then
		port="$(sed -n 's/^NETWORK_CONFIG_PORT=//p' "${ETC_DIR}/config.env" | tail -1)"
		if [[ -z "${port}" ]]; then
			port="$(sed -n 's/^HTTPS_LISTEN=//p' "${ETC_DIR}/config.env" | tail -1)"
			port="${port##*:}"
		fi
		if [[ ! "${port}" =~ ^[0-9]+$ ]]; then
			port="$(sed -n 's/^NETWORK_CONFIG_URL=//p' "${ETC_DIR}/config.env" | tail -1)"
			port="${port#*://}"
			port="${port%%/*}"
			port="${port##*:}"
		fi
	fi
	if [[ ! "${port}" =~ ^[0-9]+$ && -r "${INFO_FILE}" ]]; then
		port="$(sed -n 's/^API_PORT=//p' "${INFO_FILE}" | tail -1)"
	fi
	if [[ "${port}" =~ ^[0-9]+$ ]] && ((10#${port} >= 1 && 10#${port} <= 65535)); then
		printf '%s' "$((10#${port}))"
	fi
}

# api_port_owner prints the process name listening on a TCP port, if any.
api_port_owner() {
	ss -Hltnp "sport = :$1" 2>/dev/null |
		sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | head -1
}

# api_port_problem prints why PORT cannot be used by the Network Configuration
# API and returns 0. It returns 1 (with no output) when the port is usable.
api_port_problem() {
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
	80) printf '80 is used for ACME HTTP-01 certificate validation' ;;
	443 | "${PROXY_PORT}") printf '%d is used by the HTTPS CONNECT proxy' "${port}" ;;
	3478) printf '3478 is used by the TURN relay' ;;
	5349) printf '5349 is used by TURN over TLS' ;;
	esac
	case "${port}" in 80 | 443 | "${PROXY_PORT}" | 3478 | 5349) return 0 ;; esac
	if command -v ss >/dev/null 2>&1 && ss -Hltn "sport = :${port}" 2>/dev/null | grep -q .; then
		owner="$(api_port_owner "${port}")"
		# Our own endpoint may hold its configured port on a re-run.
		[[ "${owner}" == *dohcord-relay* ]] && return 1
		printf 'port %d is already in use%s; stop that service or choose another port' \
			"${port}" "${owner:+ by ${owner}}"
		return 0
	fi
	return 1
}

# prompt_api_port asks for the Network Configuration API port, starting from the
# value currently selected (8443 on a fresh install, the recorded port when
# re-running over an existing installation).
prompt_api_port() {
	local answer reason
	cat <<EOF

  Network Configuration API port

  Dohcord fetches its configuration from this small HTTPS endpoint. Its port is
  independent of the proxy (${PROXY_PORT}/tcp) and the TURN relay (3478/udp,
  5349/tcp), so any free port between 1024 and 65535 works. Press Enter to keep
  the port shown in brackets.

EOF
	while true; do
		read -r -p "  Network Configuration API port [${API_PORT}]: " answer || die "cancelled"
		answer="${answer:-${API_PORT}}"
		answer="${answer//[[:space:]]/}"
		if reason="$(api_port_problem "${answer}")"; then
			warn "${reason}"
			continue
		fi
		API_PORT="${answer}"
		ok "the Network Configuration API will listen on ${API_PORT}/tcp"
		return 0
	done
}

# select_api_port settles the Network Configuration API port before anything is
# written. An interactive run always shows the port and lets it be changed, with
# the recorded port (or 8443) as the default. --api-port changes it without
# asking, and --yes or a non-interactive run keeps whatever is configured.
select_api_port() {
	local existing reason
	existing="$(existing_api_port)"
	if [[ -n "${existing}" ]]; then
		# Remember it so a changed port retires the old firewall rule.
		PREVIOUS_API_PORT="${existing}"
		# A non-explicit run starts from the recorded port; --api-port wins.
		[[ ${API_PORT_EXPLICIT} -eq 1 ]] || API_PORT="${existing}"
	fi
	if [[ ${API_PORT_EXPLICIT} -eq 1 ]]; then
		reason="$(api_port_problem "${API_PORT}")" || true
		[[ -z "${reason}" ]] || die "--api-port ${API_PORT}: ${reason}"
		if [[ -n "${existing}" && "${API_PORT}" != "${existing}" ]]; then
			info "changing the Network Configuration API port from ${existing} to ${API_PORT}"
		else
			info "Network Configuration API port: ${API_PORT}"
		fi
		return 0
	fi
	if [[ ${ASSUME_YES} -eq 1 || ! -t 0 ]]; then
		if [[ -n "${existing}" ]]; then
			info "Network Configuration API port ${API_PORT} is already configured; keeping it"
			return 0
		fi
		reason="$(api_port_problem "${API_PORT}")" || true
		[[ -z "${reason}" ]] ||
			die "the default Network Configuration API port ${API_PORT} cannot be used (${reason}); pass --api-port PORT"
		info "Network Configuration API port: ${API_PORT} (default; --api-port changes it)"
		return 0
	fi
	prompt_api_port
}

# --- Address and domain validation ------------------------------------------
# is_public_ipv4 accepts only globally routable, unicast IPv4 addresses. Every
# special-purpose range from the IANA registry that must never be advertised as
# a relay address is rejected here, before anything is written.
is_public_ipv4() {
	local ip="$1" a b c d
	[[ "${ip}" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
	a=$((10#${BASH_REMATCH[1]}))
	b=$((10#${BASH_REMATCH[2]}))
	c=$((10#${BASH_REMATCH[3]}))
	d=$((10#${BASH_REMATCH[4]}))
	((a <= 255 && b <= 255 && c <= 255 && d <= 255)) || return 1
	((a == 0 || a == 10 || a == 127 || a >= 224)) && return 1
	((a == 169 && b == 254)) && return 1
	((a == 172 && b >= 16 && b <= 31)) && return 1
	((a == 192 && b == 168)) && return 1
	((a == 100 && b >= 64 && b <= 127)) && return 1
	((a == 192 && b == 0 && c == 0)) && return 1
	((a == 192 && b == 0 && c == 2)) && return 1
	((a == 198 && (b == 18 || b == 19))) && return 1
	((a == 198 && b == 51 && c == 100)) && return 1
	((a == 203 && b == 0 && c == 113)) && return 1
	return 0
}

is_domain_name() {
	local d="$1"
	[[ ${#d} -le 253 ]] || return 1
	[[ "${d}" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]]
}

detect_outbound_ip() {
	curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true
}

#" has_ipv6_egress reports whether this host has a global IPv6 address.
has_ipv6_egress() {
	ip -6 addr show scope global 2>/dev/null | grep -q 'inet6'
}

# dns_lookup RECORD NAME prints the resolved values, one per line.
dns_lookup() { # <a|aaaa> <name>
	python3 - "$1" "$2" <<'PY'
import socket, sys
kind, name = sys.argv[1], sys.argv[2]
family = socket.AF_INET if kind == "a" else socket.AF_INET6
try:
    infos = socket.getaddrinfo(name, None, family, socket.SOCK_STREAM)
except socket.gaierror:
    sys.exit(0)
seen = set()
for info in infos:
    addr = info[4][0]
    if addr not in seen:
        seen.add(addr)
        print(addr)
PY
}

# --- Wizard -----------------------------------------------------------------
wizard() {
	if [[ -z "${MODE}" ]]; then
		if [[ ${ASSUME_YES} -eq 1 || ! -t 0 ]]; then
			die "no --mode given and no terminal to ask on; use --mode domain --domain NAME or --mode ip --ip ADDRESS"
		fi
		cat <<'EOF'

  How should Dohcord reach this server?

    1. By domain name (recommended)
       Clients connect to https://relay.example.com:443 and the certificate
       is trusted everywhere. Needs a DNS A record pointing at this server.

    2. By public IPv4 address
       No DNS needed. The certificate covers the address and is short-lived,
       renewed automatically. Works with any client happy to trust an IP
       certificate.

EOF
		local choice
		while true; do
			read -r -p "  Choose 1 or 2: " choice || die "cancelled"
			case "${choice}" in
			1) MODE="domain" && break ;;
			2) MODE="ip" && break ;;
			*) warn "please answer 1 or 2" ;;
			esac
		done
	fi

	if [[ -z "${PUBLIC_IP}" ]]; then
		local detected
		detected="$(detect_outbound_ip || true)"
		if [[ -n "${detected}" && -t 0 && ${ASSUME_YES} -eq 0 ]]; then
			read -r -p "Public IPv4 [${detected}]: " PUBLIC_IP
			PUBLIC_IP="${PUBLIC_IP:-${detected}}"
		elif [[ -n "${detected}" ]]; then
			PUBLIC_IP="${detected}"
			info "detected public IPv4 ${PUBLIC_IP}"
		else
			[[ -t 0 ]] || die "cannot detect the public IPv4 address; pass --ip ADDRESS"
			read -r -p "Public IPv4: " PUBLIC_IP
		fi
	fi
	[[ -n "${PUBLIC_IP}" ]] || die "a public IPv4 address is required"
	if ! is_public_ipv4 "${PUBLIC_IP}"; then
		[[ -t 0 ]] || die "${PUBLIC_IP} is not a public IPv4 address (loopback, private, CGNAT, link-local, multicast and reserved ranges are rejected)"
		while ! is_public_ipv4 "${PUBLIC_IP}"; do
			warn "${PUBLIC_IP} is not a public IPv4 address (private, loopback, CGNAT and reserved ranges are rejected)"
			read -r -p "  Public IPv4 address of this server: " PUBLIC_IP || die "cancelled"
		done
	fi

	if [[ "${MODE}" == "domain" ]]; then
		if [[ -z "${DOMAIN}" ]]; then
			[[ -t 0 ]] || die "pass --domain NAME"
			read -r -p "Domain (for example relay.example.com): " DOMAIN
		fi
		DOMAIN="${DOMAIN,,}"
		DOMAIN="${DOMAIN%.}"
		while ! is_domain_name "${DOMAIN}"; do
			[[ -t 0 ]] || die "'${DOMAIN}' is not a valid fully qualified domain name"
			warn "'${DOMAIN}' is not a fully qualified domain name (for example relay.example.com)"
			read -r -p "  Domain: " DOMAIN || die "cancelled"
			DOMAIN="${DOMAIN,,}"
			DOMAIN="${DOMAIN%.}"
		done
		PUBLIC_HOST="${DOMAIN}"
	else
		PUBLIC_HOST="${PUBLIC_IP}"
	fi
	TURN_REALM="${TURN_REALM:-$( [[ "${MODE}" == "domain" ]] && echo "${DOMAIN}" || echo "dohcord.relay")}"

	# Upgrades keep the recorded port; fresh installations choose one here.
	select_api_port

	cat <<EOF

  This server will be reachable as

    address          ${PUBLIC_HOST} (${PUBLIC_IP})
    mode             ${MODE}
    HTTPS proxy      https://${PUBLIC_HOST}:${PROXY_PORT}
    network config   https://${PUBLIC_HOST}:${API_PORT}/network-config
    TURN (UDP)       turn:${PUBLIC_HOST}:3478?transport=udp
    TURN (TLS)       turns:${PUBLIC_HOST}:5349?transport=tcp

EOF
	if [[ ${ASSUME_YES} -eq 0 ]]; then
		local answer
		while true; do
			read -r -p "  Install with these settings? [Y/n]: " answer || die "cancelled"
			case "${answer}" in
			"" | y | Y | yes | YES) break ;;
			n | N | no | NO) die "cancelled; nothing was changed" ;;
			*) warn "please answer y or n" ;;
			esac
		done
	fi
}

# verify_dns makes sure the domain actually points at this server before a
# certificate is requested, and that any AAAA record is usable.
verify_dns() {
	[[ "${MODE}" == "domain" ]] || return 0

	local a_records
	a_records="$(dns_lookup a "${DOMAIN}" | tr '\n' ' ' || true)"
	[[ -n "${a_records// /}" ]] ||
		die "${DOMAIN} has no A record; create one pointing at ${PUBLIC_IP} and wait for DNS to propagate"
	if ! grep -qw "${PUBLIC_IP}" <<<"${a_records}"; then
		die "${DOMAIN} resolves to [${a_records% }], which is not ${PUBLIC_IP}; fix the A record (or pass the matching --ip) before installing"
	fi
	info "${DOMAIN} A record includes ${PUBLIC_IP}"

	local aaaa_records
	aaaa_records="$(dns_lookup aaaa "${DOMAIN}" | tr '\n' ' ' || true)"
	if [[ -n "${aaaa_records// /}" ]]; then
		if has_ipv6_egress; then
			info "${DOMAIN} also has AAAA [${aaaa_records% }] and this host has global IPv6, so dual-stack clients can connect"
		else
			die "${DOMAIN} has an AAAA record [${aaaa_records% }] but this host has no global IPv6 address. Clients that prefer IPv6 would fail. Remove the AAAA record (or add working IPv6 to the VPS), then re-run."
		fi
	fi
}

# --- Preconditions ----------------------------------------------------------
check_root_and_os() {
	[[ ${EUID} -eq 0 ]] || die "must run as root (use sudo)"

	[[ -r /etc/os-release ]] || die "cannot read /etc/os-release"
	# shellcheck disable=SC1091
	. /etc/os-release
	case "${ID}" in
	ubuntu | debian) ;;
	*) die "unsupported distribution '${ID}'; this installer targets Ubuntu and Debian" ;;
	esac
	info "distribution: ${PRETTY_NAME:-${ID} ${VERSION_ID:-}}"

	if [[ "${ID}" == ubuntu ]] && ! version_ge "${VERSION_ID:-0}" "22.04"; then
		warn "Ubuntu ${VERSION_ID} is older than 22.04; continuing, but it is untested"
	fi
	if [[ "${ID}" == debian ]] && ! version_ge "${VERSION_ID:-0}" "12"; then
		warn "Debian ${VERSION_ID} is older than 12; continuing, but it is untested"
	fi

	REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
	# The installer no longer compiles anything, but it still needs the
	# templates, units and helper scripts that ship in the repository archive.
	[[ -f "${REPO_DIR}/deploy/templates/config.env.tmpl" &&
		-f "${REPO_DIR}/deploy/systemd/dohcord-relay-api.service" &&
		-f "${REPO_DIR}/deploy/scripts/dohcord-relay-tls-deploy" ]] ||
		die "cannot find the installer resources; run this script from a Dohcord-relay release archive"

	command -v systemctl >/dev/null || die "systemd is required"
	info "repository: ${REPO_DIR}"
}

install_base_packages() {
	export DEBIAN_FRONTEND=noninteractive
	apt-get update -qq
	apt-get install -y -qq --no-install-recommends \
		ca-certificates curl openssl iproute2 procps python3 jq >/dev/null
	info "base packages present"
}

# check_ports refuses to take over a port that another service owns, so an
# existing web server is never disrupted.
# retire_legacy_units removes the service installed by the earlier,
# credentials-only design. That unit binds :80 and :443 permanently, and its
# process name matches this project's, so the port check would otherwise treat
# both busy ports as "ours" and leave the new services unable to start.
retire_legacy_units() {
	local unit retired=0
	local -a legacy=(dohcord-relay-credentials.service)
	for unit in "${legacy[@]}"; do
		[[ -f "/etc/systemd/system/${unit}" ]] || systemctl cat "${unit}" >/dev/null 2>&1 || continue
		info "found ${unit} from the earlier design; stopping and removing it"
		systemctl disable --now "${unit}" >/dev/null 2>&1 || true
		rm -f "/etc/systemd/system/${unit}"
		retired=1
	done
	if [[ ${retired} -eq 1 ]]; then
		systemctl daemon-reload >/dev/null 2>&1 || true
		if [[ -x /usr/local/bin/dohcord-relay-credentials ]]; then
			info "the old binary /usr/local/bin/dohcord-relay-credentials is kept but no longer runs"
		fi
	else
		info "no earlier Dohcord-relay service found"
	fi
}

check_ports() {
	local busy=0 conflicts=()

	check_one() { # proto port
		local proto="$1" port="$2" out=""
		if [[ "${proto}" == udp ]]; then
			out="$(ss -Hlun "sport = :${port}" 2>/dev/null || true)"
		else
			out="$(ss -Hltn "sport = :${port}" 2>/dev/null || true)"
		fi
		[[ -n "${out}" ]] || return 0
		# Our own services may already hold the port on a re-run.
		if [[ "${proto}" == udp ]]; then
			if ss -Hlunp "sport = :${port}" 2>/dev/null | grep -qE 'turnserver|dohcord-relay'; then
				return 0
			fi
		else
			if ss -Hltnp "sport = :${port}" 2>/dev/null | grep -qE 'squid|turnserver|dohcord-relay'; then
				return 0
			fi
		fi
		busy=1
		conflicts+=("${port}/${proto}")
	}

	check_one tcp 80
	check_one tcp "${PROXY_PORT}"
	check_one tcp "${API_PORT}"
	check_one udp 3478
	check_one tcp 5349

	if [[ ${busy} -eq 1 ]]; then
		printf '\n' >&2
		ss -lntup 2>/dev/null | grep -E ":(${PROXY_PORT}|80|${API_PORT}|3478|5349)\b" >&2 || true
		die "port(s) ${conflicts[*]} already in use by another service; stop or reconfigure it first (this installer never touches existing web servers)"
	fi
	info "ports 80/tcp, ${PROXY_PORT}/tcp, ${API_PORT}/tcp, 3478/udp and 5349/tcp are free"
}

detect_network() {
	PRIVATE_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}' || true)"
	[[ -n "${PRIVATE_IP}" ]] || PRIVATE_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
	[[ -n "${PRIVATE_IP}" ]] || die "cannot determine this host's primary IPv4 address"

	if ip -o -4 addr show | awk '{print $4}' | cut -d/ -f1 | grep -qx "${PUBLIC_IP}"; then
		RELAY_IP="${PUBLIC_IP}"
		EXTERNAL_IP="${PUBLIC_IP}"
		info "public IP ${PUBLIC_IP} is configured on this host"
	else
		# 1:1 NAT host (for example EC2): relays bind the private address,
		# and coturn must publish the public/private mapping.
		RELAY_IP="${PRIVATE_IP}"
		EXTERNAL_IP="${PUBLIC_IP}/${PRIVATE_IP}"
		info "public IP ${PUBLIC_IP} is not on this host; using 1:1 NAT mapping ${EXTERNAL_IP}"
	fi
	info "primary local address: ${PRIVATE_IP}"

	local seen
	seen="$(detect_outbound_ip || true)"
	if [[ -n "${seen}" && "${seen}" != "${PUBLIC_IP}" ]]; then
		warn "outbound traffic appears to leave from ${seen}, not ${PUBLIC_IP}; TURN allocations and the proxy may not be reachable at ${PUBLIC_IP}"
	fi
}

create_service_users() {
	if ! id -u turnserver >/dev/null 2>&1; then
		useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin turnserver
		info "created system user turnserver"
	fi
	if ! id -u dohcord-relay >/dev/null 2>&1; then
		useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin dohcord-relay
		info "created system user dohcord-relay"
	fi
	# coturn reads the certificate copies that belong to dohcord-relay.
	usermod -aG dohcord-relay turnserver
	info "turnserver added to the dohcord-relay group"
}

# --- Squid ------------------------------------------------------------------
install_squid() {
	export DEBIAN_FRONTEND=noninteractive
	apt-get install -y -qq --no-install-recommends squid >/dev/null

	# A GnuTLS build of Squid never sends intermediate certificates - upstream
	# documents the chain as OpenSSL-only - so a public certificate (Let's
	# Encrypt, whose leaf is signed by an intermediate) would be rejected by
	# every client with "unable to get local issuer certificate". Debian ships
	# the OpenSSL flavour as the squid-openssl package; on Ubuntu that package
	# replaces squid itself.
	pick_openssl_squid() {
		local candidate
		for candidate in /usr/sbin/squid-openssl "${SQUID_BINARY}"; do
			[[ -x "${candidate}" ]] || continue
			if "${candidate}" -v 2>&1 | grep -q -- '--with-openssl'; then
				SQUID_BINARY="${candidate}"
				return 0
			fi
			done
		return 1
	}
	SQUID_BINARY="$(command -v squid || echo /usr/sbin/squid)"
	[[ -x "${SQUID_BINARY}" ]] || die "the squid package did not install a squid binary"
	if ! pick_openssl_squid; then
		info "installing the OpenSSL flavour of Squid: the GnuTLS build cannot send the certificate chain"
		apt-get install -y -qq --no-install-recommends squid-openssl >/dev/null 2>&1 || true
		pick_openssl_squid ||
			die "no OpenSSL build of Squid is available here, and a GnuTLS build cannot send intermediate certificates: clients would reject the proxy certificate with 'unable to get local issuer certificate'. Install the 'squid-openssl' package (Debian/Ubuntu) or build Squid with --with-openssl, then re-run."
	fi
	info "squid binary: ${SQUID_BINARY} (OpenSSL build, so the full certificate chain is sent)"

	# Squid's distro unit must not fight ours for logs and the cache manager.
	systemctl disable --now squid.service >/dev/null 2>&1 || true

	SQUID_INSTALLED_VERSION="$("${SQUID_BINARY}" -v 2>&1 | sed -n 's/^Squid Cache: Version \([0-9][0-9.]*\).*/\1/p' | head -1)"
	[[ -n "${SQUID_INSTALLED_VERSION}" ]] ||
		SQUID_INSTALLED_VERSION="$("${SQUID_BINARY}" -v 2>&1 | grep -oE 'Version [0-9]+\.[0-9]+\.[0-9]+' | head -1 | awk '{print $2}')"
	[[ -n "${SQUID_INSTALLED_VERSION}" ]] || die "cannot determine the Squid version"
	info "squid version: ${SQUID_INSTALLED_VERSION}"

	# https_port for forward-proxy CONNECT needs a TLS-enabled Squid, and the
	# chain requirement above means it has to be the OpenSSL flavour.
	if ! "${SQUID_BINARY}" -v 2>&1 | grep -q -- '--with-openssl'; then
		die "${SQUID_BINARY} is not an OpenSSL build of Squid, so it cannot send the certificate chain and clients would reject the proxy certificate. Install squid-openssl or build Squid with --with-openssl."
	fi
	if ! version_ge "${SQUID_INSTALLED_VERSION}" "5.0"; then
		die "Squid ${SQUID_INSTALLED_VERSION} is too old; Squid 5 or newer is required for the https_port forward-proxy listener on this distribution"
	fi
	info "Squid has TLS support and is new enough for an https_port forward-proxy listener"

	if ! id -u proxy >/dev/null 2>&1; then
		useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin --user-group proxy
		info "created system user proxy"
	fi
}

# squid_tls_options prints the TLS 1.2 floor spelling this build accepts. The
# GnuTLS and OpenSSL backends reject each other's syntax outright, so the choice
# is made from the build options rather than guessed. Verified against Squid
# 6.14 (GnuTLS): "tls-min-version=1.2" is fatal there, while the explicit
# priority string below starts and refuses TLS 1.0/1.1.
squid_tls_options() {
	if "${SQUID_BINARY}" -v 2>&1 | grep -q -- '--with-gnutls'; then
		echo 'tls-options=NORMAL:-VERS-TLS1.0:-VERS-TLS1.1'
	elif "${SQUID_BINARY}" -v 2>&1 | grep -q -- '--with-openssl'; then
		echo 'options=NO_TLSv1,NO_TLSv1_1'
	else
		die "cannot tell whether Squid was built with GnuTLS or OpenSSL"
	fi
}

# AppArmor, when the distribution ships a Squid profile, confines it to
# /etc/squid and /var/log/squid. Our configuration and logs live elsewhere, so
# the local override is extended. Nothing is disabled.
configure_apparmor() {
	local profile="/etc/apparmor.d/usr.sbin.squid"
	[[ -f "${profile}" ]] || return 0

	local local_override="/etc/apparmor.d/local/usr.sbin.squid"
	mkdir -p "$(dirname "${local_override}")"
	if grep -q 'dohcord-relay' "${local_override}" 2>/dev/null; then
		info "AppArmor local override already allows the Dohcord-relay paths"
		return 0
	fi
	cat >>"${local_override}" <<'EOF'

# Dohcord-relay: configuration, certificate and log paths
/etc/dohcord-relay/** r,
/var/log/dohcord-relay/** rw,
/run/dohcord-relay-squid/** rw,
EOF
	if command -v apparmor_parser >/dev/null 2>&1; then
		apparmor_parser -r "${profile}" >/dev/null 2>&1 ||
			warn "could not reload the Squid AppArmor profile; check /etc/apparmor.d/local/usr.sbin.squid if Squid cannot read its configuration"
		info "extended the Squid AppArmor profile for /etc/dohcord-relay"
	else
		warn "AppArmor profile present but apparmor_parser is missing; Squid may be confined"
	fi
}

render_squid_conf() {
	local target="${ETC_DIR}/squid.conf" tls_options
	tls_options="$(squid_tls_options)"
	info "TLS 1.2 floor for this Squid build: ${tls_options}"
	sed -e "s|@PROXY_PORT@|${PROXY_PORT}|g" \
		-e "s|@TLS_OPTIONS@|${tls_options}|g" \
		-e "s|@SQUID_PEM@|${TLS_DIR}/squid.pem|g" \
		-e "s|@PUBLIC_HOST@|${PUBLIC_HOST}|g" \
		-e "s|@ALLOW_FILE@|${ETC_DIR}/squid-allow.conf|g" \
		-e "s|@LOG_DIR@|${SQUID_LOG_DIR}|g" \
		-e "s|@RUN_DIR@|${SQUID_RUN_DIR}|g" \
		-e "s|@MAX_CONN_PER_IP@|${MAX_CONN_PER_IP}|g" \
		-e "s|@MAX_FDS@|${MAX_FDS}|g" \
		-e "s|@READ_TIMEOUT@|${READ_TIMEOUT}|g" \
		-e "s|@CLIENT_LIFETIME@|${CLIENT_LIFETIME}|g" \
		-e "s|@BLOCKED_IP@|${PUBLIC_IP}/32|g" \
		-e "s|@SQUID_USER@|proxy|g" \
		-e "s|@SQUID_GROUP@|proxy|g" \
		"${REPO_DIR}/deploy/templates/squid.conf.tmpl" >"${target}.new"

	chown root:root "${target}.new"
	chmod 0644 "${target}.new"
	mv "${target}.new" "${target}"
	info "wrote ${target}"
}

install_squid_unit() {
	sed -e "s|@SQUID_BINARY@|${SQUID_BINARY}|g" \
		"${REPO_DIR}/deploy/systemd/dohcord-relay-squid.service" >"/etc/systemd/system/${SQUID_UNIT}"
	chmod 0644 "/etc/systemd/system/${SQUID_UNIT}"
	info "installed /etc/systemd/system/${SQUID_UNIT} (exec ${SQUID_BINARY})"
}

# --- coturn -----------------------------------------------------------------
install_coturn() {
	if [[ ${DISTRO_COTURN} -eq 1 ]]; then
		export DEBIAN_FRONTEND=noninteractive
		apt-get install -y -qq --no-install-recommends coturn >/dev/null
		TURN_BINARY="$(command -v turnserver)"
		# The distribution unit would fight ours over 3478/5349.
		systemctl disable --now coturn.service >/dev/null 2>&1 || true
		info "installed distribution coturn: ${TURN_BINARY}"
	else
		# Re-runs should not rebuild from source when the pinned release is
		# already installed.
		local existing=""
		if [[ -x /usr/local/bin/turnserver ]]; then
			existing="$(/usr/local/bin/turnserver --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
		fi
		if [[ -n "${existing}" && "${existing}" == "${COTURN_VERSION}" ]]; then
			TURN_BINARY="/usr/local/bin/turnserver"
			info "coturn ${existing} is already installed at ${TURN_BINARY}; skipping the source build"
		else
			export DEBIAN_FRONTEND=noninteractive
			apt-get install -y -qq --no-install-recommends \
				build-essential libssl-dev libevent-dev pkg-config >/dev/null
			local tmp
			tmp="$(mktemp -d)"
			info "building coturn ${COTURN_VERSION} from source (this takes a couple of minutes)"
			curl -fsSL "https://github.com/coturn/coturn/archive/refs/tags/${COTURN_VERSION}.tar.gz" \
				-o "${tmp}/coturn.tar.gz" ||
				die "cannot download coturn ${COTURN_VERSION}"
			if [[ "${COTURN_VERSION}" == "4.18.0" ]]; then
				echo "${COTURN_SHA256}  ${tmp}/coturn.tar.gz" | sha256sum -c - >/dev/null ||
					die "coturn archive checksum mismatch; refusing to build"
			else
				warn "no pinned checksum for coturn ${COTURN_VERSION}; continuing without verification"
			fi
			tar -C "${tmp}" -xzf "${tmp}/coturn.tar.gz"
			(
				cd "${tmp}/coturn-${COTURN_VERSION}"
				./configure --prefix=/usr/local >/dev/null
				make -j"$(nproc)" >/dev/null
				make install >/dev/null
			) || die "building coturn ${COTURN_VERSION} failed"
			rm -rf "${tmp}"
			TURN_BINARY="/usr/local/bin/turnserver"
			[[ -x "${TURN_BINARY}" ]] || die "coturn binary not found at ${TURN_BINARY}"
			info "installed upstream coturn at ${TURN_BINARY}"
		fi
	fi

	local version
	version="$("${TURN_BINARY}" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
	[[ -n "${version}" ]] || die "cannot determine the coturn version from ${TURN_BINARY} --version"
	if ! version_ge "${version}" "4.6.0"; then
		die "coturn ${version} is too old; install a current release with the default (source) mode"
	fi
	if ! version_ge "${version}" "4.16.0"; then
		warn "coturn ${version} predates several relay security fixes; the default source install ships ${COTURN_VERSION}"
	fi
	info "coturn version: ${version}"
	COTURN_INSTALLED_VERSION="${version}"
}

# coturn 4.18 replaced "no-tlsv1"/"no-tlsv1_1" with minimum-version flags and its
# config parser rejects the old bare spelling, while 4.6.x does not know the new
# ones. Keep only the form this binary understands.
adapt_tls_version_options() {
	local conf="$1" help_text="$2"
	if grep -qE -- '--tlsv1([^_a-z0-9-]|$)' <<<"${help_text}"; then
		sed -i -E 's/^no-tlsv1(_1)?$/#\0/' "${conf}"
		info "TLS version floor expressed with coturn's tlsv1/tlsv1_1 options"
	else
		sed -i -E 's/^tlsv1(_1)?=0$/#\0/' "${conf}"
		sed -i -E 's/^#(no-tlsv1(_1)?)$/\1/' "${conf}"
		info "TLS version floor expressed with coturn's no-tlsv1/no-tlsv1_1 options"
	fi
}

# Rejects a configuration containing options this coturn binary does not know,
# so an unsupported security option can never be silently ignored.
validate_coturn_options() {
	local conf="$1" help_text="$2" opt missing=0
	if [[ -z "${help_text}" ]]; then
		warn "coturn --help produced no output; skipping option validation"
		return 0
	fi

	while read -r opt; do
		[[ -n "${opt}" ]] || continue
		if ! grep -qE -- "--${opt}([^a-z0-9_-]|$)" <<<"${help_text}"; then
			warn "coturn ${COTURN_INSTALLED_VERSION} does not support option '${opt}'"
			missing=1
		fi
	done < <(grep -vE '^[[:space:]]*(#|$)' "${conf}" | sed -E 's/=.*$//' | sort -u)

	[[ ${missing} -eq 0 ]] || die "the generated turnserver.conf uses options this coturn build does not support"
	info "every option in turnserver.conf is supported by coturn ${COTURN_INSTALLED_VERSION}"
}

write_turn_secret() {
	local secret_file="${ETC_DIR}/turn-secret"
	install -d -m 0755 -o root -g root "${ETC_DIR}"

	if [[ -s "${secret_file}" ]]; then
		info "keeping the existing TURN shared secret"
	else
		# 32 random bytes, hex encoded: no characters that need escaping in the
		# coturn configuration file.
		(umask 077 && openssl rand -hex 32 >"${secret_file}")
		info "generated a new TURN shared secret at ${secret_file}"
	fi
	chown root:root "${secret_file}"
	chmod 0640 "${secret_file}"
	# The endpoint (group dohcord-relay) and nobody else can read it.
	chgrp dohcord-relay "${secret_file}"
}

render_turnserver_conf() {
	local secret template="${REPO_DIR}/deploy/templates/turnserver.conf.tmpl" target="${ETC_DIR}/turnserver.conf"
	secret="$(cat "${ETC_DIR}/turn-secret")"

	sed -e "s|@PUBLIC_IP@|${PUBLIC_IP}|g" \
		-e "s|@LISTENING_IP@|${LISTENING_IP}|g" \
		-e "s|@RELAY_IP@|${RELAY_IP}|g" \
		-e "s|@EXTERNAL_IP@|${EXTERNAL_IP}|g" \
		-e "s|@SECRET@|${secret}|g" \
		-e "s|@REALM@|${TURN_REALM}|g" \
		-e "s|@CERT_FILE@|${TLS_DIR}/fullchain.pem|g" \
		-e "s|@KEY_FILE@|${TLS_DIR}/privkey.pem|g" \
		-e "s|@USER_QUOTA@|${USER_QUOTA}|g" \
		-e "s|@TOTAL_QUOTA@|${TOTAL_QUOTA}|g" \
		-e "s|@MAX_BPS@|${MAX_BPS}|g" \
		-e "s|@BPS_CAPACITY@|${BPS_CAPACITY}|g" \
		-e "s|@LOG_FILE@|${TURN_LOG_DIR}/turnserver.log|g" \
		-e "s|@PID_FILE@|${TURN_RUN_DIR}/turnserver.pid|g" \
		"${template}" >"${target}.new"

	local help_text
	help_text="$("${TURN_BINARY}" --help 2>&1 || true)"
	adapt_tls_version_options "${target}.new" "${help_text}"

	chown root:turnserver "${target}.new"
	chmod 0640 "${target}.new"
	mv "${target}.new" "${target}"
	info "wrote ${target}"

	validate_coturn_options "${target}" "${help_text}"
}

install_coturn_unit() {
	sed -e "s|@TURN_BINARY@|${TURN_BINARY}|g" \
		"${REPO_DIR}/deploy/systemd/dohcord-relay-coturn.service" >"/etc/systemd/system/${COTURN_UNIT}"
	chmod 0644 "/etc/systemd/system/${COTURN_UNIT}"
	info "installed /etc/systemd/system/${COTURN_UNIT}"
}

# --- release binaries -------------------------------------------------------
# The installer never compiles. It downloads the archive for this architecture
# from the requested GitHub Release, verifies it against checksums.txt and only
# then replaces anything. A failed download or checksum leaves the installed
# binaries untouched.
cleanup_release_workdir() {
	if [[ -n "${RELEASE_WORKDIR}" && -d "${RELEASE_WORKDIR}" ]]; then
		rm -rf -- "${RELEASE_WORKDIR}"
	fi
	RELEASE_WORKDIR=""
}

# download_release_url URL DEST fetches a release file. Only HTTPS is accepted
# in normal use; file:// and loopback HTTP are allowed for the test suite.
download_release_url() {
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
		die "refusing to download from ${url}: only HTTPS (or a local test mirror) is allowed"
		;;
	esac
}

# normalize_release_tag prints a vX.Y.Z tag. It returns 1 for empty input, for
# "latest" and for anything that is not strict semantic versioning, so callers
# decide whether that means "resolve latest" or "reject the request".
normalize_release_tag() {
	local tag="$1"
	[[ -n "${tag}" && "${tag}" != "latest" ]] || return 1
	[[ "${tag}" == v* ]] || tag="v${tag}"
	[[ "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
	printf '%s' "${tag}"
}

latest_release_tag() {
	local json tag
	json="$(mktemp)"
	if ! download_release_url "${LATEST_RELEASE_API}" "${json}"; then
		rm -f "${json}"
		die "cannot query the latest release from ${LATEST_RELEASE_API}; pass --version vX.Y.Z"
	fi
	if command -v jq >/dev/null 2>&1; then
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
	[[ -n "${tag}" ]] ||
		die "the release service did not report a latest release tag; pass --version vX.Y.Z"
	normalize_release_tag "${tag}"
}

resolve_release_tag() {
	local tag
	if [[ -n "${RELEASE_REQUEST}" && "${RELEASE_REQUEST}" != "latest" ]]; then
		tag="$(normalize_release_tag "${RELEASE_REQUEST}")" ||
			die "'${RELEASE_REQUEST}' is not a semantic version tag (expected vX.Y.Z, for example v1.1.0)"
		RELEASE_TAG="${tag}"
		info "release requested: ${RELEASE_TAG}"
	else
		RELEASE_TAG="$(latest_release_tag)" ||
			die "cannot determine the latest stable release; pass --version vX.Y.Z"
		info "latest stable release: ${RELEASE_TAG}"
	fi
}

native_release_arch() {
	case "${1:-$(uname -m)}" in
	x86_64 | amd64) printf 'amd64' ;;
	aarch64 | arm64) printf 'arm64' ;;
	*) return 1 ;;
	esac
}

detect_release_arch() {
	local machine
	[[ "$(uname -s)" == "Linux" ]] ||
		die "release binaries are published for Linux only (this host is $(uname -s))"
	machine="$(uname -m)"
	RELEASE_ARCH="$(native_release_arch "${machine}")" ||
		die "unsupported architecture '${machine}': Dohcord-relay publishes linux/amd64 and linux/arm64 release binaries"
	info "release target: linux/${RELEASE_ARCH}"
}

# migrate_legacy_binary moves a pre-rename server binary out of the way. Older
# releases installed the daemon as /usr/local/bin/dohcord-relay; that name now
# belongs to the management console, so the existing executable is copied to
# /usr/local/bin/dohcord-relayd before anything is replaced. Copying (rather than
# moving) also keeps a running service's inode valid until it is restarted.
migrate_legacy_binary() {
	[[ -x "${DAEMON}" ]] && return 0
	[[ -f "${CLI}" && ! -L "${CLI}" ]] || return 0
	install -m 0755 -o root -g root "${CLI}" "${DAEMON}"
	info "migrated the previous server binary ${CLI} to ${DAEMON}"
}

# backup_current_binaries copies the installed executables so a failed upgrade
# can be undone. Configuration, certificates and policies are not touched.
backup_current_binaries() {
	if [[ ! -e "${DAEMON}" && ! -e "${CLI}" ]]; then
		return 0
	fi
	local dir
	dir="/var/backups/dohcord-relay/binaries-$(date +%Y%m%d-%H%M%S)"
	mkdir -p "${dir}"
	chmod 0700 "${dir}"
	[[ -e "${DAEMON}" ]] && cp -a "${DAEMON}" "${dir}/"
	[[ -e "${CLI}" ]] && cp -a "${CLI}" "${dir}/"
	BIN_BACKUP_DIR="${dir}"
	info "previous binaries backed up to ${dir}"
}

# restore_previous_binaries puts the backed-up executables back and restarts the
# API service. Used only when a freshly installed binary fails to start.
restore_previous_binaries() {
	[[ -n "${BIN_BACKUP_DIR}" && -d "${BIN_BACKUP_DIR}" ]] || return 1
	local restored=0
	if [[ -f "${BIN_BACKUP_DIR}/dohcord-relayd" ]]; then
		install -m 0755 -o root -g root "${BIN_BACKUP_DIR}/dohcord-relayd" "${DAEMON}"
		restored=1
	fi
	if [[ -f "${BIN_BACKUP_DIR}/dohcord-relay" ]]; then
		install -m 0755 -o root -g root "${BIN_BACKUP_DIR}/dohcord-relay" "${CLI}"
		restored=1
	fi
	((restored)) || return 1
	systemctl restart "${API_UNIT}" >/dev/null 2>&1 || true
	info "restored the previous executables from ${BIN_BACKUP_DIR}"
}

download_release_binaries() {
	local asset base url checksums unpack file magic
	base="${RELEASE_BASE_URL%/}"
	asset="dohcord-relay_linux_${RELEASE_ARCH}.tar.gz"
	url="${base}/${RELEASE_TAG}/${asset}"

	cleanup_release_workdir
	RELEASE_WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/dohcord-relay-release.XXXXXX")"
	info "downloading ${url}"
	download_release_url "${url}" "${RELEASE_WORKDIR}/${asset}" ||
		die "cannot download ${asset} for ${RELEASE_TAG}; the installed binaries were not changed"
	checksums="${RELEASE_WORKDIR}/checksums.txt"
	download_release_url "${base}/${RELEASE_TAG}/checksums.txt" "${checksums}" ||
		die "cannot download checksums.txt for ${RELEASE_TAG}; refusing to install unverified binaries"

	if ! grep -qE "^[0-9a-fA-F]{64}[[:space:]]+\*?${asset}$" "${checksums}"; then
		die "checksums.txt has no SHA256 entry for ${asset}; refusing to install unverified binaries"
	fi
	if ! (cd "${RELEASE_WORKDIR}" && sha256sum -c --ignore-missing checksums.txt >/dev/null); then
		die "SHA256 verification failed for ${asset}; the installed binaries were not changed"
	fi
	info "SHA256 verified ${asset}"

	unpack="${RELEASE_WORKDIR}/unpacked"
	mkdir -p "${unpack}"
	tar -xzf "${RELEASE_WORKDIR}/${asset}" -C "${unpack}" --no-same-owner ||
		die "cannot extract ${asset}; the installed binaries were not changed"
	for file in dohcord-relayd dohcord-relay; do
		[[ -f "${unpack}/${file}" && ! -L "${unpack}/${file}" ]] ||
			die "${asset} does not contain a regular ${file} file"
		magic="$(od -An -tx1 -N4 "${unpack}/${file}" | tr -d ' \n')"
		[[ "${magic}" == "7f454c46" ]] ||
			die "${asset} contains ${file} that is not a Linux executable"
	done

	# On the native architecture the binaries can be checked directly. The tag
	# embedded at build time must match the release being installed.
	if [[ "${RELEASE_ARCH}" == "$(native_release_arch "$(uname -m)")" ]]; then
		"${unpack}/dohcord-relayd" -version >"${RELEASE_WORKDIR}/daemon-version" 2>&1 ||
			die "the downloaded dohcord-relayd cannot run on this host; the installed binaries were not changed"
		grep -Fq " ${RELEASE_TAG} " "${RELEASE_WORKDIR}/daemon-version" ||
			die "the downloaded dohcord-relayd does not report ${RELEASE_TAG}; refusing a mismatched release"
	fi

	RELEASE_ARCHIVE_DIR="${unpack}"
}

install_release_binaries() {
	detect_release_arch
	resolve_release_tag
	download_release_binaries
	migrate_legacy_binary
	backup_current_binaries

	# Both executables are staged before either is moved into place.
	install -m 0755 -o root -g root "${RELEASE_ARCHIVE_DIR}/dohcord-relayd" "${DAEMON}.new"
	install -m 0755 -o root -g root "${RELEASE_ARCHIVE_DIR}/dohcord-relay" "${CLI}.new"
	mv -f "${DAEMON}.new" "${DAEMON}"
	mv -f "${CLI}.new" "${CLI}"

	cleanup_release_workdir
	info "installed ${RELEASE_TAG} (linux/${RELEASE_ARCH}): ${DAEMON} and ${CLI}"
}

# Kept for callers written against the previous source-build name.
build_endpoint() { install_release_binaries; }

render_config_env() {
	local target="${ETC_DIR}/config.env"
	local rendered="${target}.rendered"
	sed -e "s|@PUBLIC_HOST@|${PUBLIC_HOST}|g" \
		-e "s|@PROXY_PORT@|${PROXY_PORT}|g" \
		-e "s|@API_PORT@|${API_PORT}|g" \
		-e "s|@TLS_DIR@|${TLS_DIR}|g" \
		-e "s|@SQUID_BINARY@|${SQUID_BINARY}|g" \
		"${REPO_DIR}/deploy/templates/config.env.tmpl" >"${rendered}"

	if [[ -f "${target}" ]] && grep -q '^HTTPS_PROXY_URL=' "${target}"; then
		# Keep operator tuning, but refresh the public identity and ports so a
		# change of domain/IP is picked up. The listen address keeps its host
		# part and only takes the selected port.
		local listen_addr=":${API_PORT}" current_listen
		current_listen="$(sed -n 's/^HTTPS_LISTEN=//p' "${target}" | tail -1)"
		[[ "${current_listen}" == *:* ]] && listen_addr="${current_listen%:*}:${API_PORT}"
		sed -i -E \
			-e "s|^HTTPS_PROXY_URL=.*|HTTPS_PROXY_URL=https://${PUBLIC_HOST}:${PROXY_PORT}|" \
			-e "s|^NETWORK_CONFIG_PORT=.*|NETWORK_CONFIG_PORT=${API_PORT}|" \
			-e "s|^NETWORK_CONFIG_URL=.*|NETWORK_CONFIG_URL=https://${PUBLIC_HOST}:${API_PORT}/network-config|" \
			-e "s|^HTTPS_LISTEN=.*|HTTPS_LISTEN=${listen_addr}|" \
			-e "s|^TURN_URLS=.*|TURN_URLS=turn:${PUBLIC_HOST}:3478?transport=udp,turns:${PUBLIC_HOST}:5349?transport=tcp|" \
			-e "s|^SQUID_BINARY=.*|SQUID_BINARY=${SQUID_BINARY}|" \
			"${target}"
		# Add any setting this version needs that the file predates (for example
		# after upgrading from the credentials-only design).
		local line key
		while IFS= read -r line; do
			[[ "${line}" == *=* ]] || continue
			key="${line%%=*}"
			[[ "${key}" =~ ^[A-Z0-9_]+$ ]] || continue
			if ! grep -q "^${key}=" "${target}"; then
				printf '%s\n' "${line}" >>"${target}"
				info "added ${key} to ${target}"
			fi
		done <"${rendered}"
		info "updated the public endpoints in ${target}"
	else
		chown root:dohcord-relay "${rendered}"
		chmod 0640 "${rendered}"
		mv "${rendered}" "${target}"
		info "wrote ${target}"
	fi
	rm -f "${rendered}"
	install -d -m 0755 -o root -g root "${WEBROOT}"
}

install_api_unit() {
	install -m 0644 "${REPO_DIR}/deploy/systemd/dohcord-relay-api.service" \
		"/etc/systemd/system/${API_UNIT}"
	info "installed /etc/systemd/system/${API_UNIT}"
}

# install_management_tools puts the small operator-facing pieces where they
# survive deleting the checkout: the management console, the verification
# suite, the uninstaller and a copy of the bootstrap installer. None of them
# change how traffic is handled; they drive the services installed above.
install_management_tools() {
	install -d -m 0755 -o root -g root "${LIB_DIR}"
	if [[ -f "${REPO_DIR}/deploy/scripts/dohcord-relay-manager.sh" ]]; then
		install -m 0755 "${REPO_DIR}/deploy/scripts/dohcord-relay-manager.sh" "${MANAGER_SCRIPT}"
		info "installed ${MANAGER_SCRIPT}"
		# dohcord-relay is the console; keep the previous name working as an alias.
		ln -sfn "${CLI}" "${MANAGER_ALIAS}"
		info "linked ${MANAGER_ALIAS} -> ${CLI}"
	else
		warn "the management console is missing from this checkout; skipping it"
	fi
	install -m 0755 "${REPO_DIR}/deploy/scripts/verify.sh" "${LIB_DIR}/verify.sh"
	if [[ -f "${REPO_DIR}/uninstall.sh" ]]; then
		install -m 0755 "${REPO_DIR}/uninstall.sh" "${LIB_DIR}/uninstall.sh"
	fi
	if [[ -f "${REPO_DIR}/install.sh" ]]; then
		# Repair and update re-use the bootstrap, which fetches a complete tree.
		install -m 0755 "${REPO_DIR}/install.sh" "${LIB_DIR}/bootstrap.sh"
	fi
	ok "management console and verification suite installed to ${LIB_DIR}"
}

# write_install_info records what the management console reports. It contains no
# secrets: only the public endpoints and how this relay was installed.
write_install_info() {
	local ref stamp
	ref="${DOHCORD_RELAY_REF:-main}"
	if command -v git >/dev/null 2>&1 && [[ -d "${REPO_DIR}/.git" ]]; then
		ref="$(git -C "${REPO_DIR}" rev-parse --short HEAD 2>/dev/null || printf '%s' "${ref}")"
	fi
	stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	umask 022
	cat >"${INFO_FILE}.new" <<EOF
INSTALLER_VERSION=${INSTALLER_VERSION}
RELEASE_VERSION=${RELEASE_TAG:-unknown}
RELEASE_ARCH=${RELEASE_ARCH:-unknown}
INSTALLED_AT=${stamp}
MODE=${MODE}
PUBLIC_HOST=${PUBLIC_HOST}
PUBLIC_IP=${PUBLIC_IP}
PROXY_PORT=${PROXY_PORT}
API_PORT=${API_PORT}
REPO_REF=${ref}
EOF
	chown root:root "${INFO_FILE}.new"
	chmod 0644 "${INFO_FILE}.new"
	mv "${INFO_FILE}.new" "${INFO_FILE}"
	info "wrote ${INFO_FILE}"
}

install_policy_files() {
	local name src dst
	for name in allowed-domains.txt destination-policy.conf; do
		src="${REPO_DIR}/deploy/templates/${name}"
		dst="${ETC_DIR}/${name}"
		if [[ -f "${dst}" ]]; then
			info "keeping existing ${dst}"
		else
			install -m 0644 -o root -g root "${src}" "${dst}"
			info "wrote ${dst}"
		fi
	done
}

# --- TLS --------------------------------------------------------------------
setup_certbot() {
	local installed=""
	if command -v certbot >/dev/null 2>&1; then
		installed="$(certbot --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
		if [[ -n "${installed}" ]] && version_ge "${installed}" "5.4.0"; then
			CERTBOT="$(command -v certbot)"
			info "using certbot ${installed}"
			return 0
		fi
		info "existing certbot ${installed:-unknown} is older than 5.4 (needed for IP certificates); installing a private copy"
	fi

	export DEBIAN_FRONTEND=noninteractive
	apt-get install -y -qq --no-install-recommends python3-venv python3-pip >/dev/null
	python3 -m venv /opt/dohcord-relay-certbot
	/opt/dohcord-relay-certbot/bin/pip install --quiet --upgrade pip >/dev/null
	/opt/dohcord-relay-certbot/bin/pip install --quiet 'certbot>=5.4,<6' >/dev/null ||
		die "cannot install certbot 5.4+ from PyPI"
	CERTBOT="/opt/dohcord-relay-certbot/bin/certbot"
	info "installed $("${CERTBOT}" --version)"
}

install_deploy_hook() {
	sed -e "s|@PUBLIC_IP@|${PUBLIC_IP}|g" \
		-e "s|@PUBLIC_HOST@|${PUBLIC_HOST}|g" \
		-e "s|@MODE@|${MODE}|g" \
		"${REPO_DIR}/deploy/scripts/dohcord-relay-tls-deploy" >"${HOOK}.new"
	chown root:root "${HOOK}.new"
	chmod 0755 "${HOOK}.new"
	mv "${HOOK}.new" "${HOOK}"
	info "installed ${HOOK}"
}

# port80_pid prints the pid of the process listening on TCP port 80, if any.
port80_pid() {
	ss -Hltnp 'sport = :80' 2>/dev/null | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2
}

# unit_of_pid prints the systemd unit a process belongs to, if any.
unit_of_pid() {
	[[ -n "$1" && -r "/proc/$1/cgroup" ]] || return 1
	grep -oE '[A-Za-z0-9@._:\\-]+\.service' "/proc/$1/cgroup" 2>/dev/null | head -1
}

# responder_answers NAME succeeds when the challenge file NAME is served on
# port 80 by whatever is holding the port.
responder_answers() {
	[[ "$(curl -fsS --max-time 2 "http://127.0.0.1/.well-known/acme-challenge/$1" 2>/dev/null || true)" == "ok" ]]
}

# is_our_binary PID succeeds when PID runs a Dohcord-relay executable. The
# prefix match also covers the binary shipped by the earlier, credentials-only
# design (/usr/local/bin/dohcord-relay-credentials), which binds :80 and :443.
is_our_binary() {
	[[ -n "$1" && -r "/proc/$1/exe" ]] || return 1
	local exe
	exe="$(readlink -f "/proc/$1/exe" 2>/dev/null)" || return 1
	[[ "$(basename "${exe}")" == dohcord-relay* ]]
}

start_acme_bootstrap() {
	install -d -m 0755 -o root -g root "${WEBROOT}"
	[[ -n "${BOOTSTRAP_PID}" ]] && return 0

	local probe_dir="${WEBROOT}/.well-known/acme-challenge"
	local holder
	# port80_pid exits non-zero when nothing is listening, which is the normal
	# case here; `|| true` keeps errexit from treating that as a failure.
	holder="$(port80_pid || true)"
	if [[ -n "${holder}" ]]; then
		# An interrupted run can leave its own responder behind. It belongs to
		# this project, so reuse it when it works and replace it when it does not;
		# anything else on port 80 is someone else's service and is never touched.
		local holder_unit
		holder_unit="$(unit_of_pid "${holder}" || true)"
		if systemctl is-active --quiet "${API_UNIT}"; then
			info "port 80 is already served by ${API_UNIT}"
			return 0
		elif [[ -n "${holder_unit}" && "${holder_unit}" == dohcord-relay-* && "${holder_unit}" != "${API_UNIT}" ]]; then
			# An earlier Dohcord-relay service (the credentials-only design) still
			# runs and binds :80 and :443. It is ours, so retire it instead of
			# asking the operator to hunt it down.
			info "retiring ${holder_unit} from the earlier design; it holds port 80"
			systemctl disable --now "${holder_unit}" >/dev/null 2>&1 || true
			for _ in $(seq 1 25); do
				[[ -z "$(port80_pid || true)" ]] && break
				sleep 0.2
			done
		elif is_our_binary "${holder}"; then
			install -d -m 0755 -o root -g root "${probe_dir}"
			local reused="probe${RANDOM}${RANDOM}"
			printf 'ok\n' >"${probe_dir}/${reused}"
			if responder_answers "${reused}"; then
				rm -f "${probe_dir}/${reused}"
				BOOTSTRAP_PID="${holder}"
				info "a previous ACME responder (pid ${holder}) is still running and answering; reusing it"
				return 0
			fi
			rm -f "${probe_dir}/${reused}"
			info "replacing a stopped ACME responder left behind by an earlier run (pid ${holder})"
			kill "${holder}" 2>/dev/null || true
			for _ in $(seq 1 25); do
				[[ -z "$(port80_pid || true)" ]] && break
				sleep 0.2
			done
		else
			printf '  listener: %s\n' "$(ss -Hltnp 'sport = :80' 2>/dev/null | head -1)" >&2
			die "port 80 is used by another service; stop it or move it before installing (this installer never reconfigures existing web servers)"
		fi
		if [[ -n "$(port80_pid)" ]]; then
			die "port 80 is still in use after stopping a stale responder; check 'ss -Hltnp \"sport = :80\"'"
		fi
	fi

	local probe="probe${RANDOM}${RANDOM}"
	info "starting the ACME HTTP-01 responder on port 80"
	install -d -m 0755 -o root -g root "${probe_dir}"
	printf 'ok\n' >"${probe_dir}/${probe}"
	"${DAEMON}" -config "${ETC_DIR}/config.env" -acme-only >>"${LOG_DIR}/acme-bootstrap.log" 2>&1 &
	BOOTSTRAP_PID=$!

	for _ in $(seq 1 60); do
		if [[ "$(curl -fsS --max-time 2 "http://127.0.0.1/.well-known/acme-challenge/${probe}" 2>/dev/null || true)" == "ok" ]]; then
			rm -f "${probe_dir}/${probe}"
			info "ACME responder is answering on port 80"
			return 0
		fi
		sleep 0.5
	done
	rm -f "${probe_dir}/${probe}"
	die "the ACME responder did not start; see ${LOG_DIR}/acme-bootstrap.log"
}

stop_acme_bootstrap() {
	if [[ -n "${BOOTSTRAP_PID}" ]]; then
		kill "${BOOTSTRAP_PID}" 2>/dev/null || true
		wait "${BOOTSTRAP_PID}" 2>/dev/null || true
		BOOTSTRAP_PID=""
	fi
}

certificate_is_current() {
	local cert="${TLS_DIR}/fullchain.pem"
	[[ -r "${cert}" ]] || return 1
	if [[ "${MODE}" == "domain" ]]; then
		openssl x509 -in "${cert}" -noout -checkhost "${DOMAIN}" >/dev/null 2>&1 || return 1
	else
		openssl x509 -in "${cert}" -noout -checkip "${PUBLIC_IP}" >/dev/null 2>&1 || return 1
	fi
	# Renew with less than three days left. IP certificates live 160 hours, so
	# the renewal timer replaces them around half-life.
	openssl x509 -in "${cert}" -noout -checkend 259200 >/dev/null 2>&1
}

# certificate_is_staging reports whether the installed certificate came from the
# Let's Encrypt staging CA. Staging certificates are valid but untrusted, and
# they look "current" to certificate_is_current(), so a re-run without --staging
# must replace them instead of keeping them.
certificate_is_staging() {
	local cert="${TLS_DIR}/fullchain.pem"
	[[ -r "${cert}" ]] || return 1
	openssl x509 -in "${cert}" -noout -issuer 2>/dev/null | grep -qiE 'staging|fake|pretend'
}

obtain_certificate() {
	local force_renew=0
	if certificate_is_current; then
		if [[ ${STAGING} -eq 0 ]] && certificate_is_staging; then
			warn "the installed certificate is from the staging CA and is not publicly trusted; requesting a trusted one"
			force_renew=1
		else
			info "existing certificate in ${TLS_DIR} covers ${PUBLIC_HOST} and is not close to expiry"
			return 0
		fi
	fi

	start_acme_bootstrap

	install -d -m 0755 -o root -g root "${WEBROOT}/.well-known/acme-challenge"

	local -a args=(
		certonly
		--non-interactive
		--agree-tos
		--webroot
		--webroot-path "${WEBROOT}"
		--cert-name "${CERT_NAME}"
		--deploy-hook "${HOOK}"
	)
	if [[ ${force_renew} -eq 1 ]]; then
		args+=(--force-renewal)
	else
		args+=(--keep-until-expiring)
	fi
	if [[ "${MODE}" == "domain" ]]; then
		args+=(-d "${DOMAIN}")
	else
		args+=(--preferred-profile shortlived --ip-address "${PUBLIC_IP}")
	fi
	if [[ -n "${EMAIL}" ]]; then
		args+=(--email "${EMAIL}")
	else
		args+=(--register-unsafely-without-email)
	fi
	[[ ${STAGING} -eq 1 ]] && args+=(--staging)

	info "requesting a certificate for ${PUBLIC_HOST} (HTTP-01)"
	if ! "${CERTBOT}" "${args[@]}"; then
		stop_acme_bootstrap
		die "certificate issuance failed; port 80 must be reachable from the internet for ${PUBLIC_HOST}"
	fi
	stop_acme_bootstrap

	# certbot does not run its deploy hook when the existing lineage is not due
	# for renewal. Run the hook explicitly so a reinstall publishes the current
	# certificate, including after an earlier run stopped before this step.
	info "publishing the certificate for ${PUBLIC_HOST} to ${TLS_DIR}"
	"${HOOK}" || die "the deploy hook failed to install the certificate into ${TLS_DIR}"

	[[ -r "${TLS_DIR}/fullchain.pem" ]] || die "the deploy hook did not install the certificate into ${TLS_DIR}"
	if [[ "${MODE}" == "domain" ]]; then
		openssl x509 -in "${TLS_DIR}/fullchain.pem" -noout -checkhost "${DOMAIN}" >/dev/null ||
			die "the issued certificate does not cover ${DOMAIN}"
	else
		openssl x509 -in "${TLS_DIR}/fullchain.pem" -noout -checkip "${PUBLIC_IP}" >/dev/null ||
			die "the issued certificate does not include ${PUBLIC_IP} as an IP Subject Alternative Name"
	fi
	info "certificate installed for ${PUBLIC_HOST}"

	if [[ ${STAGING} -eq 1 ]]; then
		warn "staging certificate installed: clients will not trust it. Re-run without --staging for production"
	fi
}

install_renewal() {
	sed -e "s|@CERTBOT@|${CERTBOT}|g" \
		"${REPO_DIR}/deploy/systemd/dohcord-relay-certbot-renew.service" >"/etc/systemd/system/${RENEW_SERVICE}"
	install -m 0644 "${REPO_DIR}/deploy/systemd/dohcord-relay-certbot-renew.timer" "/etc/systemd/system/${RENEW_TIMER}"
	systemctl daemon-reload
	systemctl enable --now "${RENEW_TIMER}" >/dev/null
	info "renewal timer enabled: ${RENEW_TIMER} (every 6h; certbot decides if a renewal is due)"
	if [[ "${MODE}" == "ip" ]]; then
		info "IP certificates are only valid for 160 hours, so renewal must keep working: it is tested at the end of this install"
	fi
	# The renewal dry-run needs port 80 served by the real service, so it runs
	# in verify.sh after the services are up.
}

# --- Firewall ---------------------------------------------------------------
# ufw_api_rule_numbers prints the numbers of the ufw rules this project added for
# a port, newest first. Matching on the comment means unrelated rules - even on
# the same port - are never deleted.
ufw_api_rule_numbers() {
	local port="$1"
	ufw status numbered 2>/dev/null |
		awk -v want="${port}/tcp" -v tag="dohcord-relay network config" '
			index($0, want) && index($0, tag) {
				line = $0
				sub(/^\[[[:space:]]*/, "", line)
				sub(/\].*/, "", line)
				print line
			}' | sort -rn
}

# firewall_remove_old_api_port retires the API rule for a port that is being
# replaced. Ports that belong to the proxy, TURN or ACME are never touched, and
# only rules carrying this project's API comment are removed from ufw.
firewall_remove_old_api_port() {
	local old="$1"
	[[ -n "${old}" && "${old}" != "${API_PORT}" ]] || return 0
	case "${old}" in 80 | "${PROXY_PORT}" | 443 | 3478 | 5349) return 0 ;; esac
	if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
		local n
		while read -r n; do
			[[ -n "${n}" ]] || continue
			ufw --force delete "${n}" >/dev/null ||
				warn "could not remove the obsolete ufw rule for ${old}/tcp"
		done < <(ufw_api_rule_numbers "${old}")
		info "removed the obsolete ufw rule for ${old}/tcp"
	elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
		firewall-cmd --permanent --remove-port="${old}/tcp" >/dev/null 2>&1 || true
		firewall-cmd --reload >/dev/null 2>&1 || true
		info "removed the obsolete firewalld rule for ${old}/tcp"
	fi
}

# firewall_verify_api_port returns 0 when a supported firewall allows PORT,
# 1 when it does not, and 2 when no managed firewall is active.
firewall_verify_api_port() {
	local port="$1"
	if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
		ufw status | grep -qE "^${port}/tcp[[:space:]]+ALLOW" && return 0
		return 1
	fi
	if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
		firewall-cmd --query-port="${port}/tcp" >/dev/null 2>&1 && return 0
		return 1
	fi
	return 2
}

configure_firewall() {
	local changed=0 verify=2
	if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
		ufw allow 80/tcp comment 'dohcord-relay ACME' >/dev/null
		ufw allow "${PROXY_PORT}/tcp" comment 'dohcord-relay HTTPS CONNECT proxy' >/dev/null
		# Retire the previous API rule before opening the selected port, so 8443
		# is not left open when a different port was chosen.
		firewall_remove_old_api_port "${PREVIOUS_API_PORT}"
		ufw allow "${API_PORT}/tcp" comment 'dohcord-relay network config' >/dev/null
		ufw allow 3478/udp comment 'dohcord-relay TURN' >/dev/null
		ufw allow 5349/tcp comment 'dohcord-relay TURN TLS' >/dev/null
		ufw allow 49152:65535/udp comment 'dohcord-relay media' >/dev/null
		changed=1
		info "opened the required ports in ufw (existing rules untouched)"
		firewall_verify_api_port "${API_PORT}"
		verify=$?
	elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
		firewall-cmd --permanent --add-port=80/tcp >/dev/null
		firewall-cmd --permanent --add-port="${PROXY_PORT}/tcp" >/dev/null
		firewall_remove_old_api_port "${PREVIOUS_API_PORT}"
		firewall-cmd --permanent --add-port="${API_PORT}/tcp" >/dev/null
		firewall-cmd --permanent --add-port=3478/udp >/dev/null
		firewall-cmd --permanent --add-port=5349/tcp >/dev/null
		firewall-cmd --permanent --add-port=49152-65535/udp >/dev/null
		firewall-cmd --reload >/dev/null
		changed=1
		info "opened the required ports in firewalld"
		firewall_verify_api_port "${API_PORT}"
		verify=$?
	else
		warn "no active ufw/firewalld detected; make sure these ports are allowed in your firewall and cloud security group:"
	fi

	if [[ ${verify} -eq 1 ]]; then
		die "the firewall did not accept the Network Configuration API port ${API_PORT}/tcp; open it manually and re-run"
	elif [[ ${verify} -eq 0 ]]; then
		ok "firewall allows the Network Configuration API on ${API_PORT}/tcp"
	fi

	cat <<EOF
      80/tcp          HTTP-01 certificate validation
      ${PROXY_PORT}/tcp          HTTPS CONNECT proxy
      ${API_PORT}/tcp          network configuration endpoint
      3478/udp        TURN
      5349/tcp        TURN over TLS
      49152-65535/udp relayed media
EOF

	# Verify SSH is not accidentally closed by whatever is already configured.
	if command -v ufw >/dev/null 2>&1 && [[ ${changed} -eq 1 ]]; then
		local ssh_port
		ssh_port="$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2; exit }' || true)"
		ssh_port="${ssh_port:-22}"
		if ! ufw status | grep -qE "^${ssh_port}(/tcp)?[[:space:]]+ALLOW"; then
			warn "SSH port ${ssh_port} does not appear to be allowed in ufw; add it before logging out"
		fi
	fi
}

# --- Start and verify -------------------------------------------------------
apply_policy() {
	info "validating the destination policy and generating the Squid ACLs"

	# The TLS certificate directory must exist and contain squid.pem before the
	# full Squid configuration can be parsed.
	[[ -r "${TLS_DIR}/squid.pem" ]] ||
		die "${TLS_DIR}/squid.pem is missing; the certificate deploy hook did not run"

	if ! "${DAEMON}" -config "${ETC_DIR}/config.env" -policy-apply -no-reload; then
		die "the destination policy is invalid or Squid rejected the generated configuration; nothing was reloaded"
	fi
	info "destination policy validated and written to ${ETC_DIR}/squid-allow.conf"
}

start_services() {
	systemctl daemon-reload
	systemctl enable "${COTURN_UNIT}" "${SQUID_UNIT}" "${API_UNIT}" >/dev/null

	# Squid first: it is the service that must never come up with an
	# unvalidated configuration.
	systemctl restart "${SQUID_UNIT}"
	sleep 1
	systemctl is-active --quiet "${SQUID_UNIT}" || {
		journalctl -u "${SQUID_UNIT}" -n 30 --no-pager >&2 || true
		tail -20 "${SQUID_LOG_DIR}/cache.log" >&2 2>/dev/null || true
		die "${SQUID_UNIT} failed to start"
	}

	# coturn next: the credential URLs point at it.
	systemctl restart "${COTURN_UNIT}"
	systemctl restart "${API_UNIT}"

	sleep 2
	systemctl is-active --quiet "${COTURN_UNIT}" || {
		journalctl -u "${COTURN_UNIT}" -n 20 --no-pager >&2 || true
		die "${COTURN_UNIT} failed to start"
	}
	systemctl is-active --quiet "${API_UNIT}" || {
		journalctl -u "${API_UNIT}" -n 20 --no-pager >&2 || true
		# A previously working installation must not be left with a binary it
		# cannot run. Fresh installs have nothing to restore.
		if restore_previous_binaries; then
			warn "the new release did not start; the previous executables are back in place"
		fi
		die "${API_UNIT} failed to start"
	}
	info "proxy, TURN relay and configuration endpoint are running"
}

run_verification() {
	info "running the verification suite"
	if [[ ${STAGING} -eq 1 ]]; then
		warn "skipping HTTPS checks: a staging certificate is not publicly trusted"
		return 0
	fi
	if ! DOHCORD_RELAY_SKIP_RENEW="${SKIP_RENEW_TEST}" \
		DOHCORD_RELAY_CERTBOT="${CERTBOT}" bash "${REPO_DIR}/deploy/scripts/verify.sh"; then
		warn "one or more checks failed; see the output above"
		return 1
	fi
}

print_report() { # print_report VERIFY_RC
	local verify_rc="${1:-0}" cert_end="" cert_not_before="" cert_subject="" heading="installation complete"
	if [[ -r "${TLS_DIR}/fullchain.pem" ]]; then
		cert_end="$(openssl x509 -in "${TLS_DIR}/fullchain.pem" -noout -enddate | cut -d= -f2)"
		cert_not_before="$(openssl x509 -in "${TLS_DIR}/fullchain.pem" -noout -startdate | cut -d= -f2)"
		cert_subject="$(openssl x509 -in "${TLS_DIR}/fullchain.pem" -noout -ext subjectAltName 2>/dev/null | tail -n +2 | tr -d ' ')"
	fi

	[[ "${verify_rc}" -ne 0 ]] && heading="installed, but one or more checks failed (see above)"

	cat <<EOF

==========================================================================
Dohcord-relay ${heading}
==========================================================================
Server address       ${PUBLIC_HOST} (${PUBLIC_IP}), mode: ${MODE}

HTTPS CONNECT proxy  https://${PUBLIC_HOST}:${PROXY_PORT}
Network config URL   https://${PUBLIC_HOST}:${API_PORT}/network-config
TURN endpoints       turn:${PUBLIC_HOST}:3478?transport=udp
                     turns:${PUBLIC_HOST}:5349?transport=tcp
Destination policy   ${ETC_DIR}/allowed-domains.txt
                     ${ETC_DIR}/destination-policy.conf
                     (applied: ${ETC_DIR}/squid-allow.conf)

Release              ${RELEASE_TAG:-unknown} (linux/${RELEASE_ARCH:-unknown})
                     binaries verified against checksums.txt
Software             squid ${SQUID_INSTALLED_VERSION}
                     coturn ${COTURN_INSTALLED_VERSION:-unknown}
                     certbot $("${CERTBOT}" --version 2>/dev/null | awk '{print $2}')
TLS certificate      ${TLS_DIR}/fullchain.pem
                     ${cert_subject:-SAN unavailable}
                     valid ${cert_not_before:-?} to ${cert_end:-?}
Renewal              ${RENEW_TIMER}, every 6h (certbot decides)
                     deploy hook ${HOOK}

Firewall ports       80/tcp, ${PROXY_PORT}/tcp, ${API_PORT}/tcp,
                     3478/udp, 5349/tcp, 49152-65535/udp

Services             systemctl status ${SQUID_UNIT} ${COTURN_UNIT} ${API_UNIT}
Management console   sudo dohcord-relay
Re-check any time    sudo dohcord-relay diagnostics
Uninstall safely     sudo dohcord-relay  (option 10)
Server daemon        ${DAEMON} (dohcord-relay-api.service)
                     keeps configuration and certificates unless you purge

In Dohcord: Settings -> Custom Profile -> add this server:
  Network Configuration URL: https://${PUBLIC_HOST}:${API_PORT}/network-config
==========================================================================
EOF
}

main() {
	parse_args "$@"
	# Never leave an ACME responder holding port 80 or a release download in /tmp
	# if this run is interrupted.
	trap 'stop_acme_bootstrap; cleanup_release_workdir' EXIT
	trap 'stop_acme_bootstrap; cleanup_release_workdir; exit 130' INT
	trap 'stop_acme_bootstrap; cleanup_release_workdir; exit 143' TERM
	banner

	step_msg "Collecting how clients connect"
	wizard

	step_msg "Checking prerequisites"
	check_root_and_os
	install_base_packages

	step_msg "Checking name resolution"
	verify_dns

	step_msg "Retiring an earlier relay service, if present"
	retire_legacy_units

	step_msg "Checking the ports this relay needs"
	check_ports

	step_msg "Detecting network layout"
	detect_network

	step_msg "Creating service users and directories"
	create_service_users
	install -d -m 0755 -o root -g root "${ETC_DIR}" "${TLS_DIR}"
	install -d -m 0755 -o root -g root "${LOG_DIR}"
	install -d -m 0750 -o proxy -g proxy "${SQUID_LOG_DIR}"
	install -d -m 0750 -o turnserver -g turnserver "${TURN_LOG_DIR}"

	step_msg "Configuring the firewall"
	configure_firewall

	step_msg "Installing Squid"
	install_squid
	configure_apparmor

	step_msg "Installing coturn"
	install_coturn

	step_msg "Writing configuration"
	write_turn_secret
	render_turnserver_conf
	install_coturn_unit
	render_squid_conf
	install_squid_unit
	install_policy_files
	render_config_env
	install_api_unit

	step_msg "Installing verified release binaries"
	install_release_binaries

	step_msg "Installing the management console"
	install_management_tools

	step_msg "Installing the TLS deploy hook"
	install_deploy_hook

	step_msg "Obtaining the TLS certificate"
	setup_certbot
	obtain_certificate

	step_msg "Applying the destination policy"
	apply_policy

	step_msg "Configuring automatic renewal"
	install_renewal

	step_msg "Starting services"
	start_services

	step_msg "Verifying the installation"
	local verify_rc=0
	if [[ ${SKIP_VERIFY} -eq 1 ]]; then
		info "skipped (--skip-verify)"
	else
		run_verification || verify_rc=1
	fi

	write_install_info
	print_progress
	if [[ ${verify_rc} -eq 0 ]]; then
		printf '\n  %s✓ Installation complete.%s\n' "${C_GREEN}${C_BOLD}" "${C_RESET}"
	else
		printf '\n  %s! Installed, but some checks failed — do not hand this URL out until they are fixed.%s\n' "${C_YELLOW}${C_BOLD}" "${C_RESET}"
		printf '    Run the management console and choose Diagnostics for details.\n'
	fi
	print_report "${verify_rc}"
}

main "$@"
