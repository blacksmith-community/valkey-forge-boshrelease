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
#     [--pattern "*"]
#
use strict;
use warnings;
use IO::Socket::INET;
use Getopt::Long;
use Time::HiRes qw(time);

my %opts = (
    'redis-host' => '127.0.0.1',
    'redis-port' => 6379,
    'valkey-host' => '127.0.0.1',
    'valkey-port' => 6379,
    'batch-size' => 1000,
    'pattern' => '*',
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
    'help'
) or die "Error in command line arguments\n";

if ($opts{help}) {
    print_usage();
    exit 0;
}

# Connect to Redis and Valkey
print "Connecting to Redis at $opts{'redis-host'}:$opts{'redis-port'}...\n";
my $redis = connect_server($opts{'redis-host'}, $opts{'redis-port'}, $opts{'redis-password'});

print "Connecting to Valkey at $opts{'valkey-host'}:$opts{'valkey-port'}...\n";
my $valkey = connect_server($opts{'valkey-host'}, $opts{'valkey-port'}, $opts{'valkey-password'});

# Get list of keys
print "Scanning for keys matching pattern '$opts{pattern}'...\n";
my @keys = scan_keys($redis, $opts{pattern});
my $total_keys = scalar @keys;
print "Found $total_keys keys to migrate\n";

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
print "\nMigration complete!\n";
print "Total keys: $total_keys\n";
print "Migrated: $migrated\n";
print "Failed: $failed\n";
printf "Time elapsed: %.2f seconds\n", $elapsed;
printf "Average rate: %.0f keys/second\n", $migrated / $elapsed if $elapsed > 0;

close($redis);
close($valkey);

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
    print <<'USAGE';
Usage: redis-to-valkey-dump-restore.pl [OPTIONS]

Options:
  --redis-host HOST          Redis hostname (default: 127.0.0.1)
  --redis-port PORT          Redis port (default: 6379)
  --redis-password PASS      Redis password
  --valkey-host HOST         Valkey hostname (default: 127.0.0.1)
  --valkey-port PORT         Valkey port (default: 6379)
  --valkey-password PASS     Valkey password
  --batch-size SIZE          Keys per batch (default: 1000)
  --pattern PATTERN          Key pattern to match (default: *)
  --help                     Show this help message

Example:
  ./redis-to-valkey-dump-restore.pl \\
    --redis-host redis.internal \\
    --redis-password secret1 \\
    --valkey-host valkey.internal \\
    --valkey-password secret2 \\
    --pattern "user:*"
USAGE
}
