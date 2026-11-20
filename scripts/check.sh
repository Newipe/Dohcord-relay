#!/usr/bin/env bash
# Local check suite: formatting, vet, unit tests and shell syntax.
# Run from anywhere; it always checks the repository root.
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail=0

if ! command -v go >/dev/null 2>&1; then
	printf 'go is not installed; skipping Go checks\n' >&2
	fail=1
else
	if [[ -n "$(gofmt -l cmd internal)" ]]; then
		printf 'gofmt would change:\n%s\n' "$(gofmt -l cmd internal)" >&2
		fail=1
	fi
	go vet ./... || fail=1
	go build ./... || fail=1
	go test ./... || fail=1
fi

bash -n install.sh uninstall.sh deploy/install.sh deploy/scripts/*.sh scripts/*.sh || fail=1

bash scripts/test-api-port.sh || fail=1
bash scripts/test-release.sh || fail=1

if command -v shellcheck >/dev/null 2>&1; then
	shellcheck -S warning install.sh uninstall.sh deploy/install.sh deploy/scripts/*.sh || fail=1
fi

exit "$fail"
