#!/usr/bin/env bash
# Dohcord Relay installer.
#
# Sets up two networking services on one VPS:
#
#   Dohcord --TLS--> Squid :443 --CONNECT host:port--> Discord HTTPS/WSS
#   Dohcord --TURN--> coturn :3478/udp, :5349/tcp --> Discord RTC media
#
# plus a small HTTPS endpoint on :8443 that publishes the proxy address, the
# destination policy and temporary TURN credentials:
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

readonly INSTALLER_VERSION="2.0.0"

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
API_PORT=8443
MAX_CONN_PER_IP=20
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
readonly BIN="/usr/local/bin/dohcord-relay"
readonly HOOK="/usr/local/bin/dohcord-relay-tls-deploy"
readonly CERT_NAME="dohcord-relay"
readonly API_UNIT="dohcord-relay-api.service"
readonly SQUID_UNIT="dohcord-relay-squid.service"
readonly COTURN_UNIT="dohcord-relay-coturn.service"
readonly RENEW_SERVICE="dohcord-relay-certbot-renew.service"
readonly RENEW_TIMER="dohcord-relay-certbot-renew.timer"

REPO_DIR=""
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
step=0
step_msg() {
	step=$((step + 1))
	printf '\n[%d] %s\n' "${step}" "$*"
}
info() { printf '    %s\n' "$*"; }
warn() { printf '    warning: %s\n' "$*" >&2; }
die() {
	printf '\nerror: %s\n' "$*" >&2
	exit 1
}
on_error() {
	local rc=$?
	printf '\nerror: installer failed at line %s (exit %s)\n' "${BASH_LINENO[0]}" "${rc}" >&2
	stop_acme_bootstrap
	exit "${rc}"
}
trap on_error ERR
trap 'stop_acme_bootstrap; exit 130' INT TERM

usage() {
	cat <<'EOF'
Usage: sudo deploy/install.sh [options]

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
  --max-connections N      Concurrent proxy connections per client IP (default: 20).

Other:
  --yes                    Do not ask for confirmation (still needs --mode).
  --skip-renew-test        Do not run `certbot renew --dry-run` at the end.
  --skip-verify            Do not run deploy/verify.sh at the end.
  -h, --help               Show this help.

Ports used: 80/tcp (certificate validation), 443/tcp (HTTPS CONNECT proxy),
8443/tcp (network configuration endpoint), 3478/udp and 5349/tcp (TURN),
49152-65535/udp (TURN relay media).
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
Dohcord-relay Installation

How should clients connect to this server?

  1. Domain name (recommended)
  2. Public IPv4 address

EOF
		local choice
		read -r -p "Choose [1/2]: " choice
		case "${choice}" in
		1) MODE="domain" ;;
		2) MODE="ip" ;;
		*) die "please answer 1 or 2" ;;
		esac
	fi

	if [[ -z "${PUBLIC_IP}" ]]; then
		local detected
		detected="$(detect_outbound_ip)"
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
	is_public_ipv4 "${PUBLIC_IP}" ||
		die "${PUBLIC_IP} is not a public IPv4 address (loopback, private, CGNAT, link-local, multicast and reserved ranges are rejected)"

	if [[ "${MODE}" == "domain" ]]; then
		if [[ -z "${DOMAIN}" ]]; then
			[[ -t 0 ]] || die "pass --domain NAME"
			read -r -p "Domain (for example relay.example.com): " DOMAIN
		fi
		DOMAIN="${DOMAIN,,}"
		DOMAIN="${DOMAIN%.}"
		is_domain_name "${DOMAIN}" || die "'${DOMAIN}' is not a valid fully qualified domain name"
		DOMAIN="${DOMAIN,,}"
		PUBLIC_HOST="${DOMAIN}"
	else
		PUBLIC_HOST="${PUBLIC_IP}"
	fi
	TURN_REALM="${TURN_REALM:-$( [[ "${MODE}" == "domain" ]] && echo "${DOMAIN}" || echo "dohcord.relay")}"

	cat <<EOF

Server address .... ${PUBLIC_HOST} (${PUBLIC_IP})
Mode .............. ${MODE}
HTTPS proxy ....... https://${PUBLIC_HOST}:${PROXY_PORT}
Network config .... https://${PUBLIC_HOST}:${API_PORT}/network-config
TURN UDP .......... turn:${PUBLIC_HOST}:3478?transport=udp
TURN TLS .......... turns:${PUBLIC_HOST}:5349?transport=tcp

EOF
	if [[ ${ASSUME_YES} -eq 0 ]]; then
		local answer
		read -r -p "Install with these settings? [Y/n]: " answer
		case "${answer}" in
		"" | y | Y | yes | YES) ;;
		*) die "cancelled" ;;
		esac
	fi
}

# verify_dns makes sure the domain actually points at this server before a
# certificate is requested, and that any AAAA record is usable.
verify_dns() {
	[[ "${MODE}" == "domain" ]] || return 0

	local a_records
	a_records="$(dns_lookup a "${DOMAIN}" | tr '\n' ' ')"
	[[ -n "${a_records// /}" ]] ||
		die "${DOMAIN} has no A record; create one pointing at ${PUBLIC_IP} and wait for DNS to propagate"
	if ! grep -qw "${PUBLIC_IP}" <<<"${a_records}"; then
		die "${DOMAIN} resolves to [${a_records% }], which is not ${PUBLIC_IP}; fix the A record (or pass the matching --ip) before installing"
	fi
	info "${DOMAIN} A record includes ${PUBLIC_IP}"

	local aaaa_records
	aaaa_records="$(dns_lookup aaaa "${DOMAIN}" | tr '\n' ' ')"
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
	[[ -f "${REPO_DIR}/go.mod" && -f "${REPO_DIR}/main.go" ]] ||
		die "cannot find the Go sources; run this script from a checkout of Dohcord-relay"

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
	seen="$(detect_outbound_ip)"
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

	SQUID_BINARY="$(command -v squid || true)"
	[[ -n "${SQUID_BINARY}" ]] || SQUID_BINARY="/usr/sbin/squid"
	[[ -x "${SQUID_BINARY}" ]] || die "the squid package did not install a squid binary"

	# Squid's distro unit must not fight ours for logs and the cache manager.
	systemctl disable --now squid.service >/dev/null 2>&1 || true

	SQUID_INSTALLED_VERSION="$("${SQUID_BINARY}" -v 2>&1 | sed -n 's/^Squid Cache: Version \([0-9][0-9.]*\).*/\1/p' | head -1)"
	[[ -n "${SQUID_INSTALLED_VERSION}" ]] ||
		SQUID_INSTALLED_VERSION="$("${SQUID_BINARY}" -v 2>&1 | grep -oE 'Version [0-9]+\.[0-9]+\.[0-9]+' | head -1 | awk '{print $2}')"
	[[ -n "${SQUID_INSTALLED_VERSION}" ]] || die "cannot determine the Squid version"
	info "squid version: ${SQUID_INSTALLED_VERSION}"

	# https_port for forward-proxy CONNECT needs a TLS-enabled Squid.
	if ! "${SQUID_BINARY}" -v 2>&1 | grep -qE -- '--with-openssl|--with-gnutls'; then
		die "this Squid build has no TLS support (--with-openssl/--with-gnutls); the HTTPS CONNECT listener cannot work. Install a TLS-enabled Squid (Ubuntu 22.04+/Debian 12+ packages are)."
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
		"${REPO_DIR}/deploy/squid.conf.tmpl" >"${target}.new"

	chown root:root "${target}.new"
	chmod 0644 "${target}.new"
	mv "${target}.new" "${target}"
	info "wrote ${target}"
}

install_squid_unit() {
	install -m 0644 "${REPO_DIR}/deploy/dohcord-relay-squid.service" \
		"/etc/systemd/system/${SQUID_UNIT}"
	info "installed /etc/systemd/system/${SQUID_UNIT}"
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
	local secret template="${REPO_DIR}/deploy/turnserver.conf.tmpl" target="${ETC_DIR}/turnserver.conf"
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
		"${REPO_DIR}/deploy/dohcord-relay-coturn.service" >"/etc/systemd/system/${COTURN_UNIT}"
	chmod 0644 "/etc/systemd/system/${COTURN_UNIT}"
	info "installed /etc/systemd/system/${COTURN_UNIT}"
}

# --- endpoint ---------------------------------------------------------------
install_go() {
	export DEBIAN_FRONTEND=noninteractive
	if command -v go >/dev/null 2>&1; then
		local have
		have="$(go version | grep -oE 'go[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 | sed 's/^go//')"
		if version_ge "${have}" "1.18"; then
			info "using $(go version)"
			return 0
		fi
	fi
	apt-get install -y -qq --no-install-recommends golang-go >/dev/null
	command -v go >/dev/null || die "installing golang-go did not provide a 'go' command"
	local have
	have="$(go version | grep -oE 'go[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 | sed 's/^go//')"
	version_ge "${have}" "1.18" || die "Go ${have} is too old (1.18+ required); install a newer Go and re-run"
	info "installed $(go version)"
}

build_endpoint() {
	install_go
	(
		cd "${REPO_DIR}"
		CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o "${BIN}.new" .
	) || die "building the endpoint failed"
	install -m 0755 -o root -g root "${BIN}.new" "${BIN}"
	rm -f "${BIN}.new"
	info "installed ${BIN}"
}

render_config_env() {
	local target="${ETC_DIR}/config.env"
	if [[ -f "${target}" ]] && grep -q '^HTTPS_PROXY_URL=' "${target}"; then
		# Keep operator tuning, but refresh the public identity and ports so a
		# change of domain/IP is picked up.
		sed -i -E \
			-e "s|^HTTPS_PROXY_URL=.*|HTTPS_PROXY_URL=https://${PUBLIC_HOST}:${PROXY_PORT}|" \
			-e "s|^NETWORK_CONFIG_URL=.*|NETWORK_CONFIG_URL=https://${PUBLIC_HOST}:${API_PORT}/network-config|" \
			-e "s|^TURN_URLS=.*|TURN_URLS=turn:${PUBLIC_HOST}:3478?transport=udp,turns:${PUBLIC_HOST}:5349?transport=tcp|" \
			"${target}"
		info "updated the public endpoints in ${target}"
	else
		sed -e "s|@PUBLIC_HOST@|${PUBLIC_HOST}|g" \
			-e "s|@PROXY_PORT@|${PROXY_PORT}|g" \
			-e "s|@API_PORT@|${API_PORT}|g" \
			-e "s|@TLS_DIR@|${TLS_DIR}|g" \
			"${REPO_DIR}/deploy/config.env.tmpl" >"${target}.new"
		chown root:dohcord-relay "${target}.new"
		chmod 0640 "${target}.new"
		mv "${target}.new" "${target}"
		info "wrote ${target}"
	fi
	install -d -m 0755 -o root -g root "${WEBROOT}"
}

install_api_unit() {
	install -m 0644 "${REPO_DIR}/deploy/dohcord-relay-api.service" \
		"/etc/systemd/system/${API_UNIT}"
	info "installed /etc/systemd/system/${API_UNIT}"
}

install_policy_files() {
	local name src dst
	for name in allowed-domains.txt destination-policy.conf; do
		src="${REPO_DIR}/deploy/${name}"
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
		"${REPO_DIR}/deploy/dohcord-relay-tls-deploy" >"${HOOK}.new"
	chown root:root "${HOOK}.new"
	chmod 0755 "${HOOK}.new"
	mv "${HOOK}.new" "${HOOK}"
	info "installed ${HOOK}"
}

start_acme_bootstrap() {
	install -d -m 0755 -o root -g root "${WEBROOT}"
	[[ -n "${BOOTSTRAP_PID}" ]] && return 0
	if ss -Hltn 'sport = :80' 2>/dev/null | grep -q .; then
		if systemctl is-active --quiet "${API_UNIT}"; then
			info "port 80 is already served by ${API_UNIT}"
			return 0
		fi
		die "port 80 is in use; cannot answer the ACME HTTP-01 challenge"
	fi

	local probe="probe${RANDOM}${RANDOM}"
	local probe_dir="${WEBROOT}/.well-known/acme-challenge"
	info "starting the ACME HTTP-01 responder on port 80"
	install -d -m 0755 -o root -g root "${probe_dir}"
	printf 'ok\n' >"${probe_dir}/${probe}"
	"${BIN}" -config "${ETC_DIR}/config.env" -acme-only >>"${LOG_DIR}/acme-bootstrap.log" 2>&1 &
	BOOTSTRAP_PID=$!

	local i
	for i in $(seq 1 60); do
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
		"${REPO_DIR}/deploy/dohcord-relay-certbot-renew.service" >"/etc/systemd/system/${RENEW_SERVICE}"
	install -m 0644 "${REPO_DIR}/deploy/dohcord-relay-certbot-renew.timer" "/etc/systemd/system/${RENEW_TIMER}"
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
configure_firewall() {
	local changed=0
	if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
		ufw allow 80/tcp comment 'dohcord-relay ACME' >/dev/null
		ufw allow "${PROXY_PORT}/tcp" comment 'dohcord-relay HTTPS CONNECT proxy' >/dev/null
		ufw allow "${API_PORT}/tcp" comment 'dohcord-relay network config' >/dev/null
		ufw allow 3478/udp comment 'dohcord-relay TURN' >/dev/null
		ufw allow 5349/tcp comment 'dohcord-relay TURN TLS' >/dev/null
		ufw allow 49152:65535/udp comment 'dohcord-relay media' >/dev/null
		changed=1
		info "opened the required ports in ufw (existing rules untouched)"
	elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
		firewall-cmd --permanent --add-port=80/tcp >/dev/null
		firewall-cmd --permanent --add-port="${PROXY_PORT}/tcp" >/dev/null
		firewall-cmd --permanent --add-port="${API_PORT}/tcp" >/dev/null
		firewall-cmd --permanent --add-port=3478/udp >/dev/null
		firewall-cmd --permanent --add-port=5349/tcp >/dev/null
		firewall-cmd --permanent --add-port=49152-65535/udp >/dev/null
		firewall-cmd --reload >/dev/null
		changed=1
		info "opened the required ports in firewalld"
	else
		warn "no active ufw/firewalld detected; make sure these ports are allowed in your firewall and cloud security group:"
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

	if ! "${BIN}" -config "${ETC_DIR}/config.env" -policy-apply -no-reload; then
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
		DOHCORD_RELAY_CERTBOT="${CERTBOT}" bash "${REPO_DIR}/deploy/verify.sh"; then
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
Re-check any time    sudo bash ${REPO_DIR}/deploy/verify.sh

In Dohcord: Settings -> Custom Profile -> add this server:
  Network Configuration URL: https://${PUBLIC_HOST}:${API_PORT}/network-config
==========================================================================
EOF
}

main() {
	parse_args "$@"
	printf 'Dohcord-relay installer %s\n' "${INSTALLER_VERSION}"

	step_msg "Collecting how clients connect"
	wizard

	step_msg "Checking prerequisites"
	check_root_and_os
	install_base_packages

	step_msg "Checking name resolution"
	verify_dns

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

	step_msg "Building the configuration endpoint"
	build_endpoint

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

	if [[ ${verify_rc} -eq 0 ]]; then
		printf '\nInstallation complete.\n'
	else
		printf '\nInstallation finished, but some checks failed — do not hand this URL out until they are resolved.\n'
	fi
	print_report "${verify_rc}"
}

main "$@"
