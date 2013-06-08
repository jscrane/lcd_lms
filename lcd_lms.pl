#!/usr/bin/perl -w

use 5.005;
#use strict;
use Getopt::Std;
use IO::Socket;
use IO::Select;
use Fcntl;
use Date::Parse;
use Switch;
use URI::Escape;

############################################################
# Configurable part. Set it according your setup.
############################################################

# Host which runs LCDproc daemon (LCDd)
my $LCDD = "localhost";

# Port on which LCDd listens to requests
my $LCDPORT = "13666";

my $LIGHT = 20;

my $LMS = "rpi";
my $LMSPORT = "9090";
my $PLAYER = $ARGV[$#ARGV];

############################################################
# End of user configurable parts
############################################################

my $width = 20;
my $lines = 4;

my $progname = $0;
   $progname =~ s#.*/(.*?)$#$1#;

# declare functions
sub error($@);
sub usage($);
sub send_receive;
sub lms_query;
sub lms_query_send;
sub lms_cmd_send;
sub lms_response;

my %opt = ();
getopts("s:p:S:P:n:", \%opt);

$LCDD = defined($opt{s}) ? $opt{s} : $LCDD;
$LCDPORT = defined($opt{p}) ? $opt{p} : $LCDPORT;
$LMS = defined($opt{m}) ? $opt{m} : $LMS;
$LMSPORT = defined($opt{P}) ? $opt{P} : $LMSPORT;
$PLAYER = defined($opt{n}) ? $opt{n} : $PLAYER;

# Connect to the servers...
my $lms = IO::Socket::INET->new(
		Proto     => 'tcp',
		PeerAddr  => $LMS,
		PeerPort  => $LMSPORT,
	) or  error(1, "cannot connect to LMS server at $LMS:$LMSPORT");
$lms->autoflush(1);

my $player_id = "";
my $pcount = lms_query "player count";
for ($i = 0; $i < $pcount; $i++) {
	my $p = lms_query "player name $i";
	if ($p eq $PLAYER) {
		$player_id = lms_query "player id $i";
		last;
	}
}

$player_id ne "" || die "unable to find player $PLAYER";

my $lcd = IO::Socket::INET->new(
		Proto     => 'tcp',
		PeerAddr  => $LCDD,
		PeerPort  => $LCDPORT,
	) or  error(1, "cannot connect to LCDd daemon at $LCDD:$LCDPORT");

# Make sure our messages get there right away
$lcd->autoflush(1);

my $read_set = new IO::Select();
$read_set->add($lcd);
$read_set->add($lms);

sleep 1;	# Give server plenty of time to notice us...

my $lcdresponse = send_receive $lcd, "hello";
print $lcdresponse;

# get width & height from server's greet message
if ($lcdresponse =~ /\bwid\s+(\d+)\b/) {
	$width = 0 + $1;
}	
if ($lcdresponse =~ /\bhgt\s+(\d+)\b/) {
	$lines = 0 + $1;
}	

send_receive $lcd, "client_set name {$progname}";
send_receive $lcd, "screen_add $PLAYER";
send_receive $lcd, "screen_set $PLAYER priority 128 name playback heartbeat off";
send_receive $lcd, "widget_add $PLAYER title scroller";
send_receive $lcd, "widget_add $PLAYER album scroller";
send_receive $lcd, "widget_add $PLAYER artist scroller";
send_receive $lcd, "widget_add $PLAYER volume string";
send_receive $lcd, "widget_add $PLAYER status string";
send_receive $lcd, "widget_add $PLAYER progress string";
send_receive $lcd, "client_add_key Enter";
send_receive $lcd, "client_add_key Escape";

$sel = IO::Select->new( $lcd, $lms );

my $total_tracks = 0;
my $current_track = 0;
my $elapsed_time = 0;
my $current_duration = 0;
my $title = "";
my $artist = "";
my $album = "";
my $playing = 0;

send_receive $lms, "listen 1";

lms_query_send "mixer volume";
lms_query_send "mode";

while () {
	while (@ready = $sel->can_read(1)) {
		foreach $fh (@ready) {
			my $input = <$fh>;
			if (!defined $input) {
				close ($lcd);
				close ($lms);
				exit;
			}
			if ( $fh == $lms && $input =~ /$player_id (.+)/ ) {
				lms_response $1;
			} elsif ( $fh == $lcd ) {
				if ( $input eq "key Enter\n" ) {
					lms_cmd_send "stop";
				} elsif ( $input eq "key Escape\n" ) {
					lms_cmd_send "pause";
				}
			}
		}
	}
	if ($playing) {
		$elapsed_time++;
		set_time();
	}
}

## print out error message and eventually exit ##
# Synopsis:  error($status, $message)
sub error($@) {
my $status = shift;
my @msg = @_;

  print STDERR $progname . ": " . join(" ", @msg) . "\n";

  exit($status)  if ($status);
}


## print out usage message and exit ##
# Synopsis:  usage($status)
sub usage($) {
my $status = shift;

  print STDERR "Usage: $progname [<options>] <file>\n";
  if (!$status) {
    print STDERR "  where <options> are\n" .
                 "    -s <server>                connect to <server> (default: $LCDD)\n" .
                 "    -p <port>                  connect to <port> on <server> (default: $LCDPORT)\n" .
		 "    -h                         show this help page\n" .
		 "    -V                         display version number\n";
  }
  else {
    print STDERR "For help, type: $progname -h\n";
  }  

  exit($status);
}

sub send_receive {
	my $fd = shift;
	my $cmd = shift;

	print $fd "$cmd\n";
	return <$fd>;
}

sub lms_query {
	my $query = shift;

	print $lms "$query ?\n";
	while () {
		my $ans = <$lms>;
print "lms_query: $ans";
		if ($ans =~ /^$query (.+)/) {
			return $1;
		}
	}
}

sub lms_query_send {
	my $query = shift;

	print $lms "$player_id $query ?\n";
	my $ans = <$lms>;
print "lms: $ans";
	if ( $ans =~ /$player_id (.+)/) {
		lms_response $1;
	}
}

sub lms_cmd_send {
	my $cmd = shift;

	print $lms "$player_id $cmd\n";
	my $ans = <$lms>;
print "lms: $ans";
	if ( $ans =~ /$player_id (.+)/) {
		lms_response $1;
	}
}

sub centre {
	my $w = shift;
	my $t = shift;
	my $l = length($t);
	return $t if ($l > $w);
	return sprintf("% *s", ($l + $w) / 2, $t);
}

sub set_title {
	$title = shift;
	$title = "" if (!defined $title);
	$title = centre($width, $title);
	send_receive $lcd, "widget_set $PLAYER title 1 1 $width 1 v 8 \"$title\"";
}

sub set_album {
	$album = shift;
	# if album is undefined (as it is for radio streams) give
	# its field to part of the name of the stream.
	$album = "" if (!defined $album);
	if ($album ne "") {
		$album = centre($width, $album);
	} elsif (length($title) > $width) {
		my $pos = rindex($title, ' ', $width);
		if ($pos > 0) {
			$album = centre($width, substr($title, $pos + 1));
			set_title substr($title, 0, $pos);
		}
	}
	send_receive $lcd, "widget_set $PLAYER album 1 2 $width 2 v 8 \"$album\"";
}

sub set_artist {
	$artist = shift;
	$artist = "" if (!defined $artist);
	my $n = length($artist);
	# if artist and album are the same, and too long for the display,
	# break them up nicely
	if ($n > $width && $artist eq $album) {
		my $pos = rindex($artist, ' ', $width);
		if ($pos > 0) {
			set_album substr($artist, 0, $pos);
			$artist = substr($artist, $pos + 1);
		}
	}
	$artist = centre($width, $artist);
	send_receive $lcd, "widget_set $PLAYER artist 1 3 $width 3 v 8 \"$artist\"";
}

sub set_status {
	$state = centre(10, shift);
	send_receive $lcd, "widget_set $PLAYER status 6 4 \"$state\"";
}

sub set_progress {
	my $p = "";
	if ($total_tracks > 0) {
		$p = sprintf "%d/%d", $current_track, $total_tracks;
		$p = sprintf "% 6s", $p;
	}
	send_receive $lcd, "widget_set $PLAYER progress 15 4 \"$p\"";
}

sub set_time {
	# duration is unknown for radio stream so just show elapsed time
	my $remain = $current_duration - $elapsed_time;
	if ($remain < 0) {
		$remain = - $remain;
	}
	my $rh = int($remain / 3600);
	my $rm = int(($remain - 3600 * $rh) / 60);
	my $rs = int($remain % 60);
	my $t;
	if ($rh > 0) {
		$t = sprintf("%d:%02d:%02d", $rh, $rm, $rs);
	} else {
		$t = sprintf("%d:%02d", $rm, $rs);
	}
	set_status $t;
}

sub set_volume {
	my $vol = shift;
	if ($vol eq "100") {
		$vol = "99";
	}
	$vol = sprintf "%02s", $vol;
	send_receive $lcd, "widget_set $PLAYER volume 1 4 $vol";
}

sub set_playing {
	$playing = shift;
	if ($playing == 0) {
		send_receive $lcd, "screen_set $PLAYER -priority background -backlight off";
	} else {
		send_receive $lcd, "screen_set $PLAYER -priority foreground -backlight on";
	}
}

sub clear_track {
	set_title "";
	set_album "";
	set_artist "";
	set_status "stop";
	$total_tracks = 0;
	$current_track = 0;
	set_playing 0;
	set_progress;
}

sub playlist {
	my $cmd = shift;
	switch ($cmd) {
	case "clear"		{ clear_track; }
	case "stop"		{ set_playing 0; set_status $cmd; }
	case "pause"		{ lms_query_send "mode"; }
	case "title"		{ shift; set_title uri_unescape(shift); }
	case "album"		{ shift; set_album uri_unescape(shift); }
	case "artist"		{ shift; set_artist uri_unescape(shift); }
	case "duration"		{ shift; $current_duration = shift; set_time; }
	case "tracks"		{ $total_tracks = int(shift); }
	case "loadtracks"	{ lms_query_send "playlist tracks"; }
	case "addtracks"	{ lms_query_send "playlist tracks"; }
	case "index"		{ 
		my $id = int(shift);
		$current_track = $id + 1; 
		set_progress;
		lms_query_send "playlist title $id";
		lms_query_send "playlist album $id";
		lms_query_send "playlist artist $id";
		lms_query_send "playlist duration $id";
		lms_query_send "time";
	}
	case "newsong"		{ 
		set_title uri_unescape(shift);
		my $id = shift;
		if (defined $id) { 
			$current_track = $id + 1; 
			lms_query_send "playlist album $id";
			lms_query_send "playlist artist $id";
			lms_query_send "playlist duration $id";
		}
		set_progress;
		$elapsed_time = 0;
		set_playing 1;
	}
	else			{ print "playlist: $cmd\n"; }
	}
}

sub mixer {
	my $cmd = shift;
	switch ($cmd) {
	case "volume"	{ set_volume uri_unescape(shift); }
	else		{ print "mixer: $cmd\n"; }
	}
}

sub mode {
	my $cmd = shift;
	switch ($cmd) {
	case "stop"	{ set_playing 0; set_status $cmd; }
	case "pause"	{ set_playing 0; set_status $cmd; }
	case "play"	{ 
		set_playing 1;
		set_status $cmd; 
		lms_query_send "playlist tracks"; 
		lms_query_send "playlist index"; 
	}
	else		{ print "mode: $cmd\n"; }
	}
}

sub prefset {
	my $cmd = shift;
	switch ($cmd) {
	case "server"	{ if (shift eq "volume") { set_volume shift; } }
	else		{ print "prefset: $cmd\n"; }
	}
}

sub lms_response {
	my $r = shift;
	my @s = split(/ /, $r);
	switch ($s[0]) {
	case "playlist" { shift @s; playlist @s; }
	case "prefset" 	{ shift @s; prefset @s; }
	case "mixer" 	{ shift @s; mixer @s; }
	case "mode" 	{ shift @s; mode @s; }
	case "time"	{ $elapsed_time = $s[1]; set_time; }
	else		{ print "unknown: [$s[0]]\n"; }
	}
}
