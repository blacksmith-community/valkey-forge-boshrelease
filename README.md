# Blacksmith Valkey Forge

This Blacksmith Forge teaches a [Blacksmith Broker][broker] how to
deploy standalone and clustered [Valkey][valkey] service
deployments, which are useful for caching, persistent key-value
store, and distributed lock management.

Valkey is an open source (BSD) high-performance key/value datastore that supports a variety of workloads such as caching and message queues. This forge is a drop-in replacement for Redis with enhanced security and multi-version support.

## Version Support

This forge supports multiple Valkey versions:

- **Valkey 7** (7.2.11) - LTS, migration path from Redis 6/7
- **Valkey 8** (8.1.4) - **Recommended**, stable production release
- **Valkey 9** (9.0.0) - Latest with new features

Each version has dedicated standalone and cluster jobs: `standalone-7/8/9` and `cluster-7/8/9`.

## Deploying

To deploy this forge, you will need to add it to your existing
Blacksmith Broker manifest deployment, co-locating the
`valkey-blacksmith-plans` job on the Blacksmith instance group.

Here's an example to get you started (clipped for brevity):

```yaml
releases:
  - name:    valkey-forge
    version: latest

instance_groups:
  - name: blacksmith
    jobs:
      - name:    valkey-blacksmith-plans
        release: valkey-forge
        properties:
          plans:
            # your plans here
            # (see below)
```

The Valkey Forge deploys Valkey by using jobs that are found
_inside_ the `valkey-forge` BOSH release, which means that your
Blacksmith BOSH director also needs that release. Blacksmith is
able to upload that release for you, if you want.

For the Spruce users out there:

```yaml
---
instance_groups:
  - name: blacksmith
    jobs:
      - name: blacksmith
        properties:
          releases:
            - (( append ))
            - (( grab releases.valkey-forge ))
```

Finally, you'll need to define plans for Blacksmith to deploy.
The following sections discuss those ad nauseum.

## Standalone Topology

The `standalone` topology is as straightforward as they come: a
single dedicated VM that runs Valkey bound on all interfaces, to
port 6379. If TLS is enabled it will bind to port 16379, or both
ports if dual-mode is enabled.

Here's a diagram to clear things up:

![Standalone Topology Diagram](docs/diag/topology-standalone.png)

### Configuration Options

- *type* - Specify the job type: `standalone-7`, `standalone-8`, or `standalone-9`.
  This determines which Valkey version is deployed. We recommend `standalone-8`
  for production use.

- *vm_type* - The name of a BOSH `vm_type` from your cloud-config.
  You can use this to size your Valkey appropriate to your workload
  requirements, in terms of RAM and CPU. Increasing the disk size
  via the VM type is not going to net you much of a gain (see
  the `disk_size`, `disk_type`, and `persist` options instead).

- *azs* - An array of BOSH availability zone names (per cloud-config),
  for your standalone node placement. Deployed VMs will be
  randomly distributed across these AZs. By default, all nodes will
  be put in `z1`.

- *network* - The name of the network to deploy these instances to.
  This network should be defined in your cloud-config, and should
  be large enough to handle your anticipated service footprint.
  It does not need any static IP addresses.

  By default, VMs will be deployed into a network named
  `valkey-service`.

- *persist* - Whether or not the data stored in this Valkey
  instance should be written to disk or not. If you are just
  implementing a cache service using Valkey, you don't need to
  specify this (or `disk_size`) -- by default this topology is
  diskless.

  Persistent Valkey instances use the append-only format (AOF),
  storing the file in `/var/vcap/store/standalone-{7,8,9}/valkey.aof`. The
  AOF file is fsync'd once every second to balance safety with
  performance.

- *disk_size* - If you specify `persist` to get a durable key-value
  store, you can also specify this configuration value to change
  the size of the persistent disk. By default, you get a 1G disk.

- *disk_type* - If you specify `persist` to get a durable key-value
  store, you can also specify this configuration value to change
  the persistent disk type. If both _disk_size_ and _disk_type_ are
  defined, the _disk_size_ configuration value will be ignored.

### Example Configuration

A single standalone plan, persistent, with 4G of disk using Valkey 8:

```yaml
instance_groups:
  - name: blacksmith
    jobs:
      - name:    valkey-blacksmith-plans
        release: valkey-forge
        properties:
          plans:
            single-4g:
              type:      standalone-8
              persist:   true
              disk_size: 4_096
```

Here's a configuration that provides two different sizes of
persistent standalone, as well as a large (per cloud-config)
non-persistent cache service:

```yaml
instance_groups:
  - name: blacksmith
    jobs:
      - name:    valkey-blacksmith-plans
        release: valkey-forge
        properties:
          plans:
            small:
              type:      standalone-8
              persist:   true
              disk_size: 4_096

            large:
              type:      standalone-8
              persist:   true
              disk_size: 16_384

            cache:
              type: standalone-8
```

## Clustered Topology

The `cluster` topology shards the Valkey key hash space across _M_
masters, each with _R_ replicas. It provides fault tolerance,
with optional (but highly encouraged) striping across BOSH
availability zones.

Here's a diagram, showing a _M=2, R=2_ configuration:

![Cluster Topology Diagram](docs/diag/topology-cluster.png)

We can refer to this as a _2x2_ setup, 2 masters, with 2 replicas
each, for a total of 6 VMs. The first master (in purple) will
handle hash slots 0-8191, and the second master (in blue) takes
slots 8192-16383. Each pair of replicas contain a complete copy
of the hash slots its master is responsible for.

In the event of failure of a master, one of its replicas will
promote to a master, ensuring consistent cluster operations.

Clustered nodes persist their data to disk using AOF for durability,
and also rely on replication for additional redundancy.

### Cluster Formation

The cluster is automatically formed by the `post-deploy` script on the
bootstrap node. The script:

1. Verifies all nodes have clustering enabled
2. Introduces nodes to each other via `CLUSTER MEET` commands
3. Assigns hash slots (0-16383) evenly across masters
4. Configures replicas for each master
5. Waits for cluster convergence

TLS connections between cluster nodes use stunnel for secure communication.

### Configuration Options

- *type* - Specify the job type: `cluster-7`, `cluster-8`, or `cluster-9`.
  This determines which Valkey version is deployed. We recommend `cluster-8`
  for production use.

- *vm_type* - The name of a BOSH `vm_type` from your cloud-config.
  You can use this to size your Valkey appropriate to your workload
  requirements, in terms of RAM and CPU.

- *azs* - A list of BOSH availability zone names (per
  cloud-config), across which to stripe the nodes. By default,
  nodes will be put in `z1` and `z2`.

- *network* - The name of the network to deploy these instances to.
  This network should be defined in your cloud-config, and should
  be large enough to handle your anticipated service footprint.
  It does not need any static IP addresses.

  By default, VMs will be deployed into a network named
  `valkey-service`.

- *masters* - How many Valkey Master instances to spin. Must be at
  least 1. There is no default.

- *replicas* - How many Valkey Replica instances to provision for
  each Valkey Master. Must be at least 1, which is the default.
  Normally, you only need 1-3 replicas, depending on your
  tolerance for data loss.

### Example Configuration

Here's the configuration for the 6-VM 2x2 cluster pictured in the
topology diagram above using Valkey 8:

```yaml
instance_groups:
  - name: blacksmith
    jobs:
      - name:    valkey-blacksmith-plans
        release: valkey-forge
        properties:
          plans:
            clustered:
              type:     cluster-8
              masters:  2
              replicas: 2
```

Here, we provide two different clustered configurations, one with
wide sharding but shallow replication (4x1), and another 3-node
minimal cluster on very large (per cloud-config) VMs:

```yaml
instance_groups:
  - name: blacksmith
    jobs:
      - name:    valkey-blacksmith-plans
        release: valkey-forge
        properties:
          plans:
            clustered-4x1:
              type:     cluster-8
              masters:  4
              replicas: 1

            minimal:
              type:     cluster-8
              vm_type:  very-large
              masters:  1
              replicas: 2
```

## TLS Support

All Valkey jobs support TLS encryption with flexible configuration:

- **TLS-Only Mode**: Only encrypted connections on port 16379 (or 6379)
- **Dual-Mode**: Both encrypted (16379) and plaintext (6379) connections

Configure TLS in the `valkey-blacksmith-plans` properties:

```yaml
properties:
  valkey:
    tls:
      enabled: true
      dual-mode: true  # optional, allows both TLS and non-TLS
      ca: |
        -----BEGIN CERTIFICATE-----
        ...
        -----END CERTIFICATE-----
      ca_cert: |
        -----BEGIN CERTIFICATE-----
        ...
        -----END CERTIFICATE-----
      ca_key: |
        -----BEGIN PRIVATE KEY-----
        ...
        -----END PRIVATE KEY-----
```

TLS versions supported: TLSv1.2, TLSv1.3

## Security - Hard Coded Valkey Configuration Parameters

For security reasons the following Valkey commands have been disabled in all plan types:

1. CONFIG
2. SAVE
3. BGSAVE
4. DEBUG
5. SHUTDOWN
6. SLAVEOF
7. ACL (Use authentication password instead)

## Valkey Configuration Plan Parameters

These Valkey configuration parameters can be used when plans are created during forge deployment.
Some of these parameters may depend on other parameters or plan model properties.

| Parameter | Description | Default | Notes |
| --------- | ----------- | ------- | ----- |
| auth.password | The password required of clients wishing to use this Valkey instance | | |
| persistent | Whether or not the Valkey dataset should persist to disk (via AOF semantics) | true | |
| lua_scripting_enabled | Whether or not to allow Lua scripting | true | |
| client_connections | Set the max number of connected clients at the same time | 10000 | |
| client_timeout | Close the connection after a client is idle for N seconds | 0 | 0 = disable |
| client_tcpkeepalive | If non-zero, use SO_KEEPALIVE to send TCP ACKs to clients in absence of communication | 300 | |
| valkey_maxmemory | Set a memory usage limit to the specified amount of bytes | 0 | 0 = VM limit |
| valkey_maxmemory-policy | Sets the behavior Valkey follows when maxmemory is reached | allkeys-lru | allkeys-lru, noeviction,<br/> volatile-lru, allkeys-random,<br/> volatile-ttl, volatile-lfu,<br/> allkeys-lfu |
| valkey_notify-keyspace-events | Sets the keyspace notifications for events that affect the Valkey data set | "" | |
| valkey_slowlog-log-slower-than | Sets the threshold execution time (microseconds). Commands that exceed this execution time are added to the slowlog | 10000 | |
| valkey_slowlog-max-len | Sets the length (count) of the slowlog queue | 128 | |
| valkey_no-appendfsync-on-rewrite | If you have latency problems turn this to true. Otherwise leave it as false | false | Significant only if *persistent* is true |
| valkey_auto-aof-rewrite-percentage | Modify the percentage for auto append on rewrite | 100 | Significant only if *persistent* is true |
| valkey_auto-aof-rewrite-min-size | Modify the minimum file size for auto append on rewrite | 64mb | Significant only if *persistent* is true |
| exporter | If set to true, a Prometheus valkey_exporter will be colocated on the Valkey nodes | false | |

Memory units may be specified when specifying bytes:
- 1k => 1000 bytes
- 1kb => 1024 bytes
- 1m => 1000000 bytes
- 1mb => 1024*1024 bytes
- 1g => 1000000000 bytes
- 1gb => 1024*1024*1024 bytes
- units are case insensitive so 1GB 1Gb 1gB are all the same

## Prometheus Exporter

Enable Prometheus metrics collection by adding the `exporter: true` parameter to your plan:

```yaml
plans:
  monitored-standalone:
    type: standalone-8
    persist: true
    exporter: true
    prometheus_release_version: "30.2.0"  # optional, defaults to 30.2.0
```

The valkey_exporter will be colocated on Valkey nodes and expose metrics for Prometheus scraping.

## CF Create Service Configuration Parameters

App developers can customize the following parameters. See the [Valkey documentation][valkey-docs] for more detail.

| Property | Default | Options | Description |
| -------- | ------- | ------- | ----------- |
| **maxmemory-policy** | *allkeys-lru* | allkeys-lru, noeviction,<br/> volatile-lru,<br/> allkeys-random,<br/> volatile-ttl,<br/> volatile-lfu,<br/> allkeys-lfu | Sets the behavior Valkey follows when *maxmemory* is reached |
| **notify-keyspace-events** | "" | Set a combination of characters<br/> (e.g., *"Elg"*):<br/> K, E, g, $, l, s, h, z, x, e, A | Sets the keyspace notifications for events that affect the Valkey data set |
| **slowlog-log-slower-than** | 10000 | 0-20000 | Sets the threshold execution time (microseconds). Commands that exceed this execution time are added to the slowlog |
| **slowlog-max-len** | 128 | 1-2024 | Sets the length (count) of the slowlog queue |

## Migrating from Redis

Valkey is protocol-compatible with Redis. For a smooth migration:

1. **Read the migration guide**: See [docs/redis_to_valkey_migration.md](docs/redis_to_valkey_migration.md)
2. **Version mapping**: Redis 6/7 → Valkey 7, Redis 7+ → Valkey 8
3. **Test compatibility**: Use Valkey 7 for Redis 6/7 migrations
4. **Update clients**: Most Redis clients work with Valkey without changes
5. **Monitor performance**: Check metrics after migration

Migration helper scripts are available in `docs/migration/`.

## BOSH DNS Support

All Valkey jobs include BOSH DNS aliases for service discovery:

- Pattern: `{instance-id}.valkey.cf.internal`
- Automatically configured via `dns/aliases.json.erb` template
- Works with both standalone and cluster topologies

## Troubleshooting

For cluster-specific troubleshooting, see [docs/valkey_cluster_troubleshooting.md](docs/valkey_cluster_troubleshooting.md).

Common issues:

### Cluster Formation Fails

Check bootstrap node logs:
```bash
bosh -d service-instance-GUID logs node/0
```

Verify clustering is enabled:
```bash
bosh -d service-instance-GUID ssh node/0
sudo su - vcap
/var/vcap/packages/valkey-8/bin/valkey-cli -a PASSWORD INFO cluster
```

### TLS Connection Issues

Verify certificates are present:
```bash
bosh -d service-instance-GUID ssh standalone/0
ls -la /var/vcap/jobs/standalone-8/config/tls/
```

Test TLS connection:
```bash
valkey-cli --tls \
  --cert /var/vcap/data/standalone-8/valkey.crt \
  --key /var/vcap/data/standalone-8/valkey.key \
  --cacert /var/vcap/jobs/standalone-8/config/tls/valkey.ca \
  -h 127.0.0.1 -p 16379 -a PASSWORD PING
```

### Performance Tuning

Verify system settings:
```bash
# Check overcommit memory
sysctl vm.overcommit_memory  # Should be 1

# Check transparent huge pages
cat /sys/kernel/mm/transparent_hugepage/enabled  # Should be [never]
```

## Forge Maintainer Notes

### Upgrading Valkey Releases

1. Update version in Makefile: `VALKEY_X_VERSION = X.Y.Z`
2. Download tarball: `make fetch`
3. Add blob: `bosh add-blob ~/Downloads/valkey-X.Y.Z.tar.gz valkey/valkey-X.Y.Z.tar.gz`
4. Update blobs: `bosh upload-blobs`
5. Create dev release: `bosh create-release --name=valkey-forge --version=X.Y.Z+dev.1 --tarball=/tmp/valkey-forge.tar.gz --force`
6. Test thoroughly before creating final release
7. Document changes in `ci/release_notes.md`

### Version File Locations

Each deployed instance creates version files:
- `/var/vcap/store/{standalone,cluster}-{7,8,9}/VALKEY_VERSION` - Version number only
- `/var/vcap/store/{standalone,cluster}-{7,8,9}/VALKEY_VERSION_FULL` - Full version output

## Contributing

If you find a bug, please raise a [Github Issue][issues] first,
before submitting a PR.

We welcome contributions from the community! If you'd like to contribute:

1. Fork the repository
2. Create a branch: `git checkout -b feature-name`
3. Make your changes and commit: `git commit -m "Description of changes"`
4. Push to your fork: `git push origin feature-name`
5. Create a Pull Request

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for more details.

[broker]: https://github.com/cloudfoundry-community/blacksmith
[valkey]: https://valkey.io
[valkey-docs]: https://valkey.io/topics/config
[issues]: https://github.com/blacksmith-community/valkey-forge-boshrelease/issues
