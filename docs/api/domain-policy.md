# Domain policy

Two plain text files decide what the proxy may reach. They are the only
authoritative source: Squid's ACLs and the API's routing rules are both generated
from them.

```text
/etc/dohcord-relay/allowed-domains.txt       which host names
/etc/dohcord-relay/destination-policy.conf   which TCP ports each host may use
```

## allowed-domains.txt

One entry per line. Blank lines and `#` comments are ignored.

```text
# Discord destinations the relay may reach
discord.com
discord.gg
discordapp.com
discordapp.net
discord.media
=discord-attachments-uploads-prd.storage.googleapis.com
```

### Matching

A plain entry allows the host **and its subdomains**, matched on DNS label
boundaries:

| Entry | Requested | Result |
|---|---|---|
| `discord.com` | `discord.com` | allow |
| `discord.com` | `gateway.discord.com` | allow |
| `discord.com` | `notdiscord.com` | deny |
| `discord.com` | `discord.com.evil.example` | deny |
| `discord.com` | `evil-discord.com` | deny |

A leading `=` makes the entry **exact**: that host name and nothing else.

```text
=discord-attachments-uploads-prd.storage.googleapis.com
```

That host is where Discord uploads attachments. It is exact on purpose: on Cloud
Storage every subdomain is a different bucket, so a subdomain-covering entry would
let whoever registers `something.discord-attachments-uploads-prd` receive those
requests. `*.storage.googleapis.com`, `*.googleapis.com` and arbitrary buckets are
denied.

The marker must appear identically in both files. If it appears in one and not the
other, validation fails rather than silently changing the scope.

## destination-policy.conf

One line per host, host first, then a comma-separated port list. Spaces are fine.

```text
discord.com       443
discord.gg        443
discordapp.com    443
discordapp.net    443
discord.media     443,1024-65535
=discord-attachments-uploads-prd.storage.googleapis.com  443
```

- Ports are `1-65535`.
- A range is `LOW-HIGH` with `LOW <= HIGH`; reversed ranges are rejected.
- Every allowlisted host needs a port line, and every port line needs an
  allowlisted host. Gaps in either direction are configuration errors, not
  warnings.
- Only TCP is meaningful here: the proxy speaks CONNECT.

`discord.media`'s `1024-65535` range is the documented dynamic-port behaviour for
voice signalling. Keep it exclusive to `discord.media`; widening it to other
domains opens the proxy for no benefit.

## Adding, changing and removing destinations

### With the management console

```bash
sudo dohcord-relay
# 4. Domain policy → 1. Add a destination
```

The console validates the host name and port list, shows what it will write, backs
up both files to `/var/backups/dohcord-relay/`, edits them, runs the validator, and
restores the backup if the result is rejected. It then offers to apply.

### By hand

```bash
sudoedit /etc/dohcord-relay/allowed-domains.txt
sudoedit /etc/dohcord-relay/destination-policy.conf

sudo dohcord-relayd -config /etc/dohcord-relay/config.env -policy-check   # validate
sudo dohcord-relayd -config /etc/dohcord-relay/config.env -policy-apply   # validate + apply
```

To remove a destination, delete its line from both files. To change ports, edit
the single port line; the published `from`/`to` values follow the file.

### What apply does

1. parses and cross-validates both files (syntax, no IP literals, no wildcards,
   numeric ports, no duplicates or overlaps, full coverage);
2. renders `/etc/dohcord-relay/squid-allow.conf`;
3. validates the **whole** Squid configuration with `squid -k parse`;
4. only if that passes: installs the ACLs, writes `policy.json`, reloads Squid.

If any step fails, nothing is installed and Squid keeps enforcing the previous
policy. The API keeps serving the previous snapshot too, so a client is never told
about a destination that is not actually enforced.

## What gets generated

```squid
acl dohcord_domain_0 dstdomain .discord.com
acl dohcord_ports_0 port 443
acl dohcord_domain_6 dstdomain discord-attachments-uploads-prd.storage.googleapis.com
acl dohcord_ports_6 port 443
```

- `suffix` entries become `.host` (host plus subdomains).
- `exact` entries become `host` (no leading dot).
- The include is referenced from `squid.conf` by
  `include /etc/dohcord-relay/squid-allow.conf`; `-policy-apply` refuses to
  install ACLs into a configuration that does not include them.

## Safety rules

- **Never add broad shared namespaces** such as `googleapis.com` or `cloudfront.net`.
- **Prefer exact entries** for anything where a subdomain belongs to a third party.
- **Prefer fewer destinations**; each one is reachable by anyone who knows your
  relay address.
- **Do not add IP literals.** Host names only; IP-literal CONNECTs are denied
  regardless.
- A destination that resolves to a private, loopback, link-local, CGNAT,
  documentation or multicast address is refused after resolution, so an
  allowlisted name cannot be pointed at your internal network.

## Verifying the result

```bash
sudo dohcord-relay policy show          # matches the files
sudo dohcord-relay network              # policy valid + document
sudo bash /usr/local/lib/dohcord-relay/verify.sh
```

`verify.sh` re-checks the generated ACLs against both files, confirms the API
document agrees, and probes the proxy with allowed and denied destinations.
