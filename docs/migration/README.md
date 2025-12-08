# Redis to Valkey Migration Scripts

This directory contains helper scripts for migrating from Redis Forge to Valkey Forge.

## Scripts

| Script | Purpose | Version |
|--------|---------|---------|
| `redis-config-to-valkey.pl` | Translate Redis configuration to Valkey format | 1.1.0 |
| `redis-to-valkey-dump-restore.pl` | Migrate data from standalone Redis to Valkey | 1.1.0 |
| `redis-cluster-to-valkey.pl` | Migrate data from Redis cluster to Valkey cluster | 1.1.0 |

## Prerequisites

These scripts are designed to run on BOSH VMs (stemcells) using only core Perl modules:
- Perl 5.x (included in Ubuntu Jammy stemcell)
- No external CPAN modules required

## Quick Start

### 1. Preview Migration (Dry Run)

Always start with `--dry-run` to see what would happen:

```bash
# Upload script to Redis VM
bosh -d redis-service-instance scp redis-to-valkey-dump-restore.pl standalone/0:/tmp/

# SSH to the VM
bosh -d redis-service-instance ssh standalone/0

# Preview the migration
sudo /tmp/redis-to-valkey-dump-restore.pl \
  --redis-host localhost --redis-password $REDIS_PASS \
  --valkey-host valkey.internal --valkey-password $VALKEY_PASS \
  --dry-run
```

### 2. Execute Migration

After verifying the dry-run output, remove `--dry-run` to execute:

```bash
sudo /tmp/redis-to-valkey-dump-restore.pl \
  --redis-host localhost --redis-password $REDIS_PASS \
  --valkey-host valkey.internal --valkey-password $VALKEY_PASS
```

## Version Compatibility

| Source Redis | Target Valkey | Risk Level | Notes |
|--------------|---------------|------------|-------|
| Redis 6.x | Valkey 7.2.11 | Low | Recommended path |
| Redis 7.0-7.2 | Valkey 7.2.11 | Low | Compatible |
| Redis 7.2+ | Valkey 8.1.4 | Medium | Test thoroughly |

**Recommendation:** Redis 6 users should migrate to Valkey 7.2.11 for the safest path.

## Common Options

All scripts support these options:

| Option | Description |
|--------|-------------|
| `-n, --dry-run` | Preview changes without executing |
| `-v, --verbose` | Enable detailed output |
| `-h, --help` | Show usage information |

## Script-Specific Usage

### Config Translator

```bash
# Translate config file
./redis-config-to-valkey.pl --input redis.conf --output valkey.conf

# Preview without writing
./redis-config-to-valkey.pl --input redis.conf --dry-run
```

### Standalone Migration

```bash
# Full migration
./redis-to-valkey-dump-restore.pl \
  --redis-host localhost --redis-password secret \
  --valkey-host valkey.internal --valkey-password secret

# Migrate specific key patterns
./redis-to-valkey-dump-restore.pl \
  --redis-host localhost --redis-password secret \
  --valkey-host valkey.internal --valkey-password secret \
  --pattern "user:*"
```

### Cluster Migration

```bash
# Analyze cluster (dry-run)
./redis-cluster-to-valkey.pl \
  --redis-cluster redis1:6379,redis2:6379,redis3:6379 \
  --password secret \
  --dry-run

# Full cluster migration
./redis-cluster-to-valkey.pl \
  --redis-cluster redis1:6379,redis2:6379,redis3:6379 \
  --valkey-cluster valkey1:6379,valkey2:6379,valkey3:6379 \
  --password secret
```

## See Also

- [Main Migration Guide](../redis_to_valkey_migration.md)
- [Valkey Cluster Troubleshooting](../valkey_cluster_troubleshooting.md)
- [Topology Diagrams](../topology_diagrams.md)
