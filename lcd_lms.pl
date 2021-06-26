#!/usr/bin/perl -w

use 5.024;
use strict;
use warnings;
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
use Sys::Hostname;
use Encode;

my $DEF_LCDD = "localhost";
my $DEF_LCDPORT = "13666";
my $DEF_LMS = "localhost";
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
getopts("d:l:v:mLh", \%opt);

if ( defined($opt{h}) ) {
	HELP_MESSAGE;
}

my ($dh, $dp) = split(/:/, $opt{d}) if (defined($opt{d}));
my $LCDD = (defined($dh) && $dh ne '')? $dh: $DEF_LCDD;
my $LCDPORT = (defined($dp) && $dp ne '')? $dp: $DEF_LCDPORT;

my ($lh, $lp) = split(/:/, $opt{l}) if (defined($opt{l}));
my $LMS = (defined($lh) && $lh ne '')? $lh: $DEF_LMS;
my $LMSPORT = (defined($lp) && $lp ne '')? $lp: $DEF_LMSPORT;

my $deb_all = defined($opt{v}) ? $opt{v} eq 'all': 0;
my $deb_lcd = $deb_all || (defined($opt{v}) ? $opt{v} eq 'lcd': 0);
my $deb_lms = $deb_all || (defined($opt{v}) ? $opt{v} eq 'lms': 0);
my $charmap = defined($opt{m});
my $listen = defined($opt{L});

my $PLAYER = hostname;

if ( $#ARGV == 0 ) {
	$PLAYER = $ARGV[0];
}

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

STDOUT->autoflush(1);
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
my $current_track_id = -1;
my $elapsed_time = 0;
my $current_duration = 0;
my $title = "";
my $artist = "";
my $album = "";
my $playing = 0;
my $t = 0;
my $start_time;

my $sub = "subscribe playlist,mixer,time,mode,play,pause,title,album,artist";
if ( $listen ) {
	$sub = "listen 1";
}
debug "lms < $sub", $deb_lms;
my $ans = send_receive $lms, $sub;
chomp $ans;
debug "lms > $ans", $deb_lms;

lms_send "mixer volume ?";
lms_send "mode ?";
lms_send "time ?";
lms_send "duration ?";
lms_send "playlist index ?";
lms_send "title ?";
lms_send "album ?";
lms_send "artist ?";

while () {
	while (my @ready = $sel->can_read(0.9)) {
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
					if ($playing) {
						lms_send "playlist index +1";
					} else {
						lms_send "playlist clear";
					}
				} elsif ( $input eq "key $pause_key\n" ) {
					my $p = $playing == 1? 1: 0;
					lms_send "pause $p";
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
	print STDERR "Usage: $progname [<options>] [player]\n";
	print STDERR "    where <options> are:\n" .
		"	-d <server:port>	connect to LCDd ($DEF_LCDD:$DEF_LCDPORT)\n" .
		"	-l <server:port>	connect to LMS ($DEF_LMS:$DEF_LMSPORT)\n" .
		"	-v <lcd | lms | all>	debug conversation with lcd, lms or both\n" .
		"	-L			listen to all messages from lms\n" .
		"	-m			map UTF-8 chars for display on lcd\n".
		"	-h			this help message\n".
		"    if player is omitted it defaults to the local host name\n";
	exit(0);
}

sub send_receive {
	my $fd = shift;
	my $cmd = shift;

	print $fd qq($cmd\n);
	return <$fd>;
}

sub lcd_send_receive {
	my $cmd = shift;
	debug "lcd < $cmd", $deb_lcd;
	my $res = send_receive $lcd, $cmd;
	chomp $res;
	debug "lcd > $res", $deb_lcd;
	return $res;
}

sub lms_send_receive {
	my $query = shift . " ?";
	print $lms "$query\n";
	debug "lms < " . uri_unescape($query), $deb_lms;

	while () {
		my $ans = <$lms>;
		chomp $ans;
		debug "lms > " . uri_unescape($ans), $deb_lms;
		if ($ans =~ /^$query (.+)/) {
			return $1;
		}
	}
}

sub lms_send {
	my $cmd = "$player_id " . shift;
	print $lms "$cmd\n";
	debug "lms < " . uri_unescape($cmd), $deb_lms;

	my $ans = <$lms>;
	lms_response $ans;
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
	$s =~ tr/"//d;

	# see https://www.i18nqa.com/debug/utf8-debug.html and
	# table 4: http://fab.cba.mit.edu/classes/863.06/11.13/44780.pdf
	if ($charmap) {
		my $t = '';
		foreach my $c (split //, decode( "utf8", $s )) {
			my $o = ord( $c );
			switch ($o) {
				case 0x03bc { $c = chr(0xb5) }
				case 0x014d { $c = 'o' }
				case 0x2010 { $c = '-' }
				case 0x2011 { $c = '-' }
				case 0x2012 { $c = '-' }
				case 0x2013 { $c = '-' }
				case 0x2018 { $c = "`" }
				case 0x2019 { $c = "\'" }
				case 0x201c { $c = "\\\"" }
				case 0x201d { $c = "\\\"" }
				case 0x2026 { $c = "..." }
				case 0x2039 { $c = "<" }
				case 0x203a { $c = ">" }
				case 0x266f { $c = '#' }
				elsif ($o > 0xff) {
					msg("unknown unicode $o", $deb_lms);
					$c = chr(0xff);
				}
			}
			$t .= $c;
		}
		$s = $t;
	}
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

sub two_lines {
	my $l1 = shift;
	my $l2 = shift;

	lcd_send_receive "widget_set $PLAYER album 1 2 $width 2 h 3 \"\"";
	if (length($l1) >= $width && length($l2) >= $width) {
		my $s = multiline("$l1 $l2");
		lcd_send_receive "widget_set $PLAYER artist 1 3 $width 3 h 3 \"\"";
		lcd_send_receive "widget_set $PLAYER title 1 1 $width 3 v 8 \"$s\"";
		return 1;
	}
	if (length($l1) >= $width && length($l2) == 0) {
		my $t = multiline($l1);
		lcd_send_receive "widget_set $PLAYER title 1 1 $width 3 v 8 \"$t\"";
		return 1;
	}
	if (length($l1) >= $width) {
		my $t = multiline($l1);
		lcd_send_receive "widget_set $PLAYER title 1 1 $width 2 v 8 \"$t\"";
		my $a = centre($width, $l2);
		lcd_send_receive "widget_set $PLAYER artist 1 3 $width 3 h 3 \"$a\"";
		return 1;
	}
	if (length($l2) >= $width) {
		my $t = centre($width, $l1);
		lcd_send_receive "widget_set $PLAYER title 1 1 $width 1 h 3 \"$t\"";
		my $a = multiline($l2);
		lcd_send_receive "widget_set $PLAYER artist 1 2 $width 3 v 8 \"$a\"";
		return 1;
	}
	return 0;
}

sub set_artist {
	$artist = shift;
	$artist = (!defined $artist)? "": trim($artist);

	if (length($title) == 0 && two_lines($album, $artist)) {
		return;
	}
	if (length($album) == 0 && two_lines($title, $artist)) {
		return;
	}
	if (length($artist) == 0 && two_lines($title, $album)) {
		return;
	}
	my $t = centre($width, $title);
	my $a = centre($width, $artist);
	my $l = centre($width, $album);
	lcd_send_receive "widget_set $PLAYER title 1 1 $width 1 h 3 \"$t\"";
	lcd_send_receive "widget_set $PLAYER album 1 2 $width 2 h 3 \"$l\"";
	lcd_send_receive "widget_set $PLAYER artist 1 3 $width 3 h 3 \"$a\"";
}

sub set_status {
	my $state = centre(10, shift);
	lcd_send_receive "widget_set $PLAYER status 6 4 \"$state\"";
}

sub set_progress {
	$current_track_id = shift;
	$total_tracks = shift;
	my $p = "";
	if ($total_tracks > 0) {
		$p = sprintf "%d/%d", $current_track_id + 1, $total_tracks;
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
		if (defined($current_duration) && $current_duration > 0) {
			$current_duration -= $elapsed_time;
			$elapsed_time = 0;
		}
	} else {
		$start_time = time();
		lcd_send_receive "screen_set $PLAYER priority foreground backlight on";
		lms_send "playlist tracks ?";
		lms_send "playlist index ?";
	}
}

sub set_stopped {
	set_title "";
	set_album "";
	set_artist "";
	set_status "stop";
	set_playing 0;
}

sub playlist {
	my $cmd = shift;
	switch ($cmd) {
	case "clear"		{ set_stopped; set_progress -1, 0; }
	case "stop"		{ set_stopped; }
	case "pause"		{ set_playing !shift; }
	case "tracks"		{ set_progress $current_track_id, int(shift); }
	case "index"		{ set_progress int(shift), $total_tracks; }
	case "loadtracks"	{ lms_send "playlist tracks ?"; }
	case "addtracks"	{ lms_send "playlist tracks ?"; }
	case "load_done"	{ lms_send "playlist tracks ?"; }
	case "delete"		{ lms_send "playlist tracks ?"; lms_send "playlist index ?"; }
	case "newsong"		{
		shift;
		my $id = shift;
		if (defined $id) {
			if ($playing && $id == $current_track_id) {
				return;
			}
			lms_send "duration ?";
			lms_send "album ?";
			set_progress $id, $total_tracks;
		} else {
			set_album "";
		}
		set_playing 1;
		lms_send "title ?";
		lms_send "artist ?";
	}
	else { msg( "playlist: $cmd", $deb_lms ); }
	}
}

sub mixer {
	my $cmd = shift;
	switch ($cmd) {
	case "volume"	{
		my $vol = uri_unescape(shift);
		my $c = substr($vol, 0, 1);
		if ($c eq '-' || $c eq '+') {
			lms_send "mixer volume ?";
		} else {
			set_volume $vol;
		}
	}
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
	}
	else		{ msg( "mode: $cmd", $deb_lms ); }
	}
}

sub lms_response {
	my $input = shift;
	chomp $input;
	debug "lms > " . uri_unescape($input), $deb_lms;
	if ( $input =~ /$player_id (.+)/ ) {
		my $r = $1;
		my @s = split(/ /, $r);
		switch ($s[0]) {
		case "playlist" { shift @s; playlist @s; }
		case "mixer" 	{ shift @s; mixer @s; }
		case "mode" 	{ shift @s; mode @s; }
		case "time"	{ set_time $s[1]; }
		case "pause"	{ set_playing !$s[1]; }
		case "artist"	{ shift @s; set_artist uri_unescape shift @s; }
		case "album"	{ shift @s; set_album uri_unescape shift @s; }
		case "title"	{ shift @s; set_title uri_unescape shift @s; }
		case "duration"	{ shift @s; $current_duration = shift @s; set_elapsed_time; }
		else		{ msg "unknown: [$r]", $deb_lms; }
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

=pod

=head1 NAME

lcd_lms - Gets playlist information from Logitech Media Server and sends it
to LCDproc.

=head1 SYNOPSIS

B<lcd_lms.pl> [OPTIONS] I<Player Name>

=head1 OPTIONS

=over 4

=item B<-v [all | lms | lcd]>

Enable debugging of: everything, the LMS protocol or the LCDproc protocol.

=item B<-d lcd-server[:lcd-port]>

Set the host and port for the LCDproc server. (Default 'localhost' and
13666.)

=item B<-l lms-server[:lms-port]>

Set the host and port for the LMS server. (Default 'localhost' and 9090.)

=item B<-m>

Perform crude UTF-8 character mapping to display "special" characters properly
on, e.g., HD44780 displays.

=item B<Player Name>

The LMS player name.

=back

=head1 DIAGNOSTICS

=over 4

=item Cannot connect to LMS server at localhost:9090

By default lcd_lms tries to connect to LMS running on host I<localhost> and
port 9090.  Change the host and port where LMS is running using the
B<-l> option above.

=item Cannot connect to LCDd daemon at localhost:13066

By default lcd_lms tries to connect to the LCDproc server running
on host I<localhost> and port 13066. Change the host and port where
LCDproc is running using the B<-d> option above.

=item Unable to find player I<Player Name>

lcd_lms is unable to find the specified player on the LMS server
specified. Debugging the LMS protocol using the B<-v lms> option
will show a list of available players.

=back

=head1 REQUIRES

Perl 5.005, Getopt::Std, Log::Message::Simple;

All available on CPAN: http://www.cpan.org/

=head1 BUGS

Please report any bugs, or request features, on the Issue Tracker at the
website below.

=head1 WEBSITE

See B<https://github.com/jscrane/lcd_lms> for the latest version.

=cut

