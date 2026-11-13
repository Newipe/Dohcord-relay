#!/usr/bin/env bash
# Dohcord Relay installer.
#
# Installs a coturn TURN relay plus the small HTTPS service that hands temporary
# "Dohcord" TURN credentials to Dohcord clients:
#
#   Dohcord --TURN/UDP or TURN/TLS--> this VPS --UDP--> Discord RTC endpoint
#
# Tested on Ubuntu 24.04 and Debian 12; targets any Ubuntu 22.04+/Debian 12+.
# Run from a checkout of the repository:
#
#   sudo deploy/install.sh
#
# The installer is idempotent: it keeps an existing TURN secret and an existing
# valid certificate, and only rewrites the files it owns.
set -Eeuo pipefail

readonly INSTALLER_VERSION="1.0.0"

# --- Defaults ---------------------------------------------------------------
PUBLIC_IP="13.48.52.216"
REALM="dohcord.relay"
EMAIL=""
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
SKIP_RENEW_TEST=0

readonly ETC_DIR="/etc/dohcord-relay"
readonly TLS_DIR="${ETC_DIR}/tls"
readonly LOG_DIR="/var/log/dohcord-relay"
readonly WEBROOT="/var/www/dohcord-relay"
readonly BIN="/usr/local/bin/dohcord-relay-credentials"
readonly HOOK="/usr/local/bin/dohcord-relay-tls-deploy"
readonly CERT_NAME="dohcord-relay"
readonly CRED_UNIT="dohcord-relay-credentials.service"
readonly COTURN_UNIT="dohcord-relay-coturn.service"
readonly RENEW_SERVICE="dohcord-relay-certbot-renew.service"
readonly RENEW_TIMER="dohcord-relay-certbot-renew.timer"

REPO_DIR=""
TURN_BINARY=""
CERTBOT=""
PRIVATE_IP=""
LISTENING_IP="0.0.0.0"
RELAY_IP=""
EXTERNAL_IP=""
BOOTSTRAP_PID=""

# --- Output helpers ---------------------------------------------------------
step=0
step_msg() {
	step=$((step + 1))
	printf '\n[%d/12] %s\n' "${step}" "$*"
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

Options:
  --email ADDRESS          Optional contact address registered with Let's
                           Encrypt (used for expiry notices only). Without it
                           the ACME account is registered without an email.
  --ip ADDRESS             Public IPv4 of this relay (default: 13.48.52.216).
  --realm NAME             TURN realm (default: dohcord.relay).
  --staging                Use the Let's Encrypt staging CA (test installs).
  --distro-coturn          Use the distribution coturn package instead of
                           building the pinned upstream release.
  --coturn-version VERSION Upstream coturn release to build (default: 4.18.0).
  --user-quota N           Concurrent allocations per credential (default: 12).
  --total-quota N          Concurrent allocations for the relay (default: 1200).
  --max-bps N              Per-session bandwidth ceiling in bytes/s (default: 2000000).
  --bps-capacity N         Total relay bandwidth in bytes/s (default: 250000000).
                           coturn reserves max-bps per allocation, so
                           bps-capacity / max-bps is the number of concurrent
                           relayed sessions. Match it to the VPS uplink.
  --skip-renew-test        Do not run `certbot renew --dry-run` at the end.
  -h, --help               Show this help.

Firewall note: ports 80/tcp, 443/tcp, 3478/udp, 5349/tcp and 49152-65535/udp
must be reachable from the internet. If this host sits behind a cloud security
group (for example an EC2 security group), open them there as well.
EOF
}

version_ge() { # version_ge HAVE WANT
	[[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" == "$2" ]]
}

# --- Arguments --------------------------------------------------------------
parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--email)
			EMAIL="${2:-}"
			shift 2
			;;
		--ip)
			PUBLIC_IP="${2:-}"
			shift 2
			;;
		--realm)
			REALM="${2:-}"
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
		--skip-renew-test)
			SKIP_RENEW_TEST=1
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

	# --email is optional: without it the ACME account is registered without a
	# contact address, which Let's Encrypt allows (no expiry notifications).
	if [[ -n "${EMAIL}" ]]; then
		[[ "${EMAIL}" =~ ^[^@[:space:]]+@[^@[:space:]]+$ ]] || die "--email does not look like an address"
	fi

	local o
	for o in PUBLIC_IP USER_QUOTA TOTAL_QUOTA MAX_BPS BPS_CAPACITY; do
		[[ "${!o}" =~ ^[0-9.]+$ ]] || die "--${o,,} must be numeric"
	done
	[[ "${REALM}" =~ ^[A-Za-z0-9.-]+$ ]] || die "--realm must be a hostname-like token"
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

# Fails fast when another service owns a port this relay needs, so an existing
# web server is never disrupted.
check_ports() {
	local busy=0
	local -a conflicts=()

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
			if ss -Hlunp "sport = :${port}" 2>/dev/null | grep -qE 'turnserver|dohcord'; then
				return 0
			fi
		else
			if ss -Hltnp "sport = :${port}" 2>/dev/null | grep -qE 'turnserver|dohcord'; then
				return 0
			fi
		fi
		busy=1
		conflicts+=("${port}/${proto}")
	}

	check_one tcp 80
	check_one tcp 443
	check_one udp 3478
	check_one tcp 5349

	if [[ ${busy} -eq 1 ]]; then
		printf '\n' >&2
		ss -lntup 2>/dev/null | grep -E ':(80|443|3478|5349)\b' >&2 || true
		die "port(s) ${conflicts[*]} already in use by another service; stop or reconfigure it first (this installer does not touch existing web servers)"
	fi
	info "ports 80/tcp, 443/tcp, 3478/udp and 5349/tcp are free"
}

detect_network() {
	PRIVATE_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}' || true)"
	[[ -n "${PRIVATE_IP}" ]] || PRIVATE_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
	[[ -n "${PRIVATE_IP}" ]] || die "cannot determine this host's primary IPv4 address"

	local on_interface=0
	if ip -o -4 addr show | awk '{print $4}' | cut -d/ -f1 | grep -qx "${PUBLIC_IP}"; then
		on_interface=1
	fi

	if [[ ${on_interface} -eq 1 ]]; then
		RELAY_IP="${PUBLIC_IP}"
		EXTERNAL_IP="${PUBLIC_IP}"
		info "public IP ${PUBLIC_IP} is configured on this host"
	else
		# 1:1 NAT host (for example EC2): relays must bind the private address,
		# and coturn must publish the public/private mapping.
		RELAY_IP="${PRIVATE_IP}"
		EXTERNAL_IP="${PUBLIC_IP}/${PRIVATE_IP}"
		info "public IP ${PUBLIC_IP} is not on this host; using 1:1 NAT mapping ${EXTERNAL_IP}"
	fi
	info "primary local address: ${PRIVATE_IP}"

	if curl -fsS --max-time 5 https://api.ipify.org >/dev/null 2>&1; then
		local seen
		seen="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
		if [[ -n "${seen}" && "${seen}" != "${PUBLIC_IP}" ]]; then
			warn "outbound traffic appears to leave from ${seen}, not ${PUBLIC_IP}; TURN allocations may not be reachable at ${PUBLIC_IP}"
		fi
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

	local version
	version="$("${TURN_BINARY}" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
	if [[ -z "${version}" ]]; then
		die "cannot determine the coturn version from ${TURN_BINARY} --version"
	fi
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
	# The credential service (group dohcord-relay) and nobody else can read it.
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
		-e "s|@REALM@|${REALM}|g" \
		-e "s|@CERT_FILE@|${TLS_DIR}/fullchain.pem|g" \
		-e "s|@KEY_FILE@|${TLS_DIR}/privkey.pem|g" \
		-e "s|@USER_QUOTA@|${USER_QUOTA}|g" \
		-e "s|@TOTAL_QUOTA@|${TOTAL_QUOTA}|g" \
		-e "s|@MAX_BPS@|${MAX_BPS}|g" \
		-e "s|@BPS_CAPACITY@|${BPS_CAPACITY}|g" \
		-e "s|@LOG_FILE@|${LOG_DIR}/turnserver.log|g" \
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

# --- credential endpoint ----------------------------------------------------
install_go() {
	export DEBIAN_FRONTEND=noninteractive
	if command -v go >/dev/null 2>&1 && version_ge "$(go version | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)" "1.19"; then
		info "using $(go version)"
		return 0
	fi
	apt-get install -y -qq --no-install-recommends golang-go >/dev/null
	command -v go >/dev/null || die "installing golang-go did not provide a 'go' command"
	info "installed $(go version)"
}

build_credentials_service() {
	install_go
	(
		cd "${REPO_DIR}"
		CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o "${BIN}.new" .
	) || die "building the credential endpoint failed"
	install -m 0755 -o root -g root "${BIN}.new" "${BIN}"
	rm -f "${BIN}.new"
	info "installed ${BIN}"
}

render_config_env() {
	local target="${ETC_DIR}/config.env"
	if [[ -f "${target}" ]] && grep -q '^TURN_URLS=' "${target}"; then
		info "keeping existing ${target}"
	else
		sed -e "s|@PUBLIC_IP@|${PUBLIC_IP}|g" \
			"${REPO_DIR}/deploy/config.env.tmpl" >"${target}.new"
		chown root:dohcord-relay "${target}.new"
		chmod 0640 "${target}.new"
		mv "${target}.new" "${target}"
		info "wrote ${target}"
	fi
	install -d -m 0755 -o root -g root "${WEBROOT}"
}

install_credentials_unit() {
	install -m 0644 "${REPO_DIR}/deploy/dohcord-relay-credentials.service" \
		"/etc/systemd/system/${CRED_UNIT}"
	info "installed /etc/systemd/system/${CRED_UNIT}"
}

# --- TLS certificate for the bare IP ---------------------------------------
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
		if systemctl is-active --quiet "${CRED_UNIT}"; then
			info "port 80 is already served by ${CRED_UNIT}"
			return 0
		fi
		die "port 80 is in use; cannot answer the ACME HTTP-01 challenge"
	fi

	local probe="probe${RANDOM}${RANDOM}"
	info "starting the ACME HTTP-01 responder on port 80"
	printf 'ok\n' >"${WEBROOT}/${probe}"
	"${BIN}" -config "${ETC_DIR}/config.env" -acme-only >>"${LOG_DIR}/acme-bootstrap.log" 2>&1 &
	BOOTSTRAP_PID=$!

	local i
	for i in $(seq 1 60); do
		if [[ "$(curl -fsS --max-time 2 "http://127.0.0.1/.well-known/acme-challenge/${probe}" 2>/dev/null || true)" == "ok" ]]; then
			rm -f "${WEBROOT}/${probe}"
			info "ACME responder is answering on port 80"
			return 0
		fi
		sleep 0.5
	done
	rm -f "${WEBROOT}/${probe}"
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
	openssl x509 -in "${cert}" -noout -checkip "${PUBLIC_IP}" >/dev/null 2>&1 || return 1
	# Renew when less than 2 days remain (certificates live ~160 hours).
	openssl x509 -in "${cert}" -noout -checkend 172800 >/dev/null 2>&1
}

obtain_certificate() {
	if certificate_is_current; then
		info "existing certificate in ${TLS_DIR} still covers ${PUBLIC_IP} and is not close to expiry"
		return 0
	fi

	start_acme_bootstrap

	local -a args=(
		certonly
		--non-interactive
		--agree-tos
		--preferred-profile shortlived
		--webroot
		--webroot-path "${WEBROOT}"
		--ip-address "${PUBLIC_IP}"
		--cert-name "${CERT_NAME}"
		--keep-until-expiring
		--deploy-hook "${HOOK}"
	)
	if [[ -n "${EMAIL}" ]]; then
		args+=(--email "${EMAIL}")
	else
		args+=(--register-unsafely-without-email)
	fi
	[[ ${STAGING} -eq 1 ]] && args+=(--staging)

	info "requesting a shortlived IP certificate for ${PUBLIC_IP} (HTTP-01)"
	if ! "${CERTBOT}" "${args[@]}"; then
		stop_acme_bootstrap
		die "certificate issuance failed; port 80 must be reachable from the internet for ${PUBLIC_IP}"
	fi
	stop_acme_bootstrap

	[[ -r "${TLS_DIR}/fullchain.pem" ]] || die "the deploy hook did not install the certificate into ${TLS_DIR}"
	openssl x509 -in "${TLS_DIR}/fullchain.pem" -noout -checkip "${PUBLIC_IP}" >/dev/null ||
		die "the issued certificate does not include ${PUBLIC_IP} as a Subject Alternative Name"
	info "certificate installed for IP ${PUBLIC_IP}"

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
	info "renewal timer enabled: ${RENEW_TIMER} (every 6h, renewal decided by certbot)"
	# The renewal dry-run needs port 80 served by the real service, so it runs in
	# verify.sh after the services are up.
}

# --- Firewall ---------------------------------------------------------------
configure_firewall() {
	local changed=0
	if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
		ufw allow 80/tcp comment 'dohcord-relay ACME' >/dev/null
		ufw allow 443/tcp comment 'dohcord-relay credentials' >/dev/null
		ufw allow 3478/udp comment 'dohcord-relay TURN' >/dev/null
		ufw allow 5349/tcp comment 'dohcord-relay TURN TLS' >/dev/null
		ufw allow 49152:65535/udp comment 'dohcord-relay media' >/dev/null
		changed=1
		info "opened the required ports in ufw (existing rules untouched)"
	elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
		firewall-cmd --permanent --add-port=80/tcp >/dev/null
		firewall-cmd --permanent --add-port=443/tcp >/dev/null
		firewall-cmd --permanent --add-port=3478/udp >/dev/null
		firewall-cmd --permanent --add-port=5349/tcp >/dev/null
		firewall-cmd --permanent --add-port=49152-65535/udp >/dev/null
		firewall-cmd --reload >/dev/null
		changed=1
		info "opened the required ports in firewalld"
	else
		warn "no active ufw/firewalld detected; make sure these ports are allowed in your firewall and cloud security group:"
	fi

	cat <<'EOF'
      80/tcp   HTTP-01 certificate validation
      443/tcp  HTTPS credential endpoint
      3478/udp primary TURN
      5349/tcp TURN over TLS
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
start_services() {
	systemctl daemon-reload
	systemctl enable "${COTURN_UNIT}" "${CRED_UNIT}" >/dev/null
	# coturn first: it is what the credential endpoint's URLs point at.
	systemctl restart "${COTURN_UNIT}"
	systemctl restart "${CRED_UNIT}"

	sleep 2
	systemctl is-active --quiet "${COTURN_UNIT}" || {
		journalctl -u "${COTURN_UNIT}" -n 20 --no-pager >&2 || true
		die "${COTURN_UNIT} failed to start"
	}
	systemctl is-active --quiet "${CRED_UNIT}" || {
		journalctl -u "${CRED_UNIT}" -n 20 --no-pager >&2 || true
		die "${CRED_UNIT} failed to start"
	}
	info "both services are running"
}

run_verification() {
	info "running the verification suite (includes certbot renew --dry-run)"
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

print_report() {
	local cert_end="" cert_not_before="" version
	version="${COTURN_INSTALLED_VERSION:-unknown}"
	if [[ -r "${TLS_DIR}/fullchain.pem" ]]; then
		cert_end="$(openssl x509 -in "${TLS_DIR}/fullchain.pem" -noout -enddate | cut -d= -f2)"
		cert_not_before="$(openssl x509 -in "${TLS_DIR}/fullchain.pem" -noout -startdate | cut -d= -f2)"
	fi

	cat <<EOF

==========================================================================
Dohcord Relay installation summary
==========================================================================
TURN server          coturn ${version}
                     ${TURN_BINARY}
TURN configuration   ${ETC_DIR}/turnserver.conf (root:turnserver, 0640)
TURN shared secret   ${ETC_DIR}/turn-secret (never committed, never served)
Endpoint config      ${ETC_DIR}/config.env
Credential service   ${BIN}
HTTPS endpoint       https://${PUBLIC_IP}/turn-credentials
TURN URLs            turn:${PUBLIC_IP}:3478?transport=udp
                     turns:${PUBLIC_IP}:5349?transport=tcp
Realm                ${REALM}
Credential lifetime  24h (username <expiresAt>:Dohcord)
TLS certificate      ${TLS_DIR}/fullchain.pem [+ privkey.pem]
                     valid from ${cert_not_before:-?} to ${cert_end:-?}
Renewal              ${RENEW_TIMER} -> ${RENEW_SERVICE}
                     deploy hook ${HOOK}
Services             systemctl status ${COTURN_UNIT} ${CRED_UNIT}
Firewall             80/tcp, 443/tcp, 3478/udp, 5349/tcp, 49152-65535/udp

Service control:
  systemctl status ${COTURN_UNIT} ${CRED_UNIT}
  systemctl restart ${COTURN_UNIT}
  systemctl restart ${CRED_UNIT}
  journalctl -u ${CRED_UNIT} -f
  systemctl list-timers ${RENEW_TIMER}

Re-run the checks at any time with: sudo bash ${REPO_DIR}/deploy/verify.sh
==========================================================================
EOF
}

main() {
	parse_args "$@"
	printf 'Dohcord Relay installer %s\n' "${INSTALLER_VERSION}"

	step_msg "Checking prerequisites"
	check_root_and_os
	install_base_packages

	step_msg "Checking the ports this relay needs"
	check_ports

	step_msg "Detecting network layout"
	detect_network

	step_msg "Creating service users"
	create_service_users

	step_msg "Configuring the firewall"
	configure_firewall

	step_msg "Installing coturn"
	install_coturn

	step_msg "Writing the TURN configuration"
	# coturn writes the log itself; the certificate copies are read-only for it.
	install -d -m 0750 -o root -g dohcord-relay "${TLS_DIR}"
	install -d -m 0750 -o turnserver -g turnserver "${LOG_DIR}"
	write_turn_secret
	render_turnserver_conf
	install_coturn_unit

	step_msg "Building the credential endpoint"
	build_credentials_service
	render_config_env
	install_credentials_unit

	step_msg "Installing the certificate deploy hook"
	install_deploy_hook

	step_msg "Obtaining the IP certificate"
	setup_certbot
	obtain_certificate

	step_msg "Configuring automatic renewal"
	install_renewal

	step_msg "Starting services and verifying"
	start_services
	run_verification || true

	printf '\nInstallation complete.\n'
	print_report
}

main "$@"
