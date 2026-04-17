# Valkey Cluster Troubleshooting Guide

Comprehensive troubleshooting guide for Valkey cluster deployments in BOSH/Blacksmith environments.

## Table of Contents

1. [Quick Diagnostics](#quick-diagnostics)
2. [Cluster Formation Issues](#cluster-formation-issues)
3. [Node Communication Problems](#node-communication-problems)
4. [Replication Issues](#replication-issues)
5. [TLS/Security Issues](#tlssecurity-issues)
6. [Performance Problems](#performance-problems)
7. [Data Consistency Issues](#data-consistency-issues)
8. [Recovery Procedures](#recovery-procedures)

## Quick Diagnostics

### Health Check Commands

```bash
# Check cluster status from any node
bosh -d service-instance-GUID ssh node/0
sudo su - vcap
export VALKEY_PASSWORD=$(cat /var/vcap/jobs/cluster/config/valkey.conf | grep "^requirepass" | awk '{print $2}')
/var/vcap/packages/valkey-8/bin/valkey-cli -a $VALKEY_PASSWORD CLUSTER INFO

# Get cluster nodes
/var/vcap/packages/valkey-8/bin/valkey-cli -a $VALKEY_PASSWORD CLUSTER NODES

# Check individual node info
/var/vcap/packages/valkey-8/bin/valkey-cli -a $VALKEY_PASSWORD INFO replication
/var/vcap/packages/valkey-8/bin/valkey-cli -a $VALKEY_PASSWORD INFO server
```

### Key Health Indicators

```bash
# Expected healthy output:
cluster_state:ok
cluster_slots_assigned:16384
cluster_slots_ok:16384
cluster_slots_pfail:0
cluster_slots_fail:0
cluster_known_nodes:6  # Should match your instance count
```

## Cluster Formation Issues

### Symptom: Cluster Never Forms

**Indicators:**
- `cluster_state:fail`
- `cluster_slots_assigned:0`
- Post-deploy script times out
- Logs show "waiting for nodes to connect"

**Diagnosis Steps:**

1. **Verify bootstrap node:**
   ```bash
   bosh -d service-instance-GUID instances
   # Look for node/0 with bootstrap: true
   ```

2. **Check post-deploy logs:**
   ```bash
   bosh -d service-instance-GUID logs node/0
   # Look in /var/vcap/sys/log/cluster/post-deploy.*
   ```

3. **Verify clustering is enabled:**
   ```bash
   bosh -d service-instance-GUID ssh node/0
   sudo su - vcap
   /var/vcap/packages/valkey-8/bin/valkey-cli -a $PASSWORD INFO cluster | grep cluster_enabled
   # Expected: cluster_enabled:1
   ```

**Common Causes & Solutions:**

| Cause | Solution |
|-------|----------|
| DNS resolution failure | Check BOSH DNS: `dig node-0.valkey-service.service.cf.internal` |
| Incorrect password | Verify password in `/var/vcap/jobs/cluster/config/valkey.conf` |
| Port blocked | Check security groups allow 6379/16379 |
| Node not accessible | Verify network configuration and routing |
| Bootstrap flag missing | Redeploy with correct bootstrap configuration |

**Resolution:**

```bash
# Manual cluster formation (if post-deploy failed)
bosh -d service-instance-GUID ssh node/0
sudo su - vcap
export PASSWORD="your-password"

# Get all node IPs
bosh -d service-instance-GUID instances --json | jq -r '.Tables[0].Rows[].ips'

# Meet all nodes (example for 6-node cluster)
/var/vcap/packages/valkey-8/bin/valkey-cli -a $PASSWORD CLUSTER MEET 10.0.1.2 6379
/var/vcap/packages/valkey-8/bin/valkey-cli -a $PASSWORD CLUSTER MEET 10.0.1.3 6379
# ... repeat for all nodes

# Assign slots to first master (0-8191)
/var/vcap/packages/valkey-8/bin/valkey-cli -a $PASSWORD CLUSTER ADDSLOTS {0..8191}

# On second master, assign remaining slots (8192-16383)
bosh -d service-instance-GUID ssh node/1
/var/vcap/packages/valkey-8/bin/valkey-cli -a $PASSWORD CLUSTER ADDSLOTS {8192..16383}

# Configure replicas
# Get master IDs first
/var/vcap/packages/valkey-8/bin/valkey-cli -a $PASSWORD CLUSTER NODES | grep master

# On each replica node
bosh -d service-instance-GUID ssh node/2
/var/vcap/packages/valkey-8/bin/valkey-cli -a $PASSWORD CLUSTER REPLICATE <master-1-id>
```

### Symptom: Cluster Partially Formed

**Indicators:**
- Some slots assigned, but not all 16384
- `cluster_slots_assigned` < 16384
- Some nodes not showing in `CLUSTER NODES`

**Diagnosis:**

```bash
# Check slot distribution
/var/vcap/packages/valkey-8/bin/valkey-cli -a $PASSWORD CLUSTER SLOTS

# Identify missing slots
for i in {0..16383}; do
  /var/vcap/packages/valkey-8/bin/valkey-cli -a $PASSWORD CLUSTER KEYSLOT test-$i > /dev/null 2>&1 || echo "Slot $i not assigned"
done
```

**Resolution:**

```bash
# Identify which master is missing slots
/var/vcap/packages/valkey-8/bin/valkey-cli -a $PASSWORD CLUSTER NODES

# Manually assign missing slots to appropriate master
/var/vcap/packages/valkey-8/bin/valkey-cli -a $PASSWORD CLUSTER ADDSLOTS <missing-slots>
```

## Node Communication Problems

### Symptom: Nodes Showing as Disconnected

**Indicators:**
- `CLUSTER NODES` shows `disconnected` state
- `cluster_stats_messages_received:0`
- Ping failures between nodes

**Diagnosis:**

```bash
# From node/0, test connectivity to all other nodes
for ip in 10.0.1.2 10.0.1.3 10.0.1.4; do
  echo "Testing $ip..."
  nc -zv $ip 6379
  nc -zv $ip 16379  # If TLS enabled
done

# Check cluster bus port (node port + 10000)
nc -zv 10.0.1.2 16379  # Cluster bus for node on 6379
```

**Common Causes:**

1. **Security Group Restrictions:**
   ```bash
   # Required ports:
   # - 6379 (client connections)
   # - 16379 (TLS client connections, if enabled)
   # - 16379 (cluster bus, port + 10000)
   ```

2. **Network Partitioning:**
   ```bash
   # Test from each node to every other node
   bosh -d service-instance-GUID ssh node/X
   for i in 0 1 2 3 4 5; do
     ping -c 1 node-$i.valkey-service.service.cf.internal
   done
   ```

3. **DNS Issues:**
   ```bash
   # Verify BOSH DNS resolution
   dig @169.254.0.2 node-0.valkey-service.service.cf.internal
   ```

**Resolution:**

```bash
# Update security groups (from BOSH Director or cloud config)
# Add rules:
# - Allow TCP 6379-16389 from valkey-service network to itself
# - Allow ICMP for health checks

# Force node reintroduction
/var/vcap/packages/valkey-8/bin/valkey-cli -a $PASSWORD CLUSTER FORGET <disconnected-node-id>
/var/vcap/packages/valkey-8/bin/valkey-cli -a $PASSWORD CLUSTER MEET <disconnected-node-ip> 6379
```

## Replication Issues

### Symptom: Replica Not Syncing

**Indicators:**
- `master_link_status:down` on replica
- `master_sync_in_progress:0` but replication not working
- Increasing `master_repl_offset` difference

**Diagnosis:**

```bash
# On replica node
/var/vcap/packages/valkey-8/bin/valkey-cli -a $PASSWORD INFO replication

# Look for:
# role:slave
# master_link_status:up  # Should be 'up'
# master_last_io_seconds_ago:<5  # Should be small
# master_sync_in_progress:0  # Unless currently syncing
```

**Common Causes & Solutions:**

1. **Authentication Failure:**
   ```bash
   # Check masterauth matches master's requirepass
   grep "masterauth" /var/vcap/jobs/cluster/config/valkey.conf
   grep "requirepass" /var/vcap/jobs/cluster/config/valkey.conf
   # These should match
   ```

2. **Network Issues:**
   ```bash
   # Test connection to master
   /var/vcap/packages/valkey-8/bin/valkey-cli -h <master-ip> -p 6379 -a $PASSWORD PING
   ```

3. **Master Unreachable:**
   ```bash
   # Check master node status
   bosh -d service-instance-GUID ssh node/0
   /var/vcap/packages/valkey-8/bin/valkey-cli -a $PASSWORD INFO server
   ```

**Resolution:**

```bash
# Force replica to resync
/var/vcap/packages/valkey-8/bin/valkey-cli -a $PASSWORD CLUSTER REPLICATE <master-id>

# If still failing, break and recreate replication
/var/vcap/packages/valkey-8/bin/valkey-cli -a $PASSWORD CLUSTER RESET SOFT
# Wait 10 seconds
/var/vcap/packages/valkey-8/bin/valkey-cli -a $PASSWORD CLUSTER MEET <master-ip> 6379
/var/vcap/packages/valkey-8/bin/valkey-cli -a $PASSWORD CLUSTER REPLICATE <master-id>
```

### Symptom: Replica Promotion Not Happening

**Indicators:**
- Master node down but no replica promoted
- `cluster_state:fail` after master failure
- Manual failover needed

**Diagnosis:**

```bash
# Check failover configuration
/var/vcap/packages/valkey-8/bin/valkey-cli -a $PASSWORD CONFIG GET cluster-*

# Expected:
# cluster-node-timeout:15000
# cluster-slave-validity-factor:0
# cluster-require-full-coverage:yes
```

**Resolution:**

```bash
# Manual failover from replica
bosh -d service-instance-GUID ssh node/2  # A replica of failed master
/var/vcap/packages/valkey-8/bin/valkey-cli -a $PASSWORD CLUSTER FAILOVER

# Force failover if necessary (data loss possible)
/var/vcap/packages/valkey-8/bin/valkey-cli -a $PASSWORD CLUSTER FAILOVER FORCE
```

## TLS/Security Issues

### Symptom: TLS Connection Failures

**Indicators:**
- "SSL routines" errors in logs
- Connection refused on port 16379
- Certificate validation failures

**Diagnosis:**

```bash
# Verify TLS is enabled
grep "tls-port" /var/vcap/jobs/cluster/config/valkey.conf

# Check certificates exist and are valid
ls -la /var/vcap/jobs/cluster/config/tls/
ls -la /var/vcap/data/cluster/valkey.{crt,key}

# Verify certificate dates
openssl x509 -in /var/vcap/jobs/cluster/config/tls/valkey.cert -noout -dates
openssl x509 -in /var/vcap/data/cluster/valkey.crt -noout -dates
```

**Common Issues:**

1. **Certificate Expired:**
   ```bash
   # Check expiration
   openssl x509 -in /var/vcap/data/cluster/valkey.crt -noout -enddate

   # Regenerate (will require redeploy)
   bosh -d service-instance-GUID recreate
   ```

2. **Wrong Certificate Permissions:**
   ```bash
   # Fix permissions
   sudo chown vcap:vcap /var/vcap/data/cluster/valkey.*
   sudo chmod 600 /var/vcap/data/cluster/valkey.key
   ```

3. **Stunnel Not Running (for cluster TLS):**
   ```bash
   # Check stunnel process
   ps aux | grep stunnel

   # Check stunnel logs
   cat /var/vcap/sys/log/cluster/post-deploy.*
   ```

**Test TLS Connection:**

```bash
# Direct TLS test
/var/vcap/packages/valkey-8/bin/valkey-cli \
  --tls \
  --cert /var/vcap/data/cluster/valkey.crt \
  --key /var/vcap/data/cluster/valkey.key \
  --cacert /var/vcap/jobs/cluster/config/tls/valkey.ca \
  -h 127.0.0.1 -p 16379 -a $PASSWORD PING

# OpenSSL test
openssl s_client -connect 127.0.0.1:16379 \
  -cert /var/vcap/data/cluster/valkey.crt \
  -key /var/vcap/data/cluster/valkey.key \
  -CAfile /var/vcap/jobs/cluster/config/tls/valkey.ca
```

## Performance Problems

### Symptom: High Latency / Slow Responses

**Diagnosis:**

```bash
# Check slowlog
/var/vcap/packages/valkey-8/bin/valkey-cli -a $PASSWORD SLOWLOG GET 10

# Monitor real-time commands
/var/vcap/packages/valkey-8/bin/valkey-cli -a $PASSWORD MONITOR

# Check memory usage
/var/vcap/packages/valkey-8/bin/valkey-cli -a $PASSWORD INFO memory

# System metrics
top
iostat -x 1 5
vmstat 1 5
```

**Common Causes:**

1. **Memory Pressure / Eviction:**
   ```bash
   # Check eviction stats
   /var/vcap/packages/valkey-8/bin/valkey-cli -a $PASSWORD INFO stats | grep evicted

   # Check maxmemory policy
   /var/vcap/packages/valkey-8/bin/valkey-cli -a $PASSWORD CONFIG GET maxmemory*

   # Solution: Increase VM size or tune maxmemory
   ```

2. **Disk I/O (AOF fsync):**
   ```bash
   # Check AOF rewrite status
   /var/vcap/packages/valkey-8/bin/valkey-cli -a $PASSWORD INFO persistence

   # Tune AOF settings (if latency spikes during rewrites)
   /var/vcap/packages/valkey-8/bin/valkey-cli -a $PASSWORD CONFIG SET no-appendfsync-on-rewrite yes
   ```

3. **Network Saturation:**
   ```bash
   # Monitor network
   iftop
   nethogs

   # Check network errors
   netstat -i
   ```

4. **Transparent Huge Pages:**
   ```bash
   # Verify THP is disabled
   cat /sys/kernel/mm/transparent_hugepage/enabled
   # Should show: always madvise [never]

   # If not disabled, check pre-start script ran
   cat /var/vcap/sys/log/cluster/pre-start.*
   ```

**Performance Tuning:**

```bash
# Connection pooling (client-side)
# Use connection pools with min_idle_connections

# Pipeline commands (client-side)
# Batch multiple commands in a single round-trip

# Adjust timeout settings
/var/vcap/packages/valkey-8/bin/valkey-cli -a $PASSWORD CONFIG SET tcp-keepalive 60

# Monitor command stats
/var/vcap/packages/valkey-8/bin/valkey-cli -a $PASSWORD INFO commandstats
```

## Data Consistency Issues

### Symptom: Missing Keys or Data Mismatch

**Diagnosis:**

```bash
# Check cluster coverage
/var/vcap/packages/valkey-8/bin/valkey-cli -a $PASSWORD CLUSTER INFO | grep slots

# Verify slot ownership
/var/vcap/packages/valkey-8/bin/valkey-cli -a $PASSWORD CLUSTER SLOTS

# Check for importing/migrating slots
/var/vcap/packages/valkey-8/bin/valkey-cli -a $PASSWORD CLUSTER NODES | grep -E "importing|migrating"

# Scan for keys in wrong slots (diagnostic script)
/var/vcap/packages/valkey-8/bin/valkey-cli -a $PASSWORD --cluster check 127.0.0.1:6379
```

**Common Causes:**

1. **Incomplete Slot Migration:**
   ```bash
   # Find stuck migration
   /var/vcap/packages/valkey-8/bin/valkey-cli -a $PASSWORD CLUSTER NODES

   # Fix: Complete or abort migration
   /var/vcap/packages/valkey-8/bin/valkey-cli -a $PASSWORD CLUSTER SETSLOT <slot> NODE <target-node-id>
   ```

2. **Split-Brain Scenario:**
   ```bash
   # Check for multiple masters claiming same slots
   for node in node-{0..5}; do
     echo "=== $node ==="
     bosh -d service-instance-GUID ssh $node "sudo su - vcap -c '/var/vcap/packages/valkey-8/bin/valkey-cli -a $PASSWORD CLUSTER NODES | grep myself'"
   done
   ```

## Recovery Procedures

### Complete Cluster Reset

**WARNING: This will lose all data. Use only as last resort.**

```bash
# 1. Stop all Valkey processes
bosh -d service-instance-GUID ssh node/0
sudo monit stop cluster

# 2. Remove cluster state files from ALL nodes
sudo rm -f /var/vcap/store/cluster/state*

# 3. Start processes
sudo monit start cluster

# 4. Wait for processes to start
watch 'sudo monit summary'

# 5. Re-run post-deploy script
bosh -d service-instance-GUID run-errand post-deploy
```

### Restore from Backup (if AOF backups available)

```bash
# 1. Stop Valkey
sudo monit stop cluster

# 2. Restore AOF file
sudo cp /var/vcap/store/backups/cluster/valkey.aof /var/vcap/store/cluster/valkey.aof
sudo chown vcap:vcap /var/vcap/store/cluster/valkey.aof

# 3. Start Valkey
sudo monit start cluster

# 4. Verify data
/var/vcap/packages/valkey-8/bin/valkey-cli -a $PASSWORD DBSIZE
```

### Force Replica Promotion

```bash
# On the replica you want to promote
/var/vcap/packages/valkey-8/bin/valkey-cli -a $PASSWORD CLUSTER FAILOVER TAKEOVER

# This will:
# 1. Promote replica to master
# 2. Assign all slots from old master
# 3. Update cluster configuration
```

## Preventive Measures

1. **Regular Health Checks:**
   ```bash
   # Automated monitoring script
   */5 * * * * /var/vcap/jobs/cluster/bin/health-check.sh
   ```

2. **Backup Strategy:**
   ```bash
   # Daily AOF backups
   0 2 * * * cp /var/vcap/store/cluster/valkey.aof /var/vcap/store/backups/cluster/valkey-$(date +\%Y\%m\%d).aof
   ```

3. **Monitoring Alerts:**
   - cluster_state != ok
   - cluster_slots_assigned != 16384
   - master_link_status:down on replicas
   - Memory usage > 80%
   - Evicted keys > threshold

4. **Regular Testing:**
   - Test failover procedures quarterly
   - Validate backup restoration monthly
   - Performance benchmarking after changes

## Getting Help

If issues persist after following this guide:

1. **Collect Diagnostics:**
   ```bash
   bosh -d service-instance-GUID logs
   bosh -d service-instance-GUID instances --ps
   ```

2. **Check Valkey Issues:**
   - [Valkey GitHub Issues](https://github.com/valkey-io/valkey/issues)
   - [Valkey Discussion Forum](https://github.com/valkey-io/valkey/discussions)

3. **BOSH/Blacksmith Support:**
   - [Blacksmith Issues](https://github.com/cloudfoundry-community/blacksmith/issues)
   - [Valkey Forge Issues](https://github.com/blacksmith-community/valkey-forge-boshrelease/issues)
