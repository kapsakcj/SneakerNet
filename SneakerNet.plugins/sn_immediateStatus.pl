#!/usr/bin/env perl
# Performs an immediate check on whether a run is good to go

use strict;
use warnings;
use Getopt::Long;
use Data::Dumper;
use File::Basename qw/fileparse basename dirname/;
use File::Temp qw/tempdir/;
use File::Spec;

use FindBin;
use lib "$FindBin::RealBin/../lib/perl5";
use SneakerNet qw/recordProperties readConfig samplesheetInfo_tsv command logmsg fullPathToExec/;

use Text::Fuzzy;
use Email::Stuffer;

our $VERSION = "1.0";

local $0=fileparse $0;
exit(main());

sub main{
  my $settings=readConfig();
  GetOptions($settings,qw(version help force tempdir=s debug numcpus=i)) or die $!;
  if($$settings{version}){
    print $VERSION."\n";
    return 0;
  }

  die usage() if($$settings{help} || !@ARGV);
  $$settings{numcpus}||=1;
  $$settings{tempdir}||=File::Temp::tempdir(basename($0).".XXXXXX",TMPDIR=>1,CLEANUP=>1);
  logmsg "Temporary directory is at $$settings{tempdir}";

  my $dir=$ARGV[0];
  mkdir "$dir/SneakerNet";
  mkdir "$dir/SneakerNet/forEmail";

  my $errHash = doubleCheckRun($dir,$settings);

  my $outfile = "$dir/SneakerNet/forEmail/immediateReaction.tsv";
  open(my $fh, ">", $outfile) or die "ERROR: could not write to $outfile: $!";
  print $fh join("\t", qw(ErrType Sample ErrKeyword Error))."\n";
  for my $errType(sort keys(%$errHash)){
    for my $sample(sort keys(%{ $$errHash{$errType} })){
      for my $errKeyword(sort keys(%{ $$errHash{$errType}{$sample} })){
        print $fh join("\t",
          $errType, $sample, $errKeyword, 
          $$errHash{$errType}{$sample}{$errKeyword}
        );
        print $fh "\n";
      }
    }
  }
  close $fh;

  my @to = @{ $$settings{'default.emails'} };
  # append any snok.txt emails
  # Read the run's snok.txt for any emails
  if(-e "$dir/snok.txt"){
    my @email;
    my $snokCfg = new Config::Simple();
    eval{
      $snokCfg->read("$dir/snok.txt");
      @email = $snokCfg->param("emails");
      logmsg "Found emails in snok.txt: @email";
    };
    if($@){
      logmsg "WARNING: could not read snok.txt for any emails, but the file exists!";
    }
    push(@to, @email);
  }
  my $to = join(",",@to);
  logmsg "Sending an email to @to";

  my $from=$$settings{from} || die "ERROR: need to set 'from' in the settings.conf file!";
  my $subject="Initial SneakerNet status for ".basename(File::Spec->rel2abs($dir));
  my $body = "If you see errors below, please contact the bioinformatics team with your run number and when you deposited the run. Include this file in your message.\n";
  my $email=Email::Stuffer->from($from)
                          ->subject($subject)
                          ->to($to)
                          ->text_body($body)
                          ->attach_file($outfile);
  if(!$email->send){
    die "ERROR: email was not sent to $to!";
  }

  recordProperties($dir,{version=>$VERSION, reportTo=>$to});

  return 0;
}

sub doubleCheckRun{
  my($dir,$settings)=@_;

  my %errHash;

  if(!-e "$dir/samples.tsv"){
    $errHash{samplesSheetMissing} = 1;
  }

  my @fastq = sort glob("$dir/*.fastq.gz");
  my %fastqIndex;
  $fastqIndex{$_}=1 for(@fastq);

  logmsg "Reading sample tsv at $dir/samples.tsv";
  my $sampleInfo=samplesheetInfo_tsv("$dir/samples.tsv",$settings);
  my @sample = sort keys(%$sampleInfo);
  for my $sample(@sample){
    my $info = $$sampleInfo{$sample};

    if(!$$info{fastq} || !ref($$info{fastq})){
      $errHash{sample}{$sample}{fastqNotFound}=1;
    } elsif(@{ $$info{fastq} } < 1){
      $errHash{sample}{$sample}{fastqNotFound}=1;
    } elsif(@{ $$info{fastq} } < 2){
      print Dumper $$info{fastq};
      $errHash{sample}{$sample}{pairMissing}="Sample $sample has only a single read: ".join(" ",@{ $$info{fastq} });
    }

    if($errHash{sample}{$sample}{fastqNotFound}){
      my $tf = Text::Fuzzy->new($sample);
      my $nearest = $tf->nearestv(\@fastq);
      $errHash{sample}{$sample}{fastqNotFound} = "For sample $sample, the closest named fastq files are $nearest";
    }

  }

  # now see if there are fastq files that are not mentioned
  for my $filename(@fastq){
    next if($filename=~/Undetermined/i);
    my $basename = basename($filename);
    $basename =~ s/_.*//;
    if(!$$sampleInfo{$basename}){
      my $tf = Text::Fuzzy->new($filename);
      my $nearest = $tf->nearestv(\@sample);
      $errHash{fastq}{$filename}{sampleNotFound} = "Found fastq $filename but no entry in the sample sheet matching $basename.  Did you mean $nearest?";
    }
  }
  return \%errHash;
}


sub usage{
  "Double check a run and its completeness. Email a report.
  Usage: $0 MiSeq_run_dir
  --emails  ''   email1,[email2...]
  --version
  "
}
