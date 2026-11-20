# Security model

Dohcord-relay is a **selective forwarder**, not a tunnel into a network. This
document describes what it protects, how, and what it explicitly does not do.

## Threat model

| Assumed adversary | Consequence |
|---|---|
| Anyone on the internet who finds the relay address | Can use the proxy for allowlisted destinations only; cannot reach anything else, cannot open a tunnel to private addresses, cannot use it as a general open proxy |
| A modified or hostile client | Cannot widen the policy: destinations, ports and address checks are enforced on the server |
| A DNS answer controlled by an attacker (rebinding) | Allowlisted names that resolve to private/loopback/link-local/CGNAT addresses are refused *after* resolution |
| Someone who obtains an issued TURN credential | Can allocate TURN sessions until it expires (default 24 h), within per-credential and total quotas |
| A local unprivileged user on the server | Cannot read the TURN secret, the private key, or the policy snapshot; services run as `dohcord-relay`, `proxy`, `turnserver` |

Not defended against: an adversary who controls the server itself, an adversary
who controls your client machine, or a network that blocks the relay's address
outright.

## Transport

- **End-to-end TLS.** Discord's TLS session is between Dohcord and Discord. Squid
  does not `ssl_bump`, holds no signing certificate, and cannot read the traffic.
- **Proxy listener is TLS.** `https_port` only, with a real certificate chain; no
  plain `http_port` for proxy traffic. The chain must include the intermediate,
  which is why the installer requires the OpenSSL build of Squid.
- **No verification bypass.** Nothing in the install or the client-facing document
  asks a client to skip certificate validation. The verification script validates
  the certificate rather than disabling checks.

## Authorization

Two server-side files decide destinations and ports. Nothing else does.

- Enforcement is Squid's ACLs, generated from those files.
- The API's `routing.domains` is generated from the same parse, so the published
  policy and the enforced policy cannot diverge.
- `CONNECT` only: `GET`/`POST` through the proxy returns `403`.
- No IP literals: `CONNECT 1.1.1.1:443` is denied regardless of policy.
- The last rule is always `http_access deny all`.
- A domain entry allows subdomains on label boundaries only; `evil.example.com`
  style suffixes are not confused with `example.com`.
- The `=` marker restricts an entry to a single host where subdomains belong to
  third parties (for example Cloud Storage buckets).

## SSRF and DNS rebinding

After name resolution, Squid checks the resulting address against every
special-purpose range that must never be a proxy target: loopback, private,
link-local, CGNAT, documentation, benchmarking, multicast, and the relay's own
address. A policy entry therefore cannot be pointed at the server's internal
network by controlling DNS.

## Resource limits

| Limit | Purpose |
|---|---|
| `client_ip_max_connections` (default 40) | One client cannot exhaust the proxy |
| `client_lifetime` (4 h) | Stale tunnels are reaped |
| `read_timeout`, header limits | Slowloris-style abuse |
| `LimitNOFILE`, descriptor ceiling | Global bound |
| API per-IP and global rate limits | Credential issuance abuse |
| coturn `user-quota`, `total-quota`, `max-bps`, `bps-capacity` | Allocation and bandwidth abuse |

## Credentials and secrets

- TURN credentials are HMAC-SHA1 over the username with a shared secret, carrying
  an expiry. Only the HMAC is published.
- The shared secret lives in `/etc/dohcord-relay/turn-secret` (`0640
  root:dohcord-relay`), is read by the API and coturn, and is never logged, never
  served and never printed by the installer.
- The API never logs credentials; it logs the client address, destination count
  and expiry.
- Private keys are `0640 root:dohcord-relay`; the Squid bundle is a concatenation
  readable only by the groups that need it.

## Service hardening

All three units run unprivileged (`dohcord-relay`, `proxy`, `turnserver`), with
`NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`,
`PrivateDevices`, and a small capability set where a privileged port is needed
(`CAP_NET_BIND_SERVICE` for the API's port 80 ACME responder).

## Firewall

The installer opens exactly the ports the relay needs in an active `ufw` or
`firewalld`, never resets rules, and warns if SSH does not appear to be allowed.
A cloud security group is outside its reach and must be configured separately.

## Explicit non-goals

- **Not a VPN.** It forwards proxy and TURN traffic for one application, not a
  whole device.
- **Not anonymity.** Discord sees the relay's address. The relay operator sees
  destination host names, ports, timings and the client address.
- **Not censorship circumvention.** If the relay's own address is blocked, it
  cannot help.
- **No content inspection, filtering or logging of payloads.** The proxy cannot
  read them; do not expect DPI features.

## Reporting a problem

Include the output of `dohcord-relay diagnostics` and `verify.sh`.
Never include `turn-secret`, `privkey.pem`, or issued TURN credentials.
