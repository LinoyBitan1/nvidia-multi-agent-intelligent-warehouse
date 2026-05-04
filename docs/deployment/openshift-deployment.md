# Red Hat OpenShift AI Deployment Guide

This guide provides complete step-by-step instructions for deploying the [NVIDIA Multi-Agent Intelligent Warehouse (WOSA)](https://github.com/NVIDIA-AI-Blueprints/Multi-Agent-Intelligent-Warehouse) blueprint on Red Hat OpenShift AI (RHOAI).

## Overview

This deployment uses a Helm chart with an OpenShift-specific values overlay. Deployment runs directly from your local machine using `oc` and `helm` CLI tools.

**What gets deployed:**

- FastAPI backend with LangGraph multi-agent orchestration (operations, safety, equipment, forecasting, document processing)
- React web UI with dashboards for inventory, tasks, safety incidents, equipment telemetry, chat
- Nginx reverse proxy (single Route with path-based routing: `/api/` → backend, `/` → frontend)
- TimescaleDB (time-series relational database)
- Redis (caching and session storage)
- Milvus + etcd + MinIO (vector database stack for RAG)
- Kafka (event streaming, KRaft single-node)
- OpenShift Route, ServiceAccount, NetworkPolicies, Secrets, and Helm hook Jobs

**Optional:**

- Monitoring stack (ServiceMonitors, PrometheusRule, AlertmanagerConfig, Grafana with dashboards)
- Milvus GPU acceleration
- Demo data and demand history seeding

**Total time**: ~10-15 minutes

## Prerequisites

- **OpenShift** 4.12+ with `oc` CLI configured
- **Helm** 3.x installed
- **NVIDIA API Key** — from [NGC](https://org.ngc.nvidia.com/setup/api-keys) or [build.nvidia.com](https://build.nvidia.com/)
- **Container registry** — uses the internal OpenShift registry by default (alternatively Quay.io, GHCR, etc.)
- **Cluster resources** — see [Tested Hardware](#tested-hardware)

**Additional prerequisites for Milvus GPU mode:**

- NVIDIA GPU Operator installed and `nvidia.com/gpu` resource is allocatable
- GPU nodes are ready: `oc get nodes -l nvidia.com/gpu`
- GPU node taint keys identified: `oc describe node <gpu-node> | grep -A5 Taints`

## 1. Login and create namespace

```bash
oc login --token=$OPENSHIFT_TOKEN --server=$OPENSHIFT_CLUSTER_URL

export NAMESPACE=wosa

oc new-project $NAMESPACE
```

## 2. Export your API key

```bash
export NVIDIA_API_KEY="<your NVIDIA API key>"
```

## 3. Build the application images

The OpenShift Dockerfiles at the repo root produce images compatible with OpenShift's `restricted-v2` SCC (non-root, no capabilities, seccomp enforced). Images are built directly inside the cluster using the internal registry.

```bash
# Backend
oc new-build --binary --strategy=docker --name=wosa-backend -n $NAMESPACE
oc patch buildconfig wosa-backend -n $NAMESPACE \
  -p '{"spec":{"strategy":{"dockerStrategy":{"dockerfilePath":"Dockerfile.backend-openshift"}}}}'
oc start-build wosa-backend --from-dir=. --follow -n $NAMESPACE

# Frontend
oc new-build --binary --strategy=docker --name=wosa-frontend -n $NAMESPACE
oc patch buildconfig wosa-frontend -n $NAMESPACE \
  -p '{"spec":{"strategy":{"dockerStrategy":{"dockerfilePath":"Dockerfile.frontend-openshift"}}}}'
oc start-build wosa-frontend --from-dir=. --follow -n $NAMESPACE
```

The resulting images are available at `image-registry.openshift-image-registry.svc:5000/$NAMESPACE/wosa-backend` and `wosa-frontend`.

> **Using an external registry:** If you prefer to push images to Quay.io or another registry, build with `docker build` / `docker push` and override the image paths in Step 4.

## 4. Deploy the application

The chart creates all required Secrets, ConfigMaps, PVCs, Services, Route, and Helm hook Jobs automatically. No manual `oc create` commands are needed.

```bash
helm install wosa deploy/helm/wosa/ \
  -n $NAMESPACE \
  -f deploy/helm/wosa/values-openshift.yaml \
  --set secrets.nvidiaApiKey="$NVIDIA_API_KEY"
```

SQL schema migrations are applied automatically — the db-init job copies SQL files from the backend image and runs them against TimescaleDB. No `--set-file` flags needed.

> **Using a different namespace or external registry?** The overlay defaults to `wosa` namespace with the internal registry. Override with:
> ```
> --set image.repository=image-registry.openshift-image-registry.svc:5000/<namespace>/wosa-backend
> --set frontend.image.repository=image-registry.openshift-image-registry.svc:5000/<namespace>/wosa-frontend
> ```

**With all optional features:**

```bash
helm install wosa deploy/helm/wosa/ \
  -n $NAMESPACE \
  -f deploy/helm/wosa/values-openshift.yaml \
  --set secrets.nvidiaApiKey="$NVIDIA_API_KEY" \
  --set demoData.enabled=true \
  --set demoDemand.enabled=true \
  --set monitoring.enabled=true
```

> **Milvus GPU acceleration:** Uncomment the `milvus.gpu` section in `values-openshift.yaml` and
> adjust the toleration key to match your GPU node taints (`oc describe node <gpu-node> | grep -A5 Taints`).

### Optional deploy flags

| Flag | Purpose | Required |
|------|---------|----------|
| `--set demoData.enabled=true` | Seed inventory, tasks, safety incidents | No |
| `--set demoDemand.enabled=true` | Seed 180 days of demand history | No |
| `--set monitoring.enabled=true` | Deploy ServiceMonitors, alerts, Grafana | No |
| `--set storageClass=<name>` | Override default StorageClass for all PVCs | No |

> **Note:** Milvus GPU acceleration is configured via `values-openshift.yaml`, not `--set` flags. See the `milvus.gpu` section in that file.

## 5. Verify the deployment

```bash
# All pods should be Running
oc get pods -n $NAMESPACE

# Get the Route URL
oc get route -n $NAMESPACE

# API health check
ROUTE_HOST=$(oc get route -n $NAMESPACE -l app.kubernetes.io/component=nginx -o jsonpath='{.items[0].spec.host}')
curl -k https://$ROUTE_HOST/api/v1/health

# Stream backend logs
oc logs -f deployment/wosa-backend -n $NAMESPACE
```

All pods should be `Running` with `READY 1/1` (9 pods by default, more with monitoring enabled). Infrastructure pods (TimescaleDB, Milvus) may take 1-2 minutes for readiness probes to pass.

**Expected pods:**

| Pod | Purpose |
|-----|---------|
| `wosa-backend` | Multi-agent orchestration API |
| `wosa-frontend` | React web UI |
| `wosa-nginx` | Reverse proxy (Route entry point) |
| `wosa-timescaledb` | Time-series database |
| `wosa-redis` | Cache and sessions |
| `wosa-milvus` | Vector database |
| `wosa-etcd` | Milvus metadata store |
| `wosa-minio` | Milvus object storage |
| `wosa-kafka` | Event streaming |

## 6. Access the application

```bash
ROUTE_HOST=$(oc get route -n $NAMESPACE -l app.kubernetes.io/component=nginx -o jsonpath='{.items[0].spec.host}')
echo "https://$ROUTE_HOST"
```

Open `https://$ROUTE_HOST` in a browser. Default credentials: `admin` / `changeme`.

## Database Initialisation and Data Seeding

Schema migrations and post-deploy setup run automatically as Helm hooks on first install. The `helm.sh/hook-weight` annotation controls execution order — lower weight runs first, and Helm waits for each Job to complete before starting the next.

| Hook Job | Weight | Trigger | What it does |
|----------|--------|---------|-------------|
| `db-init-job` | 0 | post-install, post-upgrade | Applies all SQL migrations against TimescaleDB |
| `user-init-job` | 1 | post-install | Creates `admin` and `user` accounts |
| `demo-data-job` | 2 | post-install | Seeds 35 inventory items, 8 tasks, 8 safety incidents, equipment telemetry |
| `demo-demand-job` | 3 | post-install | Seeds 180 days of demand history for the Forecasting page |

**Always enabled:** `db-init-job` (SQL files are copied from the backend image automatically), `user-init-job` (required — without them, the database has no schema and login is impossible).

**Disabled by default:** `demo-data-job` (`--set demoData.enabled=true`), `demo-demand-job` (`--set demoDemand.enabled=true`).

The `db-init-job` runs on every `post-upgrade` to safely apply new migrations (`CREATE TABLE IF NOT EXISTS`). All other jobs only run on `post-install` to avoid re-seeding data.

## Monitoring

When `--set monitoring.enabled=true`, the chart deploys:

1. **ServiceMonitors** (4) — scrape targets for OpenShift's built-in Prometheus:
   - Backend `/api/v1/metrics` (port 8001)
   - PostgreSQL exporter sidecar (port 9187)
   - Redis exporter sidecar (port 9121)
   - Milvus metrics (port 9091)
2. **PrometheusRule** — 14 alert rules covering API health, database availability, high latency, memory usage, safety incidents, task completion
3. **AlertmanagerConfig** — alert routing with email and webhook receivers
4. **Grafana Operator** — installed namespace-scoped via OLM
5. **Grafana instance** — with an OpenShift Route (edge TLS) and Thanos Querier datasource
6. **GrafanaDashboard CRs** — 3 pre-built dashboards (Overview, Operations, Safety & Compliance), bundled in `deploy/helm/wosa/dashboards/` and loaded automatically via `.Files.Glob`

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
oc get route -n $NAMESPACE -l app.kubernetes.io/component=monitoring
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

No Prometheus or Alertmanager pods are deployed in the user namespace — OpenShift's built-in monitoring stack handles collection and alerting. Only Grafana is deployed for visualization.

## Troubleshooting

**Pods not starting:**

```bash
oc describe pod <pod-name> -n $NAMESPACE
oc get events -n $NAMESPACE --sort-by='.lastTimestamp'
```

**Image pull errors:**

```bash
# Verify images exist in the internal registry
oc get imagestream -n $NAMESPACE
# Check image pull secrets
oc get secrets -n $NAMESPACE | grep pull
```

**TimescaleDB or Kafka CrashLoopBackOff:**

```bash
oc logs deployment/wosa-timescaledb -n $NAMESPACE --tail=100
oc logs deployment/wosa-kafka -n $NAMESPACE --tail=100
# Usually caused by lost+found — chart uses PGDATA/KAFKA_LOG_DIRS subdirectories to avoid this
```

**Milvus or PVCs pending:**

```bash
oc get pvc -n $NAMESPACE
oc get sc
# Override storage class if needed: --set storageClass=<name>
```

**Backend unhealthy:**

```bash
oc logs deployment/wosa-backend -n $NAMESPACE --tail=100
# Check if TimescaleDB is ready
oc logs deployment/wosa-timescaledb -n $NAMESPACE --tail=50
```

**Route not accessible:**

```bash
oc get route -n $NAMESPACE
oc logs deployment/wosa-nginx -n $NAMESPACE --tail=100
```

**DB init job failing:**

```bash
oc logs job/wosa-db-init -n $NAMESPACE
# Verify the backend image is available (used by initContainer to copy SQL files)
oc get imagestream wosa-backend -n $NAMESPACE
```

**Grafana not deploying / monitoring metrics missing:**

```bash
# Check Grafana Operator is installed
oc get csv -n $NAMESPACE
# User workload monitoring must be enabled — see Prerequisite section
oc get pods -n openshift-user-workload-monitoring
```

## OpenShift Overlay Strategy

1. An `openshift.enabled` flag is added to the chart's `values.yaml` (default: `false`). When disabled, no OpenShift resources are rendered and the chart behaves identically to upstream Kubernetes.
2. All OpenShift-specific values are in a dedicated overlay file: `values-openshift.yaml`. OpenShift-specific templates (`openshift-route.yaml`, `openshift-scc.yaml`) are conditionally rendered only when `openshift.enabled: true`.
3. Secrets (NVIDIA API keys, JWT, database credentials, MinIO credentials) are created declaratively by the chart when provided via `--set` flags. This keeps the deployment to a single `helm install` command with no manual `oc create secret` steps.
4. All pods run under OpenShift's default `restricted-v2` SCC — no `anyuid` or elevated SCC is required. Storage permission issues are solved with `emptyDir` volumes and data subdirectories.
5. Source code changes are minimal: only environment variable fallbacks for database connections and file output paths, preserving backward compatibility with the upstream Docker Compose workflow.
6. The goal is to touch the original repository as little as possible, providing OpenShift deployment support with minimal changes.

## Deployment Files

All OpenShift customizations are in the `deploy/` folder. The upstream codebase is modified only where strictly necessary (env var fallbacks for DB connections and file paths).

```
Dockerfile.backend-openshift      # Backend image (restricted-v2 compatible)
Dockerfile.frontend-openshift     # Frontend image (nginx-unprivileged)
docs/deployment/
└── openshift-deployment.md       # This file
deploy/
└── helm/wosa/
    ├── .helmignore
    ├── Chart.yaml
    ├── values.yaml               # All defaults (openshift.enabled: false)
    ├── values-openshift.yaml     # OpenShift overlay (enables route, SCC, etc.)
    ├── dashboards/
    │   ├── warehouse-overview-openshift.json    # Grafana dashboard
    │   ├── warehouse-operations-openshift.json  # Grafana dashboard
    │   └── warehouse-safety-openshift.json      # Grafana dashboard
    └── templates/
        ├── _helpers.tpl
        ├── NOTES.txt
        ├── serviceaccount.yaml
        ├── secrets.yaml
        ├── pvcs.yaml
        ├── configmaps.yaml
        ├── openshift-route.yaml
        ├── openshift-scc.yaml
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

## Tested Hardware

This deployment was validated on the following cluster configuration:

**Cluster:** OpenShift 4.19 on AWS (us-east-2)

### Worker nodes (non-GPU)

| Instance Type | vCPU | RAM | Count | Role |
|---------------|------|-----|-------|------|
| `m6i.2xlarge` | 8 | 32 GiB | 1 | All WOSA pods except Milvus GPU |

### GPU node (optional — Milvus GPU mode only)

| Instance Type | GPU | VRAM | vCPU | RAM | Count | Role |
|---------------|-----|------|------|-----|-------|------|
| `g6e.2xlarge` | 1x NVIDIA L40S | 46 GB | 8 | 64 GiB | 1 | Milvus vector database (GPU-accelerated index) |

All pods run on a single worker node by default. With `milvus.gpu.enabled=true`, Milvus schedules onto a GPU node while all other pods remain on the worker.

### Minimum Requirements (Cloud NIMs)

| Resource | Requirement |
|----------|-------------|
| CPU | 10 cores |
| RAM | 18 GiB |
| Storage | 38 Gi |
| GPU | Not required |
| Network | Stable internet for API calls |

## Known Limitations

1. **Dockerfiles assume bind mounts.** The upstream Dockerfiles rely on Docker Compose bind-mounting the entire repository into the container (`volumes: [".:/app"]`). Without bind mounts, images are missing agent configs (`data/config/agents/`), SQL migrations (`data/postgres/`), scripts, and `README.md`. Additionally, `requirements.docker.txt` is missing packages (`tiktoken`, `psycopg`, `pandas`, `nemoguardrails`). This integration provides separate `Dockerfile.backend-openshift` and `Dockerfile.frontend-openshift` with the necessary fixes.

2. **Hardcoded connection parameters.** Several Python scripts hardcode `localhost` for database connections and local file paths for output, which only work in Docker Compose (all services share a network). On Kubernetes/OpenShift, each service runs in a separate pod. Affected files: `advanced_forecasting.py`, `generate_historical_demand.py`, `rapids_gpu_forecasting.py`, `phase3_advanced_forecasting.py`, `rapids_forecasting_agent.py`, `phase1_phase2_forecasting_agent.py`. This integration replaces hardcoded values with environment variables (`PGHOST`, `PGPORT`, `FORECAST_OUTPUT_DIR`) while preserving the original defaults for backward compatibility.

3. **RAPIDS GPU Forecasting.** The upstream `Dockerfile.rapids` depends on `nvcr.io/nvidia/rapidsai/rapidsai:24.02`, which was removed from NGC. The RAPIDS GPU training path cannot be built. Training works without RAPIDS — the backend automatically falls back to CPU-based scikit-learn models (RandomForest, XGBoost, GradientBoosting). All 38 SKUs train and forecast successfully on CPU.

4. **Milvus GPU Acceleration.** Full GPU support is implemented in the Helm chart (GPU image, CUDA env vars, resource requests, tolerations). However, the upstream codebase never wires it — `gpu_hybrid_retriever.py` exists but no agent imports it. All agents use the CPU `IVF_FLAT` index. The chart supports `milvus.gpu.enabled=true` at deploy time, but it has no effect until upstream imports `gpu_hybrid_retriever`.

5. **Monitoring Dashboard Metrics Coverage.** The upstream application defines business-logic Prometheus metrics and collector methods in `src/api/services/monitoring/metrics.py` but only calls the HTTP middleware metrics. Dashboard panels for infrastructure (health, API rates, resource usage) show real data; business-logic panels (tasks, equipment, safety, environmental) show "No data" or `0`. Dashboards will display data once the application calls the existing `MetricsCollector` methods.

## Uninstall

```bash
helm uninstall wosa -n $NAMESPACE
```

To also remove persistent data:

```bash
oc delete pvc -l app.kubernetes.io/instance=wosa -n $NAMESPACE
```

To remove the build resources created in Step 3 (BuildConfigs, ImageStreams, and completed Build pods):

```bash
oc delete buildconfig wosa-backend wosa-frontend -n $NAMESPACE --ignore-not-found
oc delete imagestream wosa-backend wosa-frontend -n $NAMESPACE --ignore-not-found
oc delete builds -l buildconfig=wosa-backend -n $NAMESPACE --ignore-not-found
oc delete builds -l buildconfig=wosa-frontend -n $NAMESPACE --ignore-not-found
```

If monitoring was enabled, clean up Grafana resources:

```bash
# Grafana CRs (not removed by helm uninstall)
oc delete grafanas,grafanadatasources,grafanadashboards --all -n $NAMESPACE --ignore-not-found
# Grafana Operator subscription and CSV
oc delete subscription grafana-operator -n $NAMESPACE --ignore-not-found
oc get csv -n $NAMESPACE -o name | grep grafana-operator | xargs -r oc delete -n $NAMESPACE --ignore-not-found
# Cluster-scoped resources
oc delete clusterrolebinding wosa-grafana-monitoring-view --ignore-not-found
```
