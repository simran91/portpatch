#!/usr/bin/perl

##################################################################################################################
# 
# File         : portpatch.pl
# Description  : Patches ports back from external networks to internal networks
# Original Date: ~1998
# Author       : simran@dn.gs
#
##################################################################################################################

use strict;
use POSIX;
use FileHandle;
use IO::Socket;
use IPC::Open2;
use Getopt::Long;

#
# define the global constants
#
use constant BUFFER_SIZE => 1024;

#
# define some variables
#
$| 	       = 1;
$SIG{CHLD} = \&REAPER;


##################################################################################################################
#
# main program
#

#
# predeclare some subroutines... 
#
sub spawn;

#
#
#
my $help      = 0;
my $verbose   = 0;
my $nofork    = 0;
my $listen    = 0;
my @hostports = ();

my $result = GetOptions(
                        "help+"    => \$help,
                        "verbose+" => \$verbose,
                        "nofork+"  => \$nofork,
                        "listen+"  => \$listen,
                        "port=s"   => \@hostports
);


#
#
#
if ($help || ! $result) {
    &usage();
}
elsif ((scalar @hostports) != 2) {
    &usage("Please specify exactly two --port arguments");
}

#
#
#
my ($host1, $port1) = split(/:/, $hostports[0], 2);
my ($host2, $port2) = split(/:/, $hostports[1], 2);

if (! $host1 || ! $port1 || $port1 !~ /^\d+$/) {
  &usage("Invalid host or port $host1:$port1");
}
if (! $host2 || ! $port2 || $port2 !~ /^\d+$/) {
  &usage("Invalid host or port $host2:$port2");
}

#
# start the appropriate server
#
if ($verbose || $nofork) {             &patchPorts($host1, $port1, $host2, $port2);    }
else 	                 { spawn sub { &patchPorts($host1, $port1, $host2, $port2); }; }

#
# end of 'main' part!
#
##################################################################################################################

##################################################################################################################
#
# Subroutine : patchPorts - patches two ports together... 
#
#
sub patchPorts {
    while (1) {
        my ($host1, $port1, $host2, $port2) = @_;

        #
        #
        my $peerA = undef;
        my $peerB = undef;

        my $peerAbusy = 0;
        my $peerBbusy = 0;

        #
        #
        #
        if ($listen) {
            print "staring up listening socket on $host1:$port1\n" if ($verbose);
            my $peerA_socket = new IO::Socket::INET(
                                    Listen    => 1,
                                    LocalHost => $host1,
                                    LocalPort => $port1,
                                    ReuseAddr => 1,
            ) || die "can't create listening socket on $host1:$port1 - $!\n";

            print "staring up listening socket on $host2:$port2\n" if ($verbose);
            my $peerB_socket = new IO::Socket::INET(
                                    Listen    => 1,
                                    LocalHost => $host2,
                                    LocalPort => $port2,
                                    ReuseAddr => 1,
            ) || die "can't create listening socket on $host2:$port2 - $!\n";

            #
            #
            #
            $peerA        = $peerA_socket->accept;
            $peerAbusy    = 1;
            my $peerAhost = gethostbyaddr($peerA->peeraddr, AF_INET) || $peerA->peerhost;
            my $peerAport = $peerA->peerport;
            print "received a connection from $peerAhost:$peerAport\n" if ($verbose);

            #
            #
            #
            $peerB        = $peerB_socket->accept;
            $peerBbusy    = 1;
            my $peerBhost = gethostbyaddr($peerB->peeraddr, AF_INET) || $peerA->peerhost;
            my $peerBport = $peerB->peerport;
            print "received a connection from $peerBhost:$peerBport\n" if ($verbose);
        }
        else {
            print "connecting to $host1:$port1\n" if ($verbose);
            $peerA = new IO::Socket::INET(
                                      PeerAddr => $host1,
                                      PeerPort => $port1,
                                      Type     => SOCK_STREAM,
                                      Proto    => 'tcp',
            ) || die "can't connect to $host1:$port1 - $!";
          
            print "connecting to $host2:$port2\n" if ($verbose);
            $peerB = new IO::Socket::INET(
                                      PeerAddr => $host2,
                                      PeerPort => $port2,
                                      Type     => SOCK_STREAM,
                                      Proto    => 'tcp',
            ) || die "can't connect to $host2:$port2 - $!";
        }

        #
        # patch the ports together... 
        #
        &handleSocketPeers($peerA, $peerB);
    }
}
#
#
#
##################################################################################################################

##################################################################################################################
#
# Subroutine : handleSocketPeers - passes data back and forth between peerA and peerB (both of which 
#                                  will be sockets)
#
#      Input : $peerA - the client who initially requested the redirect/connected
#              $peerB - the socket we are redirecting to... 
#      Return: none
#
sub handleSocketPeers {
  my ($peerA, $peerB) = @_;

  #
  # setup some variables so that we can interrupt/see changes in data from filehandles...
  #
  my $rin  = undef;
  my $rout = undef;

  vec($rin, fileno($peerA),1) = 1;
  vec($rin, fileno($peerB),1) = 1;

  #
  # start the exchanging of data between the peers
  #
  while ( 1 ) {
    my $data = undef;
    if (! select($rout=$rin, undef, undef, undef)) { die "select: $!"; }

    if (vec($rout, fileno($peerA),1)) {
       $peerA->recv($data, BUFFER_SIZE, 0);
       print "[".scalar localtime()."] $host1:$port1->$host2:$port2: $data\n" if ($verbose >= 2);
       $peerB->send($data, 0) || last;
    }
    elsif (vec($rout, fileno($peerB),1)) {
       $peerB->recv($data, BUFFER_SIZE, 0);
       print "[".scalar localtime()."] $host2:$port2->$host1:$port1: $data\n" if ($verbose >= 2);
       $peerA->send($data, 0) || last;
    }
  }

  $peerA->shutdown(2);
  $peerB->shutdown(2);
}
#
#
#
##################################################################################################################

##################################################################################################################
#
# Subroutine : spawn - forks code
#
#      Input :
#              $coderef - reference to code you want to 'spawn'
#
sub spawn {
  my $coderef = shift;
  unless (@_ == 0 && $coderef && ref($coderef) eq 'CODE') {
    die "usage: spawn CODEREF";
  }
  my $pid;
  if (!defined($pid = fork)) {
    print STDERR "cannot fork: $!\n";
    return;
  }
  elsif ($pid) {
    # print "begat $pid\n";
    return; # i'm the parent
  }
  # else i'm the child -- go spawn

  exit &$coderef();
}
#
#
#
##################################################################################################################

##################################################################################################################
#
# Subroutine : REAPER - reaps zombie processes
#
sub REAPER {
  my $child;
  our %Kid_Status; # store each exit status
  $SIG{CHLD} = \&REAPER;
  while ($child = waitpid(-1,WNOHANG) > 0) {
    $Kid_Status{$child} = $?;
  }
}
#
#
#
##################################################################################################################


##################################################################################################################
#
# usage: Outputs the usage of this script.. 
#
sub usage {
  my $message = shift;

  print STDERR "\n";
  print STDERR "***** $message *****\n";
  print STDERR <<EOUSAGE;

Usage: $0 

Usage: $0 [--verbose] [--verbose] [--nofork] [--listen] --port host1:port1 --port host2:port2

Usage: $0 --verbose --listen --port localhost:9000 --port localhost:9001

Examples
--------
$0 --verbose --listen --port localhost:9000 --port localhost:9001


Documentation 
-------------
Please use 'perldoc $0' to see detailed documentation

EOUSAGE
    
  exit;
}   


=pod

##################################################################################################################

=head1 NAME 

portpatch.pl - This script lets you "patch in ports" so that you can get from a machine on the external network
               back onto a machine on the internal network... 

##################################################################################################################

=head1 DESCRIPTION 

This script lets you "patch in ports" so that you can get from a machine on the external network
back onto a machine on the internal network...

 It works in the following way... 

 * Assume you have two machine named "external" and "internal"

 * The "internal" machine can connect outwars to the external machine - say for example that you can connect
   to the external machine on port 9004

 * The "external" machine cannot initiate connections back to the "internal" machine due to firewall
   restrictions. 

 On the "external" machine, run something like:

    external% ./portpatch.pl --verbose --listen --port localhost:9004 --port localhost:9005

 On the "internal" machine, run something like: 

    internal% ./portpatch.pl --verbose --port localhost:23 --port external.domainname.ext:9004

 What will then happen is that:

  * On your external machine, it will be listening on ports 9004 and 9005 and passing any data it gets
    on one port, to the other port and vice versa. 

  * On your internal machine, it will connect to ports 23 (telnet port) on localhost and port 9004
    on external.domainname.ext and pass any data it gets from one port, to the other port and vice versa. 

 You can then, log onto the external machine (from home say, from where you cannot get to the internal machine)
 and do the following:

    external% telnet localhost 9005

    Or you could do (from your home computer)

    home% telnet external.domainname.ext 9005

 As the relevant ports are patched, your telnet command will be able to use the tunnel and get a login
 shell on the internal machine. 

 NOTE: Currently you can only have one active connection... 

##################################################################################################################

=head1 REVISION

$Revision: 1.2 $

$Date: 2003/12/03 02:29:52 $

##################################################################################################################

=head1 AUTHOR

simran I<simran@reflectit.com>

##################################################################################################################

=head1 BUGS

No known bugs. 

##################################################################################################################

=head1 DIAGRAM

A digram of a running redirection (as described in the 'DESCRIPTION' above) would look like this:

                                
  -----------------                  ----------------------------------------------------     -----------------
  |Internal       |                  |External                                          |     |Home           |
  |               |                  |                                                  |     |               |
  |  localhost:23 |<================>| localhost:9004 <================> localhost:9005 |<===>| telnet        |
  |               |  (portpatch.pl)  |                  (portpatch.pl)                  |     |               |
  -----------------                  ----------------------------------------------------     -----------------

  * The steps you would have followed to setup the above patch/tunnel are:

  external% portpatch.pl --verbose --listen --port localhost:9004 --port localhost:9005
  internal% portpatch.pl --verbose --port localhost:23 --port external:9004

##################################################################################################################

=head1 USAGE

Please use the --help switch for usage details. 

eg. 
  % portpatch.pl --help

=cut

