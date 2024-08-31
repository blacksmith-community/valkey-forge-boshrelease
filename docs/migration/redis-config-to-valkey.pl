#!/usr/bin/env perl
#
# redis-config-to-valkey.pl
# Translate Redis configuration to Valkey configuration
# Pure Perl - No CPAN dependencies required
#
# Usage:
#   ./redis-config-to-valkey.pl redis.conf > valkey.conf
#   ./redis-config-to-valkey.pl < redis.conf > valkey.conf
#
use strict;
use warnings;

my $input_file = $ARGV[0];
my $fh;

if ($input_file) {
    open($fh, '<', $input_file) or die "Cannot open $input_file: $!\n";
} else {
    $fh = *STDIN;
}

print "# Valkey configuration\n";
print "# Translated from Redis configuration\n";
print "# Generated: " . localtime() . "\n";
print "\n";

my %property_map = (
    'redis.tls.enabled' => 'valkey.tls.enabled',
    'redis.tls.dual-mode' => 'valkey.tls.dual-mode',
    'redis.tls.ca' => 'valkey.tls.ca',
    'redis.tls.ca_cert' => 'valkey.tls.ca_cert',
    'redis.tls.ca_key' => 'valkey.tls.ca_key',
    'redis.maxmemory' => 'valkey.maxmemory',
    'redis.maxmemory-policy' => 'valkey.maxmemory-policy',
    'redis.notify-keyspace-events' => 'valkey.notify-keyspace-events',
    'redis.slowlog-log-slower-than' => 'valkey.slowlog-log-slower-than',
    'redis.slowlog-max-len' => 'valkey.slowlog-max-len',
    'redis.no-appendfsync-on-rewrite' => 'valkey.no-appendfsync-on-rewrite',
    'redis.auto-aof-rewrite-percentage' => 'valkey.auto-aof-rewrite-percentage',
    'redis.auto-aof-rewrite-min-size' => 'valkey.auto-aof-rewrite-min-size',
    'redis_maxmemory' => 'valkey_maxmemory',
    'redis_maxmemory-policy' => 'valkey_maxmemory-policy',
    'redis_notify-keyspace-events' => 'valkey_notify-keyspace-events',
    'redis_slowlog-log-slower-than' => 'valkey_slowlog-log-slower-than',
    'redis_slowlog-max-len' => 'valkey_slowlog-max-len',
    'redis_no-appendfsync-on-rewrite' => 'valkey_no-appendfsync-on-rewrite',
    'redis_auto-aof-rewrite-percentage' => 'valkey_auto-aof-rewrite-percentage',
    'redis_auto-aof-rewrite-min-size' => 'valkey_auto-aof-rewrite-min-size',
);

my %command_map = (
    'redis-server' => 'valkey-server',
    'redis-cli' => 'valkey-cli',
    'redis-check-aof' => 'valkey-check-aof',
    'redis-check-rdb' => 'valkey-check-rdb',
    'redis-benchmark' => 'valkey-benchmark',
);

my $line_number = 0;

while (my $line = <$fh>) {
    $line_number++;
    chomp $line;

    # Translate property names
    foreach my $redis_prop (keys %property_map) {
        my $valkey_prop = $property_map{$redis_prop};
        $line =~ s/\b\Q$redis_prop\E\b/$valkey_prop/g;
    }

    # Translate command names
    foreach my $redis_cmd (keys %command_map) {
        my $valkey_cmd = $command_map{$redis_cmd};
        $line =~ s/\b\Q$redis_cmd\E\b/$valkey_cmd/g;
    }

    # Translate file paths
    $line =~ s/\/redis\//\/valkey\//g;
    $line =~ s/redis\.conf/valkey.conf/g;
    $line =~ s/redis\.aof/valkey.aof/g;
    $line =~ s/redis\.rdb/dump.rdb/g;  # Valkey uses standard dump.rdb name
    $line =~ s/redis\.pid/valkey.pid/g;
    $line =~ s/redis\.log/valkey.log/g;
    $line =~ s/redis\.sock/valkey.sock/g;

    # Translate network names
    $line =~ s/redis-service/valkey-service/g;
    $line =~ s/redis-forge/valkey-forge/g;
    $line =~ s/redis-blacksmith-plans/valkey-blacksmith-plans/g;

    # Translate job names
    $line =~ s/standalone-redis/standalone-valkey/g;
    $line =~ s/cluster-redis/cluster-valkey/g;

    # Comments
    if ($line =~ /^#/) {
        # Translate comments
        $line =~ s/Redis/Valkey/g;
    }

    print "$line\n";
}

close($fh) if $input_file;

print "\n# Translation complete\n";
print "# Please review the configuration and adjust as needed\n";
print "# Refer to Valkey documentation for any version-specific changes\n";
