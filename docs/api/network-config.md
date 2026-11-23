# Network Configuration API

The one endpoint Pishcord needs. It returns the proxy endpoint, the routing policy
and short-lived TURN credentials, all active at install time.

```text
GET https://<relay>:8443/network-config
```

The port is configurable (`NETWORK_CONFIG_PORT`, default `8443`); the path, the
JSON document, TLS and rate limiting are the same on any port. Pishcord profiles
must name the configured port in their Network Configuration URL.

- HTTPS only; TLS is validated normally — nothing here asks a client to skip
  verification.
- `Content-Type: application/json`, `Cache-Control: no-store`.
- Rate limited per client IP (`PER_IP_RATE_PER_MINUTE`, burst) and globally.
- No authentication, no account, no API key — it is configuration data, not an
  authorization mechanism. Enforcement happens in Squid.
- `GET /turn-credentials` still exists and returns only the TURN part, for older
  Pishcord builds.

## Schema

`schemaVersion` is `1`. `version` carries the same value for clients written
before `schemaVersion` existed.

```json
{
  "schemaVersion": 1,
  "version": 1,
  "proxy": { "scheme": "https", "host": "relay.example.com", "port": 443 },
  "routing": {
    "domains": [
      { "host": "discord.com", "match": "suffix",
        "ports": [ { "from": 443, "to": 443 } ] },
      { "host": "discord.media", "match": "suffix",
        "ports": [ { "from": 443, "to": 443 },
                   { "from": 1024, "to": 65535 } ] },
      { "host": "discord-attachments-uploads-prd.storage.googleapis.com",
        "match": "exact",
        "ports": [ { "from": 443, "to": 443 } ] }
    ]
  },
  "httpsProxy": {
    "url": "https://relay.example.com:443",
    "allowedDestinations": [
      { "domain": "discord.com", "ports": [443] },
      { "domain": "discord.media", "ports": [443],
        "portRanges": [ { "from": 1024, "to": 65535 } ] }
    ]
  },
  "rtcRelay": {
    "expiresAt": 1794600000,
    "iceServers": [ {
      "urls": [ "turn:relay.example.com:3478?transport=udp",
                "turns:relay.example.com:5349?transport=tcp" ],
      "username": "1794600000:Pishcord",
      "credential": "<base64 HMAC>"
    } ]
  }
}
```

### `proxy`

| Field | Meaning |
|---|---|
| `scheme` | Always `https`. |
| `host` | The proxy host, no port. A domain or an IPv4 address, matching your install mode. |
| `port` | The CONNECT proxy port, normally `443`. **This is not the configuration endpoint**; the configured API port (8443 by default) is where this document lives and is never a proxy target. |

### `routing.domains[]`

| Field | Meaning |
|---|---|
| `host` | Normalized destination name: lower case, no trailing dot, no port. |
| `match` | `exact` — this host only. `suffix` — this host and its subdomains. |
| `ports[]` | Inclusive TCP ranges. A single port is `from == to`. |

Matching is on DNS label boundaries, exactly as Squid enforces it:

| Rule | Requested host | Result |
|---|---|---|
| `suffix` `discord.com` | `discord.com` | match |
| `suffix` `discord.com` | `gateway.discord.com` | match |
| `suffix` `discord.com` | `notdiscord.com` | no match |
| `suffix` `discord.com` | `discord.com.example.org` | no match |
| `exact` `uploads.example.com` | `uploads.example.com` | match |
| `exact` `uploads.example.com` | `a.uploads.example.com` | no match |

Ports are reported as enforced. A destination whose policy line is
`discord.media 443,1024-65535` publishes exactly `443` and `1024-65535`; nothing
is widened for neatness.

### `httpsProxy`

The original fields, kept so older clients keep working:

- `url` — the full proxy URL.
- `allowedDestinations[]` — `domain`, `ports` (single ports) and optional
  `portRanges`. Entries are ordered as in the policy files.

`routing` and `httpsProxy.allowedDestinations` describe the same policy; `routing`
adds the match mode and expresses every port as a range. New integrations should
read `routing`.

### `rtcRelay`

- `expiresAt` — Unix seconds; the credential is not valid after this.
- `iceServers[].urls` — TURN URLs in preference order.
- `username` — `<expiresAt>:<TURN_IDENTITY>`.
- `credential` — `base64(HMAC-SHA1(shared secret, username))`, coturn's REST scheme.

Credentials are bearer secrets for the lifetime of an allocation. They are
issued per request and never logged by the relay.

## Where the policy comes from

`routing.domains` is generated from the same parsed policy that produces Squid's
ACLs:

```text
allowed-domains.txt ─┐
                     ├─► parse & validate ─┬─► squid-allow.conf  (enforced)
destination-policy.conf ┘                   └─► routing.domains  (published)
```

There is no second list. After `-policy-apply`, both change in the same
operation; if validation fails, neither changes.

The endpoint prefers the applied-policy snapshot (`policy.json`) and only reads
the policy files directly when no snapshot exists yet. Editing the files without
applying them therefore does **not** change what clients are told.

## Errors

| Status | Body | When |
|---|---|---|
| `200` | Full document | Everything is available. A `200` is always complete. |
| `503` | `{"error":"destination policy unavailable"}` | The policy is missing, invalid, or the snapshot has an unsupported schema. |
| `503` | `{"error":"proxy configuration unavailable"}` | `HTTPS_PROXY_URL` cannot be described exactly. |
| `503` | `{"error":"turn configuration unavailable"}` | The TURN secret is missing, too short, or unreadable. |
| `405` | `{"error":"method not allowed"}` | Anything but `GET`/`HEAD`. |
| `429` | `{"error":"too many requests …"}` | Rate limit hit. |

Clients should treat any non-`200` as "keep the configuration you already have and
retry later". A failed response never contains partial routing data, so falling
back to an empty list is never correct — it would silently stop proxying.

## Caching

`Cache-Control: no-store, no-cache, must-revalidate, max-age=0`. Policy changes
are visible on the next request; there is no TTL to wait out and no CDN in front
of it. If you put a reverse proxy in front anyway, do not cache this path.

## Using it in Pishcord

**Settings → Custom Profile → add server**, then paste:

```text
https://relay.example.com:8443/network-config
```

Save and select the profile. Pishcord fetches the document and configures its
proxy and TURN settings from it. No other value is typed in, and no relay-specific
Pishcord build is needed.

## Checking it yourself

```bash
curl -sS https://relay.example.com:8443/network-config | python3 -m json.tool
curl -sSI https://relay.example.com:8443/network-config | grep -i cache-control
sudo pishcord-relay network
```
