#!/usr/bin/perl -l

# eco-eye serial to Emoncms script
# Jonathan D Clark
# http://www.setfirelabs.com


use strict;
use warnings;
use POSIX;
use IO::Handle;
use Device::SerialPort qw( :PARAM :STAT 0.07 );
use LWP::Useragent;

# stop buffering of input..
$| = 1;

use vars qw { $gap_flag $quiet $debug};

$quiet = 0;
$debug = 0;

# write output to a file..
# my $outfile = '/path/to/power.csv';
my $outfile;

# identify the serial port of the PL2303..
my $port = '/dev/tty.usbserial';

# Set your feed name and API key here..
my $feed_name = 'total';
my $api_key = 'xxxxxxxxxxxxx';
my $feed_target = 'http://emoncms.org';


# ignore readings over this max current:
my $max_amps = 120;

# define voltage so we can calculate power:
my $voltage = 220;

# average over this many samples. eg. 7x4s= 28 second averages:
my $samples_to_average = 7;

# set up serial port..
my $serialport = Device::SerialPort->new($port, $debug)
|| die "Can't open $port: $!";

$serialport->databits(8);
$serialport->parity("none");
$serialport->stopbits(1);
$serialport->baudrate(19200);

$serialport->handshake("rts");


# set up useragent for post
my $ua = LWP::UserAgent->new;
$ua->timeout(10);


print "Writing to ", $feed_target, " with ", $feed_name unless $quiet;
print "Averaging $samples_to_average samples.";

$serialport->purge_rx;

# expecting msb followed by lsb, then a gap
# or 0xff if no reading.
# Every 4 seconds 2 bytes are sent these are amps in binary * 100.
# So ((byte 1*256) + byte 2)/100

if ($outfile) {
    open(OUTFILE, ">>$outfile")
    || die $!;
    autoflush OUTFILE 1;
    print "Writing data to $outfile..\n" unless $quiet;
}

my ($data, $bytes_in, $count, $timestamp, $avg_power,
$amps, $avg_amps, $samples, $msb, $lsb, $bad_reading,
$feed_url, $http_response);


# set a timeout alarm to flag if we are in the four second gap..
$gap_flag = 0;

$SIG{ALRM} = sub { $gap_flag = 1; print "GAP detected!" unless ($quiet && !$debug); };


# loop continuously..
while (1) {
    $samples = 0;
    $avg_amps = 0;
    # average results over this loop..
    for ($count = 1; $count <= $samples_to_average; $count++) {
        print "reading $count.." if $debug;
        do {
            ($bytes_in, $data) = $serialport->read(255);
        } while !$bytes_in;
        
        # expecting this to be the msb..
        
        print 'got msb' if $debug;
        $msb = unpack('C', $data);
        $bad_reading = 1 if ($msb == 255);
        $amps = $msb * 256;
        
        # next will be lsb and should be within a second..
        alarm(2);
        
        do {
            ($bytes_in, $data) = $serialport->read(255);
        } while !$bytes_in;
        
        # this is lsb so next will be msb..
        alarm(0);
        print 'got lsb' if $debug;
        
        if ($gap_flag) {
            print "CAUGHT OUT OF SYNC - IGNORING." unless ($quiet && !$debug);
            $gap_flag = 0;
            do {
                ($bytes_in, $data) = $serialport->read(255);
            } while !$bytes_in;
            next;
        }
        
        $lsb = unpack('C', $data);
        $bad_reading = 1 if ($lsb == 255);
        if ($bad_reading) {
            print "BAD READING: msb: $msb, lsb: $lsb\n" unless ($quiet && !$debug);
            $bad_reading = 0;
            next;
        }
        $amps += $lsb;
        $amps = $amps / 100;
        
        if ($amps > $max_amps) {
            print "BAD READING (too high): msb: $msb, lsb: $lsb\n" unless ($quiet && !$debug);
            next;
        }
        $samples++;
        print "sample: $samples, msb: $msb, lsb; $lsb, amps: $amps" unless ($quiet && !$debug);
        $avg_amps += $amps;
        
    } # end of for
    
    $avg_amps = $avg_amps / $samples;
    
    # format to 2 decimals..
    $avg_amps = sprintf("%.2f", $avg_amps);
    
    $timestamp = POSIX::strftime('%Y-%m-%d %H:%M:%S', localtime());
    print "$timestamp avg_amps: $avg_amps" unless ($quiet && !$debug);
    print OUTFILE "$timestamp,$avg_amps" if $outfile;
    
    # power is in Watts:
    $avg_power = $avg_amps * $voltage;
    # format to 2 decimals..
    $avg_power = sprintf("%.2f", $avg_power);
    
    $feed_url = 'input/post.json?json={'
                . $feed_name . '_watts:' . $avg_power . '}&apikey='
                . $api_key;
    
    $http_response = $ua->get($feed_target . '/' . $feed_url);
    
    if (!$http_response->is_success) {
        print 'Failed to post: ', $http_response->decoded_content unless $quiet;
    }

    
} # end of while

# we don't get here as the loop is continous..
$serialport->write_drain;
$serialport->close;
undef $serialport;
close(OUTFILE) if $outfile;

