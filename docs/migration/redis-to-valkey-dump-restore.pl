#!/usr/bin/env perl
#
# redis-to-valkey-dump-restore.pl
# Migrate Redis data to Valkey using DUMP/RESTORE commands
# Pure Perl - No CPAN dependencies required
#
# Usage:
#   ./redis-to-valkey-dump-restore.pl \
#     --redis-host 127.0.0.1 \
#     --redis-port 6379 \
#     --redis-password secret \
#     --valkey-host 127.0.0.1 \
#     --valkey-port 6379 \
#     --valkey-password secret \
#     [--batch-size 1000] \
#     [--pattern "*"] \
#     [--dry-run]
#
use strict;
use warnings;
use IO::Socket::INET;
use Getopt::Long;
use Time::HiRes qw(time);

our $VERSION = '1.1.0';

my %opts = (
    'redis-host' => '127.0.0.1',
    'redis-port' => 6379,
    'valkey-host' => '127.0.0.1',
    'valkey-port' => 6379,
    'batch-size' => 1000,
    'pattern' => '*',
    'dry-run' => 0,
    'verbose' => 0,
);

GetOptions(\%opts,
    'redis-host=s',
    'redis-port=i',
    'redis-password=s',
    'valkey-host=s',
    'valkey-port=i',
    'valkey-password=s',
    'batch-size=i',
    'pattern=s',
    'dry-run|n',
    'verbose|v',
    'help|h'
) or die "Error in command line arguments\n";

if ($opts{help}) {
    print_usage();
    exit 0;
}

# Show mode
if ($opts{'dry-run'}) {
    print "=" x 60 . "\n";
    print "[DRY-RUN] Migration Preview Mode\n";
    print "=" x 60 . "\n\n";
}

# Connect to Redis
print "Connecting to Redis at $opts{'redis-host'}:$opts{'redis-port'}...\n";
my $redis = connect_server($opts{'redis-host'}, $opts{'redis-port'}, $opts{'redis-password'});

# Get Redis info
send_command($redis, "INFO", "keyspace");
my $redis_info = read_response($redis);
print "Redis info:\n$redis_info\n\n" if $opts{verbose} && $redis_info;

# In dry-run mode, connect to Valkey only if needed for validation
my $valkey;
if (!$opts{'dry-run'}) {
    print "Connecting to Valkey at $opts{'valkey-host'}:$opts{'valkey-port'}...\n";
    $valkey = connect_server($opts{'valkey-host'}, $opts{'valkey-port'}, $opts{'valkey-password'});
} else {
    print "Target: Valkey at $opts{'valkey-host'}:$opts{'valkey-port'}\n";
    print "(Skipping connection in dry-run mode)\n\n";
}

# Get list of keys
print "Scanning for keys matching pattern '$opts{pattern}'...\n";
my @keys = scan_keys($redis, $opts{pattern});
my $total_keys = scalar @keys;
print "Found $total_keys keys to migrate\n";

# Calculate data size estimate
my $total_size = 0;
if ($opts{'dry-run'} || $opts{verbose}) {
    print "Analyzing data sizes...\n";
    my $sample_count = $total_keys < 100 ? $total_keys : 100;
    my $sample_size = 0;

    for (my $i = 0; $i < $sample_count && $i < $total_keys; $i++) {
        send_command($redis, "DEBUG", "OBJECT", $keys[$i]);
        my $debug_info = read_response($redis);
        if ($debug_info && $debug_info =~ /serializedlength:(\d+)/) {
            $sample_size += $1;
        }
    }

    if ($sample_count > 0) {
        my $avg_size = $sample_size / $sample_count;
        $total_size = $avg_size * $total_keys;
        printf "Estimated total data size: %.2f MB\n", $total_size / (1024*1024);
    }
}

# Dry-run mode: show summary and exit
if ($opts{'dry-run'}) {
    print "\n" . "=" x 60 . "\n";
    print "[DRY-RUN] Migration Plan Summary\n";
    print "=" x 60 . "\n\n";

    print "Source:\n";
    printf "  Host: %s:%d\n", $opts{'redis-host'}, $opts{'redis-port'};
    printf "  Keys matching '%s': %d\n", $opts{pattern}, $total_keys;
    printf "  Estimated size: %.2f MB\n", $total_size / (1024*1024) if $total_size;

    print "\nTarget:\n";
    printf "  Host: %s:%d\n", $opts{'valkey-host'}, $opts{'valkey-port'};

    print "\nMigration Settings:\n";
    printf "  Batch size: %d\n", $opts{'batch-size'};
    printf "  Estimated batches: %d\n", int(($total_keys + $opts{'batch-size'} - 1) / $opts{'batch-size'});

    if ($total_keys > 0 && $total_size > 0) {
        # Estimate migration time (roughly 1000 keys/sec for small keys)
        my $est_rate = 1000;
        my $est_time = $total_keys / $est_rate;
        printf "\nEstimated migration time: %.0f seconds (%.1f minutes)\n",
            $est_time, $est_time / 60;
    }

    # Show sample keys
    if ($total_keys > 0 && $opts{verbose}) {
        my $sample_size = $total_keys < 10 ? $total_keys : 10;
        print "\nSample keys to migrate:\n";
        for (my $i = 0; $i < $sample_size; $i++) {
            print "  - $keys[$i]\n";
        }
        print "  ... and " . ($total_keys - $sample_size) . " more\n" if $total_keys > $sample_size;
    }

    print "\n" . "=" x 60 . "\n";
    print "[DRY-RUN] No data was migrated.\n";
    print "Remove --dry-run to perform the actual migration.\n";
    print "=" x 60 . "\n";

    close($redis);
    exit 0;
}

# Migrate keys in batches
my $migrated = 0;
my $failed = 0;
my $start_time = time();

for (my $i = 0; $i < $total_keys; $i += $opts{'batch-size'}) {
    my $end = $i + $opts{'batch-size'} - 1;
    $end = $total_keys - 1 if $end >= $total_keys;

    my @batch = @keys[$i..$end];

    foreach my $key (@batch) {
        if (migrate_key($redis, $valkey, $key)) {
            $migrated++;
        } else {
            $failed++;
            warn "Failed to migrate key: $key\n";
        }

        if ($migrated % 1000 == 0) {
            my $elapsed = time() - $start_time;
            my $rate = $migrated / $elapsed;
            printf "Progress: %d/%d keys (%.1f%%, %.0f keys/sec)\n",
                $migrated, $total_keys, ($migrated / $total_keys * 100), $rate;
        }
    }
}

my $elapsed = time() - $start_time;
print "\n" . "=" x 60 . "\n";
print "Migration complete!\n";
print "=" x 60 . "\n";
print "Total keys: $total_keys\n";
print "Migrated: $migrated\n";
print "Failed: $failed\n";
printf "Time elapsed: %.2f seconds\n", $elapsed;
printf "Average rate: %.0f keys/second\n", $migrated / $elapsed if $elapsed > 0;

close($redis);
close($valkey) if $valkey;

sub connect_server {
    my ($host, $port, $password) = @_;

    my $sock = IO::Socket::INET->new(
        PeerAddr => $host,
        PeerPort => $port,
        Proto => 'tcp',
        Timeout => 10
    ) or die "Cannot connect to $host:$port: $!\n";

    $sock->autoflush(1);

    # Authenticate if password provided
    if ($password) {
        send_command($sock, "AUTH", $password);
        my $response = read_response($sock);
        die "Authentication failed: $response\n" unless $response eq "OK";
    }

    return $sock;
}

sub send_command {
    my ($sock, @args) = @_;

    # Redis protocol: *<arg_count>\r\n$<length>\r\n<data>\r\n...
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
        # Simple string
        return $data;
    } elsif ($type eq '-') {
        # Error
        warn "Redis error: $data\n";
        return undef;
    } elsif ($type eq ':') {
        # Integer
        return $data;
    } elsif ($type eq '$') {
        # Bulk string
        my $len = $data;
        return undef if $len == -1;  # Null

        my $bulk_data = '';
        read($sock, $bulk_data, $len);
        <$sock>;  # Read trailing \r\n
        return $bulk_data;
    } elsif ($type eq '*') {
        # Array
        my $count = $data;
        return undef if $count == -1;  # Null array

        my @array;
        for (my $i = 0; $i < $count; $i++) {
            push @array, read_response($sock);
        }
        return \@array;
    }

    return undef;
}

sub scan_keys {
    my ($sock, $pattern) = @_;

    my @all_keys;
    my $cursor = 0;

    do {
        send_command($sock, "SCAN", $cursor, "MATCH", $pattern, "COUNT", 1000);
        my $response = read_response($sock);

        $cursor = $response->[0];
        my $keys = $response->[1];
        push @all_keys, @$keys if ref $keys eq 'ARRAY';

    } while ($cursor != 0);

    return @all_keys;
}

sub migrate_key {
    my ($redis, $valkey, $key) = @_;

    # Get TTL
    send_command($redis, "PTTL", $key);
    my $ttl = read_response($redis);
    return 0 unless defined $ttl;

    # -2 means key doesn't exist, -1 means no expiry
    return 1 if $ttl == -2;  # Key already gone
    $ttl = 0 if $ttl == -1;  # No expiry

    # Dump key
    send_command($redis, "DUMP", $key);
    my $serialized = read_response($redis);
    return 0 unless defined $serialized;

    # Restore to Valkey
    send_command($valkey, "RESTORE", $key, $ttl, $serialized);
    my $response = read_response($valkey);

    return defined $response && $response eq "OK";
}

sub print_usage {
    print <<"USAGE";
redis-to-valkey-dump-restore.pl v$VERSION

Migrate Redis data to Valkey using DUMP/RESTORE commands.
Designed to run locally on BOSH VMs (upload via bosh scp).

USAGE:
    $0 [OPTIONS]

OPTIONS:
  --redis-host HOST          Redis hostname (default: 127.0.0.1)
  --redis-port PORT          Redis port (default: 6379)
  --redis-password PASS      Redis password
  --valkey-host HOST         Valkey hostname (default: 127.0.0.1)
  --valkey-port PORT         Valkey port (default: 6379)
  --valkey-password PASS     Valkey password
  --batch-size SIZE          Keys per batch (default: 1000)
  --pattern PATTERN          Key pattern to match (default: *)
  -n, --dry-run              Preview migration without modifying data
  -v, --verbose              Enable verbose output
  -h, --help                 Show this help message

EXAMPLES:
  # Preview migration (dry-run)
  ./redis-to-valkey-dump-restore.pl \\
    --redis-host localhost \\
    --redis-password secret1 \\
    --valkey-host valkey.internal \\
    --valkey-password secret2 \\
    --dry-run

  # Migrate all keys
  ./redis-to-valkey-dump-restore.pl \\
    --redis-host localhost \\
    --redis-password secret1 \\
    --valkey-host valkey.internal \\
    --valkey-password secret2

  # Migrate only user:* keys
  ./redis-to-valkey-dump-restore.pl \\
    --redis-host localhost \\
    --redis-password secret1 \\
    --valkey-host valkey.internal \\
    --valkey-password secret2 \\
    --pattern "user:*"

BOSH DEPLOYMENT:
  # Upload script to Redis VM
  bosh -d redis-instance scp redis-to-valkey-dump-restore.pl standalone/0:/tmp/

  # SSH and run migration
  bosh -d redis-instance ssh standalone/0
  sudo /tmp/redis-to-valkey-dump-restore.pl \\
    --redis-host localhost --redis-password \$REDIS_PASS \\
    --valkey-host valkey.internal --valkey-password \$VALKEY_PASS \\
    --dry-run
USAGE
}
