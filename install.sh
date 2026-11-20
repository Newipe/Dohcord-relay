#!/usr/bin/env bash
# Dohcord-relay one-line installer.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/Newipe/Dohcord-relay/main/install.sh)
#
# This is a small bootstrap: it checks the machine, downloads the release
# archive of this repository over HTTPS into a private temporary directory,
# and then hands over to the real installer in deploy/install.sh. Everything
# after that point is the same code a clone-and-run install uses, so there is
# one installer, not two.
#
# It is safe to read: the only remote input is the repository archive from
# github.com, it is never piped into a shell, and the extracted tree is checked
# for the expected files before anything runs. Nothing is written outside
# /tmp until the installer itself starts.
set -Eeuo pipefail

readonly REPO_SLUG="Newipe/Dohcord-relay"
readonly DEFAULT_REF="main"
BOOTSTRAP_VERSION="1.0.0"

REF="${DOHCORD_RELAY_REF:-${DEFAULT_REF}}"
ARCHIVE_URL="${DOHCORD_RELAY_ARCHIVE_URL:-https://codeload.github.com/${REPO_SLUG}/tar.gz/refs/heads/${REF}}"
WORKDIR=""

# --- output -----------------------------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
	C_RESET=$'\033[0m' C_BOLD=$'\033[1m'
	C_CYAN=$'\033[36m' C_GREEN=$'\033[32m' C_RED=$'\033[31m' C_YELLOW=$'\033[33m'
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

banner() {
	cat <<EOF

${C_CYAN}${C_BOLD}  ╭──────────────────────────────────────────────────────╮
  │                                                      │
  │                   Dohcord-relay                      │
  │                   Installation                       │
  │                                                      │
  ╰──────────────────────────────────────────────────────╯${C_RESET}

  Welcome to Dohcord-relay.

  This sets up a private HTTPS proxy and TURN relay for Dohcord on
  this server. The installer checks the machine first, explains what
  it found, and asks before it changes anything.
EOF
}

cleanup() {
	if [[ -n "${WORKDIR}" && -d "${WORKDIR}" ]]; then
		rm -rf -- "${WORKDIR}"
	fi
}
trap cleanup EXIT

usage() {
	cat <<EOF
Dohcord-relay bootstrap ${BOOTSTRAP_VERSION}

Usage: bash <(curl -fsSL https://raw.githubusercontent.com/${REPO_SLUG}/main/install.sh) [installer options]

Downloads the repository archive over HTTPS, then runs deploy/install.sh from
it. Installer options are passed through unchanged:

  --mode domain|ip        How clients reach this relay (asked when omitted).
  --domain NAME           Domain clients use (with --mode domain).
  --ip ADDRESS            Public IPv4 of this relay (detected when omitted).
  --email ADDRESS         Let's Encrypt contact address (optional).
  --staging               Use the Let's Encrypt staging CA (test installs).
  --api-port N            Network Configuration API port (default 8443).
  --version vX.Y.Z        Release to install (default: the latest stable one).
  --yes                   Do not ask for confirmation.
  --skip-verify           Do not run the verification suite at the end.
  --help                  Show the full installer help.

The installer downloads precompiled, checksum-verified binaries from GitHub
Releases; no Go compiler is needed on the server.

Environment (optional):
  DOHCORD_RELAY_REF           Branch or tag to install (default: main).
  DOHCORD_RELAY_ARCHIVE_URL   Full archive URL override (mirrors, tests).
  NO_COLOR                    Disable colour output.

Requirements: Linux with systemd, root via sudo, bash, curl, tar, and outbound
HTTPS access to github.com and your distribution's package mirror.
EOF
}

# run_installer PATH [ARGS...] runs the real installer, elevating only when the
# current user is not root. The path is always an explicit file on disk: a file
# descriptor handed to this shell by process substitution is not assumed to
# survive sudo, and does not.
run_installer() {
	local installer="$1"
	shift

	if [[ ${EUID} -eq 0 ]]; then
		bash "${installer}" "$@"
		return
	fi

	command -v sudo >/dev/null 2>&1 ||
		die "root is required, and sudo was not found. Log in as root, or install sudo and re-run."

	say ""
	say "  ${C_BOLD}Administrator access${C_RESET}"
	info "Dohcord-relay installs system services, so the installer needs root."
	info "You will be asked for ${USER}'s password by sudo, and only this"
	info "downloaded installer is run with those privileges."
	say ""

	# shellcheck disable=SC2024 # stderr redirection is intentional and harmless
	sudo bash "${installer}" "$@" || return $?
}

# local_checkout prints the directory of a checkout that contains this script,
# so `sudo bash install.sh` inside a clone installs the files that are actually
# there instead of downloading a second copy.
local_checkout() {
	local here root
	here="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || return 1
	[[ -f "${here}/deploy/install.sh" && -f "${here}/go.mod" ]] || return 1
	root="${here}"
	printf '%s\n' "${root}"
}

fetch_archive() {
	local dest="$1"

	command -v curl >/dev/null 2>&1 || die "curl is required but not installed (try: apt-get install curl)"
	command -v tar >/dev/null 2>&1 || die "tar is required but not installed"
	command -v gzip >/dev/null 2>&1 || die "gzip is required but not installed"

	info "archive: ${ARCHIVE_URL}"
	if ! curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 \
		--connect-timeout 15 --max-time 180 --retry 2 --retry-delay 2 \
		-o "${dest}" "${ARCHIVE_URL}" 2>/dev/null; then
		# file:// is used by tests and air-gapped mirrors; retry without the
		# HTTPS-only restrictions for that scheme but never for https itself.
		if [[ "${ARCHIVE_URL}" == file://* ]]; then
			curl -fsSL -o "${dest}" "${ARCHIVE_URL}" || die "cannot read ${ARCHIVE_URL}"
		else
			die "could not download the repository archive from ${ARCHIVE_URL}.
       Check the server's internet access and that it can reach github.com,
       then try again. If this machine uses a proxy, export https_proxy first."
		fi
	fi

	[[ -s "${dest}" ]] || die "the downloaded archive is empty; nothing was installed"
	if ! gzip -t "${dest}" 2>/dev/null; then
		die "the downloaded archive is not a valid gzip file; nothing was installed"
	fi
	ok "downloaded $(du -h "${dest}" | cut -f1) archive"
}

main() {
	local args=("$@")

	case "${1:-}" in
	--bootstrap-help)
		usage
		exit 0
		;;
	-h | --help)
		# Answer locally instead of downloading a tree just to print help.
		usage
		exit 0
		;;
	esac

	((BASH_VERSINFO[0] >= 4)) || die "bash 4 or newer is required (found ${BASH_VERSION})"

	# A checkout wins: it is the code the operator can see and modify.
	local checkout
	if checkout="$(local_checkout)"; then
		run_installer "${checkout}/deploy/install.sh" "${args[@]}"
		return
	fi

	banner

	say ""
	say "  ${C_BOLD}Checking this machine${C_RESET}"
	if [[ -r /etc/os-release ]]; then
		# shellcheck disable=SC1091
		info "$( . /etc/os-release; printf '%s' "${PRETTY_NAME:-${NAME:-unknown Linux}}" )"
	else
		info "unknown Linux (no /etc/os-release)"
	fi
	info "kernel $(uname -r), $(uname -m)"
	info "bash ${BASH_VERSION%%(*}"

	WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/dohcord-relay.XXXXXX")" ||
		die "cannot create a temporary directory"
	chmod 0700 "${WORKDIR}"

	say ""
	say "  ${C_BOLD}Downloading Dohcord-relay${C_RESET}"
	fetch_archive "${WORKDIR}/repo.tar.gz"

	# sed reads the whole listing; `head` would close the pipe early and, with
	# pipefail, make a perfectly good archive look unreadable.
	local top
	top="$(tar -tzf "${WORKDIR}/repo.tar.gz" 2>/dev/null | sed -n '1p' | cut -d/ -f1)" ||
		die "cannot read the downloaded archive"
	[[ -n "${top}" ]] || die "the downloaded archive is empty; nothing was installed"
	mkdir -p "${WORKDIR}/src"
	tar -xzf "${WORKDIR}/repo.tar.gz" -C "${WORKDIR}/src" --no-same-owner --no-same-permissions ||
		die "cannot extract the downloaded archive; nothing was installed"

	local repo="${WORKDIR}/src/${top}"
	[[ -f "${repo}/deploy/install.sh" && -f "${repo}/go.mod" &&
		-f "${repo}/cmd/dohcord-relay/main.go" && -f "${repo}/cmd/dohcord-relayd/main.go" ]] ||
		die "the archive does not look like Dohcord-relay (expected deploy/install.sh and the cmd/ entry points); nothing was installed"
	ok "archive looks complete"
	# The installer runs as root in a moment; it only needs to read this tree.
	chmod -R a+rX "${WORKDIR}/src"

	say ""
	say "  ${C_BOLD}Starting the installer${C_RESET}"
	info "the next steps run deploy/install.sh from the downloaded copy"
	info "nothing outside /tmp has been changed yet"
	say ""

	run_installer "${repo}/deploy/install.sh" "${args[@]}"
}

main "$@"
