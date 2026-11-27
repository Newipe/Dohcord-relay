#!/usr/bin/env bash
# Measure what a voice-like UDP stream experiences while one client saturates its
# own bandwidth class, with and without the Pishcord-relay traffic shaper.
#
# This is the harness behind the numbers in the commit messages: it builds a
# throwaway network namespace joined to the host by a veth pair, puts the shaper
# on the host side (so both directions are shaped exactly as on a relay), then
#
#   1. measures the probe with no load            (idle round trip)
#   2. measures it while a bulk UDP flow runs     (what a screen share does)
#   3. applies the shaper and repeats 1 and 2
#   4. optionally repeats with another version of the shaper script, so an old
#      build and a new one can be compared on the same machine
#
# Requirements: root, iproute2 (tc, ip), the ifb module, python3. It refuses to
# run on a host where the real relay's shaping is already active, because it
# installs rules on the host and reuses the shaper's IFB device name.
#
#   sudo scripts/bench-voice-qos.sh --limit 16
#   sudo scripts/bench-voice-qos.sh --limit 16 --compare /tmp/pishcord-relay-tc.old
#
# Everything it creates is removed on exit; --keep leaves the namespace for
# inspection (and prints how to remove it).
set -Eeuo pipefail

readonly NS="pishcord-bench"
readonly HOST_VETH="pb-relay"
readonly CLIENT_VETH="pb-client"
readonly HOST_IP="10.99.0.1"
readonly CLIENT_IP="10.99.0.2"
readonly VOICE_PORT=3478
readonly STATE_DIR="/run/pishcord-relay-bench"

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/deploy/scripts/pishcord-relay-tc"
PROBE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/voice-probe.py"
COMPARE=""
LIMIT=16
SECONDS_UNDER_LOAD=15
BULK_FACTOR=2
KEEP=0
TMP=""

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

  --limit MBIT        TURN per-client-IP cap to apply, Mbit/s (default 16)
  --script PATH       shaper to measure (default: deploy/scripts/pishcord-relay-tc)
  --compare PATH      also measure this other shaper script (for a before/after)
  --seconds N         length of each loaded measurement (default 15)
  --bulk-factor N     bulk load as a multiple of the cap (default 2)
  --keep              keep the network namespace and the rules it installed
  -h, --help          this help
EOF
}

cleanup() {
	local rc=$?
	if ((KEEP)); then
		say "kept ${NS}; remove with: ip netns del ${NS}; ${SCRIPT} stop || true"
	else
		"${SCRIPT}" stop >/dev/null 2>&1 || true
		ip netns del "${NS}" >/dev/null 2>&1 || true
		[[ -n "${TMP}" ]] && rm -rf "${TMP}"
	fi
	return "${rc}"
}

need() {
	command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

preflight() {
	[[ ${EUID} -eq 0 ]] || die "must run as root (netns, tc and ifb need CAP_NET_ADMIN)"
	for tool in ip tc python3; do need "${tool}"; done
	if "${SCRIPT}" status 2>/dev/null | grep -qx 'shaping=active'; then
		die "the relay's shaping is active on this host; run the benchmark on a scratch machine or stop the service first (systemctl stop pishcord-relay-tc)"
	fi
	modprobe ifb >/dev/null 2>&1 || [[ -d /sys/module/ifb ]] || die "the ifb kernel module is unavailable"
	ip netns list 2>/dev/null | grep -qx "${NS}.*" && die "namespace ${NS} already exists; ip netns del ${NS}"
}

setup_netns() {
	TMP="$(mktemp -d "${TMPDIR:-/tmp}/pishcord-bench.XXXXXX")"
	ip netns add "${NS}"
	ip link add "${HOST_VETH}" type veth peer name "${CLIENT_VETH}"
	ip link set "${CLIENT_VETH}" netns "${NS}"
	ip addr add "${HOST_IP}/24" dev "${HOST_VETH}"
	ip link set "${HOST_VETH}" up
	ip netns exec "${NS}" ip link set lo up
	ip netns exec "${NS}" ip addr add "${CLIENT_IP}/24" dev "${CLIENT_VETH}"
	ip netns exec "${NS}" ip link set "${CLIENT_VETH}" up
	# The client's own qdisc must not be the bottleneck: leave a large queue and
	# no shaping there, so everything measured happens on the relay side.
	ip netns exec "${NS}" ip link set "${CLIENT_VETH}" txqueuelen 10000
	ip netns exec "${NS}" ip route add default via "${HOST_IP}" 2>/dev/null || true
}

write_config() {
	cat >"${TMP}/bench.env" <<EOF
HTTPS_PROXY_URL=https://bench.invalid:443
PROXY_UPLOAD_LIMIT_MBIT=0
PROXY_DOWNLOAD_LIMIT_MBIT=0
TURN_UPLOAD_LIMIT_MBIT=${LIMIT}
TURN_DOWNLOAD_LIMIT_MBIT=${LIMIT}
TC_MAX_CLIENTS=512
TC_IDLE_SECONDS=60
TC_REFRESH_SECONDS=1
EOF
}

apply_shaper() { # script-path
	PISHCORD_RELAY_TC_STATE="${STATE_DIR}" \
		PISHCORD_RELAY_TC_FAKE_CLIENTS="${CLIENT_IP}" \
		"$1" apply --interface "${HOST_VETH}" --config "${TMP}/bench.env"
}

stop_shaper() {
	PISHCORD_RELAY_TC_STATE="${STATE_DIR}" \
		"${SCRIPT}" stop --interface "${HOST_VETH}" --config "${TMP}/bench.env" >/dev/null 2>&1 || true
}

# measure LABEL runs the voice probe twice: idle (for the added-latency
# baseline) and while a bulk flow at BULK_FACTOR times the cap runs from the
# same client address, which is what makes it share the client's class.
measure() { # label
	local label="$1" idle loaded baseline
	python3 "${PROBE}" echo --bind "${HOST_IP}" --port "${VOICE_PORT}" >"${TMP}/echo.log" 2>&1 &
	local echo_pid=$!
	sleep 1
	idle="$(ip netns exec "${NS}" python3 "${PROBE}" send \
		--target "${HOST_IP}:${VOICE_PORT}" --seconds 5 2>/dev/null | head -1)"
	baseline="$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["rtt_ms"]["p50"])' "${idle}" 2>/dev/null || echo 0)"
	ip netns exec "${NS}" python3 "${PROBE}" flood \
		--target "${HOST_IP}:${VOICE_PORT}" --mbps $((LIMIT * BULK_FACTOR)) \
		--seconds $((SECONDS_UNDER_LOAD + 2)) >/dev/null 2>&1 &
	local flood_pid=$!
	sleep 1
	loaded="$(ip netns exec "${NS}" python3 "${PROBE}" send \
		--target "${HOST_IP}:${VOICE_PORT}" --seconds "${SECONDS_UNDER_LOAD}" \
		--baseline-ms "${baseline}" 2>/dev/null | head -1)"
	wait "${flood_pid}" 2>/dev/null || true
	kill "${echo_pid}" 2>/dev/null || true
	wait "${echo_pid}" 2>/dev/null || true
	printf '%s\t%s\t%s\n' "${label}" "${idle}" "${loaded}" >>"${TMP}/results"
	say "  ${label}: $(python3 -c '
import json, sys
d = json.loads(sys.argv[1])
r = d.get("rtt_ms", {})
print("p50 %.1f ms  p95 %.1f ms  p99 %.1f ms  jitter %.1f ms  loss %.2f%%  (%d/%d packets)" % (
    r.get("p50", 0), r.get("p95", 0), r.get("p99", 0), d.get("jitter_ms", 0),
    d.get("loss_pct", 0), d.get("received", 0), d.get("sent", 0)))
' "${loaded}")"
}

report() {
	say ""
	say "Comparison (voice stream under a bulk flow at $((LIMIT * BULK_FACTOR)) Mbit/s, cap ${LIMIT} Mbit/s)"
	say ""
	printf '  %-26s %10s %10s %10s %10s %8s\n' "measurement" "p50 ms" "p95 ms" "p99 ms" "jitter" "loss %"
	while IFS=$'\t' read -r label _idle loaded; do
		python3 -c '
import json, sys
label, raw = sys.argv[1], sys.argv[2]
d = json.loads(raw)
r = d.get("rtt_ms", {})
print("  %-26s %10.1f %10.1f %10.1f %10.1f %8.2f" % (
    label, r.get("p50", 0), r.get("p95", 0), r.get("p99", 0),
    d.get("jitter_ms", 0), d.get("loss_pct", 0)))
' "${label}" "${loaded}"
	done <"${TMP}/results"
	say ""
}

main() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--limit) LIMIT="${2:-}"; shift 2 ;;
		--script) SCRIPT="${2:-}"; shift 2 ;;
		--compare) COMPARE="${2:-}"; shift 2 ;;
		--seconds) SECONDS_UNDER_LOAD="${2:-}"; shift 2 ;;
		--bulk-factor) BULK_FACTOR="${2:-}"; shift 2 ;;
		--keep) KEEP=1; shift ;;
		-h | --help) usage; exit 0 ;;
		*) die "unknown option: $1 (see --help)" ;;
		esac
	done
	[[ "${LIMIT}" =~ ^[0-9]+$ ]] && ((LIMIT > 0)) || die "--limit must be a positive whole number of Mbit/s"
	[[ -x "${SCRIPT}" ]] || die "shaper script is not executable: ${SCRIPT}"
	[[ -r "${PROBE}" ]] || die "probe is missing: ${PROBE}"

	preflight
	trap cleanup EXIT
	setup_netns
	write_config
	: >"${TMP}/results"

	say "baseline: no shaping on ${HOST_VETH}"
	measure "unshaped"
	say "applying ${SCRIPT}"
	stop_shaper
	apply_shaper "${SCRIPT}" >/dev/null
	measure "shaped (${SCRIPT##*/})"
	if [[ -n "${COMPARE}" ]]; then
		[[ -x "${COMPARE}" ]] || die "compare script is not executable: ${COMPARE}"
		say "applying ${COMPARE}"
		stop_shaper
		apply_shaper "${COMPARE}" >/dev/null
		measure "shaped (${COMPARE##*/})"
	fi
	report
	say "Raw JSON per phase is in ${TMP}/results (kept until this script exits)."
}

main "$@"
