# Observability

cAdvisor + Prometheus + Grafana, deployed by `step_install_observability` / `step_deploy_docker_stack`, all on `forgeops_internal` with no public route by default. See `SECURITY.md`'s "VPN-gated MCP engine" for the access model — everything here is reachable only via WireGuard.

## What each piece does

- **cAdvisor** (`gcr.io/cadvisor/cadvisor:v0.60.5`) — per-container CPU/memory/disk/network metrics, scraped by Prometheus. Runs non-privileged with a reduced capability set (`SYS_PTRACE`, `DAC_READ_SEARCH` instead of `privileged: true`) — see `SECURITY.md`'s "Known gaps" if a metric looks missing in Grafana.
- **Prometheus** (`prom/prometheus:v3.13.1`) — scrapes cAdvisor per `configs/prometheus/prometheus.yml` (committed, not templated — Compose service-name DNS means no host/IP hardcoding is needed). Data persists in the `forgeops_prometheus_data` volume.
- **Grafana** (`grafana/grafana:13.1.0`) — Prometheus is auto-provisioned as its default datasource via `configs/grafana/provisioning/datasources/prometheus.yml`. Admin password reuses `WG_PASSWORD` from `.env`. **This reuse is only safe under the default `EXPOSE_GRAFANA=false`** (same trust boundary as the VPN — both are reachable only through the same tunnel). If you flip `EXPOSE_GRAFANA=true`, that equivalence breaks: Grafana becomes reachable from the public internet while wg-easy's own admin UI stays VPN-only, so a public Grafana login is now guessable/brute-forceable using the same password that unlocks WireGuard peer management. Set a dedicated `GF_SECURITY_ADMIN_PASSWORD` (not `WG_PASSWORD`) before or as part of enabling public exposure — do not reuse the VPN password once Grafana is public.

## Accessing Grafana

Connect through the VPN (see `docs/VPN_SETUP.md`), then browse to `http://<forgeops_grafana container IP or service name>:3000` from a VPN-connected device, or `docker compose exec` in for a quick local check. There is no public Caddy route by default (`EXPOSE_GRAFANA=false`) — flip that flag and re-run `install.sh`/`update.sh` only if you've deliberately decided to accept that exposure; it is not part of the documented workflow.

## Adding more scrape targets

Edit `configs/prometheus/prometheus.yml`, add a `job_name` block pointing at the new service's Compose DNS name and port, then `docker compose restart prometheus` (or re-run `install.sh`, which calls `step_deploy_docker_stack`). No rendering step involved — this file is read directly, unlike `docker/Caddyfile`.
