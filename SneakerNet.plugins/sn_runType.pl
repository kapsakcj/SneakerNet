#!/usr/bin/env perl
# Figure out what kind of run this is

use strict;
use warnings;
use Getopt::Long;
use Data::Dumper;
use File::Basename qw/fileparse basename dirname/;
use File::Temp qw/tempdir/;
use File::Copy qw/mv cp/;

use threads;
use Thread::Queue;

use FindBin;
use lib "$FindBin::RealBin/../lib/perl5";
use SneakerNet qw/readConfig samplesheetInfo command logmsg fullPathToExec/;

local $0=fileparse $0;
exit(main());

sub main{
  my $settings=readConfig();
  GetOptions($settings,qw(help force tempdir=s debug numcpus=i)) or die $!;
  die usage() if($$settings{help} || !@ARGV);
  $$settings{numcpus}||=1;
  $$settings{tempdir}||=File::Temp::tempdir(basename($0).".XXXXXX",TMPDIR=>1,CLEANUP=>1);
  logmsg "Temporary directory is at $$settings{tempdir}";

  my $dir=$ARGV[0];

  my $dirInfo = parseReadsDir($dir,$settings);

  if(!$$dirInfo{runType}){
    system("mv -v $dir $$settings{inbox}/rejected");
    logmsg "ERROR: could not determine the run type of $dir. Additional info to complete the run for any particular chemistry:\n$$dirInfo{why_not}";

    # TODO send email using snok.txt?

    return 1;
  }
  
  return 0;
}

# Figure out if this really is a reads directory
sub parseReadsDir{
  my($dir,$settings)=@_;

  my %dirInfo=(dir=>$dir,is_good=>1,why_not=>"", runType=>"");

  my $b=basename $dir;
  ($dirInfo{machine},$dirInfo{year},$dirInfo{run},$dirInfo{comment})=split(/\-/,$b);

  # If the run name isn't even there, then it's not a run directory
  if(!defined($dirInfo{run})){
    $dirInfo{why_not}.="Run name is not defined for $dir. Run name syntax should be Machine-year-runNumber-comment.\n";
    $dirInfo{is_good}=0;
    return \%dirInfo;
  }

  # Test for Illumina at the same time as seeing if all the files are in there
  if(!$dirInfo{is_good} || !$dirInfo{runType}){

    my $foundAllFiles=1;

    # See if there are actually reads in the directory
    if(!glob("$dir/*.fastq.gz")){
      $dirInfo{why_not}.= "[Illumina] Could not find fastq.gz files in $dir\n";
      $foundAllFiles=0;
    }

    # How do we tell it is a miniseq run?  My best guess
    # is if we see "SampleSheetUsed.csv" instead of
    # "SampleSheet.csv."
    if(-e "$dir/SampleSheetUsed.csv"){
      logmsg "Detected $dir/SampleSheetUsed.csv: it could be a miniseq run.";
      # cp the sample sheet to SampleSheet.csv to make it compatible.
      cp("$dir/SampleSheetUsed.csv","$dir/SampleSheet.csv");
      cp("$dir/QC/RunParameters.xml","$dir/QC/runParameters.xml");

      # edit the sample sheet to remove the run
      removeRunNumberFromSamples("$dir/SampleSheet.csv", $settings);
      
      # Make empty files for compatibility
      for("$dir/config.xml"){
        open(EMPTYFILE,">>", $_) or die "ERROR: could not make an empty file $_: $!";
        close EMPTYFILE;
      }
    }

    # See if the misc. files are in there too
    for(qw(config.xml SampleSheet.csv QC/CompletedJobInfo.xml QC/InterOp QC/runParameters.xml QC/GenerateFASTQRunStatistics.xml QC/RunInfo.xml)){
      if(!-e "$dir/$_"){
        $dirInfo{why_not}.="[Illumina] Could not find $dir/$_\n";
        $foundAllFiles=0;
      }
    }
    
    $dirInfo{runType}="Illumina" if($foundAllFiles);
  }

  # Test for Ion Torrent at the same time as seeing if all the files are in there
  if(!$dirInfo{is_good} || !$dirInfo{runType}){

    my $foundAllFiles=1;
    
    # See if there are reads in the directory
    my @fastq=(glob("$dir/plugin_out/downloads/*.fastq"),glob("$dir/plugin_out/downloads/*.fastq.gz"));
    if(!@fastq){
      $dirInfo{why_not}.= "[IonTorrent] Could not find fastq[.gz] files in $dir/plugin_out/downloads\n";
      $foundAllFiles=0;
    }
    
    $dirInfo{runType}="IonTorrent" if($foundAllFiles);
  }



  return \%dirInfo;
}

# Edit a sample sheet in-place to remove a run identifier
# from the sample names. For some reason the Miniseq
# appends a four digit number, e.g. "-6006" to the end
# of each sample name.
sub removeRunNumberFromSamples{
  my($samplesheet,$settings)=@_;

  my $newSamplesheetString="";
  open(SAMPLESHEET,"<", $samplesheet) or die "ERROR: could not read $samplesheet: $!";
  my $reachedSamples=0;
  my $runid="";
  while(<SAMPLESHEET>){
    # Make a note of the run ID when I see it
    if(/Local Run Manager Analysis Id,\s*(\d+)/){
      $runid=$1;
    }

    if(!$reachedSamples){
      $newSamplesheetString.=$_;
      if(/Sample_ID,/){
        $reachedSamples=1;
      }
    }
    # Read the samples and remove the run ID
    else {
      my($samplename,@therest)=split(/,/,$_);
      $samplename=~s/\-$runid$//;
      $newSamplesheetString.=join(",",$samplename,@therest);
    }
  }
  close SAMPLESHEET;

  # Now rewrite the sample sheet
  open(SAMPLESHEET,">", $samplesheet) or die "ERROR: could not write to $samplesheet: $!";
  print SAMPLESHEET $newSamplesheetString;
  close SAMPLESHEET;

  return 1;
} 


sub usage{
  "Figure out the type of run directory. Exit code > 0 if
  the run is invalid.

  Usage: $0 dir/
  "
}

