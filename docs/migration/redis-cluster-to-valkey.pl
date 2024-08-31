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
#     [--batch-size 100]
#
use strict;
use warnings;
use IO::Socket::INET;
use Getopt::Long;
use Time::HiRes qw(time);

my %opts = (
    'batch-size' => 100,
);

GetOptions(\%opts,
    'redis-cluster=s',
    'valkey-cluster=s',
    'password=s',
    'redis-password=s',
    'valkey-password=s',
    'batch-size=i',
    'help'
) or die "Error in command line arguments\n";

if ($opts{help} || !$opts{'redis-cluster'} || !$opts{'valkey-cluster'}) {
    print_usage();
    exit $opts{help} ? 0 : 1;
}

# Parse cluster nodes
my @redis_nodes = split(/,/, $opts{'redis-cluster'});
my @valkey_nodes = split(/,/, $opts{'valkey-cluster'});

# Use specific passwords or fallback to common password
my $redis_pass = $opts{'redis-password'} || $opts{'password'};
my $valkey_pass = $opts{'valkey-password'} || $opts{'password'};

print "Redis Cluster Migration Tool\n";
print "============================\n\n";

# Connect to first node of each cluster
print "Connecting to Redis cluster ($redis_nodes[0])...\n";
my $redis = connect_node($redis_nodes[0], $redis_pass);

print "Connecting to Valkey cluster ($valkey_nodes[0])...\n";
my $valkey = connect_node($valkey_nodes[0], $valkey_pass);

# Get cluster topology
print "\nAnalyzing Redis cluster topology...\n";
my $redis_slots = get_cluster_slots($redis);
print_cluster_info($redis_slots);

print "\nAnalyzing Valkey cluster topology...\n";
my $valkey_slots = get_cluster_slots($valkey);
print_cluster_info($valkey_slots);

# Verify slot distribution matches
if (!verify_slot_compatibility($redis_slots, $valkey_slots)) {
    die "ERROR: Cluster topologies are not compatible!\n" .
        "Redis and Valkey clusters must have the same number of shards.\n";
}

# Migrate data slot by slot
print "\nStarting data migration...\n";
my $total_keys = 0;
my $migrated_keys = 0;
my $start_time = time();

foreach my $slot_range (@$redis_slots) {
    my ($start_slot, $end_slot, $master_host, $master_port) = @$slot_range;

    print "\nMigrating slots $start_slot-$end_slot from $master_host:$master_port\n";

    # Connect to specific master
    my $redis_master = connect_node("$master_host:$master_port", $redis_pass);

    # Find corresponding Valkey master
    my $valkey_master_info = find_master_for_slots($valkey_slots, $start_slot, $end_slot);
    my $valkey_master = connect_node("$valkey_master_info->[2]:$valkey_master_info->[3]", $valkey_pass);

    # Migrate keys for this slot range
    for (my $slot = $start_slot; $slot <= $end_slot; $slot++) {
        my $keys = get_keys_in_slot($redis_master, $slot);
        $total_keys += scalar @$keys;

        foreach my $key (@$keys) {
            if (migrate_key_with_socket($redis_master, $valkey_master, $key)) {
                $migrated_keys++;
            } else {
                warn "Failed to migrate key: $key (slot $slot)\n";
            }

            if ($migrated_keys % 1000 == 0) {
                my $elapsed = time() - $start_time;
                my $rate = $migrated_keys / $elapsed;
                printf "Progress: %d keys migrated (%.0f keys/sec)\n", $migrated_keys, $rate;
            }
        }
    }

    close($redis_master);
    close($valkey_master);
}

my $elapsed = time() - $start_time;
print "\n" . ("=" x 50) . "\n";
print "Migration complete!\n";
print "Total keys found: $total_keys\n";
print "Keys migrated: $migrated_keys\n";
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
    my ($slots) = @_;

    printf "  Shards: %d\n", scalar(@$slots);
    printf "  Total slots: %d (0-16383)\n", 16384;

    foreach my $slot_range (@$slots) {
        my ($start, $end, $host, $port) = @$slot_range;
        my $slot_count = $end - $start + 1;
        printf "    Slots %d-%d (%d slots) => %s:%d\n",
            $start, $end, $slot_count, $host, $port;
    }
}

sub print_usage {
    print <<'USAGE';
Usage: redis-cluster-to-valkey.pl [OPTIONS]

Required Options:
  --redis-cluster NODES      Comma-separated list of Redis nodes
                             Format: host1:port1,host2:port2
  --valkey-cluster NODES     Comma-separated list of Valkey nodes
                             Format: host1:port1,host2:port2

Optional:
  --password PASS            Password for both clusters
  --redis-password PASS      Redis-specific password
  --valkey-password PASS     Valkey-specific password
  --batch-size SIZE          Keys per batch (default: 100)
  --help                     Show this help message

Example:
  ./redis-cluster-to-valkey.pl \\
    --redis-cluster redis1:6379,redis2:6379,redis3:6379 \\
    --valkey-cluster valkey1:6379,valkey2:6379,valkey3:6379 \\
    --password mysecret
USAGE
}
