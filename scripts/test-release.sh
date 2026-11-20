#!/usr/bin/env bash
# Tests for the release pipeline and the precompiled-binary installer.
#
# Covers: both supported architectures build, asset names and checksums are
# correct, architecture detection, version selection (explicit and latest),
# checksum enforcement, failed downloads leaving working binaries untouched,
# the installer never compiling, and the management console's download helpers.
#
# Runs entirely in a temporary directory without root. Skips when Go is absent.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dohcord-relay-release-test.XXXXXX")"
trap 'rm -rf -- "${TMP}"' EXIT

if ! command -v go >/dev/null 2>&1; then
	printf 'SKIP  go is required to build the release fixtures\n'
	exit 0
fi
for tool in openssl curl python3 tar sha256sum; do
	command -v "${tool}" >/dev/null 2>&1 || {
		printf 'SKIP  %s is required for the release tests\n' "${tool}"
		exit 0
	}
done

fail=0
ok() { printf 'PASS  %s\n' "$*"; }
bad() {
	printf 'FAIL  %s\n' "$*"
	fail=1
}

# Installer function library with fixture paths. The real script is used; only
# ownership flags, fixed install paths and the final main call are adjusted so
# the tests can run unprivileged.
sed -e "s|readonly ETC_DIR=\"/etc/dohcord-relay\"|readonly ETC_DIR=\"${TMP}/etc\"|" \
	-e "s|readonly WEBROOT=\"/var/www/dohcord-relay\"|readonly WEBROOT=\"${TMP}/webroot\"|" \
	-e "s|readonly DAEMON=\"/usr/local/bin/dohcord-relayd\"|readonly DAEMON=\"${TMP}/bin/dohcord-relayd\"|" \
	-e "s|readonly CLI=\"/usr/local/bin/dohcord-relay\"|readonly CLI=\"${TMP}/bin/dohcord-relay\"|" \
	-e "s|/var/backups/dohcord-relay|${TMP}/backups|g" \
	-e 's/-o root -g root //g' \
	-e '$d' "${REPO}/deploy/install.sh" >"${TMP}/install-lib.sh"
sed -i 's|^[[:space:]]*install -d -m 0755 -o root -g root "${WEBROOT}"$|:|' "${TMP}/install-lib.sh"
sed -e "s|^main \"\$@\"$||" "${REPO}/deploy/scripts/dohcord-relay-manager.sh" >"${TMP}/manager-lib.sh"
mkdir -p "${TMP}/etc" "${TMP}/bin"

# --- build both supported architectures -------------------------------------
build_bins() { # build_bins ARCH DEST [VERSION]
	local arch="$1" dest="$2" version="${3:-v1.2.3}"
	mkdir -p "${dest}"
	CGO_ENABLED=0 GOOS=linux GOARCH="${arch}" go build -trimpath -buildvcs=false \
		-ldflags "-s -w \
			-X github.com/Newipe/Dohcord-relay/internal/buildinfo.Version=${version} \
			-X github.com/Newipe/Dohcord-relay/internal/buildinfo.Commit=testsha \
			-X github.com/Newipe/Dohcord-relay/internal/buildinfo.Date=2026-01-01T00:00:00Z" \
		-o "${dest}/dohcord-relayd" ./cmd/dohcord-relayd || return 1
	CGO_ENABLED=0 GOOS=linux GOARCH="${arch}" go build -trimpath -buildvcs=false \
		-ldflags "-s -w \
			-X github.com/Newipe/Dohcord-relay/internal/buildinfo.Version=${version} \
			-X github.com/Newipe/Dohcord-relay/internal/buildinfo.Commit=testsha \
			-X github.com/Newipe/Dohcord-relay/internal/buildinfo.Date=2026-01-01T00:00:00Z" \
		-o "${dest}/dohcord-relay" ./cmd/dohcord-relay || return 1
	cp "${REPO}/README.md" "${dest}/README.md"
}

REL="${TMP}/releases/v1.2.3"
mkdir -p "${REL}"
built=0
for arch in amd64 arm64; do
	stage="${TMP}/stage-${arch}"
	if build_bins "${arch}" "${stage}"; then
		tar -C "${stage}" -czf "${REL}/dohcord-relay_linux_${arch}.tar.gz" \
			dohcord-relay dohcord-relayd README.md
		listing="$(tar -tzf "${REL}/dohcord-relay_linux_${arch}.tar.gz")"
		if grep -qx dohcord-relayd <<<"${listing}"; then
			ok "built linux/${arch} archive with both executables"
			built=$((built + 1))
		else
			bad "linux/${arch} archive is missing dohcord-relayd"
		fi
	else
		bad "linux/${arch} cross-build failed"
	fi
done
if [[ ${built} -eq 2 ]]; then
	(
		cd "${REL}" || exit 1
		sha256sum ./*.tar.gz | sed 's|\./||' >checksums.txt
	)
	if (cd "${REL}" && sha256sum -c checksums.txt >/dev/null); then
		ok "checksums.txt verifies both architecture archives"
	else
		bad "checksums.txt does not verify"
	fi
else
	bad "not every architecture archive was built"
fi

# --- architecture detection -------------------------------------------------
for pair in "x86_64 amd64" "amd64 amd64" "aarch64 arm64" "arm64 arm64"; do
	set -- ${pair}
	got="$(bash -c '
set -Eeuo pipefail
source "'"${TMP}"'/install-lib.sh"
native_release_arch "'"$1"'"
')"
	if [[ "${got}" == "$2" ]]; then
		ok "architecture $1 maps to $2"
	else
		bad "architecture $1 mapped to ${got}, expected $2"
	fi
done

mkdir -p "${TMP}/fakebin-riscv"
cat >"${TMP}/fakebin-riscv/uname" <<'EOF'
#!/bin/sh
case "$1" in
-m) echo riscv64 ;;
-s) echo Linux ;;
*) /usr/bin/uname "$@" ;;
esac
EOF
chmod +x "${TMP}/fakebin-riscv/uname"
if PATH="${TMP}/fakebin-riscv:${PATH}" bash -c '
set -Eeuo pipefail
source "'"${TMP}"'/install-lib.sh"
detect_release_arch
' >/dev/null 2>&1; then
	bad "an unsupported architecture was accepted"
else
	ok "unsupported architecture is rejected with an error"
fi

# --- version selection ------------------------------------------------------
if out="$(bash -c '
set -Eeuo pipefail
source "'"${TMP}"'/install-lib.sh"
printf "NORMAL=%s\n" "$(normalize_release_tag 1.2.3)"
RELEASE_REQUEST=v1.2.3
resolve_release_tag
printf "TAG=%s\n" "${RELEASE_TAG}"
')" && grep -q '^NORMAL=v1.2.3$' <<<"${out}" && grep -q '^TAG=v1.2.3$' <<<"${out}"; then
	ok "explicit version is normalised and selected"
else
	bad "explicit version selection: ${out}"
fi

printf '{"tag_name": "v1.2.3"}\n' >"${TMP}/latest.json"
if out="$(DOHCORD_RELAY_LATEST_API="file://${TMP}/latest.json" bash -c '
set -Eeuo pipefail
source "'"${TMP}"'/install-lib.sh"
resolve_release_tag
printf "TAG=%s\n" "${RELEASE_TAG}"
')" && grep -q '^TAG=v1.2.3$' <<<"${out}"; then
	ok "latest stable release is resolved when no version is requested"
else
	bad "latest release resolution: ${out}"
fi

if DOHCORD_RELAY_LATEST_API="file://${TMP}/does-not-exist.json" bash -c '
set -Eeuo pipefail
source "'"${TMP}"'/install-lib.sh"
RELEASE_REQUEST=not-a-version
resolve_release_tag
' >/dev/null 2>&1; then
	bad "an invalid version tag was accepted"
else
	ok "invalid version tags are rejected instead of falling back to latest"
fi

# --- installer: verified install and checksum failure -----------------------
if out="$(bash -c '
set -Eeuo pipefail
source "'"${TMP}"'/install-lib.sh"
RELEASE_REQUEST=v1.2.3
RELEASE_BASE_URL="file://'"${TMP}"'/releases"
install_release_binaries
printf "TAG=%s ARCH=%s\n" "${RELEASE_TAG}" "${RELEASE_ARCH}"
')" && grep -q '^TAG=v1.2.3 ARCH=amd64$' <<<"${out}" &&
	"${TMP}/bin/dohcord-relayd" -version | grep -q ' v1.2.3 '; then
	ok "installer downloads, verifies and installs the release binaries"
else
	bad "release install: ${out}"
fi

if grep -qE '(^|[^a-z])go (build|install)' "${REPO}/deploy/install.sh" ||
	grep -q 'golang-go' "${REPO}/deploy/install.sh"; then
	bad "the installer still invokes a Go compiler"
else
	ok "the installer contains no go build/go install step"
fi

# A release whose archive no longer matches checksums.txt must be refused, and
# the working binary must stay byte-for-byte identical.
BAD="${TMP}/releases/v1.2.4"
mkdir -p "${BAD}"
cp "${REL}/dohcord-relay_linux_amd64.tar.gz" "${BAD}/"
cp "${REL}/dohcord-relay_linux_arm64.tar.gz" "${BAD}/"
(cd "${BAD}" && sha256sum ./*.tar.gz | sed 's|\./||' >checksums.txt)
printf 'corrupted\n' >>"${BAD}/dohcord-relay_linux_amd64.tar.gz"
before="$(sha256sum "${TMP}/bin/dohcord-relayd" | cut -d' ' -f1)"
if bash -c '
set -Eeuo pipefail
source "'"${TMP}"'/install-lib.sh"
RELEASE_REQUEST=v1.2.4
RELEASE_BASE_URL="file://'"${TMP}"'/releases"
install_release_binaries
' >/dev/null 2>&1; then
	bad "a corrupted archive was installed"
else
	after="$(sha256sum "${TMP}/bin/dohcord-relayd" | cut -d' ' -f1)"
	if [[ "${before}" == "${after}" ]]; then
		ok "checksum failure leaves the installed binary untouched"
	else
		bad "checksum failure replaced the installed binary"
	fi
fi

# --- management console helpers --------------------------------------------
cat >"${TMP}/etc/install-info" <<'EOF'
INSTALLER_VERSION=2.0.2
RELEASE_VERSION=v1.0.0
RELEASE_ARCH=amd64
MODE=domain
PUBLIC_HOST=relay.example.test
EOF
if out="$(bash -c '
set -Eeuo pipefail
export DOHCORD_RELAY_ETC_DIR="'"${TMP}"'/etc"
export DOHCORD_RELAY_BIN="'"${TMP}"'/bin/dohcord-relayd"
export DOHCORD_RELAY_CONSOLE_BIN="'"${TMP}"'/bin/dohcord-relay"
export DOHCORD_RELAY_RELEASE_BASE_URL="file://'"${TMP}"'/releases"
export NO_COLOR=1
source "'"${TMP}"'/manager-lib.sh"
printf "INSTALLED=%s\n" "$(installed_release_version)"
release_download_archive v1.2.3 "'"${TMP}"'/manager-download"
test -x "${RELEASE_UNPACK}/dohcord-relayd" && printf "UNPACKED=%s\n" "${RELEASE_ASSET}"
record_release_version v1.2.3 amd64
printf "RECORDED=%s\n" "$(info_value RELEASE_VERSION)"
')" && grep -q '^INSTALLED=v1.0.0$' <<<"${out}" &&
	grep -q '^UNPACKED=dohcord-relay_linux_amd64.tar.gz$' <<<"${out}" &&
	grep -q '^RECORDED=v1.2.3$' <<<"${out}"; then
	ok "management console resolves, downloads and records releases"
else
	bad "management console release helpers: ${out}"
fi

# --- updater transaction: replace, record, rollback -------------------------
REL2="${TMP}/releases/v1.3.0"
mkdir -p "${REL2}"
for arch in amd64 arm64; do
	stage="${TMP}/stage130-${arch}"
	if build_bins "${arch}" "${stage}" v1.3.0; then
		tar -C "${stage}" -czf "${REL2}/dohcord-relay_linux_${arch}.tar.gz" \
			dohcord-relay dohcord-relayd README.md
	else
		bad "linux/${arch} v1.3.0 build failed"
	fi
done
(
	cd "${REL2}" || exit 1
	sha256sum ./*.tar.gz | sed 's|\./||' >checksums.txt
)
printf '{"tag_name": "v1.3.0"}\n' >"${TMP}/latest130.json"

MGR="${TMP}/mgrflow"
mkdir -p "${MGR}/etc" "${MGR}/bin" "${MGR}/fakebin"
cp "${TMP}/stage-amd64/dohcord-relayd" "${MGR}/bin/"
cp "${TMP}/stage-amd64/dohcord-relay" "${MGR}/bin/"
cat >"${MGR}/etc/config.env" <<'EOF'
HTTPS_PROXY_URL=https://relay.example.test:443
NETWORK_CONFIG_PORT=8443
NETWORK_CONFIG_URL=https://relay.example.test:8443/network-config
HTTPS_LISTEN=:8443
TURN_URLS=turn:relay.example.test:3478
EOF
cat >"${MGR}/etc/install-info" <<'EOF'
INSTALLER_VERSION=2.0.2
RELEASE_VERSION=v1.2.3
RELEASE_ARCH=amd64
MODE=domain
PUBLIC_HOST=relay.example.test
EOF
cat >"${MGR}/fakebin/systemctl" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"${MGR}/fakebin/journalctl" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "${MGR}/fakebin/systemctl" "${MGR}/fakebin/journalctl"

run_update() { # run_update REACHABLE VERSION -> updates the fixture
	local reachable="$1" version="$2"
	PATH="${MGR}/fakebin:${PATH}" \
		DOHCORD_RELAY_ETC_DIR="${MGR}/etc" \
		DOHCORD_RELAY_BIN="${MGR}/bin/dohcord-relayd" \
		DOHCORD_RELAY_CONSOLE_BIN="${MGR}/bin/dohcord-relay" \
		DOHCORD_RELAY_RELEASE_BASE_URL="file://${TMP}/releases" \
		DOHCORD_RELAY_LATEST_API="file://${TMP}/latest130.json" \
		NO_COLOR=1 \
		bash -c '
set -Eeuo pipefail
source "'"${TMP}"'/manager-lib.sh"
need_root() { :; }
confirm() { return 0; }
api_reachable() { return '"${reachable}"'; }
policy_backup_dir() { printf "%s" "'"${MGR}"'/backups"; }
sleep() { :; }
update_menu <<< "'"${version}"'"; printf "UPDATED\n"
'
}

if out="$(run_update 0 v1.3.0 2>&1)" && grep -q '^UPDATED$' <<<"${out}" &&
	"${MGR}/bin/dohcord-relayd" -version | grep -q ' v1.3.0 ' &&
	grep -q '^RELEASE_VERSION=v1.3.0$' "${MGR}/etc/install-info"; then
	ok "updater replaces the executables, records the version and verifies the API"
else
	bad "updater success path: ${out}"
fi
backup_dir="$(echo "${MGR}"/backups/binaries-*)"
if [[ -f "${backup_dir}/dohcord-relayd" ]] &&
	"${backup_dir}/dohcord-relayd" -version | grep -q ' v1.2.3 '; then
	ok "updater backs up the previous executables"
else
	bad "updater did not back up the previous executables"
fi

# A new binary that never answers must be rolled back to the old one.
cp "${TMP}/stage-amd64/dohcord-relayd" "${MGR}/bin/dohcord-relayd"
cp "${TMP}/stage-amd64/dohcord-relay" "${MGR}/bin/dohcord-relay"
sed -i 's/^RELEASE_VERSION=.*/RELEASE_VERSION=v1.2.3/' "${MGR}/etc/install-info"
before="$(sha256sum "${MGR}/bin/dohcord-relayd" | cut -d' ' -f1)"
if run_update 1 v1.3.0 >/dev/null 2>&1; then
	bad "a release that never answers was accepted"
else
	after="$(sha256sum "${MGR}/bin/dohcord-relayd" | cut -d' ' -f1)"
	if [[ "${before}" == "${after}" ]] &&
		grep -q '^RELEASE_VERSION=v1.2.3$' "${MGR}/etc/install-info"; then
		ok "a failed restart rolls the executables back"
	else
		bad "rollback did not restore the previous executables"
	fi
fi

printf '\nRelease tests: %s\n' "$( ((fail == 0)) && echo 'passed' || echo 'FAILED' )"
exit "${fail}"
