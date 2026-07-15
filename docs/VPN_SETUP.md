# VPN Setup (WireGuard / wg-easy)

The WireGuard tunnel is the only path to everything documented in `SECURITY.md`'s "VPN-gated MCP engine" — Grafana, the MCP gateway, all of it. This doc covers adding a device (peer) to it.

**Before first use:** `WG_HOST` must be set in `.env` to this VPS's public IP or DNS name — `step_install_wireguard` refuses to proceed (returns exit 75, retries on the next `install.sh` run) until it's set. See `.env.example`.

## Adding a device peer

`wg-easy` ships an admin web UI for peer management (this is why it was chosen over the bare `linuxserver/wireguard` image, which expects hand-authored peer config files — see `docs/OSS_EVALUATION.md`). The UI itself is reachable only through the VPN's own trust chain — same reasoning as Grafana in `docs/OBSERVABILITY.md`.

1. From a device already connected (or via `docker compose exec wireguard <cli, if wg-easy ships one>` as a bootstrap path for the very first peer — chicken-and-egg on the first device, since the UI itself needs the tunnel to reach it. Confirm wg-easy's documented first-peer bootstrap flow before relying on this for a from-scratch install; not independently re-verified this session).
2. Log in with `WG_PASSWORD` (from `.env`).
3. Add a peer, scan the generated QR code or download the `.conf` file for that device.
4. Import it into your device's WireGuard client and connect.

**Needs verification before production use** (flagged honestly rather than guessed): wg-easy v15's exact admin-UI env var name and whether it expects a raw password or a pre-hashed value (`PASSWORD` vs `PASSWORD_HASH` — see `docker-compose.yml`'s comment on the `wireguard` service), and the exact admin-UI port/path. Confirm against `github.com/wg-easy/wg-easy`'s current docs and update this section and `docker-compose.yml` together once confirmed.

## Verifying a connection

From the connected device:

```bash
# Should show a recent handshake once connected
wg show
```

From the VPS, `./verify.sh` includes a `WireGuard` check (container running) but does not currently verify an actual peer handshake — that's a manual check via the client above.

## Removing a peer

Same admin UI — revoke the peer, which immediately invalidates its config (no separate token/secret to rotate for that device alone).
