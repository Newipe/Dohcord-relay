#!/usr/bin/env bash
# Dohcord-relay uninstaller.
#
# Removes the services, units, binaries and runtime files this project installs.
# Your configuration, domain policy and TLS certificates are kept unless you ask
# for them to be removed, because they are the expensive things to recreate.
#
#   sudo bash uninstall.sh              # remove software, keep configuration
#   sudo bash uninstall.sh --purge      # also remove configuration and policy
#   sudo bash uninstall.sh --purge-cert # also delete the Let's Encrypt lineage
#   sudo bash uninstall.sh --yes        # no interactive confirmation
set -Eeuo pipefail

ETC_DIR="/etc/dohcord-relay"
LOG_DIR="/var/log/dohcord-relay"
WEBROOT="/var/www/dohcord-relay"
LIB_DIR="/usr/local/lib/dohcord-relay"
DAEMON="/usr/local/bin/dohcord-relayd"
CLI="/usr/local/bin/dohcord-relay"
MANAGER="/usr/local/bin/dohcord-relay-manager"
HOOK="/usr/local/bin/dohcord-relay-tls-deploy"
CERT_NAME="dohcord-relay"
CERTBOT="/opt/dohcord-relay-certbot/bin/certbot"

UNIT_DIR="/etc/systemd/system"
UNITS=(
	dohcord-relay-api.service
	dohcord-relay-squid.service
	dohcord-relay-coturn.service
	dohcord-relay-certbot-renew.timer
	dohcord-relay-certbot-renew.service
	dohcord-relay-credentials.service
)
RUN_DIRS=(
	/run/dohcord-relay-squid
	/run/dohcord-relay-coturn
)

PURGE=0
PURGE_CERT=0
ASSUME_YES=0

if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
	C_RESET=$'\033[0m' C_BOLD=$'\033[1m' C_CYAN=$'\033[36m'
	C_GREEN=$'\033[32m' C_RED=$'\033[31m' C_YELLOW=$'\033[33m'
else
	C_RESET="" C_BOLD="" C_CYAN="" C_GREEN="" C_RED="" C_YELLOW=""
fi
say() { printf '%s\n' "$*"; }
info() { printf '  %s\n' "$*"; }
ok() { printf '  %s✓%s %s\n' "${C_GREEN}" "${C_RESET}" "$*"; }
warn() { printf '  %s!%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
die() {
	printf '\n  %s✗ %s%s\n\n' "${C_RED}" "$*" "${C_RESET}" >&2
	exit 1
}

usage() {
	cat <<EOF
Dohcord-relay uninstaller

Usage: sudo bash uninstall.sh [options]

  (no options)     Remove services, units, binaries and runtime files.
                   Keep ${ETC_DIR} (configuration, domain policy, certificates).
  --purge          Also remove ${ETC_DIR} and ${LOG_DIR}.
  --purge-cert     Also delete the Let's Encrypt certificate "${CERT_NAME}".
  --yes            Do not ask for confirmation (for scripted removal).
  -h, --help       Show this help.

Not removed automatically: the squid and coturn packages, and firewall rules.
Both are reported at the end with the commands to remove them yourself.
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--purge) PURGE=1 ;;
	--purge-cert) PURGE_CERT=1 ;;
	--yes | -y) ASSUME_YES=1 ;;
	-h | --help)
		usage
		exit 0
		;;
	*) die "unknown option: $1 (see --help)" ;;
	esac
	shift
done

[[ ${EUID} -eq 0 ]] || die "must run as root (use sudo)"

banner=$(
	cat <<EOF

${C_CYAN}${C_BOLD}  ── Dohcord-relay uninstall ──${C_RESET}

  This will remove:

    · the services ${C_BOLD}dohcord-relay-api${C_RESET}, ${C_BOLD}dohcord-relay-squid${C_RESET} and ${C_BOLD}dohcord-relay-coturn${C_RESET}
    · their systemd units and the certificate renewal timer
    · ${DAEMON} and ${CLI}
    · ${MANAGER} (compatibility alias)
    · ${HOOK}
    · ${LIB_DIR}
    · ${WEBROOT} and ${LOG_DIR}
EOF
)
if [[ ${PURGE} -eq 1 ]]; then
	banner+=$'\n'"    · ${ETC_DIR} — configuration, domain policy and TLS certificates"
fi
if [[ ${PURGE_CERT} -eq 1 ]]; then
	banner+=$'\n'"    · the Let's Encrypt certificate \"${CERT_NAME}\" and its account lineage"
fi
banner+=$'\n\n'"  Kept: the squid and coturn packages, firewall rules, and the"
banner+=$'\n'"  system user dohcord-relay (removed only with --purge)."
if [[ ${PURGE} -eq 0 ]]; then
	banner+=$'\n\n'"  ${C_YELLOW}Your configuration, policy and certificates are kept.${C_RESET} A re-install"
	banner+=$'\n'"  reuses them, so the relay comes back with the same identity."
fi
say "${banner}"
say ""

if [[ ${ASSUME_YES} -eq 0 ]]; then
	[[ -t 0 ]] || die "no terminal to confirm on; re-run with --yes to uninstall non-interactively"
	printf '  Type %suninstall%s to continue: ' "${C_BOLD}" "${C_RESET}"
	read -r answer
	[[ "${answer}" == "uninstall" ]] || die "cancelled; nothing was changed"
fi

# --- 1. services ------------------------------------------------------------
say "  ${C_BOLD}Stopping services${C_RESET}"
for unit in "${UNITS[@]}"; do
	if systemctl list-unit-files "${unit}" >/dev/null 2>&1 &&
		systemctl cat "${unit}" >/dev/null 2>&1; then
		systemctl disable --now "${unit}" >/dev/null 2>&1 || true
		ok "stopped ${unit}"
	fi
done

# --- 2. units ---------------------------------------------------------------
say ""
say "  ${C_BOLD}Removing systemd units${C_RESET}"
removed_unit=0
for unit in "${UNITS[@]}"; do
	if [[ -f "${UNIT_DIR}/${unit}" ]]; then
		rm -f "${UNIT_DIR}/${unit}"
		removed_unit=1
		ok "removed ${UNIT_DIR}/${unit}"
	fi
done
[[ ${removed_unit} -eq 1 ]] || info "no Dohcord-relay units were installed"
systemctl daemon-reload
systemctl reset-failed >/dev/null 2>&1 || true

# --- 3. binaries and libraries ---------------------------------------------
say ""
say "  ${C_BOLD}Removing programs${C_RESET}"
# Remove the alias before the binary it points at. ${CLI} also covers a daemon
# left there by a pre-rename release.
for file in "${MANAGER}" "${DAEMON}" "${CLI}" "${HOOK}"; do
	if [[ -e "${file}" ]]; then
		rm -f "${file}"
		ok "removed ${file}"
	fi
done
if [[ -d "${LIB_DIR}" ]]; then
	rm -rf -- "${LIB_DIR}"
	ok "removed ${LIB_DIR}"
fi

# --- 4. runtime data --------------------------------------------------------
say ""
say "  ${C_BOLD}Removing runtime files${C_RESET}"
for dir in "${RUN_DIRS[@]}"; do
	if [[ -d "${dir}" ]]; then
		rm -rf -- "${dir}"
		ok "removed ${dir}"
	fi
done
if [[ -d "${WEBROOT}" ]]; then
	rm -rf -- "${WEBROOT}"
	ok "removed ${WEBROOT} (ACME challenge directory)"
fi
if [[ -d "${LOG_DIR}" ]]; then
	rm -rf -- "${LOG_DIR}"
	ok "removed ${LOG_DIR}"
fi

# --- 5. optional data -------------------------------------------------------
if [[ ${PURGE} -eq 1 ]]; then
	say ""
	say "  ${C_BOLD}Removing configuration and certificates${C_RESET}"
	if [[ -d "${ETC_DIR}" ]]; then
		rm -rf -- "${ETC_DIR}"
		ok "removed ${ETC_DIR}"
	fi
	if id -u dohcord-relay >/dev/null 2>&1; then
		userdel dohcord-relay >/dev/null 2>&1 || warn "could not remove the dohcord-relay user (it may still own files)"
		ok "removed the dohcord-relay system user"
	fi
	if [[ -d /opt/dohcord-relay-certbot ]]; then
		rm -rf -- /opt/dohcord-relay-certbot
		ok "removed the private certbot installation"
	fi
else
	say ""
	info "kept ${ETC_DIR} (configuration, policy, certificates)"
fi

if [[ ${PURGE_CERT} -eq 1 ]]; then
	say ""
	say "  ${C_BOLD}Deleting the Let's Encrypt certificate${C_RESET}"
	cb=""
	if [[ -x "${CERTBOT}" ]]; then
		cb="${CERTBOT}"
	elif command -v certbot >/dev/null 2>&1; then
		cb="$(command -v certbot)"
	fi
	if [[ -n "${cb}" ]]; then
		if "${cb}" delete --cert-name "${CERT_NAME}" --non-interactive >/dev/null 2>&1; then
			ok "deleted certificate ${CERT_NAME}"
		else
			warn "certbot could not delete ${CERT_NAME}; remove /etc/letsencrypt/live/${CERT_NAME} yourself"
		fi
	else
		warn "certbot not found; remove /etc/letsencrypt/live/${CERT_NAME} yourself"
	fi
fi

# --- 6. summary -------------------------------------------------------------
cat <<EOF

  ${C_GREEN}${C_BOLD}Dohcord-relay has been removed from this server.${C_RESET}

  Still present, remove them yourself if you want them gone:

    packages      apt-get remove --purge squid-openssl coturn
    firewall      ufw status numbered      (delete the Dohcord-relay rules)
                  firewall-cmd --remove-port=443/tcp   ... for each opened port

  Re-install any time with the one-line command in the README.
  ${C_BOLD}It will reuse your configuration and certificates.${C_RESET}

EOF
