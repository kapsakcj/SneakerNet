#!/usr/bin/env perl
# Moves folders from the dropbox-inbox pertaining to reads, and
# Runs read metrics on the directory

use strict;
use warnings;
use Getopt::Long;
use Data::Dumper;
use File::Basename qw/fileparse basename dirname/;
use File::Temp;
use FindBin;

use lib "$FindBin::RealBin/../lib";
use SneakerNet qw/readConfig samplesheetInfo command logmsg/;

$ENV{PATH}="$ENV{PATH}:/opt/cg_pipeline/scripts";

local $0=fileparse $0;
exit(main());

sub main{
  my $settings=readConfig();
  GetOptions($settings,qw(help inbox=s debug)) or die $!;
  die usage() if($$settings{help} || !@ARGV);

  my $dir=$ARGV[0];

  transferFilesToRemoteComputers($dir,$settings);

  return 0;
}

sub transferFilesToRemoteComputers{
  my($dir,$settings)=@_;
  
  # Find information about each genome
  my $sampleInfo=samplesheetInfo("$dir/SampleSheet.csv",$settings);

  # Which files should be transferred?
  my %filesToTransfer=(); # hash keys are species names
  while(my($sampleName,$s)=each(%$sampleInfo)){
    next if(ref($s) ne 'HASH'); # avoid file=>name aliases
    my $taxon=$$s{species};
    if(grep {/calcengine/i} @{ $$s{route} }){
      $filesToTransfer{$taxon}.=join(" ",@{ $$s{fastq} })." ";
    }
  }

  #die "ERROR: no files to transfer" if (!$filesToTransfer);
  logmsg "WARNING: no files will be transferred" if(!keys(%filesToTransfer));

  # Make the transfers based on taxon.
  # TODO consider putting this taxon logic into a config file.
  while(my($taxon,$fileString)=each(%filesToTransfer)){

    # Which folder under /scicomp/groups/OID/NCEZID/DFWED/EDLB/share/out/Calculation_Engine
    # is appropriate?  SneakerNet if nothing else is found.
    my $subfolder="SneakerNet";
    if($taxon =~ /Listeria|^L\.$/i){
      $subfolder="LMO";
    } elsif ($taxon =~ /Salmonella/i){
      $subfolder="Salm";
    } elsif ($taxon =~ /Campy|Arcobacter|Helicobacter/i){
      $subfolder="Campy";
    } elsif ($taxon =~ /^E\.$|STEC|Escherichia|Shigella/i){
      $subfolder="STEC";
    } elsif ($taxon =~ /Vibrio|cholerae|cholera/i){
      $subfolder="Vibrio";
    } else {
      logmsg "WARNING: cannot figure out the correct subfolder for taxon $taxon. The following files will be sent to $subfolder instead.";
    }
    logmsg "Transferring to $subfolder:\n  $fileString";
    command("rsync --update -av $fileString edlb-sneakernet\@biolinux.biotech.cdc.gov:/scicomp/groups/OID/NCEZID/DFWED/EDLB/share/out/Calculation_Engine/$subfolder/");
  }
}


sub usage{
  "Find all reads directories under the inbox
  Usage: $0 [-i inboxDir/]
  -i dir  # choose a different 'inbox' to look at
  --test  # Create a test directory 
  --debug # Show debugging information
  --force # Get this show on the road!!
  "
}
