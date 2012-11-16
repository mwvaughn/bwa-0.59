#!/usr/bin/perl

use Getopt::Std;
use IO::File;

my %opts = ();
getopts ('f:o:n:', \%opts);
my $fasta  = $opts{'f'};
my $outdir = $opts{'o'} || '.';
my $number = $opts{'n'} || 100;

print STDERR "splitfastq -f $fasta -o $outdir -n $number\n";

# Pre-read the first line of the FASTQ and use what we find there as the limiter
# Assume the first line is a sequence record
open (FQ1, $fasta) or die;
my $first_line = <FQ1>;
my $delim_guessed = substr($first_line, 0, 2);
close FQ1;
print STDERR "$delim_guessed is the record separator for $fasta\n";

# Pre-allocate the filehandles
my @filehandles;
for (my $i=1; $i<=$number; $i++) {
	
	my $fh = new IO::File "> $outdir/query.$i";
    push(@filehandles, $fh);

}

# Redfine the record separator to $delim_guessed for reading FASTQ file
# This is 20x faster than Bio::SeqIO, though probably less
# fault-tolerant. However, FASTQ that come from
# automated sources like sequencers are all very clean
# and standards-compliant. I forsee no problem, and if there
# is, its better to make a transformation on the 
# source file than in this code.

my $old_input_rec_sep = $/;
$/ = $delim_guessed;

open (FASTQ, $fasta) or die;
my $iterator = 0;

while (my $rec = <FASTQ>) {
	
	unless ($rec =~ /^$delim_guessed$/) {
		chomp($rec);
		
		my $seqout = $delim_guessed . $rec;
		$filehandles[$iterator]->print( $seqout );

		$iterator++;
		if ($iterator >= $number) { $iterator = 0 }
	
	}

}

$/ = $old_input_rec_sep;

print STDERR "splitfastq DONE\n";

