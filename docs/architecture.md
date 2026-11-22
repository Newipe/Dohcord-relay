# Repository architecture

The repository separates the Go service, the deployment resources it needs on a
server, and the operator documentation. Nothing outside `deploy/` runs at
runtime; everything in `deploy/` is either executed by the installer or copied to
the server.

```text
cmd/dohcord-relay/          the management console's entry point (runs manager.sh)
cmd/dohcord-relayd/         the background server's entry point (flags, startup)
internal/app/               startup wiring and the one-shot maintenance commands
internal/buildinfo/         version, commit and build date injected with -ldflags
internal/api/               HTTP endpoints, request limits, secret and certificate reloading
internal/config/            config.env parsing, validation and effective-config output
internal/credentials/       coturn TURN REST credential issue and parsing
internal/policy/            policy files, ports, routing contract, Squid ACL, applied state
internal/ratelimit/         bounded token bucket for the public endpoints
deploy/install.sh           the real installer (the root install.sh bootstraps to it)
deploy/scripts/             management console, verification suite, TLS deploy hook
deploy/systemd/             unit and timer files installed to /etc/systemd/system
deploy/templates/           config.env, Squid, coturn and policy files installed to /etc
.github/workflows/          CI (main) and tag-triggered release builds
docs/                       operator, API and development documentation
scripts/check.sh            the local check suite (fmt, vet, tests, shell syntax)
scripts/test-release.sh     release packaging, installer and updater tests
```

## The service

The two commands have separate jobs. `cmd/dohcord-relayd` is the background
server: it calls `app.Main`, which parses the flags, loads `config.env`,
dispatches the maintenance modes (`-policy-check`, `-policy-apply`,
`-print-config`, `-acme-only`) and otherwise starts the API.

`cmd/dohcord-relay` is the management console users run. It locates and runs the
console application installed as `/usr/local/lib/dohcord-relay/manager.sh`
(`deploy/scripts/dohcord-relay-manager.sh` in a checkout) and forwards its
arguments and exit status. `/usr/local/bin/dohcord-relay-manager` is a symlink to
it, kept for compatibility with the previous command name.

`internal/api` owns the two public endpoints and the ACME responder. It holds no
policy logic of its own: both the published document and the Squid ACLs come from
`internal/policy`, so they cannot disagree. The TURN secret and the TLS key pair
are read from disk and reloaded when they change; neither is ever logged or
returned to a client.

`internal/policy` is the only place that knows the policy file formats. It
validates and cross-checks `allowed-domains.txt` against
`destination-policy.conf`, renders the Squid include, publishes the routing
rules, and writes the state file that records what Squid is enforcing.

## Deployment resources

| Path | Installed as |
|---|---|
| `deploy/systemd/*.service`, `*.timer` | `/etc/systemd/system/` |
| `deploy/templates/config.env.tmpl` | `/etc/dohcord-relay/config.env` (rendered) |
| `deploy/templates/squid.conf.tmpl` | `/etc/dohcord-relay/squid.conf` (rendered) |
| `deploy/templates/turnserver.conf.tmpl` | `/etc/dohcord-relay/turnserver.conf` (rendered) |
| `deploy/templates/allowed-domains.txt` | `/etc/dohcord-relay/allowed-domains.txt` (first install only) |
| `deploy/templates/destination-policy.conf` | `/etc/dohcord-relay/destination-policy.conf` (first install only) |
| `deploy/scripts/dohcord-relay-manager.sh` | `/usr/local/lib/dohcord-relay/manager.sh` (run by `dohcord-relay`) |
| `cmd/dohcord-relayd` (built) | `/usr/local/bin/dohcord-relayd` |
| `cmd/dohcord-relay` (built) | `/usr/local/bin/dohcord-relay`, with `/usr/local/bin/dohcord-relay-manager` as a symlink |
| `deploy/scripts/verify.sh` | `/usr/local/lib/dohcord-relay/verify.sh` |
| `deploy/scripts/dohcord-relay-tls-deploy` | `/usr/local/bin/dohcord-relay-tls-deploy` |
| `uninstall.sh` | `/usr/local/lib/dohcord-relay/uninstall.sh` |
| `install.sh` | `/usr/local/lib/dohcord-relay/bootstrap.sh` |

The root `install.sh` URL is part of the documented one-line install and is kept
stable: it downloads the repository archive, checks the tree, and runs
`deploy/install.sh`. Existing configuration, policy files and certificates are
never overwritten by a re-install or an update.

## Tests

Unit tests sit next to the package they test:

- `internal/policy/policy_test.go` — file formats, exact vs suffix matching, ACL and state
- `internal/api/api_test.go` — endpoints, headers, rate limits, ACME responder
- `internal/api/routing_test.go` — published routing contract against the ACLs
- `internal/config/config_test.go` — configuration parsing and validation
- `internal/credentials/credentials_test.go` — credential vector and username format
- `internal/ratelimit/ratelimit_test.go` — token refill behaviour

Run all of them with `go test ./...` or `./scripts/check.sh`.

## Bandwidth enforcement

```
client IP --(443/tcp)--> Squid --                                  >-- HTB root qdisc on the WAN interface (download)
client IP --(3478/udp,            /        one class per client IP and service
             5349/tcp,           /
             49152-65535/udp)-> coturn

client IP --(relay ports)--> ingress mirror --> IFB --> HTB (upload)
                                                       one class per client IP and service
```

`dohcord-relay-tc` (a small systemd service, no packet-path component) refreshes
the class table from live connections and is the only thing that touches
traffic-control state. The refresh is built to stay cheap under load: one socket
scan per service (shared by both directions), parsing in `awk` rather than a
shell loop over every socket, and an address that appears only adds its own rules
instead of rebuilding the whole filter chain. Proxy and TURN are classified by port, so their allowances
are independent, and the API's control traffic is never shaped. See
[configuration.md](configuration.md#per-client-ip-bandwidth-limits).
