# Pod Failure Experiment

## Overview

The pod failure experiment validates Kubernetes' self-healing capabilities by randomly deleting pods from a target deployment and verifying that the system recovers to its steady state within a defined SLA.

## Hypothesis

When one or more pods in a deployment are unexpectedly terminated, the Kubernetes ReplicaSet controller will detect the discrepancy between desired and actual replica count and schedule replacement pods. The service will recover to full capacity within the configured recovery timeout, and the health endpoint will return to a healthy state.

## Procedure

1. **Pre-checks** — Verify cluster connectivity, namespace existence, target deployment health, and sufficient replica count
2. **Steady-state capture** — Record baseline pod count, endpoint health status, and response time
3. **Chaos injection** — Select N random pods from the target deployment and delete them with the configured grace period
4. **Observation** — Wait for a brief observation period to allow failure detection
5. **Validation** — Poll until pod count recovers to baseline and the health endpoint returns 2xx, or until the recovery timeout expires
6. **Rollback** — No manual rollback needed; Kubernetes handles pod recreation automatically
7. **Report** — Generate a Markdown report with pass/fail status and timing details

## Configuration

Edit `config.yaml` to customize the experiment:

| Parameter          | Default              | Description                                           |
|--------------------|----------------------|-------------------------------------------------------|
| `target_deployment`| `sample-app`         | Name of the deployment to target                      |
| `namespace`        | `chaos-testing`      | Kubernetes namespace                                  |
| `pods_to_kill`     | `1`                  | Number of pods to delete                              |
| `recovery_timeout` | `120`                | Max seconds to wait for recovery                      |
| `health_endpoint`  | `localhost:30080/healthz` | HTTP endpoint for health checks                  |
| `grace_period`     | `0`                  | Pod deletion grace period (0 = force kill)            |
| `observation_period`| `10`                | Seconds to wait after injection before validating     |
| `poll_interval`    | `5`                  | Seconds between validation polls                      |

## Usage

```bash
# Run with default config
./experiments/pod-failure/experiment.sh

# Run with a custom config file
./experiments/pod-failure/experiment.sh /path/to/custom-config.yaml
```

## Expected Outcome

- **PASS**: All killed pods are replaced by new pods within the recovery timeout. The total ready replica count returns to the baseline. The health endpoint (if configured) returns HTTP 2xx.
- **FAIL**: Pod count does not recover within the timeout, or the health endpoint remains unhealthy. This indicates potential issues with ReplicaSet configuration, resource constraints (insufficient CPU/memory for scheduling), node availability, or PodDisruptionBudget conflicts.

## Recovery Criteria

| Metric           | Condition                                      |
|------------------|------------------------------------------------|
| Pod count        | Current ready replicas >= baseline pod count   |
| Endpoint health  | HTTP 2xx response from health endpoint         |
| Stale pods       | All originally killed pods are fully terminated |

## Failure Investigation

If the experiment fails, investigate:

1. **Pending pods** — `kubectl get pods -n chaos-testing` to check for pods stuck in Pending state (resource constraints)
2. **Events** — `kubectl get events -n chaos-testing --sort-by=.lastTimestamp` for scheduling failures
3. **Node resources** — `kubectl describe nodes` to check available CPU and memory
4. **ReplicaSet** — `kubectl describe rs -n chaos-testing` to verify the ReplicaSet is attempting to create new pods
5. **PDBs** — Check if PodDisruptionBudgets are blocking rescheduling
