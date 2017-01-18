#!/usr/bin/perl -w

use strict;
use IO::Socket::INET;
use Time::HiRes qw(usleep);

$| = 1;

my $socket = new IO::Socket::INET(
    LocalHost => '0.0.0.0',
    LocalPort => '9090',
    Proto => 'tcp',
    Listen => 5,
    Reuse => 1
);
die "Failed to create socket $!\n" unless $socket;

my $client_socket = $socket->accept();

my $line;
foreach $line (<>) {
	print "$line";
	chomp $line;
	my ($d, $l, $dir, $proto) = split(/ /, $line, 4);
	if ($d ne "[DEBUG]" || $l ne "lms") {
		print "Skipping [$line]\n";
	} elsif ($dir eq '>') {
		print $client_socket "$proto\n";
	} else {
		my $client = <$client_socket>;
		die "EOF" if (!defined($client));
		$client =~ s/\r\n//g;
		chomp $client;
		if ($client ne $proto) {
			die "Expected [$proto] but got [$client]\n";
		}
	}
	usleep 250000;
}

close $client_socket;
close $socket;
