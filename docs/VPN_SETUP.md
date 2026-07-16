# VPN Setup (WireGuard / wg-easy)

The WireGuard tunnel is the only path to everything documented in `SECURITY.md`'s "VPN-gated MCP engine" — Grafana, the MCP gateway, all of it. This doc covers adding a device (peer) to it.

**Before first use:** `WG_HOST` must be set in `.env` to this VPS's public IP or DNS name — `step_install_wireguard` refuses to proceed (returns exit 75, retries on the next `install.sh` run) until it's set. See `.env.example`.

## Adding a device peer

`wg-easy` ships an admin web UI for peer management (this is why it was chosen over the bare `linuxserver/wireguard` image, which expects hand-authored peer config files — see `docs/OSS_EVALUATION.md`). Once at least one peer exists and is connected, the UI is reachable only through the VPN's own trust chain — same reasoning as Grafana in `docs/OBSERVABILITY.md`.

**Confirmed against wg-easy's own v15 docs (see commit message for source URLs): there is no CLI or pre-authenticated API for creating a peer.** Its `/api` requires the same admin login as the web UI, so it can't bootstrap a session that doesn't exist yet. That makes the very first peer a genuine chicken-and-egg problem: the only way to create it is through a UI that, by this stack's design, isn't reachable until a tunnel already exists. There's no way around this — the practical fix is a one-time manual bootstrap:

1. **First time only.** Temporarily publish the admin UI's port (`51821/tcp` by default) to the VPS's loopback interface — add `- "127.0.0.1:51821:51821/tcp"` to the `wireguard` service's `ports:` in `docker-compose.yml`, then `docker compose up -d wireguard`. From your workstation, open an SSH tunnel to that loopback port instead of exposing it publicly: `ssh -L 51821:127.0.0.1:51821 <user>@<vps-host>`. Browse to `http://127.0.0.1:51821` — you're now looking at the admin UI over the SSH-encrypted channel. (wg-easy's UI has no TLS of its own and requires `INSECURE=true` to serve plain HTTP at all; if login fails outright rather than just looking unstyled, add `INSECURE: "true"` to the `wireguard` service's `environment:` for this one bootstrap session and remove it afterward along with the port mapping.)
2. Log in with username `admin` and the password from `WG_PASSWORD` (from `.env`) — these are seeded via `INIT_USERNAME`/`INIT_PASSWORD` on the container's very first boot only; see the comment on the `wireguard` service in `docker-compose.yml`.
3. Add a peer, scan the generated QR code or download the `.conf` file for that device.
4. Import it into your device's WireGuard client and connect — this is now the first working tunnel.
5. Remove the `127.0.0.1:51821:51821/tcp` port mapping (and any temporary `INSECURE` env var) added in step 1, then redeploy (`docker compose up -d wireguard`), so the admin UI goes back to being reachable only through the tunnel, matching this file's stated ports policy above.

Every peer after the first is added the normal way: connect over the existing tunnel, open the admin UI, repeat steps 2-4.

wg-easy v15 confirmed facts (see commit message for source URLs): the v14-era `PASSWORD` / `PASSWORD_HASH` / `WG_HOST` env vars no longer exist in v15. v15 reads admin credentials and host/port exactly once, on the container's very first boot with no existing `/etc/wireguard` config, via `INIT_ENABLED` / `INIT_USERNAME` / `INIT_PASSWORD` / `INIT_HOST` / `INIT_PORT`. After that first boot they're ignored entirely — rotate the admin password from inside the UI, not by editing `.env` and restarting the container.

## Verifying a connection

From the connected device:

```bash
# Should show a recent handshake once connected
wg show
```

From the VPS, `./verify.sh` includes a `WireGuard` check (container running) but does not currently verify an actual peer handshake — that's a manual check via the client above.

## Removing a peer

Same admin UI — revoke the peer, which immediately invalidates its config (no separate token/secret to rotate for that device alone).
