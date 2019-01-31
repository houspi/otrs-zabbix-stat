#!/usr/bin/perl
## --
## bin/otrs.ZabbixStat.pl - generate stats for Zabbix
## Copyright (C) 2018 houspi https://github.com/houspi
## --

=head1 DESCRIPTION
 For Zabbix
 Script returns some stats for Zabbix 
 number of created/closed tickets
 number of active agents/customers
 number of tickets in various open states
 number of open tickets in queues
 
 Usage: /opt/otrs/bin/otrs.ZabbixStat.pl [params]

 without any params this script works in LLD mode
 returns a list of queues and states

=cut

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

my $CacheTTL = 31536000; # seconds, this means 1 year

#
# Config Items
#
# Discover rule
# otrs.discovery
# UserParameter=otrs.discovery,/opt/otrs/bin/otrs.ZabbixStat.pl
#
# Users
# UserParameter=otrs.users[*],/opt/otrs/bin/otrs.ZabbixStat.pl users $1
# otrs.users[Customer]  ! On by default
# otrs.users[User]      ! On by default
#
# All ticket states
# UserParameter=otrs.tickets.state[*],/opt/otrs/bin/otrs.ZabbixStat.pl statetype $1
# otrs.tickets.state[Created]   ! On by default
# otrs.tickets.state[Closed]    ! On by default
#
# Tickets states by queue
# UserParameter=otrs.queue[*],/opt/otrs/bin/otrs.ZabbixStat.pl queue $1 $2
# otrs.queue.state[{#QUEUEID}, Opened]  ! Off by default
#
#

my %get_stats_rules = (
    "users"     => \&GetStatByUsers,
    "statetype" => \&GetStatByStateType,
    "queue" => \&GetStatByQueue,
);

my @ClosedStateTypeIDs = ( 3, 6, 7 );
my @OpenedStateTypeIDs = ( 1, 2, 4, 5 );

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

my @UserTypes = qw(User Customer);


if (!scalar(@ARGV) ) {
    Discover();
} else {
    my $stat_type = $ARGV[0];
    if( exists($get_stats_rules{$stat_type}) ) {
        $get_stats_rules{$stat_type}->();
    } else {
        print "-1\n";
    }
}

=item Discover
    LLD mode
    returns a list of queues, states and users
=cut
sub Discover {
    my %json_data;
    $json_data{'data'} = ();
    local $Kernel::OM = Kernel::System::ObjectManager->new();
    my $QueueObject = $Kernel::OM->Get('Kernel::System::Queue');
    my %Queues = $QueueObject->QueueList( Valid => 1 );
    foreach my $QueueID ( keys(%Queues) ) {
        my %GroupData = $Kernel::OM->Get('Kernel::System::Group')->GroupGet( ID => $QueueObject->GetQueueGroupID(QueueID => $QueueID) );
        push( @{$json_data{'data'}}, { "{#QUEUEID}"    => int($QueueID), 
                                       "{#QUEUENAME}"  => $Queues{$QueueID}, 
                                       "{#QUEUEGROUPID}" => int($GroupData{ID}),
                                       "{#QUEUEGROUPNAME}" => $GroupData{Name} } );
    }
    my %ListType = $Kernel::OM->Get('Kernel::System::State')->StateTypeList( UserID => 1 );
    foreach my $StateID ( sort keys(%ListType) ) {
        push( @{$json_data{'data'}}, { "{#STATETYPEID}" => int($StateID), "{#STATETYPENAME}" => $ListType{$StateID} } );
    }
    foreach my $UserType ( @UserTypes ) {
        push( @{$json_data{'data'}}, { "{#USERTYPENAME}" => $UserType } );
    }
    print to_json(\%json_data), "\n";
}

=item GetStatByUsers
   returns the number of online users or customers
=cut
sub GetStatByUsers {
    my $UserType = $ARGV[1] || '';
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


=item GetStatByStateType
   returns the number of created and closed tickets for the last time
=cut
sub GetStatByStateType {
    my $StateType = $ARGV[1] || '';
    
    my $ChacheKey = join(":", "STATETYPE", $StateType);
    use POSIX qw(strftime);
    my $CurGetStatByState = strftime "%Y-%m-%d %H:%M:%S", localtime;

    local $Kernel::OM = Kernel::System::ObjectManager->new();
    my $CacheObject = $Kernel::OM->Get('Kernel::System::Cache');
    my $LastGetStatByState = $CacheObject->Get(
        Type => 'GetStatByState',
        Key  => $ChacheKey,
    );
    if (!$LastGetStatByState) {
        $LastGetStatByState = $CurGetStatByState;
    }
    
    my $TicketObject = $Kernel::OM->Get('Kernel::System::Ticket');
    my @TicketIDs;
    if ($StateType eq 'Created' ) {
        @TicketIDs = $TicketObject->TicketSearch(
            Result   => 'COUNT',
            UserID   => 1,
            TicketCreateTimeNewerDate => $LastGetStatByState, 
        );
    } elsif ($StateType eq 'Closed') {
        @TicketIDs = $TicketObject->TicketSearch(
            Result   => 'COUNT',
            UserID   => 1,
            StateTypeIDs => \@ClosedStateTypeIDs,
            TicketChangeTimeNewerDate => $LastGetStatByState, 
        );
    } else {
        $TicketIDs[0] = "-1";
    }
    $CacheObject->Set(
        Type  => 'GetStatByState',
        Key   => $ChacheKey,
        Value => $CurGetStatByState,
        TTL   => $CacheTTL, 
        CacheInMemory  => 0,
        CacheInBackend => 1,
    );
    print $TicketIDs[0] . "\n";
}

=item GetStatByQueue
   returns the number of tickets in the open state type in a specific queue
=cut
sub GetStatByQueue {
    my $QueueID = $ARGV[1] || 3; # spam queue by default
    $QueueID =~ s/\D//g;
    $QueueID = 3 unless($QueueID);
    my $StateType = $ARGV[2] || 'Opened';
    
    local $Kernel::OM = Kernel::System::ObjectManager->new();
    my $TicketObject = $Kernel::OM->Get('Kernel::System::Ticket');
    my $CacheObject = $Kernel::OM->Get('Kernel::System::Cache');

    my $ChacheKey = join(":", "QUEUE", $QueueID,  $StateType);
    
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
    if ($StateType eq 'Opened' ) {
#            TicketCreateTimeNewerDate => $LastGetStatByQueue, 
        @TicketIDs = $TicketObject->TicketSearch(
            Result   => 'COUNT',
            QueueIDs => [ $QueueID ],
            UserID   => 1,
            StateTypeIDs => \@OpenedStateTypeIDs,
        );
    } else {
#            TicketCreateTimeNewerDate => $LastGetStatByQueue, 
        @TicketIDs = $TicketObject->TicketSearch(
            Result   => 'COUNT', 
            UserID   => 1, 
            QueueIDs => [ $QueueID ], 
            StateType    => [ $StateType ],
        );
    }
    $CacheObject->Set(
        Type  => 'GetStatByQueue',
        Key   => $ChacheKey,
        Value => $CurGetStatByQueue,
        TTL   => $CacheTTL, 
        CacheInMemory  => 0,
        CacheInBackend => 1,
    );
    print $TicketIDs[0] . "\n";
}
