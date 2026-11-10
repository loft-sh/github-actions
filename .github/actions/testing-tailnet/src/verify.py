"""Verify the joined node before exposing its address to later steps."""
import ipaddress
import json
import os
import subprocess
import sys


def verify(status, expected_tailnet):
    if not isinstance(status, dict) or status.get("BackendState") != "Running":
        raise ValueError("Tailscale backend is not running")
    tailnet = status.get("CurrentTailnet")
    node = status.get("Self")
    if not isinstance(tailnet, dict) or tailnet.get("MagicDNSSuffix") != expected_tailnet:
        raise ValueError("unexpected tailnet")
    if not isinstance(node, dict) or node.get("Tags") != ["tag:e2e-github-runner"]:
        raise ValueError("unexpected node tags")
    node_id = node.get("ID")
    if not isinstance(node_id, str) or not node_id or any(c in node_id for c in "\r\n"):
        raise ValueError("missing or invalid node ID")
    addresses = node.get("TailscaleIPs")
    if not isinstance(addresses, list):
        raise ValueError("missing node addresses")
    for address in addresses:
        try:
            parsed = ipaddress.ip_address(address)
            if isinstance(parsed, ipaddress.IPv4Address):
                return str(parsed), node_id
        except ValueError:
            continue
    raise ValueError("missing IPv4 address")


def main():
    try:
        result = subprocess.run(["tailscale", "status", "--json"], check=True, capture_output=True, text=True)
        ipv4, node_id = verify(json.loads(result.stdout), os.environ["INPUT_EXPECTED_TAILNET"])
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
            output.write(f"ipv4={ipv4}\nnode-id={node_id}\n")
    except (ValueError, TypeError, KeyError, OSError, subprocess.CalledProcessError) as exc:
        print(f"Tailnet verification failed: {type(exc).__name__}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
