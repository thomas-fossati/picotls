#!/usr/bin/env perl

use strict;
use warnings;
use Digest::MD5 qw(md5_hex);
use File::Temp qw(tempdir);
use Net::EmptyPort qw(check_port empty_port);
use POSIX ":sys_wait_h";
use Scope::Guard qw(scope_guard);
use Test::More;
use Time::HiRes qw(sleep);

$ENV{BINARY_DIR} ||= ".";
my $cli = "$ENV{BINARY_DIR}/cli";
my $port = empty_port();
my $tempdir = tempdir(CLEANUP => 1);

subtest "hello" => sub {
    my $guard = spawn_server(qw(-i t/assets/hello.txt));
    subtest "full-handshake" => sub {
        my $resp = `$cli 127.0.0.1 $port 2> /dev/null`;
        is $resp, "hello";
    };
    subtest "resumption" => sub {
        for (1..10) {
            my $resp = `$cli -s $tempdir/session 127.0.0.1 $port 2> /dev/null`;
            is $resp, "hello";
        }
    };
};

unlink "$tempdir/session";

subtest "early-data" => sub {
    subtest "success" => sub {
        plan skip_all => "faketime not found"
            unless system("which faketime > /dev/null 2>&1") == 0;
        my $guard = spawn_server(qw(-i t/assets/hello.txt -l), "$tempdir/events");
        my $resp = `$cli -s $tempdir/session 127.0.0.1 $port`;
        is $resp, "hello";
        $resp = `$cli -e -s $tempdir/session 127.0.0.1 $port`;
        is $resp, "hello";
        like slurp_file("$tempdir/events"), qr/^CLIENT_EARLY_TRAFFIC_SECRET /m;
        $resp = `$cli -e -s $tempdir/session 127.0.0.1 $port`;
        is $resp, "hello";
        is 2, (() = slurp_file("$tempdir/events") =~ /^CLIENT_EARLY_TRAFFIC_SECRET /mg);
        # check +15 seconds jitter
        $resp = `faketime -f +15 $cli -e -s $tempdir/session 127.0.0.1 $port`;
        is $resp, "hello";
        is 2, (() = slurp_file("$tempdir/events") =~ /^CLIENT_EARLY_TRAFFIC_SECRET /mg);
        # re-fetch the ticket
        unlink "$tempdir/session";
        $resp = `$cli -e -s $tempdir/session 127.0.0.1 $port`;
        is $resp, "hello";
        is 2, (() = slurp_file("$tempdir/events") =~ /^CLIENT_EARLY_TRAFFIC_SECRET /mg);
        # check -15 seconds jitter
        $resp = `faketime -f -15 $cli -e -s $tempdir/session 127.0.0.1 $port`;
        is $resp, "hello";
        is 2, (() = slurp_file("$tempdir/events") =~ /^CLIENT_EARLY_TRAFFIC_SECRET /mg);
    };
};

subtest "certificate-compression" => sub {
    plan skip_all => "feature disabled"
        unless system("$cli -b -h > /dev/null 2>&1") == 0;
    my $guard = spawn_server(qw(-i t/assets/hello.txt -b));
    my $resp = `$cli 127.0.0.1 $port 2> /dev/null`;
    isnt $resp, "hello";
    $resp = `$cli -b 127.0.0.1 $port 2> /dev/null`;
    is $resp, "hello";
};

done_testing;

sub spawn_server {
    my @cmd = ($cli, "-k", "t/assets/server.key", "-c", "t/assets/server.crt", @_, "127.0.0.1", $port);
    my $pid = fork;
    die "fork failed:$!"
        unless defined $pid;
    if ($pid == 0) {
        exec @cmd;
        die "failed to exec $cmd[0]:$?";
    }
    while (!check_port($port)) {
        sleep 0.1;
    }
    return scope_guard(sub {
        kill 9, $pid;
        while (waitpid($pid, 0) != $pid) {}
    });
}

sub slurp_file {
    my $fn = shift;
    open my $fh, "<", $fn
        or die "failed to open file:$fn:$!";
    do {
        local $/;
        <$fh>;
    };
}
