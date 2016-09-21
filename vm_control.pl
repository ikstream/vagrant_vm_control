#!/usr/bin/perl

# Copyright (c) 2016 Stefan Venz
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

#TODO: provide option to add all vagrant boxes of a user
#TODO: reduce number of global variables
#TODO: filter input to do start and stop jobs
#TODO: check if box is already in file
#TODO: separate array for suspend and halt queue
#TODO: Fork on start and shutdown
#TODO: write vagrant outpu to individual logfiles
#TODO: print debug output to logfile or journalctl

use strict;
use warnings;

use File::HomeDir;

my $user;
my @boxes, my @suspend, my @halt;
my $cfg_dir = '/etc/vm_control/';

#enable and start systemd units for each user
#@param unit file: systemd unit to start and enable
sub enable_unit {
	print "enabling systemd unit @_\n";
	my $ret = `systemctl enable @_`;
	print "something went wrong: systemd returned $ret" if ($ret);

	print "starting systemd unit @_\n";
	$ret = `systemctl start @_`;
	print "something went wrong: systemd returned $ret" if ($ret);
}

#create systemd units for each user monitored
#@param user: start/stop vagrant boxes of this user
sub create_units {
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
	print $STOP_FILE "Type=forking\n"
	print $STOP_FILE "RemainAfterExit=yes\n";
	print $STOP_FILE "ExecStop=/usr/local/bin/vm_control.pl stop $user\n";
	print $STOP_FILE "\n";
	print $STOP_FILE "[Install]\n";
	print $STOP_FILE "WantedBy=mutli-user.target\n";
	close($STOP_FILE);

	&enable_unit($stop_file);
}

#run vagrant halt/suspend/up on given vagrant box and write to log
#@param vm: vagrant box to run vagrant command on
#@param job: command to run. should be halt/suspend/up
#TODO: probably check job parameter for correctness
sub job_control {
	(my $vm, my $job) = @_;
	my $home = File::HomeDir->my_home;
	my $log_file = $home ."/.vm_control/$vm" .".log";
	my $date = localtime();

	if (! -f $home ."/.vm_control/") {
		mkdir "$home/.vm_control", 0755;
	}

	open(my $ID_LOG, '>>', "$log_file")
	 or die "Could not open file $log_file: $!\n";

	print $ID_LOG "======$date======$job======\n";
	close($ID_LOG);
	system("vagrant $job $vm 1>>$log_file");
}

#start all tracked vagrant boxes of a user
#@param vm_user: vagrant boxes of this user will be started
#TODO: check if vm_user is in user file to avoid exploits
sub start_vms {
	my $vm_user = @_;
	my @vms;
	my $forks;

	open(my $BOX_CFG, "<", "$cfg_dir$vm_user" ."_box.cfg")
	 or die "Could not open $cfg_dir$vm_user". "_box.cfg");
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
#@param vm_user: vagrant boxes of this user will be stopped
sub stop_vms {
	my $vm_user = @_;
	my @vgs_line, my @ids;
	my $id = 0;
	my $i = 0;
	my $state = 3;
	my %vms;
	my $datetime;

	print"stopping boxes of @_\n";
	open(my $VGS, "vagrant global-status |")
	 or die "Failed to run vagrant global-status: $!\n";

	#get state and id of vagrant boxes
	 while(<$VGS>) {
		next if /^\-*$/ || /id/;
		last if /^$/ || /^\s*$/;
		@vgs_line = split;

		push(@ids, $vgs_line[$id]);
		$vms{$ids[$i]} = $data[$state];
		$i++;
	}

	#check if box should be suspended or halted
	open(my $CFG_FILE, '<', "$cfg_dir$vm_user" ."_box.cfg")
	 or die "Could not open $cfg_dir$vm_user" ."_box.cfg"
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

#read command line input
#@param ARGV: input from caller
#	start: start boxes of user
#	stop: suspend/halt boxes of user
#	user: user to add to vm_controll
#	boxes: id of boxes to add.
#	help: calls help function
sub get_input {

	#read user
	if ( shift(@ARGV) eq "user" ) {
		$user = shift(@ARGV);
	} else {
		die "username expected\n";
	}

	#read boxes
	if ( shift(@ARGV) eq "box" ) {
		while(@ARGV) {
			push @boxes, shift(@ARGV);
		}
	} else {
		die "wrong input: vagrant id expected\n";
	}
}

#write user to config file
#A List of all users monitored by this program will be
#created.
sub write_user {
	my $file_name = "$cfg_dir" ."user_cfg";

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
	while(chomp(my $known_user = <$USR_CFG>)) {
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

#write boxes for a user to its config file
sub write_boxes {
	my $file_name = "$cfg_dir$user" ."_box.cfg";

	if (! -f $file_name) {
		open( my $CFG_FILE, '>>', $file_name)
		 or die "Could not open file $file_name $!\n";
		for (@boxes) {
			print $CFG_FILE $_ . "\n";
		}
		close($CFG_FILE);
	} else {
		open(my $CFG_FILE, '<', $file_name)
		 or die "Could not open file $file_name $!\n";
		close($CFG_FILE);
	}
}

#check if config directory exists
sub check_directory {

	print "checking if $cfg_dir exists\n";
	if ( -d $cfg_dir ) {
		&write_user();
		&write_boxes();
	} else {
		print "directory does not exist - creating it\n";
		mkdir $cfg_dir, 0755
		 or die "could not create $cfg_dir: $!\n";
		&write_user();
		&write_boxes();
	}
}

&get_input(@ARGV);

