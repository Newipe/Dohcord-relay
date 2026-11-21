# Installation

## Supported systems

| | |
|---|---|
| Debian | 12 and newer |
| Ubuntu | 22.04 and newer |
| Init | systemd (required) |
| Architectures | `amd64` and `arm64`, plus whatever your distribution builds Squid and coturn for |
| Access | root, or a user with `sudo` |

The installer refuses to run on other distributions rather than half-configuring
them, and warns (but continues) on older releases it has not been tested on.

## Release binaries

Normal installations use precompiled binaries published on GitHub Releases.
**No Go toolchain or compiler is installed or required on the server.**

| Asset | Architecture |
|---|---|
| `dohcord-relay_linux_amd64.tar.gz` | Linux x86-64 (`x86_64`, `amd64`) |
| `dohcord-relay_linux_arm64.tar.gz` | Linux ARM64 (`aarch64`, `arm64`) |
| `checksums.txt` | SHA256 for every archive |

Each archive contains `dohcord-relay` (management console), `dohcord-relayd`
(daemon) and `README.md`. The installer maps `uname -m` to one of these assets,
downloads the archive and `checksums.txt` from the selected release, verifies the
SHA256 before extracting anything, and stops with an error on any unsupported
architecture or verification failure. It never falls back to an unverified file
and never compiles from source.

By default the latest stable release is installed. Pass `--version vX.Y.Z` to
install a specific one.

## Before you start

1. A server with a public IPv4 address. One-to-one NAT (EC2 and similar) is
   detected and handled.
2. One of:
   - **A domain** (recommended) — an A record pointing at the server. AAAA records
     are fine only if the server has working IPv6; the installer checks and stops
     if clients would prefer a route that does not exist.
   - **An address-only install** — no DNS needed; a short-lived IP certificate is
     issued and renewed automatically.
3. Inbound ports open in the host firewall **and** any cloud security group:
   `80/tcp`, `443/tcp`, `8443/tcp` (or the API port you choose), `3478/udp`,
   `5349/tcp`, `49152-65535/udp`.
4. Outbound HTTPS, and port 80 reachable *from the internet* at install time for
   the HTTP-01 challenge.

## One-line install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Newipe/Dohcord-relay/main/install.sh)
```

What the bootstrap does, in order:

1. prints the banner and the machine it detected;
2. downloads `https://codeload.github.com/Newipe/Dohcord-relay/tar.gz/refs/heads/main`
   into a `0700` temporary directory, refusing empty or non-gzip responses;
3. checks the extracted tree for `deploy/install.sh`, `go.mod`, `cmd/dohcord-relay/main.go` and `cmd/dohcord-relayd/main.go`;
4. re-runs the installer with `sudo` when you are not root — always as an
   explicit file on disk, never through the process-substitution descriptor;
5. removes the temporary directory afterwards.

Nothing outside `/tmp` is touched before the installer starts, and the archive is
never piped into a shell.

### From a checkout

```bash
git clone https://github.com/Newipe/Dohcord-relay
cd Dohcord-relay
sudo bash deploy/install.sh
```

Running `bash install.sh` inside a checkout uses that checkout instead of
downloading anything, so local changes are what gets installed.

## Installer options

| Option | Meaning |
|---|---|
| `--mode domain` / `--mode ip` | How clients reach the relay. Asked interactively when omitted. |
| `--domain NAME` | Domain name (with `--mode domain`). |
| `--ip ADDRESS` | Public IPv4. Detected when omitted. |
| `--email ADDRESS` | Optional Let's Encrypt contact address. |
| `--staging` | Use the staging CA for a throwaway test install. |
| `--yes` | Do not ask for confirmation (still needs `--mode`). |
| `--realm NAME` | TURN realm (default: the domain, or `dohcord.relay`). |
| `--distro-coturn` | Use the distribution's coturn instead of the pinned upstream build. |
| `--coturn-version V` | Upstream coturn release to build (default `4.18.0`, SHA-256 checked). |
| `--user-quota N` | Allocations per credential (default 12). |
| `--total-quota N` | Allocations for the relay (default 1200). |
| `--max-bps N` | Per-session bandwidth ceiling, bytes/s (default 2000000). |
| `--bps-capacity N` | Total relay bandwidth reservation (default 250000000). |
| `--max-connections N` | Concurrent proxy connections per client IP (default 100). Interactive installs always show it and let you change it (Enter keeps the configured value on a re-run). Use this with `--yes` for automation. |
| `--api-port N` | Network Configuration API port (default 8443). Interactive installs always show the port and let you change it (Enter keeps the configured one on a re-run). Use this with `--yes` for automation. |
| `--version vX.Y.Z` | Release to install. Defaults to the latest stable GitHub Release. `1.1.0` is accepted and normalised to `v1.1.0`. |
| `--skip-renew-test` | Skip the certbot renewal dry run at the end. |
| `--skip-verify` | Skip the verification suite at the end. |
| `-h`, `--help` | Show the help. |

Non-interactive install, fully specified:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Newipe/Dohcord-relay/main/install.sh) \
  --mode domain --domain relay.example.com --email you@example.com \
  --api-port 8443 --version v1.1.0 --yes
```

Omitting `--api-port` uses `8443` on a fresh install and keeps the port already
configured when re-running over an existing installation; pass another free
port (1024-65535) for a custom endpoint. Interactive installs always ask, with
the current value as the default, and `--yes` or a non-interactive run keeps the
configured port without asking.

Omitting `--max-connections` uses `100` on a fresh install and keeps the limit
recorded in `/etc/dohcord-relay/squid.conf` when re-running. Interactive
installs always ask for it too, with the current value as the default, so the
per-client connection ceiling can be changed without editing the template.

## What the installer changes

| Step | Effect |
|---|---|
| Packages | Installs Squid (the OpenSSL build, required so the proxy sends the full certificate chain), coturn, a private certbot ≥ 5.4 in `/opt/dohcord-relay-certbot`, base tools |
| Users | Creates `dohcord-relay` and `turnserver` system users |
| Binaries | Downloads the release archive for this architecture, verifies it against `checksums.txt`, and installs `/usr/local/bin/dohcord-relayd` (server) and `/usr/local/bin/dohcord-relay` (management console); no compiler is installed |
| Files | Writes `/etc/dohcord-relay/*`, the `dohcord-relay-manager` alias, `/usr/local/bin/dohcord-relay-tls-deploy`, `/usr/local/lib/dohcord-relay/*` |
| Units | Installs and enables `dohcord-relay-api`, `dohcord-relay-squid`, `dohcord-relay-coturn`, and the renewal timer every 6 h |
| Firewall | Opens the relay ports in `ufw` or `firewalld` if one is active, including the selected API port; removes an obsolete API port rule from a previous run, never resets unrelated rules, and warns if SSH is not allowed |
| Certificates | Requests one certificate for the domain or address, installs it into `/etc/dohcord-relay/tls` through a deploy hook |
| Policy | Validates the bundled destination policy and generates the Squid ACLs |

It does **not**: change SSH configuration, replace your web server, stop
unrelated services, remove packages, or reset the firewall.

## Re-running and idempotency

The installer is safe to repeat:

- an existing `config.env` is kept; only missing keys are appended;
- the configured API port is detected and preserved — upgrades are never asked
  to choose a port again;
- the installed release is replaced only after its archive passes checksum
  verification; the previous executables are backed up first;
- existing policy files are kept — your added destinations survive;
- a valid, unexpired certificate covering the address is reused, not reissued;
- the TURN secret is preserved, so issued credentials stay valid;
- units are rewritten identically and restarted, not duplicated;
- ports already held by the relay's own services are treated as free.

## After installation

```bash
sudo dohcord-relay          # management console
curl -sS https://relay.example.com:8443/network-config | python3 -m json.tool
```

To upgrade later, run `sudo dohcord-relay update` (or the one-line installer); the
updater downloads and verifies the new release and rolls back the executables if
the service does not start. Configuration, certificates and policy are untouched.

In Dohcord: **Settings → Custom Profile → add server**, paste
`https://relay.example.com:8443/network-config` (use your chosen port if it is
not 8443), save, select it.

## If installation fails

The installer stops at the failed step and changes nothing further. Re-running
the same command resumes safely. Common causes:

| Message | Fix |
|---|---|
| `unsupported distribution` | Use Debian 12+/Ubuntu 22.04+, or install manually (not supported) |
| `port(s) … already in use` | Stop the conflicting service; the installer never takes over a web server |
| `unsupported architecture` | Releases exist for linux/amd64 and linux/arm64 only |
| `cannot download …` / `SHA256 verification failed` | Check access to github.com; the installed binaries were not changed. Retry or pass a specific `--version` |
| `has no A record` / `resolves to …, which is not …` | Fix DNS, wait for propagation |
| `has an AAAA record … but this host has no global IPv6` | Remove the AAAA record or add IPv6 |
| `certificate issuance failed` | Port 80 blocked, or DNS not pointing here |
| `Squid rejected the generated policy` | The bundled policy did not validate; report the output |

Full recovery guidance: [operations/troubleshooting.md](operations/troubleshooting.md).
