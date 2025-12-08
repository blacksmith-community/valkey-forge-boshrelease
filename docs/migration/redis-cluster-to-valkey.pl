#!/usr/bin/env perl
#
# redis-cluster-to-valkey.pl
# Migrate Redis Cluster to Valkey Cluster
# Pure Perl - No CPAN dependencies required
#
# Usage:
#   ./redis-cluster-to-valkey.pl \
#     --redis-cluster host1:6379,host2:6379 \
#     --valkey-cluster host1:6379,host2:6379 \
#     --password secret \
#     [--batch-size 100] \
#     [--dry-run]
#
use strict;
use warnings;
use IO::Socket::INET;
use Getopt::Long;
use Time::HiRes qw(time);

our $VERSION = '1.1.0';

my %opts = (
    'batch-size' => 100,
    'dry-run' => 0,
    'verbose' => 0,
);

GetOptions(\%opts,
    'redis-cluster=s',
    'valkey-cluster=s',
    'password=s',
    'redis-password=s',
    'valkey-password=s',
    'batch-size=i',
    'dry-run|n',
    'verbose|v',
    'help|h'
) or die "Error in command line arguments\n";

if ($opts{help} || !$opts{'redis-cluster'}) {
    print_usage();
    exit $opts{help} ? 0 : 1;
}

# In dry-run mode, valkey-cluster is optional
if (!$opts{'dry-run'} && !$opts{'valkey-cluster'}) {
    print "Error: --valkey-cluster is required (unless using --dry-run)\n\n";
    print_usage();
    exit 1;
}

# Parse cluster nodes
my @redis_nodes = split(/,/, $opts{'redis-cluster'});
my @valkey_nodes = $opts{'valkey-cluster'} ? split(/,/, $opts{'valkey-cluster'}) : ();

# Use specific passwords or fallback to common password
my $redis_pass = $opts{'redis-password'} || $opts{'password'};
my $valkey_pass = $opts{'valkey-password'} || $opts{'password'};

# Print header
print "=" x 60 . "\n";
if ($opts{'dry-run'}) {
    print "[DRY-RUN] Redis Cluster Migration Preview\n";
} else {
    print "Redis Cluster Migration Tool v$VERSION\n";
}
print "=" x 60 . "\n\n";

# Connect to first node of Redis cluster
print "Connecting to Redis cluster ($redis_nodes[0])...\n";
my $redis = connect_node($redis_nodes[0], $redis_pass);

# Get Redis cluster topology
print "\nAnalyzing Redis cluster topology...\n";
my $redis_slots = get_cluster_slots($redis);
print_cluster_info($redis_slots, "Redis");

# Count total keys in Redis cluster
my $total_keys = 0;
my $total_data_size = 0;
print "\nCounting keys per shard...\n";
foreach my $slot_range (@$redis_slots) {
    my ($start_slot, $end_slot, $master_host, $master_port) = @$slot_range;
    my $redis_master = connect_node("$master_host:$master_port", $redis_pass);

    send_command($redis_master, "DBSIZE");
    my $dbsize = read_response($redis_master);
    $total_keys += $dbsize if $dbsize;

    # Estimate memory usage
    send_command($redis_master, "INFO", "memory");
    my $mem_info = read_response($redis_master);
    if ($mem_info && $mem_info =~ /used_memory:(\d+)/) {
        $total_data_size += $1;
    }

    printf "  Shard %s:%d - %d keys\n", $master_host, $master_port, $dbsize || 0;
    close($redis_master);
}

printf "\nTotal keys across cluster: %d\n", $total_keys;
printf "Total data size: %.2f MB\n", $total_data_size / (1024*1024) if $total_data_size;

# In dry-run mode, show analysis and exit
if ($opts{'dry-run'}) {
    print "\n" . "=" x 60 . "\n";
    print "[DRY-RUN] Migration Plan Summary\n";
    print "=" x 60 . "\n\n";

    print "Source (Redis Cluster):\n";
    printf "  Nodes: %s\n", join(", ", @redis_nodes);
    printf "  Shards: %d\n", scalar(@$redis_slots);
    printf "  Total keys: %d\n", $total_keys;
    printf "  Total data: %.2f MB\n", $total_data_size / (1024*1024) if $total_data_size;

    if (@valkey_nodes) {
        print "\nTarget (Valkey Cluster):\n";
        printf "  Nodes: %s\n", join(", ", @valkey_nodes);

        # Try to connect and analyze Valkey cluster
        eval {
            print "\nConnecting to Valkey cluster ($valkey_nodes[0])...\n";
            my $valkey = connect_node($valkey_nodes[0], $valkey_pass);
            my $valkey_slots = get_cluster_slots($valkey);
            print_cluster_info($valkey_slots, "Valkey");

            if (verify_slot_compatibility($redis_slots, $valkey_slots)) {
                print "\n[OK] Cluster topologies are compatible.\n";
            } else {
                print "\n[WARNING] Cluster topologies may not be compatible.\n";
                print "Redis and Valkey clusters should have the same number of shards.\n";
            }
            close($valkey);
        };
        if ($@) {
            print "\n[INFO] Could not connect to Valkey cluster for validation.\n";
        }
    } else {
        print "\nTarget (Valkey Cluster):\n";
        print "  Not specified (use --valkey-cluster to specify)\n";
    }

    print "\nMigration Settings:\n";
    printf "  Batch size: %d\n", $opts{'batch-size'};

    # Estimate time
    if ($total_keys > 0) {
        my $est_rate = 500;  # Conservative estimate for cluster migration
        my $est_time = $total_keys / $est_rate;
        printf "\nEstimated migration time: %.0f seconds (%.1f minutes)\n",
            $est_time, $est_time / 60;
    }

    print "\n" . "=" x 60 . "\n";
    print "[DRY-RUN] No data was migrated.\n";
    print "Remove --dry-run to perform the actual migration.\n";
    print "=" x 60 . "\n";

    close($redis);
    exit 0;
}

# Actual migration mode - connect to Valkey cluster
print "\nConnecting to Valkey cluster ($valkey_nodes[0])...\n";
my $valkey = connect_node($valkey_nodes[0], $valkey_pass);

print "\nAnalyzing Valkey cluster topology...\n";
my $valkey_slots = get_cluster_slots($valkey);
print_cluster_info($valkey_slots, "Valkey");

# Verify slot distribution matches
if (!verify_slot_compatibility($redis_slots, $valkey_slots)) {
    die "ERROR: Cluster topologies are not compatible!\n" .
        "Redis and Valkey clusters must have the same number of shards.\n";
}

# Migrate data slot by slot
print "\n" . "=" x 60 . "\n";
print "Starting data migration...\n";
print "=" x 60 . "\n";

my $migrated_keys = 0;
my $failed_keys = 0;
my $start_time = time();

foreach my $slot_range (@$redis_slots) {
    my ($start_slot, $end_slot, $master_host, $master_port) = @$slot_range;

    print "\nMigrating slots $start_slot-$end_slot from $master_host:$master_port\n";

    # Connect to specific master
    my $redis_master = connect_node("$master_host:$master_port", $redis_pass);

    # Find corresponding Valkey master
    my $valkey_master_info = find_master_for_slots($valkey_slots, $start_slot, $end_slot);
    my $valkey_master = connect_node("$valkey_master_info->[2]:$valkey_master_info->[3]", $valkey_pass);

    printf "  -> Valkey master: %s:%d\n", $valkey_master_info->[2], $valkey_master_info->[3];

    # Migrate keys for this slot range
    my $shard_keys = 0;
    for (my $slot = $start_slot; $slot <= $end_slot; $slot++) {
        my $keys = get_keys_in_slot($redis_master, $slot);
        $shard_keys += scalar @$keys;

        foreach my $key (@$keys) {
            if (migrate_key_with_socket($redis_master, $valkey_master, $key)) {
                $migrated_keys++;
            } else {
                $failed_keys++;
                warn "Failed to migrate key: $key (slot $slot)\n" if $opts{verbose};
            }

            if ($migrated_keys % 1000 == 0) {
                my $elapsed = time() - $start_time;
                my $rate = $migrated_keys / $elapsed;
                printf "Progress: %d keys migrated (%.0f keys/sec)\n", $migrated_keys, $rate;
            }
        }
    }

    printf "  Shard complete: %d keys processed\n", $shard_keys;
    close($redis_master);
    close($valkey_master);
}

my $elapsed = time() - $start_time;
print "\n" . "=" x 60 . "\n";
print "Migration complete!\n";
print "=" x 60 . "\n";
printf "Total keys found: %d\n", $total_keys;
printf "Keys migrated: %d\n", $migrated_keys;
printf "Keys failed: %d\n", $failed_keys;
printf "Time elapsed: %.2f seconds\n", $elapsed;
printf "Average rate: %.0f keys/second\n", $migrated_keys / $elapsed if $elapsed > 0;

close($redis);
close($valkey);

sub connect_node {
    my ($node_spec, $password) = @_;

    my ($host, $port) = split(/:/, $node_spec);
    $port ||= 6379;

    my $sock = IO::Socket::INET->new(
        PeerAddr => $host,
        PeerPort => $port,
        Proto => 'tcp',
        Timeout => 10
    ) or die "Cannot connect to $host:$port: $!\n";

    $sock->autoflush(1);

    if ($password) {
        send_command($sock, "AUTH", $password);
        my $response = read_response($sock);
        die "Authentication failed on $host:$port\n" unless $response eq "OK";
    }

    return $sock;
}

sub send_command {
    my ($sock, @args) = @_;

    my $cmd = "*" . scalar(@args) . "\r\n";
    foreach my $arg (@args) {
        $cmd .= "\$" . length($arg) . "\r\n$arg\r\n";
    }

    print $sock $cmd;
}

sub read_response {
    my ($sock) = @_;

    my $line = <$sock>;
    return undef unless defined $line;

    chomp $line;

    my $type = substr($line, 0, 1);
    my $data = substr($line, 1);

    if ($type eq '+') {
        return $data;
    } elsif ($type eq '-') {
        warn "Error: $data\n";
        return undef;
    } elsif ($type eq ':') {
        return $data;
    } elsif ($type eq '$') {
        my $len = $data;
        return undef if $len == -1;

        my $bulk_data = '';
        read($sock, $bulk_data, $len);
        <$sock>;
        return $bulk_data;
    } elsif ($type eq '*') {
        my $count = $data;
        return undef if $count == -1;

        my @array;
        for (my $i = 0; $i < $count; $i++) {
            push @array, read_response($sock);
        }
        return \@array;
    }

    return undef;
}

sub get_cluster_slots {
    my ($sock) = @_;

    send_command($sock, "CLUSTER", "SLOTS");
    my $response = read_response($sock);

    my @slots;
    foreach my $slot_info (@$response) {
        my $start_slot = $slot_info->[0];
        my $end_slot = $slot_info->[1];
        my $master_info = $slot_info->[2];
        my $master_host = $master_info->[0];
        my $master_port = $master_info->[1];

        push @slots, [$start_slot, $end_slot, $master_host, $master_port];
    }

    return \@slots;
}

sub get_keys_in_slot {
    my ($sock, $slot) = @_;

    send_command($sock, "CLUSTER", "GETKEYSINSLOT", $slot, 1000);
    my $response = read_response($sock);

    return $response || [];
}

sub migrate_key_with_socket {
    my ($redis, $valkey, $key) = @_;

    # Get TTL
    send_command($redis, "PTTL", $key);
    my $ttl = read_response($redis);
    return 0 unless defined $ttl;

    return 1 if $ttl == -2;
    $ttl = 0 if $ttl == -1;

    # Dump key
    send_command($redis, "DUMP", $key);
    my $serialized = read_response($redis);
    return 0 unless defined $serialized;

    # Restore to Valkey
    send_command($valkey, "RESTORE", $key, $ttl, $serialized, "REPLACE");
    my $response = read_response($valkey);

    return defined $response && $response eq "OK";
}

sub verify_slot_compatibility {
    my ($redis_slots, $valkey_slots) = @_;

    return scalar(@$redis_slots) == scalar(@$valkey_slots);
}

sub find_master_for_slots {
    my ($slots, $start, $end) = @_;

    foreach my $slot_range (@$slots) {
        my ($slot_start, $slot_end) = @$slot_range;
        if ($slot_start <= $start && $slot_end >= $end) {
            return $slot_range;
        }
    }

    return undef;
}

sub print_cluster_info {
    my ($slots, $label) = @_;
    $label ||= "Cluster";

    printf "%s Cluster Topology:\n", $label;
    printf "  Shards: %d\n", scalar(@$slots);
    printf "  Total slots: %d (0-16383)\n", 16384;

    foreach my $slot_range (@$slots) {
        my ($start, $end, $host, $port) = @$slot_range;
        my $slot_count = $end - $start + 1;
        printf "    Slots %5d-%5d (%5d slots) => %s:%d\n",
            $start, $end, $slot_count, $host, $port;
    }
}

sub print_usage {
    print <<"USAGE";
redis-cluster-to-valkey.pl v$VERSION

Migrate Redis Cluster to Valkey Cluster using DUMP/RESTORE commands.
Designed to run locally on BOSH VMs (upload via bosh scp).

USAGE:
    $0 [OPTIONS]

REQUIRED OPTIONS:
  --redis-cluster NODES      Comma-separated list of Redis nodes
                             Format: host1:port1,host2:port2

OPTIONAL (required unless --dry-run):
  --valkey-cluster NODES     Comma-separated list of Valkey nodes
                             Format: host1:port1,host2:port2

AUTHENTICATION:
  --password PASS            Password for both clusters
  --redis-password PASS      Redis-specific password
  --valkey-password PASS     Valkey-specific password

OPTIONS:
  --batch-size SIZE          Keys per batch (default: 100)
  -n, --dry-run              Preview migration without modifying data
  -v, --verbose              Enable verbose output
  -h, --help                 Show this help message

EXAMPLES:
  # Preview migration (dry-run)
  ./redis-cluster-to-valkey.pl \\
    --redis-cluster redis1:6379,redis2:6379,redis3:6379 \\
    --password mysecret \\
    --dry-run

  # Full migration
  ./redis-cluster-to-valkey.pl \\
    --redis-cluster redis1:6379,redis2:6379,redis3:6379 \\
    --valkey-cluster valkey1:6379,valkey2:6379,valkey3:6379 \\
    --password mysecret

  # Different passwords for each cluster
  ./redis-cluster-to-valkey.pl \\
    --redis-cluster redis1:6379,redis2:6379 \\
    --redis-password redis_secret \\
    --valkey-cluster valkey1:6379,valkey2:6379 \\
    --valkey-password valkey_secret

BOSH DEPLOYMENT:
  # Upload script to a Redis cluster node
  bosh -d redis-cluster scp redis-cluster-to-valkey.pl cluster/0:/tmp/

  # SSH and run migration preview
  bosh -d redis-cluster ssh cluster/0
  sudo /tmp/redis-cluster-to-valkey.pl \\
    --redis-cluster localhost:6379 \\
    --password \$REDIS_PASS \\
    --dry-run

NOTES:
  - Both clusters must have the same number of shards
  - Slot distribution should match between clusters
  - The script uses CLUSTER SLOTS to discover topology
USAGE
}
