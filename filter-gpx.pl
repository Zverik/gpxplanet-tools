#!/usr/bin/perl

# This script filters gpx tar archive by a set of polygons.
# Written by Ilya Zverev, licensed under WTFPL.
# Poly reading sub is from extract_polygon.pl by Frederik Ramm.

use strict;
use Math::Polygon::Tree;
use Getopt::Long;
use File::Basename;
use File::Path 2.07 qw(make_path);
use IO::Compress::Gzip;
use IO::File;
use Archive::Tar;

my $help;
my $verbose;
my $target;
my $suffix = '';
my $polylist;
my $polyfile;
my $bbox;
my $zip;
my $min_points = 10;

GetOptions('h|help' => \$help,
           'v|verbose' => \$verbose,
           'o|target=s' => \$target,
           's|suffix=s' => \$suffix,
           'l|list=s' => \$polylist,
           'p|polyfile=s' => \$polyfile,
           'b|bbox=s' => \$bbox,
           'z|gzip' => \$zip,
           ) || usage();

if( $help ) {
  usage();
}

my $minlon = 999;
my $minlat = 999;
my $maxlat = -999;
my $maxlon = -999;
my $bboxset = 0;
my @polygons = ();

if( $bbox ) {
    # simply set minlat, maxlat etc from bbox parameter - no polygons
    ($minlon, $minlat, $maxlon, $maxlat) = split(",", $bbox);
    die ("badly formed bounding box - use four comma-separated values for left longitude, ".
        "bottom latitude, right longitude, top latitude") unless defined($maxlat);
    die ("max longitude is less than min longitude") if ($maxlon < $minlon);
    die ("max latitude is less than min latitude") if ($maxlat < $minlat);
    $bboxset = 1;
}

if( $polylist ) {
    open LIST, "<$polylist" or die "Cannot open $polylist: $!";
    $target = '.' if !$target;
    make_path($target);
    while(<LIST>) {
        chomp;
        add_polygon_file($_, 1);
    }
    close LIST;
} elsif( $polyfile ) {
    add_polygon_file($polyfile, 0);
} elsif( $bbox ) {
    printf STDERR "bbox -> %s\n", $target || 'STDOUT' if $verbose;
    push_poly($target, poly_from_bbox());
} else {
    usage("Please specify either bbox, polygon file or a list of them.");
}

my $tariter = Archive::Tar->iter(IO::File->new_from_fd(*STDIN, '<'));
my $metadata_name = 'metadata.xml';
my $metadata_header = '';
my %metadata;
my @keysmetadata;
while(my $f = $tariter->()) {
    my $cref = $f->get_content_by_ref;
    my $name = $f->full_path;
    if( $name =~ /metadata\.xml$/ ) {
        $metadata_name = $name;
        $metadata_header = $1 if $$cref =~ /^(.+?)(?=\<gpxFile )/s;
        # this parses metadata.xml into a hash { filename => xml <gpxFile> fragment }
        %metadata = map { /filename="([^"]+\.gpx)"/ ? ($1 => $_) : () } $$cref =~ /\<gpxFile .+?\<\/gpxFile\>\s+/gs;
        @keysmetadata = keys %metadata;
    } elsif( $name =~ /\.gpx$/ ) {
        my @check_polygons = @polygons;
        my @poly_cnt = ($min_points) x scalar(@check_polygons);
        # find relevant metadata entry (NB: filenames in tar and metadata are different)
        my $metadata_fragment = '';
        foreach (@keysmetadata) {
            if( index($name, $_) != -1 ) {
                $metadata_fragment = $metadata{$_};
                last;
            }
        }
        for( split /\n/, $$cref ) {
            next if !/\<trkpt.+?l(at|on)=['"](-?\d+(?:\.\d+)?)['"]\s+l(?:at|on)=['"](-?\d+(?:\.\d+)?)['"]/;
            my $lat = $1 eq 'at' ? $2 : $3;
            my $lon = $1 eq 'at' ? $3 : $2;
            next if $lat < $minlat || $lat > $maxlat || $lon < $minlon || $lon > $maxlon;
            for( my $pid = $#check_polygons; $pid >= 0; $pid-- ) {
                my $poly = $check_polygons[$pid];
                if( is_in_poly($poly->[1], $lat, $lon) && --$poly_cnt[$pid] <= 0 ) {
                    # append GPX file to the resulting tar archive
                    my $arch = Archive::Tar->new;
                    push @{$arch->{_data}}, $f; # dirty hack from Archive::Tar source
                    my $tardata = $arch->write;
                    $poly->[0]->syswrite($tardata, length($tardata) - (Archive::Tar::Constant::BLOCK * 2));
                    $arch->clear();
                    # append metadata fragment to a resulting metadata.xml
                    $poly->[2] .= $metadata_fragment;
                    # remove polygon from array
                    splice @check_polygons, $pid, 1;
                    splice @poly_cnt, $pid, 1;
                }
            }
        }
    }
}

for (@polygons) {
    # finalize GPX traces tar archive
    $_->[0]->syswrite(Archive::Tar::Constant::TAR_END x 2);
    close $_->[0];
    # write metadata.xml.tar header (not a proper tar file, intended for concatenation)
    if( $_->[2] && $_->[3] && open my $fh, '>', $_->[3] ) {
        my $arch = Archive::Tar->new;
        $arch->add_data($metadata_name, $metadata_header.$_->[2]."</gpxFiles>\n");
        my $tardata = $arch->write;
        $arch->clear();
        syswrite $fh, $tardata, length($tardata) - (Archive::Tar::Constant::BLOCK * 2);
        close $fh;
    }
}

sub add_polygon_file {
    my ($p, $multi) = @_;
    my $filename = $multi ? ($target ? $target.'/'.basename($p) : basename($p)) : $target;
    $filename =~ s/\.poly$/$suffix\.tar/;
    $filename .= '.gz' if $zip && $filename !~ /\.gz$/;
    print STDERR "$p -> $filename\n" if $verbose;
    my $bp = read_poly($p);
    push_poly($target ? $filename : '-', $bp);
}

sub push_poly {
    my ($filename, $poly) = @_;
    my $fh = $filename && $filename ne '-'
        ? ($zip ? new IO::Compress::Gzip $filename : IO::File->new($filename, 'w'))
        : IO::File->new_from_fd(*STDOUT, '>');
    die "Cannot open file: $!" if !$fh;
    my $metaname = $filename && $filename =~ /^(.+)\.tar(?:\.gz)?$/ ? "$1.metadata.tarc" : 'metadata.tarc';
    # file handle, polygon, metadata.xml contents, metadata.xml archive filename
    push @polygons, [$fh, $poly, '', $metaname];
}

sub is_in_poly {
    my ($borderpolys, $lat, $lon) = @_;
    my $ll = [$lat, $lon];
    my $rv = 0;
    foreach my $p (@{$borderpolys})
    {
        my($poly,$invert,$bbox) = @$p;
        next if ($ll->[0] < $bbox->[0]) or ($ll->[0] > $bbox->[2]);
        next if ($ll->[1] < $bbox->[1]) or ($ll->[1] > $bbox->[3]);

        if ($poly->contains($ll))
        {
            # If this polygon is for exclusion, we immediately bail and go for the next point
            if($invert)
            {
                return 0;
            }
            $rv = 1; 
            # do not exit here as an exclusion poly may still be there 
        }
    }
    return $rv;
}

sub read_poly {
    my $polyfile = shift;
    my $borderpolys = [];
    my $currentpoints;
    open (PF, "<$polyfile") || die "Could not open $polyfile: $!";

    my $invert;
    # initialize border polygon.
    while(<PF>)
    {
        if (/^(!?)\d/)
        {
            $invert = ($1 eq "!") ? 1 : 0;
            $currentpoints = [];
        }
        elsif (/^END/)
        {
            if( $#{$currentpoints} > 0 ) {
                # close polygon if it isn't
                push(@{$currentpoints}, [$currentpoints->[0][0], $currentpoints->[0][1]])
                    if $currentpoints->[0][0] != $currentpoints->[-1][0]
                    || $currentpoints->[0][1] != $currentpoints->[-1][1];
                my $pol = Math::Polygon::Tree->new($currentpoints);
                push(@{$borderpolys}, [$pol,$invert,[$pol->bbox]]);
                printf STDERR "Added polygon: %d points (%d,%d)-(%d,%d) %s\n",
                    scalar(@{$currentpoints}), @{$borderpolys->[-1][2]},
                    ($borderpolys->[-1][1] ? "exclude" : "include") if $verbose;
            }
            undef $currentpoints;
        }
        elsif (defined($currentpoints))
        {
            /^\s+([0-9.E+-]+)\s+([0-9.E+-]+)/ or die "Incorrent line in poly: $_";
            push(@{$currentpoints}, [$2, $1]);
            if( !$bboxset ) {
                $minlat = $2 if ($2 < $minlat);
                $maxlat = $2 if ($2 > $maxlat);
                $minlon = $1 if ($1 < $minlon);
                $maxlon = $1 if ($1 > $maxlon);
            }
        }
    }
    close (PF);
    return $borderpolys;
}

sub poly_from_bbox {
    my @b = ($minlat, $minlon, $maxlat, $maxlon);
    my $currentpoints = [[$b[0], $b[1]], [$b[0], $b[3]], [$b[2], $b[3]], [$b[2], $b[1]], [$b[0], $b[1]]];
    my $pol = Math::Polygon::Tree->new($currentpoints);
    my $bp = [];
    push(@{$bp}, [$pol,0,[$pol->bbox]]);
    return $bp;
}

sub usage {
    my ($msg) = @_;
    print STDERR "$msg\n\n" if defined($msg);

    my $prog = basename($0);
    print STDERR << "EOF";
This script receives a tar archive of GPX files (from STDIN)
and filters it by a bounding box, an osmosis' polygon filter file
or a number of them.

usage: $prog [-h] [-o target] [-z] [-b bbox] [ -p poly | -l list [-s suffix] ]

 -h        : print ths help message and exit.
 -o target : a file or a directory to put resulting files.
 -z        : compress output files with gzip.
 -b bbox   : limit points by bounding box (four comma-separated
             numbers: minlon,minlat,maxlon,maxlat).
 -p poly   : a polygon filter file.
 -l list   : file with names of poly files.
 -s suffix : a suffix to add to all output files.
 -v        : print debug messages.

Resulting files will have .metadata.tarc counterparts if input
file had metadata.xml file. Those should be concatenated with
their respective tar files, so they are first in resulting archives.

Please keep the number of polygons below 100, or unexpected problems
may occur.

EOF
    exit;
}
