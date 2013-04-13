#!/usr/bin/perl

# Generate a status image of existing tiles (in any format).
# Written by Ilya Zverev, licensed WTFPL.

use strict;
use GD;
use File::Basename;
use Getopt::Long;

my $source_dir;
my $dest;
my $zoom;
my $thread_str;
my $help;

GetOptions('h|help' => \$help,
           'i|input=s' => \$source_dir,
           'o|output=s' => \$dest,
           'z|zoom=i' => \$zoom,
           't|threads=s' => \$thread_str,
           ) || usage();

if( $help ) {
    usage();
}

usage("Please specify input directory with -i") unless defined($source_dir);
die "Source directory not found" unless -d $source_dir;
usage("Please specify target image name with -o") unless defined($dest);

$zoom = find_zoom($source_dir) unless defined($zoom);
my $size = 2**$zoom;

my $bxmin = $size + 1;
my $bxmax;
my $width;
if( defined($thread_str) ) {
    die 'Threads string should contain three numbers: minlon, maxlon, thread count.' unless $thread_str =~ /^(-?[\d.]+),(-?[\d.]+),(\d{1,2})$/;
    my ($minlon, $maxlon, $threads) = ($1, $2, $3);

    my $eps = 10**-8;
    $bxmin = int(($minlon+$eps+180)/360 * $size);
    $bxmax = int(($maxlon-$eps+180)/360 * $size);
    my $bxwidth = $bxmax - $bxmin + 1;
    die("Total number of threads is higher than horizontal number of tiles") if $threads > $bxwidth;
    $width = int(($bxwidth + $threads - 1) / $threads);
}

my $img = GD::Image->new($size, $size);
my $black = $img->colorAllocate(0, 0, 0);
my $white = $img->colorAllocate(255, 255, 255);
my $gray = $img->colorAllocate(224, 224, 224);

for my $x (0 .. $size) {
    my %ys = {};
    if( opendir(my $dh, "$source_dir/$zoom/$x") ) {
        %ys = map { if( /^(\d+)\./ ) { $1 => 1 } } readdir($dh);
        closedir($dh);
    }
    for my $y (0 .. $size) {
        if( exists $ys{$y} ) {
            $img->setPixel($x, $y, $black)
        } else {
            $img->setPixel($x, $y, $x < $bxmin ? $white : $x > $bxmax ? (int($bxmax / $width)%2 ? $gray : $white) : int(($x - $bxmin) / $width)%2 ? $white : $gray);
        }
    }
}

open PIC, ">$dest";
binmode PIC;
print PIC $img->png();
close PIC;

sub find_zoom {
    my $dir = shift;
    my $dh;
    opendir($dh, $dir) or die "Cannot open $dir";
    my @zlist = sort grep { /^\d+$/ && -d "$dir/$_" } readdir($dh);
    closedir($dh);
    die "No tiles found in $dir" if $#zlist < 0;
    return $zlist[-1];
}

sub usage {
    my ($msg) = @_;
    print STDERR "$msg\n\n" if defined($msg);

    my $prog = basename($0);
    print STDERR << "EOF";
Generate a PNG image with all existing tiles drawn as dots.

usage: $prog [-h] -i source -o target [-z zoom] [-t minlon,maxlon,threads]

 -h        : print ths help message and exit.
 -i source : directory with tiles.
 -o target : output file name.
 -z zoom   : tiles zoom level (detected automatically).
 -t minlon,laxlon,threads : bounds and number of threads in bitiles generation.

EOF
    exit;
}
