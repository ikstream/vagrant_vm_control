#!/usr/bin/perl

#	MIT License
#
#	Copyright (c) 2016 Stefan Venz
#
#	Permission is hereby granted, free of charge, to any person obtaining a copy
#	of this software and associated documentation files (the "Software"), to deal
#	in the Software without restriction, including without limitation the rights
#	to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
#	copies of the Software, and to permit persons to whom the Software is
#	furnished to do so, subject to the following conditions:
#
#	The above copyright notice and this permission notice shall be included in all
#	copies or substantial portions of the Software.
#
#	THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
#	IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
#	FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
#	AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
#	LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
#	OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
#	SOFTWARE.

#TODO: provide option to add all vagrant boxes of a user
#TODO: filter input to do start and stop jobs
#TODO: check if box is already in file
#TODO: Fork on start and shutdown
#TODO: write vagrant outpu to individual logfiles
#TODO: print debug output to logfile or journalctl
#TODO: rewrite box storage to keep boxes in own home dir
#TODO: allow user to add boxes instead of only root
#TODO: simplify
use strict;
use warnings;

use File::HomeDir;
use Getopt::Long;
use Pod::Usage;

my $cfg_dir = '/etc/vm_control/';
my $debug = 0;

#enable and start systemd units for each user
#@unit file: systemd unit to start and enable
sub enable_unit {
	my $unit = shift;
	print "enabling systemd unit $unit\n";
	my $ret = `systemctl enable $unit`;
	print "something went wrong: systemd returned $ret" if ($ret);

#	print "starting systemd unit $unit\n";
#	$ret = `systemctl start $unit`;
#	print "something went wrong: systemd returned $ret" if ($ret);
}

#create systemd units for each user monitored
#@user: start/stop vagrant boxes of this user
sub create_units {
	my $user = shift;
	my $sys_dir = '/etc/systemd/system/';
	my $start_file = "start_$user" ."_VM.service";

	print "creating systemd unit for $user VM startup\n";

	open(my $START_FILE, '>', "$sys_dir" ."$start_file")
	 or die "could not open $sys_dir" ."$start_file: $!\n";

	print $START_FILE "[UNIT]\n";
	print $START_FILE "Description=Start $user Vagrant Boxes on start\n";
	print $START_FILE "Requires=network.target\n";
	print $START_FILE "After=network.target\n";
	print $START_FILE "\n";
	print $START_FILE "[Service]\n";
	print $START_FILE "User=$user\n";
	print $START_FILE "Type=forking\n";
	print $START_FILE "RemainAfterExit=yes\n";
	print $START_FILE "ExecStart=/usr/local/bin/vm_conrol.pl start $user\n";
	print $START_FILE "\n";
	print $START_FILE "[Install]\n";
	print $START_FILE "WantedBy=multi-user.target\n";
	close($START_FILE);

	&enable_unit($start_file);

	my $stop_file = "stop_$user" ."_VM.service";
	print "creating systemd unit for $user VM stop\n";

	open(my $STOP_FILE, '>', "$sys_dir" ."$stop_file")
	 or die "could not open $sys_dir" ."$stop_file: $!\n";

	print $STOP_FILE "[Unit]\n";
	print $STOP_FILE "Description= Stop $user Vagrant Boxes on system down\n";
	print $STOP_FILE "Requires=network.target\n";
	print $STOP_FILE "After=network.target\n";
	print $STOP_FILE "\n";
	print $STOP_FILE "[Service]\n";
	print $STOP_FILE "User=$user\n";
	print $STOP_FILE "Type=forking\n";
	print $STOP_FILE "RemainAfterExit=yes\n";
	print $STOP_FILE "ExecStop=/usr/local/bin/vm_control.pl stop $user\n";
	print $STOP_FILE "\n";
	print $STOP_FILE "[Install]\n";
	print $STOP_FILE "WantedBy=mutli-user.target\n";
	close($STOP_FILE);

	&enable_unit($stop_file);
}

#run vagrant halt/suspend/up on given vagrant box and write to log
#@vm: vagrant box to run vagrant command on
#@job: command to run. should be halt/suspend/up
sub job_control {
	my ($vm, $job) = @_;
	my $home = File::HomeDir->my_home;
	my $log_file = $home ."/.config/vm_control/$vm" .".log";
	my $date = localtime();

	if (! -f $home ."/.config/vm_control/") {
		#TODO: replace so user owns it
		mkdir "$home/.config/vm_control/", 0755;
	}

	open(my $ID_LOG, '>>', "$log_file")
	 or die "Could not open file $log_file: $!\n";

	print $ID_LOG "======$date======$job======\n";
	close($ID_LOG);
	system("vagrant $job $vm 1>>$log_file");
}

#start all tracked vagrant boxes of a user
#@vm_user: vagrant boxes of this user will be started
#TODO: check if vm_user is in user file to avoid exploits
sub start_vms {
	my $user = shift;
	my @vms;
	my $forks;
	my $home_dir = File::HomeDir->users_home("$user");

	open(my $BOX_CFG, "<", "$home_dir/.config/vm_control/$user" ."_box.cfg")
	 or die "Could not open $home_dir/.config/vm_control/$user" ."_box.cfgi: $!\n";

	while (<$BOX_CFG>) {
		push(@vms,$_);
	}

	for my $vm (@vms) {
		my $pid = fork();

		if (not defined $pid) {
			print "Could not fork $!\n";
		}

		if (! $pid) {
			&job_control($vm, "up");
			exit;
		} else {
			$forks++;
		}
	}

	for (1 .. $forks) {
		my $pid = wait();
	}
}

#suspend all boxes of a user that are in the list
#if they are not in the list halt them
#@vm_user: vagrant boxes of this user will be stopped
sub stop_vms {
	my $user = shift;
	my @vgs_line, my @ids;
	my $id = 0;
	my $i = 0;
	my $state = 3;
	my %vms;
	my $datetime;
	my @suspend, my @halt;
	my $home_dir = File::HomeDir->users_home("$user");

	print"stopping boxes of $user\n";
	open(my $VGS, "vagrant global-status |")
	 or die "Failed to run vagrant global-status: $!\n";

	#get state and id of vagrant boxes
	 while(<$VGS>) {
		next if /^\-*$/ || /id/;
		last if /^$/ || /^\s*$/;
		@vgs_line = split;

		push(@ids, $vgs_line[$id]);
		$vms{$ids[$i]} = $vgs_line[$state];
		$i++;
	}

	#check if box should be suspended or halted
	open(my $CFG_FILE, '<', "$home_dir/.config/vm_control/$user" ."_box.cfg")
	 or die "Could not open $home_dir/.config/vm_control/$user" ."_box.cfg";
	for my $box_id (@ids) {
		my $match = 0;
		while(<$CFG_FILE>) {
			if($_ eq $box_id) {
				push (@suspend, $box_id);
				$match = 1;
				last;
			}
		}
		if(! $match) {
			push(@halt, $box_id);
		}
	}

	#create a child process for each vagrant box in suspend
	for my $vm (@suspend) {
		my $pid = fork();

		if(not defined $pid) {
			print "could not fork\n";
		}
		if(!$pid) {
			&job_control($vm, "suspend");
		}
	}

	#create a child process for each vagrant box in halt
	for my $vm (@halt) {
		my $pid = fork();

		if(not defined $pid) {
			print "could not fork\n";
		}
		if(!$pid) {
			&job_control($vm, "halt");
		}
	}
}

sub get_boxes {
	#get all boxes to stop
	#put them in halt and suspend array
}

#write user to config file
#A List of all users monitored by this program will be
#created.
#@user: write this user to config
sub write_user {
	my $user = shift;
	my $file_name = "$cfg_dir" ."user_cfg";

	print "user in write_user(): $user\n" if ($debug);

	if ( ! -f $file_name) {
		print "$file_name does not exist -> creating...\n";
		my $ret = `touch $file_name`;
		if ($ret) {
			print "touch returned $ret\n";
			die "something went wrong\n";
		}
	}
	open(my $USR_CFG, '<:encoding(UTF-8)', "$file_name")
	 or die "Could not open file $file_name $!\n";
	while(my $known_user = <$USR_CFG>) {
		if ($known_user) {
			chomp($known_user);
		}
		if($known_user eq "$user") {
			close($USR_CFG);
			return 0;
		}
	}
	close($USR_CFG);
	open ($USR_CFG, '>>', "$file_name")
	 or die "could not open file $file_name: $!\n";
	print $USR_CFG $user ."\n";
	close($USR_CFG);
	&create_units($user);
}

#check if .vm_control directory exists in users home directory
#@user: check home directory of this user
sub check_home_directory {
	my $user = shift;
	my $user_dir = File::HomeDir->users_home("$user") ."/.config/vm_control";

	if (! -d $user_dir) {
		my $ret = qx{"su" "-c" "mkdir -m755 $user_dir ; touch $user_dir/config" "$user"}
	}
}

#write boxes for a user to its config file
#@user write vagrant boxes of this user to files
sub write_boxes {
	my $user = $_[0];
	my $all = 0;
	my @boxes;

	if ($_[2]) {
		$all = $_[1];
		@boxes = @{$_[2]};
	} else {
		@boxes = @{$_[1]};
	}
	print "in write boxes user: $user, all: $all, boxes: @boxes\n" if ($debug);
	my $home_dir = File::HomeDir->users_home("$user");
	my $file_name = "$home_dir/.config/vm_control/$user" ."_box.cfg";

	&check_home_directory($user);
	if ($all) {
		&get_boxes();
		return 0;
	}
	if (! -f $file_name) {
		open( my $CFG_FILE, '>>', $file_name)
		 or die "Could not open file $file_name $!\n";
		for my $box (@boxes) {
			print "writing $box to $file_name\n";
			print $CFG_FILE $box . "\n";
		}
		close($CFG_FILE);
	} else {
		#TODO: check if box is already in config
		open( my $CFG_FILE, '>>', $file_name)
		 or die "Could not open file $file_name $!\n";
		for my $box (@boxes) {
			print $CFG_FILE $box . "\n";
		}
		close($CFG_FILE);
	}
}

#check if config directory exists
sub check_directory {
	my $user = $_[0];
	my $all = $_[1];
	my @boxes = @{$_[2]};
	
	print "checking if $cfg_dir exists\n";
	if ( -d $cfg_dir ) {
		&write_user($user);
		&write_boxes($user, \@boxes);
	} else {
		print "directory does not exist - creating it\n";
		mkdir $cfg_dir, 0755
		 or die "could not create $cfg_dir: $!\n";
		&write_user($user);
		&write_boxes($user, \@boxes);
	}
}

#print help
sub help {
	print "Usage [option] <arguments> {[option] <argument>}\n";
	print "\n";
	print "Options:\n";
	print "\t--user <username> \tmonitor Vagrant boxes of this user\n";
	print "\t--box <vagrant_id>... \tmonitor the Vagrant Boxes with theses IDs\n";
	print "\t--help | --h \tshow this help\n";
	print "\t--debug \t show debug output\n";
	print "\n";
}

#read command line input
#@ARGV: input from caller
#	start <user>: start boxes of user
#	stop <user>: suspend/halt boxes of user
#	user: followed by user to add to vm_control
#	box: followed by id(s) of boxes to add, no id means all boxes
#	help: calls help function
sub get_input {
	my $help = 0;
	my $man = 0;
	my $start_user, my $stop_user, my $user;
	my $all = 0;
	my @boxes;

	GetOptions(	'start=s'	=> \$start_user,
			'stop=s'	=> \$stop_user,
			'user=s'	=> \$user,
			'box=s{,}'	=> \@boxes,
			'help|h|?'	=> \$help,
			'all'		=> \$all,
			'debug'		=> \$debug)
	 or pod2usage(2);
 	pod2usage(1) if $help;
	pod2usage(-exitval => 0, -verbose => 2) if $man;

	print "user: $user\n";
	if ($start_user) {
		&start_boxes($start_user);
	} elsif ($stop_user) {
		&stop_boxes($stop_user);
	} elsif ($user) {
		&check_directory($user, $all, \@boxes);
	} else {
		&help();
	}
}
&get_input(@ARGV);

=head1 NAME
	sample - Using Getopt::Long and Pod::Usage
=head1 SYNOPSIS
	sample [options] [file ...]
	 Options:
	   -help            brief help message
	   -man             full documentation
=head1 OPTIONS
=over 8
=item B<-help>
	Print a brief help message and exits.
=item B<-man>
	Prints the manual page and exits.
	=back
=head1 DESCRIPTION
	B<This program> will read the given input file(s) and do something
	useful with the contents thereof.
=cut

