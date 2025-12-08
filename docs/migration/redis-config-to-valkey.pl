#!/usr/bin/env perl
#
# redis-config-to-valkey.pl
# Translate Redis configuration to Valkey configuration
# Pure Perl - No CPAN dependencies required
#
# Usage:
#   ./redis-config-to-valkey.pl --input redis.conf --output valkey.conf
#   ./redis-config-to-valkey.pl --input redis.conf --dry-run
#   ./redis-config-to-valkey.pl redis.conf > valkey.conf
#   ./redis-config-to-valkey.pl < redis.conf > valkey.conf
#
use strict;
use warnings;
use Getopt::Long qw(:config no_ignore_case bundling pass_through);

our $VERSION = '1.1.0';

# Options
my %opts = (
    input   => '',
    output  => '',
    dry_run => 0,
    verbose => 0,
    help    => 0,
);

GetOptions(
    'input|i=s'   => \$opts{input},
    'output|o=s'  => \$opts{output},
    'dry-run|n'   => \$opts{dry_run},
    'verbose|v'   => \$opts{verbose},
    'help|h'      => \$opts{help},
) or usage(1);

usage(0) if $opts{help};

# Support legacy positional argument
if (!$opts{input} && @ARGV) {
    $opts{input} = shift @ARGV;
}

my $input_file = $opts{input};
my $fh;

if ($input_file) {
    open($fh, '<', $input_file) or die "Cannot open $input_file: $!\n";
} else {
    $fh = *STDIN;
}

# Statistics for dry-run output
my %stats = (
    total_lines  => 0,
    translated   => 0,
    unchanged    => 0,
    comments     => 0,
);

# Collect output for dry-run mode
my @output_lines;

push @output_lines, "# Valkey configuration\n";
push @output_lines, "# Translated from Redis configuration v$VERSION\n";
push @output_lines, "# Generated: " . localtime() . "\n";
push @output_lines, "\n";

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
    $stats{total_lines}++;
    chomp $line;

    my $original_line = $line;
    my $was_translated = 0;

    # Translate property names
    foreach my $redis_prop (keys %property_map) {
        my $valkey_prop = $property_map{$redis_prop};
        if ($line =~ s/\b\Q$redis_prop\E\b/$valkey_prop/g) {
            $was_translated = 1;
            verbose("Line $line_number: '$redis_prop' -> '$valkey_prop'");
        }
    }

    # Translate command names
    foreach my $redis_cmd (keys %command_map) {
        my $valkey_cmd = $command_map{$redis_cmd};
        if ($line =~ s/\b\Q$redis_cmd\E\b/$valkey_cmd/g) {
            $was_translated = 1;
            verbose("Line $line_number: '$redis_cmd' -> '$valkey_cmd'");
        }
    }

    # Translate file paths
    $was_translated = 1 if $line =~ s/\/redis\//\/valkey\//g;
    $was_translated = 1 if $line =~ s/redis\.conf/valkey.conf/g;
    $was_translated = 1 if $line =~ s/redis\.aof/valkey.aof/g;
    $was_translated = 1 if $line =~ s/redis\.rdb/dump.rdb/g;
    $was_translated = 1 if $line =~ s/redis\.pid/valkey.pid/g;
    $was_translated = 1 if $line =~ s/redis\.log/valkey.log/g;
    $was_translated = 1 if $line =~ s/redis\.sock/valkey.sock/g;

    # Translate network names
    $was_translated = 1 if $line =~ s/redis-service/valkey-service/g;
    $was_translated = 1 if $line =~ s/redis-forge/valkey-forge/g;
    $was_translated = 1 if $line =~ s/redis-blacksmith-plans/valkey-blacksmith-plans/g;

    # Translate job names
    $was_translated = 1 if $line =~ s/standalone-redis/standalone-valkey/g;
    $was_translated = 1 if $line =~ s/cluster-redis/cluster-valkey/g;

    # Comments
    if ($original_line =~ /^#/) {
        $stats{comments}++;
        $line =~ s/Redis/Valkey/g;
    }

    if ($was_translated) {
        $stats{translated}++;
    } else {
        $stats{unchanged}++;
    }

    push @output_lines, "$line\n";
}

close($fh) if $input_file;

push @output_lines, "\n# Translation complete\n";
push @output_lines, "# Please review the configuration and adjust as needed\n";
push @output_lines, "# Refer to Valkey documentation for any version-specific changes\n";

# Output results
if ($opts{dry_run}) {
    print_dry_run_summary();
} else {
    if ($opts{output}) {
        open(my $out, '>', $opts{output}) or die "Cannot write to $opts{output}: $!\n";
        print $out @output_lines;
        close($out);
        print STDERR "Output written to: $opts{output}\n";
        print_stats() if $opts{verbose};
    } else {
        print @output_lines;
    }
}

sub print_dry_run_summary {
    print "=" x 60 . "\n";
    print "[DRY-RUN] Configuration Translation Preview\n";
    print "=" x 60 . "\n\n";

    print "Input file:  " . ($input_file || 'STDIN') . "\n";
    print "Output file: " . ($opts{output} || 'STDOUT') . "\n\n";

    print "Translation Summary:\n";
    print "-" x 40 . "\n";
    printf "  Total lines:    %d\n", $stats{total_lines};
    printf "  Translated:     %d\n", $stats{translated};
    printf "  Unchanged:      %d\n", $stats{unchanged};
    printf "  Comments:       %d\n", $stats{comments};
    print "\n";

    print "Would write the following output:\n";
    print "-" x 40 . "\n";
    print @output_lines;
    print "-" x 40 . "\n";
    print "\n[DRY-RUN] No files were modified.\n";
    print "Remove --dry-run to perform the actual translation.\n";
}

sub print_stats {
    print STDERR "\nTranslation Summary:\n";
    printf STDERR "  Total lines:    %d\n", $stats{total_lines};
    printf STDERR "  Translated:     %d\n", $stats{translated};
    printf STDERR "  Unchanged:      %d\n", $stats{unchanged};
    printf STDERR "  Comments:       %d\n", $stats{comments};
}

sub verbose {
    my ($msg) = @_;
    print STDERR "[VERBOSE] $msg\n" if $opts{verbose};
}

sub usage {
    my ($exit_code) = @_;
    print <<EOF;
redis-config-to-valkey.pl v$VERSION

Translate Redis configuration to Valkey configuration.

USAGE:
    $0 [OPTIONS] [--input FILE | FILE]

OPTIONS:
    -i, --input FILE    Input Redis configuration file
    -o, --output FILE   Output file (default: stdout)
    -n, --dry-run       Preview changes without writing
    -v, --verbose       Enable verbose output
    -h, --help          Show this help message

EXAMPLES:
    # Convert redis.conf to valkey.conf
    $0 --input redis.conf --output valkey.conf

    # Preview conversion without writing
    $0 --input redis.conf --dry-run

    # Use positional argument (legacy)
    $0 redis.conf > valkey.conf

    # Read from stdin
    cat redis.conf | $0 > valkey.conf

PROPERTY MAPPINGS:
    redis.tls.*                  -> valkey.tls.*
    redis.maxmemory              -> valkey.maxmemory
    redis.maxmemory-policy       -> valkey.maxmemory-policy
    redis.notify-keyspace-events -> valkey.notify-keyspace-events
    redis.slowlog-*              -> valkey.slowlog-*
    redis.disabled-commands      -> valkey.disabled-commands

EOF
    exit $exit_code;
}
