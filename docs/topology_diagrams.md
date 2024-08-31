# Valkey Topology Diagrams

This document describes the topology diagrams for Valkey deployments.

## Standalone Topology

```
┌──────────────────────────────────────┐
│                                      │
│    Valkey Standalone Instance        │
│                                      │
│  ┌────────────────────────────────┐  │
│  │                                │  │
│  │  Valkey Server (port 6379)     │  │
│  │  or TLS (port 16379)           │  │
│  │                                │  │
│  │  /var/vcap/store/standalone-X/ │  │
│  │    ├── valkey.aof (if persist) │  │
│  │    ├── VALKEY_VERSION          │  │
│  │    └── VALKEY_VERSION_FULL     │  │
│  │                                │  │
│  └────────────────────────────────┘  │
│                                      │
│  Optional: Prometheus Exporter       │
│  (port 9121)                         │
│                                      │
└──────────────────────────────────────┘

Network: valkey-service
VM Type: Configurable (default)
AZ: z1 (default)
```

**Key Features:**
- Single VM deployment
- Optional persistent disk with AOF
- Optional TLS support (dual-mode available)
- Optional Prometheus exporter co-location
- BOSH DNS alias: {instance-id}.valkey.cf.internal

**Use Cases:**
- Development environments
- Cache services (non-persistent)
- Small-scale key-value store
- Testing and prototyping

## Cluster Topology (2x2 Example)

```
┌─────────────────────────────────────────────────────────────────┐
│                     Valkey Cluster (2x2)                        │
│                                                                 │
│  Master Group 1 (Purple)              Master Group 2 (Blue)    │
│  ┌─────────────────────┐              ┌─────────────────────┐  │
│  │  Master 1           │              │  Master 2           │  │
│  │  Slots: 0-8191      │              │  Slots: 8192-16383  │  │
│  │  node/0 (bootstrap) │              │  node/1             │  │
│  │  AZ: z1             │              │  AZ: z2             │  │
│  └─────────────────────┘              └─────────────────────┘  │
│           ▲                                     ▲               │
│           │ Replication                         │ Replication   │
│           │                                     │               │
│  ┌────────┴─────────┐              ┌───────────┴──────────┐    │
│  │  Replica 1a      │              │  Replica 2a          │    │
│  │  node/2          │              │  node/3              │    │
│  │  AZ: z2          │              │  AZ: z1              │    │
│  └──────────────────┘              └──────────────────────┘    │
│           ▲                                     ▲               │
│           │ Replication                         │ Replication   │
│           │                                     │               │
│  ┌────────┴─────────┐              ┌───────────┴──────────┐    │
│  │  Replica 1b      │              │  Replica 2b          │    │
│  │  node/4          │              │  node/5              │    │
│  │  AZ: z1          │              │  AZ: z2              │    │
│  └──────────────────┘              └──────────────────────┘    │
│                                                                 │
│  Total: 6 VMs (2 masters + 4 replicas)                         │
│  Hash Slots: 16384 (0-16383)                                   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

Network: valkey-service
VM Type: Configurable (default)
AZs: z1, z2 (striped for HA)
```

**Key Features:**
- Automatic cluster formation via post-deploy script
- Sharded hash space (16384 slots)
- Master-replica replication
- Automatic failover on master failure
- Cross-AZ striping for high availability
- TLS support with stunnel for cluster communication
- AOF persistence on all nodes

**Cluster Formation Process:**
1. Bootstrap node (node/0) runs post-deploy script
2. All nodes verify `cluster_enabled:1`
3. DNS resolution for all node addresses
4. `CLUSTER MEET` commands introduce nodes
5. Hash slots distributed evenly across masters
6. Replicas assigned to masters via `CLUSTER REPLICATE`
7. Convergence wait (configurable boot_wait, default 20s)
8. Verification: No disconnected nodes

**Replication Flow:**
```
Master 1 (0-8191) ──┬──→ Replica 1a (full copy of 0-8191)
                    └──→ Replica 1b (full copy of 0-8191)

Master 2 (8192-16383) ──┬──→ Replica 2a (full copy of 8192-16383)
                        └──→ Replica 2b (full copy of 8192-16383)
```

**Use Cases:**
- Production key-value store
- High-availability caching
- Large-scale distributed applications
- Multi-tenant services
- Geo-distributed deployments

## TLS Communication Flow

### Standalone with TLS

```
Client ──[TLS]──> Port 16379 ──> Valkey Server
                  (or dual-mode: 6379 + 16379)
```

### Cluster with TLS

```
Client ──[TLS]──> Port 16379 ──> Valkey Node

Valkey Node 1 ──[Stunnel]──> Valkey Node 2
              (TLS wrapped)

Cluster Bus: Port 16379 (gossip protocol)
```

**TLS Certificate Locations:**
- CA: `/var/vcap/jobs/{job}/config/tls/valkey.ca`
- Cert: `/var/vcap/jobs/{job}/config/tls/valkey.cert`
- Key: `/var/vcap/jobs/{job}/config/tls/valkey.key`
- Node Cert: `/var/vcap/data/{job}/valkey.crt`
- Node Key: `/var/vcap/data/{job}/valkey.key`

## Network Architecture

```
┌─────────────────────────────────────────────────┐
│              Cloud Foundry Network              │
│                                                 │
│  ┌───────────────────────────────────────────┐  │
│  │         Blacksmith Broker                 │  │
│  │         (Orchestration)                   │  │
│  └───────────────┬───────────────────────────┘  │
│                  │                               │
│                  │ BOSH Director API             │
│                  ▼                               │
│  ┌───────────────────────────────────────────┐  │
│  │         BOSH Director                     │  │
│  │    (Creates service instances)            │  │
│  └───────────────┬───────────────────────────┘  │
│                  │                               │
│                  │ Deploys VMs                   │
│                  ▼                               │
└─────────────────────────────────────────────────┘
                   │
                   │
┌──────────────────▼──────────────────────────────┐
│           Valkey Service Network                │
│          (valkey-service network)               │
│                                                 │
│  ┌─────────────────────────────────────────┐   │
│  │    Valkey Service Instance              │   │
│  │    (Standalone or Cluster)              │   │
│  │                                         │   │
│  │  - BOSH DNS for service discovery       │   │
│  │  - Automatic IP assignment              │   │
│  │  - Security groups applied              │   │
│  │  - Persistent disks attached            │   │
│  └─────────────────────────────────────────┘   │
│                                                 │
└─────────────────────────────────────────────────┘
                   │
                   │ Service Binding
                   ▼
┌─────────────────────────────────────────────────┐
│         Application (Cloud Foundry App)         │
│                                                 │
│  Credentials provided via VCAP_SERVICES:        │
│  - host / hosts                                 │
│  - port / tls_port                              │
│  - password                                     │
└─────────────────────────────────────────────────┘
```

## Deployment Sizing Examples

### Small (Development)
```
Standalone:
  - 1 VM
  - vm_type: small (1 CPU, 1GB RAM)
  - No persistent disk
  - Use case: Dev/test caching
```

### Medium (Production Cache)
```
Standalone:
  - 1 VM
  - vm_type: medium (2 CPU, 4GB RAM)
  - 10GB persistent disk
  - Use case: Production cache with persistence
```

### Large (Production Cluster)
```
Cluster (2x2):
  - 6 VMs total
  - vm_type: large (4 CPU, 16GB RAM)
  - 50GB persistent disk per node
  - AZs: z1, z2, z3 (striped)
  - Use case: High-availability production workload
```

### Enterprise (Multi-Region Cluster)
```
Cluster (4x2):
  - 12 VMs total (4 masters, 8 replicas)
  - vm_type: xlarge (8 CPU, 32GB RAM)
  - 100GB persistent disk per node
  - AZs: z1, z2, z3 (multi-region)
  - TLS enabled with dual-mode
  - Prometheus exporters enabled
  - Use case: Enterprise-scale distributed cache
```

## Monitoring and Observability

```
┌─────────────────────────────────────────────────┐
│         Prometheus (if exporter enabled)        │
│                                                 │
│  Scrapes metrics from valkey_exporter:          │
│  - Port 9121 on each Valkey node               │
│  - Metrics: memory usage, commands/sec,         │
│    connections, replication lag, etc.           │
└─────────────────────────────────────────────────┘
                   │
                   │ Metrics
                   ▼
┌─────────────────────────────────────────────────┐
│              Grafana Dashboards                 │
│                                                 │
│  - Cluster health overview                      │
│  - Per-node resource usage                      │
│  - Replication lag monitoring                   │
│  - Command throughput                           │
│  - Memory utilization                           │
└─────────────────────────────────────────────────┘
```

## Image Generation Instructions

To generate actual PNG diagrams from these ASCII diagrams:

1. **Tool Options:**
   - Draw.io (diagrams.net) - Free, web-based
   - PlantUML - Text-to-diagram, good for automation
   - Lucidchart - Professional diagramming tool
   - Mermaid - Markdown-based diagrams

2. **Recommended Approach:**
   ```bash
   # Using PlantUML
   plantuml topology-standalone.puml -o docs/diag/
   plantuml topology-cluster.puml -o docs/diag/
   ```

3. **Color Scheme:**
   - Master 1 Group: #9370DB (Medium Purple)
   - Master 2 Group: #4169E1 (Royal Blue)
   - Replicas: Lighter shades of respective master colors
   - Network boxes: #F0F0F0 (Light Gray)
   - Arrows: #333333 (Dark Gray)

4. **Export Settings:**
   - Format: PNG
   - Resolution: 300 DPI
   - Size: 1200x800 pixels (landscape)
   - Transparent background: Optional
   - File naming: `topology-standalone.png`, `topology-cluster.png`
