# Device Health Neon-ready scaffold

This package adds a Node HTTP ingestion API, database-backed report query, and a buildable static dashboard to the original Windows/macOS collectors. The dashboard remains local-import mode until its authenticated live fetch is wired. **Not deployed**.

## Neon setup (run on a network-enabled workstation)

```sh
npm i -g neon@latest # or npx neon@latest
neon login
neon init -y --org-id org-white-surf-95076564 --project-id divine-band-50879011 --branch production --services postgres,auth
neon deploy
npm install
npm run build
npm start
```

Apply `NEONDB_SCHEMA.sql` in the Neon SQL editor or with your database migration runner. Neon Auth must be configured and integrated before exposing the fleet dashboard to users. The server currently requires a shared ingestion token for both `/api/ingest` and `/api/reports`; it is **not suitable for a public multi-user deployment** until per-device tokens and Neon Auth session verification are implemented. Never expose DATABASE_URL or tokens in browser code.

Collectors can upload to `https://your-host/api/ingest` by setting `DEVICE_HEALTH_API_URL` and `DEVICE_HEALTH_API_TOKEN`. No network upload happens by default. The collector reports and local HTML dashboard remain usable offline.

## Verification
`npm run build` verifies dashboard assets. `GET /api/health` tests server liveness, not database connectivity. Authenticated POST `/api/ingest` and GET `/api/reports` require a provisioned database and applied schema. A real Neon Auth session flow is not implemented.


## Battery and overall rating (v3)
TXT summaries include the capacity ratio, calculated battery health, cycle count and category, recommendation, and reasons for the overall rating. Cycle categories assume a **1,000-cycle** battery life (low <300, medium 300–699, high 700–999, limit reached >=1000); this is an IT triage default, not a verified manufacturer limit. Device-specific limits and reported service condition should be checked before recommending replacement. The overall rating is critical when any of CPU, RAM, storage or battery is critical; it is not driven by age or cycles alone. Mac capacity figures in the TXT ratio are raw values with potentially differing units; only compare figures returned in the same unit by the same device.

### Windows battery capacity fix (v5)
The Windows collector generates the official `powercfg /batteryreport` HTML **before** producing JSON/TXT ratings. It reads `DESIGN CAPACITY`, `FULL CHARGE CAPACITY` and (if available) `CYCLE COUNT` from the report when WMI does not supply them. Capacity values in the report are in mWh. Battery health is calculated from the two capacity measurements; if either is missing, health remains unknown. This change is not yet tested on Windows hardware.

### RAM process investigation (v6)
Both launchers now generate `health_<hostname>_<timestamp>_ram.txt` in `Desktop/DeviceHealthReports` alongside the main TXT, battery report and JSON. It lists up to 15 process-name groups ranked by resident memory and their instance counts. Windows JSON also stores `processes.memory_groups` and `memory_top5_working_set_mb`; macOS JSON stores `processes.memory_groups`. No extra installation is required. These values are point-in-time resident working sets, not proof of a leak or an exact breakdown of system RAM. macOS total RAM utilisation remains unknown; Activity Monitor memory pressure is the recommended diagnostic. Some protected processes may not expose full metrics. Run while the user is experiencing slowness for the most useful snapshot.

## Web dashboard v7
Start with `npm run build && npm start`, then open `http://localhost:3000`.
Use **Connect to server** to enter `DEVICE_HEALTH_API_TOKEN` (held in tab memory), then **Sync now** to load reports from the PostgreSQL-backed API. Imported JSON files are also sent to the API when connected. The Device Details panel includes a RAM investigation ranking of up to 15 process groups. Reports remain available locally when disconnected.

**Neon setup:** Configure `DATABASE_URL` and `DEVICE_HEALTH_API_TOKEN` on the server, apply `NEONDB_SCHEMA.sql` to your Neon production branch, and deploy the Node server to a trusted HTTPS host. Do not put `DATABASE_URL` into browser code or distribute the shared API token to end users. The token-based UI is an internal prototype, **not production user authentication**. Neon Auth and per-user permissions still need implementation before broad rollout. Windows/Mac collectors currently create local files; they do not automatically upload unless explicitly configured.
