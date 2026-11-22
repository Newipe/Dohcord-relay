# Troubleshooting

Start here:

```bash
sudo dohcord-relay diagnostics
curl -sS https://relay.example.com:8443/network-config | python3 -m json.tool
```

`diagnostics` checks the policy, file permissions, the three units, the endpoint,
the certificate and the firewall, and prints exactly what is broken. `repair` fixes
permissions, recreates missing directories and restarts stopped units, asking
first.

## Installation

| Symptom | Cause | Fix |
|---|---|---|
| `unsupported distribution` | Not Debian/Ubuntu | Use Debian 12+ or Ubuntu 22.04+. Nothing was changed. |
| `port(s) … already in use` | nginx/Apache/another proxy holds 80 or 443 | Stop or reconfigure it. The installer never takes over a running web server. |
| `has no A record` / `resolves to …, which is not …` | DNS not pointing at this server | Fix the A record, wait for propagation, re-run. |
| `has an AAAA record … but this host has no global IPv6` | Clients would prefer an unusable IPv6 route | Remove the AAAA record, or enable IPv6 on the server. |
| `cannot detect the public IPv4 address` | No outbound access to the detection service | Pass `--ip ADDRESS`. |
| `Squid rejected the generated policy` | The bundled policy or your edits did not validate | Run `-policy-check`; the message names the file and line. |
| `curl: (7) Failed to connect` during bootstrap | No outbound HTTPS to github.com | Check DNS/proxy; set `https_proxy` if needed. |
| Installer stops mid-way | A command failed | Re-run the same command. Completed steps are idempotent; configuration and certificates are kept. |

To look at what the installer saw: re-run with `TELEMETRY`-free plain output by
setting `NO_COLOR=1`; the step list shows how far it got.

## Certificates

### HTTP-01 validation failed

`certbot` reports `unauthorized`, `connection refused`, `timeout` or `Invalid
response from http://…/.well-known/acme-challenge/…`.

Check, in order:

```bash
curl -I http://relay.example.com/.well-known/acme-challenge/test   # from outside
sudo ss -Hltnp 'sport = :80'                                        # who listens
sudo dohcord-relay services status
```

- Port 80 must be open in the host firewall **and** the cloud security group.
- The A record must still resolve to this server.
- No other web server may hold port 80 — the installer stops if one does.

The existing certificate is never deleted on failure; it keeps being served.

### Let's Encrypt rate limits

`too many certificates`, `too many failed authorizations`, `rateLimited`, or a
`Retry after` value.

- The existing certificate is kept and stays in service.
- Do not retry in a loop; limits reset over hours to a week.
- Use `--staging` for testing so you never consume production limits.
- Details: <https://letsencrypt.org/docs/rate-limits/>

### Certificate exists but clients reject it

```bash
openssl x509 -in /etc/dohcord-relay/tls/fullchain.pem -noout -subject -issuer -dates
openssl s_client -connect relay.example.com:443 -servername relay.example.com </dev/null 2>/dev/null | grep -E '^ *[0-9]+ s:'
```

- Fewer than two `s:` lines means only the leaf was sent. The relay requires the
  OpenSSL build of Squid precisely so the intermediate is sent; re-run the
  installer if the package was replaced.
- A staging certificate is valid but untrusted. Re-run without `--staging`.

## Proxy

| Symptom | Meaning |
|---|---|
| `CONNECT tunnel failed, response 403` | Denied by policy: the host is not listed, or that port is not allowed for it |
| `CONNECT tunnel failed, response 503` | The proxy is up but cannot reach the destination (DNS or outbound failure) |
| `empty reply from server` on the proxy port | Nothing is listening; check `dohcord-relay-squid` |
| TLS handshake errors to a random host | Expected: only policy destinations are reachable |

```bash
sudo dohcord-relay policy show
sudo dohcord-relay services status
sudo tail -f /var/log/dohcord-relay/squid/cache.log
grep TCP_DENIED /var/log/dohcord-relay/squid/access.log | tail
```

### Squid will not start

```bash
sudo dohcord-relay policy check          # policy files valid?
sudo dohcord-relay services validate dohcord-relay-squid.service
sudo journalctl -u dohcord-relay-squid -n 50 --no-pager
```

Almost always a policy or certificate problem:

- `squid.pem` missing → the deploy hook has not run; re-run the installer.
- `FATAL: … dstdomain` → an allowlist entry is malformed; `-policy-check` says where.
- `Address already in use` → something else holds 443; the installer refuses to
  take over an existing listener, so stop it first.

## TURN and voice

Voice connects but nobody hears anyone, or voice does not connect at all:

1. `sudo dohcord-relay services status` — is `dohcord-relay-coturn` running?
2. Open `3478/udp`, `5349/tcp` and `49152-65535/udp` in the host firewall and the
   cloud security group. The relay range is mandatory; TURN cannot fall back.
3. Check the realm and the secret:

   ```bash
   sudo grep -E '^(realm|listening-port|tls-listening-port|min-port|max-port)' /etc/dohcord-relay/turnserver.conf
   sudo ls -l /etc/dohcord-relay/turn-secret
   ```

4. `curl -sS https://relay.example.com:8443/network-config | python3 -m json.tool`
   — the credential must be present and `expiresAt` in the future.
5. A clock skew of more than the credential TTL invalidates credentials. Check
   `timedatectl`.

`401 Unauthorized` from coturn means the secret the API signs with and the one
coturn reads differ. They are the same file; re-run the installer to re-render
`turnserver.conf`.

## Network Configuration API

| Symptom | Cause |
|---|---|
| `connection refused` on 8443 | `dohcord-relay-api` is down, or the port is closed |
| `connection refused` after changing the API port | The Dohcord profile still names the old port; run `sudo dohcord-relay diagnostics` and update the profile to the configured port |
| `502`/`504` from a reverse proxy in front | You have something in front of it; the API expects to be reached directly |
| `503 destination policy unavailable` | No valid policy/snapshot; run `-policy-check` |
| `503 turn configuration unavailable` | `turn-secret` missing or shorter than 16 bytes |
| `429` | Rate limited; wait a few seconds |
| Clients get old data | A caching proxy in front of 8443 — the API itself sends `no-store` |

```bash
sudo journalctl -u dohcord-relay-api -n 50 --no-pager
sudo dohcord-relay services validate dohcord-relay-api.service
```

## Updates

| Symptom | Cause |
|---|---|
| `cannot download …` during install or update | github.com is unreachable, or the tag does not exist; nothing was replaced |
| `SHA256 verification failed` | The archive does not match the release checksums; the installed binaries were kept |
| `unsupported architecture` | Releases exist for linux/amd64 and linux/arm64 only |
| Service does not start after an update | The updater restores the previous executables automatically; check `journalctl -u dohcord-relay-api` |

```bash
sudo dohcord-relay update        # latest, or enter a specific vX.Y.Z
sudo dohcord-relay dashboard     # installed release and service state
```

## Firewall

```bash
sudo dohcord-relay firewall
sudo dohcord-relay diagnostics
sudo ufw status numbered
```

`diagnostics` prints the configured API port, the listen address, whether the
port is listening (or free, or taken by another process), whether the firewall
allows it, and whether the endpoint answers.

Required inbound: `80/tcp`, `443/tcp`, `8443/tcp` (or the configured API port),
`3478/udp`, `5349/tcp`, `49152-65535/udp`. A cloud security group (EC2, Hetzner, OVH, GCP) is separate
from the host firewall; the installer cannot open it for you.

Do not close SSH while editing rules:

```bash
sudo ufw allow 22/tcp     # adjust if sshd uses another port
```

## systemd

```bash
systemctl status dohcord-relay-api dohcord-relay-squid dohcord-relay-coturn
journalctl -u dohcord-relay-squid -n 100 --no-pager
systemd-analyze verify dohcord-relay-api.service
```

| State | Meaning |
|---|---|
| `activating (auto-restart)` | Crashing repeatedly; read the journal |
| `failed (Result: exit-code)` | The process exited non-zero; the journal has the reason |
| `inactive (dead)` after enable | Not started; `systemctl start` it |

Do not touch the distribution's `squid.service`; the relay runs
`dohcord-relay-squid.service` with its own configuration.

## Permissions

Symptoms: `permission denied` in logs, services unable to read the key or secret.

```bash
sudo ls -l /etc/dohcord-relay /etc/dohcord-relay/tls
```

Expected: `config.env`, `turnserver.conf`, `turn-secret`, `privkey.pem`,
`squid.pem` are `0640 root:dohcord-relay`; `fullchain.pem` is `0644`;
`turnserver` is a member of the `dohcord-relay` group.

```bash
sudo dohcord-relay repair
```

fixes these modes individually after asking.

## Collecting a report

```bash
sudo dohcord-relay dashboard
sudo dohcord-relay diagnostics
sudo bash /usr/local/lib/dohcord-relay/verify.sh
sudo journalctl -u dohcord-relay-api -u dohcord-relay-squid -u dohcord-relay-coturn --since '1 hour ago' --no-pager
```

Do not paste `/etc/dohcord-relay/turn-secret` or `tls/privkey.pem` into an issue.

## Bandwidth limits are not being enforced

`dohcord-relay diagnostics`, `verify.sh` and `dohcord-relay-tc status` all report
this explicitly; a configured limit that is not active is a failure, never a
success.

```bash
sudo dohcord-relay-tc status
sudo systemctl status dohcord-relay-tc.service
sudo journalctl -u dohcord-relay-tc -n 50 --no-pager
```

| Symptom | Cause and fix |
|---|---|
| `shaping=inactive`, log says the root qdisc is not managed | The interface already carries an administrator's qdisc (`cake`, `tbf`, a foreign `htb`, …). The relay refuses to overwrite it: remove it, or set `TC_INTERFACE` to an interface whose root qdisc is a kernel default (`mq`, `fq_codel`, `pfifo_fast`), then `sudo dohcord-relay-tc apply` |
| `egress_qdisc=mq` in `status` | The interface is multiqueue (common on AWS ENA and 10G+ NICs) and its default `mq` root is still in place: the `dohcord-relay-tc` service failed to start. Run `sudo journalctl -u dohcord-relay-tc -n 30` for the reason, fix it, then `sudo systemctl restart dohcord-relay-tc` |
| `tc is not installed` | `sudo apt-get install iproute2` |
| `no network interface detected` | Set `TC_INTERFACE` in `/etc/dohcord-relay/config.env` (the default route could not be read) |
| `ingress_qdisc=missing` | Upload shaping needs the `ifb` kernel module: `sudo modprobe ifb`, then restart `dohcord-relay-tc`. The installer loads it and records it in `/etc/modules-load.d/dohcord-relay-ifb.conf`; the service itself cannot autoload modules |
| `shaped_addresses=0` | No client has its own class yet; traffic is still limited by the service's fallback class, and the table fills within `TC_REFRESH_SECONDS` (up to 30 s for TURN) |
| `missing_filter=…` or `missing_fallback_filter=…` | The class exists but the `u32` filter that steers traffic into it does not, so that traffic is unshaped. The kernel refused the filter (often a kernel without `cls_u32`): `sudo journalctl -u dohcord-relay-tc -n 30` then `sudo dohcord-relay-tc apply` |
| A client is not limited | It may be above `TC_MAX_CLIENTS`; the shaper logs which address was skipped and diagnostics reports it. Raise the limit or reduce concurrent addresses |
| New connections share one allowance briefly | Expected: an address without its own class uses its service's fallback class (same rate as the per-IP limit) until the next refresh, so several new addresses share one allowance for at most `TC_REFRESH_SECONDS` (5 s by default; up to 30 s for TURN). Lower it for a tighter bound |
| `dohcord-relay-tc` shows noticeable CPU | A refresh reads one socket table per service, so its cost grows with the number of sockets on the host, not with the number of shaped clients. `ss -s` shows that count; coturn's socket table is read at most every 30 s for the same reason |
| Rates look different from the configuration | `sudo dohcord-relay-tc apply` re-applies the current `config.env`; `status` prints any `rate_mismatch` |

The shaper only ever deletes its own qdisc handles (`1:` on the interface,
`2:` on the IFB device, the `ffff:` ingress hook and the IFB device itself).
`dohcord-relay-tc stop` removes them and restores the root qdisc kind that was
there before.

## Profiles load slowly or are rate limited

A profile load is one `GET /network-config`; it should take milliseconds.

```bash
curl -sS -o /dev/null -w '%{http_code} %{time_total}s
' "$(sed -n 's/^NETWORK_CONFIG_URL=//p' /etc/dohcord-relay/config.env)"
sudo journalctl -u dohcord-relay-api --since '-1 hour' | grep -c 'rate limited'
```

- `429` with a `Retry-After` header means the burst was genuinely exhausted:
  raise `PER_IP_BURST` (default 30) or `PER_IP_RATE_PER_MINUTE` (default 60) with
  `sudo dohcord-relay limits` (**Limits & performance**), then reload/restart.
- No `429` at all means the limit was never the problem; check the endpoint's
  latency and the API unit's log.
- A `503` is a configuration problem (policy or TURN secret), not a limit.
