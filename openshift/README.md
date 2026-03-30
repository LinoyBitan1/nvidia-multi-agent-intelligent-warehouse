# Deploying NVIDIA Multi-Agent Intelligent Warehouse on Red Hat OpenShift AI

This guide covers deploying the [NVIDIA Multi-Agent Intelligent Warehouse (WOSA)](https://github.com/NVIDIA-AI-Blueprints/Multi-Agent-Intelligent-Warehouse) blueprint on Red Hat OpenShift AI (RHOAI) using a single Helm command. All OpenShift-specific adaptations are applied at install time - no post-deploy patching is required.

## Table of Contents

- [What Gets Deployed](#what-gets-deployed)
- [Tested Hardware](#tested-hardware)
- [Prerequisites](#prerequisites)
- [Configuration Reference](#configuration-reference)
- [Deployment](#deployment)
- [Verification](#verification)
- [Accessing the Application](#accessing-the-application)
- [Database Initialisation and Data Seeding](#database-initialisation-and-data-seeding)
- [Monitoring](#monitoring)
- [Upgrading](#upgrading)
- [Uninstalling](#uninstalling)
- [Known Limitations](#known-limitations)
- [Security Considerations](#security-considerations)
- [OpenShift-Specific Challenges and Solutions](#openshift-specific-challenges-and-solutions)
- [Deployment Files](#deployment-files)

---

## What Gets Deployed

This Helm chart deploys the following components:

### Application Services


| Component    | Description                         | Port | Purpose                                                                                                                                                                          |
| ------------ | ----------------------------------- | ---- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Backend**  | FastAPI-based orchestration service | 8001 | Central coordinator using LangGraph for multi-agent workflows (operations, safety, equipment, forecasting, document processing), REST API, time-series forecasting, RAG pipeline |
| **Frontend** | React-based web UI                  | 8080 | Dashboards for inventory, tasks, safety incidents, equipment telemetry, chat interface, training management                                                                      |
| **Nginx**    | Reverse proxy                       | 8080 | Routes `/api/` requests to backend, all other requests to frontend                                                                                                               |


### Infrastructure Services


| Component       | Description                         | Port  | Purpose                                                                                                |
| --------------- | ----------------------------------- | ----- | ------------------------------------------------------------------------------------------------------ |
| **TimescaleDB** | Time-series relational database     | 5432  | Primary database for inventory, tasks, safety incidents, equipment telemetry, forecasts, user accounts |
| **Redis**       | In-memory data store                | 6379  | Caching and session storage                                                                            |
| **Milvus**      | Vector database                     | 19530 | Stores document embeddings for RAG similarity search                                                   |
| **Kafka**       | Event streaming (KRaft single-node) | 9092  | Event streaming for telemetry and notifications                                                        |
| **etcd**        | Key-value store                     | 2379  | Metadata storage for Milvus                                                                            |
| **MinIO**       | Object storage                      | 9000  | Blob storage for Milvus data                                                                           |


### Additional Resources Created

- **ConfigMap**: Nginx reverse proxy configuration
- **Secret**: API keys (NVIDIA, embedding, guardrails, OCR) and database credentials
- **PersistentVolumeClaims**: Storage for each stateful service (6 PVCs, 38 Gi total)
- **Services**: ClusterIP services for internal communication
- **Route**: OpenShift Route for external HTTPS access (edge TLS termination)
- **ServiceAccount**: `wosa-sa` with `system:image-puller` only
- **NetworkPolicy**: Default-deny + allowlists for network segmentation (optional)
- **Helm hook Jobs**: DB schema migrations, user creation, demo data seeding
- **Monitoring** (optional): ServiceMonitors, PrometheusRule, AlertmanagerConfig, Grafana - see [Monitoring](#monitoring)

---

## Tested Hardware

This deployment was validated on the following cluster configuration:

**Cluster:** OpenShift 4.19 on AWS (us-east-2)

### Worker nodes (non-GPU)

| Instance Type | vCPU | RAM | Count | Role |
|---------------|------|-----|-------|------|
| `m6i.2xlarge` | 8 | 32 GiB | 1 | All WOSA pods except Milvus GPU (backend, frontend, nginx, TimescaleDB, Redis, Kafka, etcd, MinIO, Grafana) |

### GPU node (optional - Milvus GPU mode only)

| Instance Type | GPU | VRAM | vCPU | RAM | Count | Role |
|---------------|-----|------|------|-----|-------|------|
| `g6e.2xlarge` | 1x NVIDIA L40S | 46 GB | 8 | 64 GiB | 1 | Milvus vector database (GPU-accelerated index) |

All pods run on a single worker node by default. With `MILVUS_GPU_ENABLED=true`, Milvus schedules onto a GPU node while all other pods remain on the worker.

### Minimum Requirements (Cloud NIMs)

| Resource | Requirement |
|----------|-------------|
| CPU | 10 cores |
| RAM | 18 GiB |
| Storage | 38 Gi |
| GPU | Not required |
| Network | Stable internet for API calls |

---

## Prerequisites

- OpenShift CLI (`oc`) 4.12+ installed and authenticated with the cluster
- Helm 3.x installed
- NGC API key from [NGC](https://org.ngc.nvidia.com/setup/api-keys) or [build.nvidia.com](https://build.nvidia.com/) (requires NVIDIA AI Enterprise license)
- Sufficient cluster resources (see [Tested Hardware](#tested-hardware))

**Additional prerequisites for Milvus GPU mode** (`MILVUS_GPU_ENABLED=true`):

- NVIDIA GPU Operator installed on the cluster and `nvidia.com/gpu` resource is allocatable
- GPU nodes are ready: `oc get nodes -l nvidia.com/gpu`
- GPU node taint keys identified: `oc describe node <gpu-node> | grep -A5 Taints`

---

## Configuration Reference

All options are set via environment variables before calling the deploy script.

### Required Variables


| Variable         | Description                                    |
| ---------------- | ---------------------------------------------- |
| `NVIDIA_API_KEY` | NVIDIA API key for LLM and embedding inference |
| `NAMESPACE`      | OpenShift namespace to deploy into             |


### Optional Variables


| Variable                  | Default                                    | Description                                                                  |
| ------------------------- | ------------------------------------------ | ---------------------------------------------------------------------------- |
| `SKIP_BUILD`              | `false`                                    | `true` skips image build (deploy only, uses existing images)                 |
| `BACKEND_IMAGE`           | internal registry image                    | Override backend image (e.g. `quay.io/myorg/wosa-backend:1.0.0`)             |
| `FRONTEND_IMAGE`          | internal registry image                    | Override frontend image (e.g. `quay.io/myorg/wosa-frontend:1.0.0`)           |
| `LLM_MODEL`               | `nvidia/llama-3.3-nemotron-super-49b-v1` | LLM model identifier                                                         |
| `LLM_NIM_URL`             | `https://integrate.api.nvidia.com/v1`      | LLM endpoint (cloud default)                                                 |
| `DEFAULT_ADMIN_PASSWORD`  | `changeme`                                 | Admin password (also used by `user-init-job`)                                |
| `STORAGE_CLASS`           | cluster default                            | StorageClass for PVCs                                                        |
| `HELM_RELEASE`            | `wosa`                                     | Helm release name                                                            |
| `DEMO_DATA_ENABLED`       | `false`                                    | `true` seeds demo inventory, tasks, incidents, and telemetry                 |
| `DEMAND_HISTORY_ENABLED`  | `false`                                    | `true` seeds 180 days of demand data (required for Forecasting page)         |
| `MONITORING_ENABLED`      | `false`                                    | `true` deploys ServiceMonitor, PrometheusRule, Grafana Operator + dashboards |
| `GRAFANA_ADMIN_PASSWORD`  | `changeme`                                 | Grafana admin password                                                       |
| `MILVUS_GPU_ENABLED`      | `false`                                    | `true` switches Milvus to GPU image and requests `nvidia.com/gpu`            |
| `MILVUS_GPU_TOLERATIONS`  | (none)                                     | Comma-separated GPU node taint keys (e.g. `g6-gpu,p4-gpu`)                   |
| `LLM_CLIENT_TIMEOUT`      | `120`                                      | HTTP timeout (seconds) for each LLM API call                                 |
| `GUARDRAILS_TIMEOUT`      | `10`                                       | Timeout for NeMo Guardrails API calls                                        |


---

## Deployment

### Step 1: Build and push the application images

```bash
NAMESPACE=wosa ./openshift/build-openshift.sh
```

The script creates `BuildConfig` resources using `openshift/Dockerfile.backend` and `openshift/Dockerfile.frontend`, streaming the local source into the cluster. The resulting images are available at:

```
image-registry.openshift-image-registry.svc:5000/wosa/wosa-backend:latest
image-registry.openshift-image-registry.svc:5000/wosa/wosa-frontend:latest
```

Alternatively, build locally and push to an external registry:

```bash
docker build -f openshift/Dockerfile.backend -t quay.io/myorg/wosa-backend:1.0.0 .
docker build -f openshift/Dockerfile.frontend -t quay.io/myorg/wosa-frontend:1.0.0 .
docker push quay.io/myorg/wosa-backend:1.0.0
docker push quay.io/myorg/wosa-frontend:1.0.0
```

### Step 2: Deploy

```bash
NVIDIA_API_KEY=nvapi-... \
NAMESPACE=wosa \
./openshift/deploy-openshift.sh
```

The script will:

1. Create the namespace if it does not exist
2. Build images (unless `SKIP_BUILD=true`)
3. Load SQL migration files via `--set-file`
4. Load Grafana dashboards via `--set-file` (if `MONITORING_ENABLED=true`)
5. Parse image overrides (if `BACKEND_IMAGE` or `FRONTEND_IMAGE` is set)
6. Build Milvus GPU toleration args (if `MILVUS_GPU_TOLERATIONS` is set)
7. Enable demo data seeding (if `DEMO_DATA_ENABLED=true`)
8. Enable demand history seeding (if `DEMAND_HISTORY_ENABLED=true`)
9. Run `helm upgrade --install` with all overrides (Helm hooks run DB migrations and create users automatically)
10. Wait for all Deployments to be ready
11. Print the Route URL and pod status

**With all optional features:**

```bash
NVIDIA_API_KEY=nvapi-... \
NAMESPACE=wosa \
DEMO_DATA_ENABLED=true \
DEMAND_HISTORY_ENABLED=true \
MONITORING_ENABLED=true \
MILVUS_GPU_ENABLED=true \
MILVUS_GPU_TOLERATIONS=nvidia.com/gpu \
./openshift/deploy-openshift.sh
```

- `DEMO_DATA_ENABLED` - seeds inventory, tasks, safety incidents, equipment telemetry
- `DEMAND_HISTORY_ENABLED` - seeds 180 days of demand history (required for Forecasting page)
- `MONITORING_ENABLED` - deploys ServiceMonitor, PrometheusRule, Grafana Operator + dashboards
- `MILVUS_GPU_ENABLED` - switches Milvus to GPU image and requests `nvidia.com/gpu`
- `MILVUS_GPU_TOLERATIONS` - comma-separated GPU node taint keys for scheduling. To find them:
  ```bash
  oc describe node <gpu-node> | grep -A5 Taints
  ```

To skip the image build and use pre-built images:

```bash
NVIDIA_API_KEY=nvapi-... \
NAMESPACE=wosa \
SKIP_BUILD=true \
BACKEND_IMAGE=quay.io/myorg/wosa-backend:1.0.0 \
FRONTEND_IMAGE=quay.io/myorg/wosa-frontend:1.0.0 \
./openshift/deploy-openshift.sh
```

---

## Verification

After the script exits, verify all pods are running:

```bash
oc get pods -n wosa
```

All pods should be `Running` with `READY 1/1` (9 pods by default, more with monitoring enabled). Infrastructure pods (TimescaleDB, Milvus) may take 1-2 minutes for readiness probes to pass.

Verify services and route:

```bash
oc get svc -n wosa
oc get route -n wosa
```

Monitor specific pod progress:

```bash
oc logs -f deployment/wosa-backend -n wosa
oc logs -f deployment/wosa-timescaledb -n wosa
```

---

## Accessing the Application

The deploy script prints the application URL at the end of the run:

```
=== Done ===
Application URL: https://wosa-wosa.apps.cluster.example.com
```

Open the printed URL in a browser.

---

## Database Initialisation and Data Seeding

Schema migrations and post-deploy setup run automatically as Helm hooks on first install. The `helm.sh/hook-weight` annotation controls execution order - lower weight runs first, and Helm waits for each Job to complete before starting the next.


| Hook Job          | Weight | Trigger                    | What it does                                                               |
| ----------------- | ------ | -------------------------- | -------------------------------------------------------------------------- |
| `db-init-job`     | 0      | post-install, post-upgrade | Applies all SQL migrations against TimescaleDB                             |
| `user-init-job`   | 1      | post-install               | Creates `admin` and `user` accounts                                        |
| `demo-data-job`   | 2      | post-install               | Seeds 35 inventory items, 8 tasks, 8 safety incidents, equipment telemetry |
| `demo-demand-job` | 3      | post-install               | Seeds 180 days of demand history for the Forecasting page                  |


**Always enabled:** `db-init-job`, `user-init-job` (required - without them, the database has no schema and login is impossible).

**Disabled by default:** `demo-data-job` (`DEMO_DATA_ENABLED=true`), `demo-demand-job` (`DEMAND_HISTORY_ENABLED=true`).

The `db-init-job` runs on every `post-upgrade` to safely apply new migrations (`CREATE TABLE IF NOT EXISTS`). All other jobs only run on `post-install` to avoid re-seeding data.

---

## Monitoring

When `MONITORING_ENABLED=true`, the chart deploys:

1. **ServiceMonitors** (4) - scrape targets for OpenShift's built-in Prometheus:
  - Backend `/api/v1/metrics` (port 8001)
  - PostgreSQL exporter sidecar (port 9187)
  - Redis exporter sidecar (port 9121)
  - Milvus metrics (port 9091)
2. **PrometheusRule** - 14 alert rules covering API health, database availability, high latency, memory usage, safety incidents, task completion
3. **AlertmanagerConfig** - alert routing with email and webhook receivers
4. **Grafana Operator** - installed namespace-scoped via OLM
5. **Grafana instance** - with an OpenShift Route (edge TLS) and Thanos Querier datasource
6. **GrafanaDashboard CRs** - 3 pre-built dashboards (Overview, Operations, Safety & Compliance)

### Prerequisite (cluster-admin, one-time)

Enable user workload monitoring on the cluster:

```bash
oc apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
EOF
```

### Access Grafana

```bash
oc get route -n wosa -l app.kubernetes.io/component=monitoring
# Default credentials: admin / changeme
```

### Monitoring Architecture

```
OpenShift Cluster
├── openshift-monitoring namespace (cluster-admin managed)
│   ├── Prometheus (scrapes ServiceMonitors)
│   ├── Alertmanager (routes alerts via AlertmanagerConfig)
│   └── Thanos Querier (federated query endpoint)
│
└── wosa namespace (user managed)
    ├── ServiceMonitor × 4 (backend, postgres-exporter, redis-exporter, milvus)
    ├── PrometheusRule (14 alert rules)
    ├── AlertmanagerConfig (email + webhook routing)
    ├── Grafana Operator (OLM, namespace-scoped)
    ├── Grafana instance + Route
    ├── GrafanaDatasource → thanos-querier.openshift-monitoring:9091
    └── GrafanaDashboard × 3 (overview, operations, safety)
```

No Prometheus or Alertmanager pods are deployed in the user namespace - OpenShift's built-in monitoring stack handles collection and alerting. Only Grafana is deployed for visualization.

---

## Upgrading

```bash
# Re-run deploy script (handles helm upgrade automatically)
NVIDIA_API_KEY=nvapi-... NAMESPACE=wosa ./openshift/deploy-openshift.sh

# Or upgrade directly with Helm
helm upgrade wosa openshift/helm/ --namespace wosa --reuse-values \
  --set backend.env.llmModel=nvidia/llama-3.3-nemotron-super-49b-v1
```

### Scaling

Application services (backend, frontend, nginx) are stateless and can be scaled independently:

```bash
helm upgrade wosa openshift/helm/ --namespace wosa --reuse-values \
  --set backend.replicas=2 \
  --set frontend.replicas=2 \
  --set nginx.replicas=2
```

Infrastructure services use RWO PVCs and should remain at 1 replica.

### Rollback

```bash
helm history wosa --namespace wosa
helm rollback wosa 1 --namespace wosa
```

---

## Uninstalling

Use the uninstall script - it cleans up OLM-managed Grafana resources, build artifacts, PVCs, and the Helm release in one step:

```bash
NAMESPACE=wosa ./openshift/uninstall-openshift.sh
```

To keep persistent data (PVCs) for a future redeploy:

```bash
NAMESPACE=wosa KEEP_PVCS=true ./openshift/uninstall-openshift.sh
```

> **Note:** Use the uninstall script instead of `helm uninstall` - it also cleans up OLM-managed Grafana resources, PVCs, and build artifacts.

- `NAMESPACE` (required) - OpenShift namespace
- `HELM_RELEASE` (default: `wosa`) - Helm release name
- `KEEP_PVCS` (default: `false`) - `true` keeps PVCs (preserves persistent data for redeploy)

---

## Known Limitations

### RAPIDS GPU Forecasting

**Problem:** The upstream `Dockerfile.rapids` depends on `nvcr.io/nvidia/rapidsai/rapidsai:24.02`, which was removed from NGC. The RAPIDS GPU training path cannot be built.

**Workaround:** Training works without RAPIDS - the backend automatically falls back to CPU-based scikit-learn models (RandomForest, XGBoost, GradientBoosting). All 38 SKUs train and forecast successfully on CPU. Can be implemented once the upstream base image is fixed or fully supported in the codebase.

### Milvus GPU Acceleration

**Problem:** We implemented full GPU support for Milvus in the Helm chart (GPU image, CUDA env vars, resource requests, tolerations). However, the upstream NVIDIA codebase never wires it - `gpu_hybrid_retriever.py` exists but no agent imports it. All agents use the CPU `IVF_FLAT` index.

**Workaround:** Milvus runs on CPU with `IVF_FLAT` index. The Helm chart supports `MILVUS_GPU_ENABLED=true` at deploy time, but has no effect until upstream imports `gpu_hybrid_retriever`. Default: `milvus.gpu.enabled: false`.

### Monitoring Dashboard Metrics Coverage

**Problem:** The upstream application defines business-logic Prometheus metrics and collector methods in `src/api/services/monitoring/metrics.py` but only calls the HTTP middleware metrics. Dashboard panels for infrastructure (health, API rates, resource usage) show real data; business-logic panels (tasks, equipment, safety, environmental) show "No data" or `0`.

**Current state:** Dashboards, alert rules, and ServiceMonitors are aligned 1:1 with the upstream metric definitions and will display data once the application calls the existing `MetricsCollector` methods from its business logic.

---

## Security Considerations

### Secrets Management

The Helm chart creates secrets for:

- NVIDIA API keys (LLM, Embedding, Guardrails, OCR, Retriever, Parse, VL)
- JWT secret key
- TimescaleDB credentials (user, password, database)
- MinIO credentials (access key, secret key)
- Default user password

For production, consider:

- External secret management (HashiCorp Vault, AWS Secrets Manager)
- OpenShift Secrets Store CSI Driver
- Sealed Secrets for GitOps workflows

### Network Policies

The Helm chart includes NetworkPolicies that:

- Allow ingress from OpenShift ingress controller
- Allow internal pod-to-pod communication within the namespace
- Allow egress to external NVIDIA API endpoints (port 443)
- Allow Prometheus scrapes from `openshift-monitoring` and `openshift-user-workload-monitoring` (when `monitoring.enabled`)

### Pod Security

All pods run under OpenShift's default `restricted-v2` SCC - no `anyuid` or elevated SCC is required:

- Non-root user execution (random UID, GID 0)
- Dropped capabilities (`drop: [ALL]`)
- Seccomp profile enforcement (`RuntimeDefault`)

```yaml
securityContext:
  runAsNonRoot: true
  seccompProfile:
    type: RuntimeDefault

containerSecurityContext:
  allowPrivilegeEscalation: false
  capabilities:
    drop:
      - ALL
```

---

## OpenShift-Specific Challenges and Solutions

The upstream WOSA blueprint targets Docker Compose on a developer workstation. Running on OpenShift required solving compatibility issues across security contexts, storage permissions, network topology, and build processes. All fixes are applied at install time by `deploy-openshift.sh` and the Helm chart - no post-deploy patching is required.

---

### 1. Storage Permissions

OpenShift assigns a random UID (e.g. `1000660000`) to containers rather than the UID defined in the image. Because this UID does not own the container's writable directories, services fail on startup with permission errors.

**Affected Services:**

- **backend** - Document upload directory (`/app/data/uploads`) and forecast output directory (`/app/output`)
- **nginx** - Cache and temp directories (`/var/cache/nginx`, `/var/run`, `/tmp`)
- **kafka** - KRaft config directory (`/opt/kafka/config`) and GC/server logs directory (`/opt/kafka/logs`)
- **demo-demand-job** - Script writes `historical_demand_summary.json` to cwd (`/app/output` + `workingDir`)
- **milvus** - PVC subdirectories (`data/`, `logs/`, `wal/`, `rdb_data/`, `rdb_data_meta_kv/`) created by `initContainer`; explicit path env vars redirect Milvus internals to the PVC

**Solution:** Mount an `emptyDir` volume over each problematic path. OpenShift automatically sets GID 0 with group-write permissions on `emptyDir` volumes, making them writable by any assigned UID.

```yaml
# backend
volumeMounts:
  - name: uploads
    mountPath: /app/data/uploads
  - name: forecast-output
    mountPath: /app/output
volumes:
  - name: uploads
    emptyDir: {}
  - name: forecast-output
    emptyDir: {}

# nginx
volumeMounts:
  - name: nginx-cache
    mountPath: /var/cache/nginx
  - name: nginx-run
    mountPath: /var/run
  - name: nginx-tmp
    mountPath: /tmp
volumes:
  - name: nginx-cache
    emptyDir: {}
  - name: nginx-run
    emptyDir: {}
  - name: nginx-tmp
    emptyDir: {}

# kafka
volumeMounts:
  - name: config
    mountPath: /opt/kafka/config
  - name: logs
    mountPath: /opt/kafka/logs
volumes:
  - name: config
    emptyDir: {}
  - name: logs
    emptyDir: {}

# demo-demand-job
workingDir: /app/output
volumeMounts:
  - name: scratch
    mountPath: /app/output
volumes:
  - name: scratch
    emptyDir: {}
```

---

### 2. `lost+found` on Block Storage

Block-storage PVCs contain a `lost+found` directory at the mount root. Services that use the PVC root as their data directory fail on startup.

**Affected Services:**

- **timescaledb** - `initdb` refuses a non-empty data directory (`/var/lib/postgresql/data`)
- **kafka** - KRaft rejects `lost+found` as an invalid topic-partition (`/var/lib/kafka/data`)

**Solution:** Point each service's data path to a subdirectory within the PVC mount:

```yaml
# timescaledb
env:
  - name: PGDATA
    value: /var/lib/postgresql/data/pgdata
volumeMounts:
  - name: data
    mountPath: /var/lib/postgresql/data

# kafka
env:
  - name: KAFKA_LOG_DIRS
    value: /var/lib/kafka/data/kraft-logs
volumeMounts:
  - name: data
    mountPath: /var/lib/kafka/data
```

---

### 3. Dockerfile Fixes

The upstream Dockerfiles rely on Docker Compose bind-mounting the entire repository into the container (`volumes: [".:/app"]`). Without bind mounts, the images are missing required files and have dependency issues.

**Affected files:**

- `openshift/Dockerfile.backend`
- `openshift/Dockerfile.frontend`

**Solution:**

**Backend** - three issues fixed:

1. **Missing files**: Added explicit `COPY` directives for agent configs (`data/config/agents/`), SQL migrations (`data/postgres/`), scripts, and `README.md` (needed by the project root finder in `agent_config.py`):
   ```dockerfile
   COPY src/ ./src/
   COPY data/ ./data/
   COPY scripts/ ./scripts/
   COPY README.md ./
   ```

2. **Missing Python package**: Switched from `requirements.docker.txt` (missing `tiktoken` and other packages) to `requirements.txt`:
   ```dockerfile
   COPY requirements.txt ./requirements.txt
   RUN pip install --no-cache-dir -r requirements.txt
   ```

3. **No USER directive**: Omitted so OpenShift can assign its random UID via restricted-v2.

**Frontend** - replaced `npm ci` with `npm install` to resolve unresolvable peer dependency conflicts (`ajv@6.x` vs `ajv@8.x`, `picomatch@2.x` vs `picomatch@4.x`). Uses `nginx-unprivileged` on port 8080 for the production build.

---

### 4. Hardcoded Connection and Path Parameters

Several Python scripts hardcode values that only work in the upstream Docker Compose environment. On OpenShift, each service runs in a separate pod, so `localhost` does not resolve to the database. File output paths also need redirecting to writable directories.

**Affected files:**

- `src/api/routers/advanced_forecasting.py` - database connections
- `scripts/data/generate_historical_demand.py` - database connections
- `scripts/forecasting/rapids_gpu_forecasting.py` - database connections, output file path
- `scripts/forecasting/phase3_advanced_forecasting.py` - database connections, output file path
- `scripts/forecasting/rapids_forecasting_agent.py` - database connections
- `scripts/forecasting/phase1_phase2_forecasting_agent.py` - output file path

**Solution:** Replaced hardcoded values with environment variables, preserving the original defaults for backward compatibility:

```python
# Database connections
host=os.getenv("PGHOST", "localhost"),
port=int(os.getenv("PGPORT", "5435")),

# Forecast output paths
output_file = os.path.join(os.getenv("FORECAST_OUTPUT_DIR", ""), "phase1_phase2_forecasts.json")
```

The Helm chart injects `PGHOST`, `PGPORT`, `POSTGRES_USER`, `POSTGRES_DB`, `REDIS_HOST`, `REDIS_PORT`, and `FORECAST_OUTPUT_DIR` as environment variables.

---

## Deployment Files

All OpenShift customizations are in the `openshift/` folder. The upstream codebase is modified only where strictly necessary (env var fallbacks for DB connections and file paths).

```
openshift/
├── Dockerfile.backend            # Backend image (restricted-v2 compatible)
├── Dockerfile.frontend           # Frontend image (nginx-unprivileged)
├── build-openshift.sh            # Builds images into OpenShift internal registry
├── deploy-openshift.sh           # Full deploy (build + helm install)
├── uninstall-openshift.sh        # Clean uninstall (OLM cleanup + helm + build artifacts)
├── README.md                     # This file
├── grafana/dashboards/           # Grafana dashboard JSON files (loaded via --set-file)
│   ├── warehouse-operations.json
│   ├── warehouse-overview.json
│   └── warehouse-safety.json
└── helm/
    ├── .helmignore
    ├── Chart.yaml
    ├── values.yaml               # All defaults - override at deploy time
    └── templates/
        ├── _helpers.tpl
        ├── NOTES.txt
        ├── serviceaccount.yaml
        ├── secrets.yaml
        ├── pvcs.yaml
        ├── configmaps.yaml
        ├── route.yaml
        ├── networkpolicy.yaml
        ├── backend-deployment.yaml
        ├── frontend-deployment.yaml
        ├── nginx-deployment.yaml
        ├── timescaledb-deployment.yaml
        ├── redis-deployment.yaml
        ├── kafka-deployment.yaml
        ├── etcd-deployment.yaml
        ├── minio-deployment.yaml
        ├── milvus-deployment.yaml
        ├── db-init-job.yaml
        ├── user-init-job.yaml
        ├── demo-data-job.yaml
        ├── demo-demand-job.yaml
        ├── monitoring-servicemonitor.yaml
        ├── monitoring-prometheusrule.yaml
        ├── monitoring-alertmanagerconfig.yaml
        ├── monitoring-grafana.yaml
        └── monitoring-dashboards.yaml
```

