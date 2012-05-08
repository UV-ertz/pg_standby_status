#!/usr/bin/perl

=head1 NAME

pg_standby_status - Status Monitor for PostgreSQL Hot Standby Servers

=head1 SYNOPSIS

pg_standby_status MASTER_DSN [ STANDBY_DSN1, ... ]

=head1 DESCRIPTION

pg_standby_status is a status monitor which is able to display the lag of
transaction logs and offsets of PostgreSQL standby servers, which are running with
hot_standby = on. Thus this program requires at least PostgreSQL 9.0. It doesn't matter
wether you are running a streaming replication setup or a WAL-shipping solution, 
though.

=head1 DISCUSSION

pg_standby status currently prints the status of the primary node on the first line
of the status monitor output:

    M= 192.168.1.6:5445 3E/5B05DE30 keep 64

The M= indicates the position of the primary node, followed by its IP and port
number. The XX/XXXXXXXX formatted string displays the current segment id and
offset in the transaction log. The "keep" keyword tells how many wal_keep_segments
are currently configured on the primary node. Next to the primary node status line, each
standby is printed per line, introduced by the S= flag. Until the XX/XXXXXXXX string, 
the status line matches the one for the primary node. After this, the replay keyword
dispays the distance of the XLOG segment id from the standby to the primary node (segid) 
and its number of XLOG segments it is behind (count) replaying. The XLOG records actually
received from the master during streaming replication are displayed by the recv() values.

Next to each S= line there is a  summary line, indicated by a '>>' string. It displays 
the absolute position of the transaction log (XX/XX) on the master and the standby so 
it can be compared manually. The first value is the XLOG segment id, the second the 
XLOG segment number of the current XLOG segment id.

    S=    192.168.1.6:5446 3E/5B05DE30 replay(segid=0/count=0) recv(segid=0/count=0)
       STREAMING possible
       -M>>S=(3E/91 3E/91) 0 MB

The status monitor displays a status string next to each S= line, telling the
user wether it is possible for the standby server to stream from the primary's
transaction log ("STREAMING possible"). When the transaction lag counter exceeds the
wal_keep_segments of the primary node, the status monitor will change to the string
"RECOVER FROM ARCHIVE required". When the standby catches up and falls below the
threshold of wal_keep_segments of the primary, 
it will change back to "STREAMING possible". However, this doesn't indicate that
the specific standby will return to streaming mode immediately. It just means that
the PostgreSQL server likely will switch back to streaming mode soon, once it has 
absorbed all required XLOG segments from the archive.

=head1 RETURN CODES

Since pg_standby_status currently dies on database errors, there might be some
confusion about specific error codes  and which one belongs to which error
condition. This might be subject to change in the future, when pg_standby_status
gets a more sane error handling once.

=cut

use strict;
use DBI;
use Curses;

my $dsn_master = $ARGV[0];
my $dbh_master = DBI->connect("dbi:Pg:".$dsn_master,
                              "",
                              "",
                              { RaiseError => 1, AutoCommit => 1})
    || die DBI::errstr;

my @dsn_slaves = ();

##
## Retrieve the current xlog position on the primary. Returns
## a hash reference with all informations
##
sub XLOGLocationPrimary(%) {
    my %args = @_;

    my $db = $args{DBH};
    my $sth = $db->prepare(qq/SELECT pg_current_xlog_location() AS location, 
                                     (SELECT a.setting::int4 * b.setting::int4 
                                      FROM pg_settings a, pg_settings b 
                                      WHERE a.name = 'wal_segment_size' 
                                            AND b.name = 'wal_block_size') AS xlogsegsize,
                              current_setting('block_size') AS xlogblocksize,
                              current_setting('wal_keep_segments') AS wal_keep_segments;/)
        || die "error executing pg_current_xlog_location on master\n";
    my %location = {};
    $sth->execute();

    ## host and port info
    $location{PGHOST} = $db->{pg_host};
    $location{PGPORT} = $db->{pg_port};

    ## We catch some more informations on the primary, since we
    ## need some of the compile time settings to calculate the XLOG offsets.
    ## Note that we easily can rely on those settings on the standby, too,
    ## since we must be binary compatible there.

    if (my $hashref = $sth->fetchrow_hashref()) {
        $location{XLOGLOCATION} = $hashref->{location};
        $location{XLOGSEGSIZE}  = $hashref->{xlogsegsize};
        $location{XLOGBLKSIZE}  = $hashref->{xlogblocksize};
        $location{WAL_KEEP_SEGMENTS} = $hashref->{wal_keep_segments};
    }

    $sth->finish();
    return %location;
}

## Calculates the distance between two xlog locations
##
## This does the guts of this holy tool. We get the
## current XLOGSEGID/XLOGOFFSET via XLOGLocationPrimary() and
## XLOGLocationStandby() and calculate the following values,
## returned by a hash reference (and its equally named key):
##
## XLOGSEGID = Distance between the SEGID from standby to primary
## XLOGCOUNT = Distance between current XLOG segment on primary
##             and standby
## MASTER_XLOGSEGID = current XLOGSEGID on the primary
## SLAVE_XLOGSEGID  = current XLOGSEGID on the standby
## MASTER_XLOGCOUNT = current XLOG segment on the primary
## SLAVE_XLOGCOUNT  = current XLOG segment on the standby
## 
## The time we calculate the values might be outdated: the standby and the 
## primary might already advanced their XLOG offsets, so the value
## will likely appear a little "off".
##
sub XLOGDistance($$) {

    ## NOTE: master_location is passed as a hash reference
    my ($master_location, $standby_location) = @_;
    my ($master_xlogid, $master_xlogoffset) = split '/', $master_location->{XLOGLOCATION};
    my ($standby_xlogid, $standby_xlogoffset) = split '/', $standby_location;

    ## convert hex values of xlogsegid
    $master_xlogid = hex("$master_xlogid");
    $standby_xlogid = hex("$standby_xlogid");

    ## calculate the number of the current segment of the current XLOGSEGID. This is relativ to
    ## the starting segment of the current XLOGSEGID.

    my $master_log = 1 + hex("FF") - ((hex("FF000000") 
                                       - (hex($master_xlogoffset))) / $master_location->{XLOGSEGSIZE});
    my $standby_log = 1 + hex("FF") - ((hex("FF000000") 
                                        - (hex($standby_xlogoffset))) / $master_location->{XLOGSEGSIZE});
    my %distance = {};
    $distance{XLOGSEGID} = hex("$master_xlogid") - hex("$standby_xlogid");

    ## Calculate the current distance of number of XLOG segments between
    ## the primary and the standby.

    $distance{XLOGCOUNT} = ($master_xlogid * hex("FF") + $master_log) 
        - ($standby_xlogid * hex("FF") + $standby_log);

    ## record remaining values

    $distance{MASTER_XLOGSEGID} = $master_xlogid;
    $distance{SLAVE_XLOGSEGID}  = $standby_xlogid;
    $distance{MASTER_XLOGCOUNT} = $master_log;
    $distance{SLAVE_XLOGCOUNT}  = $standby_log;
    $distance{SLAVE_XLOG_BACKLOG_SZ} = $distance{XLOGCOUNT} * $master_location->{XLOGSEGSIZE};

    return %distance;
}

##
## Retrieve the last replayed XLOG location from the primary
##
## Returns a hash with the following keys/values:
## XLOGLOCATION    : Last location replayed by the standby
## XLOGRECVLOCATION: Last location received by streaming
## STANDBYENABLED  : The standby is in recovery mode (true)
##                   or was normally started (false).
##                   If the latter is the case, this standby is not
##                   really replicating.
## PGHOST: hostname of the standby (eases tracking from which
##         standby this information comes)
## PGPORT: port of the standby 
##
## XLOGRECVLOCATION might not yet be initialized when streaming
## wasn't enabled or wasn't started yet on the specified standby.
##
sub XLOGLocationStandby(%) {
    my %args = @_;
    my $db = $args{DBH};

    my $sth = $db->prepare(qq/SELECT pg_is_in_recovery() AS standby_enabled,
                                     pg_last_xlog_receive_location() AS receive, 
                                     pg_last_xlog_replay_location() AS location;/)
        || die "error executing pg_last_xlog_replay_location on standby\n";
    my %standby_info = {};
    $sth->execute();

    if (my $hashref = $sth->fetchrow_hashref()) {
        $standby_info{STANDBYENABLED}   = $hashref->{standby_enabled};
        $standby_info{XLOGLOCATION}     = $hashref->{location};
        $standby_info{XLOGRECVLOCATION} = $hashref->{receive};
    }

    $standby_info{PGHOST} = $db->{pg_host};
    $standby_info{PGPORT} = $db->{pg_port};

    $sth->finish();
    return \%standby_info;
}

##
## Aggregates all standby XLOGLocationStandby() hash references
## from all standby nodes.
##
sub XLOGStandbyLocations(%) {
    my %args = @_;
    my @standby = @{$args{DBHS}};
    my @locations;

    for (my $i = 0; $i <= $#standby; $i++) {
        $locations[$i] = XLOGLocationStandby(DBH => $standby[$i]);
    }

    return @locations;
}

## connect to all given standby nodes
for(my $i = 1; $i <= $#ARGV; $i++) {
    $dsn_slaves[$i - 1] = DBI->connect("dbi:Pg:".$ARGV[$i],
                                       "",
                                       "",
                                       { RaiseError => 1, AutoCommit => 1 })
        || die DBI::errstr;
}

## Curses initialization
initscr;
start_color;
init_pair(1, COLOR_CYAN, COLOR_BLACK);
init_pair(2, COLOR_RED, COLOR_BLACK);

while(1) {

    my %master_location = XLOGLocationPrimary(DBH => $dbh_master);
    my @standby_locations = XLOGStandbyLocations(DBHS => \@dsn_slaves);

    my $standby_locstr;
    my $extra_locstr;

    erase();
    attron(A_BOLD);
    printw(sprintf "M= %s:%s %8s keep %d\n", $master_location{PGHOST}, $master_location{PGPORT},
           $master_location{XLOGLOCATION}, $master_location{WAL_KEEP_SEGMENTS});
    attroff(A_BOLD);
    addstr("");

    foreach my $location (@standby_locations) {
        my %distance; ## distance xlog's replayed
        my %distance_recv;  ## distance xlog's received by streaming

        ## is this standby in recovery mode ??
        if (!$location->{STANDBYENABLED}) {
            ## oops, seems this is not a standby server,
            ## mark it accordingly and step forward to the next
            ## standby, if any

            $standby_locstr = sprintf "   %s:%s is not in recovery mode\n", 
                              $location->{PGHOST}, $location->{PGPORT};
            printw("S= ");
            attron(COLOR_PAIR(2));
            printw($standby_locstr);
            attroff(COLOR_PAIR(2));
            next;
        }

        ## Calculate the distance of XLOGs replayed between master and standby
        %distance = XLOGDistance(\%master_location, $location->{XLOGLOCATION});

        ## Calculate the distance of XLOGs received from master
        %distance_recv = XLOGDistance(\%master_location, $location->{XLOGRECVLOCATION});

        ## Materialize output
        $standby_locstr = sprintf "   %s:%s %s replay(segid=%d/count=%d) recv(segid=%d/count=%d)\n", 
                                  $location->{PGHOST}, $location->{PGPORT},
                                  $location->{XLOGLOCATION}, $distance{XLOGSEGID}, 
                                  $distance{XLOGCOUNT}, $distance_recv{XLOGSEGID},
                                  $distance_recv{XLOGCOUNT};
        $extra_locstr = sprintf "   -M>>S=(%X/%d %X/%d) %u MB\n", $distance{MASTER_XLOGSEGID}, 
                                $distance{MASTER_XLOGCOUNT}, $distance{SLAVE_XLOGSEGID}, 
                                $distance{SLAVE_XLOGCOUNT}, 
                                $distance{SLAVE_XLOG_BACKLOG_SZ} / 1024 / 1024;

        ## check wether the current lag will likely exceed the available
        ## XLOG segments located on the primary. Give a warning when
        ## we exceed wal_keep_segments. 
        ##
        ## NOTE: this will return to 'STREAMING possible' as soon as the standby 
        ## doesn't lag more than XLOGCOUNT > WAL_KEEP_SEGMENTS.
        ## However, this doesn't mean that the standby *will* immediately return
        ## into XLOG streaming. The PostgreSQL startup process will seek the XLOG
        ## segments from archive until it has absorbed all available segments and can
        ## safely return to streaming mode.
        
        if ($master_location{WAL_KEEP_SEGMENTS} > $distance{XLOGCOUNT}) {
            printw(sprintf "S= %s ", $standby_locstr);
            attron(COLOR_PAIR(1));
            printw("  STREAMING possible\n");
            attroff(COLOR_PAIR(1));
        } else {
            printw(sprintf "S= %s ", $standby_locstr);
            attron(COLOR_PAIR(2));
            printw("  RECOVER FROM ARCHIVE required\n");
            attroff(COLOR_PAIR(2));
        }

        printw($extra_locstr);
        addstr("");
    }

    refresh();
    sleep 5;
}

endwin;

exit(0);
