#!/usr/bin/env perl
# Moves folders from the dropbox-inbox pertaining to reads, and
# Runs read metrics on the directory

use strict;
use warnings;
use Getopt::Long;
use Data::Dumper;
use File::Copy;
use File::Basename qw/fileparse basename dirname/;
use File::Temp qw/tempdir/;
use FindBin;

use lib "$FindBin::RealBin/../lib/perl5";
use SneakerNet qw/readConfig command logmsg/;

$ENV{PATH}="$ENV{PATH}:/opt/cg_pipeline/scripts";

local $0=fileparse $0;

exit(main());

sub main{
  my $settings={};
  GetOptions($settings,qw(help createsamplesheet tempdir=s numcpus=i outdir=s)) or die $!;
  $$settings{tempdir}||=tempdir("$0.XXXXXX",TMPDIR=>1,CLEANUP=>1);
  mkdir($$settings{tempdir}) if(!-e $$settings{tempdir});
  $$settings{numcpus}||=1;
  $$settings{outdir}||="sneakernet.out";

  die usage() if($$settings{help} || !@ARGV);

  for my $dir(@ARGV){
    my $sneakernetDir = makeSneakernetDir($dir,$settings);
    saveSneakernetDir($sneakernetDir, $$settings{outdir});
  }

  return 0;
}

sub makeSneakernetDir{
  my($dir,$settings)=@_;

  my $outdir="$$settings{tempdir}/runData";
  mkdir $outdir;

  my @fastq       = glob("$dir/Data/Intensities/BaseCalls/*.fastq.gz");
  my $snok        = "$dir/snok.txt";
  my $sampleSheet = "$dir/Data/Intensities/BaseCalls/SampleSheet.csv";
  my $sampleSheet2= "$dir/SampleSheet.csv"; # backup in case the first is not found
  my $config      =  "$dir/Data/Intensities/BaseCalls/config.xml";
  my @interop     =  glob("$dir/InterOp/*");
  my @xml         = ("$dir/CompletedJobInfo.xml",
                     "$dir/runParameters.xml",
                     "$dir/GenerateFASTQRunStatistics.xml",
                     "$dir/RunInfo.xml",
                    );
  
  if(! -e $sampleSheet){
    if(! -e $sampleSheet2){
      if($$settings{createsamplesheet}){
        # do nothing
      } else {
        die "ERROR: could not find the samplesheet in either $sampleSheet or $sampleSheet2";
      }
    }
    $sampleSheet = $sampleSheet2;
  }
  if(!@interop){
    @interop  = glob("$dir/QC/InterOp/*");
    if(!@interop){
      logmsg "ERROR: no interop files were found in $dir";
    }
  }
  #for(@fastq, $config, @interop, @xml){
  #  if(!-e $_){
  #    die "ERROR: file does not exist: $_";
  #  }
  #}

  if($$settings{createsamplesheet}){
    $sampleSheet = createSampleSheet($dir, $outdir, $settings);
  }

  if(-e $snok){
    cp($snok,"$outdir/".basename($snok));
  } else {
    logmsg "snok.txt not found. I will not read from it.";
    # "touch" the snok file
    open(my $fh, ">>", "$outdir/".basename($snok)) or die "ERROR: could not touch $outdir/".basename($snok).": $!";
    close $fh;
  }
  if(!@fastq){
    # If there aren't any fastq files, try to see if they're in the main dir
    @fastq = glob("$dir/*.fastq.gz $dir/*/*.fastq.gz");
    if(!@fastq){
      logmsg "WARNING: no fastq files were found; attempting bcl2fastq";
      @fastq=bcl2fastq($dir,$settings);
      if(!@fastq){
        die "ERROR: could not find any fastq files in $dir";
      }
    }
  }

  for(@fastq, $sampleSheet, $config){
    my $to="$outdir/".basename($_);
    cp($_, $to);
  }
  mkdir "$outdir/QC";
  for(@xml){
    my $to="$outdir/QC/".basename($_);
    cp($_, $to);
  }
  mkdir "$outdir/QC/InterOp";
  for(@interop){
    my $to="$outdir/QC/InterOp/".basename($_);
    cp($_, $to);
  }

  return $outdir;
}

sub bcl2fastq{
  my($dir,$settings)=@_;
  my $fastqdir="$$settings{tempdir}/bcl2fastq";
  mkdir($fastqdir);

  #command("bcl2fastq --input-dir $dir/Data/Intensities/BaseCalls --runfolder-dir $dir --output-dir $fastqdir --processing-threads $$settings{numcpus} --demultiplexing-threads $$settings{numcpus} --barcode-mismatches 1 >&2");
  command("bcl2fastq --input-dir $dir/Data/Intensities/BaseCalls --runfolder-dir $dir --output-dir $fastqdir --processing-threads $$settings{numcpus} --barcode-mismatches 1 --ignore-missing-bcls >&2");

  my @fastq=glob("$$settings{tempdir}/bcl2fastq/*.fastq.gz");
  return @fastq;
}

sub saveSneakernetDir{
  my($tmpdir,$outdir,$settings)=@_;
  system("mv -v $tmpdir $outdir 1>&2");
  die if $?;
  #File::Copy::mv($tmpdir,$outdir) or die "ERROR: could not move $tmpdir to $outdir: $!";
  return 1;
}

sub cp{
  my($from,$to)=@_;
  if(-e $to && -s $to > 0){
    logmsg "Found $to. Not copying";
    return 1;
  }
  logmsg "cp $from to $to";
  my $return = link($from, $to) ||
    File::Copy::cp($from,$to) or warn "ERROR: could not copy $from to $to: $!";
  open(my $fh, ">>", $to) or die "ERROR: could not write to $to: $!";
  close $fh;
  return $return;
}

sub createSampleSheet{
  my($dir, $outdir, $settings) = @_;

  my $samplesheet = "$outdir/SampleSheet.csv";
  if(-e $samplesheet){
    die "ERROR: was going to create a samplesheet but it already exists at $samplesheet";
  }
  open(my $fh, ">", $samplesheet) or die "ERROR: could not write to $samplesheet: $!";
  print $fh "[Data]\n";
  for my $demuxSamples(glob("$dir/*_*.csv")){ # should just be one file
    open(my $demuxFh, "<", $demuxSamples) or die "ERROR: could not read from $demuxSamples: $!";
    my $found_the_samples = 0;
    while(<$demuxFh>){
      if(/,Sample,/){
        s/,Sample,/,SampleID,/;
      }
      if(/Flowcell/){
        next;
      }
      if(/^,+$/){
        next;
      }
      if(/^\s*$/){
        next;
      }
      print $fh $_;
    }
    close $demuxFh;
  }
  close $fh;

  return $samplesheet;
}



sub usage{
  "Parses an unaltered Illumina run and formats it
  into something usable for SneakerNet

  Usage: $0 illuminaDirectory [illuminaDirectory2...]
  
  --numcpus  1
  --outdir   ''
  --createsamplesheet
  "
}
