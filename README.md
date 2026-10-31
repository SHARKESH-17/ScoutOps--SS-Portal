# ScoutOps

## Find. Track. Resolve.

> *Every issue has a mission.*

ScoutOps is a campus issue and maintenance management web application with a complete, containerized DevOps lifecycle: GitHub → Jenkins → automated tests → Docker build → deployment → Prometheus/Grafana monitoring and alerting, with database backup and image-based rollback.

ScoutOps is an **original application**. Its "scout / reconnaissance / mission-control" look uses only original UI elements (a compass mark, status indicators, a dark operations dashboard). It contains no third-party characters, artwork, logos or dialogue and is not affiliated with any anime or other franchise.

---

## Table of contents

1. [Project overview](#1-project-overview)
2. [Project objectives](#2-project-objectives)
3. [Architecture](#3-architecture)
4. [Technology stack](#4-technology-stack)
5. [Project structure](#5-project-structure)
6. [Ports, names and conventions](#6-ports-names-and-conventions)
7. [Prerequisites](#7-prerequisites)
8. [Installation on a fresh Ubuntu machine](#8-installation-on-a-fresh-ubuntu-machine)
9. [Clone, environment, run locally](#9-clone-environment-run-locally)
10. [Docker execution](#10-docker-execution)
11. [Testing the application and API reference](#11-testing-the-application-and-api-reference)
12. [Database](#12-database)
13. [Stop / start and data persistence](#13-stop--start-and-data-persistence)
14. [Production deployment](#14-production-deployment)
15. [Backup, rollback and cleanup](#15-backup-rollback-and-cleanup)
16. [Monitoring: Prometheus, Grafana, alerts](#16-monitoring-prometheus-grafana-alerts)
17. [Jenkins and GitHub CI/CD](#17-jenkins-and-github-cicd)
18. [Failure, monitoring and recovery tests](#18-failure-monitoring-and-recovery-tests)
19. [Complete execution procedure (35 steps)](#19-complete-execution-procedure-35-steps)
20. [Troubleshooting](#20-troubleshooting)
21. [Security](#21-security)
22. [License](#22-license)

---

## 1. Project overview

ScoutOps lets students and staff **report campus infrastructure problems** (broken projectors, leaking taps, dead Wi-Fi, damaged furniture, security hardware...) and lets the maintenance team **track, assign, update and resolve** them.

```
Students / Staff -> Report issue -> Issue created (OPEN) -> Maintenance team
                 -> Track / Assign / Update -> Resolve -> Close
```

An issue has: `id`, `title`, `description`, `category`, `location`, `priority`, `status`, `reporter_name`, `created_at`, `updated_at`.

| Field | Allowed values |
|-------|----------------|
| status | `OPEN`, `ASSIGNED`, `IN_PROGRESS`, `RESOLVED`, `CLOSED` |
| priority | `LOW`, `MEDIUM`, `HIGH`, `CRITICAL` |
| category | `ELECTRICAL`, `PLUMBING`, `INTERNET`, `CLEANING`, `FURNITURE`, `EQUIPMENT`, `SECURITY`, `OTHER` |

**How DevOps practices are integrated**

| Practice | Where it lives |
|----------|----------------|
| Version control | Git + GitHub |
| Continuous integration | `Jenkinsfile`: `npm ci`, Jest/Supertest tests on every push |
| Containerization | `Dockerfile`, `docker-compose.yml`, `docker-compose.prod.yml` |
| Continuous delivery | Jenkins builds `scoutops:1.0.<build>` and runs `scripts/deploy.sh` |
| Infrastructure separation | local stack vs. production stack, no shared credentials |
| Observability | `prom-client` metrics, Prometheus, Grafana |
| Alerting | Prometheus alert rules (`monitoring/alerts.yml`) |
| Resilience | `scripts/backup.sh` (pg_dump) and `scripts/rollback.sh` (image tags) |
| Hygiene | `scripts/cleanup.sh` (never deletes database volumes) |

## 2. Project objectives

- Centralized issue reporting
- Issue tracking
- Status management
- Database persistence (PostgreSQL + named Docker volume)
- REST API with validation and parameterized SQL
- Containerization (Docker, Docker Compose)
- Automated testing (Jest + Supertest)
- CI/CD (GitHub → Jenkins)
- Production deployment (Ubuntu / AWS EC2)
- Monitoring (Prometheus + Grafana)
- Alerting (Prometheus rules)
- Backup (timestamped `pg_dump`)
- Rollback (versioned Docker image tags)

## 3. Architecture

**Application**

```
User
 |
 v
ScoutOps Web UI   (public/index.html - HTML/CSS/vanilla JS)
 |  fetch()
 v
Express REST API  (src/app.js)
 |  pg pool, parameterized queries
 v
PostgreSQL        (db/init.sql schema)
```

**DevOps pipeline**

```
Developer
 |  git push
 v
GitHub  --webhook-->  Jenkins controller
                          |  schedules on agent
                          v
                      Jenkins agent (Docker + Node.js)
                          |
   Checkout -> npm ci -> npm test -> docker build -> validate -> deploy -> health check
                                                                     |
                                                                     v
                                                  ScoutOps (scoutops-app) --> PostgreSQL (postgres)
```

**Monitoring**

```
ScoutOps (/metrics) --scrape every 15s--> Prometheus (:9090) --datasource--> Grafana (:3001)
                                              |
                                              +--> alert rules: ScoutOpsApplicationDown,
                                                   ScoutOpsHighErrorRate, ScoutOpsHighLatency
```

**Docker networks**

| Stack | Network | Purpose |
|-------|---------|---------|
| local | `scoutops-net` | app and Prometheus/Grafana |
| local | `scoutops-db` (internal) | app <-> postgres only; no outside access |
| production | `scoutops-prod-net` | app and Prometheus/Grafana |
| production | `scoutops-prod-db` (internal) | app <-> postgres only; no outside access |

PostgreSQL publishes **no** host port in either stack.

## 4. Technology stack

| Technology | Why it is used |
|------------|----------------|
| **Node.js 22 LTS** | Runtime for the API; one language front to back |
| **Express 4** | Small, well-understood HTTP framework for the REST API |
| **PostgreSQL 16** | Relational store with constraints (`CHECK`), indexes and identity keys |
| **pg** | Official Node driver; connection pool and parameterized queries |
| **dotenv** | Loads `.env` for local (non-Docker) runs |
| **HTML5 / CSS3 / vanilla JS** | Dependency-free UI, responsive, XSS-safe rendering via `textContent` |
| **Jest + Supertest** | Unit/API tests; the DB module is mocked so CI needs no PostgreSQL |
| **Docker** | Reproducible image (non-root, health check) |
| **Docker Compose** | Declares app + database + networks + volumes for local and production |
| **Git / GitHub** | Source control and webhook source |
| **Jenkins (controller + agent)** | CI/CD orchestration; agent runs Docker builds and deployments |
| **prom-client** | Exposes Prometheus metrics (HTTP count, duration, errors, process metrics) |
| **Prometheus** | Scrapes metrics, evaluates alert rules |
| **Grafana** | Dashboards; Prometheus datasource is provisioned automatically |
| **Bash scripts** | Deploy, rollback, backup, cleanup with explicit error handling |

## 5. Project structure

```
scoutops/
├── src/
│   ├── app.js                 # Express app: routes, validation, metrics, errors
│   ├── server.js              # Process entry point, graceful SIGTERM/SIGINT
│   └── db.js                  # PostgreSQL pool and helpers
├── public/
│   └── index.html             # ScoutOps web UI
├── tests/
│   └── app.test.js            # Jest + Supertest (database mocked)
├── db/
│   └── init.sql               # Schema, indexes, demo data
├── scripts/
│   ├── deploy.sh              # Build + deploy production stack, verify health
│   ├── rollback.sh            # Switch app to previous image version
│   ├── backup.sh              # Timestamped pg_dump backup
│   └── cleanup.sh             # Safe Docker cleanup
├── monitoring/
│   ├── docker-compose.monitoring.yml
│   ├── prometheus.yml
│   ├── alerts.yml
│   └── grafana-datasource.yml
├── Dockerfile
├── .gitignore
├── docker-compose.yml         # local stack
├── docker-compose.prod.yml    # production stack
├── Jenkinsfile
├── .env.example
├── LICENSE
├── README.md
├── package.json
└── package-lock.json
```

Created at runtime (not part of the repository): `.env`, `node_modules/`, `backups/`.

## 6. Ports, names and conventions

Every command in this README uses these exact names.

| Item | Value |
|------|-------|
| ScoutOps application | `http://localhost:3000` (override host port with `APP_PORT`) |
| Prometheus | `http://localhost:9090` (bound to 127.0.0.1) |
| Grafana | `http://localhost:3001` (bound to 127.0.0.1) |
| Compose service names | `scoutops-app`, `postgres` (monitoring: `prometheus`, `grafana`) |
| Container names | `scoutops-app`, `scoutops-postgres`, `scoutops-prometheus`, `scoutops-grafana` |
| Volumes | `scoutops_pgdata` (local), `scoutops_prod_pgdata` (production), `scoutops_prometheus_data`, `scoutops_grafana_data` |
| Image tags | `scoutops:local` (local compose), `scoutops:latest`, `scoutops:<MAJOR.MINOR.PATCH>` (production) |
| Database | name `scoutops`, user `scoutops_user`, host `postgres` inside Docker |

> **Local and production stacks use the same container names and port 3000, so run only one at a time.** Run `docker compose down` before starting production (and the reverse). Their data volumes are separate.

## 7. Prerequisites

| Tool | Needed for | Version check |
|------|------------|---------------|
| Ubuntu 22.04 / 24.04 (or other Linux) | everything | `lsb_release -a` |
| Git | cloning, CI | `git --version` |
| Node.js 20+ (22 LTS recommended) and npm | local run, tests, Jenkins agent | `node --version` / `npm --version` |
| Docker Engine | containers | `docker --version` |
| Docker Compose v2 plugin | stacks | `docker compose version` |
| curl | health checks and scripts | `curl --version` |
| Jenkins LTS + a Docker-capable agent | CI/CD | Jenkins UI → Manage Jenkins → About |
| PostgreSQL client (`psql`, `pg_dump`) | **optional**: only for host-mode backups or local-Node runs against a host database | `psql --version` |

Check everything at once:

```bash
node --version
npm --version
git --version
docker --version
docker compose version
curl --version | head -1
```

## 8. Installation on a fresh Ubuntu machine

```bash
# 1. System packages
sudo apt-get update
sudo apt-get install -y git curl ca-certificates gnupg

# 2. Node.js 22 LTS (NodeSource). Review any script before piping it to a shell.
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -y nodejs

# 3. Docker Engine + Compose plugin (official Docker apt repository)
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# 4. Run docker without sudo (log out and back in afterwards)
sudo usermod -aG docker "$USER"

# 5. Optional: PostgreSQL client tools
sudo apt-get install -y postgresql-client
```

Verify (after logging back in):

```bash
docker run --rm hello-world
```

## 9. Clone, environment, run locally

### Clone

```bash
git clone <repository-url>
cd scoutops
```

Replace `<repository-url>` with the URL of **your own** GitHub repository (for example the HTTPS or SSH URL shown by GitHub's green **Code** button). No repository URL is built into this project.

### Environment

```bash
cp .env.example .env
```

Edit `.env` (e.g. `nano .env`). **`.env` holds secrets and must never be committed.** Keep it out of Git:

```bash
printf '.env\nnode_modules/\nbackups/\n' >> .git/info/exclude
```

| Variable | Meaning |
|----------|---------|
| `NODE_ENV` | `development` or `production` (Compose sets this itself per stack) |
| `PORT` | Port the Node process listens on when run directly (default 3000) |
| `DB_HOST` | `postgres` (Compose service name). Use `localhost` when running Node directly on your host |
| `DB_PORT` | PostgreSQL port, `5432` |
| `DB_NAME` | Database name, `scoutops` |
| `DB_USER` | Database user, `scoutops_user` |
| `DB_PASSWORD` | **Change `change_me`** to a strong password. Production refuses the placeholder |
| `APP_PORT` | Host port the container is published on (default 3000) |
| `SCOUTOPS_VERSION` | Image tag for production (`MAJOR.MINOR.PATCH`) |
| `GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD` | Grafana login; the password is required to start monitoring |

### Local Node execution (without Docker for the app)

```bash
npm ci
npm test
npm start
```

* `npm test` needs **no database** (the DB module is mocked).
* `npm start` needs a reachable PostgreSQL with the ScoutOps schema. Easiest option, a throw-away PostgreSQL container published on localhost only:

```bash
docker run -d --name scoutops-dev-pg \
  -e POSTGRES_DB=scoutops -e POSTGRES_USER=scoutops_user \
  -e POSTGRES_PASSWORD='<same value as DB_PASSWORD in .env>' \
  -p 127.0.0.1:5432:5432 \
  -v "$PWD/db/init.sql:/docker-entrypoint-initdb.d/init.sql:ro" \
  postgres:16-alpine
```

and set `DB_HOST=localhost` in `.env`. (A host-installed PostgreSQL also works: create the user/database and run `psql -f db/init.sql`.) Remove the throw-away container with `docker rm -f scoutops-dev-pg`.

Verify: open **http://localhost:3000**. `npm run dev` restarts on file changes.

## 10. Docker execution

Build the image:

```bash
docker build -t scoutops:latest .
```

Start the local stack (app + PostgreSQL), in the foreground:

```bash
docker compose up --build
```

or in the background:

```bash
docker compose up -d --build
```

Verify and read logs:

```bash
docker compose ps
docker compose logs
docker compose logs scoutops-app
docker compose logs postgres
```

`docker compose ps` should show both services `Up ... (healthy)`; `scoutops-app` is published on `0.0.0.0:3000->3000/tcp`, `postgres` shows only the internal `5432/tcp`.

`db/init.sql` runs automatically the **first** time PostgreSQL starts with an empty volume. It is idempotent (`CREATE ... IF NOT EXISTS`, demo rows inserted only when the table is empty).

## 11. Testing the application and API reference

```bash
curl http://localhost:3000/health
# {"status":"UP","service":"scoutops"}

curl http://localhost:3000/health/db
# {"status":"UP","service":"scoutops","database":"UP"}      (HTTP 503 + "DOWN" if the DB is unreachable)

curl http://localhost:3000/metrics
# Prometheus text format: http_requests_total, http_request_duration_seconds, http_errors_total, scoutops_process_* ...
```

### API

| Method | Path | Description | Success | Errors |
|--------|------|-------------|---------|--------|
| GET | `/` | Web UI | 200 | |
| GET | `/health` | Liveness | 200 | |
| GET | `/health/db` | Runs `SELECT 1` against PostgreSQL | 200 | 503 |
| GET | `/metrics` | Prometheus metrics | 200 | 500 |
| GET | `/api/issues` | List issues (newest first). Optional filters `?status=&priority=&category=` | 200 | 400 invalid filter, 503 DB error |
| GET | `/api/issues/:id` | One issue | 200 | 400 bad id, 404 missing |
| POST | `/api/issues` | Create issue | 201 | 400 validation / malformed JSON |
| PUT | `/api/issues/:id` | Replace editable fields | 200 | 400, 404 |
| PATCH | `/api/issues/:id/status` | Change status only | 200 | 400, 404 |
| DELETE | `/api/issues/:id` | Delete issue | 200 | 400, 404 |

**Validation:** `title` 3-150 chars, `location` 2-150, `reporter_name` 2-100, `description` ≤ 2000 (optional), `category` required enum, `priority` default `MEDIUM`, `status` default `OPEN`. Enum values are case-insensitive on input and stored upper-case. All SQL uses `$1, $2...` parameters; user input is never concatenated into SQL.

### curl examples

```bash
# GET (list, filtered list, single)
curl http://localhost:3000/api/issues
curl "http://localhost:3000/api/issues?status=OPEN&priority=CRITICAL"
curl http://localhost:3000/api/issues/1

# POST (create) - capture the new id
ID=$(curl -s -X POST http://localhost:3000/api/issues \
  -H 'Content-Type: application/json' \
  -d '{"title":"Water cooler leaking","description":"Puddle near the lift","category":"PLUMBING","location":"Block B, Ground Floor","priority":"HIGH","reporter_name":"Demo User"}' \
  | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)
echo "Created issue $ID"

# PUT (update all editable fields)
curl -X PUT http://localhost:3000/api/issues/$ID \
  -H 'Content-Type: application/json' \
  -d '{"title":"Water cooler leaking (updated)","description":"Puddle near the lift","category":"PLUMBING","location":"Block B, Ground Floor","priority":"CRITICAL","reporter_name":"Demo User","status":"ASSIGNED"}'

# PATCH (status only)
curl -X PATCH http://localhost:3000/api/issues/$ID/status \
  -H 'Content-Type: application/json' -d '{"status":"IN_PROGRESS"}'

# DELETE
curl -X DELETE http://localhost:3000/api/issues/$ID
# {"message":"Issue deleted","id":<ID>}

# Error examples
curl -i http://localhost:3000/api/issues/999999      # 404 {"error":"Issue not found"}
curl -i -X POST http://localhost:3000/api/issues -H 'Content-Type: application/json' -d '{"title":"x"}'   # 400 with details
```

## 12. Database

```bash
docker compose exec postgres psql \
  -U scoutops_user \
  -d scoutops
```

Inside `psql`:

```sql
\dt
SELECT * FROM issues;
SELECT status, count(*) FROM issues GROUP BY status;
\q
```

Expected: `\dt` lists the `issues` table; `SELECT * FROM issues;` shows 10 demo rows (plus any you created). The schema has an identity primary key, `CHECK` constraints on `category`/`priority`/`status`, `NOT NULL` columns with defaults, and indexes on `status`, `priority`, `category` and `created_at`.

**Persistence:** data lives in the named volume `scoutops_pgdata`, not in the container filesystem, so containers can be removed and recreated without losing issues.

## 13. Stop / start and data persistence

```bash
docker compose down        # stops and removes containers and networks; data volume is KEPT
docker compose up -d       # starts again; your issues are still there
```

Named volumes survive `docker compose down`.

> **WARNING:** `docker compose down -v` also **deletes the named volumes, i.e. all local database data**. Only use it when you intentionally want a fresh, re-seeded database.

## 14. Production deployment

The production stack (`docker-compose.prod.yml`) is separate from the local one: different network and volume names, `NODE_ENV=production`, `restart: always`, a read-only app filesystem with all Linux capabilities dropped, log rotation, and **no credentials in the file** (everything comes from `.env` or the environment; missing values make Compose refuse to start).

Prerequisites: `.env` contains a real `DB_PASSWORD` (not `change_me`), `DB_NAME`, `DB_USER`, and optionally `APP_PORT` and `SCOUTOPS_VERSION`. Stop the local stack first: `docker compose down`.

```bash
docker compose -f docker-compose.prod.yml build

docker compose -f docker-compose.prod.yml up -d
```

Verify:

```bash
docker compose -f docker-compose.prod.yml ps
```

Logs:

```bash
docker compose -f docker-compose.prod.yml logs -f
```

The image built is tagged `scoutops:${SCOUTOPS_VERSION}` (default `1.0.0`).

### Deployment script

Prefer the script: it validates, builds, starts, and **verifies** instead of assuming success.

```bash
chmod +x scripts/*.sh

./scripts/deploy.sh
```

| Step | What happens |
|------|--------------|
| 1. Validate | Checks `docker`, `curl`, Compose v2 and daemon access; requires `DB_NAME`, `DB_USER`, `DB_PASSWORD` (rejects `change_me`); requires a `MAJOR.MINOR.PATCH` version; refuses to run if the **local** stack's `scoutops-app` still exists; runs `docker compose config -q` |
| 2. Build | Builds `scoutops:<version>` and also tags it `scoutops:latest` (`--no-build` reuses an existing image; Jenkins uses this) |
| 3-4. Database | Starts `postgres`, waits until Docker reports it `healthy` (timeout `HEALTH_TIMEOUT`, default 120 s) |
| 5. Application | Starts `scoutops-app`, waits until `healthy` |
| 6. Verify | `curl`s `/health` and `/health/db`; any non-2xx fails the deployment |
| Report | Prints version, URLs, container names and the rollback command. On any failure it exits non-zero with `DEPLOYMENT FAILED` and shows container logs |

To deploy a specific version: `SCOUTOPS_VERSION=1.0.4 ./scripts/deploy.sh`. **Bump the version for every deployment you may want to roll back from**: rebuilding an existing version overwrites that tag (the script warns).

## 15. Backup, rollback and cleanup

### Database backup

```bash
./scripts/backup.sh
```

* **Directory:** `./backups` (created with mode `700`; override with `BACKUP_DIR`).
* **File name:** `scoutops_<DB_NAME>_<UTC timestamp>.dump`, e.g. `scoutops_scoutops_20261013T083734Z.dump` (mode `600`).
* **Format:** `pg_dump --format=custom` (compressed; restore with `pg_restore`).
* **Mode:** `BACKUP_MODE=auto` (default) runs `pg_dump` **inside** the `scoutops-postgres` container when it is running (PostgreSQL is not published to the host); otherwise it runs host `pg_dump` against `DB_HOST:DB_PORT`. Force with `BACKUP_MODE=docker` or `BACKUP_MODE=host`.
* **Safety:** the password is read from `.env`/environment, passed only via `PGPASSWORD`, and never printed. The dump is written to a `.partial` file, verified with `pg_restore --list`, then renamed; a failed backup leaves no file behind.
* **Retention:** optional `BACKUP_KEEP=N` keeps only the newest N dumps.

**Restore procedure (safe, into a scratch database first)**

```bash
# 1. pick the backup
ls -l backups/

# 2. create a scratch database and restore into it (Docker)
docker exec scoutops-postgres createdb -U scoutops_user scoutops_restore_test
docker exec -i scoutops-postgres pg_restore -U scoutops_user -d scoutops_restore_test --no-owner < backups/<file>.dump

# 3. inspect it
docker exec scoutops-postgres psql -U scoutops_user -d scoutops_restore_test -c "SELECT count(*) FROM issues;"

# 4. remove the scratch database
docker exec scoutops-postgres dropdb -U scoutops_user scoutops_restore_test
```

To recover the real database after data loss: stop the app (`docker compose -f docker-compose.prod.yml stop scoutops-app`), take a fresh backup of what remains, restore the dump into a **new** database as above, verify it, then switch the app to it (rename databases with `ALTER DATABASE`, or point `DB_NAME` at the restored database) and start the app again. Do not restore over a live database you have not backed up.

### Rollback

```bash
./scripts/rollback.sh
```

**Versioning strategy.** Production images are tagged `scoutops:MAJOR.MINOR.PATCH` (for example `scoutops:1.0.1`, `scoutops:1.0.2`). Jenkins uses `1.0.<BUILD_NUMBER>`; manual deployments set `SCOUTOPS_VERSION`. `scoutops:latest` always points at the newest build but is **not** used for rollback.

**What the script does**

1. Reads the running container's image tag → **current version**.
2. Lists local `scoutops:X.Y.Z` images, sorted with `sort -V` → **previous version** = the next lower tag.
3. Stops `scoutops-app`.
4. Starts `scoutops-app` from the previous tag (`docker compose up -d --no-build --no-deps --force-recreate`).
5. Waits for Docker's health check to report `healthy` and `curl`s `/health` and `/health/db`.
6. Prints `ROLLBACK SUCCEEDED: <old> -> <new>` **only if** all checks pass; otherwise it exits non-zero with `ROLLBACK FAILED`.

Options: `./scripts/rollback.sh --dry-run` (show the plan only) and `./scripts/rollback.sh 1.0.3` (explicit target tag). It fails clearly when there is no older image. **Only the application image is rolled back; database contents are not** (restore a backup for that). Keep several old images: `cleanup.sh --keep-versions N` preserves them.

### Cleanup

```bash
./scripts/cleanup.sh
```

After a confirmation prompt it removes **stopped containers, unused networks, dangling images, Docker build cache, `./.tmp` and `./coverage`**. Options: `--dry-run` (print only), `--yes` (no prompt, for CI), `--keep-versions N` (also delete `scoutops:X.Y.Z` images except the newest N and any in use). **Docker volumes are never removed**, so the PostgreSQL data (`scoutops_pgdata`, `scoutops_prod_pgdata`) is safe. Backups in `./backups` are not touched.

## 16. Monitoring: Prometheus, Grafana, alerts

The monitoring stack joins the application's Docker network, so Prometheus scrapes `scoutops-app:3000/metrics` by service name. **Start the application stack first.**

### Prometheus

```bash
docker compose \
  --env-file .env \
  -f monitoring/docker-compose.monitoring.yml \
  up -d
```

`--env-file .env` is required because Compose reads `.env` from the directory of the compose file (`monitoring/`), and Grafana needs `GRAFANA_ADMIN_PASSWORD` from your root `.env`.

If the **production** stack is running, tell Prometheus to join the production network:

```bash
SCOUTOPS_NETWORK=scoutops-prod-net docker compose \
  --env-file .env \
  -f monitoring/docker-compose.monitoring.yml \
  up -d
```

(default `SCOUTOPS_NETWORK` is `scoutops-net`, the local stack's network.)

Open **http://localhost:9090** → **Status → Targets**. The `scoutops` target (`scoutops-app:3000`) must show **UP**.

Useful queries (Graph tab):

| Question | PromQL |
|----------|--------|
| Is the app up? (1 = yes) | `up{job="scoutops"}` |
| Requests per second | `sum(rate(http_requests_total{job="scoutops"}[1m]))` |
| Requests per route | `sum by (route) (rate(http_requests_total[5m]))` |
| 5xx error ratio | `sum(rate(http_requests_total{status_code=~"5.."}[5m])) / sum(rate(http_requests_total[5m]))` |
| 4xx + 5xx errors per second | `sum(rate(http_errors_total[5m]))` |
| p95 latency (seconds) | `histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket[5m])))` |
| Memory | `scoutops_process_resident_memory_bytes` |
| Event loop lag | `scoutops_nodejs_eventloop_lag_seconds` |

Metrics exposed: `http_requests_total{method,route,status_code}`, `http_request_duration_seconds` (histogram), `http_errors_total` (status ≥ 400), and Node.js/process metrics prefixed `scoutops_`.

### Grafana

Open **http://localhost:3001**.

* **Login:** user = `GRAFANA_ADMIN_USER` (default `admin`), password = the `GRAFANA_ADMIN_PASSWORD` you set in `.env`. There is no built-in default password.
* **Datasource:** provisioned automatically from `monitoring/grafana-datasource.yml` as **Prometheus** (`http://prometheus:9090`, default). Verify under **Connections → Data sources → Prometheus → Save & test** (should report success).
* **Dashboard:** **Dashboards → New → New dashboard → Add visualization**, pick *Prometheus*, and add panels using the queries above, for example: *Requests/s*, *p95 latency*, *5xx ratio*, *App up (stat panel)*, *Memory*. Save the dashboard.
* **Metrics:** use **Explore** for ad-hoc queries.

Both Prometheus and Grafana are bound to `127.0.0.1`. On a remote server use an SSH tunnel: `ssh -L 3001:localhost:3001 -L 9090:localhost:9090 ubuntu@<server>`.

### Alerts

Defined in `monitoring/alerts.yml`, loaded by Prometheus:

| Alert | Condition | Severity |
|-------|-----------|----------|
| `ScoutOpsApplicationDown` | `up{job="scoutops"} == 0` for 1 minute | critical |
| `ScoutOpsHighErrorRate` | more than 5 % of requests return 5xx over 5 minutes, sustained for 5 minutes | warning |
| `ScoutOpsHighLatency` | p95 request latency above 1 second, sustained for 5 minutes | warning |

View them at **http://localhost:9090/alerts** (or **Status → Rule health**). States: *inactive* → *pending* (condition true, waiting out `for:`) → *firing*. Prometheus only **evaluates** rules; delivering notifications (email, Slack...) needs an Alertmanager, which is not part of this project.

## 17. Jenkins and GitHub CI/CD

### 17.1 Jenkins architecture

```
Jenkins Controller  (UI, scheduling, credentials)
        |  SSH (or inbound agent)
        v
Jenkins Agent  label: docker
        |  runs: git, node/npm, docker build, docker compose, curl
        v
Docker Build / Test / Deployment  (production stack runs on the agent host)
```

The `Jenkinsfile` requests `agent { label 'docker' }`. The agent host is where ScoutOps is deployed, so for EC2 it is your production server (or a build server that deploys remotely - not covered by the default pipeline).

**Tools the agent must have (nothing is assumed to be preinstalled):**

| Tool | Why | Check as the `jenkins` user |
|------|-----|------------------------------|
| Java 17 or 21 | runs the Jenkins agent process | `java -version` |
| Git | checkout | `git --version` |
| Node.js 20+ and npm | `npm ci`, `npm test` | `node --version && npm --version` |
| Docker Engine + Compose v2 plugin | image build, `docker compose` | `docker --version && docker compose version` |
| curl | health checks, scripts | `curl --version` |
| bash | `scripts/*.sh` | `bash --version` |

### 17.2 Install Jenkins (controller)

```bash
sudo apt-get update
sudo apt-get install -y fontconfig openjdk-17-jre
sudo wget -O /usr/share/keyrings/jenkins-keyring.asc https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key
echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/" \
  | sudo tee /etc/apt/sources.list.d/jenkins.list > /dev/null
sudo apt-get update
sudo apt-get install -y jenkins
sudo systemctl enable --now jenkins
sudo cat /var/lib/jenkins/secrets/initialAdminPassword      # unlock Jenkins at http://<controller>:8080
```

Put Jenkins behind HTTPS (a reverse proxy such as nginx with a certificate) before exposing it to GitHub. Use your own domain wherever this README shows `<jenkins-domain>`.

### 17.3 Required plugins

Manage Jenkins → Plugins → Available: **Git**, **GitHub**, **Pipeline** (workflow-aggregator), **Credentials Binding**, **Timestamper**, **SSH Build Agents** (for SSH-launched agents). The suggested-plugins set at first start includes most of these.

### 17.4 Prepare the agent (Git, Node, Docker, permissions)

On the **agent** machine:

```bash
# dedicated user
sudo adduser --disabled-password --gecos "" jenkins
sudo apt-get install -y openjdk-17-jre git curl
# Node.js 22 and Docker Engine: use the commands from section 8

# Docker group: lets the jenkins user run docker without sudo
sudo usermod -aG docker jenkins
```

> **Security note:** membership of the `docker` group is effectively root on that host. Only trusted pipelines should run on this agent.

Group changes apply to **new** sessions: disconnect and relaunch the agent (or `sudo systemctl restart jenkins` on a built-in node) afterwards. Verify:

```bash
sudo -u jenkins docker ps
```

SSH access for the controller (run on the controller as the `jenkins` user, or wherever you generate keys; never commit the key):

```bash
ssh-keygen -t ed25519 -C "jenkins-agent" -f ~/.ssh/scoutops_agent
ssh-copy-id -i ~/.ssh/scoutops_agent.pub jenkins@<agent-host>
```

### 17.5 Credentials

Manage Jenkins → Credentials → System → Global → Add Credentials. **Never put real secrets in Git.**

| Credential ID | Type | Purpose | Where used |
|---------------|------|---------|------------|
| `github-credentials` | Username with password (GitHub username + personal access token) **or** SSH Username with private key | Lets Jenkins clone a private repository | Pipeline job → Definition → SCM → Credentials (used by `checkout scm`) |
| `scoutops-env-file` | **Secret file** (upload a copy of your production `.env`: `DB_NAME`, `DB_USER`, `DB_PASSWORD`, `APP_PORT`, `GRAFANA_ADMIN_PASSWORD`, ...) | Supplies production configuration without storing it in Git | `Jenkinsfile` stages **Validate** and **Deploy** (`withCredentials([file(...)])`); copied to `.env` and deleted in `post { always }` |
| `deployment-ssh-key` | SSH Username with private key | Key the controller uses to connect to the agent (and to a remote host if you extend the pipeline to deploy remotely) | Manage Jenkins → Nodes → agent → Launch method *Launch agents via SSH* → Credentials. **Not referenced inside the default Jenkinsfile** |
| `docker-credentials` | Username with password | Only if you extend the pipeline to push images to a registry | **Not used by the default pipeline** (images stay on the agent host) |

Credential IDs are exact: the Jenkinsfile refers to `scoutops-env-file`.

### 17.6 Configure the Jenkins agent

Manage Jenkins → Nodes → **New Node** → name `scoutops-agent` → *Permanent Agent*:

* Remote root directory: `/home/jenkins/agent`
* Labels: **`docker`**
* Usage: *Only build jobs with label expressions matching this node* (recommended)
* Launch method: **Launch agents via SSH** → Host `<agent-host>` → Credentials `deployment-ssh-key` → Host Key Verification Strategy *Known hosts file verification* (run `ssh jenkins@<agent-host>` once from the controller first to trust the host)

Save. The node log must end with *"Agent successfully connected and online"*. Connectivity requirements: controller → agent TCP/22; agent → Docker Hub (image pulls) and, for GitHub checkouts, outbound HTTPS. If you cannot use a label named `docker`, change `agent { label 'docker' }` in the `Jenkinsfile`.

### 17.7 Create the pipeline job

1. Dashboard → **New Item** → name `scoutops` → **Pipeline** → OK.
2. **Build Triggers:** tick *GitHub hook trigger for GITScm polling*.
3. **Pipeline → Definition:** *Pipeline script from SCM*.
4. **SCM:** Git → Repository URL `<repository-url>` (your repo) → Credentials `github-credentials` → Branch `*/main`.
5. **Script Path:** `Jenkinsfile`.
6. Save → **Build Now** once (this registers the `githubPush()` trigger).

(For a *Multibranch Pipeline* job the `Deploy` stage deploys only the `main` branch.)

### 17.8 GitHub webhook

Flow:

```
Developer -> git push -> GitHub -> Webhook -> Jenkins -> Jenkinsfile -> Pipeline
```

GitHub repository → **Settings → Webhooks → Add webhook**:

| Field | Value |
|-------|-------|
| Payload URL | `https://<jenkins-domain>/github-webhook/` (keep the trailing slash; replace the placeholder with your real Jenkins address) |
| Content type | `application/json` |
| Secret | optional shared secret (also configure it in Jenkins → System → GitHub if used) |
| Events | **Just the push event** |
| Active | ✔ |

After saving, GitHub shows a green tick under *Recent Deliveries* (HTTP 200). Jenkins must be reachable from the internet over HTTPS for this to work; if it is not, use *Poll SCM* in the job instead.

### 17.9 Pipeline stages

| # | Stage | What runs | Success looks like | Typical failure |
|---|-------|-----------|--------------------|-----------------|
| 1 | **Checkout** | `checkout scm` | latest commit printed | wrong credentials / URL / branch |
| 2 | **Install Dependencies** | `npm ci` (falls back to `npm install` only if no lockfile) | dependencies installed | Node/npm missing on agent; lockfile out of sync with `package.json` |
| 3 | **Run Tests** | `npm test` (23 Jest tests, DB mocked) | `Tests: 23 passed` | any failing test - **pipeline stops here** |
| 4 | **Build Docker Image** | `docker build -t scoutops:1.0.<BUILD_NUMBER> -t scoutops:latest .` | image built | Docker permission denied; Docker Hub unreachable |
| 5 | **Validate** | injects `.env`, `bash -n scripts/*.sh`, `docker compose config -q` for production and monitoring, `docker image inspect` | no output, exit 0 | missing/blank variable in the `scoutops-env-file` credential |
| 6 | **Deploy** | `./scripts/deploy.sh --no-build` (starts DB, app, waits for `healthy`, checks endpoints) | `ScoutOps deployed successfully` | local stack still running; port in use; DB password placeholder |
| 7 | **Health Check** | `curl` `/health` and `/health/db` with retries | both return JSON with `UP` | app crashed or DB unreachable |

When a stage fails, **later stages are skipped**, so a failing test can never reach Deploy. `post { failure }` prints the last 100 log lines of `scoutops-app`; `post { always }` deletes `.env` from the workspace and prunes dangling images.

### 17.10 Complete CI/CD test

```bash
git add .
git commit -m "Update ScoutOps application"
git push origin main
```

Then, without touching Jenkins, watch the chain:

```
GitHub receives push -> Webhook (green tick) -> Jenkins build #N starts automatically
-> Checkout -> Install Dependencies -> Run Tests -> Build Docker Image -> Validate
-> Deploy -> Health Check -> SUCCESS
```

Confirm on the agent host: `docker images scoutops` shows `1.0.N`, and `curl http://localhost:3000/health` returns `{"status":"UP","service":"scoutops"}`.

## 18. Failure, monitoring and recovery tests

### 18.1 Controlled CI failure test

```bash
# 1. add an intentionally failing test
cat >> tests/app.test.js <<'TESTEOF'

test('intentional CI failure (remove me)', () => {
  expect(true).toBe(false);
});
TESTEOF

# 2. commit and push
git add tests/app.test.js
git commit -m "TEST: intentional failing test"
git push origin main
```

Expected in Jenkins: the build turns **red** at **Run Tests**; **Build Docker Image, Validate, Deploy and Health Check are skipped**; the running application is unchanged (still the previous version).

Fix and push again:

```bash
git revert --no-edit HEAD
git push origin main
```

Expected: a new build runs, all seven stages are green, and the new version is deployed.

### 18.2 Monitoring failure test

The monitoring stack and application stack must be running.

```bash
docker stop scoutops-app
```

* Within ~15-30 s, **Status → Targets** at http://localhost:9090/targets shows `scoutops` as **DOWN**.
* After the 1-minute `for:` window, **http://localhost:9090/alerts** shows `ScoutOpsApplicationDown` as **FIRING** (it is *pending* first).

Restore:

```bash
docker start scoutops-app
```

Verify: the target returns to **UP** within a scrape interval or two, the alert returns to *inactive*, and `curl http://localhost:3000/health` answers again. (`docker stop` is a manual stop, so the `restart` policy intentionally does not bring the container back.)

### 18.3 Backup and recovery test

Run against the stack that is running (examples use Docker mode; `backup.sh` auto-detects the `scoutops-postgres` container).

```bash
# 1. create a recognizable issue
curl -s -X POST http://localhost:3000/api/issues -H 'Content-Type: application/json' \
  -d '{"title":"Backup test issue","description":"created before backup","category":"OTHER","location":"Test Lab","priority":"LOW","reporter_name":"Backup Tester"}'

# 2. run a backup
./scripts/backup.sh

# 3. verify the backup file exists and is readable
ls -l backups/
docker exec -i scoutops-postgres pg_restore --list < "$(ls -t backups/scoutops_*.dump | head -1)" | head

# 4. safe test recovery into a SCRATCH database (production data is not touched)
docker exec scoutops-postgres createdb -U scoutops_user scoutops_restore_test
docker exec -i scoutops-postgres pg_restore -U scoutops_user -d scoutops_restore_test --no-owner \
  < "$(ls -t backups/scoutops_*.dump | head -1)"

# 5-6. verify the issue exists in the restored copy
docker exec scoutops-postgres psql -U scoutops_user -d scoutops_restore_test \
  -c "SELECT id, title FROM issues WHERE title = 'Backup test issue';"

# 7. clean up the scratch database
docker exec scoutops-postgres dropdb -U scoutops_user scoutops_restore_test
```

Expected: the `SELECT` returns the `Backup test issue` row. Delete the test issue from the UI or with `curl -X DELETE`.

## 19. Complete execution procedure (35 steps)

Follow the steps in order on one Ubuntu machine (a laptop, VM, or an EC2 instance). Steps 1-17 use the **local** stack, steps 18-25 the **production** stack and monitoring, steps 26-31 Jenkins/GitHub, steps 32-35 resilience tests. Troubleshooting numbers refer to [section 20](#20-troubleshooting).

---

### STEP 1 - Install prerequisites
**Purpose:** Have Git, Node.js, Docker and Compose available.
**Command:** run the commands in [section 8](#8-installation-on-a-fresh-ubuntu-machine), then log out and back in.
**Expected output:** `docker run --rm hello-world` prints "Hello from Docker!".
**Verification:**
```bash
git --version && node --version && npm --version && docker --version && docker compose version
```
All five print versions (Node ≥ 20).
**Troubleshooting:** 1 (daemon not running), 7 (permission denied).

### STEP 2 - Clone ScoutOps
**Purpose:** Get the source onto the machine.
**Command:**
```bash
git clone <repository-url>
```
Replace `<repository-url>` with your own GitHub repository URL.
*If you only have `scoutops.zip`:* create an **empty** repository on GitHub, then
```bash
unzip scoutops.zip && cd scoutops
git init -b main
printf '.env\nnode_modules/\nbackups/\n' >> .git/info/exclude
git add .
git commit -m "Initial ScoutOps import"
git remote add origin <repository-url>
git push -u origin main
```
**Expected output:** a `scoutops/` directory (or "Cloning into 'scoutops'...").
**Verification:** `ls scoutops` lists `src public tests db scripts monitoring Dockerfile ...`.
**Troubleshooting:** 10 (GitHub authentication failure).

### STEP 3 - Enter the directory
**Purpose:** All later commands assume the project root.
**Command:** `cd scoutops`
**Expected output:** none.
**Verification:** `pwd` ends with `/scoutops`; `ls package.json` succeeds.

### STEP 4 - Create `.env`
**Purpose:** Provide configuration and secrets (never committed).
**Command:**
```bash
cp .env.example .env
nano .env        # set DB_PASSWORD and GRAFANA_ADMIN_PASSWORD to strong values
```
**Expected output:** none.
**Verification:** `grep -c change_me .env` prints `0`; `git status` does not list `.env`.
**Troubleshooting:** 16 (missing environment variable).

### STEP 5 - Install dependencies
**Purpose:** Install exact locked dependency versions.
**Command:**
```bash
npm ci
```
**Expected output:** `added ~290 packages` with no errors.
**Verification:** `ls node_modules/express` succeeds.
**Troubleshooting:** 12 (npm failure) - `npm ci` fails if `package-lock.json` disagrees with `package.json`.

### STEP 6 - Run tests
**Purpose:** Prove the API logic works before building anything.
**Command:**
```bash
npm test
```
**Expected output:** `Tests: 23 passed, 23 total`.
**Verification:** exit code 0 (`echo $?` → `0`). No database is needed.
**Troubleshooting:** 12.

### STEP 7 - Build the Docker image
**Purpose:** Produce the container image.
**Command:**
```bash
docker build -t scoutops:latest .
```
**Expected output:** ends with `naming to docker.io/library/scoutops:latest`.
**Verification:** `docker images scoutops` lists `latest`.
**Troubleshooting:** 1, 7, 18.

### STEP 8 - Start Docker Compose (local stack)
**Purpose:** Start ScoutOps + PostgreSQL.
**Command:**
```bash
docker compose up -d --build
```
**Expected output:** `Container scoutops-postgres Healthy`, then `Container scoutops-app Started`.
**Verification:** continue to Step 9.
**Troubleshooting:** 2 (port in use), 3/4 (PostgreSQL connection/auth), 5 (container exits), 16, 17, 18.

### STEP 9 - Verify containers
**Purpose:** Confirm both services are healthy.
**Command:**
```bash
docker compose ps
```
**Expected output:**
```
NAME                IMAGE                SERVICE        STATUS                  PORTS
scoutops-app        scoutops:local       scoutops-app   Up ... (healthy)        0.0.0.0:3000->3000/tcp
scoutops-postgres   postgres:16-alpine   postgres       Up ... (healthy)        5432/tcp
```
**Verification:** both rows say `(healthy)`; PostgreSQL has no `0.0.0.0` mapping.
**Troubleshooting:** 5, 6 - `docker compose logs scoutops-app`.

### STEP 10 - Open ScoutOps
**Purpose:** Use the web UI.
**Command:** open **http://localhost:3000** in a browser.
**Expected output:** the SCOUTOPS header, "Find. Track. Resolve.", dashboard counters, the report form and 10 demo issues.
**Verification:** the header pills read **API: UP** and **Database: UP**.
**Troubleshooting:** 2, 6.

### STEP 11 - Check the health endpoint
**Purpose:** Confirm the API process is alive.
**Command:**
```bash
curl http://localhost:3000/health
```
**Expected output:** `{"status":"UP","service":"scoutops"}`
**Verification:** HTTP 200 (`curl -i`).

### STEP 12 - Check database health
**Purpose:** Confirm the API can reach PostgreSQL.
**Command:**
```bash
curl http://localhost:3000/health/db
```
**Expected output:** `{"status":"UP","service":"scoutops","database":"UP"}`
**Verification:** HTTP 200; `503` with `"database":"DOWN"` means the app cannot reach PostgreSQL.
**Troubleshooting:** 3, 4, 17.

### STEP 13 - Check metrics
**Purpose:** Confirm Prometheus-format metrics are exposed.
**Command:**
```bash
curl -s http://localhost:3000/metrics | grep -E '^(http_requests_total|http_request_duration_seconds_count)'
```
**Expected output:** lines such as `http_requests_total{method="GET",route="/health",status_code="200"} 1`.
**Verification:** the counter increases when you repeat Step 11 and re-run this command.

### STEP 14 - Create an issue
**Purpose:** Exercise the create (POST) endpoint.
**Command:**
```bash
ID=$(curl -s -X POST http://localhost:3000/api/issues -H 'Content-Type: application/json' \
  -d '{"title":"Water cooler leaking","description":"Puddle near the lift","category":"PLUMBING","location":"Block B, Ground Floor","priority":"HIGH","reporter_name":"Demo User"}' \
  | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)
echo "Created issue $ID"
```
**Expected output:** `Created issue 11` (id may differ). HTTP status of the POST is 201.
**Verification:** `curl http://localhost:3000/api/issues/$ID` returns it; it also appears in the UI (press **Refresh**).

### STEP 15 - Update the issue
**Purpose:** Exercise the update (PUT) endpoint.
**Command:**
```bash
curl -X PUT http://localhost:3000/api/issues/$ID -H 'Content-Type: application/json' \
  -d '{"title":"Water cooler leaking (updated)","description":"Puddle near the lift","category":"PLUMBING","location":"Block B, Ground Floor","priority":"CRITICAL","reporter_name":"Demo User","status":"ASSIGNED"}'
```
**Expected output:** the JSON issue with the new title, `"priority":"CRITICAL"`, `"status":"ASSIGNED"` and a newer `updated_at`.
**Verification:** in the UI click **Edit** on the issue to see the same values.

### STEP 16 - Change the issue status
**Purpose:** Exercise the status-change (PATCH) endpoint.
**Command:**
```bash
curl -X PATCH http://localhost:3000/api/issues/$ID/status -H 'Content-Type: application/json' -d '{"status":"IN_PROGRESS"}'
```
**Expected output:** the issue JSON with `"status":"IN_PROGRESS"`.
**Verification:** the status dropdown on the issue card shows IN PROGRESS; an invalid value (`{"status":"DONE"}`) returns 400.

### STEP 17 - Delete the test issue
**Purpose:** Exercise the delete endpoint and clean up test data.
**Command:**
```bash
curl -X DELETE http://localhost:3000/api/issues/$ID
```
**Expected output:** `{"message":"Issue deleted","id":11}`
**Verification:** `curl -i http://localhost:3000/api/issues/$ID` now returns `404`.

### STEP 18 - Build the production environment
**Purpose:** Switch from the local to the production stack (they share names and port 3000).
**Command:**
```bash
docker compose down
docker compose -f docker-compose.prod.yml build
```
**Expected output:** `Image scoutops:1.0.0 Built` (the tag follows `SCOUTOPS_VERSION`).
**Verification:** `docker images scoutops` shows `1.0.0`.
**Troubleshooting:** 16 (a `required` variable message names the missing variable), 1, 18.

### STEP 19 - Run the deployment script
**Purpose:** Deploy the production stack with validation and verified health checks.
**Command:**
```bash
chmod +x scripts/*.sh
./scripts/deploy.sh
```
**Expected output:** six numbered steps followed by the box `ScoutOps deployed successfully` with version, URLs and container names.
**Verification:** `docker compose -f docker-compose.prod.yml ps` shows both services `(healthy)`; `curl http://localhost:3000/health/db` returns `UP`. The script exits non-zero (and says `DEPLOYMENT FAILED`) otherwise.
**Troubleshooting:** 15 (permission denied), 7, 2, 16, 5.

### STEP 20 - Run a database backup
**Purpose:** Create a timestamped, verified PostgreSQL backup.
**Command:**
```bash
./scripts/backup.sh
```
**Expected output:** `Backing up 'scoutops' via container scoutops-postgres` then `Backup created: ./backups/scoutops_scoutops_<timestamp>.dump (12K)`.
**Verification:** `ls -l backups/` shows the file (mode `-rw-------`); the script already ran `pg_restore --list` on it.
**Troubleshooting:** 3/4, 16.

### STEP 21 - Start Prometheus (and Grafana)
**Purpose:** Start Prometheus and Grafana so ScoutOps can be monitored.
**Command:** (production network, because Step 19 deployed production)
```bash
SCOUTOPS_NETWORK=scoutops-prod-net docker compose \
  --env-file .env \
  -f monitoring/docker-compose.monitoring.yml \
  up -d
```
**Expected output:** `Container scoutops-prometheus Healthy`, `Container scoutops-grafana Started`.
**Verification:** `docker ps --format '{{.Names}}: {{.Status}}'` lists `scoutops-prometheus` and `scoutops-grafana`; http://localhost:9090 loads.
**Troubleshooting:** 16 (GRAFANA_ADMIN_PASSWORD), 18 (`network ... not found` → start the application stack first), 2.

### STEP 22 - Verify the Prometheus target
**Purpose:** Confirm Prometheus is successfully scraping ScoutOps.
**Command:** open **http://localhost:9090/targets**.
**Expected output:** job `scoutops`, endpoint `http://scoutops-app:3000/metrics`, state **UP**.
**Verification:** run `up{job="scoutops"}` in the Graph tab → value `1`.
**Troubleshooting:** 13 (target DOWN).

### STEP 23 - Access Grafana
**Purpose:** Log in to Grafana.
**Command:** open **http://localhost:3001** and log in with `GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD` from `.env`.
**Expected output:** the Grafana home page.
**Verification:** you can create a dashboard (Dashboards → New → Add visualization).
**Troubleshooting:** 14, 2.

### STEP 24 - Verify the Grafana datasource
**Purpose:** Confirm Grafana is connected to Prometheus automatically (no manual datasource setup).
**Command:** Connections → Data sources → **Prometheus** → **Save & test**.
**Expected output:** a green "Successfully queried the Prometheus API" message. URL shown: `http://prometheus:9090`.
**Verification:** Explore → run `up{job="scoutops"}` → returns `1`.
**Troubleshooting:** 14.

### STEP 25 - Verify Prometheus alerts
**Purpose:** Confirm the three alert rules are loaded.
**Command:** open **http://localhost:9090/alerts**.
**Expected output:** `ScoutOpsApplicationDown`, `ScoutOpsHighErrorRate`, `ScoutOpsHighLatency` listed, all **inactive** (green).
**Verification:** Status → Rule health shows 3 rules `ok`. See Step 34 for making one fire.

### STEP 26 - Configure Jenkins
**Purpose:** Set up the Jenkins controller, Docker-capable agent, credentials and pipeline job.
**Command:** follow [17.2-17.7](#17-jenkins-and-github-cicd): install Jenkins and plugins, prepare the agent (Git, Node, Docker, `docker` group), add credentials `github-credentials` and `scoutops-env-file`, add the node labelled `docker`, create the `scoutops` Pipeline job.
**Expected output:** the node is **online**; **Build Now** runs the pipeline.
**Verification:** `sudo -u jenkins docker ps` works on the agent; the first build reaches the Deploy stage.
**Troubleshooting:** 8 (Jenkins Docker permission denied), 9 (agent offline), 10 (GitHub authentication), 11 (pipeline failure).

### STEP 27 - Configure the GitHub webhook
**Purpose:** Make GitHub notify Jenkins on every push.
**Command:** GitHub → repository → Settings → Webhooks → Add webhook: payload URL `https://<jenkins-domain>/github-webhook/`, content type `application/json`, *Just the push event*.
**Expected output:** a green tick under *Recent Deliveries*.
**Verification:** the delivery's response code is 200.
**Troubleshooting:** 11 (Jenkins unreachable/HTTP 403/302 - check the trailing slash and HTTPS).

### STEP 28 - Push code
**Purpose:** Trigger the CI/CD pipeline from a push.
**Command:**
```bash
git add .
git commit -m "Update ScoutOps application"
git push origin main
```
**Expected output:** the push succeeds and a Jenkins build starts within seconds.
**Verification:** a new build number appears on the job page.
**Troubleshooting:** 10.

### STEP 29 - Verify the Jenkins pipeline
**Purpose:** Confirm every pipeline stage succeeded.
**Command:** open the job in Jenkins (`https://<jenkins-domain>/job/scoutops/`) → latest build → **Console Output**, or from the agent:
```bash
docker images scoutops
```
**Expected output:** stages Checkout → Install Dependencies → Run Tests → Build Docker Image → Validate → Deploy → Health Check all green; console ends with `ScoutOps 1.0.<N> built, deployed and healthy.`
**Verification:** Stage View shows seven green stages.
**Troubleshooting:** 8, 11, 12.

### STEP 30 - Verify the production deployment
**Purpose:** Confirm the Jenkins-deployed version is what is actually running.
**Command:**
```bash
docker ps --filter name=scoutops
docker inspect -f '{{.Config.Image}}' scoutops-app
curl http://localhost:3000/health/db
```
**Expected output:** `scoutops-app` and `scoutops-postgres` healthy; image `scoutops:1.0.<N>`; `database":"UP"`.
**Verification:** the production database is **separate** from the local one, so it starts with the demo data only (issues you created in Steps 14-17 live in the local volume).

### STEP 31 - Controlled CI failure test
**Purpose:** Prove a failing test stops the pipeline before deployment.
**Command:** follow [18.1](#181-controlled-ci-failure-test).
**Expected output:** build red at **Run Tests**; later stages skipped; after the revert push, a green build.
**Verification:** `docker inspect -f '{{.Config.Image}}' scoutops-app` shows the version of the last **green** build, never one from the failing build.

### STEP 32 - Controlled monitoring failure test
**Purpose:** Prove Prometheus detects an outage and raises an alert.
**Command:** follow [18.2](#182-monitoring-failure-test) (`docker stop scoutops-app` ... `docker start scoutops-app`).
**Expected output:** target DOWN, then alert `ScoutOpsApplicationDown` pending → firing; after the restart the target is UP and the alert clears.
**Verification:** `up{job="scoutops"}` returns `0`, then `1`.

### STEP 33 - Backup / recovery test
**Purpose:** Prove backups can be restored, safely, into a scratch database.
**Command:** follow [18.3](#183-backup-and-recovery-test).
**Expected output:** the `Backup test issue` row appears in the scratch database.
**Verification:** scratch database dropped; production data untouched.

### STEP 34 - Rollback test
**Purpose:** Prove you can return to the previous version.
**Command:**
```bash
./scripts/rollback.sh --dry-run
SCOUTOPS_VERSION=1.0.1 ./scripts/deploy.sh      # deploy a second, newer version (1.0.0 stays available)
./scripts/rollback.sh
```
**Expected output:** the dry run reports the plan; the deploy prints version `1.0.1`; the rollback prints `Current version: 1.0.1`, `Rollback target: 1.0.0`, health responses, and `ROLLBACK SUCCEEDED: 1.0.1 -> 1.0.0`.
**Verification:**
```bash
docker inspect -f '{{.Config.Image}}' scoutops-app     # scoutops:1.0.0
curl http://localhost:3000/health
```
(If Jenkins already deployed `1.0.<N>` builds, use `./scripts/rollback.sh` once or pass an explicit version.)
**Troubleshooting:** "No version older than ..." means only one versioned image exists; deploy a second version first.

### STEP 35 - Cleanup
**Purpose:** Reclaim Docker resources without touching database data.
**Command:**
```bash
./scripts/cleanup.sh --dry-run
./scripts/cleanup.sh
```
**Expected output:** the plan, then `Total reclaimed space: ...` lines from Docker and `Cleanup finished. Database volumes were not touched.`
**Verification:** `docker volume ls` still lists `scoutops_prod_pgdata` (and `scoutops_pgdata`); `docker ps` still shows the running stack.
To stop everything you started (volumes are kept):
```bash
SCOUTOPS_NETWORK=scoutops-prod-net docker compose --env-file .env -f monitoring/docker-compose.monitoring.yml down
docker compose -f docker-compose.prod.yml down
```

## 20. Troubleshooting

### Diagnostic toolbox

```bash
docker ps                                   # running containers
docker ps -a                                # including stopped/crashed ones
docker logs --tail=100 scoutops-app         # container logs (also: scoutops-postgres, scoutops-prometheus, scoutops-grafana)
docker inspect -f '{{json .State.Health}}' scoutops-app     # health check history
docker compose ps                           # local stack  (add -f docker-compose.prod.yml for production)
docker compose logs scoutops-app            # compose logs for one service
docker network ls                           # networks
docker volume ls                            # volumes (database data!)
docker system df                            # disk used by Docker
ss -tulpn | grep -E ':(3000|3001|9090|5432)\b'   # who is listening on which port
curl -i http://localhost:3000/health        # HTTP-level check
systemctl status docker                     # Docker daemon state
journalctl -u docker --no-pager -n 50       # Docker daemon logs (use -u jenkins for Jenkins)
```

### 1. Docker daemon not running
*Symptom:* `Cannot connect to the Docker daemon at unix:///var/run/docker.sock`.
*Diagnose:* `systemctl status docker`, `journalctl -u docker -n 50`.
*Fix:* `sudo systemctl enable --now docker`.

### 2. Port already in use
*Symptom:* `Bind for 0.0.0.0:3000 failed: port is already allocated` (also 3001/9090).
*Diagnose:* `ss -tulpn | grep :3000`, `docker ps` (the local and production stacks use the same port and container names).
*Fix:* stop the other stack (`docker compose down` or `docker compose -f docker-compose.prod.yml down`), or set another host port with `APP_PORT=3100` in `.env`. Remember to use that port in every `curl`.

### 3. PostgreSQL connection refused
*Symptom:* `/health/db` returns 503; logs show `ECONNREFUSED`.
*Diagnose:* `docker compose ps` (is `postgres` healthy?), `docker compose logs postgres`. When running Node on the host, `DB_HOST` must be `localhost`, not `postgres`.
*Fix:* wait for the health check, start it (`docker compose up -d postgres`), or correct `DB_HOST`/`DB_PORT`.

### 4. PostgreSQL authentication failure
*Symptom:* `password authentication failed for user "scoutops_user"`.
*Diagnose:* compare `DB_USER`/`DB_PASSWORD` in `.env` with what the volume was created with. PostgreSQL only applies `POSTGRES_PASSWORD` the **first** time the volume is initialized; changing `.env` later does not change the stored password.
*Fix:* set the old password back, **or** change it inside the database: `docker compose exec postgres psql -U scoutops_user -d scoutops -c "ALTER USER scoutops_user PASSWORD '<new>';"`, **or** (data loss, local only) `docker compose down -v` and start again.

### 5. Application container exits
*Symptom:* `scoutops-app` shows `Exited` or restarts repeatedly.
*Diagnose:* `docker ps -a`, `docker logs scoutops-app`, `docker inspect -f '{{.State.ExitCode}}' scoutops-app`.
*Fix:* typical causes are a missing/incorrect variable (16), unreachable database (3, 4) or a code error shown in the logs.

### 6. Health check failure
*Symptom:* status `(unhealthy)` or `starting` for a long time; `deploy.sh` reports `did not become healthy`.
*Diagnose:* `docker inspect -f '{{json .State.Health}}' scoutops-app`, `docker exec scoutops-app node -e "fetch('http://127.0.0.1:3000/health').then(r=>console.log(r.status))"`, `docker logs scoutops-app`.
*Fix:* fix the underlying error (usually 3/4/5); the app container waits for a healthy database before starting.

### 7. Docker permission denied
*Symptom:* `permission denied while trying to connect to the Docker daemon socket`.
*Diagnose:* `groups` (is `docker` listed?), `ls -l /var/run/docker.sock`.
*Fix:* `sudo usermod -aG docker "$USER"` then log out and in (or `newgrp docker`).

### 8. Jenkins Docker permission denied
*Symptom:* pipeline fails with the same message as above, in the Build/Deploy stage.
*Diagnose:* on the agent `sudo -u jenkins docker ps`; `id jenkins`.
*Fix:* `sudo usermod -aG docker jenkins`, then **disconnect and relaunch the agent** (group membership is read at login). Confirm the build runs on the agent that has Docker (label `docker`).

### 9. Jenkins agent offline
*Symptom:* the node is greyed out; builds wait with "Waiting for next available executor" / label `docker` not found.
*Diagnose:* node page → *Log*; from the controller `ssh -i <key> jenkins@<agent-host> 'java -version'`; `ss -tulpn | grep :22` and the firewall/security group on the agent.
*Fix:* install Java on the agent, correct the SSH credential (`deployment-ssh-key`) and host-key verification, open TCP/22 from the controller, make sure the node's label is exactly `docker`, then **Relaunch agent**.

### 10. GitHub authentication failure
*Symptom:* Checkout fails: `Authentication failed`, `Permission denied (publickey)` or `Repository not found`.
*Diagnose:* `git ls-remote <repository-url>` as the same user; in Jenkins re-test the credential.
*Fix:* GitHub no longer accepts account passwords for Git over HTTPS: use a personal access token (repo scope) in `github-credentials`, or an SSH deploy key with the SSH URL. Check the repository URL and branch (`*/main`).

### 11. Jenkins pipeline failure
*Symptom:* red build.
*Diagnose:* open **Console Output** and find the **first** red stage; the later ones are skipped by design. For webhook problems check GitHub → Webhooks → *Recent Deliveries*.
*Fix:* by stage: Checkout → (10); Install/Test → (12); Build → (7/8); Validate → a variable is missing from the `scoutops-env-file` secret file (16); Deploy → (2, 3, 4, 5, 6); webhook 403/404/302 → use `https://<jenkins-domain>/github-webhook/` with the trailing slash.

### 12. npm test failure
*Symptom:* `npm test` exits non-zero; `npm ci` complains about the lockfile.
*Diagnose:* read the failing test name and diff in the output; `node --version` (needs ≥ 20); run `npx jest --runInBand` for detail.
*Fix:* fix the code or test. For lockfile errors run `npm install` once locally and commit the updated `package-lock.json`. Tests mock the database, so a missing PostgreSQL is never the cause.

### 13. Prometheus target DOWN
*Symptom:* Status → Targets shows `scoutops` DOWN with `connection refused` or `no such host`.
*Diagnose:* `docker ps` (is `scoutops-app` running and healthy?), `docker network ls`, `docker network inspect scoutops-net` (or `scoutops-prod-net`) - both `scoutops-app` and `scoutops-prometheus` must be listed, `docker exec scoutops-prometheus wget -qO- http://scoutops-app:3000/health`.
*Fix:* start the app; if Prometheus joined the wrong network, recreate it with the right one: `SCOUTOPS_NETWORK=scoutops-prod-net docker compose --env-file .env -f monitoring/docker-compose.monitoring.yml up -d --force-recreate`.

### 14. Grafana datasource failure
*Symptom:* *Save & test* fails, or the Prometheus datasource is missing.
*Diagnose:* `docker logs scoutops-grafana`, `docker exec scoutops-grafana ls /etc/grafana/provisioning/datasources`, check `docker ps` shows `scoutops-prometheus` healthy.
*Fix:* the URL must be `http://prometheus:9090` (Docker service name, not `localhost`); recreate with `docker compose --env-file .env -f monitoring/docker-compose.monitoring.yml up -d --force-recreate grafana`. Forgot the admin password? It is `GRAFANA_ADMIN_PASSWORD` from `.env` **at first start**; afterwards reset with `docker exec -it scoutops-grafana grafana cli admin reset-admin-password '<new>'`.

### 15. Shell script permission denied
*Symptom:* `bash: ./scripts/deploy.sh: Permission denied`.
*Fix:* `chmod +x scripts/*.sh` (zip/Windows copies can drop the executable bit); or run `bash scripts/deploy.sh`. Commit the mode with `git update-index --chmod=+x scripts/*.sh`.

### 16. Missing environment variable
*Symptom:* Compose prints `required variable DB_PASSWORD is missing a value`, or a script says `DB_PASSWORD is not set`.
*Diagnose:* `ls -l .env`, `grep -E '^(DB_|APP_|GRAFANA_)' .env | sed 's/=.*/=.../'`.
*Fix:* `cp .env.example .env` and fill it in. Monitoring needs `--env-file .env`. Jenkins needs the `.env` content in the `scoutops-env-file` secret file.

### 17. Database initialization failure
*Symptom:* app starts but queries fail with `relation "issues" does not exist`; `docker compose logs postgres` shows no `init.sql` execution.
*Cause:* `db/init.sql` only runs when the data volume is **empty**. If the volume was created earlier (e.g. by a failed first start), it is skipped.
*Fix (safe, keeps data):* `docker compose exec -T postgres psql -U scoutops_user -d scoutops < db/init.sql` (idempotent). *Fix (destroys local data):* `docker compose down -v && docker compose up -d --build`. SQL errors are shown in `docker compose logs postgres`.

### 18. Docker network issue
*Symptom:* `network scoutops-prod-net not found`, `no such host`, containers cannot reach each other, `Pool overlaps with other one`.
*Diagnose:* `docker network ls`, `docker network inspect <name>`, `docker compose ps`.
*Fix:* the monitoring stack needs the application stack running first (it uses an **external** network). Match the network to the stack (`SCOUTOPS_NETWORK`). Remove unused networks with `docker network prune` (or `./scripts/cleanup.sh`). Restart the Docker daemon if DNS inside containers fails (`sudo systemctl restart docker`).

## 21. Security

* **Never commit `.env`.** Only `.env.example` (placeholders) belongs in Git. `git status` must never list `.env`.
* **Never hardcode secrets.** No credentials are in the source, compose files, scripts or Jenkinsfile; everything comes from `.env`/the environment.
* **Use Jenkins credentials.** Production configuration is injected from the `scoutops-env-file` secret file and deleted when the build ends; GitHub access uses `github-credentials`.
* **Parameterized SQL only.** Every query uses `$1, $2...` placeholders; filters and ids are validated against allow-lists/integers before use.
* **Non-root containers.** The app runs as the `node` user; in production it also has a read-only filesystem, no Linux capabilities and `no-new-privileges`.
* **Least privilege.** Use a dedicated `scoutops_user` (not `postgres`); a dedicated `jenkins` OS user. Remember `docker` group membership is root-equivalent.
* **Protect production database credentials.** Strong unique `DB_PASSWORD`; `.env` mode `600` (`chmod 600 .env`); backups are created mode `600` in a `700` directory - store copies off-host and encrypted.
* **Restrict exposed ports.** PostgreSQL is never published; Prometheus and Grafana bind to `127.0.0.1` (reach them through an SSH tunnel). On EC2 open only 22 (from your IP) and 3000 (or 80/443 via a reverse proxy) in the security group; consider blocking public access to `/metrics` at the proxy.
* **Secure SSH.** Key-based login only (`PasswordAuthentication no`, `PermitRootLogin no` in `/etc/ssh/sshd_config`), ed25519 keys, `Known hosts` verification for Jenkins agents.
* **Do not store private keys in Git.** Keep keys in Jenkins credentials or `~/.ssh` with mode `600`.
* **Authentication is out of scope.** The ScoutOps API has no login: anyone who can reach it can create, edit and delete issues. Put it behind your campus network, VPN or an authenticating reverse proxy before exposing it publicly, and add authentication/roles before real use.
* **Keep things updated.** Rebuild images regularly for base-image security fixes and run `npm audit`.

## 22. License

MIT - see [LICENSE](LICENSE). The copyright line reads "ScoutOps contributors"; replace it with your own name or organization if you publish the project.
