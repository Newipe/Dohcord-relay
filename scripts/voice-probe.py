#!/usr/bin/env python3
"""Voice-like traffic probe for the Pishcord-relay bandwidth limiter.

Sends small UDP datagrams at a fixed packet rate, has them echoed back and
reports round-trip latency percentiles, jitter and loss. A second process can
saturate the same shaper class with bulk UDP so the probe measures what a voice
call experiences while somebody screen-shares.

Two subcommands:

  echo  --port PORT                 echo everything received back to the sender
  send  --target HOST:PORT [...]    measure a voice-like stream against it
  flood --target HOST:PORT [...]    bulk UDP load, no measurement

Typical use (see scripts/bench-voice-qos.sh, which wires up netns + tc):

  python3 voice-probe.py echo --port 3478 &
  python3 voice-probe.py flood --target 10.99.0.1:3478 --mbps 30 &
  python3 voice-probe.py send  --target 10.99.0.1:3478 --seconds 20

The printed report is one JSON object per run plus a human summary, so a
before/after comparison can be kept in a file. Latency is measured as the
round trip of a packet that carries its own send timestamp, which is what the
shaper can influence; it is not a one-way delay estimate.
"""

import argparse
import json
import random
import socket
import struct
import sys
import time

MAGIC = b"PSV1"
HEADER = struct.Struct("!4sdI")  # magic, monotonic send time, sequence


def percentile(sorted_values, fraction):
    if not sorted_values:
        return 0.0
    index = int(round((len(sorted_values) - 1) * fraction))
    return sorted_values[index]


def summarize(rtts_ms, sent, received, duration_s, baseline_ms):
    ordered = sorted(rtts_ms)
    if not ordered:
        return {
            "sent": sent,
            "received": 0,
            "loss_pct": 100.0,
            "duration_s": round(duration_s, 3),
        }
    jitter = 0.0
    if len(rtts_ms) > 1:
        jitter = sum(abs(b - a) for a, b in zip(rtts_ms, rtts_ms[1:])) / (len(rtts_ms) - 1)
    p50 = percentile(ordered, 0.50)
    p95 = percentile(ordered, 0.95)
    p99 = percentile(ordered, 0.99)
    return {
        "sent": sent,
        "received": received,
        "loss_pct": round(100.0 * (sent - received) / sent, 2) if sent else 0.0,
        "duration_s": round(duration_s, 3),
        "rtt_ms": {
            "min": round(ordered[0], 2),
            "p50": round(p50, 2),
            "p95": round(p95, 2),
            "p99": round(p99, 2),
            "max": round(ordered[-1], 2),
        },
        "added_p50_ms": round(max(0.0, p50 - baseline_ms), 2),
        "added_p95_ms": round(max(0.0, p95 - baseline_ms), 2),
        "added_p99_ms": round(max(0.0, p99 - baseline_ms), 2),
        "jitter_ms": round(jitter, 2),
    }


def do_echo(port, bind):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((bind, port))
    sys.stderr.write("echo on udp/%d\n" % port)
    sys.stderr.flush()
    while True:
        try:
            data, addr = sock.recvfrom(65535)
        except KeyboardInterrupt:
            return 0
        except OSError:
            continue
        try:
            sock.sendto(data, addr)
        except OSError:
            pass


def do_send(args):
    target = args.target.rsplit(":", 1)
    address = (target[0], int(target[1]))
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("0.0.0.0", 0))
    sock.settimeout(1.0)

    payload_pad = max(0, args.bytes - HEADER.size)
    interval = 1.0 / args.pps
    total = int(round(args.pps * args.seconds))
    rtts = []
    sent = 0
    received = 0
    # A short warm-up keeps the first measurement from being a cold-path outlier.
    for _ in range(args.warmup):
        sock.sendto(HEADER.pack(MAGIC, time.monotonic(), 0) + b"\0" * payload_pad, address)
        try:
            sock.recvfrom(65535)
        except (socket.timeout, OSError):
            pass

    start = time.monotonic()
    next_send = start
    deadline = start + args.seconds
    while time.monotonic() < deadline:
        now = time.monotonic()
        if now < next_send:
            time.sleep(next_send - now)
        seq = random.randint(1, 2**31 - 1)
        packet = HEADER.pack(MAGIC, time.monotonic(), seq) + b"\0" * payload_pad
        try:
            sock.sendto(packet, address)
            sent += 1
        except OSError:
            pass
        next_send += interval
        # Drain whatever came back since the last send. Waiting for the echo of
        # this exact packet would serialize the stream; matching on any reply is
        # enough because the stream is one packet per interval.
        drain_until = time.monotonic() + interval
        while True:
            remaining = drain_until - time.monotonic()
            if remaining <= 0:
                break
            sock.settimeout(remaining)
            try:
                data, _ = sock.recvfrom(65535)
            except (socket.timeout, OSError):
                break
            if len(data) >= HEADER.size and data[:4] == MAGIC:
                _, sent_at, _ = HEADER.unpack(data[: HEADER.size])
                rtts.append((time.monotonic() - sent_at) * 1000.0)
                received += 1

    elapsed = time.monotonic() - start
    report = summarize(rtts, sent, received, elapsed, args.baseline_ms)
    print(json.dumps(report))
    if received:
        print(
            "voice p50 {p50:.1f} ms  p95 {p95:.1f} ms  p99 {p99:.1f} ms  "
            "jitter {jitter:.1f} ms  loss {loss:.2f}%".format(
                p50=report["rtt_ms"]["p50"],
                p95=report["rtt_ms"]["p95"],
                p99=report["rtt_ms"]["p99"],
                jitter=report["jitter_ms"],
                loss=report["loss_pct"],
            )
        )
    else:
        print("voice: no replies (%d sent)" % sent)
    return 0


def do_flood(args):
    target = args.target.rsplit(":", 1)
    address = (target[0], int(target[1]))
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("0.0.0.0", 0))
    size = args.bytes
    rate = args.mbps * 1000 * 1000 / 8.0
    chunk = 50  # packets per burst
    burst_bytes = chunk * size
    burst_interval = burst_bytes / rate
    deadline = time.monotonic() + args.seconds
    sent = 0
    while time.monotonic() < deadline:
        for _ in range(chunk):
            try:
                sock.sendto(b"\0" * size, address)
                sent += 1
            except OSError:
                break
        time.sleep(burst_interval)
    print(json.dumps({"flood_sent": sent, "flood_mbps": args.mbps}))
    return 0


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    echo = sub.add_parser("echo", help="echo received datagrams back")
    echo.add_argument("--port", type=int, required=True)
    echo.add_argument("--bind", default="0.0.0.0", help="local address to listen on")
    echo.add_argument("--seconds", type=float, default=0.0, help=argparse.SUPPRESS)

    send = sub.add_parser("send", help="measure a voice-like stream")
    send.add_argument("--target", required=True)
    send.add_argument("--pps", type=int, default=50)
    send.add_argument("--bytes", type=int, default=180)
    send.add_argument("--seconds", type=float, default=20.0)
    send.add_argument("--warmup", type=int, default=5)
    send.add_argument(
        "--baseline-ms",
        type=float,
        default=0.0,
        help="idle RTT of the same path, subtracted for the added-latency columns",
    )

    flood = sub.add_parser("flood", help="bulk UDP load")
    flood.add_argument("--target", required=True)
    flood.add_argument("--mbps", type=float, default=30.0)
    flood.add_argument("--bytes", type=int, default=1200)
    flood.add_argument("--seconds", type=float, default=20.0)

    args = parser.parse_args(argv)
    if args.command == "echo":
        return do_echo(args.port, args.bind)
    if args.command == "send":
        return do_send(args)
    return do_flood(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
