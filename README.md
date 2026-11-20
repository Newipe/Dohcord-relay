# Dohcord-relay

**A private HTTPS proxy and TURN relay for [Dohcord](https://github.com/Newipe/Dohcord), on your own server.**

Dohcord-relay gives Dohcord a way to reach Discord's HTTPS, WebSocket and voice
endpoints through a server you control, without a VPN and without decrypting
anything. It runs two well-known pieces of software, Squid and coturn, behind a
small HTTPS endpoint that tells the client exactly how to connect.

[![Platform](https://img.shields.io/badge/platform-Debian%2012%20%7C%20Ubuntu%2022.04%2B-0b7285?style=flat-square)](#requirements)
[![Shell](https://img.shields.io/badge/installer-bash%204%2B-2f9e44?style=flat-square)](#quick-installation)
[![Services](https://img.shields.io/badge/services-Squid%20%2B%20coturn%20%2B%20systemd-495057?style=flat-square)](#architecture)

---

## Contents

- [About](#about) · [Features](#features) · [Quick installation](#quick-installation)
- [Architecture](#architecture) · [Requirements](#requirements) · [Configuration](#configuration)
- [Network Configuration API](#network-configuration-api) · [Domain policy](#domain-policy)
- [Management](#management) · [Updating](#updating) · [Troubleshooting](#troubleshooting)
- [Uninstalling](#uninstalling) · [Security](#security) · [Development](#development)
- [Repository layout](#repository-layout) · [Documentation](#documentation)

---

## About

Dohcord is a Discord client. Discord's traffic has two halves: ordinary HTTPS
and WebSocket connections to a handful of domains, and WebRTC media for voice
and video. Dohcord-relay provides a server-side rendezvous for both:

- an **HTTPS CONNECT proxy** (Squid) that accepts encrypted connections and
  forwards them to a **short, server-enforced list of destinations**;
- a **TURN relay** (coturn) for voice and video when a direct connection between
  peers is not possible;
- a **Network Configuration API** (port 8443 by default, configurable at install
  time) that hands Dohcord the proxy address, the routing policy and short-lived
  TURN credentials in one document.

Nothing is intercepted or re-encrypted. Discord's TLS session runs end-to-end
between Dohcord and Discord; the proxy only sees host names and ports, and only
for destinations the relay has been told to allow.

> **Compatibility promise.** The client-facing contract is unchanged by this
> documentation and tooling work: same ports, same endpoints, same JSON, same
> proxy and TURN protocols. An existing Dohcord build keeps working; no client
> update is needed to use this version of the relay. The API port defaults to
> 8443; if an administrator chooses a custom port, the Dohcord profile's Network
> Configuration URL must name that port (the path, JSON, TLS and authentication
> are unchanged).

---

## Features

| | |
|---|---|
| **HTTPS CONNECT proxy** | Squid on TCP 443, CONNECT only, no TLS interception, certificate chain sent to clients. |
| **Selective routing** | Two plain-text policy files decide which hosts and ports may be reached. Everyone else gets `403`. |
| **Server-side enforcement** | The client is never trusted: limits, destination checks and resolved-address checks all happen on the server. |
| **TURN relay** | coturn on 3478/udp and 5349/tcp with REST credentials and a bounded relay range. |
| **Network Configuration API** | One HTTPS document (`/network-config`) with the proxy endpoint, routing rules and temporary credentials. |
| **Automated certificates** | certbot with a deploy hook and a systemd timer, including IP certificates for address-only installs. |
| **Management console** | `dohcord-relay` for status, policy, certificates, updates, repair and uninstall. |
| **Idempotent installer** | Re-running it keeps your configuration, policy and certificates. |

---

## Quick installation

On a fresh Debian 12 or Ubuntu 22.04+ server, as a user with `sudo`:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Newipe/Dohcord-relay/main/install.sh)
```

That single command:

1. checks the machine (distribution, architecture, internet access, busy ports);
2. downloads this repository's archive over HTTPS into a private temporary
   directory — the archive is extracted, never piped into a shell;
3. asks how clients should reach the server (a domain name, recommended, or the
   public IPv4 address) and, on a fresh install, the Network Configuration API
   port (8443 by default), then shows every setting before changing anything;
4. installs Squid, coturn and a pinned certbot, then downloads the verified
   precompiled relay binaries for this server's architecture;
5. obtains a TLS certificate, opens the required firewall ports, installs the
   systemd services and validates the configuration;
6. runs the verification suite and prints the URLs to paste into Dohcord.

When it finishes you get the line to add in **Dohcord → Settings → Custom
Profile**:

```text
https://relay.example.com:8443/network-config
```

and a management console:

```bash
sudo dohcord-relay
```

`dohcord-relay` is the management command; the previous `dohcord-relay-manager`
name remains installed as an alias. The background server is `dohcord-relayd`,
run by `dohcord-relay-api.service`; you do not normally start it yourself.

**No compiler is required on the server.** The installer downloads
`dohcord-relay_linux_amd64.tar.gz` or `dohcord-relay_linux_arm64.tar.gz` from
the matching GitHub Release, verifies it against the release's `checksums.txt`,
and only then installs the two executables. Supported targets are **linux/amd64**
and **linux/arm64**; any other architecture stops with a clear error. `--version
v1.1.0` installs a specific release, and omitting it installs the latest stable
one. A download or checksum failure leaves the currently installed binaries
untouched.

Requirements and options are in [docs/installation.md](docs/installation.md).
The installer needs root (it uses `sudo` itself when started as a normal user),
outbound HTTPS to github.com and your package mirror, and these inbound ports:
**80/tcp** (certificate validation), **443/tcp**, **8443/tcp** (or your chosen
API port), **3478/udp**, **5349/tcp**, **49152–65535/udp**.

> **Security note.** This command downloads and runs the installer from this
> repository. That is the same trust model as running any install script: you are
> trusting the repository's `main` branch. The bootstrap itself makes no other
> network requests beyond the archive and the packages the installer installs,
> never disables TLS verification, and prints what each step does. If you prefer
> to read before running, clone the repository and run
> `sudo bash deploy/install.sh`, which uses the files you can see.

---

## Architecture

```mermaid
flowchart TB
    subgraph client["Your machine"]
        D["Dohcord (Electron)"]
    end

    subgraph vps["Your VPS"]
        API["Network Configuration API<br/>:<configured port>/network-config"]
        SQ["Squid HTTPS CONNECT proxy<br/>:443"]
        POLICY["Destination policy<br/>allowed-domains.txt<br/>destination-policy.conf"]
        ACL["Generated Squid ACLs<br/>squid-allow.conf"]
        TURN["coturn<br/>:3478/udp · :5349/tcp"]
    end

    subgraph discord["Discord"]
        WEB["HTTPS / WSS<br/>discord.com · gateway.discord.gg<br/>cdn.discordapp.com · …"]
        RTC["WebRTC media"]
    end

    D -- "1. HTTPS: proxy URL,<br/>routing policy, TURN credentials" --> API
    D -- "2. CONNECT host:port<br/>(TLS end to end)" --> SQ
    SQ -- "3. allow only if the host<br/>and port are in the ACLs" --> ACL
    ACL --- POLICY
    SQ -- "4. forward encrypted bytes" --> WEB
    D -- "5. TURN allocation" --> TURN
    TURN -- "6. relayed media" --> RTC
```

The policy files are the only source of truth. Both the Squid authorization and
the `routing.domains` array in `/network-config` are generated from the same
parsed policy, so the client can never be told about a destination the proxy
would refuse — or the reverse.

```
allowed-domains.txt ─┐
                     ├─► validate ─► squid-allow.conf  (Squid enforcement)
destination-policy.conf ┘        └─► /network-config    (client routing)
```

---

## Requirements

| | |
|---|---|
| **Distribution** | Debian 12+ ; Ubuntu 22.04+ (tested on Ubuntu 24.04 and Debian 12) |
| **Architecture** | `amd64`, `arm64` — anything Debian/Ubuntu and coturn build for |
| **Init** | systemd |
| **Privileges** | root (or a user with `sudo`) |
| **Network** | outbound HTTPS; inbound TCP 80, 443, 8443 (or the chosen API port), 5349 and UDP 3478, 49152–65535 |
| **Client** | Dohcord's Custom Profile feature; no relay-specific client build |

An IP-only install works without a domain, using a short-lived Let's Encrypt IP
certificate that the renewal timer keeps current. A domain install additionally
requires an A record pointing at the server before the installer runs.

---

## Configuration

Everything lives under `/etc/dohcord-relay`:

| File | Purpose |
|---|---|
| `config.env` | The API's own settings: proxy URL, TURN URLs, credential lifetime, listen address. |
| `allowed-domains.txt` | Which host names the proxy may reach. |
| `destination-policy.conf` | Which TCP ports each of those hosts may use. |
| `squid-allow.conf` | **Generated** Squid ACLs — do not edit. |
| `squid.conf` | Squid configuration, rendered by the installer. |
| `turnserver.conf` | coturn configuration, rendered by the installer. |
| `turn-secret` | Shared secret for TURN REST credentials (`0640`). |
| `tls/` | `fullchain.pem`, `privkey.pem`, and `squid.pem` for the proxy listener. |
| `policy.json` | Snapshot of the policy Squid is currently enforcing. |
| `install-info` | Version, mode and public endpoints, read by the management console. |

Full details, including every `config.env` key: [docs/configuration.md](docs/configuration.md).

---

## Network Configuration API

`GET https://<your relay>:8443/network-config` is the only endpoint Dohcord needs
(replace `8443` with your configured API port if it is different; existing 8443
profiles are unaffected by the default).

```json
{
  "schemaVersion": 1,
  "version": 1,
  "proxy": { "scheme": "https", "host": "relay.example.com", "port": 443 },
  "routing": {
    "domains": [
      { "host": "discord.com", "match": "suffix",
        "ports": [{ "from": 443, "to": 443 }] },
      { "host": "discord-attachments-uploads-prd.storage.googleapis.com",
        "match": "exact", "ports": [{ "from": 443, "to": 443 }] }
    ]
  },
  "httpsProxy": { "url": "https://relay.example.com:443", "allowedDestinations": [] },
  "rtcRelay": { "expiresAt": 1794600000, "iceServers": [] }
}
```

- `routing.domains` — hosts to send through the proxy, with `exact` or `suffix`
  matching and the permitted port ranges.
- `proxy` — where the proxy is (443). The **configuration** endpoint is the
  configured API port (8443 by default) and is not a proxy target.
- `httpsProxy` and `rtcRelay` — the original fields, unchanged for older clients.

The document is `no-store`, rate limited, and answers `503` rather than serving an
incomplete policy. Full schema and error behaviour:
[docs/api/network-config.md](docs/api/network-config.md).

---

## Domain policy

The allowlist is two plain text files, and the same workflow serves every change:

```bash
sudoedit /etc/dohcord-relay/allowed-domains.txt        # add: cdn.example.com
sudoedit /etc/dohcord-relay/destination-policy.conf    # add: cdn.example.com  443
sudo dohcord-relayd -config /etc/dohcord-relay/config.env -policy-check
sudo dohcord-relayd -config /etc/dohcord-relay/config.env -policy-apply
```

Or without touching files:

```bash
sudo dohcord-relay        # Domain policy → Add a destination
```

`-policy-check` validates both files and the whole Squid configuration;
`-policy-apply` additionally writes the ACLs, records the applied snapshot and
reloads Squid. **If anything is invalid, nothing is applied** and the previous
policy stays in force — for the proxy and for the API alike.

A leading `=` makes an entry exact-host (no subdomains):

```text
=discord-attachments-uploads-prd.storage.googleapis.com
```

Format, matching rules and safety notes: [docs/api/domain-policy.md](docs/api/domain-policy.md).

---

## Management

```bash
sudo dohcord-relay
```

```text
  ╭──────────────────────────────────────────────────────╮
  │                                                      │
  │                    Dohcord-relay                     │
  │                      Management                      │
  │                                                      │
  ├──────────────────────────────────────────────────────┤
  │                                                      │
  │  1. Dashboard          6. TLS certificates           │
  │  2. Services           7. Diagnostics                │
  │  3. Network            8. Update                     │
  │  4. Domain policy      9. Repair                     │
  │  5. Firewall           10. Uninstall                 │
  │                                                      │
  │  0. Exit                                             │
  ╰──────────────────────────────────────────────────────╯
```

Every menu entry is also a subcommand, for scripts and headless use:

| Command | What it does |
|---|---|
| `dohcord-relay dashboard` | Services, certificate, endpoints, listeners, load, policy state |
| `dohcord-relay network` | Addresses, files, policy validity, and the document clients receive |
| `dohcord-relay services status` | The three relay units and the renewal timer |
| `dohcord-relay services restart dohcord-relay-squid.service` | Restart one unit |
| `dohcord-relay policy show` | Every destination with its match type and ports |
| `dohcord-relay cert status` | Issuer, validity, days remaining, renewal timer |
| `dohcord-relay diagnostics` | Health checks, optionally the full verification suite |
| `dohcord-relay update` | Download and verify a release, back up the executables, replace, restart and verify |
| `dohcord-relay repair` | Fix permissions, directories, stopped units |
| `dohcord-relay uninstall` | Remove the relay (see below) |

Prefer plain systemctl? Nothing depends on the console:

```bash
systemctl status  dohcord-relay-api dohcord-relay-squid dohcord-relay-coturn
systemctl restart dohcord-relay-squid
journalctl -u dohcord-relay-api -f
```

> The relay's proxy is its **own** unit, `dohcord-relay-squid.service`. The
> distribution's `squid.service` is a different service and is neither used nor
> touched.

---

## Updating

```bash
sudo dohcord-relay        # Update
```

On an upgrade from a release that installed the server as
`/usr/local/bin/dohcord-relay`, the installer copies that binary to
`/usr/local/bin/dohcord-relayd` before installing the console under the old
name. The systemd unit keeps its name and is rewritten to the new executable.

`Update` shows the installed and latest release versions, asks which version to
install (the latest by default), downloads the archive for this architecture,
verifies it against `checksums.txt`, backs up the current executables to
`/var/backups/dohcord-relay`, replaces them, restarts
`dohcord-relay-api.service` and confirms the endpoint answers. If the new binary
does not come up, it restores the previous executables automatically.

Configuration, domain policy, certificates and private keys are never touched by
a binary update. Re-running the one-line installer (`--version` optional) also
preserves them, and is always safe to repeat.

---

## Troubleshooting

Start with the built-in checks:

```bash
sudo dohcord-relay diagnostics
curl -sS https://relay.example.com:8443/network-config | python3 -m json.tool
```

| Symptom | First thing to check |
|---|---|
| Installer stops at ports | Something already listens on 80/443/8443/3478/5349 (or your chosen API port) — `sudo dohcord-relay dashboard` |
| Certificate issuance fails | Port 80 reachable, A record points here, no AAAA record without IPv6 |
| Let's Encrypt rate limit | The existing certificate is kept; wait for the stated reset. Do not retry in a loop |
| Dohcord cannot connect | `curl` the config URL; check `dohcord-relay-api` and the firewall |
| Proxy returns 403 | The host is not in the policy, or the port is not allowed for it |
| Voice fails, text works | TURN ports/security group, or coturn is down (`services status`) |
| Squid will not start | `dohcord-relay policy check`, then `services validate` |

Detailed causes and commands: [docs/operations/troubleshooting.md](docs/operations/troubleshooting.md).

---

## Uninstalling

```bash
sudo bash uninstall.sh            # or: dohcord-relay → Uninstall
```

It stops and removes the services, units, binaries and runtime directories, then
asks before deleting anything that is expensive to recreate.

```text
  Kept by default:  /etc/dohcord-relay (configuration, policy, certificates)
  --purge:          also removes that directory and the service user
  --purge-cert:     also deletes the Let's Encrypt certificate lineage
```

The squid and coturn packages and any firewall rules you opened are left in
place and reported at the end. Nothing is deleted without a typed confirmation.

---

## Security

- **No interception.** TLS runs end-to-end between Dohcord and Discord. There is
  no `ssl_bump`, no generated certificates, no plaintext.
- **Server-side authorization.** The destination policy is enforced by Squid from
  files on the server. A modified client cannot reach a host the relay has not
  authorized.
- **Resolved addresses are checked.** Allowlisted names that resolve to
  loopback, private, link-local, CGNAT, documentation or multicast addresses are
  refused after resolution, which closes DNS-rebinding paths.
- **Not an open proxy.** CONNECT only, no IP literals, per-client connection and
  rate limits, global descriptor limits, and a final `deny all`.
- **Credentials stay short-lived.** TURN credentials are HMACs over a server-side
  secret with an expiry; the secret never leaves the server and is never logged.

What it is not: not a VPN, not anonymity, not a way around network policy where
the relay's own address is blocked. The threat model and its limits are in
[docs/operations/security.md](docs/operations/security.md).

---

## Repository layout

```text
cmd/dohcord-relay/      management console entry point (runs the console script)
cmd/dohcord-relayd/     server entry point (flags and startup only)
internal/app/           startup wiring and the -policy-check/-policy-apply commands
internal/api/           /network-config, /turn-credentials, ACME responder, limits
internal/config/        config.env parsing, validation, effective-config output
internal/credentials/   coturn TURN REST credentials
internal/policy/        policy files, ports, routing contract, Squid ACL, applied state
internal/ratelimit/     bounded token bucket for the public endpoints
deploy/install.sh       the installer the one-line bootstrap runs
deploy/scripts/         management console, verification suite, TLS deploy hook
deploy/systemd/         units and timer installed to /etc/systemd/system
deploy/templates/       config.env, Squid, coturn and policy templates
docs/                   installation, configuration, API, operations documentation
.github/workflows/     CI and tag-triggered release builds
internal/buildinfo/     version, commit and build date injected with -ldflags
scripts/check.sh        formatting, vet, tests and shell syntax in one command
scripts/test-release.sh release packaging, installer and updater tests
```

The tests for a package live beside it (`internal/policy/policy_test.go`); the
routing contract tests in `internal/api/routing_test.go` compare the published
document with the generated Squid ACLs. [docs/architecture.md](docs/architecture.md)
describes the layout and the install destinations in more detail.

---

## Development

Developers compile from source; the one-line installer does not. GitHub Actions
builds and publishes the official binaries on `vX.Y.Z` tags, so normal users
never need Go.

```bash
./scripts/check.sh                            # gofmt, go vet, build, tests, shell and integration tests
make build                                    # dohcord-relayd and dohcord-relay
go test ./...                                 # policy, routing, API, credentials
bash -n install.sh uninstall.sh deploy/install.sh deploy/scripts/*.sh
sudo bash deploy/scripts/verify.sh            # end-to-end checks on a live relay
```

A local `make build` reports itself as `dev`; only the release workflow stamps a
version tag. See [docs/development.md](docs/development.md) for the full source
workflow, release process and local release testing.

`deploy/scripts/verify.sh` verifies the services, listeners, certificate chain, the
generated ACLs against the policy files, real CONNECT allow/deny behaviour, the
API document, TURN credentials and media, and renewal. It is read-only apart from
a certbot dry run (skip it with `DOHCORD_RELAY_SKIP_RENEW=1`).

---

## Documentation

| Document | Contents |
|---|---|
| [Installation](docs/installation.md) | Requirements, one-line install, all installer options, non-interactive use, what the installer does |
| [Configuration](docs/configuration.md) | `config.env`, Squid, coturn, file locations and permissions, tuning |
| [Network Configuration API](docs/api/network-config.md) | Schema, fields, matching, errors, caching, custom profiles |
| [Domain policy](docs/api/domain-policy.md) | File format, exact vs suffix, ports, validation and apply workflow |
| [Troubleshooting](docs/operations/troubleshooting.md) | Symptom → cause → command |
| [Security](docs/operations/security.md) | Threat model, protections, non-goals |
| [Architecture](docs/architecture.md) | Repository layout, package responsibilities, install destinations |
| [Development](docs/development.md) | Source builds, tests, CI and the release process |

No other language variants are maintained.

## License

No license file is currently included in this repository, so all rights are
reserved by the author. If you intend to reuse the code, ask first.
