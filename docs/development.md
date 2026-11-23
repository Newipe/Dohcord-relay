# Development and releases

Normal users install verified, precompiled binaries. This document is for people
changing the source or cutting a release.

## Requirements

- Go 1.18 or newer (the version in `go.mod`).
- Bash, `curl`, `openssl` and `python3` for the integration tests.
- No C dependencies: the binaries are built with `CGO_ENABLED=0` and are static.

## Build and test

```bash
go test ./...                    # unit tests for every package
go build ./...                   # both commands, development binaries
make build                       # ./pishcord-relayd and ./pishcord-relay
./scripts/check.sh               # formatting, vet, build, tests, shellcheck, integration tests
```

`make build` stamps the binaries as `dev`. A development binary reports:

```text
pishcord-relayd dev (commit <sha>, built <commit date>, linux/amd64)
pishcord-relay dev (commit <sha>, built <commit date>, linux/amd64)
```

Check it with `./pishcord-relayd -version` or `./pishcord-relay --build-info`.

Integration tests run unprivileged in temporary directories:

```bash
bash scripts/test-api-port.sh    # configurable API port, daemon on a custom port
bash scripts/test-release.sh     # archives, checksums, installer and updater helpers
```

`scripts/test-release.sh` builds linux/amd64 and linux/arm64 fixtures, packages
them as release archives, and exercises the installer's download, verification
and refusal paths against a local `file://` mirror. It never contacts GitHub.

## Continuous integration

`.github/workflows/ci.yml` runs on pushes and pull requests to `main` and:

1. checks `gofmt`;
2. runs `go vet ./...` and `go test ./...`;
3. cross-builds both executables for linux/amd64 and linux/arm64;
4. validates every shell script with `bash -n` and `shellcheck`;
5. runs the API port and release integration tests.

Any failure fails the workflow. CI has read-only permissions and never publishes
a release.

## Cutting a release

Releases are produced only by pushing a semantic version tag:

```bash
git tag v1.1.0
git push origin v1.1.0
```

`.github/workflows/release.yml` then:

1. checks out the tagged commit and repeats the validation (format, vet, tests,
   shell checks, integration tests);
2. builds `pishcord-relayd` and `pishcord-relay` for linux/amd64 and linux/arm64
   with `CGO_ENABLED=0`, `-trimpath`, `-buildvcs=false` and the tag, commit and
   commit date injected through `internal/buildinfo`;
3. packages one archive per architecture:
   `pishcord-relay_linux_amd64.tar.gz`, `pishcord-relay_linux_arm64.tar.gz`
   (each contains both executables and `README.md`);
4. checks that each archive really contains both executables;
5. generates `checksums.txt` with SHA256 for both archives and re-verifies it;
6. creates the GitHub Release with the three assets using the tagged version in
   the title and generated release notes.

The build is reproducible for the same tag: paths are trimmed, VCS stamping is
disabled, the build date is the commit date, and the tar metadata uses the commit
timestamp with fixed ownership. Ordinary commits and pull requests never publish
anything.

Do not upload assets by hand. A release must come from this workflow so the
checksums and binaries always match the tag.

## Installer and updater

`deploy/install.sh` never compiles. It resolves the requested tag (or the latest
stable release), maps `uname -m` to `amd64` or `arm64`, downloads the archive and
`checksums.txt`, verifies SHA256, checks that the payload is a Linux ELF and, on
the native architecture, that the binary reports the same tag. Only then does it
back up and replace the executables.

`pishcord-relay update` performs the same verification in the management console,
backs up the current executables under `/var/backups/pishcord-relay`, restarts
`pishcord-relay-api.service`, confirms the endpoint answers, and restores the
previous executables if it does not.

Configuration, certificates, destination policy and runtime data are never
modified by a binary download or update.

## Manual release check

To exercise the download path without publishing:

```bash
bash scripts/test-release.sh
```

To install from a local mirror on a test server, set
`PISHCORD_RELAY_RELEASE_BASE_URL=file:///path/to/mirror` and
`PISHCORD_RELAY_VERSION=v1.1.0` before running `deploy/install.sh`. These
overrides exist for testing; production installations use GitHub Releases over
HTTPS.
