#!/usr/bin/perl -w

use strict;
use IO::Socket::INET;

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
	if ($dir eq '>') {
		print $client_socket "$proto\n";
	} else {
		my $client = <$client_socket>;
		$client =~ s/\r\n//g;
		die "Expected [$proto] but got [$client]\n" if ($client ne $proto);
	}
}

close $client_socket;
close $socket;
