# Node Drain Experiment

## Hypothesis

When a worker node is cordoned and drained, Kubernetes will:

1. **Respect PodDisruptionBudgets** — the minimum number of available pods specified by PDBs will be maintained throughout the eviction process
2. **Reschedule evicted pods** — all pods from the drained node will be placed onto remaining healthy worker nodes within the recovery timeout
3. **Maintain service availability** — the application's health endpoint will continue responding with HTTP 200 during and after the drain operation

If any of these conditions fail, it indicates gaps in PDB configuration, scheduling constraints, or cluster capacity planning.

## Why This Matters

Node drains happen during:
- **Planned maintenance** — OS patching, kernel upgrades, instance type changes
- **Cluster autoscaler** — scaling down removes underutilized nodes
- **Spot instance reclamation** — cloud provider reclaims preemptible instances
- **Hardware failure** — a node becomes unhealthy and is cordoned automatically

Without testing, teams discover PDB misconfigurations and scheduling failures during real incidents — when it's too late to fix them.

## Procedure

```
┌─────────────────────────────────────────────────┐
│  1. Pre-flight checks                           │
│     - Verify cluster, namespace, deployment     │
│     - Ensure ≥ 2 worker nodes available         │
├─────────────────────────────────────────────────┤
│  2. Capture steady state                        │
│     - Node count, pod count, pod distribution   │
│     - Health endpoint baseline                  │
├─────────────────────────────────────────────────┤
│  3. Select target node                          │
│     - Strategy: random / specific / most-loaded │
├─────────────────────────────────────────────────┤
│  4. Cordon node (mark unschedulable)            │
│     - No new pods will be placed on this node   │
├─────────────────────────────────────────────────┤
│  5. Drain node (evict pods)                     │
│     - Respects PDBs and grace periods           │
│     - Waits up to drain_timeout seconds         │
├─────────────────────────────────────────────────┤
│  6. Validate                                    │
│     - PDB compliance (currentHealthy ≥ desired) │
│     - Pod count recovered to steady state       │
│     - No pods remain on drained node            │
│     - Health endpoint returns 200               │
├─────────────────────────────────────────────────┤
│  7. Rollback: uncordon node                     │
│     - Node becomes schedulable again            │
│     - Wait for cluster stabilization            │
├─────────────────────────────────────────────────┤
│  8. Generate report                             │
│     - Markdown report with PASS/FAIL verdict    │
└─────────────────────────────────────────────────┘
```

## Expected Outcome

| Check | Expected |
|-------|----------|
| PDB compliance | `currentHealthy >= desiredHealthy` at all times |
| Pod rescheduling | All pods running on remaining nodes within recovery timeout |
| Service availability | Health endpoint returns HTTP 200 |
| Cluster recovery | After uncordon, cluster returns to normal state |

## Configuration

See [`config.yaml`](config.yaml) for all tunable parameters. Key settings:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `node_selection_strategy` | `random` | How to choose the drain target |
| `drain_timeout` | `120s` | Max wait for drain to complete |
| `grace_period` | `30s` | Pod eviction grace period |
| `recovery_timeout` | `180s` | Max wait for pod rescheduling |

## Usage

```bash
# Run with defaults
./experiments/node-drain/experiment.sh

# Drain the most-loaded worker node
./experiments/node-drain/experiment.sh --strategy most-loaded

# Drain a specific node
./experiments/node-drain/experiment.sh --strategy specific --node kind-worker2

# Dry run (prints actions without executing)
./experiments/node-drain/experiment.sh --dry-run
```

## Prerequisites

- Kubernetes cluster with **at least 2 worker nodes**
- Target deployment with a **PodDisruptionBudget** configured
- `kubectl` configured with cluster access
- Sufficient capacity on remaining nodes to absorb evicted pods
