#!/usr/bin/perl

use strict;
use Getopt::Long;
use Env;
use File::Basename;
use File::copy;
use File::Spec;
use File::Path;
use Cwd;

my $eos_home = defined $ENV{EOS_HOME} ? $ENV{EOS_HOME} : getcwd;
my $eosd = $eos_home . "/programs/eosd/eosd";

my $nodes = defined $ENV{EOS_TEST_RING} ? $ENV{EOS_TEST_RING} : "1";
my $pnodes = defined $ENV{EOS_TEST_PRODUCERS} ? $ENV{EOS_TEST_PRODUCERS} : "1";

my $prods = 21;
my $genesis = "$eos_home/genesis.json";
my $http_port_base = 8888;
my $p2p_port_base = 9876;
my $data_dir_base = "ttdn";
my $hostname = "127.0.0.1";
my $first_pause = 45;
my $launch_pause = 5;
my $run_duration = 60;
my $topo = "ring";
my $override_gts; # = "now";

if (!GetOptions("nodes=i" => \$nodes,
                "first-pause=i" => \$first_pause,
                "launch-pause=i" => \$launch_pause,
                "duration=i" => \$run_duration,
                "topo=s" => \$topo,
                "pnodes=i" => \$pnodes)) {
    print "usage: $ARGV[0] [--nodes=<n>] [--pnodes=<n>] [--topo=<ring|star>] [--first-pause=<n>] [--launch-pause=<n>] [--duration=<n>]\n";
    print "where:\n";
    print "--nodes=n (default = 1) sets the number of eosd instances to launch\n";
    print "--pnodes=n (default = 1) sets the number nodes that will also be producers\n";
    print "--topo=s (default = ring) sets the network topology to eithar a ring shape or a star shape\n";
    print "--first-pause=n (default = 45) sets the seconds delay after starting the first instance\n";
    print "--launch-pause=n (default = 5) sets the seconds delay after starting subsequent nodes\n";
    print "--duration=n (default = 60) sets the seconds delay after starting the last node before shutting down the test\n";
    print "\nproducer count currently fixed at $prods\n";
    exit
}

die "pnodes value must be between 1 and $prods\n" if ($pnodes < 1 || $pnodes > $prods);

$nodes = $pnodes if ($nodes < $pnodes);

my $per_node = int ($prods / $pnodes);
my $extra = $prods - ($per_node * $pnodes);
my @pcount;
for (my $p = 0; $p < $pnodes; $p++) {
    $pcount[$p] = $per_node;
    if ($extra) {
        $pcount[$p]++;
        $extra--;
    }
}
my @pid;
my @data_dir;
my @p2p_port;
my @http_port;
my @peers;
my $rhost = $hostname; # from a list for multihost tests
for (my $i = 0; $i < $nodes; $i++) {
    $p2p_port[$i] = $p2p_port_base + $i;
    $http_port[$i] = $http_port_base + $i;
    $data_dir[$i] = "$data_dir_base-$i";
}

opendir(DIR, ".") or die $!;
while (my $d = readdir(DIR)) {
    if ($d =~ $data_dir_base) {
        rmtree ($d) or die $!;
    }
}
closedir(DIR);

sub write_config {
    my $i = shift;
    my $producer = shift;
    mkdir ($data_dir[$i]);
    mkdir ($data_dir[$i]."/blocks");
    mkdir ($data_dir[$i]."/blockchain");

    open (my $cfg, '>', "$data_dir[$i]/config.ini") ;
    print $cfg "genesis-json = \"$genesis\"\n";
    print $cfg "block-log-dir = blocks\n";
    print $cfg "readonly = 0\n";
    print $cfg "shared-file-dir = blockchain\n";
    print $cfg "shared-file-size = 64\n";
    print $cfg "http-server-endpoint = 127.0.0.1:$http_port[$i]\n";
    print $cfg "listen-endpoint = 0.0.0.0:$p2p_port[$i]\n";
    print $cfg "public-endpoint = $hostname:$p2p_port[$i]\n";
    foreach my $peer (@peers) {
        print $cfg "remote-endpoint = $peer\n";
    }

    if (defined $producer) {
        print $cfg "enable-stale-production = true\n";
        print $cfg "required-participation = true\n";
        print $cfg "private-key = [\"EOS6MRyAjQq8ud7hVNYcfnVPJqcVpscN5So8BhtHuGYqET5GDW5CV\",\"5KQwrPbwdL6PhXujxW37FSSQZ1JiwsST4cqQzDeyXtP79zkvFD3\"]\n";

        print $cfg "plugin = eos::producer_plugin\n";
        print $cfg "plugin = eos::chain_api_plugin\n";

        my $prod_ndx = ord('a') + $producer;
        my $num_prod = $pcount[$producer];
        for (my $p = 0; $p < $num_prod; $p++) {
            print $cfg "producer-name = init" . chr($prod_ndx) . "\n";
            $prod_ndx += $pnodes; # ($p < $per_node-1) ? $pnodes : 1;
        }
    }
    close $cfg;
}


sub make_ring_topology () {
    for (my $i = 0; $i < $nodes; $i++) {
        my $pi = $i if ($i < $pnodes);
        my $rport = ($i == $nodes - 1) ? $p2p_port_base : $p2p_port[$i] + 1;
        $peers[0] = "$rhost:$rport";
        if ($nodes > 2) {
            $rport = $p2p_port[$i] - 1;
            $rport += $nodes if ($i == 0);
            $peers[1] = "$rhost:$rport";
        }
        write_config ($i, $pi);
    }
    return 1;
}

sub make_grid_topology () {
    print "Sorry, the grid topology is not yet implemented\n";
    return 0;
}

sub make_star_topology () {
    print "Sorry, the star topology is not yet implemented\n";
    return 0;
 }

sub launch_nodes () {
    my $gtsarg;
    if (defined $override_gts) {
        my $GTS = $override_gts;
        print "$override_gts\n";

        if ($override_gts =~ "now" ) {
            chomp ($GTS = `date -u "+%Y-%m-%dT%H:%M:%S"`);
            my @s = split (':',$GTS);
            $s[2] = substr ((100 + (int ($s[2]/3) * 3)),1);
            $GTS = join (':', @s);
            print "using genesis time stamp $GTS\n";
        }
        $gtsarg = " --genesis-timestamp=$GTS";
    }

    for (my $i = 0; $i < $nodes;  $i++) {
        my @cmdline = ($eosd,
                       $gtsarg,
                       " --data-dir=$data_dir[$i]");
        print "starting $eosd $gtsarg --data-dir=$data_dir[$i]\n";
        $pid[$i] = fork;
        if ($pid[$i] > 0) {
            my $pause = $i == 0 ? $first_pause : $launch_pause;
            print "parent process looping, child pid = $pid[$i]";
            if ($i < $nodes - 1) {
                print ", pausing $pause seconds\n";
                sleep ($pause);
            }
            else {
                print "\n";
            }

        }
        elsif (defined ($pid[$i])) {
            print "child execing now, pid = $$\n";
            open OUTPUT, '>', "$data_dir[$i]/stdout.txt" or die $!;
            open ERROR, '>', "$data_dir[$i]/stderr.txt" or die $!;
            STDOUT->fdopen ( \*OUTPUT, 'w') or die $!;
            STDERR->fdopen ( \*ERROR, 'w') or die $!;

            exec @cmdline;
            print "child terminating now\n";
            exit;
        }
        else {
            print "fork failed\n";
            exit;
        }
    }
}

sub kill_nodes () {
    print "all nodes launched, network running for $run_duration seconds\n";
    sleep ($run_duration);

    foreach my $pp (@pid) {
        print "killing $pp\n";
        kill 2, $pp;
    }
}


###################################################
# main

if ($nodes == 1) {
    write_config (0);
}
else {
    if    ( $topo =~ "ring" ) { make_ring_topology () or die; }
    elsif ( $topo =~ "grid" ) { make_grid_topology () or die; }
    elsif ( $topo =~ "star" ) { make_star_topology () or die; }
    else  { print "$topo is not a known topology" and die; }
}
exit; #sleep(1);
launch_nodes ();

kill_nodes () if ($run_duration > 0);
