# Redis to Valkey Migration Guide

Complete guide for migrating from Redis Forge to Valkey Forge in BOSH/Blacksmith environments.

## Overview

Valkey is protocol-compatible with Redis, making migration straightforward. This guide covers both data migration and infrastructure transition.

## Version Mapping

| Redis Version | Target Valkey Version | Compatibility | Risk Level |
|---------------|----------------------|---------------|------------|
| Redis 6.x | Valkey 7.2.11 | High | Low |
| Redis 7.0-7.2 | Valkey 7.2.11 | High | Low |
| Redis 7.2+ | Valkey 8.1.4 | Medium | Medium |
| Any version | Valkey 9.0.0 | Medium | Medium-High |

**Recommendation:**
- Redis 6/7 → **Valkey 7** (safest, tested migration path)
- New deployments → **Valkey 8** (stable, recommended)

## Pre-Migration Checklist

### 1. Assessment Phase

```bash
# Document current Redis configuration
bosh -d redis-service-instance ssh standalone/0
cat /var/vcap/jobs/standalone-*/config/redis.conf > /tmp/redis-config.txt

# Check Redis version
redis-cli INFO server | grep redis_version

# Document data size
redis-cli INFO keyspace
redis-cli DBSIZE

# Check replication status (if cluster)
redis-cli INFO replication

# Identify disabled commands
grep "rename-command" /var/vcap/jobs/*/config/redis.conf
```

### 2. Application Compatibility Check

**Client Libraries:** Most Redis clients work with Valkey without changes:
- ✅ redis-py (Python)
- ✅ ioredis (Node.js)
- ✅ Jedis (Java)
- ✅ StackExchange.Redis (C#)
- ✅ go-redis (Go)

**Test Connection:**
```bash
# Point existing client to Valkey test instance
# Verify command compatibility
# Run integration tests
```

### 3. Backup Current Data

```bash
# Method 1: AOF backup (if persistence enabled)
bosh -d redis-service-instance ssh standalone/0
sudo cp /var/vcap/store/standalone-*/redis.aof /tmp/backup-$(date +%Y%m%d).aof

# Method 2: RDB snapshot
redis-cli BGSAVE
# Wait for completion
redis-cli LASTSAVE
sudo cp /var/vcap/store/standalone-*/dump.rdb /tmp/backup-$(date +%Y%m%d).rdb

# Method 3: Replication-based (zero downtime)
# Set up Valkey as replica of Redis
# See "Zero-Downtime Migration" section below
```

## Migration Strategies

### Strategy 1: New Instance (Simplest, Downtime Required)

**Best for:** Development, staging, non-critical services

**Steps:**

1. **Create Valkey Service Instance:**
   ```bash
   cf create-service valkey standalone-8 my-valkey-instance
   cf service my-valkey-instance  # Wait for completion
   ```

2. **Export Data from Redis:**
   ```bash
   # Using redis-cli with --rdb
   redis-cli --rdb /tmp/redis-dump.rdb -h redis-host -p 6379 -a password

   # Or using RIOT (Redis Input/Output Tool)
   riot -h redis-host -p 6379 -a redis-pass \
     replicate -h valkey-host -p 6379 -a valkey-pass
   ```

3. **Import Data to Valkey:**
   ```bash
   # Method A: Copy RDB file
   bosh -d valkey-service-instance scp /tmp/redis-dump.rdb standalone/0:/tmp/
   bosh -d valkey-service-instance ssh standalone/0
   sudo monit stop standalone-8
   sudo cp /tmp/redis-dump.rdb /var/vcap/store/standalone-8/dump.rdb
   sudo chown vcap:vcap /var/vcap/store/standalone-8/dump.rdb
   sudo monit start standalone-8

   # Method B: RESTORE commands (for selective migration)
   # See migration script: redis-to-valkey-dump-restore.pl
   ```

4. **Update Application Bindings:**
   ```bash
   # Unbind from Redis
   cf unbind-service my-app redis-instance

   # Bind to Valkey
   cf bind-service my-app my-valkey-instance
   cf restage my-app
   ```

5. **Verify and Cleanup:**
   ```bash
   # Verify data
   cf ssh my-app
   # Test application functionality

   # Delete old Redis instance
   cf delete-service redis-instance
   ```

**Downtime:** 5-30 minutes depending on data size

### Strategy 2: Blue-Green Deployment (Minimal Downtime)

**Best for:** Production services with planned maintenance windows

**Steps:**

1. **Deploy Valkey Alongside Redis:**
   ```bash
   cf create-service valkey standalone-8 my-valkey-blue
   ```

2. **Replicate Data:**
   ```bash
   # Use migration script
   ./docs/migration/redis-to-valkey-replicate.pl \
     --redis-host redis.internal \
     --redis-port 6379 \
     --redis-password $REDIS_PASS \
     --valkey-host valkey.internal \
     --valkey-port 6379 \
     --valkey-password $VALKEY_PASS \
     --continuous
   ```

3. **Deploy Green Application:**
   ```bash
   cf push my-app-green -f manifest.yml --no-start
   cf bind-service my-app-green my-valkey-blue
   cf start my-app-green
   ```

4. **Smoke Test Green:**
   ```bash
   # Run validation tests against green deployment
   curl https://my-app-green.cfapps.io/health
   ```

5. **Switch Traffic:**
   ```bash
   # Map routes
   cf map-route my-app-green cfapps.io --hostname my-app
   cf unmap-route my-app cfapps.io --hostname my-app
   ```

6. **Cleanup Blue:**
   ```bash
   cf delete my-app
   cf delete-service redis-instance
   cf rename my-app-green my-app
   ```

**Downtime:** < 1 minute (DNS propagation)

### Strategy 3: Zero-Downtime Migration (Complex)

**Best for:** Mission-critical production services

**Architecture:**
```
┌─────────────┐         ┌─────────────┐
│   Redis     │────────>│   Valkey    │
│   Master    │ Replica │   (Replica) │
└─────────────┘         └─────────────┘
      ▲                        │
      │                        │
      │                        ▼
  ┌───┴───┐              ┌─────────┐
  │  App  │──┐           │   App   │
  │(Read) │  │Gradually  │ (Read   │
  └───────┘  │switch     │  Write) │
             └───────────>└─────────┘
```

**Steps:**

1. **Configure Valkey as Redis Replica:**
   ```bash
   # Temporarily configure Valkey to replicate from Redis
   # This requires custom configuration
   bosh -d valkey-instance ssh standalone/0
   /var/vcap/packages/valkey-8/bin/valkey-cli CONFIG SET replicaof redis-host 6379
   /var/vcap/packages/valkey-8/bin/valkey-cli CONFIG SET masterauth redis-password

   # Monitor replication
   /var/vcap/packages/valkey-8/bin/valkey-cli INFO replication
   # Wait for master_link_status:up
   ```

2. **Verify Data Sync:**
   ```bash
   # Check replication offset
   redis-cli INFO replication | grep master_repl_offset
   valkey-cli INFO replication | grep master_repl_offset
   # Offsets should match
   ```

3. **Promote Valkey to Master:**
   ```bash
   /var/vcap/packages/valkey-8/bin/valkey-cli REPLICAOF NO ONE
   ```

4. **Update Application Config:**
   ```bash
   # Use feature flags or config service
   # Gradually shift read traffic to Valkey
   # Then shift write traffic
   ```

5. **Decommission Redis:**
   ```bash
   # After 100% traffic on Valkey and validation period
   cf delete-service redis-instance
   ```

**Downtime:** None (gradual switchover)

## Configuration Migration

### Translate Redis Config to Valkey

```bash
# Automated translation script
./docs/migration/redis-config-to-valkey.pl redis.conf > valkey.conf

# Manual translations:
# redis.conf                    → valkey.conf
redis.tls.enabled               → valkey.tls.enabled
redis.maxmemory                 → valkey.maxmemory
redis_maxmemory-policy          → valkey_maxmemory-policy
redis-exporter                  → valkey-exporter (Prometheus)
```

### Property Mapping

| Redis Forge Property | Valkey Forge Property | Notes |
|----------------------|----------------------|-------|
| `redis.tls.*` | `valkey.tls.*` | Direct mapping |
| `redis.maxmemory` | `valkey.maxmemory` | Same format |
| `redis.disabled-commands` | `valkey.disabled-commands` | Same list, ACL added |
| `redis_maxmemory-policy` | `valkey_maxmemory-policy` | Same options |
| `redis_slowlog-*` | `valkey_slowlog-*` | Same values |
| `service.id: redis` | `service.id: valkey` | Change for new service |
| `redis-blacksmith-plans` | `valkey-blacksmith-plans` | Job name change |

### Example Manifest Transformation

**Before (Redis):**
```yaml
properties:
  plans:
    small:
      type: standalone-7
      persist: true
      disk_size: 4_096
      redis_maxmemory-policy: allkeys-lru
      redis_maxmemory: 2gb
```

**After (Valkey):**
```yaml
properties:
  plans:
    small:
      type: standalone-8  # Version change
      persist: true
      disk_size: 4_096
      valkey_maxmemory-policy: allkeys-lru  # Property rename
      valkey_maxmemory: 2gb  # Property rename
```

## Cluster Migration

### Considerations

- Cluster migration is more complex due to slot distribution
- Consider shard count compatibility
- Plan for potential resharding

### Approach 1: New Cluster with Data Import

```bash
# 1. Create Valkey cluster with same topology
cf create-service valkey cluster-8-2x2 my-valkey-cluster \
  -c '{"masters": 2, "replicas": 2}'

# 2. Use cluster-aware migration tool
./docs/migration/redis-cluster-to-valkey.pl \
  --redis-cluster redis-node1:6379,redis-node2:6379 \
  --valkey-cluster valkey-node1:6379,valkey-node2:6379 \
  --password $PASSWORD

# 3. Verify slot distribution
valkey-cli --cluster check valkey-node1:6379
```

### Approach 2: Shard-by-Shard Migration

```bash
# For each Redis master:
# 1. Create corresponding Valkey master
# 2. Migrate keys for that master's slot range
# 3. Update application routing
# 4. Repeat for next shard
```

## Client Application Updates

### Minimal Changes Required

Most applications need NO code changes:

```python
# Python - No changes needed
import redis
r = redis.Redis(host='valkey-host', port=6379, password='pass')
r.set('key', 'value')

# Node.js - No changes needed
const Redis = require('ioredis');
const client = new Redis({
  host: 'valkey-host',
  port: 6379,
  password: 'pass'
});

# Java - No changes needed
Jedis jedis = new Jedis("valkey-host", 6379);
jedis.auth("pass");
```

### Connection String Updates

```bash
# Old
redis://user:password@redis-host:6379/0

# New
redis://user:password@valkey-host:6379/0
# OR (optional, for clarity)
valkey://user:password@valkey-host:6379/0
```

### TLS Configuration

```bash
# If TLS enabled, update connection parameters
# Old
redis://redis-host:16379?tls=true

# New
redis://valkey-host:16379?tls=true
```

## Monitoring and Validation

### Post-Migration Checks

```bash
# 1. Verify key count
valkey-cli DBSIZE

# 2. Spot check keys
valkey-cli RANDOMKEY
valkey-cli GET <key>

# 3. Check memory usage
valkey-cli INFO memory

# 4. Verify replication (if cluster)
valkey-cli INFO replication

# 5. Test application functionality
# Run smoke tests
# Run integration tests
# Monitor error rates

# 6. Performance comparison
# Compare latency metrics
# Check throughput
# Monitor resource usage
```

### Monitoring Metrics

| Metric | Pre-Migration | Post-Migration | Delta |
|--------|---------------|----------------|-------|
| Response time (p95) | X ms | Y ms | +/- Z% |
| Commands/sec | A | B | +/- C% |
| Memory usage | D MB | E MB | +/- F% |
| Error rate | G% | H% | +/- I% |

## Rollback Plan

### If Issues Detected

1. **Keep Redis Instance Active** during validation period
2. **Revert Application Binding:**
   ```bash
   cf unbind-service my-app valkey-instance
   cf bind-service my-app redis-instance
   cf restage my-app
   ```
3. **Analyze Issues:**
   - Check logs: `bosh -d valkey-instance logs`
   - Compare behavior
   - Identify incompatibilities

4. **Retry with Adjustments:**
   - Use Valkey 7 if Valkey 8 had issues
   - Adjust configuration
   - Test in non-production first

## Troubleshooting Common Issues

### Data Loss or Inconsistency

**Cause:** Incomplete replication or export
**Solution:**
```bash
# Verify source data before deletion
redis-cli DBSIZE > /tmp/redis-keys-before.txt
valkey-cli DBSIZE > /tmp/valkey-keys-after.txt
diff /tmp/redis-keys-before.txt /tmp/valkey-keys-after.txt

# Re-run migration for missing keys
```

### Performance Degradation

**Causes:**
- Different memory allocator
- AOF fsync settings
- Transparent Huge Pages

**Solutions:**
```bash
# Check system settings
cat /sys/kernel/mm/transparent_hugepage/enabled  # Should be [never]

# Tune AOF if needed
valkey-cli CONFIG SET appendfsync everysec

# Adjust memory policy
valkey-cli CONFIG SET maxmemory-policy allkeys-lru
```

### Command Not Supported

**Issue:** Some Redis commands may have subtle differences

**Solution:**
```bash
# Check Valkey version compatibility
valkey-cli INFO server

# Review deprecated commands
# https://valkey.io/topics/compatibility

# Update application code if needed
```

## Migration Timeline Example

### Small Service (< 1GB data)

| Phase | Duration | Description |
|-------|----------|-------------|
| Planning | 1 day | Assessment and strategy |
| Testing | 2 days | Dev/staging migration |
| Production | 4 hours | Blue-green deployment |
| Validation | 1 week | Monitoring period |
| Cleanup | 1 day | Decommission Redis |

### Large Service (> 10GB data, clustered)

| Phase | Duration | Description |
|-------|----------|-------------|
| Planning | 1 week | Detailed assessment |
| Testing | 2 weeks | Comprehensive testing |
| Production | 2 days | Zero-downtime migration |
| Validation | 2 weeks | Extended monitoring |
| Cleanup | 1 week | Gradual decommission |

## Helper Scripts

Provided migration scripts in `docs/migration/`:

1. **redis-to-valkey-dump-restore.pl** - Dump and restore individual keys
2. **redis-config-to-valkey.pl** - Translate Redis config to Valkey
3. **redis-cluster-to-valkey.pl** - Migrate clustered deployments

Usage examples provided in each script header.

## Additional Resources

- [Valkey Documentation](https://valkey.io/documentation/)
- [Redis to Valkey Compatibility Guide](https://valkey.io/topics/compatibility)
- [BOSH Documentation](https://bosh.io/docs/)
- [Blacksmith Documentation](https://github.com/cloudfoundry-community/blacksmith)

## Support

For migration assistance:
- Create issue: [Valkey Forge Issues](https://github.com/blacksmith-community/valkey-forge-boshrelease/issues)
- Community support: [Valkey Discussions](https://github.com/valkey-io/valkey/discussions)
