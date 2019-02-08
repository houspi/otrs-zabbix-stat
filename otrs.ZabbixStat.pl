#!/usr/bin/perl
## --
## bin/otrs.ZabbixStat.pl - generate stats for Zabbix
## 2018 houspi https://github.com/houspi
## --

=head1 DESCRIPTION
 
 Script returns some stats for Zabbix 
 Ticket activity: number of created/closed tickets
 User activity: number of active agents/customers
 Count of open tickets in queues
 Count of tickets in various states
 
 Usage: /opt/otrs/bin/otrs.ZabbixStat.pl [params]

 Without any params this script works in LLD mode
 returns a list of queues and states

=cut

use strict;
use warnings;
use utf8;

use File::Basename;
use FindBin qw($RealBin);
use lib dirname($RealBin);
use lib dirname($RealBin) . '/Kernel/cpan-lib';
use lib dirname($RealBin) . '/Custom';

use Kernel::System::ObjectManager;

use JSON;
use Data::Dumper;

my $CacheTTL = 2678400; # seconds, this means 1 month

my %get_stats_rules = (
    "users"     => \&GetStatByUsers,
    "statetype" => \&GetStatByStateType,
    "queue"     => \&GetStatByQueue,
);

my @ClosedStateTypeIDs = ( 3, 5, 6, 7 );
my @OpenedStateTypeIDs = ( 1, 2, 4);
my @UserTypes = qw(User Customer);

my $rv = "-1";

if (!scalar(@ARGV) ) {
    $rv = Discover();
} else {
    my $stat_type = $ARGV[0];
    if( exists($get_stats_rules{$stat_type}) ) {
        $rv = $get_stats_rules{$stat_type}->();
    }
}
print "$rv\n";


=item Discover
    LLD mode
    returns a list of queues, states and users
=cut
sub Discover {
    my %json_data;
    $json_data{'data'} = ();
    local $Kernel::OM = Kernel::System::ObjectManager->new();
    
    my %Queues = $Kernel::OM->Get('Kernel::System::Queue')->QueueList( Valid => 1 );
    map {push( @{$json_data{'data'}}, { "{#QUEUEID}"    => int($_), "{#QUEUENAME}"  => $Queues{$_} }) } sort keys %Queues;
    
    my %ListType = $Kernel::OM->Get('Kernel::System::State')->StateTypeList( UserID => 1 );
    map {push( @{$json_data{'data'}}, { "{#STATETYPEID}" => int($_), "{#STATETYPENAME}" => $ListType{$_} } )} sort keys %ListType;
    
    foreach ( @UserTypes ) {
        push( @{$json_data{'data'}}, { "{#USERTYPENAME}" => $_ } );
    }
    return to_json(\%json_data);
}


=item GetStatByUsers
   returns the number of online users or customers
=cut
sub GetStatByUsers {
    my $UserType = $ARGV[1] || '';

    if ( $UserType ne 'User' && $UserType ne 'Customer' ) {
        return "-1";
    }
    use Kernel::System::ObjectManager;
    local $Kernel::OM = Kernel::System::ObjectManager->new();
    my $SessionObject = $Kernel::OM->Get('Kernel::System::AuthSession');
    my %Result = $SessionObject->GetActiveSessions( UserType => $UserType );
    return $Result{Total};
}


=item GetStatByStateType
   returns the number of created and closed tickets for the last time
=cut
sub GetStatByStateType {
    my $StateType = $ARGV[1] || '';
    
    my $ChacheKey = join(":", "STATETYPE", $StateType);
    use POSIX qw(strftime);
    my $CurGetStat = strftime "%Y-%m-%d %H:%M:%S", localtime;

    local $Kernel::OM = Kernel::System::ObjectManager->new();
    
    my $CacheObject = $Kernel::OM->Get('Kernel::System::Cache');
    my $LastGetStat = $CacheObject->Get(
        Type => 'GetStatByStateType',
        Key  => $ChacheKey,
    );
    if (!$LastGetStat) {
        $LastGetStat = $CurGetStat;
    }
    
    my @TicketIDs;
    my %Params;
    if ($StateType eq 'Created' ) {
        %Params = (
            Result   => 'COUNT',
            UserID   => 1,
            TicketCreateTimeNewerDate => $LastGetStat, 
        );
    } elsif ($StateType eq 'Closed') {
        %Params = (
            Result   => 'COUNT',
            UserID   => 1,
            StateTypeIDs => \@ClosedStateTypeIDs,
            TicketChangeTimeNewerDate => $LastGetStat, 
        );
    } else {
        return -1;
    }
    @TicketIDs = $Kernel::OM->Get('Kernel::System::Ticket')->TicketSearch( %Params );
    $CacheObject->Set(
        Type  => 'GetStatByStateType',
        Key   => $ChacheKey,
        Value => $CurGetStat,
        TTL   => $CacheTTL, 
        CacheInMemory  => 0,
        CacheInBackend => 1,
    );
    return $TicketIDs[0];
}


=item GetStatByQueue
   returns the number of tickets in the open state type in a specific queue
   <queue id> <state type> <count with subqueues>
=cut
sub GetStatByQueue {
    my $QueueID = $ARGV[1] || 3; # spam queue by default
    $QueueID =~ s/\D//g;
    $QueueID = 3 unless($QueueID);
    
    my $StateType = $ARGV[2] || 'opened';
    $StateType =~ tr/A-Z/a-z/;  # for backward compatibility
    
    my $UseSubQueues = $ARGV[3] || 0; 
    $UseSubQueues = 0 if ( $UseSubQueues =~ /\D/ or ($UseSubQueues != 0 and $UseSubQueues != 1));
    
    local $Kernel::OM = Kernel::System::ObjectManager->new();
    
    # Use SQL query to check queue
    # because the QueueLookup method prints error message if the queue doesn't exists
    my $Select = $Kernel::OM->Get('Kernel::System::DB')->SelectAll(
        SQL =>    "SELECT COUNT(*) FROM queue WHERE id=?",
        Bind => [ \$QueueID ]
    );
    return -1 if (!@{$Select}[0]->[0]);
    
    my $CacheObject = $Kernel::OM->Get('Kernel::System::Cache');

    my @TicketIDs;
    my %Params;
    if ($StateType eq 'opened' ) {
        %Params = (
            Result   => 'COUNT',
            UserID   => 1,
            QueueIDs => [ $QueueID ],
            UseSubQueues => $UseSubQueues,
            StateTypeIDs => \@OpenedStateTypeIDs,
        );
    } else {
        %Params = (
            Result   => 'COUNT',
            UserID   => 1,
            QueueIDs => [ $QueueID ],
            UseSubQueues => $UseSubQueues,
            StateType    => [ $StateType ],
        );
    }
    @TicketIDs = $Kernel::OM->Get('Kernel::System::Ticket')->TicketSearch( %Params );
    $TicketIDs[0] = -1 if ($#TicketIDs < 0 );
    return $TicketIDs[0];
}

sub PrintStateType {
    local $Kernel::OM = Kernel::System::ObjectManager->new();
    my $StateObject = $Kernel::OM->Get('Kernel::System::State');
    my %ListType = $StateObject->StateTypeList( UserID => 1 );
    print "\n";
    print map { "$_ => $ListType{$_}\n" } sort keys %ListType;
    print "\n";
}
