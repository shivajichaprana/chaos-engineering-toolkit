# Chaos Engineering Toolkit

Lightweight Kubernetes chaos engineering framework with pod failure, network chaos, and node drain experiments.

## Overview

This toolkit provides a structured approach to chaos engineering on Kubernetes clusters. It includes a reusable experiment runner framework, pre-built experiments, and a local Kind cluster setup for safe testing.

### Why This Exists

Teams assume Kubernetes self-heals, but never test it. When a node fails or a pod gets OOM-killed during peak traffic, they discover their readiness probes, PDBs, and autoscaling configs were wrong all along. This toolkit lets you validate resilience assumptions before production incidents do it for you.

## Architecture

```
chaos-engineering-toolkit/
├── lib/                          # Shared framework libraries
│   ├── experiment_runner.sh      # Experiment lifecycle manager
│   └── steady_state.sh          # Steady-state capture & validation
├── experiments/                  # Individual chaos experiments
│   ├── pod-failure/             # Random pod deletion
│   ├── network-chaos/           # Network latency injection
│   └── node-drain/             # Node cordon & drain
├── manifests/                    # Kubernetes manifests
│   ├── sample-app/              # Target application (nginx)
│   └── network-chaos/           # tc-injector DaemonSet
├── scripts/                      # Utility scripts
│   └── setup-cluster.sh         # Kind cluster bootstrap
├── dashboards/                   # Grafana dashboards
└── kind-config.yaml             # Kind cluster configuration
```

## Quick Start

### Prerequisites

- [Kind](https://kind.sigs.k8s.io/) v0.20+
- [kubectl](https://kubernetes.io/docs/tasks/tools/) v1.27+
- [Docker](https://docs.docker.com/get-docker/) 24+
- [Helm](https://helm.sh/) v3 (optional, for monitoring)

### Setup

```bash
# Create a local Kind cluster with sample app
./scripts/setup-cluster.sh

# With Prometheus/Grafana monitoring
./scripts/setup-cluster.sh --with-monitoring
```

### Run an Experiment

```bash
# Run the pod failure experiment
./experiments/pod-failure/experiment.sh

# Run with custom config
TARGET_DEPLOYMENT=my-app TARGET_NAMESPACE=default \
  ./experiments/pod-failure/experiment.sh
```

## Experiment Lifecycle

Every experiment follows a structured 6-phase lifecycle:

1. **Pre-checks** — Validate cluster connectivity, namespace, and deployment exist
2. **Steady-state capture** — Record baseline metrics (pod count, endpoint health, response time)
3. **Chaos injection** — Execute the experiment's chaos action
4. **Observation** — Wait for the configured observation period
5. **Validation** — Compare current state against the baseline, with configurable recovery timeout
6. **Rollback & Report** — Restore the system and generate a markdown report

## Writing Custom Experiments

Create a new experiment by implementing the required `experiment_inject` function:

```bash
#!/usr/bin/env bash
EXPERIMENT_NAME="my-experiment"
EXPERIMENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_NAMESPACE="chaos-sandbox"
TARGET_DEPLOYMENT="sample-app"
RECOVERY_TIMEOUT=60

source "$(dirname "${EXPERIMENT_DIR}")/lib/experiment_runner.sh"

experiment_inject() {
    # Your chaos logic here
    kubectl delete pod -n "${TARGET_NAMESPACE}" -l app=sample-app --wait=false
}

experiment_rollback() {
    # Cleanup if needed
    echo "No manual rollback needed — K8s will reschedule pods"
}

run_experiment
```

## Experiments

| Experiment | Description | Validates |
|-----------|-------------|-----------|
| pod-failure | Randomly deletes pods from a target deployment | Pod rescheduling, readiness probes, service continuity |
| network-chaos | Injects network latency using tc traffic control | Timeout handling, circuit breakers, degraded mode |
| node-drain | Cordons and drains a worker node | PDB compliance, pod rescheduling, multi-node resilience |

## Configuration

Experiments are configured via environment variables or `config.yaml` files:

| Variable | Description | Default |
|----------|-------------|---------|
| `TARGET_NAMESPACE` | Kubernetes namespace | `chaos-sandbox` |
| `TARGET_DEPLOYMENT` | Target deployment name | `sample-app` |
| `RECOVERY_TIMEOUT` | Seconds to wait for recovery | `120` |
| `POLL_INTERVAL` | Seconds between validation checks | `5` |
| `HEALTH_ENDPOINT` | HTTP endpoint for health checks | _(none)_ |
| `OBSERVATION_PERIOD` | Seconds to observe after injection | `0` |

## License

MIT License — see [LICENSE](LICENSE) for details.
