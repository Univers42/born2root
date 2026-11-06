# 0001 — The VM wall lets the guest reach the host's own tailscaled over UDP

Status: accepted, 2026-11-06 (devil verdict PROCEED-WITH-CONDITIONS, W1–W12).

## Context

`setup/host/vm_wall.sh` refuses every new connection from the VM unit's cgroup
to any address of the host, except DNS and the listed TCP ports. That also
refused the guest tailscaled's UDP to the host tailscaled. The two tailnet
nodes on this one machine could therefore only talk through a DERP relay on
the internet (Madrid), crossing the host NIC twice. Every DERP stall cut the
browser, the websockets and the bridge at the same time. Evidence: the wall's
reject counter stood at 14046. The host journal showed
`open-conn-track: timeout opening (TCP 100.94.109.44:… => 100.97.49.118:443)`
at the same seconds as the path-probe failures on 2026-11-06.

## Decision

`apply` adds one rule: `udp dport { N } fib daddr type local accept`. N is the
port the **main process of `tailscaled.service`** holds on a wildcard address.
If that process was started with `--port=N`, N is used exactly, and only if
the process holds it.

- No process name is matched. osionos-apps runs a second, userspace
  `tailscaled` on random ports (`--port=0`), and that one stays walled.
- No address is pinned. Every local address reaches the same wildcard socket,
  and pinning the LAN address would break on a NIC flap or a DHCP change.
- If no port is found there is no rule, and stderr says the VM falls back to
  DERP.

## Consequences

- Only the transport changes. Tailscale's packet filter applies after
  decryption, so the guest reaches nothing the tailnet did not already route
  to it. Raw UDP to the socket needs a known WireGuard key, or a sealed disco
  message, to do anything.
- The port is read once, at apply time. A tailscaled that moves port, or
  starts after the VM, stays walled until the VM's next start: DERP again,
  slower, not broken.
- The second daemon's ports need their own ruling if they are ever opened
  (W12).

## Rejected

- Pinning the destination address (192.168.1.131): fragile, see above.
- A flag: the change is visible in the apply line and the journal, so it is
  default-on.
- Matching `tailscaled` by name: it opens the second daemon's random ports,
  and any process can call itself `tailscaled`.
