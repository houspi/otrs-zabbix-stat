#!/usr/bin/perl
## --
## bin/otrs.ZabbixStat.pl - generate stats for Zabbix
## Copyright (C) 2018 houspi https://github.com/houspi
## --
#
# For Zabbix
# Script returns some stats for Zabbix 
# number tickets in queue
# number active agents
# number active customers
# Usage: bin/otrs.ZabbixStat.pl
#
# without any params this script works in LLD mode
# returns queue list
#

use strict;
use warnings;
use utf8;

use Getopt::Long;

use File::Basename;
use FindBin qw($RealBin);
use lib dirname($RealBin);
use lib dirname($RealBin) . '/Kernel/cpan-lib';
use lib dirname($RealBin) . '/Custom';

use Kernel::System::ObjectManager;

use JSON;
use Data::Dumper;

my %get_stats_rules = (
    "queue" => \&GetStatByQueue,
    "state" => \&GetStatByState,
    "users" => \&GetStatByUsers,
);
my %StateTypes = (
    99 => "created", 
    1  => "new", 
    2  => "open", 
    3  => "closed", 
    4  => "pending reminder", 
    5  => "pending auto", 
    6  => "removed", 
    7  => "merged", 
);

#print "Hello\n";

if (!scalar(@ARGV) ) {
    Discover();
} else {
    my $stat_type = $ARGV[0];
    if( exists($get_stats_rules{$stat_type}) ) {
        $get_stats_rules{$stat_type}->();
    } else {
        print "-1\n";
    }
    #print "QueueID = $QueueID\n";
    #print "StateID = $StateID\n";
    #GetTicketsCount($QueueID, $StateID);
}

#print "Done\n";

sub Discover {
    #print "Discover\n";
    my %json_data;
    $json_data{'data'} = ();
    #push(@{$json_data{'data'}}, {"{#QUEUEID}" => "0", "{#QUEUENAME}" => "TOTAL", "{#QUEUEGROUP}" => "2", });
    local $Kernel::OM = Kernel::System::ObjectManager->new();
    my $QueueObject = $Kernel::OM->Get('Kernel::System::Queue');
    my %Queues = $QueueObject->QueueList( Valid => 1 );
    foreach my $QueueID ( keys(%Queues) ) {
        push( @{$json_data{'data'}}, { "{#QUEUEID}"    => int($QueueID), 
                                      "{#QUEUENAME}"  => $Queues{$QueueID}, 
                                      "{#QUEUEGROUP}" => int($QueueObject->GetQueueGroupID(QueueID => $QueueID)) } );
        #GetTicketsCount($QueueID, 0);
    }
    foreach my $StateID ( keys(%StateTypes) ) {
        push( @{$json_data{'data'}}, { "{#STATETYPEID}" => int($StateID), "{#STATETYPENAME}" => $StateTypes{$StateID} } );
    }
    print to_json(\%json_data);
}

sub GetStatByQueue {
    my $QueueID = $ARGV[1] || 3; # spam queue by default
    my $StateTypeID = $ARGV[2] || 99;
    $StateTypeID = 99 unless( exists($StateTypes{$StateTypeID}) ); # 99 means all created tickets for last period
    
    local $Kernel::OM = Kernel::System::ObjectManager->new();
    my $TicketObject = $Kernel::OM->Get('Kernel::System::Ticket');
    my $CacheObject = $Kernel::OM->Get('Kernel::System::Cache');

    #my %ListType = $StateObject->StateTypeList( UserID => 1 );
    #print "queue $QueueID:\n";
    #foreach my $TypeID (sort keys %ListType) {
    my @StateTypeIDs;
    my $ChacheKey = join(":", "QUEUE", $QueueID,  $StateTypeID);
    
    use POSIX qw(strftime);
    my $CurGetStatByQueue = strftime "%Y-%m-%d %H:%M:%S", localtime;
    my $LastGetStatByQueue = $CacheObject->Get(
        Type => 'GetStatByQueue',
        Key  => $ChacheKey,
    );
    if (!$LastGetStatByQueue) {
        $LastGetStatByQueue = $CurGetStatByQueue;
    }
    my @TicketIDs;
    if ( $StateTypeID == 99 ) {
        @TicketIDs = $TicketObject->TicketSearch(
            Result   => 'COUNT',
            QueueIDs => [ $QueueID ],
            TicketCreateTimeNewerDate => $LastGetStatByQueue, 
            UserID   => 1,
        );
    } else {
        @TicketIDs = $TicketObject->TicketSearch(
            Result   => 'COUNT', 
            QueueIDs => [ $QueueID ], 
            StateTypeIDs => [ $StateTypeID ], 
            TicketCreateTimeNewerDate => $LastGetStatByQueue, 
            UserID   => 1, 
        );
    }
    $CacheObject->Set(
        Type  => 'GetStatByQueue',
        Key   => $ChacheKey,
        Value => $CurGetStatByQueue,
        TTL   => 31536000, # seconds, this means 1 year
        CacheInMemory  => 0,
        CacheInBackend => 1,
    );
    print $TicketIDs[0] . "\n";
}

sub GetStatByState {
    my $StateTypeID = $ARGV[1] || "99";
    $StateTypeID = "99" unless( exists($StateTypes{$StateTypeID}) );

    local $Kernel::OM = Kernel::System::ObjectManager->new();
    my $CacheObject = $Kernel::OM->Get('Kernel::System::Cache');
    my $ChacheKey = join(":", "STATETYPE", $StateTypeID);
    my $LastGetStatByState = $CacheObject->Get(
        Type => 'GetStatByState',
        Key  => $ChacheKey,
    );
    use POSIX qw(strftime);
    if (!$LastGetStatByState) {
        $LastGetStatByState = strftime "%Y-%m-%d %H:%M:%S", localtime;
    }
    my $CurGetStatByState = strftime "%Y-%m-%d %H:%M:%S", localtime;
    my $TicketObject = $Kernel::OM->Get('Kernel::System::Ticket');
    my @TicketIDs;
    if ( $StateTypeID == "99" ) {
        @TicketIDs = $TicketObject->TicketSearch(
            Result   => 'COUNT',
            TicketCreateTimeNewerDate => $LastGetStatByState, 
            UserID   => 1,
        );
    } else {
        @TicketIDs = $TicketObject->TicketSearch(
            Result   => 'COUNT',
            StateTypeIDs => [ $StateTypeID ],
            TicketCreateTimeNewerDate => $LastGetStatByState, 
            UserID   => 1,
        );
    }
    $CacheObject->Set(
        Type  => 'GetStatByState',
        Key   => $ChacheKey,
        Value => $CurGetStatByState,
        TTL   => 31536000, # seconds, this means 1 year
        CacheInMemory  => 0,
        CacheInBackend => 1,
    );
    print $TicketIDs[0] . "\n";
}

sub GetStatByUsers {
    my $UserType = $ARGV[1] || 'User';
    if ( $UserType ne 'User' && $UserType ne 'Customer' ) {
        print "-1\n";
        return;
    }
    use Kernel::System::ObjectManager;
    local $Kernel::OM = Kernel::System::ObjectManager->new();
    my $SessionObject = $Kernel::OM->Get('Kernel::System::AuthSession');
    
    my %Result = $SessionObject->GetActiveSessions(
        UserType => $UserType,
    );
    print "$Result{Total}\n";
}

sub PrintStateType {
    local $Kernel::OM = Kernel::System::ObjectManager->new();
    my $StateObject = $Kernel::OM->Get('Kernel::System::State');
    my %ListType = $StateObject->StateTypeList( UserID => 1 );
    print "\n";
    foreach my $TypeID (sort keys %ListType) {
        print "$TypeID => $ListType{$TypeID}\n";
    }
    print "\n";
}
