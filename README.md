# Dohcord-relay

A small, self-hosted relay for [Dohcord](https://github.com/Newipe)'s **Newipe**
and **Custom Profile** features. You run it on your own VPS; Dohcord gets one
URL from it and can then reach Discord even on networks that block or interfere
with Discord directly.

It installs two separate services on **one server**:

| Service | What it carries | Port |
|---|---|---|
| **HTTPS CONNECT proxy** (Squid) | Discord **HTTPS and WSS** (login, API, gateway, voice *signalling*) | TCP 443 |
| **TURN relay** (coturn) | Discord **voice/video UDP media** | UDP 3478, TCP 5349, UDP 49152–65535 |

Plus one tiny HTTPS endpoint that tells Dohcord where those two services are:

| Endpoint | What it returns | Port |
|---|---|---|
| `GET /network-config` | proxy URL, the destinations the proxy allows, temporary TURN credentials | TCP 8443 |

```text
                        YOUR VPS
                 ┌──────────────────────────────────────────────┐
  Dohcord        │                                              │
  (Electron)     │   Squid :443   ── CONNECT host:port ──┐      │
      │          │   (TLS forward proxy)                 │      │
      │  TLS     │                                       ▼      │
      ├─────────►│                              Discord HTTPS/WSS│
      │  CONNECT │                                              │
      │          │   coturn :3478/udp, :5349/tcp               │
      │  TURN    │        │                                     │
      ├─────────►│        └──── UDP relay ────► Discord RTC     │
      │          │                                              │
      │  HTTPS   │   dohcord-relay :8443 /network-config        │
      └─────────►│                                              │
                 └──────────────────────────────────────────────┘
```

Nothing is decrypted. The Discord TLS session runs end-to-end between Dohcord
and Discord; the proxy only forwards encrypted bytes. Voice media is relayed
with standard TURN, also without inspection.

---

## Contents

- [Quick start](#quick-start)
- [Why two services?](#why-two-services)
- [How Discord traffic flows](#how-discord-traffic-flows)
- [The domain-and-port allowlist](#the-domain-and-port-allowlist)
- [What you need](#what-you-need)
- [Domain or IP address? (TLS certificates)](#domain-or-ip-address-tls-certificates)
- [Install](#install)
- [Configure Dohcord](#configure-dohcord)
- [Your endpoints](#your-endpoints)
- [Editing the allowlist safely](#editing-the-allowlist-safely)
- [Firewall](#firewall)
- [Everyday operations](#everyday-operations)
- [Upgrading](#upgrading)
- [Uninstalling](#uninstalling)
- [Troubleshooting](#troubleshooting)
- [Security model and limitations](#security-model-and-limitations)
- [Files on the server](#files-on-the-server)
- [What was tested](#what-was-tested)

---

## Quick start

On a fresh Ubuntu or Debian VPS, as `root`:

```bash
sudo apt-get update && sudo apt-get install -y git
git clone https://github.com/Newipe/Dohcord-relay.git
cd Dohcord-relay
sudo deploy/install.sh
```

The installer asks one question:

```text
Dohcord-relay Installation

How should clients connect to this server?

  1. Domain name (recommended)
  2. Public IPv4 address

Choose [1/2]:
```

Answer, confirm the detected IP address (and your domain, if you chose one), and
let it run. At the end it prints the one URL you paste into Dohcord, plus the
firewall ports, certificate status and service status.

That's the whole installation. Everything below explains what it did and how to
look after it.

---

## Why two services?

Discord needs two different kinds of connection, and they cannot be served by one
mechanism:

| | HTTPS CONNECT proxy | TURN relay |
|---|---|---|
| Discord uses it for | the app itself: login, messages, gateway WebSocket, voice **signalling** | the actual voice/video **media** |
| Transport | TCP, wrapped in TLS to your server | UDP (plus TCP/TLS fallback) |
| Protocol the server speaks | HTTP `CONNECT` inside TLS | TURN (STUN extensions) |
| What the server can see | destination host name and port | allocation metadata only |
| What it forwards | an encrypted byte stream | UDP datagrams |

A proxy cannot carry UDP media, and TURN cannot fetch a web page. Dohcord needs
both, so the relay installs both, from the same wizard, on the same VPS.

### The HTTPS CONNECT proxy, in one paragraph

Dohcord opens a **TLS connection to your server's port 443** and sends a line
like `CONNECT discord.com:443` *inside* that encrypted connection. Your server
checks the requested host and port against its own allowlist, resolves the host
name on the VPS, checks the resolved address, then opens a plain TCP connection
to Discord and copies bytes in both directions. Dohcord then starts its own TLS
session to Discord through that tunnel. Your server never sees that inner
session, and an observer on the local network only sees TLS to your VPS.

### The TURN relay, in one paragraph

For voice, Discord tells the client to send UDP media to particular addresses.
With TURN, Dohcord instead asks your server for a **relay address**; the VPS opens
a UDP socket and forwards every datagram to Discord and back through the same
allocation. Discord's media stays encrypted (DTLS-SRTP); coturn just moves the
packets.

---

## How Discord traffic flows

### 1. Normal Discord HTTPS and WSS

```text
Dohcord ──TLS──► your VPS :443 ──TCP──► discord.com:443
   │                │
   │                └─ sees only "CONNECT discord.com:443"
   └─ TLS to Discord runs *through* the tunnel, end to end
```

Dohcord's PAC rules decide which requests to send to the proxy; the VPS decides
which requests to **allow**. Both must agree, but only the server's decision is
security-relevant.

### 2. Voice signalling can use a port that is not 443

This is the part people get wrong. Discord's
[voice documentation](https://docs.discord.com/developers/topics/voice-connections)
describes a `VOICE_SERVER_UPDATE` event that hands the client a **dynamically
assigned voice server**, for example:

```text
sweetwater-12345.discord.media:2048
```

The client prepends `wss://` and connects to **that exact port** — which changes
per call and per region, and is not always 443. Dohcord sends:

```http
CONNECT sweetwater-12345.discord.media:2048 HTTP/1.1
```

through the same TLS proxy connection. The relay's policy therefore allows
`discord.media` on **443 and 1024–65535**, and nothing else is allowed those
ports:

```text
discord.com       443
discord.gg        443
discordapp.com    443
discordapp.net    443
discord.media     443,1024-65535
```

The proxy never rewrites the requested port to 443 and never decrypts the
WebSocket. The sample port 2048 is not hardcoded anywhere.

### 3. Voice media

```text
Dohcord ──TURN/UDP──► your VPS :3478 ──UDP──► Discord RTC endpoint
                     allocation 49152-65535
```

Both directions use the same allocation. Discord's endpoint addresses are
discovered at call time and are never hardcoded.

---

## The domain-and-port allowlist

The proxy is public (Dohcord is public), so assume strangers will find it. It is
**not** an open proxy: two server-side files decide what it may reach, and both
must pass before a connection is made.

`/etc/dohcord-relay/allowed-domains.txt` — which domains:

```text
discord.com
discord.gg
discordapp.com
discordapp.net
discord.media
```

A domain allows itself and its subdomains, matched on DNS label boundaries:

| Requested destination | Result |
|---|---|
| `discord.com` | allow |
| `gateway.discord.com` | allow |
| `cdn.discordapp.com` | allow |
| `discord.com.evil.example` | **deny** |
| `evil-discord.com` | **deny** |
| `example.com` | **deny** |

`/etc/dohcord-relay/destination-policy.conf` — which TCP ports each domain may
use:

```text
discord.com       443
discord.gg        443
discordapp.com    443
discordapp.net    443
discord.media     443,1024-65535
```

Every domain in the allowlist must have a policy line, and every policy line must
belong to an allowlisted domain; anything else is rejected as a configuration
error rather than half-applied.

Additional protection, enforced by Squid at connect time:

- **CONNECT only.** Any other request gets `403`.
- **No IP literals.** `CONNECT 1.1.1.1:443` is denied; only host names match.
- **Resolved addresses are checked.** After the VPS resolves the host name, the
  address must not be loopback, private, link-local, CGNAT, documentation,
  benchmarking, multicast or this relay itself. This is what stops DNS rebinding
  from turning an allowed name into a connection to `127.0.0.1` or your
  private network.
- **Limits.** Per-client connection cap, global descriptor ceiling, request
  header limits, connect/read/lifetime timeouts.
- **An empty or invalid policy can never mean "allow everything".** The generated
  ACLs are validated with `squid -k parse` before Squid is reloaded, and the
  final rule is always `http_access deny all`.

> The allowlist proves *where* a connection may go. It cannot prove a request
> came from the official Dohcord app: anyone who knows your address can use the
> proxy for those Discord destinations. That is why the destination list, port
> policy, IP checks and limits are strict — they are the security boundary.

---

## What you need

- A VPS with a **public IPv4 address** (a 1:1 NAT host such as EC2 works).
- **Ubuntu 22.04/24.04** or **Debian 12+**, root access, systemd.
- About **1 CPU / 1 GB RAM** and roughly **1 Mbit/s per concurrent voice call**
  of bandwidth. Voice relaying is cheap; a small VPS handles dozens of calls.
- Ports **80/tcp, 443/tcp, 8443/tcp, 3478/udp, 5349/tcp, 49152–65535/udp**
  reachable from the internet (and open in your cloud firewall/security group).
- **SSH access preserved** — the installer never flushes firewall rules.

You do **not** need Docker, a database, user accounts, or an existing web server.

---

## Domain or IP address? (TLS certificates)

All public listeners use publicly trusted certificates. Nothing self-signed is
ever installed in production, and certificate verification is never disabled.

**Domain (recommended).** Let's Encrypt issues normal certificates over HTTP-01,
validated on port 80 by the relay's own endpoint. Renewal runs every six hours
and restarts the affected services automatically. The installer checks that the
domain's A record points at the IP you gave it, and warns/fails if an AAAA record
exists but the VPS has no working IPv6 (clients would otherwise prefer a broken
path).

**Public IPv4 only.** This works, but read this carefully:

- Let's Encrypt has issued IP-address certificates since January 2026, but **only
  on its `shortlived` profile: 160 hours (about 6⅔ days) per certificate**.
- That makes renewal a permanent requirement, not an installation step. The
  installer sets up automatic renewal with a six-hour timer and verifies it with
  `certbot renew --dry-run` at the end.
- If renewal breaks, the relay stops working within days. A domain certificate
  gives you weeks of slack instead.
- IP certificates need certbot 5.4+ (for webroot); the installer installs a
  private copy in `/opt/dohcord-relay-certbot` when the system certbot is older.

Choose IP mode when you cannot point DNS at the VPS. Choose a domain for anything
long-lived.

---

## Install

### Interactive (the normal way)

```bash
git clone https://github.com/Newipe/Dohcord-relay.git
cd Dohcord-relay
sudo deploy/install.sh
```

Test against Let's Encrypt staging first if you like (the certificate is not
trusted, so clients cannot use it yet):

```bash
sudo deploy/install.sh --staging
sudo deploy/install.sh          # for real: replaces the staging certificate
```

### Non-interactive

```bash
# domain
sudo deploy/install.sh --mode domain --domain relay.example.com --ip 203.0.113.10

# public IPv4 only
sudo deploy/install.sh --mode ip --ip 203.0.113.10
```

Useful options (see `--help`):

| Option | Meaning |
|---|---|
| `--email ADDRESS` | Let's Encrypt expiry notices (optional) |
| `--staging` | staging CA for test installs |
| `--user-quota N` | concurrent TURN allocations per credential (default 12) |
| `--total-quota N` | concurrent allocations for the relay (default 1200) |
| `--max-bps N` | per-session TURN bandwidth, bytes/s (default 2 MB/s) |
| `--bps-capacity N` | total TURN bandwidth reservation (default 250 MB/s) |
| `--max-connections N` | concurrent proxy connections per client IP (default 20) |
| `--distro-coturn` | use the distribution coturn package instead of building 4.18.0 |
| `--skip-verify` | skip the final verification suite |
| `--yes` | skip the confirmation prompt (still needs `--mode`) |

The installer is re-runnable. It keeps the existing TURN secret, an existing
valid certificate and any allowlist edits, and only rewrites the files it owns.

### What the installer does

1. Asks how clients connect (domain or IP), validates the public IPv4 and, for a
   domain, that the A record points at it.
2. Refuses to continue if 80, 443, 8443, 3478/udp or 5349/tcp are already taken
   by another service — it prints the listener and stops; it never reconfigures
   an existing web server.
3. Detects 1:1 NAT so coturn publishes the right `external-ip` mapping.
4. Creates the `turnserver` and `dohcord-relay` users and directories.
5. Opens exactly the required ports in ufw or firewalld, leaving existing rules
   (including SSH) untouched.
6. Installs **Squid** from the distribution, verifies the build has TLS support
   and Squid 5+, and picks the TLS-floor syntax that build accepts (GnuTLS and
   OpenSSL builds reject each other's spelling).
7. Installs **coturn**: builds the pinned 4.18.0 release with a verified checksum
   (or uses the distribution package with `--distro-coturn`), and checks every
   option in the generated `turnserver.conf` against `turnserver --help`.
8. Generates `/etc/dohcord-relay/turn-secret` and both policy files.
9. Builds the Go endpoint and writes `config.env`.
10. Obtains the certificate over HTTP-01 using a temporary ACME-only instance of
    the endpoint on port 80.
11. Renders the Squid ACLs from the policy files and validates the whole Squid
    configuration with `squid -k parse` **before** anything is started.
12. Starts and enables Squid, coturn and the endpoint, with the distribution
    `squid.service` and `coturn.service` disabled so they cannot fight over ports.
13. Installs the six-hour certificate renewal timer with a deploy hook that
    verifies the new certificate covers the host, publishes copies for the
    unprivileged services, and restarts/reloads them.
14. Runs `deploy/verify.sh` and prints a summary.

---

## Configure Dohcord

### In Dohcord (not on the server)

1. Open Dohcord's settings and find **Custom Profile** (also used by **Newipe**).
2. Add a profile / server and paste the **Network Configuration URL** the
   installer printed:

   ```text
   https://relay.example.com:8443/network-config
   ```

3. Save and select it.

Dohcord fetches that one document and gets everything else from it: the HTTPS
proxy URL, the destinations the proxy permits, and fresh TURN credentials with an
expiry. There is nothing else to type in, and no account or API key.

### On the VPS

Nothing — that is the point of the endpoint. If you want to see what Dohcord
receives:

```bash
curl -sS https://relay.example.com:8443/network-config | python3 -m json.tool
```

---

## Your endpoints

For a domain install (`relay.example.com`):

```text
HTTPS CONNECT proxy   https://relay.example.com:443
Network configuration https://relay.example.com:8443/network-config
TURN UDP              turn:relay.example.com:3478?transport=udp
TURN TLS              turns:relay.example.com:5349?transport=tcp
```

For an IP install, `relay.example.com` is replaced by your IPv4 address
everywhere. Both are generated from your answers — nothing is hardcoded.

The `/network-config` document looks like this (shortened):

```json
{
  "version": 1,
  "httpsProxy": {
    "url": "https://relay.example.com:443",
    "allowedDestinations": [
      { "domain": "discord.com", "ports": [443] },
      { "domain": "discord.gg", "ports": [443] },
      { "domain": "discordapp.com", "ports": [443] },
      { "domain": "discordapp.net", "ports": [443] },
      { "domain": "discord.media", "ports": [443],
        "portRanges": [{ "from": 1024, "to": 65535 }] }
    ]
  },
  "rtcRelay": {
    "expiresAt": 1794600000,
    "iceServers": [{
      "urls": [
        "turn:relay.example.com:3478?transport=udp",
        "turns:relay.example.com:5349?transport=tcp"
      ],
      "username": "1794600000:Dohcord",
      "credential": "……"
    }]
  }
}
```

- It is HTTPS-only, `Cache-Control: no-store`, and rate limited per client IP and
  globally.
- The advertised destination list is read from the policy Squid is **actually**
  enforcing, so the document cannot drift from reality.
- `GET /turn-credentials` still exists for older Dohcord builds and returns only
  the `expiresAt` + `iceServers` part.
- The permanent TURN secret never leaves the server and is never logged.

TURN credentials use coturn's standard REST scheme:

```text
username = "<unix expiration>:Dohcord"
password = base64(HMAC-SHA1(shared secret, username))
```

The lifetime defaults to 24 hours (`CREDENTIAL_TTL`).

---

## Editing the allowlist safely

Both files are plain text and live on the VPS:

```bash
sudoedit /etc/dohcord-relay/allowed-domains.txt
sudoedit /etc/dohcord-relay/destination-policy.conf
```

Examples:

```text
# allowed-domains.txt
discord.com
discord.gg
discordapp.com
discordapp.net
discord.media
```

```text
# destination-policy.conf
discord.com       443
discord.gg        443
discordapp.com    443
discordapp.net    443
discord.media     443,1024-65535
```

Then apply them:

```bash
sudo dohcord-relay -config /etc/dohcord-relay/config.env -policy-apply
```

What that command does, in order:

1. Parses and cross-validates both files (strict domain syntax, no IP literals,
   no wildcards, valid port numbers, no duplicates, no overlap, full coverage of
   the allowlist).
2. Renders the Squid ACLs.
3. Runs `squid -k parse` on the **complete** configuration.
4. Only if all of that passes: installs the new ACLs, writes the applied-policy
   snapshot used by `/network-config`, and reloads Squid.

If anything fails, the command prints the reason, changes nothing, and Squid
keeps enforcing the previous policy. `-policy-check` validates without applying.

`discord.media`'s dynamic range is configurable — it is just that line. Keep it
exclusive to `discord.media`: other Discord domains do not need it, and giving it
to them widens the proxy for no benefit.

> Do not add broad shared namespaces such as `googleapis.com`. If Discord
> genuinely needs a specific Google host, add that exact host name only, after
> confirming it. Fewer destinations is strictly safer.

---

## Firewall

| Port | Protocol | Purpose |
|---|---|---|
| 80 | TCP | HTTP-01 certificate validation (and renewal) |
| 443 | TCP | HTTPS CONNECT proxy |
| 8443 | TCP | Network configuration endpoint |
| 3478 | UDP | TURN |
| 5349 | TCP | TURN over TLS |
| 49152–65535 | UDP | TURN relayed media |

The installer opens these in ufw or firewalld and preserves everything else. If
your VPS sits behind a cloud security group (EC2, OVH, Hetzner firewall…), open
the same ports there too — the host firewall cannot do that for you.

**No extra inbound ports are needed for proxied destinations.** When the proxy
connects to `discord.media:2048`, port 2048 is the *remote* port on Discord; your
server only needs normal outbound TCP (and outbound UDP for TURN media).

---

## Everyday operations

```bash
# what is running
systemctl status dohcord-relay-squid.service dohcord-relay-coturn.service dohcord-relay-api.service

# logs
journalctl -u dohcord-relay-api.service -f
journalctl -u dohcord-relay-squid.service -f      # or /var/log/dohcord-relay/squid/cache.log
tail -f /var/log/dohcord-relay/turnserver/turnserver.log

# re-run all checks (services, listeners, policy, proxy allow/deny, API, TURN, certs)
sudo deploy/verify.sh

# policy work
sudo dohcord-relay -config /etc/dohcord-relay/config.env -policy-check
sudo dohcord-relay -config /etc/dohcord-relay/config.env -policy-apply

# certificate
sudo /opt/dohcord-relay-certbot/bin/certbot certificates --cert-name dohcord-relay
systemctl list-timers dohcord-relay-certbot-renew.timer

# which policy did Squid last accept
cat /etc/dohcord-relay/policy.json
```

`deploy/verify.sh` checks, among other things: all three services active; the
four listeners; Squid configured as a TLS forward proxy with `https_port`, no
`ssl_bump`, CONNECT-only rules and private-address filtering; the generated ACLs
matching the policy files exactly; real CONNECT tests through the proxy
(`discord.com:443` and `gateway.discord.gg:443` succeed; unlisted domains,
`discord.com.evil.example`, similarity tricks, IP literals, disallowed ports and
the dynamic range on *other* domains are denied); the `/network-config` document
matching the policy and not leaking the TURN secret; TURN allocation, wrong
password, expired username, quota and bidirectional media (when coturn's
utilities are installed); outbound UDP; and certificate validity plus
`certbot renew --dry-run`.

### Editing endpoint tuning

`/etc/dohcord-relay/config.env` holds the endpoint's own settings
(`CREDENTIAL_TTL`, rate limits, ports). After editing:

```bash
sudo systemctl restart dohcord-relay-api.service
```

Squid limits live in `/etc/dohcord-relay/squid.conf`. Change them through the
installer flags where possible (`--max-connections`), then:

```bash
sudo squid -k parse -f /etc/dohcord-relay/squid.conf
sudo systemctl reload dohcord-relay-squid.service
```

### Rotating the TURN secret

This invalidates every credential in flight (within one allocation lifetime):

```bash
sudo sh -c 'openssl rand -hex 32 > /etc/dohcord-relay/turn-secret'
sudo chown root:dohcord-relay /etc/dohcord-relay/turn-secret
sudo chmod 0640 /etc/dohcord-relay/turn-secret
sudo sed -i "s|^static-auth-secret=.*|static-auth-secret=$(sudo cat /etc/dohcord-relay/turn-secret)|" \
  /etc/dohcord-relay/turnserver.conf
sudo systemctl restart dohcord-relay-coturn.service dohcord-relay-api.service
```

---

## Upgrading

```bash
cd Dohcord-relay
git pull
sudo deploy/install.sh --mode domain --domain relay.example.com --ip 203.0.113.10
```

Re-running the installer is the supported upgrade path: it rebuilds the endpoint,
re-renders configuration, re-validates the policy and restarts the services. Your
allowlist edits, TURN secret and valid certificate are kept.

- **coturn:** `sudo deploy/install.sh --coturn-version 4.19.0` (only 4.18.0 has a
  pinned checksum; other versions build without one and print a warning).
- **Squid:** upgraded by `apt`; the installer re-checks TLS support and version
  and re-renders `squid.conf` for the right TLS syntax.

---

## Uninstalling

```bash
sudo systemctl disable --now dohcord-relay-squid.service \
  dohcord-relay-coturn.service dohcord-relay-api.service \
  dohcord-relay-certbot-renew.timer
sudo rm -f /etc/systemd/system/dohcord-relay-squid.service \
  /etc/systemd/system/dohcord-relay-coturn.service \
  /etc/systemd/system/dohcord-relay-api.service \
  /etc/systemd/system/dohcord-relay-certbot-renew.service \
  /etc/systemd/system/dohcord-relay-certbot-renew.timer
sudo rm -f /usr/local/bin/dohcord-relay /usr/local/bin/dohcord-relay-tls-deploy
sudo rm -rf /etc/dohcord-relay /var/log/dohcord-relay /var/www/dohcord-relay
sudo systemctl daemon-reload
# optional: remove the certificate lineage
sudo /opt/dohcord-relay-certbot/bin/certbot delete --cert-name dohcord-relay
# optional: remove the packages
sudo apt-get remove squid coturn
```

Firewall rules the installer added stay in place; remove them by hand if you want
them gone. If you edited `/etc/apparmor.d/local/usr.sbin.squid`, remove the
Dohcord-relay block there too.

---

## Troubleshooting

**The installer stops: "port(s) … already in use".**
Something else owns 80, 443, 8443, 3478 or 5349. It prints the listener and does
not touch it. Stop or move that service (for example an existing nginx), then
re-run. The relay does not integrate with another web server automatically.

**The installer stops on the DNS check.**
The domain's A record must contain the IP you supplied. Fix DNS (and wait for
propagation), or pass the matching `--ip`. If the domain has an AAAA record but
the VPS has no global IPv6, remove the AAAA record.

**Certificate issuance fails.**
Port 80 must be reachable from the internet for the domain/IP. Check the cloud
firewall and `journalctl -u dohcord-relay-api.service`. Re-run the installer; it
retries issuance when the current certificate is missing or near expiry.

**Certificate renewal fails (IP installs especially).**
IP certificates last 160 hours, so watch this. `deploy/verify.sh` includes
`certbot renew --dry-run`; run it and check the certbot log. Renewal needs port
80 to keep working.

**Dohcord shows a 403 or "proxy refused" for a Discord address.**
Squid denied it. Check `/var/log/dohcord-relay/squid/access.log` for
`TCP_DENIED/403`: the destination is not covered by the policy, or the port is
not allowed for that domain. Add the exact domain to both files and run
`-policy-apply`. If the log shows `HIER_NONE/-` with a 403, the resolved address
was rejected (private/loopback) — that is intentional.

**Voice connects but audio is silent / no relay candidate.**
TURN is not being reached: check UDP 3478 and 49152–65535 are open in the host
firewall *and* the cloud firewall, and that outbound UDP works
(`deploy/verify.sh` tests a public STUN server). Coturn logs specific errors in
`/var/log/dohcord-relay/turnserver/turnserver.log`.

**`486 Allocation Bandwidth Quota Reached`.**
`bps-capacity` is too small relative to `max-bps`: coturn reserves `max-bps` for
every allocation, so `bps-capacity / max-bps` is the number of concurrent
sessions. Raise `bps-capacity` or lower `max-bps`, then restart coturn.

**`403 Forbidden IP` on a TURN permission.**
The peer address fell into a denied range. Only private, loopback, link-local,
multicast and documentation ranges are denied; if a legitimate endpoint is in one
of those, add a narrow `allowed-peer-ip` for it.

**Squid will not start after an edit.**
Run `sudo squid -k parse -f /etc/dohcord-relay/squid.conf` — it prints the exact
line. Never start Squid with a broken policy; `-policy-apply` refuses to reload
one.

**Dohcord cannot validate the certificate.**
The certificate must be publicly trusted and must contain the exact host clients
use. `deploy/verify.sh` checks both the proxy and the TURN TLS listener. A staging
certificate is not trusted — re-run without `--staging`.

---

## Security model and limitations

Read this before exposing the relay publicly.

**What the server enforces**

- Only `CONNECT`, only allowlisted domains, only their permitted ports.
- Only public destination addresses, checked after server-side resolution.
- Bounded connections per client IP, bounded total descriptors, request header
  limits, connect/read/lifetime timeouts.
- No TLS interception: no `ssl_bump`, no custom CA, no client certificate.
- TURN requires short-lived credentials signed with a secret that never leaves
  the server; private/loopback/multicast peers are denied; quotas and bandwidth
  reservations bound allocations.
- The policy files are validated before they can change behaviour; an empty or
  broken policy denies everything.

**What it does not do**

- **It does not authenticate clients.** Anyone who knows your address can fetch
  `/network-config` and use the proxy for the allowed Discord destinations. The
  server cannot prove a request came from official Dohcord. The destination
  policy is the boundary; do not claim more.
- **Bandwidth inside a proxy tunnel is not shaped by Squid.** Stock Squid has no
  per-tunnel byte-rate limiter. Concurrency is capped per client and globally,
  and idle/lifetime timeouts apply, but a single tunnel can use the link. If you
  need hard per-client shaping, apply it at the network layer on your VPS. TURN
  media *is* rate-limited (`max-bps` / `bps-capacity`).
- **DNS rebinding resistance has a narrow window.** Squid resolves the name,
  checks the resolved address, and connects to that same resolved address, so an
  attacker cannot swap the answer between the check and the connect. A hostile
  resolver can still return a public address that later redirects at the
  application layer; the allowlist prevents that from reaching non-Discord
  services. Run a trustworthy resolver on the VPS.
- **No IPv6 endpoints are advertised.** TURN URLs use the domain name or IPv4
  address. If your domain publishes AAAA and the VPS has no IPv6, the installer
  stops rather than shipping a broken configuration.
- **The endpoint is public by design.** It hands out TURN credentials to anyone
  who asks, at a rate limit. That is the trade-off for "no accounts".

**Operational notes**

- Certificates and keys are readable only by the services that need them
  (`/etc/dohcord-relay/tls`, root-owned directory, group-readable files).
- Temporary TURN credentials are never logged; only the client address and expiry.
- The shared TURN secret is stored once, in `/etc/dohcord-relay/turn-secret`.

---

## Files on the server

| Path | Purpose |
|---|---|
| `/etc/dohcord-relay/squid.conf` | proxy configuration (TLS forward proxy, limits, checks) |
| `/etc/dohcord-relay/squid-allow.conf` | **generated** ACLs — do not edit |
| `/etc/dohcord-relay/allowed-domains.txt` | domains the proxy may reach (edit this) |
| `/etc/dohcord-relay/destination-policy.conf` | ports per domain (edit this) |
| `/etc/dohcord-relay/policy.json` | the exact policy Squid is enforcing |
| `/etc/dohcord-relay/turnserver.conf` | coturn configuration |
| `/etc/dohcord-relay/turn-secret` | TURN shared secret (`root:dohcord-relay 0640`) |
| `/etc/dohcord-relay/config.env` | endpoint configuration |
| `/etc/dohcord-relay/tls/` | certificate, key and the combined `squid.pem` |
| `/usr/local/bin/dohcord-relay` | the endpoint / policy tool |
| `/usr/local/bin/dohcord-relay-tls-deploy` | certbot deploy hook |
| `/var/www/dohcord-relay` | ACME HTTP-01 webroot |
| `/var/log/dohcord-relay/squid/` | Squid access and cache logs (owned by `proxy`) |
| `/var/log/dohcord-relay/turnserver/` | coturn log (owned by `turnserver`) |

Units: `dohcord-relay-squid.service`, `dohcord-relay-coturn.service`,
`dohcord-relay-api.service`, `dohcord-relay-certbot-renew.timer`.

---

## What was tested

This project is a networking product, so treat "works" claims carefully.

**Verified in development against real software (not just unit tests):**

- The Go service builds, `go vet` is clean, and the unit tests pass (policy
  parsing and boundary matching, Squid ACL rendering, credential HMAC vector,
  config validation, `/network-config` schema and rate limiting).
- **Squid 6.14** (Ubuntu 24.04 build, GnuTLS) was started with the repository's
  own rendered `squid.conf` and generated ACLs, and driven with real HTTPS proxy
  requests:
  - CONNECT to an allowlisted domain on 443 succeeded end to end (TLS through
    the tunnel), and to a second allowlisted domain on a dynamic high port was
    permitted.
  - Denied: an unlisted domain, `allowed.com.evil.test`, `evilallowed.com`, an
    IP-literal destination, a port outside the domain's policy, and the dynamic
    range on a non-media domain.
  - A plain `GET` through the proxy returned 403 (CONNECT-only).
  - A hostname resolving to `127.0.0.1` and one resolving to `10.1.2.3` were
    both denied *after* resolution (`TCP_DENIED/403`), while a public address was
    tunnelled (`TCP_TUNNEL`).
  - Policy changes: removing a domain and running `-policy-apply` made the same
    Squid process deny it without a restart; an inconsistent or empty policy was
    refused and the running policy stayed in force.
  - TLS 1.0/1.1 are refused, TLS 1.2 accepted.
- The endpoint was run over HTTPS and returned the documented JSON (correct
  policy, HMAC credential, `no-store`, HTTP/2), 404 for unknown paths, and 429
  once the per-IP burst was spent. Logs contain no secrets.
- **`deploy/verify.sh` itself** was run against that live Squid plus endpoint:
  39 checks passed, 0 failed, with systemd, renewal and TURN-runtime checks
  skipped in the sandbox (the self-signed test certificate was supplied through
  its `DOHCORD_RELAY_CA_FILE` / `DOHCORD_RELAY_PROXY_CA` overrides, which still
  verify the certificate rather than disabling verification).
- Two more bugs that running the verifier found and fixed: it treated the word
  `ssl_bump` inside a comment as a configured directive, and it reported a failed
  proxy certificate check as "a non-media domain was allowed on a dynamic port".
- Bugs this testing found and fixed: Squid rejects `options=` on GnuTLS builds
  and is *fatal* on `tls-min-version=1.2` there; two ACL types cannot share a
  name; `.domain` already covers the apex; `::ffff:0:0/96` silently collapses to
  `0.0.0.0/0` (which would have denied every destination).

**Not verified here, so not claimed:**

- **A real Discord call or Electron client through the relay.** That needs the
  Dohcord app on a real network; the proxy and TURN paths were tested separately
  as described above.
- **Live coturn relaying in this environment.** The coturn configuration and the
  credential algorithm are unchanged from the previous tested revision, and the
  credential output was verified live, but the sandbox used for this change could
  not run a coturn binary (no root; available packages were ABI-incompatible). Run
  `sudo deploy/verify.sh` on your VPS — it performs real allocation, expired- and
  wrong-credential, quota and bidirectional media tests.
- **Let's Encrypt issuance and renewal against the public CA.** That needs port 80
  of a real public address. The ACME responder, IP-SAN/domain checks and deploy
  hook were exercised locally; `verify.sh` runs `certbot renew --dry-run` on your
  server.
- **The installer end to end on a fresh VPS.** It was syntax-checked and its
  individual steps were exercised, but it was not executed as root against a real
  Ubuntu/Debian host in a cloud with real DNS and a public IP.
- **systemd units under systemd** and **reboot recovery** — verify with
  `systemctl status` and a reboot on your VPS.

After installing, the honest final checks are:

```bash
sudo deploy/verify.sh
curl -sS https://YOUR-HOST:8443/network-config | python3 -m json.tool
```

then place a real call from Dohcord and confirm the ICE candidate pair is
`relay` with bytes flowing both ways.
