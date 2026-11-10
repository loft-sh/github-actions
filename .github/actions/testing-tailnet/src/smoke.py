"""Expose a short-lived marker on the runner's tailnet IPv4 address."""
import ipaddress
import os
import re
import socket
import sys
import time

PORT = 18070
DURATIONS = {"success": 180, "failure": 180, "cancellation": 900}


def validate(address, run_id, attempt, mode):
    try:
        parsed = ipaddress.ip_address(address)
    except ValueError as exc:
        raise ValueError("invalid IPv4 address") from exc
    if not isinstance(parsed, ipaddress.IPv4Address) or parsed not in ipaddress.ip_network("100.64.0.0/10"):
        raise ValueError("address must be a Tailscale IPv4 address")
    if not re.fullmatch(r"[1-9][0-9]*", run_id) or not re.fullmatch(r"[1-9][0-9]*", attempt):
        raise ValueError("invalid run identity")
    if mode not in DURATIONS:
        raise ValueError("invalid smoke mode")
    return str(parsed), f"run_id={run_id} run_attempt={attempt}\n"


def serve(address, run_id, attempt, mode, *, clock=time.monotonic, server_factory=socket.socket):
    address, marker = validate(address, run_id, attempt, mode)
    with server_factory(socket.AF_INET, socket.SOCK_STREAM) as server:
        server.bind((address, PORT))
        server.listen(5)
        deadline = clock() + DURATIONS[mode]
        print(f"Smoke endpoint {address}:{PORT} {marker.strip()}", flush=True)
        while (remaining := deadline - clock()) > 0:
            server.settimeout(min(remaining, 1))
            try:
                conn, _ = server.accept()
            except socket.timeout:
                continue
            with conn:
                conn.sendall(marker.encode("ascii"))
    return 1 if mode == "failure" else 0


def main():
    try:
        return serve(os.environ["TAILNET_IPV4"], os.environ["GITHUB_RUN_ID"], os.environ["GITHUB_RUN_ATTEMPT"], os.environ["SMOKE_MODE"])
    except (KeyError, ValueError, OSError) as exc:
        print(f"Smoke endpoint failed: {type(exc).__name__}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
