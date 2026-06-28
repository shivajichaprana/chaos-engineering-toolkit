# Network Chaos Experiment — Latency Injection

## Hypothesis

When network latency is injected into application pods, the service will continue
to respond within acceptable bounds because:

- Circuit breakers will trip before downstream timeouts cascade
- Retry logic with exponential backoff will handle transient delays
- Health check probes will detect degraded pods but not mark them as failed
- Client-side timeouts will prevent unbounded wait times

If the system lacks these resilience patterns, this experiment will expose the gap
by measuring response time degradation under controlled network conditions.

## Procedure

```
┌──────────────────────────────────────────────────────────────────────┐
│  1. Pre-checks                                                       │
│     └─ Verify cluster, namespace, deployment, and pod readiness      │
│                                                                      │
│  2. Capture Steady State                                             │
│     └─ Record baseline response time (average of 3 probes)          │
│                                                                      │
│  3. Inject Chaos                                                     │
│     ├─ Apply tc netem rules to each target pod's network interface   │
│     ├─ Rules: configurable latency + jitter + optional packet loss   │
│     └─ Probe health endpoint repeatedly during chaos window          │
│                                                                      │
│  4. Validate                                                         │
│     ├─ Check p95 response time against acceptable threshold          │
│     ├─ Verify probe success rate ≥ 80%                               │
│     └─ Confirm all pods still running (latency ≠ crash)             │
│                                                                      │
│  5. Rollback                                                         │
│     ├─ Remove tc netem rules from all targeted pods                  │
│     ├─ Verify response time recovers to near-baseline               │
│     └─ Confirm deployment is stable                                  │
│                                                                      │
│  6. Report                                                           │
│     └─ Generate Markdown report with timing data and pass/fail       │
└──────────────────────────────────────────────────────────────────────┘
```

## Expected Behavior

### Pass Conditions

- p95 response time stays below the configured `acceptable_response_time_ms`
- At least 80% of health probes succeed (don't timeout at 10s)
- Pod count remains stable throughout the experiment
- Response times recover to within 2x baseline after rollback

### Fail Conditions

- p95 response time exceeds the threshold — indicates missing timeouts or
  circuit breakers
- High probe timeout rate — indicates the service becomes unresponsive under
  latency (no graceful degradation)
- Pods crash or restart — indicates the application treats slow networking as
  a fatal error

## Configuration

Edit `config.yaml` to tune the experiment:

| Parameter                   | Default  | Description                                      |
|-----------------------------|----------|--------------------------------------------------|
| `target_deployment`         | sample-app | Deployment to inject latency into               |
| `namespace`                 | chaos-testing | Kubernetes namespace                          |
| `latency_ms`                | 200      | Injected delay in milliseconds                   |
| `jitter_ms`                 | 50       | Variation in delay (±)                           |
| `chaos_duration`            | 60       | How long to keep latency active (seconds)        |
| `acceptable_response_time_ms` | 2000   | Max acceptable p95 response time                 |
| `health_endpoint`           | —        | URL to probe for response time                   |
| `probe_count`               | 10       | Number of probes during chaos window             |
| `recovery_timeout`          | 90       | Max wait for response time recovery (seconds)    |
| `packet_loss_percent`       | 0        | Optional packet loss to inject alongside latency |
| `target_interface`          | eth0     | Network interface for tc rules                   |

## Usage

```bash
# Run with default config
./experiments/network-chaos/experiment.sh

# Run with custom config
./experiments/network-chaos/experiment.sh --config path/to/config.yaml

# Run via Makefile
make run-network-chaos
```

## How It Works

The experiment uses Linux `tc` (traffic control) with the `netem` (network
emulator) queueing discipline to inject latency at the kernel level:

```bash
# What gets executed inside each pod:
tc qdisc add dev eth0 root netem delay 200ms 50ms loss 1%
```

This is the same mechanism used by production chaos engineering tools. The
tc-injector DaemonSet provides a privileged sidecar with `NET_ADMIN` capability
to run these commands inside the pod's network namespace.

## Prerequisites

- Running Kind cluster with the sample application deployed
- `tc-injector` DaemonSet deployed (see `manifests/network-chaos/tc-injector.yaml`)
- `curl` available on the machine running the experiment
- Health endpoint accessible via NodePort or port-forward
