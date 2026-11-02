---
kind: stage
status: todo
---

# Live checks

## Goal

Prove on a real server and a device that the work done before the map
(stages 1–5) actually works. None of it has been checked live: CI is green,
nothing has run against a tunnel server.

The check list is section 6 of `docs/DOH_DOT_TUN2SOCKS_ARCHITECTURE.md`. Every
failing item becomes a node of this map; the results go to the journal and,
where generally useful, into the stage reports under `docs/` (without
environment, servers, resolvers or addresses).

## What to do, what is touched

- DoH and DoT for DNSTT and for Slipstream, in proxy and VPN mode, on Android
  and on desktop.
- VPN mode with tun2socks: TCP, the fake-IP DNS answers, IPv6, applications
  that need `SRV`/`TXT`/`MX` records.
- Throughput compared with the upstream app; network switch (Wi-Fi ↔ mobile).
- Leak tests: no plain DNS leaves the device, no traffic bypasses the tunnel.
- Upstream SOCKS5 authentication with and without pipelining
  (`Socks5AuthRelay`).
- SSH mode with host key verification.

## Done when

- Every item of the list passed, or is written down as a defect with its own
  node in this map.
- The results are in the journal; the generally useful part is in the stage
  reports.

## Depends on

5 (the release is what gets installed and tested).

## Risks and what is needed from the user

Needs the user's tunnel server, a phone and a desktop; the checks cannot be
delegated to an agent. The user runs the sessions and reports what fails; the
`lead` turns the reports into nodes. The results contain the server, the
resolver and the addresses — the journal outside git, not `docs/`.
