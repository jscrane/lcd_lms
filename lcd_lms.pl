#!/usr/bin/perl -w

use 5.005;
use strict;
use Getopt::Std;
use IO::Socket;
use IO::Select;
use Fcntl;
use Date::Parse;
use Switch;
use URI::Escape;
use POSIX qw(strftime);
use Time::HiRes;
use Log::Message::Simple qw(debug msg);

my $DEF_LCDD = "localhost";
my $DEF_LCDPORT = "13666";
my $DEF_LMS = "rpi";
my $DEF_LMSPORT = "9090";

my $width = 20;
my $lines = 4;
my $stop_key = "Enter";
my $pause_key = "Down";

my $progname = $0;
   $progname =~ s#.*/(.*?)$#$1#;

sub error($@);
sub send_receive;
sub lcd_send_receive;
sub lms_send_receive;
sub lms_send;
sub lms_response;
sub set_clock_widget;
sub set_title;
sub set_album;
sub set_artist;
sub set_status;
sub set_playing;
sub set_volume;
sub HELP_MESSAGE;

my %opt = ();
getopts("d:l:v:", \%opt);

my ($dh, $dp) = split(/:/, $opt{d}) if (defined($opt{d}));
my $LCDD = (defined($dh) && $dh ne '')? $dh: $DEF_LCDD;
my $LCDPORT = (defined($dp) && $dp ne '')? $dp: $DEF_LCDPORT;

my ($lh, $lp) = split(/:/, $opt{l}) if (defined($opt{l}));
my $LMS = (defined($lh) && $lh ne '')? $lh: $DEF_LMS;
my $LMSPORT = (defined($lp) && $lp ne '')? $lp: $DEF_LMSPORT;

my $deb_all = defined($opt{v}) ? $opt{v} eq 'all': 0;
my $deb_lcd = $deb_all || (defined($opt{v}) ? $opt{v} eq 'lcd': 0);
my $deb_lms = $deb_all || (defined($opt{v}) ? $opt{v} eq 'lms': 0);

if ( $#ARGV != 0 ) {
	HELP_MESSAGE;
}

my $PLAYER = $ARGV[0];

# Connect to the servers...
my $lms = IO::Socket::INET->new(
		Proto     => 'tcp',
		PeerAddr  => $LMS,
		PeerPort  => $LMSPORT,
	) or error(1, "cannot connect to LMS server at $LMS:$LMSPORT");
$lms->autoflush(1);

my $player_id = "";
my $pcount = lms_send_receive "player count";
for (my $i = 0; $i < $pcount; $i++) {
	my $p = lms_send_receive "player name $i";
	if ($p eq $PLAYER) {
		$player_id = lms_send_receive "player id $i";
		last;
	}
}

$player_id ne "" || die "unable to find player $PLAYER";

my $lcd = IO::Socket::INET->new(
		Proto     => 'tcp',
		PeerAddr  => $LCDD,
		PeerPort  => $LCDPORT,
	) or error(1, "cannot connect to LCDd daemon at $LCDD:$LCDPORT");

# Make sure our messages get there right away
$lcd->autoflush(1);

my $read_set = new IO::Select();
$read_set->add($lcd);
$read_set->add($lms);

sleep 1;	# Give server plenty of time to notice us...

my $lcdresponse = send_receive $lcd, "hello";
debug( $lcdresponse, $deb_lcd );

# get width & height from server's greet message
if ($lcdresponse =~ /\bwid\s+(\d+)\b/) {
	$width = 0 + $1;
}	
if ($lcdresponse =~ /\bhgt\s+(\d+)\b/) {
	$lines = 0 + $1;
}	

lcd_send_receive "client_set name {$progname}";
lcd_send_receive "screen_add $PLAYER";
lcd_send_receive "screen_set $PLAYER priority foreground name playback heartbeat off";
lcd_send_receive "widget_add $PLAYER title scroller";
lcd_send_receive "widget_add $PLAYER album scroller";
lcd_send_receive "widget_add $PLAYER artist scroller";
lcd_send_receive "widget_add $PLAYER volume string";
lcd_send_receive "widget_add $PLAYER status string";
lcd_send_receive "widget_add $PLAYER progress string";

lcd_send_receive "client_add_key $stop_key";
lcd_send_receive "client_add_key $pause_key";

lcd_send_receive "screen_add CLOCK";
lcd_send_receive "screen_set CLOCK -priority info heartbeat off backlight off";
lcd_send_receive "widget_add CLOCK time string";
lcd_send_receive "widget_add CLOCK day string";
lcd_send_receive "widget_add CLOCK date string";

my $sel = IO::Select->new( $lcd, $lms );

my $total_tracks = 0;
my $current_track = 0;
my $elapsed_time = 0;
my $current_duration = 0;
my $title = "";
my $artist = "";
my $album = "";
my $playing = 0;
my $t = 0;
my $start_time;

debug( "lms < listen 1", $deb_lms );
my $ans = send_receive $lms, "listen 1";
chomp $ans;
debug( "lms > $ans", $deb_lms );

lms_send "mixer volume ?";
lms_send "mode ?";

while () {
	while (my @ready = $sel->can_read(1)) {
		my $fh;
		foreach $fh (@ready) {
			my $input = <$fh>;
			if ( !defined $input ) {
				close $lcd;
				close $lms;
				exit;
			}
			if ( $fh == $lms ) {
				lms_response $input;
			} elsif ( $fh == $lcd ) {
				if ( $input eq "key $stop_key\n" ) {
					lms_send "playlist index +1";
				} elsif ( $input eq "key $pause_key\n" ) {
					lms_send "pause";
				}
			}
		}
	}
	if ($playing) {
		$elapsed_time = time() - $start_time;
		set_elapsed_time();
	}
	my $fmt = ($t++ & 1)? "%H:%M": "%H %M";
	set_clock_widget( "time", 2, strftime( $fmt, localtime() ));
	set_clock_widget( "day", 3, strftime( "%A", localtime() ));
	set_clock_widget( "date", 4, strftime( "%d %B %Y", localtime() ));
}

sub error($@) {
	my $status = shift;
	my @msg = @_;

	print STDERR $progname . ": " . join(" ", @msg) . "\n";
	exit($status) if ($status);
}

sub HELP_MESSAGE {
	print STDERR "Usage: $progname [<options>] <player>\n";
	print STDERR "    where <options> are:\n" .
		"	-d <server:port>	connect to LCDd ($DEF_LCDD:$DEF_LCDPORT)\n" .
		"	-l <server:port>	connect to LMS ($DEF_LMS:$DEF_LMSPORT)\n" .
		"	-v <lcd | lms | all>	debug conversation with lcd, lms or both\n";
	exit(0);
}

sub send_receive {
	my $fd = shift;
	my $cmd = shift;

	print $fd "$cmd\n";
	return <$fd>;
}

sub lcd_send_receive {
	my $cmd = shift;
	debug( "lcd < $cmd", $deb_lcd );
	my $res = send_receive $lcd, $cmd;
	chomp $res;
	debug( "lcd > $res", $deb_lcd );
	return $res;
}

sub lms_send_receive {
	my $query = shift;

	print $lms "$query ?\n";
	debug( "lms < $query ?", $deb_lms );

	while () {
		my $ans = <$lms>;
		chomp $ans;
		debug( "lms > $ans", $deb_lms );
		if ($ans =~ /^$query (.+)/) {
			debug( "lms > $1", $deb_lms );
			return $1;
		}
	}
}

sub lms_send {
	my $cmd = shift;

	print $lms "$player_id $cmd\n";
	debug( "lms < $player_id $cmd", $deb_lms );
}

sub centre {
	my $w = shift;
	my $t = shift;
	my $l = length($t);
	return $t if ($l > $w);
	my $a = int(($w - $l) / 2);
	my $b = $w - $l - $a;
	return (' ' x $a) . $t . (' ' x $b);
}

sub trim {
	my $s = shift;
	$s =~ s/^\s+|\s+$//g;
	return $s;
}

sub set_title {
	$title = shift;
	$title = (!defined $title)? "": trim($title);
}

sub set_album {
	$album = shift;
	$album = (!defined $album)? "": trim($album);
}

sub multiline {
	my $s = shift;
	my $t = "";
	my $l = "";
	my $len = 0;
	foreach ( split(' ', $s) ) {
		my $w = $_;
		my $n = length($w);
		if ($n + $len < $width) {
			if ($len > 0) {
				$l = "$l $w";
				$len += $n + 1;
			} else {
				$l = $w;
				$len = $n;
			}
		} else {
			$t = $t . centre($width, $l);
			$l = $w;
			$len = $n;
		}
	}
	return $t . centre($width, $l);
}

sub set_artist {
	$artist = shift;
	$artist = (!defined $artist)? "": trim($artist);

	if (length($album) == 0) {
		if (length($title) >= $width && length($artist) >= $width) {
			my $s = multiline("$title $artist");
			lcd_send_receive "widget_set $PLAYER title 1 1 $width 3 v 8 \"$s\"";
			return;
		} 
		if (length($title) >= $width) {
			my $t = multiline($title);
			lcd_send_receive "widget_set $PLAYER title 1 1 $width 2 v 8 \"$t\"";
			my $a = centre($width, $artist);
			lcd_send_receive "widget_set $PLAYER artist 1 3 $width 3 h 3 \"$a\"";
			return;
		}
		if (length($artist) >= $width) {
			my $t = centre($width, $title);
			lcd_send_receive "widget_set $PLAYER title 1 1 $width 1 h 3 \"$t\"";
			my $a = multiline($artist);
			lcd_send_receive "widget_set $PLAYER artist 1 2 $width 3 v 8 \"$a\"";
			return;
		}
	}
	my $t = centre($width, $title);
	my $a = centre($width, $artist);
	my $l = centre($width, $album);
	lcd_send_receive "widget_set $PLAYER title 1 1 $width 1 h 3 \"$t\"";
	lcd_send_receive "widget_set $PLAYER album 1 2 $width 2 h 3 \"$a\"";
	lcd_send_receive "widget_set $PLAYER artist 1 3 $width 3 h 3 \"$l\"";
}

sub set_status {
	my $state = centre(10, shift);
	lcd_send_receive "widget_set $PLAYER status 6 4 \"$state\"";
}

sub set_progress {
	my $p = "";
	if ($total_tracks > 0) {
		$p = sprintf "%d/%d", $current_track, $total_tracks;
		$p = sprintf "% 6s", $p;
	}
	lcd_send_receive "widget_set $PLAYER progress 15 4 \"$p\"";
}

sub set_elapsed_time {
	# duration is unknown for radio stream so just show elapsed time
	my $remain;
	if (defined($current_duration)) {
		$remain = $current_duration - $elapsed_time;
		if ($remain < 0) {
			$remain = -$remain;
		}
	} else {
		$remain = $elapsed_time;
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

sub set_time {
	$elapsed_time = shift;
	$start_time = time() - $elapsed_time;
	set_elapsed_time;
}

sub set_volume {
	my $vol = shift;
	if ($vol eq "100") {
		$vol = "99";
	}
	$vol = sprintf "%02s", $vol;
	lcd_send_receive "widget_set $PLAYER volume 1 4 $vol";
}

sub set_playing {
	$playing = shift;
	if ($playing == 0) {
		lcd_send_receive "screen_set $PLAYER priority background backlight off";
		if ($current_duration > 0) {
			$current_duration -= $elapsed_time;
			$elapsed_time = 0;
		}
	} else {
		lcd_send_receive "screen_set $PLAYER priority foreground backlight on";
		$start_time = time();
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
	case "stop"		{ lms_send "mode ?"; }
	case "pause"		{ lms_send "mode ?"; }
	case "title"		{ shift; set_title uri_unescape(shift); }
	case "album"		{ shift; set_album uri_unescape(shift); }
	case "artist"		{ shift; set_artist uri_unescape(shift); }
	case "duration"		{ shift; $current_duration = shift; set_elapsed_time; }
	case "tracks"		{ $total_tracks = int(shift); }
	case "loadtracks"	{ lms_send "playlist tracks ?"; }
	case "addtracks"	{ lms_send "playlist tracks ?"; }
	case "load_done"	{ lms_send "playlist tracks ?"; }
	case "index"		{ 
		my $a = uri_unescape(shift);
		my $id;
		if ( $a ne "+1" ) {
			$id = int($a);
			$current_track = $id + 1;
		} elsif ( $current_track < $total_tracks ) {
			$id = $current_track;
			$current_track++; 
		} else {
			lms_send "stop";
			return;
		}
		set_progress;
		lms_send "playlist title $id ?";
		lms_send "playlist album $id ?";
		lms_send "playlist artist $id ?";
		lms_send "playlist duration $id ?";
		lms_send "time ?";
	}
	case "newsong"		{ 
		my $t = uri_unescape(shift);
		my $id = shift;
		if (defined $id) { 
			$current_track = $id + 1; 
			lms_send "playlist title $id ?";
			lms_send "playlist album $id ?";
			lms_send "playlist artist $id ?";
			lms_send "playlist duration $id ?";
			lms_send "time ?";
		} else {
			set_album "";
			lms_send "playlist title 0 ?";
			lms_send "playlist artist 0 ?";
		}
		set_progress;
		set_playing 1;
	}
	else { msg( "playlist: $cmd", $deb_lms ); }
	}
}

sub mixer {
	my $cmd = shift;
	switch ($cmd) {
	case "volume"	{ set_volume uri_unescape(shift); }
	else		{ msg( "mixer: $cmd", $deb_lms ); }
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
		lms_send "playlist tracks ?"; 
		lms_send "playlist index ?"; 
	}
	else		{ msg( "mode: $cmd", $deb_lms ); }
	}
}

sub prefset {
	my $cmd = shift;
	switch ($cmd) {
	case "server"	{ if (shift eq "volume") { set_volume shift; } }
	else		{ msg( "prefset: $cmd", $deb_lms ); }
	}
}

sub lms_response {
	my $input = shift;
	chomp $input;
	debug( "lms > $input", $deb_lms );
	if ( $input =~ /$player_id (.+)/ ) {
		my $r = $1;
		my @s = split(/ /, $r);
		switch ($s[0]) {
		case "playlist" { shift @s; playlist @s; }
		case "prefset" 	{ shift @s; prefset @s; }
		case "mixer" 	{ shift @s; mixer @s; }
		case "mode" 	{ shift @s; mode @s; }
		case "time"	{ set_time $s[1]; }
		case "play"	{ lms_send "mode ?"; }
		case "pause"	{ lms_send "mode ?"; }
		else		{ msg( "unknown: [$r]", $deb_lms ); }
		}
	}
}

sub set_clock_widget {
        my $w = shift;
        my $l = shift;
        my $s = shift;
        $s = centre($width, $s);
        send_receive $lcd, "widget_set CLOCK $w 1 $l \"$s\"";
}

