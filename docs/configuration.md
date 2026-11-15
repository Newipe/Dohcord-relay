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

Read by `/usr/local/bin/dohcord-relay`. Values are `KEY=value` lines; the file is
parsed, not sourced.

| Key | Meaning |
|---|---|
| `HTTPS_PROXY_URL` | Proxy address clients use. Published as `proxy` and `httpsProxy.url`. Must be `https://`. |
| `NETWORK_CONFIG_URL` | This endpoint's public URL, for logs and reports. |
| `TURN_URLS` | Comma-separated TURN URLs handed to clients. UDP first, TLS second by convention. |
| `TURN_IDENTITY` | Username suffix in issued credentials (`<expiry>:Dohcord`). |
| `CREDENTIAL_TTL` | Lifetime of a TURN credential (default `24h`). |
| `SECRET_FILE` | File holding the coturn shared secret. Never served, never logged. |
| `TLS_CERT_FILE`, `TLS_KEY_FILE` | Certificate and key for the HTTPS endpoint. |
| `HTTPS_LISTEN` | API listen address, `:8443`. Port 443 belongs to the proxy. |
| `HTTP_LISTEN` | Plain HTTP listener, used only to answer ACME challenges on `:80`. |
| `ACME_WEBROOT` | Webroot for HTTP-01 challenges. |
| `ALLOWED_DOMAINS_FILE`, `DESTINATION_POLICY_FILE` | The authoritative policy. |
| `POLICY_STATE_FILE` | Applied-policy snapshot written after a successful apply. |
| `SQUID_CONF`, `SQUID_ALLOW_FILE`, `SQUID_BINARY` | Where Squid lives, for validation and reload. |
| `PER_IP_RATE_PER_MINUTE`, `PER_IP_BURST` | Per-client request limits on the API. |
| `GLOBAL_RATE_PER_MINUTE`, `GLOBAL_BURST` | Global request limits on the API. |
| `TRUST_PROXY_HEADER` | Set `true` **only** behind a reverse proxy that overwrites `X-Forwarded-For`. |

The API reloads this file on `SIGHUP` (the unit's `ExecReload`) and picks up
rotated secrets and tuning without a restart. `systemctl reload dohcord-relay-api`.

> Changing `HTTPS_PROXY_URL` changes what clients are told. It must stay the
> address clients actually reach the proxy on; the installer sets it from your
> answers.

## Squid configuration

`squid.conf` is rendered from `deploy/squid.conf.tmpl`. It is a TLS forward proxy:
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
installer's flags where they exist (`--max-connections`).

## coturn configuration

`turnserver.conf` is rendered from `deploy/turnserver.conf.tmpl`:

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
[troubleshooting.md](troubleshooting.md).

## Tuning guidelines

| Goal | Change |
|---|---|
| More concurrent connections per client | `--max-connections N` (default 40) |
| More concurrent TURN allocations | `--total-quota N`, `--user-quota N` |
| More bandwidth | `--max-bps N`, `--bps-capacity N` |
| Longer credential lifetime | `CREDENTIAL_TTL` in `config.env`, then reload the API |
| Stricter API rate limiting | `PER_IP_RATE_PER_MINUTE`, `GLOBAL_RATE_PER_MINUTE`, reload |

After any change: `sudo dohcord-relay-manager diagnostics`.

## Backups

Everything worth keeping is text plus two key files:

```bash
sudo tar -C /etc -czf dohcord-relay-$(date +%F).tar.gz dohcord-relay
```

`dohcord-relay-manager update` and policy edits already create backups under
`/var/backups/dohcord-relay/` (`config-*` directories and timestamped copies of
the two policy files).
