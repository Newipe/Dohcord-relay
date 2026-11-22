# Configuration

Everything the relay needs is under `/etc/dohcord-relay`. Files marked *generated*
are written by the installer or by the relay itself; edit the sources, not the
output.

| Path | Mode | Purpose |
|---|---|---|
| `/etc/dohcord-relay/config.env` | `0640 root:dohcord-relay` | Settings for the API and policy tools |
| `/etc/dohcord-relay/allowed-domains.txt` | `0644` | Allowed host names (source of truth) |
| `/etc/dohcord-relay/destination-policy.conf` | `0644` | Allowed ports per host (source of truth) |
| `/etc/dohcord-relay/squid-allow.conf` | `0644` | *Generated* Squid ACLs |
| `/etc/dohcord-relay/squid.conf` | `0644` | *Rendered* Squid configuration |
| `/etc/dohcord-relay/turnserver.conf` | `0640 root:dohcord-relay` | *Rendered* coturn configuration |
| `/etc/dohcord-relay/turn-secret` | `0640 root:dohcord-relay` | Shared secret for TURN credentials |
| `/etc/dohcord-relay/tls/fullchain.pem` | `0644` | Certificate chain |
| `/etc/dohcord-relay/tls/privkey.pem` | `0640 root:dohcord-relay` | Private key |
| `/etc/dohcord-relay/tls/squid.pem` | `0640` | Key + chain concatenated for Squid's `tls-cert=` |
| `/etc/dohcord-relay/policy.json` | `0644` | Snapshot of the applied policy |
| `/etc/dohcord-relay/install-info` | `0644` | Version, mode, public endpoints |
| `/var/log/dohcord-relay/squid/` | `0750 proxy:proxy` | Squid logs |
| `/var/log/dohcord-relay/turnserver/` | `0750 turnserver:turnserver` | coturn log |
| `/usr/local/lib/dohcord-relay/` | `0755` | `verify.sh`, `uninstall.sh`, `bootstrap.sh` |

## config.env

Read by `/usr/local/bin/dohcord-relayd`. Values are `KEY=value` lines; the file is
parsed, not sourced.

| Key | Meaning |
|---|---|
| `HTTPS_PROXY_URL` | Proxy address clients use. Published as `proxy` and `httpsProxy.url`. Must be `https://`. |
| `NETWORK_CONFIG_PORT` | The Network Configuration API port (default `8443`, chosen at install time). Authoritative: `HTTPS_LISTEN` and `NETWORK_CONFIG_URL` must name the same port. |
| `NETWORK_CONFIG_URL` | This endpoint's public URL, for logs and reports. |
| `TURN_URLS` | Comma-separated TURN URLs handed to clients. UDP first, TLS second by convention. |
| `TURN_IDENTITY` | Username suffix in issued credentials (`<expiry>:Dohcord`). |
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
| `TC_REFRESH_SECONDS` | How often active client addresses are re-read (default `5`). |
| `TRUST_PROXY_HEADER` | Set `true` **only** behind a reverse proxy that overwrites `X-Forwarded-For`. |

The API reloads this file on `SIGHUP` (the unit's `ExecReload`) and picks up
rotated secrets and tuning without a restart. `systemctl reload dohcord-relay-api`.

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
scope=per-ip` and is counted by `dohcord-relay diagnostics`.

Values are validated at startup (whole numbers, 1 to 1,000,000); an invalid
value stops the service instead of silently disabling the limiter. Changes take
effect with `systemctl reload dohcord-relay-api` and are made for you by the
installer or **Limits & performance** in the console.

### Network Configuration API port

`NETWORK_CONFIG_PORT` is the one place the API port is defined; the listener and
the public URL are kept on the same port. Fresh installations default to `8443`
and may choose another free port; upgrades keep whatever is already configured
(falling back to `8443` when the key is absent). Change it later through the
management console (**Network → Change the Network Configuration API port** or
`sudo dohcord-relay network port`), which updates this file, the firewall and the
service, then verifies the endpoint before reporting success.

> **Dohcord profile dependency.** The client connects to the full URL stored in
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
include /etc/dohcord-relay/squid-allow.conf
```

`-policy-apply` rewrites the include and validates **the whole configuration**
with `squid -k parse` before anything is installed or reloaded. Do not edit
`squid.conf` by hand: re-running the installer re-renders it. If you must change
timeouts or limits permanently, change the template and re-install, or use the
installer's flags where they exist (`--max-connections`), or change it with
`sudo dohcord-relay limits` (**Limits & performance**), which validates the whole
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

`/usr/local/lib/dohcord-relay/dohcord-relay-tc` (run by
`dohcord-relay-tc.service`) builds two HTB trees:

- **download** (server to client) on the WAN interface: one class per client IP
  per service, and a `u32` filter that matches the client address together with
  the service's source port (`443`, `3478`, `5349`, and the coturn relay range
  `49152-65535`). Anything that matches no class uses the default class, which is
  unlimited, so unrelated traffic on the server is untouched.
- **upload** (client to server) on an IFB device: only packets addressed to
  those relay ports are mirrored there (unrelated traffic never leaves the normal
  path), and the same per-address classification happens on the IFB.

Limit values are Mbit/s everywhere: installer, console, `config.env`, this page.
HTB is given a 50 ms burst so UDP voice does not suffer from packet loss on
micro-bursts.

### Limitations, stated plainly

Linux `tc` has no per-IP hash table for HTB, so the class table is refreshed from
the connections that actually exist, every `TC_REFRESH_SECONDS`:

- a client that starts its first connection is shaped within one refresh
  interval (5 s by default); until then its traffic uses the unlimited class;
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
  `dohcord-relay-tc stop`;
- upload shaping needs the `ifb` kernel module. The service runs with
  `ProtectKernelModules=yes`, so the installer loads the module and records it in
  `/etc/modules-load.d/dohcord-relay-ifb.conf` for the next boot;
- IPv6 clients are shaped with their own filters; if a kernel rejects them the
  `status` command reports the missing classes rather than claiming success.

### Changing and checking limits

- During installation: the **Network and performance settings** section asks for
  each value, with units and defaults; Enter keeps the value in brackets.
- Afterwards: `sudo dohcord-relay limits` (**Limits & performance**). Changes are
  staged, validated, backed up to `/var/backups/dohcord-relay/limits-<time>/`,
  applied, verified, and rolled back if the services do not come back healthy.
- Diagnosis: `sudo dohcord-relay-tc status` prints the configured limits, the
  interface, the qdiscs and whether the classes carry the configured rates;
  `dohcord-relay diagnostics` and `verify.sh` report a configured-but-inactive
  limit as a failure, never as success.

## coturn configuration

`turnserver.conf` is rendered from `deploy/templates/turnserver.conf.tmpl`:

| Setting | Value |
|---|---|
| `listening-port` / `tls-listening-port` | `3478` / `5349` |
| `min-port` / `max-port` | `49152` / `65535` |
| `realm` | Your domain, or `dohcord.relay` for address installs |
| `fingerprint`, `stale-nonce=600`, `no-tcp-relay`, `no-multicast-peers` | Enabled |
| `user-quota` / `total-quota` | `12` / `1200` (installer flags) |
| `max-bps` / `bps-capacity` | `2000000` / `250000000` |
| `cert` / `pkey` | The relay's certificate and key |

Credentials use coturn's REST mechanism:

```text
username = "<unix expiry>:Dohcord"
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

After any change: `sudo dohcord-relay diagnostics`.

## Backups

Everything worth keeping is text plus two key files:

```bash
sudo tar -C /etc -czf dohcord-relay-$(date +%F).tar.gz dohcord-relay
```

`dohcord-relay update` and policy edits already create backups under
`/var/backups/dohcord-relay/` (`config-*` directories and timestamped copies of
the two policy files).
