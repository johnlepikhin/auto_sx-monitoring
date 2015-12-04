#!/usr/bin/perl

use warnings;
use strict;

my $operating_mode = 'read-write';

my @cluster_nodes;
my @poll_nodes;
my @volumes;

if (!$ARGV[0]) {
    print "sxmonitoring error: no cluster URI/alias specified\n";
    exit 1
}

{
    my $found = 0;
    foreach (split '\n', qx|/sx/sx/bin/sxinit --list 2>&1|) {
        my @f = split /\s+/;
        $found = 1 if ($f[1] eq $ARGV[0])
    }
    if (!$found) {
        print "sxmonitoring error: cluster alias $ARGV[0] not found\n";
        exit 1
    }
}

foreach (split '\n', qx|/sx/sx/sbin/sxadm cluster -I "$ARGV[0]" 2>&1|) {
    if (/^Current configuration: (.*)/) {
        foreach (split /\s+/, $1) {
            m|^(\d+)/([^/]+)/([^/]+)/([^/]+)|;
            push @cluster_nodes, {
                size => $1,
                ext_ip => $2,
                int_ip => $3,
                uuid => $4
            }
        }
    } elsif (/^Operating mode: (.*)/) {
        $operating_mode = $1;
    }
}

{
    my ($uuid, $sx_version, $storage_version, $os, $arch, $kernel, $ext_ip, $int_ip, $storage_dir, $storage_allocated, $storage_used, $fs_total, $fs_available);
    foreach (split '\n', (qx|/sx/sx/sbin/sxadm cluster -l "$ARGV[0]" 2>&1| . '\n')) {
        if (/^Node (\S+)/) {
            ($uuid, $sx_version, $storage_version, $os, $arch, $kernel, $ext_ip, $int_ip, $storage_dir, $storage_allocated, $storage_used, $fs_total, $fs_available) =
                ($1,    '',          '',               '',  '',    '',      '',      '',      '',           '',                 '',            '',        '');
        }
        elsif (/^\s*SX: (\S+)/) { $sx_version = $1 }
        elsif (/^\s*HashFS: (\S+)/) { $storage_version = $1 }
        elsif (/^\s*Name: (\S+)/) { $os = $1 }
        elsif (/^\s*Architecture: (\S+)/) { $arch = $1 }
        elsif (/^\s*Release: (\S+)/) { $kernel = $1 }
        elsif (/^\s*Public address: (\S+)/) { $ext_ip = $1 }
        elsif (/^\s*Internal address: (\S+)/) { $int_ip = $1 }
        elsif (/^\s*Storage directory: (\S+)/) { $storage_dir = $1 }
        elsif (/^\s*Allocated space: (\S+)/) { $storage_allocated = $1 }
        elsif (/^\s*Used space: (\S+)/) { $storage_used = $1 }
        elsif (/^\s*Total size: (\S+)/) { $fs_total = $1 }
        elsif (/^\s*Available: (\S+)/) { $fs_available = $1 }
        elsif (/^\s*$/) {
            push @poll_nodes, {
                error => '',
                sx_version => $sx_version,
                storage_version => $storage_version,
                os => $os,
                arch => $arch,
                kernel => $kernel,
                ext_ip => $ext_ip,
                int_ip => $int_ip,
                storage_dir => $storage_dir,
                storage_allocated => $storage_allocated,
                storage_used => $storage_used,
                fs_total => $fs_total,
                fs_available => $fs_available
            }
        } elsif (/^\s*ERROR: Can't query node ([^:]+):\s*(.*)/) {
            push @poll_nodes, {
                error => $2,
                ext_ip => $1
            }
        }
    }
}
    
foreach (split '\n', qx|/sx/sx/bin/sxls -l "$ARGV[0]" 2>&1|) {
    if (/VOL\s+rep:(\d+)\s+rev:(\d+)\s+(\S+)\s+\S+\s+(\d+)\s+(\d+)\s+(\d+)%\s+(\S+)\s+(\S+)/) {
        push @volumes, {
            replicas => $1,
            revisions => $2,
            mode => $3,
            used => $4,
            size => $5,
            used_pct => $6,
            owner => $7,
            path => $8
        }
    }
}

my $has_error = 0;
sub check ($&) {
    if ($_[1]->()) {
        print "ERROR: $_[0]<br>";
        $has_error = 1;
    }
}

####################################

check "Operating mode is not read-write: '$operating_mode'", sub () { return $operating_mode ne 'read-write' };

foreach (@poll_nodes) {
    check "Cannot poll node $_->{ext_ip}: $_->{error}", sub () { return $_->{error} };
    if (!$_->{error}) {
        my $fs_used = 100 - int ($_->{fs_available}/$_->{fs_total}*100);
        my $storage_used = int ($_->{storage_used}/$_->{fs_total}*100);
        my $storage_allocated = int ($_->{storage_allocated}/$_->{fs_total}*100);
        my $fs_storage_usage_diff = int (100 * abs (1 - ($_->{fs_available} / ($_->{fs_total} - $_->{storage_used}))));
        
        check "Node $_->{ext_ip}: FS used for $fs_used; garbage collection && disk space reclaim required (https://bugzilla.skylable.com/show_bug.cgi?id=1355) or expand FS!",
            sub () { return $fs_used > 85 };

        check "Node $_->{ext_ip}: actual storage usage $storage_used; garbage collection && disk space reclaim required (https://bugzilla.skylable.com/show_bug.cgi?id=1355) or expand FS!",
            sub () { return $storage_used > 85 };

        check "Node $_->{ext_ip}: allocated storage usage $storage_allocated%; garbage collection && disk space reclaim required? https://bugzilla.skylable.com/show_bug.cgi?id=1355",
            sub () { return $storage_allocated > 85 && $storage_used < 85 };

        check "Node $_->{ext_ip}: actual FS available disagree with storage disk usage for $fs_storage_usage_diff%; storage bug?",
            sub () {
                return $fs_storage_usage_diff > 10;
        };
    }
}

{
    my (%sx, %storage);
    foreach (@poll_nodes) {
        if (!$_->{error}) {
            $sx{$_->{sx_version}} = 1;
            $storage{$_->{storage_version}} = 1;
        }
    }
    check "Nodes in cluster works on different SX versions; partial upgrade?", sub () { return (keys %sx) > 1};
    check "Nodes in cluster works on different SX-storage versions; partial upgrade?", sub () { return (keys %storage) > 1};
}

foreach (@volumes) {
    check "Volume $_->{path} usage $_->{used_pct}%", sub () { return int ($_->{used_pct})>90 }
}

if (!$has_error) {
    print "OK\n";
}
