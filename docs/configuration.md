# Configuration

Everything the relay needs is under `/etc/pishcord-relay`. Files marked *generated*
are written by the installer or by the relay itself; edit the sources, not the
output.

| Path | Mode | Purpose |
|---|---|---|
| `/etc/pishcord-relay/config.env` | `0640 root:pishcord-relay` | Settings for the API and policy tools |
| `/etc/pishcord-relay/allowed-domains.txt` | `0644` | Allowed host names (source of truth) |
| `/etc/pishcord-relay/destination-policy.conf` | `0644` | Allowed ports per host (source of truth) |
| `/etc/pishcord-relay/squid-allow.conf` | `0644` | *Generated* Squid ACLs |
| `/etc/pishcord-relay/squid.conf` | `0644` | *Rendered* Squid configuration |
| `/etc/pishcord-relay/turnserver.conf` | `0640 root:pishcord-relay` | *Rendered* coturn configuration |
| `/etc/pishcord-relay/turn-secret` | `0640 root:pishcord-relay` | Shared secret for TURN credentials |
| `/etc/pishcord-relay/tls/fullchain.pem` | `0644` | Certificate chain |
| `/etc/pishcord-relay/tls/privkey.pem` | `0640 root:pishcord-relay` | Private key |
| `/etc/pishcord-relay/tls/squid.pem` | `0640` | Key + chain concatenated for Squid's `tls-cert=` |
| `/etc/pishcord-relay/policy.json` | `0644` | Snapshot of the applied policy |
| `/etc/pishcord-relay/install-info` | `0644` | Version, mode, public endpoints |
| `/var/log/pishcord-relay/squid/` | `0750 proxy:proxy` | Squid logs |
| `/var/log/pishcord-relay/turnserver/` | `0750 turnserver:turnserver` | coturn log |
| `/usr/local/lib/pishcord-relay/` | `0755` | `verify.sh`, `uninstall.sh`, `bootstrap.sh` |

## config.env

Read by `/usr/local/bin/pishcord-relayd`. Values are `KEY=value` lines; the file is
parsed, not sourced.

| Key | Meaning |
|---|---|
| `HTTPS_PROXY_URL` | Proxy address clients use. Published as `proxy` and `httpsProxy.url`. Must be `https://`. |
| `NETWORK_CONFIG_PORT` | The Network Configuration API port (default `8443`, chosen at install time). Authoritative: `HTTPS_LISTEN` and `NETWORK_CONFIG_URL` must name the same port. |
| `NETWORK_CONFIG_URL` | This endpoint's public URL, for logs and reports. |
| `TURN_URLS` | Comma-separated TURN URLs handed to clients. UDP first, TLS second by convention. |
| `TURN_IDENTITY` | Username suffix in issued credentials (`<expiry>:Pishcord`). |
| `CREDENTIAL_TTL` | Lifetime of a TURN credential (default `24h`). |
| `SECRET_FILE` | File holding the coturn shared secret. Never served, never logged. |
| `TLS_CERT_FILE`, `TLS_KEY_FILE` | Certificate and key for the HTTPS endpoint. |
| `HTTPS_LISTEN` | API listen address, `:8443` unless another port was chosen. Port 443 belongs to the proxy. |
| `HTTP_LISTEN` | Plain HTTP listener, used only to answer ACME challenges on `:80`. |
| `ACME_WEBROOT` | Webroot for HTTP-01 challenges. |
| `ALLOWED_DOMAINS_FILE`, `DESTINATION_POLICY_FILE` | The authoritative policy. |
| `POLICY_STATE_FILE` | Applied-policy snapshot written after a successful apply. |
| `SQUID_CONF`, `SQUID_ALLOW_FILE`, `SQUID_BINARY` | Where Squid lives, for validation and reload. |
| `PER_IP_RATE_PER_MINUTE`, `PER_IP_BURST` | Per-client request limits on the API (default `60`/minute, burst `30`). |
| `GLOBAL_RATE_PER_MINUTE`, `GLOBAL_BURST` | Global request limits on the API (default `1200`/minute, burst `300`). |
| `PROXY_UPLOAD_LIMIT_MBIT`, `PROXY_DOWNLOAD_LIMIT_MBIT` | Per-client proxy bandwidth in Mbit/s, `0` disables (default `8`/`8`). |
| `TURN_UPLOAD_LIMIT_MBIT`, `TURN_DOWNLOAD_LIMIT_MBIT` | Per-client TURN bandwidth in Mbit/s, `0` disables (default `16`/`16`). |
| `TC_INTERFACE` | Interface to shape. Empty detects it from the default route. |
| `TC_MAX_CLIENTS` | Client addresses tracked per service and direction (default `512`, range 1-2047). |
| `TC_REFRESH_SECONDS` | How often the proxy's client addresses are re-read (default `5`). The TURN socket table is much larger on a busy relay, so it is re-read at most every 30 s. |
| `TRUST_PROXY_HEADER` | Set `true` **only** behind a reverse proxy that overwrites `X-Forwarded-For`. |

The API reloads this file on `SIGHUP` (the unit's `ExecReload`) and picks up
rotated secrets and tuning without a restart: `systemctl reload pishcord-relay-api`.

The TURN secret is read from `SECRET_FILE` on demand and cached, and the file is
re-checked at most once a second, so a secret rotated in place is noticed within a
second even without a reload; `SIGHUP` skips the wait. The policy snapshot in
`POLICY_STATE_FILE` is checked on every request, so a policy apply is visible at
once.

> Changing `HTTPS_PROXY_URL` changes what clients are told. It must stay the
> address clients actually reach the proxy on; the installer sets it from your
> answers.

### API request limits

`/network-config` and `/turn-credentials` share two token buckets: one per client
address and one for the relay as a whole.

| Key | Default | Meaning |
|---|---|---|
| `PER_IP_RATE_PER_MINUTE` | `60` | Steady allowance for one address |
| `PER_IP_BURST` | `30` | How many requests may arrive at once from one address |
| `GLOBAL_RATE_PER_MINUTE` | `1200` | Steady allowance for the whole relay |
| `GLOBAL_BURST` | `300` | Burst for the whole relay |

One profile load is exactly one request, so the burst has to cover the profiles a
user opens at the same time. The old defaults (6/minute, burst 3) answered `429`
for perfectly normal use; the current ones leave the limiter to do what it is
for, bounding abuse. A refused request logs `rate limited client=<addr>
scope=per-ip` and is counted by `pishcord-relay diagnostics`.

Values are validated at startup (whole numbers, 1 to 1,000,000); an invalid
value stops the service instead of silently disabling the limiter. Changes take
effect with `systemctl reload pishcord-relay-api` and are made for you by the
installer or **Limits & performance** in the console.

### Network Configuration API port

`NETWORK_CONFIG_PORT` is the one place the API port is defined; the listener and
the public URL are kept on the same port. Fresh installations default to `8443`
and may choose another free port; upgrades keep whatever is already configured
(falling back to `8443` when the key is absent). Change it later through the
management console (**Network → Change the Network Configuration API port** or
`sudo pishcord-relay network port`), which updates this file, the firewall and the
service, then verifies the endpoint before reporting success.

> **Pishcord profile dependency.** The client connects to the full URL stored in
> its Custom Profile, including the port. Changing the API port does not change
> `/network-config`, its JSON, TLS or authentication, but every profile that
> still names the old port stops working until its Network Configuration URL is
> updated. Profiles using `8443` keep working without changes.

## Squid configuration

`squid.conf` is rendered from `deploy/templates/squid.conf.tmpl`. It is a TLS forward proxy:
`https_port` only (no plain `http_port`), CONNECT only, no `ssl_bump`, private and
special-purpose destinations denied by ACL, per-client connection ceiling, finite
`client_lifetime`, and a final `http_access deny all`.

The destination allowlist is one line:

```squid
include /etc/pishcord-relay/squid-allow.conf
```

`-policy-apply` rewrites the include and validates **the whole configuration**
with `squid -k parse` before anything is installed or reloaded. Do not edit
`squid.conf` by hand: re-running the installer re-renders it. If you must change
timeouts or limits permanently, change the template and re-install, or use the
installer's flags where they exist (`--max-connections`), or change it with
`sudo pishcord-relay limits` (**Limits & performance**), which validates the whole
Squid configuration before reloading it.

## Per-client-IP bandwidth limits

Bandwidth is limited **per client IP**, separately for the proxy and the TURN
relay, in each direction, with Linux `tc`. Nothing is per connection or per
session, no application is placed in the packet path, and Squid/coturn protocols
are unchanged.

| Key | Default | Applies to |
|---|---|---|
| `PROXY_UPLOAD_LIMIT_MBIT` | `8` | All proxy upload from one client IP, all connections together |
| `PROXY_DOWNLOAD_LIMIT_MBIT` | `8` | All proxy download to one client IP |
| `TURN_UPLOAD_LIMIT_MBIT` | `16` | All TURN upload from one client IP, all allocations together |
| `TURN_DOWNLOAD_LIMIT_MBIT` | `16` | All TURN download to one client IP |

`0` disables that single limit. With all four at `0` the shaper removes its own
rules and does nothing.

### How it is enforced

`/usr/local/lib/pishcord-relay/pishcord-relay-tc` (run by
`pishcord-relay-tc.service`) builds two HTB trees:

- **download** (server to client) on the WAN interface: one class per client IP
  per service, and a `u32` filter that matches the client address together with
  the service's source port (`443`, `3478`, `5349`, and the coturn relay range
  `49152-65535`). Each service also has one **fallback class** at exactly its
  per-IP rate: relay traffic from an address that has no class yet lands there,
  so the limit is enforced from the very first packet. The fallback matches the
  service's listener ports only. The coturn relay range is covered per address
  instead, because on the WAN interface a source port in `49152-65535` is also
  what the host's own outbound connections look like, and the server's own
  traffic must never be limited as TURN. Traffic that matches no relay filter at
  all (the API, SSH, anything else) uses the default class, which is unlimited.
- **upload** (client to server) on an IFB device: only packets addressed to the
  service's own listener ports (IPv4 and IPv6) are redirected there, and the same
  per-address classification happens on the IFB. coturn's relay port range is not
  mirrored: packets arriving for those ports come from *peers*, not from the
  client, so they are not a client's upload.

Every class — per-client, fallback and the unlimited default — carries an
**`fq_codel` leaf queue** (`limit` 1000 packets, `target 5ms`, `interval 100ms`,
ECN). Without it a class is a plain `pfifo` whose limit is the device
`txqueuelen`: about 1000 packets on a WAN device, which buffers more than a
second of audio at 8 Mbit/s before it starts dropping a whole burst, and only 32
on an IFB device, which drops inside every 24 ms of a 16 Mbit/s burst. That is
what made calls stutter and cut out. With the leaf queue the standing queue stays
at a few milliseconds, losses are spread over the flow that causes them instead
of arriving as one clump, and the configured average rate is unchanged. A kernel
without `sch_fq_codel` is detected at apply time and gets a bounded `pfifo`
(`TC_AQM=pfifo` forces that path).

HTB classes are also given an explicit `quantum` (`TC_QUANTUM`, 1500 bytes = one
packet) and a 50 ms `burst`/`cburst`. HTB's default quantum is `rate/r2q`, which
at 8-16 Mbit/s is 100-200 kB per round — 60 to 130 voice packets served from one
class before the scheduler looks at another, and the kernel warns that the
quantum is big.

Limit values are Mbit/s everywhere: installer, console, `config.env`, this page.

| Key | Default | Meaning |
|---|---|---|
| `TC_AQM` | `auto` | Leaf queue: `auto` (fq_codel, falling back to pfifo), `fq_codel` or `pfifo` |
| `TC_AQM_LIMIT` | `1000` | Leaf queue length, packets |
| `TC_QUANTUM` | `1500` | HTB quantum, bytes served per class per round |
| `TC_DISCOVERY` | `auto` | Client addresses from `auto`, `conntrack`, `proc` or `ss` |
| `TC_TURN_SCAN_SECONDS` | *(empty)* | How often the TURN client table is re-read; empty = every refresh with conntrack, 30 s with `/proc` |

### How clients are discovered

Linux `tc` has no per-IP hash table for HTB, so the per-address class table is
built from the flows that actually exist. Client addresses come from the
**conntrack table**: one entry per client flow to `3478`/`5349`, over UDP or TCP,
filtered in the kernel by protocol and destination port. The parsing happens in
`awk`, and an address that appears only adds its own class and filters, so a
refresh costs the same whether five or five hundred addresses are shaped.

This matters more than it may sound. Before conntrack discovery, TURN clients
were read from `ss -uan`, which **cannot name a UDP TURN client at all**: coturn
answers it from the shared listener socket bound to `0.0.0.0:3478`, whose peer
address is never recorded, and its per-allocation relay sockets only ever talk to
the peers. The result was that every TURN user stayed in the single per-service
fallback class and shared one per-IP allowance — a call with several participants
saw its voice cut out. `ss` remains the source for the proxy (a connection
accepted by Squid has the client as its peer) and as a fallback for TURN over
TLS; `status` reports which source is in use and warns when only `ss` is
available.

`TC_DISCOVERY=auto` prefers the `conntrack` tool (cheap kernel-filtered dumps),
then `/proc/net/nf_conntrack`, then `ss`. The installer installs `conntrack` and
loads `nf_conntrack`, so a default installation gets the primary source.

### Limitations, stated plainly

- a new client address is limited immediately, by its service's fallback class,
  which carries exactly the configured per-IP rate. Within one refresh
  (`TC_REFRESH_SECONDS`, 5 s by default) it moves to a class of its own. While
  several new addresses are in the fallback class they share that one
  allowance, so a burst of new clients can be slower than configured for a few
  seconds, but never faster. If only `ss` is available, UDP TURN clients never
  leave the fallback class and `status` says so;
- at most `TC_MAX_CLIENTS` addresses are tracked per service and direction
  (`512` by default, 1-2047). Beyond that, extra addresses are logged as not
  limited and reported by diagnostics; raise the value or lower the number of
  active addresses;
- an address with no traffic for `TC_IDLE_SECONDS` (60) is forgotten, so kernel
  state does not grow without bound;
- if the interface already carries an administrator's root qdisc (`cake`, `tbf`,
  a foreign `htb`, …) the shaper refuses to replace it and reports that shaping
  is not active, instead of overwriting an administrator's configuration. Kernel
  and driver defaults (`mq` on multiqueue NICs, `fq_codel`, `pfifo_fast`) are
  replaced, and the previous qdisc kind is recorded and restored by
  `pishcord-relay-tc stop`;
- upload shaping needs the `ifb` kernel module. The service runs with
  `ProtectKernelModules=yes`, so the installer loads the module and records it in
  `/etc/modules-load.d/pishcord-relay-ifb.conf` for the next boot;
- IPv6 clients are shaped with their own filters (upload and download). Every
  `tc` command is checked: a rule the kernel refuses aborts `apply` instead of
  leaving a half-installed tree, and `status` requires each class *and* the
  filter that steers traffic into it (`missing_class`, `missing_filter`,
  `missing_fallback_class`, `missing_fallback_filter`), so a tree that shapes
  nothing is never reported as active;
- an expired address's classifiers are removed on their own. Only a removal the
  kernel does not confirm falls back to rebuilding the chain, because a rebuild
  briefly sends every packet through the unlimited default class.

### Changing and checking limits

- During installation: the **Network and performance settings** section asks for
  each value, with units and defaults; Enter keeps the value in brackets.
- Afterwards: `sudo pishcord-relay limits` (**Limits & performance**). Changes are
  staged, validated, backed up to `/var/backups/pishcord-relay/limits-<time>/`,
  applied, verified, and rolled back if the services do not come back healthy.
- Diagnosis: `sudo pishcord-relay-tc status` prints the configured limits, the
  interface, the discovery source, the qdiscs and whether the classes carry the
  configured rates; `sudo pishcord-relay-tc diagnose` adds the per-class queue
  state (`Sent`, `dropped`, `overlimits`, `backlog`) and coturn's error-486
  count; `pishcord-relay diagnostics` and `verify.sh` report a
  configured-but-inactive limit as a failure, never as success.

## coturn configuration

`turnserver.conf` is rendered from `deploy/templates/turnserver.conf.tmpl`:

| Setting | Value |
|---|---|
| `listening-port` / `tls-listening-port` | `3478` / `5349` |
| `min-port` / `max-port` | `49152` / `65535` |
| `realm` | Your domain, or `pishcord.relay` for address installs |
| `fingerprint`, `stale-nonce=600`, `no-tcp-relay`, `no-multicast-peers` | Enabled |
| `user-quota` / `total-quota` | `12` / `1200` (installer flags) |
| `max-bps` / `bps-capacity` | `8000000` / `0` (no reservation ceiling) |
| `cert` / `pkey` | The relay's certificate and key |

Credentials use coturn's REST mechanism:

```text
username = "<unix expiry>:Pishcord"
password = base64(HMAC-SHA1(shared secret, username))
```

Only the HMAC and its expiry are published; the secret stays on the server. To
rotate it, see [../README.md#security](../README.md#security) and
[operations/troubleshooting.md](operations/troubleshooting.md).

## Tuning guidelines

| Goal | Change |
|---|---|
| More concurrent connections per client | `--max-connections N` (default 100; asked during install) |
| More concurrent TURN allocations | `--total-quota N`, `--user-quota N` |
| More bandwidth | `--max-bps N`, `--bps-capacity N` |
| Longer credential lifetime | `CREDENTIAL_TTL` in `config.env`, then reload the API |
| Stricter API rate limiting | `PER_IP_RATE_PER_MINUTE`, `GLOBAL_RATE_PER_MINUTE`, reload |
| Proxy bandwidth per client IP | `--proxy-upload-limit` / `--proxy-download-limit`, or **Limits & performance** |
| TURN bandwidth per client IP | `--turn-upload-limit` / `--turn-download-limit`, or **Limits & performance** |
| More simultaneous profiles | `--api-per-ip-burst` / `--api-per-ip-rate` |
| Shape more client addresses at once | `--tc-max-clients`, `TC_REFRESH_SECONDS` |

After any change: `sudo pishcord-relay diagnostics`.

## Backups

Everything worth keeping is text plus two key files:

```bash
sudo tar -C /etc -czf pishcord-relay-$(date +%F).tar.gz pishcord-relay
```

`pishcord-relay update` and policy edits already create backups under
`/var/backups/pishcord-relay/` (`config-*` directories and timestamped copies of
the two policy files).
