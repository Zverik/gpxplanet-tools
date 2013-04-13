#!/usr/bin/perl

# This script receives CSV file of "lat,lon" and makes a lot of bitiles.
# A bitile is a 8k bit array. Those should be converted to PNG images with bitiles2png.pl
# Written by Ilya Zverev, licensed WTFPL.

use strict;
use Math::Trig;
use File::Path 2.07 qw(make_path);
use File::Basename;
use Bit::Vector;
use Fcntl qw( SEEK_SET O_RDWR O_RDONLY O_BINARY O_CREAT );
use Getopt::Long;

my $factor = 10**7; # number by which all coordinates in source CSV are multiplied
my $notify_points = 50000; # how often to print dots and save state file

my $tile_folder;
my $zoom;
my $bbox_str = '-180,-85,180,85';

my $help;
my $verbose;
my $infile = '-';
my $thread_str;
my $state_file = 'gpx2bitiles.state';
my $lines;

GetOptions('h|help' => \$help,
           'o|output=s' => \$tile_folder,
           'z|zoom=i' => \$zoom,
           'v|verbose' => \$verbose,
           'i|input=s' => \$infile,
           'b|bbox=s' => \$bbox_str,
           't|thread=s' => \$thread_str,
           'l|lines' => \$lines,
           ) || usage();

if( $help ) {
  usage();
}

usage("Please specify output directory with -o") unless defined($tile_folder);
usage("Please specify zoom level with -z") unless defined($zoom);

die('Drawing lines is not implemented yet.') if $lines;

my @bbox = split(",", $bbox_str);
die ("badly formed bounding box - use four comma-separated values for left longitude, ".
    "bottom latitude, right longitude, top latitude") unless $#bbox == 3;
die("max longitude is less than min longitude") if $bbox[2] < $bbox[0];
die("max latitude is less than min latitude") if $bbox[3] < $bbox[1];

my $zoom2 = 2**$zoom;
my $xmintile = 0;
my $xmaxtile = 2**18;
my $thread = '';
my @cache = ('', undef, 0);
my $maxdist = $zoom < 11 ? 1 : 2**($zoom - 11);
$maxdist = 255 if $maxdist > 255;

if( defined($thread_str) ) {
  die("Badly formed thread string: it must be THREAD,TOTAL") unless $thread_str =~ /^(\d+),(\d+)$/;
  $thread = $1;
  my $total = $2;
  die("Total number of threads must be no more than 16") if $total <1 || $total > 16;
  die("Thread number is higher than number of threads") if $thread > $total || $thread < 1;

  my $eps = 10**-8;
  my $bxmin = int(($bbox[0]+$eps+180)/360 * $zoom2);
  my $bxmax = int(($bbox[2]-$eps+180)/360 * $zoom2);
  my $bxwidth = $bxmax - $bxmin + 1;
  die("Total number of threads is higher than horizontal number of tiles") if $total > $bxwidth;
  my $width = int(($bxwidth + $total - 1) / $total);
  $xmintile = $bxmin + ($thread-1) * $width;
  $xmaxtile = $xmintile + $width - 1;
}

my $count = 0;
my $ctarget = 0;
if( open(STATE, "<$state_file$thread") ) {
  my $line = <STATE>;
  close STATE;
  $ctarget = $1 if $line =~ /^(\d+)/;
  flush_tile();
  print STDERR "Continuing from point $ctarget\n" if $verbose;
}

my $filemode = 0; # 1=csv, 2=gpx
my @lastpoint;

open CSV, "<$infile" or die "Cannot open $infile: $!\n";
while(<CSV>) {
  if( !$filemode ) {
    if( /^-?\d+(?:\.\d+)?,\s*-?\d+(?:\.\d+)?/ ) {
        $filemode = 1;
    } elsif( /\<gpx / ) {
        $filemode = 2;
    } else {
        next;
    }
  }

  my $lat;
  my $lon;
  if( $filemode == 1 ) {
    next if !/^(-?\d+(?:\.\d+)?),\s*(-?\d+(?:\.\d+)?)/;
    $lat = $1 / $factor;
    $lon = $2 / $factor;
  } elsif( $filemode == 2 ) {
    undef @lastpoint if /\<\/trkseg\>/;
    next if !/\<trkpt.+?l(at|on)=['"](-?\d+(?:\.\d+)?)['"]\s+l(?:at|on)=['"](-?\d+(?:\.\d+)?)['"]/;
    $lat = $1 eq 'at' ? $2 : $3;
    $lon = $1 eq 'at' ? $3 : $2;
  }

  $count++;
  next if $count < $ctarget;
  next if $lat <= $bbox[1] || $lat >= $bbox[3] || $lon <= $bbox[0] || $lon >= $bbox[2];
  if( $count % $notify_points == 0 && open(STATE, ">$state_file$thread") ) {
    print STDERR '.' if $verbose;
    print STATE $count;
    close STATE;
  }

  my $x = ($lon+180)/360 * $zoom2;
  my $y = (1 - log(tan(deg2rad($lat)) + sec(deg2rad($lat)))/pi)/2 * $zoom2;
  my $xtile = int($x);
  my $ytile = int($y);
  next if $xtile < $xmintile || $xtile > $xmaxtile;
  my $xpix = int(256 * ($x - $xtile));
  my $ypix = int(256 * ($y - $ytile));

  my $dist = @lastpoint ? abs($lastpoint[0] - $x) + abs($lastpoint[1] - $y) : 0;
  if( $filemode != 2 || !$lines || $dist <= 1 || $dist > $maxdist ) {
    my $vec = read_tile("$tile_folder/$zoom/$xtile/$ytile.bitile");
    $vec->Bit_On($ypix * 256 + $xpix);
  } else {
    draw_line("$tile_folder/$zoom", $lastpoint[0], $lastpoint[1], $x, $y);
  }
  @lastpoint = ($x, $y);
}
close CSV;
flush_tile();
unlink "$state_file$thread";
print STDERR "\n" if $verbose;

sub read_tile {
  my $filename = shift;
  return $cache[1] if $filename eq $cache[0];
  flush_tile();

  my $vec = Bit::Vector->new(65536);
  if( sysopen(BITILE, $filename, O_RDONLY | O_BINARY) ) {
    if( sysread(BITILE, my $read, 8192) == 8192 ) {
        $vec->Block_Store($read);
    }
    close BITILE;
  }
  $cache[0] = $filename;
  $cache[1] = $vec;
  $cache[2] = $vec->Norm();
  return $vec;
}

sub flush_tile {
  return if !$cache[0] || $cache[1]->Norm() == $cache[2];
  make_path(dirname($cache[0]));
  print STDERR "Error opening tile $cache[0]\n" unless sysopen(BITILE, $cache[0], O_RDWR | O_CREAT | O_BINARY);
  syswrite(BITILE, $cache[1]->Block_Read());
  close BITILE;
}

sub draw_line {
  # draw a line from @lastpoint (excluding it) to ($x, $y)
  # todo
  my ($base, $x0, $y0, $x, $y) = @_;
  my $xtile = int($x);
  my $ytile = int($y);
  my $xpix = int(256 * ($x - $xtile));
  my $ypix = int(256 * ($y - $ytile));
}

sub usage {
    my ($msg) = @_;
    print STDERR "$msg\n\n" if defined($msg);

    my $prog = basename($0);
    print STDERR << "EOF";
This script receives CSV file of "lat,lon" (or GPX) and makes a lot of bitiles.
A bitile is a 8k bit array, which can be converted to regular PNG tile
with bitiles2png.pl

usage: $prog [-h] [-v] [-i file] -o target -z zoom [-b bbox]

 -h        : print ths help message and exit.
 -i file   : CSV/GPX points file to process (default is STDIN).
 -o target : directory to store bitiles.
 -z zoom   : generated tiles zoom level.
 -b bbox   : limit points by bounding box (four comma-separated
             numbers: minlon,minlat,maxlon,maxlat).
 -t n,t    : process Nth part of T jobs.
 -l        : connect GPX trace points.
 -v        : print a dot every $notify_points points.

All coordinates in source CSV file should be multiplied by $factor
(you can change this number in the code).

EOF
    exit;
}
