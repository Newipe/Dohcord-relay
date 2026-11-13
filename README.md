# Dohcord Relay

A minimal TURN relay for [Dohcord](https://github.com/Newipe)'s Discord WebRTC
feature, plus one small HTTPS endpoint that hands Dohcord temporary TURN
credentials. Users configure nothing: the Electron app calls the endpoint and
gets a working `iceServers` array.

```text
Dohcord — Discord WebRTC
          |
          | TURN / UDP  (primary)
          | TURN / TLS  (fallback)
          v
VPS 13.48.52.216   coturn :3478/udp, :5349/tcp, relay 49152-65535/udp
          |
          | UDP forwarding
          v
Discord's actual RTC endpoint   (dynamic, never hardcoded)
```

Incoming media returns through the same TURN allocation; nothing is decrypted,
rewritten or proxied beyond standard TURN relaying.

## What this is, and what it deliberately is not

* **coturn** does all TURN work. There is no custom relay, VPN, QUIC tunnel,
  SOCKS/HTTP proxy or DNS service here.
* **One Go binary** (standard library only) terminates HTTPS on 443, answers
  ACME HTTP-01 on 80, and serves `GET /turn-credentials`. No database, no user
  accounts, no dashboard, no client API keys, no persistent records.
* The only thing stored is one random shared secret in
  `/etc/dohcord-relay/turn-secret`; it is never served and never logged.

TURN's security model, stated plainly: coturn authenticates *allocations* with
short-lived credentials, and this relay only accepts credentials signed with its
shared secret. Anyone who can reach the public endpoint can obtain such
credentials, so the endpoint cannot prove a request came from the official
Dohcord build. The defence is rate limiting, allocation quotas and bandwidth
ceilings, not client identity.

## Layout

```text
main.go, credentials.go, ratelimit.go, main_test.go   credential endpoint
deploy/install.sh                                      installer (Ubuntu/Debian)
deploy/verify.sh                                       verification suite
deploy/turnserver.conf.tmpl                            coturn configuration
deploy/config.env.tmpl                                 endpoint configuration
deploy/dohcord-relay-coturn.service                    coturn unit
deploy/dohcord-relay-credentials.service                endpoint unit
deploy/dohcord-relay-certbot-renew.{service,timer}      certificate renewal
deploy/dohcord-relay-tls-deploy                         certbot deploy hook
```

## Install

On the VPS (Ubuntu 22.04+/Debian 12+, root):

```bash
git clone https://github.com/Newipe/Dohcord-relay.git
cd Dohcord-relay
sudo deploy/install.sh
```

No email address is needed: the ACME account is registered without a contact
address. Add `--email ADDRESS` only if you want Let's Encrypt expiry notices.

Test the whole pipeline against Let's Encrypt staging first, then run it for
real (staging certificates are not trusted by clients):

```bash
sudo deploy/install.sh --staging
sudo deploy/install.sh
```

Useful flags: `--email ADDRESS`, `--ip ADDRESS`, `--realm NAME`, `--distro-coturn`,
`--coturn-version VERSION`, `--user-quota N`, `--total-quota N`,
`--max-bps N`, `--bps-capacity N`, `--skip-renew-test`. `--help` lists them all.

The installer is idempotent. Re-running it keeps the existing TURN secret and a
still-valid certificate, and only rewrites files it owns.

### What the installer does

1. Verifies the OS (`ubuntu` or `debian`) and that it runs as root.
2. Verifies ports 80/tcp, 443/tcp, 3478/udp and 5349/tcp are free. If an existing
   web server holds them the installer stops and prints what is listening — it
   never reconfigures or stops another service. (See
   [Existing web server](#existing-web-server) for the manual integration.)
3. Detects the network layout. If `13.48.52.216` is configured on an interface,
   relays bind it directly. If the public address is 1:1 NAT (typical for EC2),
   relays bind the private address and coturn publishes
   `external-ip=13.48.52.216/<private>`.
4. Creates the `turnserver` and `dohcord-relay` system users.
5. Opens only the required ports in ufw or firewalld, leaving existing rules
   alone, and warns if the SSH port is not allowed.
6. Installs coturn 4.18.0 built from the pinned, checksum-verified upstream
   release (`--distro-coturn` uses the distribution package instead and warns if
   it is old).
7. Generates `/etc/dohcord-relay/turn-secret` (32 random bytes, hex, `0640`) and
   renders `/etc/dohcord-relay/turnserver.conf`. Every option in the rendered
   file is checked against `turnserver --help` of the installed binary; an
   unsupported option aborts the install instead of being silently ignored.
8. Builds and installs `/usr/local/bin/dohcord-relay-credentials` with the
   distribution Go compiler, writes `/etc/dohcord-relay/config.env`, installs
   the systemd unit.
9. Installs `/usr/local/bin/dohcord-relay-tls-deploy`, the certbot deploy hook.
10. Installs certbot 5.4+ (a private venv if the distribution package is older),
    starts a temporary ACME-responder-only instance of the credential endpoint,
    and requests a **shortlived IP certificate** for `13.48.52.216` with
    `--ip-address` and `--preferred-profile shortlived` over HTTP-01 webroot.
11. Installs and enables the renewal service and timer (`6h`, with jitter).
12. Starts both services, runs `deploy/verify.sh` (which includes
    `certbot renew --dry-run`, once port 80 is served by the real service), and
    prints a summary.

## Server layout

| Path | Purpose |
|---|---|
| `/etc/dohcord-relay/turnserver.conf` | coturn configuration (`root:turnserver 0640`) |
| `/etc/dohcord-relay/turn-secret` | TURN shared secret (`root:dohcord-relay 0640`) |
| `/etc/dohcord-relay/config.env` | credential endpoint configuration |
| `/etc/dohcord-relay/tls/{fullchain,privkey}.pem` | certificate copies for the unprivileged services |
| `/usr/local/bin/dohcord-relay-credentials` | credential endpoint |
| `/usr/local/bin/dohcord-relay-tls-deploy` | certbot deploy hook |
| `/usr/local/bin/turnserver` | coturn (source install) |
| `/var/www/dohcord-relay` | ACME HTTP-01 webroot |
| `/var/log/dohcord-relay/turnserver.log` | coturn log |

Services: `dohcord-relay-coturn.service`, `dohcord-relay-credentials.service`,
`dohcord-relay-certbot-renew.timer`.

## TURN configuration

Key settings in `/etc/dohcord-relay/turnserver.conf`:

| Setting | Value | Why |
|---|---|---|
| `listening-port` | 3478 | primary TURN over UDP |
| `tls-listening-port` | 5349 | TURN over TLS |
| `min-port` / `max-port` | 49152 / 65535 | media allocation range |
| `listening-ip` / `relay-ip` | local addresses | bind what exists on the host |
| `external-ip` | `13.48.52.216[/private]` | publish the public address, with NAT mapping when needed |
| `use-auth-secret` + `static-auth-secret` | random 64-char secret | coturn TURN REST authentication |
| `realm` / `server-name` | `dohcord.relay` | TURN realm |
| `fingerprint` | on | STUN/TURN fingerprinting |
| `cert` / `pkey` | `/etc/dohcord-relay/tls/*` | Let's Encrypt IP certificate |
| `tlsv1=0`, `tlsv1_1=0` | TLS 1.2/1.3 only | TLS 1.0/1.1 disabled |
| `no-tcp-relay` | on | peers are reached over UDP; this is not a TCP proxy |
| `user-quota` / `total-quota` | 12 / 1200 | concurrent allocations per credential / overall |
| `max-bps` / `bps-capacity` | 2000000 / 250000000 | ~16 Mbit/s per session, ~2 Gbit/s of reservations |
| `denied-peer-ip` (0/8, 10/8, 100.64/10, 127/8, 169.254/16, 172.16/12, 192.0.0/24, 192.168/16, 198.18/15, 198.51.100/24, 203.0.113/24, 224/4, all IPv6 special ranges) | denied | no relaying to private, loopback, link-local or multicast destinations |
| `allowed-peer-ip` | `13.48.52.216` | allows same-relay hairpin calls and the local media self-test |
| `no-multicast-peers` | on | extra guard against broadcast destinations |
| `no-software-attribute` | on | no implementation details in STUN replies |

`bps-capacity` deserves care: coturn reserves `max-bps` for every open
allocation, so `bps-capacity / max-bps` is the number of concurrent relayed
sessions the relay accepts. Setting it too low makes coturn reject nearly every
allocation with `486 Allocation Bandwidth Quota Reached` (this genuinely happened
during development). Match it to the VPS uplink.

## The credential endpoint

```http
GET https://13.48.52.216/turn-credentials
```

```json
{
  "expiresAt": 1794600000,
  "iceServers": [
    {
      "urls": [
        "turn:13.48.52.216:3478?transport=udp",
        "turns:13.48.52.216:5349?transport=tcp"
      ],
      "username": "1794600000:Dohcord",
      "credential": "c2VjcmV0LW5vdC1yZWFsbHk="
    }
  ]
}
```

Behaviour:

* HTTPS only, with a publicly trusted certificate for the IP address.
  `Cache-Control: no-store, no-cache, must-revalidate, max-age=0`,
  `Pragma: no-cache`, `X-Content-Type-Options: nosniff`,
  `Access-Control-Allow-Origin: *` (no cookies or credentials involved).
* Fresh credentials on every request; the TURN shared secret is never returned
  and never logged (only client address and expiry are logged).
* `503` with `{"error":"turn configuration unavailable"}` when the secret is
  missing, unreadable or too short — the reason stays in the local log.
* `429` with `Retry-After` when rate limited.
* Per-IP token bucket (`PER_IP_RATE_PER_MINUTE`, `PER_IP_BURST`) plus a global
  bucket (`GLOBAL_RATE_PER_MINUTE`, `GLOBAL_BURST`).
* Only `/turn-credentials` is an API. Port 80 answers ACME HTTP-01 challenges and
  returns `404` for everything else.

Only the two configured URLs are ever returned; the URL list is configuration
(`TURN_URLS`), not client input.

### Credential scheme (coturn TURN REST authentication)

```text
username = "<unix expiration timestamp>:Dohcord"
password = base64(HMAC-SHA1(key = shared secret, message = username))
```

* Lifetime: 24 hours (`CREDENTIAL_TTL`, changeable between 1 minute and 7 days).
* The password is the standard padded base64 of the raw HMAC-SHA1 digest, which
  is exactly what coturn computes for `use-auth-secret` — verified against a real
  coturn instance (see [Tests](#tests)).
* coturn rejects the credential once the timestamp has passed, and rejects any
  credential not signed with the shared secret.

Rotate the secret (invalidates every credential in flight, within one allocation
lifetime):

```bash
sudo sh -c 'openssl rand -hex 32 > /etc/dohcord-relay/turn-secret'
sudo chown root:dohcord-relay /etc/dohcord-relay/turn-secret
sudo chmod 0640 /etc/dohcord-relay/turn-secret
# keep turnserver.conf in sync, then restart both consumers
sudo sed -i "s|^static-auth-secret=.*|static-auth-secret=$(cat /etc/dohcord-relay/turn-secret)|" \
  /etc/dohcord-relay/turnserver.conf
sudo systemctl restart dohcord-relay-coturn.service dohcord-relay-credentials.service
```

## TLS for a bare IP address

No domain name is needed. Let's Encrypt issues IP-address certificates only with
its `shortlived` profile (~160 hours), validated over HTTP-01:

```bash
certbot certonly \
  --preferred-profile shortlived \
  --webroot --webroot-path /var/www/dohcord-relay \
  --ip-address 13.48.52.216 \
  --cert-name dohcord-relay \
  --deploy-hook /usr/local/bin/dohcord-relay-tls-deploy \
  --agree-tos --register-unsafely-without-email
```

(Use `--email ADDRESS` instead of `--register-unsafely-without-email` if you want
Let's Encrypt expiry notices.)

`--ip-address` needs certbot 5.3+ and webroot support needs 5.4+; the installer
reuses a suitable `certbot` if present, otherwise installs one in
`/opt/dohcord-relay-certbot`.

Renewal: `dohcord-relay-certbot-renew.timer` runs every 6 hours with jitter and
calls `certbot renew` for the `dohcord-relay` lineage. Certbot renews
certificates valid for under 10 days at half their lifetime, so a 160-hour
certificate is replaced with ~80 hours left; six-hour checks leave many retries
before expiry. No `renew_before_expiry` is set (an inherited 30-day value would
renew on every run).

The deploy hook runs only after a successful issuance/renewal and:

1. verifies the new certificate contains `13.48.52.216` as an IP SAN
   (`openssl x509 -checkip`) and fails loudly if not;
2. copies `fullchain.pem` and `privkey.pem` to `/etc/dohcord-relay/tls` as
   `root:dohcord-relay 0640`, because both services run unprivileged and cannot
   read `/etc/letsencrypt/live`;
3. restarts `dohcord-relay-credentials.service` and
   `dohcord-relay-coturn.service` so both use the new certificate.

The credential endpoint also reloads the certificate on `SIGHUP` and whenever the
file changes on disk (`systemctl reload dohcord-relay-credentials`).

## Firewall

| Port | Protocol | Purpose |
|---|---|---|
| 80 | TCP | IP certificate HTTP-01 validation |
| 443 | TCP | HTTPS credential endpoint |
| 3478 | UDP | primary TURN |
| 5349 | TCP | TURN over TLS |
| 49152–65535 | UDP | TURN media allocations |

The installer opens exactly these in ufw or firewalld and never removes SSH or
other rules. If the VPS sits behind a cloud security group (EC2, for example),
the same ports must be allowed there — the host firewall cannot do that for you.
coturn also listens on 3478/tcp and 5349/udp by default; those are not opened, so
only the required transports are reachable.

## Service operations

```bash
systemctl status dohcord-relay-coturn.service dohcord-relay-credentials.service
systemctl restart dohcord-relay-coturn.service
systemctl restart dohcord-relay-credentials.service
journalctl -u dohcord-relay-credentials.service -f
tail -f /var/log/dohcord-relay/turnserver.log
systemctl list-timers dohcord-relay-certbot-renew.timer
certbot certificates --cert-name dohcord-relay   # or /opt/dohcord-relay-certbot/bin/certbot
```

## Verification

```bash
sudo deploy/verify.sh
```

It checks: both services active; UDP 3478 and TCP 5349 listening; relay range
49152–65535; quotas and peer filtering present; the HTTPS response contract
(status, `no-store`, JSON, `expiresAt` ≈ now + TTL, `<timestamp>:Dohcord`
username, HMAC recomputed from the local secret); TLS validity for the IP; a real
TURN client obtaining a relay candidate over UDP and over TLS; rejection of a
wrong password, an expired username and unauthenticated requests; bidirectional
media through the relay; port 80 serving an ACME challenge file (written into the
webroot, then fetched back over HTTP); outbound UDP (STUN to a public server); the
certificate's IP SAN; the renewal timer; and `certbot renew --dry-run`.

### Tests

What was actually run, and where: coturn **4.18.0** was built from the pinned
upstream release in a Linux sandbox and driven by the project's own rendered
configuration, the real credential binary, and coturn's `turnutils_uclient` /
`turnutils_peer`. Public-IP-specific steps were adjusted to loopback only for
that sandbox (unprivileged ports, `allow-loopback-peers`); nothing else in the
configuration was relaxed.

| Check | Result |
|---|---|
| coturn 4.18.0 starts with the generated configuration | pass — 0 parse warnings |
| Every option in the generated config exists in coturn 4.18.0 | pass |
| UDP listener + TCP/TLS listener | pass |
| TLS 1.0 / 1.1 refused, TLS 1.2 / 1.3 accepted | pass |
| HTTPS endpoint: JSON, HTTP/2, `Cache-Control: no-store` | pass |
| `expiresAt` = now + 24h, username `<timestamp>:Dohcord` | pass |
| Credential = `base64(HMAC-SHA1(secret, username))` | pass — matched an independent Python computation |
| Allocation with issued credentials (UDP) | pass — relay candidate from the allocation range |
| Allocation with issued credentials over TLS | pass |
| Wrong password rejected | pass — coturn `401 Unauthorized` (“message integrity does not match any auth secret”) |
| Expired username rejected | pass — coturn `401 Unauthorized` (“time-limited username timestamp is in the past”) |
| Unauthenticated allocation rejected | pass — coturn `401 Unauthorized` |
| Per-user allocation quota | pass — second allocation with `user-quota=1` rejected with `486` |
| Bidirectional media through the relay (UDP) | pass — 20/20 messages, 2000/2000 bytes echoed |
| Bidirectional media through the relay (TLS) | pass — 20/20 messages |
| Port 80 serves ACME HTTP-01 challenge files from the webroot | pass — probe file fetched back over HTTP |
| Missing secret → clear error | pass — `503 {"error":"turn configuration unavailable"}` |
| Per-IP rate limit | pass — burst exhausted → `429` |
| `deploy/verify.sh` against a live instance | 22 pass, 0 fail, 1 warning (below), 4 skipped (systemd/renewal) |

Not verified here, and therefore not claimed:

* **Deployment to 13.48.52.216.** This environment has no access to that VPS, so
  the installer was never executed against it.
* **Real Let's Encrypt IP certificate issuance and renewal.** That needs port 80
  of the public IP; only the TLS serving path, IP-SAN verification and the deploy
  hook logic were exercised, with a locally generated IP-SAN certificate.
* **systemd units under systemd.** No systemd in the build sandbox; units and
  scripts were syntax-checked and their commands exercised manually.
* **A real Electron/WebRTC client** (no browser here). TURN behaviour was proven
  with coturn's own TURN client instead.
* **Outbound UDP to a public STUN server** — the sandbox filters UDP to
  non-DNS ports, so `verify.sh` reports a warning there. On the VPS this check is
  expected to pass; if it does not, relayed media cannot reach Discord.

Finish verification on the VPS:

```bash
sudo deploy/verify.sh                                  # all checks, including renewal
sudo certbot certificates --cert-name dohcord-relay     # IP SAN + expiry (~160h)
curl -sS https://13.48.52.216/turn-credentials | head -c 400
```

Then place a real call from Dohcord through the relay and confirm the ICE
candidate pair is `relay`, with bytes flowing both ways.

## Tuning

`/etc/dohcord-relay/config.env` (restart `dohcord-relay-credentials` after
editing): `CREDENTIAL_TTL`, `PER_IP_RATE_PER_MINUTE`, `PER_IP_BURST`,
`GLOBAL_RATE_PER_MINUTE`, `GLOBAL_BURST`, `TURN_URLS`, `TURN_IDENTITY`,
`TRUST_PROXY_HEADER` (only behind a proxy that overwrites `X-Forwarded-For`).

coturn limits live in `/etc/dohcord-relay/turnserver.conf`; re-run the installer
with `--user-quota`, `--total-quota`, `--max-bps` or `--bps-capacity` to change
them in a supported way, then `systemctl restart dohcord-relay-coturn.service`.

## Troubleshooting

**`486 Allocation Bandwidth Quota Reached`.** `bps-capacity` is smaller than a
few `max-bps` reservations. Raise `bps-capacity` (or lower `max-bps`).

**`403 Forbidden IP` on permission/channel bind.** The peer address is in a
denied range. Only private, loopback, link-local, multicast and documentation
ranges are denied; if a legitimate endpoint falls into one, add a narrow
`allowed-peer-ip` for it.

**Allocations time out.** UDP 3478 (and the relay range) is not reaching the
host, or outbound UDP is filtered. `deploy/verify.sh` reports both.

**Issuance fails with `Invalid response ... 404` on the challenge.** The CA reached
port 80 but the challenge file was not served. The endpoint serves
`<ACME_WEBROOT>/.well-known/acme-challenge/<token>`, which is where
`certbot --webroot` writes it; check `ACME_WEBROOT` in `config.env` and run
`sudo bash deploy/verify.sh`, whose ACME check writes a probe file and fetches it
back over HTTP.

**Certificate renewal fails.** Port 80 must stay reachable for HTTP-01; check
`journalctl -u dohcord-relay-certbot-renew.service`, then run
`certbot renew --cert-name dohcord-relay --dry-run` (or the venv certbot at
`/opt/dohcord-relay-certbot/bin/certbot`). With a 160-hour certificate, act well
before expiry.

**Port already in use.** The installer refuses to continue and prints the
listener. Stop or move the conflicting service; it will not touch existing web
server configuration.

<a name="existing-web-server"></a>
**Existing web server on 80/443.** The installer stops rather than reconfiguring
it. To integrate manually: serve `/.well-known/acme-challenge/` from
`/var/www/dohcord-relay` over plain HTTP, run certbot with
`--webroot -w /var/www/dohcord-relay --ip-address 13.48.52.216
--preferred-profile shortlived`, copy the certificates with
`/usr/local/bin/dohcord-relay-tls-deploy`, and reverse-proxy
`https://13.48.52.216/turn-credentials` to `127.0.0.1:8080` after setting
`HTTPS_LISTEN=127.0.0.1:8080`, `HTTP_LISTEN=` and `TRUST_PROXY_HEADER=true` in
`config.env` (the proxy must overwrite `X-Forwarded-For`).

## Updating

* **coturn:** `sudo deploy/install.sh --coturn-version 4.19.0`
  (or whatever the current release is; the pinned checksum applies to 4.18.0).
* **credential endpoint:** `git pull && sudo deploy/install.sh`
  rebuilds the binary and restarts the service.

## Removing

```bash
sudo systemctl disable --now dohcord-relay-coturn.service \
  dohcord-relay-credentials.service dohcord-relay-certbot-renew.timer
sudo rm -f /etc/systemd/system/dohcord-relay-*.service \
  /etc/systemd/system/dohcord-relay-certbot-renew.timer
sudo rm -f /usr/local/bin/dohcord-relay-credentials /usr/local/bin/dohcord-relay-tls-deploy
sudo rm -rf /etc/dohcord-relay /var/log/dohcord-relay /var/www/dohcord-relay
sudo systemctl daemon-reload
# optionally: sudo certbot delete --cert-name dohcord-relay
```
