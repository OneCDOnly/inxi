#!/usr/bin/env perl
## infobash: Copyright (C) 2005-2007  Michiel de Boer aka locsmif
## inxi: Copyright (C) 2008-2020 Harald Hope
##       Additional features (C) Scott Rogers - kde, cpu info
## Further fixes (listed as known): Horst Tritremmel <hjt at sidux.com>
## Steven Barrett (aka: damentz) - usb audio patch; swap percent used patch
## Jarett.Stevens - dmidecode -M patch for older systems with the /sys
##
## License: GNU GPL v3 or greater
##
## You should have received a copy of the GNU General Public License
## along with this program.  If not, see <http://www.gnu.org/licenses/>.
##
## If you don't understand what Free Software is, please read (or reread)
## this page: http://www.gnu.org/philosophy/free-sw.html

use strict;
use warnings;
# use diagnostics;
use 5.008;

## Perl 7 things for testing: depend on Perl 5.032
# use 5.032
# use compat::perl5;  # act like Perl 5's defaults
# no feature qw(indirect);
# no multidimensional;
# no bareword::filehandle;

use Cwd qw(abs_path); # #abs_path realpath getcwd
use Data::Dumper qw(Dumper); # print_r
use File::Find;
use File::stat; # needed for Xorg.0.log file mtime comparisons
use Getopt::Long qw(GetOptions);
# Note: default auto_abbrev is enabled
Getopt::Long::Configure ('bundling', 'no_ignore_case', 
'no_getopt_compat', 'no_auto_abbrev','pass_through');
use POSIX qw(uname strftime ttyname);
# use feature qw(state);

## INXI INFO ##
my $self_name='inxi';
my $self_version='3.1.09';
my $self_date='2020-11-11';
my $self_patch='00';
## END INXI INFO ##

### INITIALIZE VARIABLES ###

## Self data
my ($self_path, $user_config_dir, $user_config_file,$user_data_dir);

## Debuggers
my $debug=0;
my (@t0,$end,$start,$fh_l,$log_file); # log file handle, file
my ($b_hires,$t1,$t2,$t3) = (0,0,0,0);
# NOTE: redhat removed HiRes from Perl Core Modules. 
if (eval {require Time::HiRes}){
	Time::HiRes->import('gettimeofday','tv_interval','usleep');
	$b_hires = 1;
}
@t0 = eval 'Time::HiRes::gettimeofday()' if $b_hires; # let's start it right away
## Hashes
my (%alerts,%build_prop,%client,%colors,%debugger,%dl,%files,%program_values,
%rows,%sensors_raw,%system_files);

## Arrays
# ps_aux is full output, ps_cmd is only the last 10 columns to last
my (@app,@dmesg_boot,@devices_audio,@devices_graphics,@devices_network,
@devices_hwraid,@devices_timer,@dmi,@gpudata,@ifs,@ifs_bsd,
@paths,@proc_partitions,@ps_aux,@ps_cmd,@ps_gui,@sensors_exclude,@sensors_use,
@sysctl,@sysctl_battery,@sysctl_sensors,@sysctl_machine,@uname,@usb);
## Disk arrays 
my (@dm_boot_disk,@dm_boot_optical,@glabel,@gpart,@hardware_raid,@labels,
@lsblk,@partitions,@raid,@sysctl_disks,@swaps,@uuids);
my @test = (0,0,0,0,0);

## Booleans
my ($b_admin,$b_arm,$b_bb_ps,$b_block_tool,$b_build_prop,
$b_display,$b_dmesg_boot_check,$b_dmi,$b_dmidecode_force,
$b_fake_bsd,$b_fake_dboot,$b_fake_dmidecode,$b_fake_pciconf,$b_fake_sysctl,
$b_fake_usbdevs,$b_force_display,$b_gpudata,$b_irc,
$b_log,$b_log_colors,$b_log_full,$b_man,$b_mem,$b_no_html_wan,$b_mips,$b_no_sudo,
$b_pci,$b_pci_tool,$b_pkg,$b_ppc,$b_proc_partitions,$b_ps_gui,
$b_root,$b_running_in_display,$b_sensors,$b_skip_dig,
$b_slot_tool,$b_soc_audio,$b_soc_gfx,$b_soc_net,$b_soc_timer,$b_sparc,
$b_swaps,$b_sysctl,$b_usb,$b_usb_check,$b_usb_sys,$b_usb_tool,
$b_wmctrl);
## Disk checks
my ($b_dm_boot_disk,$b_dm_boot_optical,$b_glabel,$b_hardware_raid,
$b_label_uuid,$b_lsblk,$b_partitions,$b_raid,$b_smartctl);
# initialize basic use features
my %use = (
'sysctl_disk' => 1, # unused currently
'update' => 1, # switched off/on with maintainer config ALLOW_UPDATE
'weather' => 1, # switched off/on with maintainer config ALLOW_WEATHER
);
## System
my ($bsd_type,$device_vm,$language,$os,$pci_tool,$wan_url) = ('','','','','','');
my ($bits_sys,$cpu_arch);
my ($cpu_sleep,$dl_timeout,$limit,$ps_cols,$ps_count) = (0.35,4,10,0,5);
my $sensors_cpu_nu = 0;
my ($dl_ua,$weather_source,$weather_unit) = ('s-tools/' . $self_name  . '-',100,'mi');
## Tools
my ($display,$ftp_alt,$tty_session);
my ($display_opt,$sudo) = ('','');

## Output
my $extra = 0;# supported values: 0-3
my $filter_string = '<filter>';
my $line1 = "----------------------------------------------------------------------\n";
my $line2 = "======================================================================\n";
my $line3 = "----------------------------------------\n";
my ($output_file,$output_type) = ('','screen');
my $prefix = 0; # for the primiary row hash key prefix

# these will assign a separator to non irc states. Important! Using ':' can 
# trigger stupid emoticon. Note: SEP1/SEP2 from short form not used anymore.
# behaviors in output on IRC, so do not use those.
my %sep = ( 
's1-irc' => ':',
's1-console' => ':',
's2-irc' => '',
's2-console' => ':',
);
my %show;
#$show{'host'} = 1;
my %size = (
'console' => 115,
# Default indentation level. NOTE: actual indent is 1 greater to allow for 
# spacing
'indent' => 11,
'indent-min' => 90,
'irc' => 100, # shorter because IRC clients have nick  lists etc
'max' => 0,
'no-display' => 130,
# these will be set dynamically in set_display_width()
'term' => 80,
'term-lines' => 100,
);

## debug / temp tools
$debugger{'sys'} = 1;
$client{'test-konvi'} = 0;

########################################################################
#### STARTUP
########################################################################

#### -------------------------------------------------------------------
#### MAIN
#### -------------------------------------------------------------------

sub main {
# 	print Dumper \@ARGV;
	eval $start if $b_log;
	initialize();
	## Uncomment these two values for start client debugging
	# $debug = 3; # 3 prints timers / 10 prints to log file
	# set_debugger(); # for debugging of konvi and other start client issues
	## legacy method
	#my $ob_start = StartClient->new();
	#$ob_start->get_client_data();
	StartClient::get_client_data();
	# print_line( Dumper \%client);
	get_options();
	set_debugger(); # right after so it's set
	check_tools();
	set_colors();
	set_sep();
	# print download_file('stdout','https://') . "\n";
	generate_lines();
	eval $end if $b_log;
	cleanup();
	# weechat's executor plugin forced me to do this, and rightfully so, 
	# because else the exit code from the last command is taken..
	exit 0;
}

#### -------------------------------------------------------------------
#### INITIALIZE
#### -------------------------------------------------------------------

sub initialize {
	set_os();
	set_path();
	set_user_paths();
	set_basics();
	system_files('set');
	get_configs();
	# set_downloader();
	set_display_width('live');
}

sub check_tools {
	my ($action,$program,$message,@data,%commands,%hash);
	if ( $b_dmi ){
		$action = 'use';
		if ($program = check_program('dmidecode')) {
			@data = grabber("$program -t chassis -t baseboard -t processor 2>&1");
			if (scalar @data < 15){
				if ($b_root) {
					foreach (@data){
						if ($_ =~ /No SMBIOS/i){
							$action = 'smbios';
							last;
						}
						elsif ($_ =~ /^\/dev\/mem: Operation/i){
							$action = 'no-data';
							last;
						}
						else {
							$action = 'unknown-error';
							last;
						}
					}
				}
				else {
					if (grep { $_ =~ /^\/dev\/mem: Permission/i } @data){
						$action = 'permissions';
					}
					else {
						$action = 'unknown-error';
					}
				}
			}
		}
		else {
			$action = 'missing';
		}
		%hash = (
		'dmidecode' => {
		'action' => $action,
		'missing' => row_defaults('tool-missing-required','dmidecode'),
		'permissions' => row_defaults('tool-permissions','dmidecode'),
		'smbios' => row_defaults('dmidecode-smbios'),
		'no-data' => row_defaults('dmidecode-dev-mem'),
		'unknown-error' => row_defaults('tool-unknown-error','dmidecode'),
		},
		);
		%alerts = (%alerts, %hash);
	}
	# note: gnu/linux has sysctl so it may be used that for something if present
	# there is lspci for bsds so doesn't hurt to check it
	if ($b_pci || $b_sysctl){
		if (!$bsd_type){
			if ($b_pci ){
				%hash = ('lspci' => '-n',);
				%commands = (%commands,%hash);
			}
		}
		else {
			if ($b_pci ){
				%hash = ('pciconf' => '-l','pcictl' => 'list', 'pcidump' => '');
				%commands = (%commands,%hash);
			}
			if ($b_sysctl ){
				# note: there is a case of kernel.osrelease but it's a linux distro
				%hash = ('sysctl' => 'kern.osrelease',);
				%commands = (%commands,%hash);
			}
		}
		foreach ( keys %commands ){
			$action = 'use';
			if ($program = check_program($_)) {
				# > 0 means error in shell
				#my $cmd = "$program $commands{$_} >/dev/null";
				#print "$cmd\n";
				$pci_tool = $_ if $_ =~ /pci/;
				$action = 'permissions' if system("$program $commands{$_} >/dev/null 2>&1");
			}
			else {
				$action = 'missing';
			}
			%hash = (
			$_ => {
			'action' => $action,
			'missing' => row_defaults('tool-missing-incomplete',"$_"),
			'permissions' => row_defaults('tool-permissions',"$_"),
			},
			);
			%alerts = (%alerts, %hash);
		}
	}
	%commands = ();
	if ( $show{'sensor'} ){
		%commands = ('sensors' => 'linux',);
	}
	# note: lsusb ships in FreeBSD ports sysutils/usbutils
	if ( $b_usb ){
		%hash = ('lsusb' => 'all',);
		%commands = (%commands,%hash);
		%hash = ('usbdevs' => 'bsd',);
		%commands = (%commands,%hash);
	}
	if ($show{'ip'} || ($bsd_type && $show{'network-advanced'})){
		%hash = (
		'ip' => 'linux',
		'ifconfig' => 'all',
		);
		%commands = (%commands,%hash);
	}
	# can't check permissions since we need to know the partition/disc
	if ($b_block_tool){
		%hash = (
		'blockdev' => 'linux',
		'lsblk' => 'linux',
		);
		%commands = (%commands,%hash);
	}
	if ($b_smartctl){
		%hash = (
		'smartctl' => 'all',
		);
		%commands = (%commands,%hash);
	}
	foreach ( keys %commands ){
		$action = 'use';
		$message = row_defaults('tool-present');
		if ( ($commands{$_} eq 'linux' && $os ne 'linux' ) || ($commands{$_} eq 'bsd' && $os eq 'linux' ) ){
			$message = row_defaults('tool-missing-os', ucfirst($os) . " $_");
			$action = 'platform';
		}
		elsif (!check_program($_)){
			$message = row_defaults('tool-missing-recommends',"$_");
			$action = 'missing';
		}
		%hash = (
		$_ => {
		'action' => $action,
		'missing' => $message,
		'platform' => $message,
		},
		);
		%alerts = (%alerts, %hash);
	}
	# print Dumper \%alerts;
	set_fake_tools() if $b_fake_bsd;
}
# args: 1 - desktop/app command for --version; 2 - search string; 
# 3 - space print number; 4 - [optional] version arg: -v, version, etc
# 5 - [optional] exit first find 0/1; 6 - [optional] 0/1 stderr output
sub set_basics {
	### LOCALIZATION - DO NOT CHANGE! ###
	# set to default LANG to avoid locales errors with , or .
	# Make sure every program speaks English.
	$ENV{'LANG'}='C';
	$ENV{'LC_ALL'}='C';
	# remember, perl uses the opposite t/f return as shell!!!
	# some versions of busybox do not have tty, like openwrt
	$b_irc = ( check_program('tty') && system('tty >/dev/null') ) ? 1 : 0;
	# print "birc: $b_irc\n";
	$b_display = ( $ENV{'DISPLAY'} ) ? 1 : 0;
	$b_root = $< == 0; # root UID 0, all others > 0
	$dl{'dl'} = 'curl';
	$dl{'curl'} = 1;
	$dl{'tiny'} = 1; # note: two modules needed, tested for in set_downloader
	$dl{'wget'} = 1;
	$dl{'fetch'} = 1;
	$client{'console-irc'} = 0;
	$client{'dcop'} = (check_program('dcop')) ? 1 : 0;
	$client{'qdbus'} = (check_program('qdbus')) ? 1 : 0;
	$client{'konvi'} = 0;
	$client{'name'} = '';
	$client{'name-print'} = '';
	$client{'su-start'} = ''; # shows sudo/su
	$client{'version'} = '';
	$colors{'default'} = 2;
	$show{'partition-sort'} = 'id'; # sort order for partitions
}

# args: $1 - default OR override default cols max integer count. $_[0]
# is the display width override.
sub set_display_width {
	my ($width) = @_;
	if ( $width eq 'live' ){
		## sometimes tput will trigger an error (mageia) if irc client
		if ( ! $b_irc ){
			if ( check_program('tput') ) {
				# trips error if use qx()...
				chomp($size{'term'}=qx{tput cols});
				chomp($size{'term-lines'}=qx{tput lines});
				$size{'term-cols'} = $size{'term'};
			}
			# print "tc: $size{'term'} cmc: $size{'console'}\n";
			# double check, just in case it's missing functionality or whatever
			if ( $size{'term'} == 0 || !is_int($size{'term'}) ){ 
				$size{'term'}=80;
				# we'll be using this for terminal dimensions later so don't set default.
				# $size{'term-lines'}=100;
			}
		}
		# this lets you set different size for in or out of display server
		if ( ! $b_running_in_display && $size{'no-display'} ){
			$size{'console'}=$size{'no-display'};
		}
		# term_cols is set in top globals, using tput cols
		# print "tc: $size{'term'} cmc: $size{'console'}\n";
		if ( $size{'term'} < $size{'console'} ){
			$size{'console'}=$size{'term'};
		}
		# adjust, some terminals will wrap if output cols == term cols
		$size{'console'}=( $size{'console'} - 2 );
		# echo cmc: $size{'console'}
		# comes after source for user set stuff
		if ( ! $b_irc ){
			$size{'max'}=$size{'console'};
		}
		else {
			$size{'max'}=$size{'irc'};
		}
	}
	else {
		$size{'max'}=$width;
	}
	# print "tc: $size{'term'} cmc: $size{'console'} cm: $size{'max'}\n";
}

# only for dev/debugging BSD 
sub set_fake_tools {
	$system_files{'dmesg-boot'} = '/var/run/dmesg.boot' if $b_fake_dboot;
	$alerts{'pciconf'} = ({'action' => 'use'}) if $b_fake_pciconf;
	$alerts{'sysctl'} = ({'action' => 'use'}) if $b_fake_sysctl;
	if ($b_fake_usbdevs ){
		$alerts{'usbdevs'} = ({'action' => 'use'});
		$alerts{'lsusb'} = ({
		'action' => 'missing',
		'missing' => 'Required program lsusb not available',
		});
	}
}

# NOTE: most tests internally are against !$bsd_type
sub set_os {
	@uname = uname();
	$os = lc($uname[0]);
	$cpu_arch = lc($uname[-1]);
	if ($cpu_arch =~ /arm|aarch/){$b_arm = 1}
	elsif ($cpu_arch =~ /mips/) {$b_mips = 1}
	elsif ($cpu_arch =~ /power|ppc/) {$b_ppc = 1}
	elsif ($cpu_arch =~ /sparc/) {$b_sparc = 1}
	# aarch32 mips32 intel/amd handled in cpu
	if ($cpu_arch =~ /(armv[1-7]|32|sparc_v9)/){
		$bits_sys = 32;
	}
	elsif ($cpu_arch =~ /(alpha|64|e2k)/){
		$bits_sys = 64;
	}
	if ( $os =~ /(aix|bsd|cosix|dragonfly|darwin|hp-?ux|indiana|irix|sunos|solaris|ultrix|unix)/ ){
		if ( $os =~ /openbsd/ ){
			$os = 'openbsd';
		}
		elsif ($os =~ /darwin/){
			$os = 'darwin';
		}
		if ($os =~ /kfreebsd/){
			$bsd_type = 'debian-bsd';
		}
		else {
			$bsd_type = $os;
		}
	}
}

# This data is hard set top of program but due to a specific project's
# foolish idea that ignoring the FSH totally is somehow a positive step
# forwards for free software, we also have to padd the results with PATH.
sub set_path {
	# Extra path variable to make execute failures less likely, merged below
	my (@path);
	# NOTE: recent Xorg's show error if you try /usr/bin/Xorg -version but work 
	# if you use the /usr/lib/xorg-server/Xorg path.
	@paths = qw(/sbin /bin /usr/sbin /usr/bin /usr/local/sbin /usr/local/bin);
	@path = split /:/, $ENV{'PATH'} if $ENV{'PATH'};
	# print "paths: @paths\nPATH: $ENV{'PATH'}\n";
	# Create a difference of $PATH and $extra_paths and add that to $PATH:
	foreach my $id (@path) {
		if ( !(grep { /^$id$/ } @paths) && $id !~ /(game)/ ){
			push @paths, $id;
		}
	}
	# print "paths: @paths\n";
}

sub set_sep {
	if ( $b_irc ){
		# too hard to read if no colors, so force that for users on irc
		if ($colors{'scheme'} == 0 ){
			$sep{'s1'} = $sep{'s1-console'};
			$sep{'s2'} = $sep{'s2-console'};
		}
		else {
			$sep{'s1'} = $sep{'s1-irc'};
			$sep{'s2'} = $sep{'s2-irc'};
		}
	}
	else {
		$sep{'s1'} = $sep{'s1-console'};
		$sep{'s2'} = $sep{'s2-console'};
	}
}

# Important: -n makes it non interactive, no prompt for password
# only use sudo if not root, -n option requires sudo -V 1.7 or greater. 
# for some reason sudo -n with < 1.7 in Perl does not print to stderr
# sudo will just error out which is the safest course here for now,
# otherwise that interactive sudo password thing is too annoying
sub set_sudo {
	if (!$b_root && !$b_no_sudo && (my $path = check_program('sudo'))) {
		my @data = program_data('sudo');
		$data[1] =~ s/^([0-9]+\.[0-9]+).*/$1/;
		#print "sudo v: $data[1]\n";
		$sudo = "$path -n " if is_numeric($data[1]) && $data[1] >= 1.7;
	}
}

sub set_user_paths {
	my ( $b_conf, $b_data );
	# this needs to be set here because various options call the parent 
	# initialize function directly.
	$self_path = $0;
	$self_path =~ s/[^\/]+$//;
	# print "0: $0 sp: $self_path\n";
	
	if ( defined $ENV{'XDG_CONFIG_HOME'} && $ENV{'XDG_CONFIG_HOME'} ){
		$user_config_dir=$ENV{'XDG_CONFIG_HOME'};
		$b_conf=1;
	}
	elsif ( -d "$ENV{'HOME'}/.config" ){
		$user_config_dir="$ENV{'HOME'}/.config";
		$b_conf=1;
	}
	else {
		$user_config_dir="$ENV{'HOME'}/.$self_name";
	}
	if ( defined $ENV{'XDG_DATA_HOME'} && $ENV{'XDG_DATA_HOME'} ){
		$user_data_dir="$ENV{'XDG_DATA_HOME'}/$self_name";
		$b_data=1;
	}
	elsif ( -d "$ENV{'HOME'}/.local/share" ){
		$user_data_dir="$ENV{'HOME'}/.local/share/$self_name";
		$b_data=1;
	}
	else {
		$user_data_dir="$ENV{'HOME'}/.$self_name";
	}
	# note, this used to be created/checked in specific instance, but we'll just do it
	# universally so it's done at script start.
	if ( ! -d $user_data_dir ){
		mkdir $user_data_dir;
		# system "echo", "Made: $user_data_dir";
	}
	if ( $b_conf && -f "$ENV{'HOME'}/.$self_name/$self_name.conf" ){
		#system 'mv', "-f $ENV{'HOME'}/.$self_name/$self_name.conf", $user_config_dir;
		# print "WOULD: Moved $self_name.conf from $ENV{'HOME'}/.$self_name to $user_config_dir\n";
	}
	if ( $b_data && -d "$ENV{'HOME'}/.$self_name" ){
		#system 'mv', '-f', "$ENV{'HOME'}/.$self_name/*", $user_data_dir;
		#system 'rm', '-Rf', "$ENV{'HOME'}/.$self_name";
		# print "WOULD: Moved data dir $ENV{'HOME'}/.$self_name to $user_data_dir\n";
	}
	$log_file="$user_data_dir/$self_name.log";
	#system 'echo', "$ENV{'HOME'}/.$self_name/* $user_data_dir";
	# print "scd: $user_config_dir sdd: $user_data_dir \n";
}

# args: 1: set|hash key to return either null or path
sub system_files {
	my ($file) = @_;
	if ( $file eq 'set'){
		%files = (
		'asound-cards' => '/proc/asound/cards',
		'asound-modules' => '/proc/asound/modules',
		'asound-version' => '/proc/asound/version',
		'cmdline' => '/proc/cmdline',
		'cpuinfo' => '/proc/cpuinfo',
		'dmesg-boot' => '/var/run/dmesg.boot',
		'lsb-release' => '/etc/lsb-release',
		'mdstat' => '/proc/mdstat',
		'meminfo' => '/proc/meminfo',
		'modules' => '/proc/modules',
		'mounts' => '/proc/mounts',
		'os-release' => '/etc/os-release',
		'partitions' => '/proc/partitions',
		'scsi' => '/proc/scsi/scsi',
		'version' => '/proc/version',
		# note: 'xorg-log' is set only if -G is triggered
		);
		foreach ( keys %files ){
			$system_files{$_} = ( -e $files{$_} ) ? $files{$_} : '';
		}
	}
	else {
		return $system_files{$file};
	}
}
sub set_xorg_log {
	eval $start if $b_log;
	my (@temp,@x_logs);
	my ($file_holder,$time_holder,$x_mtime) = ('',0,0);
	# NOTE: other variations may be /var/run/gdm3/... but not confirmed
	# we are just going to get all the Xorg logs we can find, and not worry about 
	# which is 'right'.
	@temp = globber('/var/log/Xorg.*.log');
	push @x_logs, @temp if @temp;
	@temp = globber('/var/lib/gdm/.local/share/xorg/Xorg.*.log');
	push @x_logs, @temp if @temp;
	@temp = globber($ENV{'HOME'} . '/.local/share/xorg/Xorg.*.log',);
	push @x_logs, @temp if @temp;
	# root will not have a /root/.local/share/xorg directory so need to use a 
	# user one if we can find one.
	if ($b_root){
		@temp = globber('/home/*/.local/share/xorg/Xorg.*.log');
		push @x_logs, @temp if @temp;
	}
	foreach (@x_logs){
		if (-r $_){
			my $src_info = File::stat::stat("$_");
			#print "$_\n";
			if ($src_info){
				$x_mtime = $src_info->mtime;
				# print $_ . ": $x_time" . "\n";
				if ($x_mtime > $time_holder ){
					$time_holder = $x_mtime;
					$file_holder = $_;
				}
			}
		}
	}
	if ( !$file_holder && check_program('xset') ){
		my $data = qx(xset q 2>/dev/null);
		foreach ( split /\n/, $data){
			if ($_ =~ /Log file/i){
				$file_holder = get_piece($_,3);
				last;
			}
		}
	}
	print "Xorg log file: $file_holder\nLast modified: $time_holder\n" if $test[14];
	log_data('data',"Xorg log file: $file_holder") if $b_log;
	$system_files{'xorg-log'} = $file_holder;
	eval $end if $b_log;
}

########################################################################
#### UTILITIES
########################################################################

#### -------------------------------------------------------------------
#### COLORS
#### -------------------------------------------------------------------

## arg: 1 - the type of action, either integer, count, or full
sub get_color_scheme {
	my ($type) = @_;
	eval $start if $b_log;
	my @color_schemes = (
	[qw(EMPTY EMPTY EMPTY )],
	[qw(NORMAL NORMAL NORMAL )],
	# for dark OR light backgrounds
	[qw(BLUE NORMAL NORMAL)],
	[qw(BLUE RED NORMAL )],
	[qw(CYAN BLUE NORMAL )],
	[qw(DCYAN NORMAL NORMAL)],
	[qw(DCYAN BLUE NORMAL )],
	[qw(DGREEN NORMAL NORMAL )],
	[qw(DYELLOW NORMAL NORMAL )],
	[qw(GREEN DGREEN NORMAL )],
	[qw(GREEN NORMAL NORMAL )],
	[qw(MAGENTA NORMAL NORMAL)],
	[qw(RED NORMAL NORMAL)],
	# for light backgrounds
	[qw(BLACK DGREY NORMAL)],
	[qw(DBLUE DGREY NORMAL )],
	[qw(DBLUE DMAGENTA NORMAL)],
	[qw(DBLUE DRED NORMAL )],
	[qw(DBLUE BLACK NORMAL)],
	[qw(DGREEN DYELLOW NORMAL )],
	[qw(DYELLOW BLACK NORMAL)],
	[qw(DMAGENTA BLACK NORMAL)],
	[qw(DCYAN DBLUE NORMAL)],
	# for dark backgrounds
	[qw(WHITE GREY NORMAL)],
	[qw(GREY WHITE NORMAL)],
	[qw(CYAN GREY NORMAL )],
	[qw(GREEN WHITE NORMAL )],
	[qw(GREEN YELLOW NORMAL )],
	[qw(YELLOW WHITE NORMAL )],
	[qw(MAGENTA CYAN NORMAL )],
	[qw(MAGENTA YELLOW NORMAL)],
	[qw(RED CYAN NORMAL)],
	[qw(RED WHITE NORMAL )],
	[qw(BLUE WHITE NORMAL)],
	# miscellaneous
	[qw(RED BLUE NORMAL )],
	[qw(RED DBLUE NORMAL)],
	[qw(BLACK BLUE NORMAL)],
	[qw(BLACK DBLUE NORMAL)],
	[qw(NORMAL BLUE NORMAL)],
	[qw(BLUE MAGENTA NORMAL)],
	[qw(DBLUE MAGENTA NORMAL)],
	[qw(BLACK MAGENTA NORMAL)],
	[qw(MAGENTA BLUE NORMAL)],
	[qw(MAGENTA DBLUE NORMAL)],
	);
	eval $end if $b_log;
	if ($type eq 'count' ){
		return scalar @color_schemes;
	}
	if ($type eq 'full' ){
		return @color_schemes;
	}
	else {
		return @{$color_schemes[$type]};
		# print Dumper $color_schemes[$scheme_nu];
	}
}

sub set_color_scheme {
	eval $start if $b_log;
	my ($scheme) = @_;
	$colors{'scheme'} = $scheme;
	my $index = ( $b_irc ) ? 1 : 0; # defaults to non irc
	
	# NOTE: qw(...) kills the escape, it is NOT the same as using 
	# Literal "..", ".." despite docs saying it is.
	my %color_palette = (
	'EMPTY' => [ '', '' ],
	'DGREY' => [ "\e[1;30m", "\x0314" ],
	'BLACK' => [ "\e[0;30m", "\x0301" ],
	'RED' => [ "\e[1;31m", "\x0304" ],
	'DRED' => [ "\e[0;31m", "\x0305" ],
	'GREEN' => [ "\e[1;32m", "\x0309" ],
	'DGREEN' => [ "\e[0;32m", "\x0303" ],
	'YELLOW' => [ "\e[1;33m", "\x0308" ],
	'DYELLOW' => [ "\e[0;33m", "\x0307" ],
	'BLUE' => [ "\e[1;34m", "\x0312" ],
	'DBLUE' => [ "\e[0;34m", "\x0302" ],
	'MAGENTA' => [ "\e[1;35m", "\x0313" ],
	'DMAGENTA' => [ "\e[0;35m", "\x0306" ],
	'CYAN' => [ "\e[1;36m", "\x0311" ],
	'DCYAN' => [ "\e[0;36m", "\x0310" ],
	'WHITE' => [ "\e[1;37m", "\x0300" ],
	'GREY' => [ "\e[0;37m", "\x0315" ],
	'NORMAL' => [ "\e[0m", "\x03" ],
	);
	my @scheme = get_color_scheme($colors{'scheme'});
	$colors{'c1'} = $color_palette{$scheme[0]}[$index];
	$colors{'c2'} = $color_palette{$scheme[1]}[$index];
	$colors{'cn'} = $color_palette{$scheme[2]}[$index];
	# print Dumper \@scheme;
	# print "$colors{'c1'}here$colors{'c2'} we are!$colors{'cn'}\n";
	eval $end if $b_log;
}

sub set_colors {
	eval $start if $b_log;
	# it's already been set with -c 0-43
	if ( exists $colors{'c1'} ){
		return 1;
	}
	# This let's user pick their color scheme. For IRC, only shows the color schemes, 
	# no interactive. The override value only will be placed in user config files. 
	# /etc/inxi.conf can also override
	if (exists $colors{'selector'}){
		my $ob_selector = SelectColors->new($colors{'selector'});
		$ob_selector->select_schema();
		return 1;
	}
	# set the default, then override as required
	my $color_scheme = $colors{'default'};
	# these are set in user configs
	if (defined $colors{'global'}){
		$color_scheme = $colors{'global'};
	}
	else {
		if ( $b_irc ){
			if (defined $colors{'irc-virt-term'} && $b_display && $client{'console-irc'}){
				$color_scheme = $colors{'irc-virt-term'};
			}
			elsif (defined $colors{'irc-console'} && !$b_display){
				$color_scheme = $colors{'irc-console'};
			}
			elsif ( defined $colors{'irc-gui'}) {
				$color_scheme = $colors{'irc-gui'};
			}
		}
		else {
			if (defined $colors{'console'} && !$b_display){
				$color_scheme = $colors{'console'};
			}
			elsif (defined $colors{'virt-term'}){
				$color_scheme = $colors{'virt-term'};
			}
		}
	}
	# force 0 for | or > output, all others prints to irc or screen
	if (!$b_irc && ! -t STDOUT ){
		$color_scheme = 0;
	}
	set_color_scheme($color_scheme);
	eval $end if $b_log;
}

## SelectColors
{
package SelectColors;

# use warnings;
# use strict;
# use diagnostics;
# use 5.008;

my (@data,@rows,%configs,%status);
my ($type,$w_fh);
my $safe_color_count = 12; # null/normal + default color group
my $count = 0;

# args: 1 - type
sub new {
	my $class = shift;
	($type) = @_;
	my $self = {};
	return bless $self, $class;
}
sub select_schema {
	eval $start if $b_log;
	assign_selectors();
	main::set_color_scheme(0);
	set_status();
	start_selector();
	create_color_selections();
	if (! $b_irc ){
		main::check_config_file();
		get_selection();
	}
	else {
		print_irc_message();
	}
	eval $end if $b_log;
}

sub set_status {
	$status{'console'} = (defined $colors{'console'}) ? "Set: $colors{'console'}" : 'Not Set';
	$status{'virt-term'} = (defined $colors{'virt-term'}) ? "Set: $colors{'virt-term'}" : 'Not Set';
	$status{'irc-console'} = (defined $colors{'irc-console'}) ? "Set: $colors{'irc-console'}" : 'Not Set';
	$status{'irc-gui'} = (defined $colors{'irc-gui'}) ? "Set: $colors{'irc-gui'}" : 'Not Set';
	$status{'irc-virt-term'} = (defined $colors{'irc-virt-term'}) ? "Set: $colors{'irc-virt-term'}" : 'Not Set';
	$status{'global'} = (defined $colors{'global'}) ? "Set: $colors{'global'}" : 'Not Set';
}

sub assign_selectors {
	if ($type == 94){
		$configs{'variable'} = 'CONSOLE_COLOR_SCHEME';
		$configs{'selection'} = 'console';
	}
	elsif ($type == 95){
		$configs{'variable'} = 'VIRT_TERM_COLOR_SCHEME';
		$configs{'selection'} = 'virt-term';
	}
	elsif ($type == 96){
		$configs{'variable'} = 'IRC_COLOR_SCHEME';
		$configs{'selection'} = 'irc-gui';
	}
	elsif ($type == 97){
		$configs{'variable'} = 'IRC_X_TERM_COLOR_SCHEME';
		$configs{'selection'} = 'irc-virt-term';
	}
	elsif ($type == 98){
		$configs{'variable'} = 'IRC_CONS_COLOR_SCHEME';
		$configs{'selection'} = 'irc-console';
	}
	elsif ($type == 99){
		$configs{'variable'} = 'GLOBAL_COLOR_SCHEME';
		$configs{'selection'} = 'global';
	}
}
sub start_selector {
	my $whoami = getpwuid($<) || "unknown???";
	if ( ! $b_irc ){
		@data = (
		[ 0, '', '', "Welcome to $self_name! Please select the default 
		$configs{'selection'} color scheme."],
		);
	}
	@rows = (
	[ 0, '', '', "Because there is no way to know your $configs{'selection'}
	foreground/background colors, you can set your color preferences from 
	color scheme option list below:"],
	[ 0, '', '', "0 is no colors; 1 is neutral."],
	[ 0, '', '', "After these, there are 4 sets:"],
	[ 0, '', '', "1-dark^or^light^backgrounds; 2-light^backgrounds; 
	3-dark^backgrounds; 4-miscellaneous"],
	[ 0, '', '', ""],
	);
	push @data, @rows;
	if ( ! $b_irc ){
		@rows = (
		[ 0, '', '', "Please note that this will set the $configs{'selection'} 
		preferences only for user: $whoami"],
		);
		push @data, @rows;
	}
	@rows = (
	[ 0, '', '', "$line1"],
	);
	push @data, @rows;
	main::print_basic(@data); 
	@data = ();
}
sub create_color_selections {
	my $spacer = '^^'; # printer removes double spaces, but replaces ^ with ' '
	$count = ( main::get_color_scheme('count') - 1 );
	for my $i (0 .. $count){
		if ($i > 9){
			$spacer = '^';
		}
		if ($configs{'selection'} =~ /^(global|irc-gui|irc-console|irc-virt-term)$/ && $i > $safe_color_count ){
			last;
		}
		main::set_color_scheme($i);
		@rows = (
		[0, '', '', "$i)$spacer$colors{'c1'}Card:$colors{'c2'}^nVidia^GT218 
		$colors{'c1'}Display^Server$colors{'c2'}^x11^(X.Org^1.7.7)$colors{'cn'}"],
		);
		push @data, @rows;
	}
	main::print_basic(@data); 
	@data = ();
	main::set_color_scheme(0);
}
sub get_selection {
	my $number = $count + 1;
	@data = (
	[0, '', '', ($number++) . ")^Remove all color settings. Restore $self_name default."],
	[0, '', '', ($number++) . ")^Continue, no changes or config file setting."],
	[0, '', '', ($number++) . ")^Exit, use another terminal, or set manually."],
	[0, '', '', "$line1"],
	[0, '', '', "Simply type the number for the color scheme that looks best to your 
	eyes for your $configs{'selection'} settings and hit <ENTER>. NOTE: You can bring this 
	option list up by starting $self_name with option: -c plus one of these numbers:"],
	[0, '', '', "94^-^console,^not^in^desktop^-^$status{'console'}"],
	[0, '', '', "95^-^terminal,^desktop^-^$status{'virt-term'}"],
	[0, '', '', "96^-^irc,^gui,^desktop^-^$status{'irc-gui'}"],
	[0, '', '', "97^-^irc,^desktop,^in^terminal^-^$status{'irc-virt-term'}"],
	[0, '', '', "98^-^irc,^not^in^desktop^-^$status{'irc-console'}"],
	[0, '', '', "99^-^global^-^$status{'global'}"],
	[0, '', '',  ""],
	[0, '', '', "Your selection(s) will be stored here: $user_config_file"],
	[0, '', '', "Global overrides all individual color schemes. Individual 
	schemes remove the global setting."],
	[0, '', '', "$line1"],
	);
	main::print_basic(@data); 
	@data = ();
	my $response = <STDIN>;
	chomp $response;
	if (!main::is_int($response) || $response > ($count + 3) ){
		@data = (
		[0, '', '', "Error - Invalid Selection. You entered this: $response. Hit <ENTER> to continue."],
		[0, '', '',  "$line1"],
		);
		main::print_basic(@data); 
		my $response = <STDIN>;
		start_selector();
		create_color_selections();
		get_selection();
	}
	else {
		process_selection($response);
	}
}
sub process_selection {
	my $response = shift;
	if ($response == ($count + 3) ){
		@data = ([0, '', '', "Ok, exiting $self_name now. You can set the colors later."],);
		main::print_basic(@data); 
		exit 0;
	}
	elsif ($response == ($count + 2)){
		@data = (
		[0, '', '', "Ok, continuing $self_name unchanged."],
		[0, '', '',  "$line1"],
		);
		main::print_basic(@data); 
		if ( defined $colors{'console'} && !$b_display ){
			main::set_color_scheme($colors{'console'});
		}
		if ( defined $colors{'virt-term'} ){
			main::set_color_scheme($colors{'virt-term'});
		}
		else {
			main::set_color_scheme($colors{'default'});
		}
	}
	elsif ($response == ($count + 1)){
		@data = (
		[0, '', '', "Removing all color settings from config file now..."],
		[0, '', '',  "$line1"],
		);
		main::print_basic(@data); 
		delete_all_config_colors();
		main::set_color_scheme($colors{'default'});
	}
	else {
		main::set_color_scheme($response);
		@data = (
		[0, '', '', "Updating config file for $configs{'selection'} color scheme now..."],
		[0, '', '',  "$line1"],
		);
		main::print_basic(@data); 
		if ($configs{'selection'} eq 'global'){
			delete_all_colors();
		}
		else {
			delete_global_color();
		}
		set_config_color_scheme($response);
	}
}
sub delete_all_colors {
	my @file_lines = main::reader( $user_config_file );
	open( $w_fh, '>', $user_config_file ) or main::error_handler('open', $user_config_file, $!);
	foreach ( @file_lines ) { 
		if ( $_ !~ /^(CONSOLE_COLOR_SCHEME|GLOBAL_COLOR_SCHEME|IRC_COLOR_SCHEME|IRC_CONS_COLOR_SCHEME|IRC_X_TERM_COLOR_SCHEME|VIRT_TERM_COLOR_SCHEME)/){
			print {$w_fh} "$_"; 
		}
	} 
	close $w_fh;
}
sub delete_global_color {
	my @file_lines = main::reader( $user_config_file );
	open( $w_fh, '>', $user_config_file ) or main::error_handler('open', $user_config_file, $!);
	foreach ( @file_lines ) { 
		if ( $_ !~ /^GLOBAL_COLOR_SCHEME/){
			print {$w_fh} "$_"; 
		}
	} 
	close $w_fh;
}
sub set_config_color_scheme {
	my $value = shift;
	my @file_lines = main::reader( $user_config_file );
	my $b_found = 0;
	open( $w_fh, '>', $user_config_file ) or main::error_handler('open', $user_config_file, $!);
	foreach ( @file_lines ) { 
		if ( $_ =~ /^$configs{'variable'}/ ){
			$_ = "$configs{'variable'}=$value";
			$b_found = 1;
		}
		print $w_fh "$_\n";
	}
	if (! $b_found ){
		print $w_fh "$configs{'variable'}=$value\n";
	}
	close $w_fh;
}

sub print_irc_message {
	@data = (
	[ 0, '', '', "$line1"],
	[ 0, '', '', "After finding the scheme number you like, simply run this again
	in a terminal to set the configuration data file for your irc client. You can 
	set color schemes for the following: start inxi with -c plus:"],
	[ 0, '', '', "94 (console,^not^in^desktop^-^$status{'console'})"],
	[ 0, '', '', "95 (terminal, desktop^-^$status{'virt-term'})"],
	[ 0, '', '', "96 (irc,^gui,^desktop^-^$status{'irc-gui'})"],
	[ 0, '', '', "97 (irc,^desktop,^in terminal^-^$status{'irc-virt-term'})"],
	[ 0, '', '', "98 (irc,^not^in^desktop^-^$status{'irc-console'})"],
	[ 0, '', '', "99 (global^-^$status{'global'})"]
	);
	main::print_basic(@data); 
	exit 0;
}

}

#### -------------------------------------------------------------------
#### CONFIGS
#### -------------------------------------------------------------------

sub check_config_file {
	$user_config_file = "$user_config_dir/$self_name.conf";
	if ( ! -f $user_config_file ){
		open( my $fh, '>', $user_config_file ) or error_handler('create', $user_config_file, $!);
	}
}

sub get_configs {
	my (@configs) = @_;
	my ($key, $val,@config_files);
	if (!@configs){
		@config_files = (
		qq(/etc/$self_name.conf), 
		qq($user_config_dir/$self_name.conf)
		);
	}
	else {
		@config_files = (@configs);
	}
	# Config files should be passed in an array as a param to this function.
	# Default intended use: global @CONFIGS;
	foreach (@config_files) {
		next unless open (my $fh, '<', "$_");
		while (<$fh>) {
			chomp;
			s/#.*//;
			s/^\s+//;
			s/\s+$//;
			s/'|"//g;
			s/true/1/i; # switch to 1/0 perl boolean
			s/false/0/i; # switch to 1/0 perl boolean
			next unless length;
			($key, $val) = split(/\s*=\s*/, $_, 2);
			next unless length($val);
			get_config_item($key,$val);
			# print "f: $file key: $key val: $val\n";
		}
		close $fh;
	}
}

# note: someone managed to make a config file with corrupted values, so check int 
# explicitly, don't assume it was done correctly.
# args: 0: key; 1: value
sub get_config_item {
	my ($key,$val) = @_;
	if ($key eq 'ALLOW_UPDATE' || $key eq 'B_ALLOW_UPDATE') {$use{'update'} = $val if is_int($val)}
	elsif ($key eq 'ALLOW_WEATHER' || $key eq 'B_ALLOW_WEATHER') {$use{'weather'} = $val if is_int($val)}
	elsif ($key eq 'CPU_SLEEP') {$cpu_sleep = $val if is_numeric($val)}
	elsif ($key eq 'DL_TIMEOUT') {$dl_timeout = $val if is_int($val)}
	elsif ($key eq 'DOWNLOADER') {
		if ($val =~ /^(curl|fetch|ftp|perl|wget)$/){
			# this dumps all the other data and resets %dl for only the
			# desired downloader.
			$val = set_perl_downloader($val);
			%dl = ('dl' => $val, $val => 1);
		}}
	elsif ($key eq 'FILTER_STRING') {$filter_string = $val}
	elsif ($key eq 'LANGUAGE') {$language = $val if $val =~ /^(en)$/}
	elsif ($key eq 'LIMIT') {$limit = $val if is_int($val)}
	elsif ($key eq 'OUTPUT_TYPE') {$output_type = $val if $val =~ /^(json|screen|xml)$/}
	elsif ($key eq 'NO_DIG') {$b_skip_dig = $val if is_int($val)}
	elsif ($key eq 'NO_HTML_WAN') {$b_no_html_wan = $val if is_int($val)}
	elsif ($key eq 'NO_SUDO') {$b_no_sudo = $val if is_int($val)}
	elsif ($key eq 'PARTITION_SORT') {$show{'partition-sort'} = $val if ($val =~ /^(dev-base|fs|id|label|percent-used|size|uuid|used)$/) }
	elsif ($key eq 'PS_COUNT') {$ps_count = $val if is_int($val) }
	elsif ($key eq 'SENSORS_CPU_NO') {$sensors_cpu_nu = $val if is_int($val)}
	elsif ($key eq 'SENSORS_EXCLUDE') {@sensors_exclude = split /\s*,\s*/, $val if $val}
	elsif ($key eq 'SENSORS_USE') {@sensors_use = split /\s*,\s*/, $val if $val}
	elsif ($key eq 'SHOW_HOST' || $key eq 'B_SHOW_HOST') {
		if (is_int($val)){
			$show{'host'} = $val;
			$show{'no-host'} = 1 if !$show{'host'};
		}
	}
	elsif ($key eq 'USB_SYS') {$b_usb_sys = $val if is_int($val)}
	elsif ($key eq 'WAN_IP_URL') {
		if ($val =~ /^(ht|f)tp[s]?:\//i){
			$wan_url = $val;
			$b_skip_dig = 1;
		}
	}
	elsif ($key eq 'WEATHER_SOURCE') {$weather_source = $val if is_int($val)}
	elsif ($key eq 'WEATHER_UNIT') { 
		$val = lc($val) if $val;
		if ($val && $val =~ /^(c|f|cf|fc|i|m|im|mi)$/){
			my %units = ('c'=>'m','f'=>'i','cf'=>'mi','fc'=>'im');
			$val = $units{$val} if defined $units{$val};
			$weather_unit = $val;
		}
	}
	# layout
	elsif ($key eq 'CONSOLE_COLOR_SCHEME') {$colors{'console'} = $val if is_int($val)}
	elsif ($key eq 'GLOBAL_COLOR_SCHEME') {$colors{'global'} = $val if is_int($val)}
	elsif ($key eq 'IRC_COLOR_SCHEME') {$colors{'irc-gui'} = $val if is_int($val)}
	elsif ($key eq 'IRC_CONS_COLOR_SCHEME') {$colors{'irc-console'} = $val if is_int($val)}
	elsif ($key eq 'IRC_X_TERM_COLOR_SCHEME') {$colors{'irc-virt-term'} = $val if is_int($val)}
	elsif ($key eq 'VIRT_TERM_COLOR_SCHEME') {$colors{'virt-term'} = $val if is_int($val)}
	# note: not using the old short SEP1/SEP2
	elsif ($key eq 'SEP1_IRC') {$sep{'s1-irc'} = $val}
	elsif ($key eq 'SEP1_CONSOLE') {$sep{'s1-console'} = $val}
	elsif ($key eq 'SEP2_IRC') {$sep{'s2-irc'} = $val}
	elsif ($key eq 'SEP2_CONSOLE') {$sep{'s2-console'} = $val}
	# size
	elsif ($key eq 'COLS_MAX_CONSOLE') {$size{'console'} = $val if is_int($val)}
	elsif ($key eq 'COLS_MAX_IRC') {$size{'irc'} = $val if is_int($val)}
	elsif ($key eq 'COLS_MAX_NO_DISPLAY') {$size{'no-display'} = $val if is_int($val)}
	elsif ($key eq 'INDENT') {$size{'indent'} = $val if is_int($val)}
	elsif ($key eq 'INDENT_MIN') {$size{'indent-min'} = $val if is_int($val)}
	#  print "mc: key: $key val: $val\n";
	# print Dumper (keys %size) . "\n";
}

#### -------------------------------------------------------------------
#### DEBUGGERS
#### -------------------------------------------------------------------

# called in the initial -@ 10 program args setting so we can get logging 
# as soon as possible # will have max 3 files, inxi.log, inxi.1.log, 
# inxi.2.log
sub begin_logging {
	return 1 if $fh_l; # if we want to start logging for testing before options
	my $log_file_2="$user_data_dir/$self_name.1.log";
	my $log_file_3="$user_data_dir/$self_name.2.log";
	my $data = '';
	$end='main::log_data("fe", (caller(1))[3], "");';
	$start='main::log_data("fs", (caller(1))[3], \@_);';
	#$t3 = tv_interval ($t0, [gettimeofday]);
	$t3 = eval 'Time::HiRes::tv_interval (\@t0, [Time::HiRes::gettimeofday()]);' if $b_hires;
	#print Dumper $@;
	my $now = strftime "%Y-%m-%d %H:%M:%S", localtime;
	return if $debugger{'timers'};
	# do the rotation if logfile exists
	if ( -f $log_file ){
		# copy if present second to third
		if ( -f $log_file_2 ){
			rename $log_file_2, $log_file_3 or error_handler('rename', "$log_file_2 -> $log_file_3", "$!");
		}
		# then copy initial to second
		rename $log_file, $log_file_2 or error_handler('rename', "$log_file -> $log_file_2", "$!");
	}
	# now create the logfile
	# print "Opening log file for reading: $log_file\n";
	open $fh_l, '>', $log_file or error_handler(4, $log_file, "$!");
	# and echo the start data
	$data = $line2;
	$data .= "START $self_name LOGGING:\n";
	$data .= "NOTE: HiRes timer not available.\n" if !$b_hires;
	$data .= "$now\n";
	$data .= "Elapsed since start: $t3\n";
	$data .= "n: $self_name v: $self_version p: $self_patch d: $self_date\n";
	$data .= '@paths:' . joiner(\@paths, '::', 'unset') . "\n";
	$data .= $line2;
	
	print $fh_l $data;
}

# NOTE: no logging available until get_parameters is run, since that's what 
# sets logging # in order to trigger earlier logging manually set $b_log
# to true in top variables.
# args: $1 - type [fs|fe|cat|dump|raw] OR data to log
# arg: $2 - 
# arg: $one type (fs/fe/cat/dump/raw) or logged data; 
# [$two is function name; [$three - function args]]
sub log_data {
	return if ! $b_log;
	my ($one, $two, $three) = @_;
	my ($args,$data,$timer) = ('','','');
	my $spacer = '   ';
	# print "1: $one 2: $two 3: $three\n";
	if ($one eq 'fs') {
		if (ref $three eq 'ARRAY'){
			# my @temp = @$three;
			# print Data::Dumper::Dumper \@$three;
			$args = "\n${spacer}Args: " . joiner($three, '; ', 'unset');
		}
		else {
			$args = "\n${spacer}Args: None";
		}
		# $t1 = [gettimeofday];
		#$t3 = tv_interval ($t0, [gettimeofday]);
		$t3 = eval 'Time::HiRes::tv_interval(\@t0, [Time::HiRes::gettimeofday()])' if $b_hires;
		#print Dumper $@;
		$data = "Start: Function: $two$args\n${spacer}Elapsed: $t3\n";
		$spacer='';
		$timer = $data if $debugger{'timers'};
	}
	elsif ( $one eq 'fe') {
		# print 'timer:', Time::HiRes::tv_interval(\@t0, [Time::HiRes::gettimeofday()]),"\n";
		#$t3 = tv_interval ($t0, [gettimeofday]);
		eval '$t3 = Time::HiRes::tv_interval(\@t0, [Time::HiRes::gettimeofday()])' if $b_hires;
		#print Dumper $t3;
		$data = "${spacer}Elapsed: $t3\nEnd: Function: $two\n";
		$spacer='';
		$timer = $data if $debugger{'timers'};
	}
	elsif ( $one eq 'cat') {
		if ( $b_log_full ){
			for my $file ($two){
				my $contents = do { local( @ARGV, $/ ) = $file; <> }; # or: qx(cat $file)
				$data = "$data${line3}Full file data: $file\n\n$contents\n$line3\n";
			}
			$spacer='';
		}
	}
	elsif ($one eq 'cmd'){
		$data = "Command: $two\n";
		$data .= qx($two);
	}
	elsif ($one eq 'data'){
		$data = "$two\n";
	}
	elsif ( $one eq 'dump') {
		$data = "$two:\n";
		if (ref $three eq 'HASH'){
			$data .= Data::Dumper::Dumper \%$three;
		}
		elsif (ref $three eq 'ARRAY'){
			# print Data::Dumper::Dumper \@$three;
			$data .= Data::Dumper::Dumper \@$three;
		}
		else {
			$data .= Data::Dumper::Dumper $three;
		}
		$data .= "\n";
		# print $data;
	}
	elsif ( $one eq 'raw') {
		if ( $b_log_full ){
			$data = "\n${line3}Raw System Data:\n\n$two\n$line3";
			$spacer='';
		}
	}
	else {
		$data = "$two\n";
	}
	if ($debugger{'timers'}){
		print $timer if $timer;
	}
	#print "d: $data";
	elsif ($data){
		print $fh_l "$spacer$data";
	}
}

sub set_debugger {
	user_debug_test_1() if $debugger{'test-1'};
	if ( $debug >= 20){
		error_handler('not-in-irc', 'debug data generator') if $b_irc;
		my $option = ( $debug > 22 ) ? 'main-full' : 'main';
		$debugger{'gz'} = 1 if ($debug == 22 || $debug == 24);
		my $ob_sys = SystemDebugger->new($option);
		$ob_sys->run_debugger();
		$ob_sys->upload_file($ftp_alt) if $debug > 20;
		exit 0;
	}
	elsif ($debug >= 10 && $debug <= 12){
		$b_log = 1;
		if ($debug == 11){
			$b_log_full = 1;
		}
		elsif ($debug == 12){
			$b_log_colors = 1;
		}
		begin_logging();
	}
	elsif ($debug <= 3){
		if ($debug == 3){
			$b_log = 1;
			$debugger{'timers'} = 1;
			begin_logging();
		}
		else {
			$end = '';
			$start = '';
		}
	}
}

## SystemDebugger
{
package SystemDebugger;

# use File::Find q(find);
#no warnings 'File::Find';
# use File::Spec::Functions;
#use File::Copy;
#use POSIX qw(strftime);

my $option = 'main';
my ($data_dir,$debug_dir,$debug_gz,$parse_src,$upload) = ('','','','','');
my @content = (); 
my $b_debug = 0;
my $b_delete_dir = 1;
# args: 1 - type
# args: 2 - upload
sub new {
	my $class = shift;
	($option) = @_;
	my $self = {};
	# print "$f\n";
	# print "$option\n";
	return bless $self, $class;
}

sub run_debugger {
	#require File::Find;
	#File::Find::Functions->import;
	require File::Copy;
	File::Copy->import;
	require File::Spec::Functions;
	File::Spec::Functions->import;
	
	print "Starting $self_name debugging data collector...\n";
	create_debug_directory();
	print "Note: for dmidecode data you must be root.\n" if !$b_root;
	print $line3;
	if (!$b_debug){
		audio_data();
		disk_data();
		display_data();
		network_data();
		perl_modules();
		system_data();
	}
	system_files();
	print $line3;
	if (!$b_debug){
		# note: android has unreadable /sys, but -x and -r tests pass
		# main::globber('/sys/*') && 
		if ( $debugger{'sys'} && main::count_dir_files('/sys') ){
			build_tree('sys');
			# kernel crash, not sure what creates it, for ppc, as root
			sys_traverse_data() if ($debugger{'sys'} && ($debugger{'sys-force'} || !$b_root || !$b_ppc )) ; 
		}
		else {
			print "Skipping /sys data collection.\n";
		}
		print $line3;
		# note: proc has some files that are apparently kernel processes, I've tried 
		# filtering them out but more keep appearing, so only run proc debugger if not root
		if ( !$debugger{'no-proc'} && (!$b_root || $debugger{'proc'} ) && -d '/proc' && main::count_dir_files('/proc') ){
			build_tree('proc');
			proc_traverse_data();
		}
		else {
			print "Skipping /proc data collection.\n";
		}
		print $line3;
	}
	run_self();
	print $line3;
	compress_dir();
}

sub create_debug_directory {
	my $host = main::get_hostname();
	$host =~ s/ /-/g;
	$host = 'no-host' if !$host || $host eq 'N/A';
	my ($alt_string,$bsd_string,$root_string) = ('','','');
	# note: Time::Piece was introduced in perl 5.9.5
	my ($sec,$min,$hour,$mday,$mon,$year) = localtime;
	$year = $year+1900;
	$mon += 1;
	if (length($sec)  == 1) {$sec = "0$sec";}
	if (length($min)  == 1) {$min = "0$min";}
	if (length($hour) == 1) {$hour = "0$hour";}
	if (length($mon)  == 1) {$mon = "0$mon";}
	if (length($mday) == 1) {$mday = "0$mday";}
	
	my $today = "$year-$mon-${mday}_$hour$min$sec";
	# my $date = strftime "-%Y-%m-%d_", localtime;
	if ($b_root){
		$root_string = '-root';
	}
	$bsd_string = "-BSD-$bsd_type" if $bsd_type;
	if ($b_arm ){$alt_string = '-ARM'}
	elsif ($b_mips) {$alt_string = '-MIPS'}
	elsif ($b_ppc) {$alt_string = '-PPC'}
	elsif ($b_sparc) {$alt_string = '-SPARC'}
	$debug_dir = "$self_name$alt_string$bsd_string-$host-$today$root_string-$self_version";
	$debug_gz = "$debug_dir.tar.gz";
	$data_dir = "$user_data_dir/$debug_dir";
	if ( -d $data_dir ){
		unlink $data_dir or main::error_handler('remove', "$data_dir", "$!");
	}
	mkdir $data_dir or main::error_handler('mkdir', "$data_dir", "$!");
	if ( -e "$user_data_dir/$debug_gz" ){
		#rmdir "$user_data_dir$debug_gz" or main::error_handler('remove', "$user_data_dir/$debug_gz", "$!");
		print "Failed removing leftover directory:\n$user_data_dir$debug_gz error: $?" if system('rm','-rf',"$user_data_dir$debug_gz");
	}
	print "Data going into:\n$data_dir\n";
}
sub compress_dir {
	print "Creating tar.gz compressed file of this material...\n";
	print "File: $debug_gz\n";
	system("cd $user_data_dir; tar -czf $debug_gz $debug_dir");
	print "Removing $data_dir...\n";
	#rmdir $data_dir or print "failed removing: $data_dir error: $!\n";
	return 1 if !$b_delete_dir;
	if (system('rm','-rf',$data_dir) ){
		print "Failed removing: $data_dir\nError: $?\n";
	}
	else {
		print "Directory removed.\n";
	}
}
# NOTE: incomplete, don't know how to ever find out 
# what sound server is actually running, and is in control
sub audio_data {
	my (%data,@files,@files2);
	print "Collecting audio data...\n";
	my @cmds = (
	['aplay', '-l'], # alsa
	['pactl', 'list'], # pulseaudio
	);
	run_commands(\@cmds,'audio');
	@files = main::globber('/proc/asound/card*/codec*');
	if (@files){
		my $asound = qx(head -n 1 /proc/asound/card*/codec* 2>&1);
		$data{'proc-asound-codecs'} = $asound;
	}
	else {
		$data{'proc-asound-codecs'} = undef;
	}
	write_data(\%data,'audio');
	@files = (
	'/proc/asound/cards',
	'/proc/asound/version',
	);
	@files2 = main::globber('/proc/asound/*/usbid');
	@files = (@files,@files2) if @files2;
	copy_files(\@files,'audio');
}
## NOTE: >/dev/null 2>&1 is sh, and &>/dev/null is bash, fix this
# ls -w 1 /sysrs > tester 2>&1
sub disk_data {
	my (%data,@files,@files2);
	print "Collecting dev, label, disk, uuid data, df...\n";
	@files = (
	'/etc/fstab',
	'/etc/mtab',
	'/proc/mdstat',
	'/proc/mounts',
	'/proc/partitions',
	'/proc/scsi/scsi',
	'/proc/sys/dev/cdrom/info',
	);
	# very old systems
	if (-d '/proc/ide/'){
		my @ides = main::globber('/proc/ide/*/*');
		@files = (@files, @ides) if @ides;
	}
	else {
		push (@files, '/proc-ide-directory');
	}
	copy_files(\@files, 'disk');
	my @cmds = (
	['blockdev', '--report'],
	['btrfs', 'filesystem show'],
	['btrfs', 'filesystem show --mounted'],
	# ['btrfs', 'filesystem show --all-devices'],
	['df', '-h -T'],
	['df', '-h'],
	['df', '-k'],
	['df', '-k -T'],
	['df', '-k -T -P'],
	['df', '-k -T -P -a'],
	['df', '-P'],
	['findmnt', ''],
	['findmnt', '--df --no-truncate'],
	['findmnt', '--list --no-truncate'],
	['lsblk', '-fs'],
	['lsblk', '-fsr'],
	['lsblk', '-fsP'],
	['lsblk', '-a'],
	['lsblk', '-aP'],
	['lsblk', '-ar'],
	['lsblk', '-p'],
	['lsblk', '-pr'],
	['lsblk', '-pP'],
	['lsblk', '-r'],
	['lsblk', '-r --output NAME,PKNAME,TYPE,RM,FSTYPE,SIZE,LABEL,UUID,MOUNTPOINT,PHY-SEC,LOG-SEC,PARTFLAGS'],
	['lsblk', '-rb --output NAME,PKNAME,TYPE,RM,FSTYPE,SIZE,LABEL,UUID,MOUNTPOINT,PHY-SEC,LOG-SEC,PARTFLAGS'],
	['lsblk', '-Pb --output NAME,PKNAME,TYPE,RM,FSTYPE,SIZE'],
	['lsblk', '-Pb --output NAME,TYPE,RM,FSTYPE,SIZE,LABEL,UUID,SERIAL,MOUNTPOINT,PHY-SEC,LOG-SEC,PARTFLAGS'],
	['gpart', 'list'],
	['gpart', 'show'],
	['gpart', 'status'],
	['ls', '-l /dev'],
	# block is for mmcblk / arm devices
	['ls', '-l /dev/block'],
	['ls', '-l /dev/block/bootdevice'],
	['ls', '-l /dev/block/bootdevice/by-name'],
	['ls', '-l /dev/disk'],
	['ls', '-l /dev/disk/by-id'],
	['ls', '-l /dev/disk/by-label'],
	['ls', '-l /dev/disk/by-partlabel'],
	['ls', '-l /dev/disk/by-partuuid'],
	['ls', '-l /dev/disk/by-path'],
	['ls', '-l /dev/disk/by-uuid'],
	# http://comments.gmane.org/gmane.linux.file-systems.zfs.user/2032
	['ls', '-l /dev/disk/by-wwn'],
	['ls', '-l /dev/mapper'],
	# LSI raid https://hwraid.le-vert.net/wiki/LSIMegaRAIDSAS
	['megacli', '-AdpAllInfo -aAll'],
	['megacli', '-LDInfo -L0 -a0'],
	['megacli', '-PDList -a0'],
	['megaclisas-status', ''],
	['megaraidsas-status', ''],
	['megasasctl', ''],
	['mount', ''],
	['nvme', 'present'],
	['readlink', '/dev/root'],
	['swapon', '-s'],
	# 3ware-raid
	['tw-cli', 'info'],
	['zfs', 'list'],
	['zpool', 'list'],
	['zpool', 'list -v'],
	);
	run_commands(\@cmds,'disk');
	@cmds = (
	['atacontrol', 'list'],
	['camcontrol', 'devlist'], 
	['glabel', 'status'], 
	['swapctl', '-l -k'],
	['swapctl', '-l -k'],
	['vmstat', '-H'],
	);
	run_commands(\@cmds,'disk-bsd');
}
sub display_data {
	my (%data,@files,@files2);
	my $working = '';
	if ( ! $b_display ){
		print "Warning: only some of the data collection can occur if you are not in X\n";
		main::toucher("$data_dir/display-data-warning-user-not-in-x");
	}
	if ( $b_root ){
		print "Warning: only some of the data collection can occur if you are running as Root user\n";
		main::toucher("$data_dir/display-data-warning-root-user");
	}
	print "Collecting Xorg log and xorg.conf files...\n";
	if ( -d "/etc/X11/xorg.conf.d/" ){
		@files = main::globber("/etc/X11/xorg.conf.d/*");
	}
	else {
		@files = ('/xorg-conf-d');
	}
	# keep this updated to handle all possible locations we know about for Xorg.0.log
	# not using $system_files{'xorg-log'} for now though it would be best to know what file is used
	main::set_xorg_log();
	push (@files, '/var/log/Xorg.0.log');
	push (@files, '/var/lib/gdm/.local/share/xorg/Xorg.0.log');
	push (@files, $ENV{'HOME'} . '/.local/share/xorg/Xorg.0.log');
	push (@files, $system_files{'xorg-log'}) if $system_files{'xorg-log'};
	push (@files, '/etc/X11/xorg.conf');
	copy_files(\@files,'display-xorg');
	print "Collecting X, xprop, glxinfo, xrandr, xdpyinfo data, wayland, weston...\n";
	%data = (
	'desktop-session' => $ENV{'DESKTOP_SESSION'},
	'gdmsession' => $ENV{'GDMSESSION'},
	'gnome-desktop-session-id' => $ENV{'GNOME_DESKTOP_SESSION_ID'},
	'kde-full-session' => $ENV{'KDE_FULL_SESSION'},
	'kde-session-version' => $ENV{'KDE_SESSION_VERSION'},
	'vdpau-driver' => $ENV{'VDPAU_DRIVER'},
	'xdg-current-desktop' => $ENV{'XDG_CURRENT_DESKTOP'},
	'xdg-session-desktop' => $ENV{'XDG_SESSION_DESKTOP'},
	'xdg-vtnr' => $ENV{'XDG_VTNR'},
	# wayland data collectors:
	'xdg-session-type' => $ENV{'XDG_SESSION_TYPE'},
	'wayland-display' =>  $ENV{'WAYLAND_DISPLAY'},
	'gdk-backend' => $ENV{'GDK_BACKEND'},
	'qt-qpa-platform' => $ENV{'QT_QPA_PLATFORM'},
	'clutter-backend' => $ENV{'CLUTTER_BACKEND'},
	'sdl-videodriver' => $ENV{'SDL_VIDEODRIVER'},
	# program display values
	'size-indent' => $size{'indent'},
	'size-indent-min' => $size{'indent-min'},
	'size-cols-max' => $size{'max'},
	);
	write_data(\%data,'display');
	my @cmds = (
	# kde 5/plasma desktop 5, this is maybe an extra package and won't be used
	['about-distro',''],
	['aticonfig','--adapter=all --od-gettemperature'],
	['glxinfo',''],
	['glxinfo','-B'],
	['kded','--version'],
	['kded1','--version'],
	['kded2','--version'],
	['kded3','--version'],
	['kded4','--version'],
	['kded5','--version'],
	['kded6','--version'],
	['kf4-config','--version'],
	['kf5-config','--version'],
	['kf6-config','--version'],
	['kwin_x11','--version'],
	# ['locate','/Xorg'], # for Xorg.wrap problem
	['loginctl','--no-pager list-sessions'],
	['nvidia-settings','-q screens'],
	['nvidia-settings','-c :0.0 -q all'],
	['nvidia-smi','-q'],
	['nvidia-smi','-q -x'],
	['plasmashell','--version'],
	['vainfo',''],
	['vdpauinfo',''],
	['vulkaninfo',''],
	['weston-info',''], 
	['wmctrl','-m'],
	['weston','--version'],
	['xdpyinfo',''],
	['Xorg','-version'],
	['xprop','-root'],
	['xrandr',''],
	);
	run_commands(\@cmds,'display');
}
sub network_data {
	print "Collecting networking data...\n";
# 	no warnings 'uninitialized';
	my @cmds = (
	['ifconfig',''],
	['ip','addr'],
	['ip','-s link'],
	);
	run_commands(\@cmds,'network');
}
sub perl_modules {
	print "Collecting Perl module data (this can take a while)...\n";
	my @modules = ();
	my ($dirname,$holder,$mods,$value) = ('','','','');
	my $filename = 'perl-modules.txt';
	my @inc;
	foreach (sort @INC){
		# some BSD installs have '.' n @INC path
		if (-d $_ && $_ ne '.'){
			$_ =~ s/\/$//; # just in case, trim off trailing slash
			$value .= "EXISTS: $_\n";
			push @inc, $_;
		} 
		else {
			$value .= "ABSENT: $_\n";
		}
	}
	main::writer("$data_dir/perl-inc-data.txt",$value);
	File::Find::find { wanted => sub { 
		push @modules, File::Spec->canonpath($_) if /\.pm\z/  
	}, no_chdir => 1 }, @inc;
	@modules = sort(@modules);
	foreach (@modules){
		my $dir = $_;
		$dir =~ s/[^\/]+$//;
		if (!$holder || $holder ne $dir ){
			$holder = $dir;
			$value = "DIR: $dir\n";
			$_ =~ s/^$dir//;
			$value .= " $_\n";
		}
		else {
			$value = $_;
			$value =~ s/^$dir//;
			$value = " $value\n";
		}
		$mods .= $value;
	}
	open (my $fh, '>', "$data_dir/$filename");
	print $fh $mods;
	close $fh;
}
sub system_data {
	print "Collecting system data...\n";
	my %data = (
	'cc' => $ENV{'CC'},
	# @(#)MIRBSD KSH R56 2018/03/09: ksh and mksh
	'ksh-version' => system('ksh -c \'printf %s "$KSH_VERSION"\''), # shell, not env, variable
	'manpath' => $ENV{'MANPATH'},
	'path' => $ENV{'PATH'},
	'xdg-config-home' => $ENV{'XDG_CONFIG_HOME'},
	'xdg-config-dirs' => $ENV{'XDG_CONFIG_DIRS'},
	'xdg-data-home' => $ENV{'XDG_DATA_HOME'},
	'xdg-data-dirs' => $ENV{'XDG_DATA_DIRS'},
	);
	my @files = main::globber('/usr/bin/gcc*');
	if (@files){
		$data{'gcc-versions'} = join "\n",@files;
	}
	else {
		$data{'gcc-versions'} = undef;
	}
	@files = main::globber('/sys/*');
	if (@files){
		$data{'sys-tree-ls-1-basic'} = join "\n", @files;
	}
	else {
		$data{'sys-tree-ls-1-basic'} = undef;
	}
	write_data(\%data,'system');
	# bsd tools http://cb.vu/unixtoolbox.xhtml
	my @cmds = (
	# general
	['sysctl', '-b kern.geom.conftxt'],
	['sysctl', '-b kern.geom.confxml'],
	['usbdevs','-v'],
	# freebsd
	['pciconf','-l -cv'],
	['pciconf','-vl'],
	['pciconf','-l'],
	# openbsd
	['pcidump',''],
	['pcidump','-v'],
	# netbsd
	['kldstat',''],
	['pcictl','list'],
	['pcictl','list -ns'],
	);
	run_commands(\@cmds,'system-bsd');
	# diskinfo -v <disk>
	# fdisk <disk>
	@cmds = (
	['clang','--version'],
	# only for prospective ram feature data collection: requires i2c-tools and module eeprom loaded
	['decode-dimms',''], 
	['dmidecode',''],
	['dmesg',''],
	['gcc','--version'],
	['hciconfig','-a'],
	['initctl','list'],
	['ipmi-sensors',''],
	['ipmi-sensors','--output-sensor-thresholds'],
	['ipmitool','sensor'],
	['lscpu',''],
	['lspci',''],
	['lspci','-k'],
	['lspci','-n'],
	['lspci','-nn'],
	['lspci','-nnk'],
	['lspci','-nnkv'],# returns ports
	['lspci','-nnv'],
	['lspci','-mm'],
	['lspci','-mmk'],
	['lspci','-mmkv'],
	['lspci','-mmv'],
	['lspci','-mmnn'],
	['lspci','-v'],
	['lsusb',''],
	['lsusb','-t'],
	['lsusb','-v'],
	['ps','aux'],
	['ps','-e'],
	['ps','-p 1'],
	['runlevel',''],
	['rc-status','-a'],
	['rc-status','-l'],
	['rc-status','-r'],
	['sensors',''],
	['sensors','-j'],
	['sensors','-u'],
	# leaving this commented out to remind that some systems do not
	# support strings --version, but will just simply hang at that command
	# which you can duplicate by simply typing: strings then hitting enter.
	# ['strings','--version'],
	['strings','present'],
	['sysctl','-a'],
	['systemctl','list-units'],
	['systemctl','list-units --type=target'],
	['systemd-detect-virt',''],
	['uname','-a'],
	['upower','-e'],
	['uptime',''],
	['vcgencmd','get_mem arm'],
	['vcgencmd','get_mem gpu'],
	);
	run_commands(\@cmds,'system');
	@files = main::globber('/dev/bus/usb/*/*');
	copy_files(\@files, 'system');
}
sub system_files {
	print "Collecting system files data...\n";
	my (%data,@files,@files2);
	@files = RepoData::get($data_dir);
	copy_files(\@files, 'repo');
	# chdir "/etc";
	@files = main::globber('/etc/*[-_]{[rR]elease,[vV]ersion,issue}*');
	push (@files, '/etc/issue');
	push (@files, '/etc/lsb-release');
	push (@files, '/etc/os-release');
	push (@files, '/system/build.prop');# android data file, requires rooted
	push (@files, '/var/log/installer/oem-id'); # ubuntu only for oem installs?
	copy_files(\@files,'system-distro');
	@files = main::globber('/etc/upstream[-_]{[rR]elease,[vV]ersion}/*');
	copy_files(\@files,'system-distro');
	@files = main::globber('/etc/calamares/branding/*/branding.desc');
	copy_files(\@files,'system-distro');
	@files = (
	'/proc/1/comm',
	'/proc/cmdline',
	'/proc/cpuinfo',
	'/proc/meminfo',
	'/proc/modules',
	'/proc/net/arp',
	'/proc/version',
	);
	@files2=main::globber('/sys/class/power_supply/*/uevent');
	if (@files2){
		@files = (@files,@files2);
	}
	else {
		push (@files, '/sys-class-power-supply-empty');
	}
	copy_files(\@files, 'system');
	@files = (
	'/etc/make.conf',
	'/etc/src.conf',
	'/var/run/dmesg.boot',
	);
	copy_files(\@files,'system-bsd');
	@files = main::globber('/sys/devices/system/cpu/vulnerabilities/*');
	copy_files(\@files,'security');
}
## SELF EXECUTE FOR LOG/OUTPUT
sub run_self {
	print "Creating $self_name output file now. This can take a few seconds...\n";
	print "Starting $self_name from: $self_path\n";
	my $i = ($option eq 'main-full')? ' -i' : '';
	my $z = ($debugger{'filter'}) ? ' -z' : '';
	my $iz = "$i$z";
	$iz =~ s/[\s-]//g;
	my $cmd = "$self_path/$self_name -FRfJrploudmaxxx$i$z --slots --debug 10 -y 120 > $data_dir/$self_name-FRfJrploudmaxxx$iz-slots-y120.txt 2>&1";
	system($cmd);
	copy($log_file, "$data_dir") or main::error_handler('copy-failed', "$log_file", "$!");
	system("$self_path/$self_name --recommends -y 120 > $data_dir/$self_name-recommends-120.txt 2>&1");
}

## UTILITIES COPY/CMD/WRITE
sub copy_files {
	my ($files_ref,$type,$alt_dir) = @_;
	my ($absent,$error,$good,$name,$unreadable);
	my $directory = ($alt_dir) ? $alt_dir : $data_dir;
	my $working = ($type ne 'proc') ? "$type-file-": '';
	foreach (@$files_ref) {
		$name = $_;
		$name =~ s/^\///;
		$name =~ s/\//~/g;
		# print "$name\n" if $type eq 'proc';
		$name = "$directory/$working$name";
		$good = $name . '.txt';
		$absent = $name . '-absent';
		$error = $name . '-error';
		$unreadable = $name . '-unreadable';
		# proc have already been tested for readable/exists
		if ($type eq 'proc' || -e $_ ) {
			print "F:$_\n" if $type eq 'proc' && $debugger{'proc-print'};
			if ($type eq 'proc' || -r $_){
				copy($_,"$good") or main::toucher($error);
			}
			else {
				main::toucher($unreadable);
			}
		}
		else {
			main::toucher($absent);
		}
	}
}
sub run_commands {
	my ($cmds,$type) = @_;
	my $holder = '';
	my ($name,$cmd,$args);
	foreach (@$cmds){
		my @rows = @$_;
		if (my $program = main::check_program($rows[0])){
			if ($rows[1] eq 'present'){
				$name = "$data_dir/$type-cmd-$rows[0]-present";
				main::toucher($name);
			}
			else {
				$args = $rows[1];
				$args =~ s/\s|--|\/|=/-/g; # for:
				$args =~ s/--/-/g;# strip out -- that result from the above
				$args =~ s/^-//g;
				$args = "-$args" if $args;
				$name = "$data_dir/$type-cmd-$rows[0]$args.txt";
				$cmd = "$program $rows[1] >$name 2>&1";
				system($cmd);
			}
		}
		else {
			if ($holder ne $rows[0]){
				$name = "$data_dir/$type-cmd-$rows[0]-absent";
				main::toucher($name);
				$holder = $rows[0];
			}
		}
	}
}
sub write_data {
	my ($data_ref, $type) = @_;
	my ($empty,$error,$fh,$good,$name,$undefined,$value);
	foreach (keys %$data_ref) {
		$value = $$data_ref{$_};
		$name = "$data_dir/$type-data-$_";
		$good = $name . '.txt';
		$empty = $name . '-empty';
		$error = $name . '-error';
		$undefined = $name . '-undefined';
		if (defined $value) {
			if ($value || $value eq '0'){
				open($fh, '>', $good) or main::toucher($error);
				print $fh "$value";
			}
			else {
				main::toucher($empty);
			}
		}
		else {
			main::toucher($undefined);
		}
	}
}
## TOOLS FOR DIRECTORY TREE/LS/TRAVERSE; UPLOADER
sub build_tree {
	my ($which) = @_;
	if ( $which eq 'sys' && main::check_program('tree') ){
		print "Constructing /$which tree data...\n";
		my $dirname = '/sys';
		my $cmd;
		system("tree -a -L 10 /sys > $data_dir/sys-data-tree-full-10.txt");
		opendir my($dh), $dirname or main::error_handler('open-dir',"$dirname", "$!");
		my @files = readdir $dh;
		closedir $dh;
		foreach (@files){
			next if /^\./;
			$cmd = "tree -a -L 10 $dirname/$_ > $data_dir/sys-data-tree-$_-10.txt";
			#print "$cmd\n";
			system($cmd);
		}
	}
	print "Constructing /$which ls data...\n";
	if ($which eq 'sys'){
		directory_ls($which,1);
		directory_ls($which,2);
		directory_ls($which,3);
		directory_ls($which,4);
	}
	elsif ($which eq 'proc') {
		directory_ls('proc',1);
		directory_ls('proc',2,'[a-z]');
		# don't want the /proc/self or /proc/thread-self directories, those are 
		# too invasive
		#directory_ls('proc',3,'[a-z]');
		#directory_ls('proc',4,'[a-z]');
	}
}

# include is basic regex for ls path syntax, like [a-z]
sub directory_ls {
	my ( $dir,$depth,$include) = @_;
	$include ||= '';
	my ($exclude) = ('');
	# wd do NOT want to see anything in self or thread-self!!
	# $exclude = 'I self -I thread-self' if $dir eq 'proc';
	my $cmd = do {
		if ( $depth == 1 ){ "ls -l $exclude /$dir/$include 2>/dev/null" }
		elsif ( $depth == 2 ){ "ls -l $exclude /$dir/$include*/ 2>/dev/null" }
		elsif ( $depth == 3 ){ "ls -l $exclude /$dir/$include*/*/ 2>/dev/null" }
		elsif ( $depth == 4 ){ "ls -l $exclude /$dir/$include*/*/*/ 2>/dev/null" }
		elsif ( $depth == 5 ){ "ls -l $exclude /$dir/$include*/*/*/*/ 2>/dev/null" }
		elsif ( $depth == 6 ){ "ls -l $exclude /$dir/$include*/*/*/*/*/ 2>/dev/null" }
	};
	my @working = ();
	my $output = '';
	my ($type);
	my $result = qx($cmd);
	open my $ch, '<', \$result or main::error_handler('open-data',"$cmd", "$!");
	while ( my $line = <$ch> ){
		chomp($line);
		$line =~ s/^\s+|\s+$//g;
		@working = split /\s+/, $line;
		$working[0] ||= '';
		if ( scalar @working > 7 ){
			if ($working[0] =~ /^d/ ){
				$type = "d - ";
			}
			elsif ($working[0] =~ /^l/){
				$type = "l - ";
			}
			else {
				$type = "f - ";
			}
			$working[9] ||= '';
			$working[10] ||= '';
			$output = $output . "  $type$working[8] $working[9] $working[10]\n";
		}
		elsif ( $working[0] !~ /^total/ ){
			$output = $output . $line . "\n";
		}
	}
	close $ch;
	my $file = "$data_dir/$dir-data-ls-$depth.txt";
	open my $fh, '>', $file or main::error_handler('create',"$file", "$!");
	print $fh $output;
	close $fh;
	# print "$output\n";
}
sub proc_traverse_data {
	print "Building /proc file list...\n";
	# get rid pointless error:Can't cd to (/sys/kernel/) debug: Permission denied
	no warnings 'File::Find';
	$parse_src = 'proc';
	File::Find::find( \&wanted, "/proc");
	proc_traverse_processor();
	@content = ();
}
sub proc_traverse_processor {
	my ($data,$fh,$result,$row,$sep);
	my $proc_dir = "$data_dir/proc";
	print "Adding /proc files...\n";
	mkdir $proc_dir or main::error_handler('mkdir', "$proc_dir", "$!");
	# @content = sort @content; 
	copy_files(\@content,'proc',$proc_dir);
# 	foreach (@content){
# 		print "$_\n";
# 	}
}

sub sys_traverse_data {
	print "Building /sys file list...\n";
	# get rid pointless error:Can't cd to (/sys/kernel/) debug: Permission denied
	no warnings 'File::Find';
	$parse_src = 'sys';
	File::Find::find( \&wanted, "/sys");
	sys_traverse_processsor();
	@content = ();
}
sub sys_traverse_processsor {
	my ($data,$fh,$result,$row,$sep);
	my $filename = "sys-data-parse.txt";
	print "Parsing /sys files...\n";
	# no sorts, we want the order it comes in
	# @content = sort @content; 
	foreach (@content){
		$data='';
		$sep='';
		my $b_fh = 1;
		print "F:$_\n" if $debugger{'sys-print'};
		open($fh, '<', $_) or $b_fh = 0;
		# needed for removing -T test and root
		if ($b_fh){
			while ($row = <$fh>) {
				chomp $row;
				$data .= $sep . '"' . $row . '"';
				$sep=', ';
			}
		}
		else {
			$data = '<unreadable>';
		}
		$result .= "$_:[$data]\n";
		# print "$_:[$data]\n"
	}
	# print scalar @content . "\n";
	open ($fh, '>', "$data_dir/$filename");
	print $fh $result;
	close $fh;
	# print $fh "$result";
}

sub wanted {
	return if -d; # not directory
	return unless -e; # Must exist
	return unless -f; # Must be file
	return unless -r; # Must be readable
	if ($parse_src eq 'sys'){
		# note: a new file in 4.11 /sys can hang this, it is /parameter/ then
		# a few variables. Since inxi does not need to see that file, we will
		# not use it. Also do not need . files or __ starting files
		# print $File::Find::name . "\n";
		# block maybe: cfgroup\/
		# picdec\/|, wait_for_fb_sleep/wake is an odroid thing caused hang
		# wakeup_count also fails for android, but works fine on regular systems
		return if $b_arm && $File::Find::name =~ /^\/sys\/power\/(wait_for_fb_|wakeup_count$)/;
		return if $File::Find::name =~ /\/(\.[a-z]|kernel\/|trace\/|parameters\/|debug\/)/;
		# pp_num_states: amdgpu driver bug; android: wakeup_count
		return if $File::Find::name =~ /\/pp_num_states$/;
		# comment this one out if you experience hangs or if 
		# we discover syntax of foreign language characters
		# Must be ascii like. This is questionable and might require further
		# investigation, it is removing some characters that we might want
		# NOTE: this made a bunch of files on arm systems unreadable so we handle 
		# the readable tests in copy_files()
		# return unless -T; 
	}
	elsif ($parse_src eq 'proc') {
		return if $File::Find::name =~ /^\/proc\/[0-9]+\//;
		return if $File::Find::name =~ /^\/proc\/bus\/pci\//;
		return if $File::Find::name =~ /^\/proc\/(irq|spl|sys)\//;
		# these choke on sudo/root: kmsg kcore kpage and we don't want keys or kallsyms
		return if $File::Find::name =~ /^\/proc\/k/; 
		return if $File::Find::name =~ /(\/mb_groups|debug)$/;
	}
	# print $File::Find::name . "\n";
	push (@content, $File::Find::name);
	return;
}
# args: 1 - path to file to be uploaded
# args: 2 - optional: alternate ftp upload url
# NOTE: must be in format: ftp.site.com/incoming
sub upload_file {
	require Net::FTP;
	Net::FTP->import;
	my ($self, $ftp_url) = @_;
	my ($ftp, $domain, $host, $user, $pass, $dir, $error);
	$ftp_url ||= main::get_defaults('ftp-upload');
	$ftp_url =~ s/\/$//g; # trim off trailing slash if present
	my @url = split(/\//, $ftp_url);
	my $file_path = "$user_data_dir/$debug_gz";
	$host = $url[0];
	$dir = $url[1];
	$domain = $host;
	$domain =~ s/^ftp\.//;
	$user = "anonymous";
	$pass = "anonymous\@$domain";
	
	print $line3;
	print "Uploading to: $ftp_url\n";
	# print "$host $domain $dir $user $pass\n";
	print "File to be uploaded:\n$file_path\n";
	
	if ($host && ( $file_path && -e $file_path ) ){
		# NOTE: important: must explicitly set to passive true/1
		$ftp = Net::FTP->new($host, Debug => 0, Passive => 1) || main::error_handler('ftp-connect', $ftp->message);
		$ftp->login($user, $pass) || main::error_handler('ftp-login', $ftp->message);
		$ftp->binary();
		$ftp->cwd($dir);
		print "Connected to FTP server.\n";
		$ftp->put($file_path) || main::error_handler('ftp-upload', $ftp->message);
		$ftp->quit;
		print "Uploaded file successfully!\n";
		print $ftp->message;
		if ($debugger{'gz'}){
			print "Removing debugger gz file:\n$file_path\n";
			unlink $file_path or main::error_handler('remove',"$file_path", "$!");
			print "File removed.\n";
		}
		print "Debugger data generation and upload completed. Thank you for your help.\n";
	}
	else {
		main::error_handler('ftp-bad-path', "$file_path");
	}
}
}
# random tests for various issues
sub user_debug_test_1 {
# 	open(my $duped, '>&', STDOUT);
# 	local *STDOUT = $duped;
# 	my $item = POSIX::strftime("%c", localtime);
# 	print "Testing character encoding handling. Perl IO data:\n";
# 	print(join(', ', PerlIO::get_layers(STDOUT)), "\n");
# 	print "Without binmode: ", $item,"\n";
# 	binmode STDOUT,":utf8";
# 	print "With binmode: ", $item,"\n";
# 	print "Perl IO data:\n";
# 	print(join(', ', PerlIO::get_layers(STDOUT)), "\n");
# 	close($duped);
}

#### -------------------------------------------------------------------
#### DOWNLOADER
#### -------------------------------------------------------------------

sub download_file {
	my ($type, $url, $file,$ua) = @_;
	my ($cmd,$args,$timeout) = ('','','');
	my $debug_data = '';
	my $result = 1;
	$ua = ($ua && $dl{'ua'}) ? $dl{'ua'} . $ua : '';
	$dl{'no-ssl-opt'} ||= '';
	$dl{'spider'} ||= '';
	$file ||= 'N/A'; # to avoid debug error
	if ( ! $dl{'dl'} ){
		return 0;
	}
	if ($dl{'timeout'}){
		$timeout = "$dl{'timeout'}$dl_timeout";
	}
	# print "$dl{'no-ssl-opt'}\n";
	# print "$dl{'dl'}\n";
	# tiny supports spider sort of
	## NOTE: 1 is success, 0 false for Perl
	if ($dl{'dl'} eq 'tiny' ){
		$cmd = "Using tiny: type: $type \nurl: $url \nfile: $file";
		$result = get_file($type, $url, $file);
		$debug_data = ($type ne 'stdout') ? $result : 'Success: stdout data not null.';
	}
	# But: 0 is success, and 1 is false for these
	# when strings are returned, they will be taken as true
	# urls must be " quoted in case special characters present
	else {
		if ($type eq 'stdout'){
			$args = $dl{'stdout'};
			$cmd = "$dl{'dl'} $dl{'no-ssl-opt'} $ua $timeout $args \"$url\" $dl{'null'}";
			$result = qx($cmd);
			$debug_data = ($result) ? 'Success: stdout data not null.' : 'Download resulted in null data!';
		}
		elsif ($type eq 'file') {
			$args = $dl{'file'};
			$cmd = "$dl{'dl'} $dl{'no-ssl-opt'} $ua $timeout $args $file \"$url\" $dl{'null'}";
			system($cmd);
			$result = ($?) ? 0 : 1; # reverse these into Perl t/f
			$debug_data = $result;
		}
		elsif ( $dl{'dl'} eq 'wget' && $type eq 'spider'){
			$cmd = "$dl{'dl'} $dl{'no-ssl-opt'} $ua $timeout $dl{'spider'} \"$url\"";
			system($cmd);
			$result = ($?) ? 0 : 1; # reverse these into Perl t/f
			$debug_data = $result;
		}
	}
	print "-------\nDownloader Data:\n$cmd\nResult: $debug_data\n" if $test[1];
	log_data('data',"$cmd\nResult: $result") if $b_log;
	return $result;
}

sub get_file {
	my ($type, $url, $file) = @_;
	my $tiny = HTTP::Tiny->new;
	# note: default is no verify, so default here actually is to verify unless overridden
	$tiny->verify_SSL => 1 if !$dl{'no-ssl-opt'};
	my $response = $tiny->get($url);
	my $return = 1;
	my $debug = 0;
	my $fh;
	$file ||= 'N/A';
	log_data('dump','%{$response}',\%{$response}) if $b_log;
	# print Dumper \%{$response};
	if ( ! $response->{success} ){
		my $content = $response->{content};
		$content ||= "N/A\n";
		my $msg = "Failed to connect to server/file!\n";
		$msg .= "Response: ${content}Downloader: HTTP::Tiny URL: $url\nFile: $file";
		log_data('data',$msg) if $b_log;
		print error_defaults('download-error',$msg) if $test[1];
		$return = 0;
	}
	else {
		if ( $debug ){
			print "$response->{success}\n";
			print "$response->{status} $response->{reason}\n";
			while (my ($key, $value) = each %{$response->{headers}}) {
				for (ref $value eq "ARRAY" ? @$value : $value) {
					print "$key: $_\n";
				}
			}
		}
		if ( $type eq "stdout" || $type eq "ua-stdout" ){
			$return = $response->{content};
		}
		elsif ($type eq "spider"){
			# do nothing, just use the return value
		}
		elsif ($type eq "file"){
			open($fh, ">", $file);
			print $fh $response->{content}; # or die "can't write to file!\n";
			close $fh;
		}
	}
	return $return;
}

sub set_downloader {
	eval $start if $b_log;
	my $quiet = '';
	$dl{'no-ssl'} = '';
	$dl{'null'} = '';
	$dl{'spider'} = '';
	# we only want to use HTTP::Tiny if it's present in user system.
	# It is NOT part of core modules. IO::Socket::SSL is also required 
	# For some https connections so only use tiny as option if both present
	if ($dl{'tiny'}){
		if (check_module('HTTP::Tiny') && check_module('IO::Socket::SSL')){
			HTTP::Tiny->import;
			IO::Socket::SSL->import;
			$dl{'tiny'} = 1;
		}
		else {
			$dl{'tiny'} = 0;
		}
	}
	#print $dl{'tiny'} . "\n";
	if ($dl{'tiny'}){
		$dl{'dl'} = 'tiny';
		$dl{'file'} = '';
		$dl{'stdout'} = '';
		$dl{'timeout'} = '';
	}
	elsif ( $dl{'curl'} && check_program('curl')  ){
		$quiet = '-s ' if !$test[1];
		$dl{'dl'} = 'curl';
		$dl{'file'} = "  -L ${quiet}-o ";
		$dl{'no-ssl'} = ' --insecure';
		$dl{'stdout'} = " -L ${quiet}";
		$dl{'timeout'} = ' -y ';
		$dl{'ua'} = ' -A ' . $dl_ua;
	}
	elsif ($dl{'wget'} && check_program('wget') ){
		$quiet = '-q ' if !$test[1];
		$dl{'dl'} = 'wget';
		$dl{'file'} = " ${quiet}-O ";
		$dl{'no-ssl'} = ' --no-check-certificate';
		$dl{'spider'} = " ${quiet}--spider";
		$dl{'stdout'} = " $quiet -O -";
		$dl{'timeout'} = ' -T ';
		$dl{'ua'} = ' -U ' . $dl_ua;
	}
	elsif ($dl{'fetch'} && check_program('fetch')){
		$quiet = '-q ' if !$test[1];
		$dl{'dl'} = 'fetch';
		$dl{'file'} = " ${quiet}-o ";
		$dl{'no-ssl'} = ' --no-verify-peer';
		$dl{'stdout'} = " ${quiet}-o -";
		$dl{'timeout'} = ' -T ';
	}
	elsif ( $bsd_type eq 'openbsd' && check_program('ftp') ){
		$dl{'dl'} = 'ftp';
		$dl{'file'} = ' -o ';
		$dl{'null'} = ' 2>/dev/null';
		$dl{'stdout'} = ' -o - ';
		$dl{'timeout'} = '';
	}
	else {
		$dl{'dl'} = '';
	}
	# no-ssl-opt is set to 1 with --no-ssl, so it is true, then assign
	$dl{'no-ssl-opt'} = $dl{'no-ssl'} if $dl{'no-ssl-opt'};
	eval $end if $b_log;
}

sub set_perl_downloader {
	my ($downloader) = @_;
	$downloader =~ s/perl/tiny/;
	return $downloader;
}

#### -------------------------------------------------------------------
#### ERROR HANDLER
#### -------------------------------------------------------------------

sub error_handler {
	eval $start if $b_log;
	my ( $err, $one, $two) = @_;
	my ($b_help,$b_recommends);
	my ($b_exit,$errno) = (1,0);
	my $message = do {
		if ( $err eq 'empty' ) { 'empty value' }
		## Basic rules
		elsif ( $err eq 'not-in-irc' ) { 
			$errno=1; "You can't run option $one in an IRC client!" }
		## Internal/external options
		elsif ( $err eq 'bad-arg' ) { 
			$errno=10; $b_help=1; "Unsupported value: $two for option: $one" }
		elsif ( $err eq 'bad-arg-int' ) { 
			$errno=11; "Bad internal argument: $one" }
		elsif ( $err eq 'distro-block' ) { 
			$errno=20; "Option: $one has been disabled by the $self_name distribution maintainer." }
		elsif ( $err eq 'option-feature-incomplete' ) { 
			$errno=21; "Option: '$one' feature: '$two' has not been implemented yet." }
		elsif ( $err eq 'unknown-option' ) { 
			$errno=22; $b_help=1; "Unsupported option: $one" }
		## Data
		elsif ( $err eq 'open-data' ) { 
			$errno=32; "Error opening data for reading: $one \nError: $two" }
		elsif ( $err eq 'download-error' ) { 
			$errno=33; "Error downloading file with $dl{'dl'}: $one \nError: $two" }
		## Files:
		elsif ( $err eq 'copy-failed' ) { 
			$errno=40; "Error copying file: $one \nError: $two" }
		elsif ( $err eq 'create' ) { 
			$errno=41; "Error creating file: $one \nError: $two" }
		elsif ( $err eq 'downloader-error' ) { 
			$errno=42; "Error downloading file: $one \nfor download source: $two" }
		elsif ( $err eq 'file-corrupt' ) { 
			$errno=43; "Downloaded file is corrupted: $one" }
		elsif ( $err eq 'mkdir' ) { 
			$errno=44; "Error creating directory: $one \nError: $two" }
		elsif ( $err eq 'open' ) { 
			$errno=45; $b_exit=0; "Error opening file: $one \nError: $two" }
		elsif ( $err eq 'open-dir' ) { 
			$errno=46; "Error opening directory: $one \nError: $two" }
		elsif ( $err eq 'output-file-bad' ) { 
			$errno=47; "Value for --output-file must be full path, a writable directory, \nand include file name. Path: $two" }
		elsif ( $err eq 'not-writable' ) { 
			$errno=48; "The file: $one is not writable!" }
		elsif ( $err eq 'open-dir-failed' ) { 
			$errno=49; "The directory: $one failed to open with error: $two" }
		elsif ( $err eq 'remove' ) { 
			$errno=50; "Failed to remove file: $one Error: $two" }
		elsif ( $err eq 'rename' ) { 
			$errno=51; "There was an error moving files: $one\nError: $two" }
		elsif ( $err eq 'write' ) { 
			$errno=52; "Failed writing file: $one - Error: $two!" }
		## Downloaders
		elsif ( $err eq 'missing-downloader' ) { 
			$errno=60; "Downloader program $two could not be located on your system." }
		elsif ( $err eq 'missing-perl-downloader' ) { 
			$errno=61; $b_recommends=1; "Perl downloader missing required module." }
		## FTP
		elsif ( $err eq 'ftp-bad-path' ) { 
			$errno=70; "Unable to locate for FTP upload file:\n$one" }
		elsif ( $err eq 'ftp-connect' ) { 
			$errno=71; "There was an error with connection to ftp server: $one" }
		elsif ( $err eq 'ftp-login' ) { 
			$errno=72; "There was an error with login to ftp server: $one" }
		elsif ( $err eq 'ftp-upload' ) { 
			$errno=73; "There was an error with upload to ftp server: $one" }
		## Modules
		elsif ( $err eq 'required-module' ) { 
			$errno=80; $b_recommends=1; "The required $one Perl module is not installed:\n$two" }
		## DEFAULT
		else {
			$errno=255; "Error handler ERROR!! Unsupported options: $err!"}
	};
	print_line("Error $errno: $message\n");
	if ($b_help){
		print_line("Check -h for correct parameters.\n");
	}
	if ($b_recommends){
		print_line("See --recommends for more information.\n");
	}
	eval $end if $b_log;
	exit $errno if $b_exit && !$debugger{'no-exit'};
}

sub error_defaults {
	my ($type,$one) = @_;
	$one ||= '';
	my %errors = (
	'download-error' => "Download Failure:\n$one\n",
	);
	return $errors{$type};
}

#### -------------------------------------------------------------------
#### RECOMMENDS
#### -------------------------------------------------------------------

## CheckRecommends
{
package CheckRecommends;
sub run {
	main::error_handler('not-in-irc', 'recommends') if $b_irc;
	my (@data,@rows);
	my $line = make_line();
	my $pm = get_pm();
	@data = basic_data($line,$pm);
	push @rows,@data;
	if (!$bsd_type){
		@data = check_items('required system directories',$line,$pm);
		push @rows,@data;
	}
	@data = check_items('recommended system programs',$line,$pm);
	push @rows,@data;
	@data = check_items('recommended display information programs',$line,$pm);
	push @rows,@data;
	@data = check_items('recommended downloader programs',$line,$pm);
	push @rows,@data;
	@data = check_items('recommended Perl modules',$line,$pm);
	push @rows,@data;
	@data = check_items('recommended directories',$line,'');
	push @rows,@data;
	@data = check_items('recommended files',$line,'');
	push @rows,@data;
	@data = (
	['0', '', '', "$line"],
	['0', '', '', "Ok, all done with the checks. Have a nice day."],
	['0', '', '', " "],
	);
	push @rows,@data;
	#print Data::Dumper::Dumper \@rows;
	main::print_basic(@rows); 
	exit 0; # shell true
}

sub basic_data {
	my ($line,$pm_local) = @_;
	my (@data,@rows);
	my $client = $client{'name-print'};
	$pm_local ||= 'N/A';
	$client .= ' ' . $client{'version'} if $client{'version'};
	my $default_shell = 'N/A';
	if ($ENV{'SHELL'}){
		$default_shell = $ENV{'SHELL'};
		$default_shell =~ s/.*\///;
	}
	my $sh = main::check_program('sh');
	my $sh_real = Cwd::abs_path($sh);
	@rows = (
	['0', '', '', "$self_name will now begin checking for the programs it needs 
	to operate."],
	['0', '', '', "" ],
	['0', '', '', "Check $self_name --help or the man page (man $self_name) 
	to see what options are available." ],
	['0', '', '', "$line" ],
	['0', '', '', "Test: core tools:" ],
	['0', '', '', "" ],
	['0', '', '', "Perl version: ^$]" ],
	['0', '', '', "Current shell: " . $client ],
	['0', '', '', "Default shell: " . $default_shell ],
	['0', '', '', "sh links to: $sh_real" ],
	['0', '', '', "Package manager: $pm_local" ],
	);
	return @rows;
}
sub check_items {
	my ($type,$line,$pm) = @_;
	my (@data,%info,@missing,$row,@rows,$result,@unreadable);
	my ($b_dir,$b_file,$b_module,$b_program,$item);
	my ($about,$extra,$extra2,$extra3,$extra4,$info_os,$install) = ('','','','','','info','');
	if ($type eq 'required system directories'){
		@data = qw(/proc /sys);
		$b_dir = 1;
		$item = 'Directory';
	}
	elsif ($type eq 'recommended system programs'){
		if ($bsd_type){
			@data = qw(camcontrol dig dmidecode fdisk file glabel gpart ifconfig ipmi-sensors 
			ipmitool lsusb sudo smartctl sysctl tree upower uptime usbdevs);
			$info_os = 'info-bsd';
		}
		else {
			@data = qw(blockdev dig dmidecode fdisk file hddtemp ifconfig ip ipmitool 
			ipmi-sensors lsblk lsusb modinfo runlevel sensors smartctl strings sudo 
			tree upower uptime);
		}
		$b_program = 1;
		$item = 'Program';
		$extra2 = "Note: IPMI sensors are generally only found on servers. To access 
		that data, you only need one of the ipmi items.";
	}
	elsif ($type eq 'recommended display information programs'){
		if ($bsd_type){
			@data = qw(glxinfo wmctrl xdpyinfo xprop xrandr);
			$info_os = 'info-bsd';
		}
		else {
			@data = qw(glxinfo wmctrl xdpyinfo xprop xrandr);
		}
		$b_program = 1;
		$item = 'Program';
	}
	elsif ($type eq 'recommended downloader programs'){
		if ($bsd_type){
			@data = qw(curl dig fetch ftp wget);
			$info_os = 'info-bsd';
		}
		else {
			@data = qw(curl dig wget);
		}
		$b_program = 1;
		$extra = ' (You only need one of these)';
		$extra2 = "Perl HTTP::Tiny is the default downloader tool if IO::Socket::SSL is present.
		See --help --alt 40-44 options for how to override default downloader(s) in case of issues. ";
		$extra3 = "If dig is installed, it is the default for WAN IP data. 
		Strongly recommended. Dig is fast and accurate.";
		$extra4 = ". However, you really only need dig in most cases. All systems should have ";
		$extra4 .= "at least one of the downloader options present.";
		$item = 'Program';
	}
	elsif ($type eq 'recommended Perl modules'){
		@data = qw(HTTP::Tiny IO::Socket::SSL Time::HiRes Cpanel::JSON::XS JSON::XS XML::Dumper Net::FTP);
		$b_module = 1;
		$item = 'Perl Module';
		$extra = ' (Optional)';
		$extra2 = "None of these are strictly required, but if you have them all, you can eliminate
		some recommended non Perl programs from the install. ";
		$extra3 = "HTTP::Tiny and IO::Socket::SSL must both be present to use as a downloader option. 
		For json export Cpanel::JSON::XS is preferred over JSON::XS.";
	}
	elsif ($type eq 'recommended directories'){
		if ($bsd_type){
			@data = qw(/dev);
		}
		else {
			@data = qw(/dev /dev/disk/by-id /dev/disk/by-label /dev/disk/by-path 
			/dev/disk/by-uuid /sys/class/dmi/id);
		}
		$b_dir = 1;
		$item = 'Directory';
	}
	elsif ($type eq 'recommended files'){
		if ($bsd_type){
			@data = qw(/var/run/dmesg.boot /var/log/Xorg.0.log);
		}
		else {
			@data = qw(/etc/lsb-release /etc/os-release /proc/asound/cards 
			/proc/asound/version /proc/cpuinfo /proc/mdstat /proc/meminfo /proc/modules 
			/proc/mounts /proc/scsi/scsi /var/log/Xorg.0.log );
		}
		$b_file = 1;
		$item = 'File';
		$extra2 = "Note that not all of these are used by every system, 
		so if one is missing it's usually not a big deal.";
	}
	@rows = (
	['0', '', '', "$line" ],
	['0', '', '', "Test: $type$extra:" ],
	['0', '', '', " " ],
	);
	if ($extra2){
		$rows[scalar @rows] = (['0', '', '', $extra2]);
		$rows[scalar @rows] = (['0', '', '', ' ']);
	}
	if ($extra3){
		$rows[scalar @rows] = (['0', '', '', $extra3]);
		$rows[scalar @rows] = (['0', '', '', ' ']);
	}
	foreach (@data){
		$install = '';
		$about = '';
		%info = item_data($_);
		$about = $info{$info_os};
		if ( ( $b_dir && -d $_ ) || ( $b_file && -r $_ ) ||
		     ($b_program && main::check_program($_) ) || ($b_module && main::check_module($_)) ){
			$result = 'Present';
		}
		elsif ($b_file && -f $_){
			$result = 'Unreadable';
			push @unreadable, "$_";
		}
		else {
			$result = 'Missing';
			if (($b_program || $b_module) && $pm){
				$info{$pm} ||= 'N/A';
				$install = " ~ Install package: $info{$pm}";
			}
			push @missing, "$_$install";
		}
		$row = make_row($_,$about,$result);
		$rows[scalar @rows] = (['0', '', '', $row]);
	}
	$rows[scalar @rows] = (['0', '', '', " "]);
	if (@missing){
		$rows[scalar @rows] = (['0', '', '', "The following $type are missing$extra4:"]);
		foreach (@missing) {
			$rows[scalar @rows] = (['0', '', '', "$item: $_"]);
		}
	}
	if (@unreadable){
		$rows[scalar @rows] = (['0', '', '', "The following $type are not readable: "]);
		foreach (@unreadable) {
			$rows[scalar @rows] = (['0', '', '', "$item: $_"]);
		}
	}
	if (!@missing && !@unreadable){
		$rows[scalar @rows] = (['0', '', '', "All $type are present"]);
	}
	return @rows;
}

sub item_data {
	my ($type) = @_;
	my %data = (
	# Directory Data
	'/sys/class/dmi/id' => ({
	'info' => '-M system, motherboard, bios',
	}),
	'/dev' => ({
	'info' => '-l,-u,-o,-p,-P,-D disk partition data',
	}),
	'/dev/disk/by-id' => ({
	'info' => '-D serial numbers',
	}),
	'/dev/disk/by-path' => ({
	'info' => '-D extra data',
	}),
	'/dev/disk/by-label' => ({
	'info' => '-l,-o,-p,-P partition labels',
	}),
	'/dev/disk/by-uuid' => ({
	'info' => '-u,-o,-p,-P partition uuid',
	}),
	'/proc' => ({
	'info' => '',
	}),
	'/sys' => ({
	'info' => '',
	}),
	# File Data
	'/etc/lsb-release' => ({
	'info' => '-S distro version data (older version)',
	}),
	'/etc/os-release' => ({
	'info' => '-S distro version data (newer version)',
	}),
	'/proc/asound/cards' => ({
	'info' => '-A sound card data',
	}),
	'/proc/asound/version' => ({
	'info' => '-A ALSA data',
	}),
	'/proc/cpuinfo' => ({
	'info' => '-C cpu data',
	}),
	'/proc/mdstat' => ({
	'info' => '-R mdraid data (if you use dm-raid)',
	}),
	'/proc/meminfo' => ({
	'info' => '-I,-tm, -m memory data',
	}),
	'/proc/modules' => ({
	'info' => '-G module data (sometimes)',
	}),
	'/proc/mounts' => ({
	'info' => '-P,-p partition advanced data',
	}),
	'/proc/scsi/scsi' => ({
	'info' => '-D Advanced hard disk data (used rarely)',
	}),
	'/var/log/Xorg.0.log' => ({
	'info' => '-G graphics driver load status',
	}),
	'/var/run/dmesg.boot' => ({
	'info' => '-D,-d disk data',
	}),
	## START PACKAGE MANAGER BLOCK ##
	# Note: see inxi-perl branch for details: docs/recommends-package-manager.txt
	# System Tools
	'blockdev' => ({
	'info' => '--admin -p/-P (filesystem blocksize)',
	'info-bsd' => '',
	'apt' => 'util-linux',
	'pacman' => 'util-linux',
	'rpm' => 'util-linux',
	}),
	'curl' => ({
	'info' => '-i (if no dig); -w,-W; -U',
	'info-bsd' => '-i (if no dig); -w,-W; -U',
	'apt' => 'curl',
	'pacman' => 'curl',
	'rpm' => 'curl',
	}),
	'camcontrol' => ({
	'info' => '',
	'info-bsd' => '-R; -D; -P. Get actual gptid /dev path',
	'apt' => '',
	'pacman' => '',
	'rpm' => '',
	}),
	'dig' => ({
	'info' => '-i wlan IP',
	'info-bsd' => '-i wlan IP',
	'apt' => 'dnsutils',
	'pacman' => 'dnsutils',
	'rpm' => 'bind-utils',
	}),
	'dmidecode' => ({
	'info' => '-M if no sys machine data; -m',
	'info-bsd' => '-M if null sysctl; -m; -B if null sysctl',
	'apt' => 'dmidecode',
	'pacman' => 'dmidecode',
	'rpm' => 'dmidecode',
	}),
	'fdisk' => ({
	'info' => '-D partition scheme (fallback)',
	'info-bsd' => '-D partition scheme',
	'apt' => 'fdisk',
	'pacman' => 'util-linux',
	'rpm' => 'util-linux',
	}),
	'fetch' => ({
	'info' => '',
	'info-bsd' => '-i (if no dig); -w,-W; -U',
	'apt' => '',
	'pacman' => '',
	'rpm' => '',
	}),
	'file' => ({
	'info' => '-o unmounted file system (if no lsblk)',
	'info-bsd' => '-o unmounted file system',
	'apt' => 'file',
	'pacman' => 'file',
	'rpm' => 'file',
	}),
	'ftp' => ({
	'info' => '',
	'info-bsd' => '-i (if no dig); -w,-W; -U',
	'apt' => '',
	'pacman' => '',
	'rpm' => '',
	}),
	'glabel' => ({
	'info' => '',
	'info-bsd' => '-R; -D; -P. Get actual gptid /dev path',
	'apt' => '',
	'pacman' => '',
	'rpm' => '',
	}),
	'gpart' => ({
	'info' => '',
	'info-bsd' => '-p,-P file system, size',
	'apt' => '',
	'pacman' => '',
	'rpm' => '',
	}),
	'hciconfig' => ({
	'info' => 'Experimental',
	'info-bsd' => '',
	'apt' => 'bluez',
	'pacman' => 'bluez-utils',
	'rpm' => 'bluez-utils',
	}),
	'hddtemp' => ({
	'info' => '-Dx show hdd temp',
	'info-bsd' => '-Dx show hdd temp',
	'apt' => 'hddtemp',
	'pacman' => 'hddtemp',
	'rpm' => 'hddtemp',
	}),
	'ifconfig' => ({
	'info' => '-i ip LAN (deprecated)',
	'info-bsd' => '-i ip LAN',
	'apt' => 'net-tools',
	'pacman' => 'net-tools',
	'rpm' => 'net-tools',
	}),
	'ip' => ({
	'info' => '-i ip LAN',
	'info-bsd' => '',
	'apt' => 'iproute',
	'pacman' => 'iproute2',
	'rpm' => 'iproute',
	}),
	'ipmi-sensors' => ({
	'info' => '-s IPMI sensors (servers)',
	'info-bsd' => '',
	'apt' => 'freeipmi-tools',
	'pacman' => 'freeipmi',
	'rpm' => 'freeipmi',
	}),
	'ipmitool' => ({
	'info' => '-s IPMI sensors (servers)',
	'info-bsd' => '-s IPMI sensors (servers)',
	'apt' => 'ipmitool',
	'pacman' => 'ipmitool',
	'rpm' => 'ipmitool',
	}),
	'lsblk' => ({
	'info' => '-o unmounted file system (best option)',
	'info-bsd' => '-o unmounted file system',
	'apt' => 'util-linux',
	'pacman' => 'util-linux',
	'rpm' => 'util-linux-ng',
	}),
	'lsusb' => ({
	'info' => '-A usb audio; -J (optional); -N usb networking',
	'info-bsd' => '-A; -J; -N. Alternate to usbdevs',
	'apt' => 'usbutils',
	'pacman' => 'usbutils',
	'rpm' => 'usbutils',
	}),
	'modinfo' => ({
	'info' => 'Ax; -Nx module version',
	'info-bsd' => '',
	'apt' => 'module-init-tools',
	'pacman' => 'module-init-tools',
	'rpm' => 'module-init-tools',
	}),
	'runlevel' => ({
	'info' => '-I fallback to Perl',
	'info-bsd' => '',
	'apt' => 'systemd or sysvinit',
	'pacman' => 'systemd',
	'rpm' => 'systemd or sysvinit',
	}),
	'sensors' => ({
	'info' => '-s sensors output',
	'info-bsd' => '',
	'apt' => 'lm-sensors',
	'pacman' => 'lm-sensors',
	'rpm' => 'lm-sensors',
	}),
	'smartctl' => ({
	'info' => '-Da advanced data',
	'info-bsd' => '-Da advanced data',
	'apt' => 'smartmontools',
	'pacman' => 'smartmontools',
	'rpm' => 'smartmontools',
	}),
	'strings' => ({
	'info' => '-I sysvinit version',
	'info-bsd' => '',
	'apt' => 'binutils',
	'pacman' => '?',
	'rpm' => '?',
	}),
	'sysctl' => ({
	'info' => '',
	'info-bsd' => '-C; -I; -m; -tm',
	'apt' => '?',
	'pacman' => '?',
	'rpm' => '?',
	}),
	'sudo' => ({
	'info' => '-Dx hddtemp-user; -o file-user',
	'info-bsd' => '-Dx hddtemp-user; -o file-user',
	'apt' => 'sudo',
	'pacman' => 'sudo',
	'rpm' => 'sudo',
	}),
	'tree' => ({
	'info' => '--debugger 20,21 /sys tree',
	'info-bsd' => '--debugger 20,21 /sys tree',
	'apt' => 'tree',
	'pacman' => 'tree',
	'rpm' => 'tree',
	}),
	'upower' => ({
	'info' => '-sx attached device battery info',
	'info-bsd' => '-sx attached device battery info',
	'apt' => 'upower',
	'pacman' => 'upower',
	'rpm' => 'upower',
	}),
	'uptime' => ({
	'info' => '-I uptime',
	'info-bsd' => '-I uptime',
	'apt' => 'procps',
	'pacman' => 'procps',
	'rpm' => 'procps',
	}),
	'usbdevs' => ({
	'info' => '',
	'info-bsd' => '-A; -J; -N;',
	'apt' => 'usbutils',
	'pacman' => 'usbutils',
	'rpm' => 'usbutils',
	}),
	'wget' => ({
	'info' => '-i (if no dig); -w,-W; -U',
	'info-bsd' => '-i (if no dig); -w,-W; -U',
	'apt' => 'wget',
	'pacman' => 'wget',
	'rpm' => 'wget',
	}),
	# Display Tools
	'glxinfo' => ({
	'info' => '-G glx info',
	'info-bsd' => '-G glx info',
	'apt' => 'mesa-utils',
	'pacman' => 'mesa-demos',
	'rpm' => 'glx-utils (openSUSE 12.3 and later Mesa-demo-x)',
	}),
	'wmctrl' => ({
	'info' => '-S active window manager (fallback)',
	'info-bsd' => '-S active window managerr (fallback)',
	'apt' => 'wmctrl',
	'pacman' => 'wmctrl',
	'rpm' => 'wmctrl',
	}),
	'xdpyinfo' => ({
	'info' => '-G multi screen resolution',
	'info-bsd' => '-G multi screen resolution',
	'apt' => 'X11-utils',
	'pacman' => 'xorg-xdpyinfo',
	'rpm' => 'xorg-x11-utils',
	}),
	'xprop' => ({
	'info' => '-S desktop data',
	'info-bsd' => '-S desktop data',
	'apt' => 'X11-utils',
	'pacman' => 'xorg-xprop',
	'rpm' => 'x11-utils',
	}),
	'xrandr' => ({
	'info' => '-G single screen resolution',
	'info-bsd' => '-G single screen resolution',
	'apt' => 'x11-xserver-utils',
	'pacman' => 'xrandr',
	'rpm' => 'x11-server-utils',
	}),
	# Perl Modules
	'Cpanel::JSON::XS' => ({
	'info' => '--output json - required for export.',
	'info-bsd' => '--output json - required for export.',
	'apt' => 'libcpanel-json-xs-perl',
	'pacman' => 'perl-cpanel-json-xs',
	'rpm' => 'perl-Cpanel-JSON-XS',
	}),
	'HTTP::Tiny' => ({
	'info' => '-U; -w,-W; -i (if dig not installed).',
	'info-bsd' => '-U; -w,-W; -i (if dig not installed)',
	'apt' => 'libhttp-tiny-perl',
	'pacman' => 'Core Modules',
	'rpm' => 'Perl-http-tiny',
	}),
	'IO::Socket::SSL' => ({
	'info' => '-U; -w,-W; -i (if dig not installed).',
	'info-bsd' => '-U; -w,-W; -i (if dig not installed)',
	'apt' => 'libio-socket-ssl-perl',
	'pacman' => 'perl-io-socket-ssl',
	'rpm' => 'perl-IO-Socket-SSL',
	}),
	'JSON::XS' => ({
	'info' => '--output json - required for export (legacy).',
	'info-bsd' => '--output json - required for export (legacy).',
	'apt' => 'libjson-xs-perl',
	'pacman' => 'perl-json-xs',
	'rpm' => 'perl-JSON-XS',
	}),
	'Net::FTP' => ({
	'info' => '--debug 21,22',
	'info-bsd' => '--debug 21,22',
	'apt' => 'Core Modules',
	'pacman' => 'Core Modules',
	'rpm' => 'Core Modules',
	}),
	'Time::HiRes' => ({
	'info' => '-C cpu sleep (not required); --debug timers',
	'info-bsd' => '-C cpu sleep (not required); --debug timers',
	'apt' => 'Core Modules',
	'pacman' => 'Core Modules',
	'rpm' => 'perl-Time-HiRes',
	}),
	'XML::Dumper' => ({
	'info' => '--output xml - Crude and raw.',
	'info-bsd' => '--output xml - Crude and raw.',
	'apt' => 'libxml-dumper-perl',
	'pacman' => 'perl-xml-dumper',
	'rpm' => 'perl-XML-Dumper',
	}),
	## END PACKAGE MANAGER BLOCK ##
	);
	my $ref = $data{$type};
	my %values = %$ref;
	return %values;
}
sub get_pm {
	my ($pm) = ('');
	# support maintainers of other pm types using custom lists
	if (main::check_program('dpkg')){
		$pm = 'apt';
	}
	elsif (main::check_program('pacman')){
		$pm = 'pacman';
	}
	elsif (main::check_program('rpm')){
		$pm = 'rpm';
	}
	return $pm;
}
# note: end will vary, but should always be treated as longest value possible.
# expected values: Present/Missing
sub make_row {
	my ($start,$middle,$end) = @_;
	my ($dots,$line,$sep) = ('','',': ');
	foreach (0 .. ($size{'max'} - 16 - length("$start$middle"))){
		$dots .= '.';
	}
	$line = "$start$sep$middle$dots $end";
	return $line;
}
sub make_line {
	my $line = '';
	foreach (0 .. $size{'max'} - 2 ){
		$line .= '-';
	}
	return $line;
}
}

#### -------------------------------------------------------------------
#### TOOLS
#### -------------------------------------------------------------------

# Duplicates the functionality of awk to allow for one liner
# type data parsing. note: -1 corresponds to awk NF
# args 1: array of data; 2: search term; 3: field result; 4: separator
# correpsonds to: awk -F='separator' '/search/ {print $2}' <<< @data
# array is sent by reference so it must be dereferenced
# NOTE: if you just want the first row, pass it \S as search string
# NOTE: if $num is undefined, it will skip the second step
sub awk {
	eval $start if $b_log;
	my ($ref,$search,$num,$sep) = @_;
	my ($result);
	# print "search: $search\n";
	return if ! @$ref || ! $search;
	foreach (@$ref){
		if (/$search/i){
			$result = $_;
			$result =~ s/^\s+|\s+$//g;
			last;
		}
	}
	if ($result && defined $num){
		$sep ||= '\s+';
		$num-- if $num > 0; # retain the negative values as is
		$result = (split /$sep/, $result)[$num];
		$result =~ s/^\s+|,|\s+$//g if $result;
	}
	eval $end if $b_log;
	return $result;
}

# $1 - Perl module to check
sub check_module {
	my ($module) = @_;
	my $b_present = 0;
	eval "require $module";
	$b_present = 1 if !$@;
	return $b_present;
}

# arg: 1 - string or path to search gneerated @paths data for.
# note: a few nano seconds are saved by using raw $_[0] for program
sub check_program {
	(grep { return "$_/$_[0]" if -e "$_/$_[0]"} @paths)[0];
}

sub cleanup {
	# maybe add in future: , $fh_c, $fh_j, $fh_x
	foreach my $fh ($fh_l){
		if ($fh){
			close $fh;
		}
	}
}

# args: $1, $2, version numbers to compare by turning them to strings
# note that the structure of the two numbers is expected to be fairly 
# similar, otherwise it may not work perfectly.
sub compare_versions {
	my ($one,$two) = @_;
	if ($one && !$two){return $one;}
	elsif ($two && !$one){return $two;}
	elsif (!$one && !$two){return}
	my ($pad1,$pad2) = ('','');
	my (@temp1) = split /[._-]/, $one;
	my (@temp2) = split /[._-]/, $two;
	@temp1 = map {$_ = sprintf("%04s", $_);$_ } @temp1;
	@temp2 = map {$_ = sprintf("%04s", $_);$_ } @temp2;
	$pad1 = join '', @temp1;
	$pad2 = join '', @temp2;
	# print "p1:$pad1 p2:$pad2\n";
	if ($pad1 ge $pad2){return $one}
	elsif ($pad2 gt $pad1){return $two}
}

# some things randomly use hex with 0x starter, return always integer
# warning: perl will generate a 32 bit too big number warning if you pass it
# random values that exceed 2^32 in hex, even if the base system is 64 bit. 
# sample: convert_hex(0x000b0000000b);
sub convert_hex {
	return (defined $_[0] && $_[0] =~ /^0x/) ? hex($_[0]) : $_[0];
}
# returns count of files in directory, if 0, dir is empty
sub count_dir_files {
	return unless -d $_[0];
	opendir my $dh, $_[0] or error_handler('open-dir-failed', "$_[0]", $!); 
	my $count = grep { ! /^\.{1,2}/ } readdir $dh; # strips out . and ..
	return $count;
}

# args: 1 - the string to get piece of
# 2 - the position in string, starting at 1 for 0 index.
# 3 - the separator, default is ' '
sub get_piece {
	eval $start if $b_log;
	my ($string, $num, $sep) = @_;
	$num--;
	$sep ||= '\s+';
	$string =~ s/^\s+|\s+$//g;
	my @temp = split(/$sep/, $string);
	eval $end if $b_log;
	if ( exists $temp[$num] ){
		$temp[$num] =~ s/,//g;
		return $temp[$num];
	}
}

# arg: 1 - command to turn into an array; 2 - optional: splitter
# 3 - optionsl, strip and clean data
# similar to reader() except this creates an array of data 
# by lines from the command arg
sub grabber {
	eval $start if $b_log;
	my ($cmd,$split,$strip) = @_;
	$split ||= "\n";
	my @rows = split /$split/, qx($cmd);
	if ($strip && @rows){
		@rows = grep {/^\s*[^#]/} @rows;
		@rows = map {s/^\s+|\s+$//g; $_} @rows if @rows;
	}
	eval $end if $b_log;
	return @rows;
}

# args: 1 - string value to glob
sub globber {
	eval $start if $b_log;
	my @files = <$_[0]>;
	eval $end if $b_log;
	return @files;
}
# arg MUST be quoted when inserted, otherwise perl takes it for a hex number
sub is_hex {
	return (defined $_[0] && $_[0] =~ /^0x/) ? 1 : 0;
}

## NOTE: for perl pre 5.012 length(undef) returns warning
# receives string, returns boolean 1 if integer
sub is_int {
	return 1 if (defined $_[0] && length($_[0]) && length($_[0]) == ($_[0] =~ tr/0123456789//));
}

# receives string, returns boolean 1 if numeric. tr/// is 4x faster than regex
sub is_numeric {
	return 1 if ( defined $_[0] && ( $_[0] =~ tr/0123456789//) >= 1 && 
	length($_[0]) == ($_[0] =~ tr/0123456789.//) && ($_[0] =~ tr/.//) <= 1);
}

# gets array ref, which may be undefined, plus join string
# this helps avoid debugger print errors when we are printing arrays
# which we don't know are defined or not null.
# args: 1 - array ref; 2 - join string; 3 - default value, optional
sub joiner {
	my ($ref,$join,$default) = @_;
	my @arr = @$ref;
	$default ||= '';
	my $string = '';
	foreach (@arr){
		if (defined $_){
			$string .= $_ . $join;
		}
		else {
			$string .= $default . $join;
		}
	}
	return $string;
}

# returns array of: 0: program print name 1: program version
# args: 1: program values id  2: program version string
# 3: $extra level. Note that StartClient runs BEFORE -x levels are set!
# Only use this function when you only need the name/version data returned
sub program_data {
	eval $start if $b_log;
	my ($values_id,$version_id,$level) = @_;
	my (@data,$path,@program_data);
	$level = 0 if ! $level;
	#print "val_id: $values_id ver_id:$version_id lev:$level ex:$extra\n";
	$version_id = $values_id if ! $version_id;
	@data = program_values($values_id);
	if ($data[3]){
		$program_data[0] = $data[3];
		# programs that have no version method return 0 0 for index 1 and 2
		if ( $extra >= $level && $data[1] && $data[2]){
			$program_data[1] = program_version($version_id,$data[0],
			$data[1],$data[2],$data[5],$data[6],$data[7],$data[8]);
		}
	}
	$program_data[0] ||= '';
	$program_data[1] ||= '';
	eval $end if $b_log;
	return @program_data;
}

# it's almost 1000 times slower to load these each time program_values is called!!
sub set_program_values {
	%program_values = (
	## Clients ##
	'bitchx' => ['bitchx',2,'','BitchX',1,0,0,'',''],# special
	'finch' => ['finch',2,'-v','Finch',1,1,0,'',''],
	'gaim' => ['[0-9.]+',2,'-v','Gaim',0,1,0,'',''],
	'ircii' => ['[0-9.]+',3,'-v','ircII',1,1,0,'',''],
	'irssi' => ['irssi',2,'-v','Irssi',1,1,0,'',''],
	'irssi-text' => ['irssi',2,'-v','Irssi',1,1,0,'',''],
	'konversation' => ['konversation',2,'-v','Konversation',0,0,0,'',''],
	'kopete' => ['Kopete',2,'-v','Kopete',0,0,0,'',''],
	'kvirc' => ['[0-9.]+',2,'-v','KVIrc',0,0,1,'',''], # special
	'pidgin' => ['[0-9.]+',2,'-v','Pidgin',0,1,0,'',''],
	'quassel' => ['',1,'-v','Quassel [M]',0,0,0,'',''], # special
	'quasselclient' => ['',1,'-v','Quassel',0,0,0,'',''],# special
	'quasselcore' => ['',1,'-v','Quassel (core)',0,0,0,'',''],# special
	'gribble' => ['^Supybot',2,'--version','Gribble',1,0,0,'',''],# special
	'limnoria' => ['^Supybot',2,'--version','Limnoria',1,0,0,'',''],# special
	'supybot' => ['^Supybot',2,'--version','Supybot',1,0,0,'',''],# special
	'weechat' => ['[0-9.]+',1,'-v','WeeChat',1,0,0,'',''],
	'weechat-curses' => ['[0-9.]+',1,'-v','WeeChat',1,0,0,'',''],
	'xchat-gnome' => ['[0-9.]+',2,'-v','X-Chat-Gnome',1,1,0,'',''],
	'xchat' => ['[0-9.]+',2,'-v','X-Chat',1,1,0,'',''],
	## Desktops / wm / compositors ##
	'3dwm' => ['^3dwm',0,'0','3Dwm',0,1,0,'',''], # unverified
	'9wm' => ['^9wm',3,'-version','9wm',0,1,0,'',''],
	'aewm' => ['^aewm',3,'--version','aewm',0,1,0,'',''],
	'aewm++' => ['^Version:',2,'-version','aewm++',0,1,0,'',''],
	'afterstep' => ['^afterstep',3,'--version','AfterStep',0,1,0,'',''],
	'amiwm' => ['^amiwm',0,'0','AmiWM',0,1,0,'',''], # no version
	'antiwm' => ['^antiwm',0,'0','AntiWM',0,1,0,'',''], # no version known
	'asc' => ['^asc',0,'0','asc',0,1,0,'',''],
	'awesome' => ['^awesome',2,'--version','awesome',0,1,0,'',''],
	'beryl' => ['^beryl',0,'0','Beryl',0,1,0,'',''], # unverified; legacy
	'blackbox' => ['^Blackbox',2,'--version','Blackbox',0,1,0,'',''],
	'bspwm' => ['^\S',1,'-v','bspwm',0,1,0,'',''],
	'budgie-desktop' => ['^budgie-desktop',2,'--version','Budgie',0,1,0,'',''],
	'budgie-wm' => ['^budgie',0,'0','budgie-wm',0,1,0,'',''],
	'cagebreak' => ['^Cagebreak',3,'-v','Cagebreak',0,1,0,'',''],
	'calmwm' => ['^calmwm',0,'0','CalmWM',0,1,0,'',''], # unverified
	'cinnamon' => ['^cinnamon',2,'--version','Cinnamon',0,1,0,'',''],
	'clfswm' => ['^clsfwm',0,'0','clfswm',0,1,0,'',''], # no version
	'compiz' => ['^compiz',2,'--version','Compiz',0,1,0,'',''],
	'compton' => ['^\d',1,'--version','Compton',0,1,0,'',''],
	'cwm' => ['^cwm',0,'0','CWM',0,1,0,'',''], # no version
	'dcompmgr' => ['^dcompmgr',0,'0','dcompmgr',0,1,0,'',''], # unverified
	'deepin' => ['^Version',2,'file','Deepin',0,100,'=','','/etc/deepin-version'], # special
	'deepin-metacity' => ['^metacity',2,'--version','Deepin-Metacity',0,1,0,'',''],
	'deepin-mutter' => ['^mutter',2,'--version','Deepin-Mutter',0,1,0,'',''],
	'deepin-wm' => ['^gala',0,'0','DeepinWM',0,1,0,'',''], # no version
	'dwc' => ['^dwc',0,'0','dwc',0,1,0,'',''], # unverified
	'dwm' => ['^dwm',1,'-v','dwm',0,1,1,'^dwm-',''],
	'echinus' => ['^echinus',1,'-v','echinus',0,1,1,'',''], # echinus-0.4.9 (c)...
	# only listed here for compositor values, version data comes from xprop
	'enlightenment' => ['^enlightenment',0,'0','enlightenment',0,1,0,'',''], # no version, yet?
	'evilwm' => ['evilwm',3,'-V','evilwm',0,1,0,'',''],# might use full path in match
	'fireplace' => ['^fireplace',0,'0','fireplace',0,1,0,'',''], # unverified
	'fluxbox' => ['^fluxbox',2,'-v','Fluxbox',0,1,0,'',''],
	'flwm' => ['^flwm',0,'0','FLWM',0,0,1,'',''], # no version
	'fvwm' => ['^fvwm',2,'-version','FVWM',0,1,0,'',''],
	'fvwm1' => ['^Fvwm',3,'-version','FVWM1',0,1,1,'',''],
	'fvwm2' => ['^fvwm',2,'--version','fVWM2',0,1,0,'',''],
	'fvwm3' => ['^fvwm',2,'--version','fVWM3',0,1,0,'',''],
	'fvwm95' => ['^fvwm',2,'--version','FVWM95',0,1,1,'',''],
	'fvwm-crystal' => ['^fvwm',2,'--version','FVWM-Crystal',0,0,0,'',''], # for print name fvwm
	'gala' => ['^gala',0,'0','gala',0,1,0,'',''], # pantheon wm: super slow result, 2, '--version' works?
	'glass' => ['^glass',3,'-v','Glass',0,1,0,'',''], 
	'gnome' => ['^gnome',3,'--version','GNOME',0,1,0,'',''], # no version, print name
	'gnome-about' => ['^gnome',3,'--version','GNOME',0,1,0,'',''],
	'gnome-shell' => ['^gnome',3,'--version','gnome-shell',0,1,0,'',''],
	'grefson' => ['^grefson',0,'0','grefson',0,1,0,'',''], # unverified
	'hackedbox' => ['^hackedbox',2,'-version','HackedBox',0,1,0,'',''], # unverified, assume blackbox
	# note, herbstluftwm when launched with full path returns full path in version string
	'herbstluftwm' => ['herbstluftwm',2,'--version','herbstluftwm',0,1,0,'',''],
	'i3' => ['^i3',3,'--version','i3',0,1,0,'',''],
	'icewm' => ['^icewm',2,'--version','IceWM',0,1,0,'',''],
	'instantwm' => ['^instantwm',1,'-v','instantWM',0,1,1,'^instantwm-?(instantos-?)?',''],
	'ion3' => ['^ion3',0,'--version','Ion3',0,1,0,'',''], # unverified; also shell called ion
	'jbwm' => ['jbwm',3,'-v','JBWM',0,1,0,'',''], # might use full path in match
	'jwm' => ['^jwm',2,'--version','JWM',0,1,0,'',''],
	'kded' => ['^KDE Development Platform:',4,'--version','KDE',0,1,0,'',''],
	'kded1' => ['^KDE Development Platform:',4,'--version','KDE',0,1,0,'',''],
	'kded2' => ['^KDE Development Platform:',4,'--version','KDE',0,1,0,'',''],
	'kded3' => ['^KDE Development Platform:',4,'--version','KDE',0,1,0,'',''],
	'kded4' => ['^KDE Development Platform:',4,'--version','KDE',0,1,0,'',''],
	'ksmcon' => ['^ksmcon',0,'0','ksmcon',0,1,0,'',''],# no version
	'kwin' => ['^kwin',0,'0','kwin',0,1,0,'',''],# no version
	'kwin_wayland' => ['^kwin_wayland',0,'0','kwin_wayland',0,1,0,'',''],# no version
	'kwin_x11' => ['^kwin_x11',0,'0','kwin_x11',0,1,0,'',''],# no version
	'larswm' => ['^larswm',2,'-v','larswm',0,1,1,'',''],
	'liri' => ['^liri',0,'0','liri',0,1,0,'',''],
	'lumina' => ['^\S',1,'--version','Lumina',0,1,1,'',''],
	'lwm' => ['^lwm',0,'0','lwm',0,1,0,'',''], # no version
	'lxpanel' => ['^lxpanel',2,'--version','LXDE',0,1,0,'',''],
	# command: lxqt-panel
	'lxqt-panel' => ['^lxqt-panel',2,'--version','LXQt',0,1,0,'',''],
	'lxqt-variant' => ['^lxqt-panel',0,'0','LXQt-Variant',0,1,0,'',''],
	'lxsession' => ['^lxsession',0,'0','lxsession',0,1,0,'',''],
	'manokwari' => ['^manokwari',0,'0','Manokwari',0,1,0,'',''],
	'marco' => ['^marco',2,'--version','marco',0,1,0,'',''],
	'matchbox' => ['^matchbox',0,'0','Matchbox',0,1,0,'',''],
	'matchbox-window-manager' => ['^matchbox',2,'--help','Matchbox',0,0,0,'',''],
	'mate-about' => ['^MATE[[:space:]]DESKTOP',-1,'--version','MATE',0,1,0,'',''],
	# note, mate-session when launched with full path returns full path in version string
	'mate-session' => ['mate-session',-1,'--version','MATE',0,1,0,'',''], 
	'metacity' => ['^metacity',2,'--version','Metacity',0,1,0,'',''],
	'metisse' => ['^metisse',0,'0','metisse',0,1,0,'',''],
	'mini' => ['^Mini',5,'--version','Mini',0,1,0,'',''],
	'mir' => ['^mir',0,'0','mir',0,1,0,'',''],# unverified
	'moblin' => ['^moblin',0,'0','moblin',0,1,0,'',''],# unverified
	'motorcar' => ['^motorcar',0,'0','motorcar',0,1,0,'',''],# unverified
	'muffin' => ['^muffin',2,'--version','Muffin',0,1,0,'',''],
	'musca' => ['^musca',0,'-v','Musca',0,1,0,'',''], # unverified
	'mutter' => ['^mutter',2,'--version','Mutter',0,1,0,'',''],
	'mwm' => ['^mwm',0,'0','MWM',0,1,0,'',''],# no version
	'nawm' => ['^nawm',0,'0','nawm',0,1,0,'',''],# unverified
	'notion' => ['^.',1,'--version','Notion',0,1,0,'',''],
	'openbox' => ['^openbox',2,'--version','Openbox',0,1,0,'',''],
	'orbital' => ['^orbital',0,'0','orbital',0,1,0,'',''],# unverified
	'pantheon' => ['^pantheon',0,'0','Pantheon',0,1,0,'',''],# no version
	'papyros' => ['^papyros',0,'0','papyros',0,1,0,'',''],# no version
	'pekwm' => ['^pekwm',3,'--version','PekWM',0,1,0,'',''],
	'perceptia' => ['^perceptia',0,'0','perceptia',0,1,0,'',''],
	'picom' => ['^\S',1,'--version','Picom',0,1,0,'^v',''],
	'plasmashell' => ['^plasmashell',2,'--version','KDE Plasma',0,1,0,'',''],
	'qtile' => ['^',1,'--version','Qtile',0,1,0,'',''],
	'qvwm' => ['^qvwm',0,'0','qvwm',0,1,0,'',''], # unverified
	'razor-session' => ['^razor',0,'0','Razor-Qt',0,1,0,'',''],
	'ratpoison' => ['^ratpoison',2,'--version','Ratpoison',0,1,0,'',''],
	'rustland' => ['^rustland',0,'0','rustland',0,1,0,'',''], # unverified
	'sawfish' => ['^sawfish',3,'--version','Sawfish',0,1,0,'',''],
	'scrotwm' => ['^scrotwm.*welcome.*',5,'-v','scrotwm',0,1,1,'',''],
	'sommelier' => ['^sommelier',0,'0','sommelier',0,1,0,'',''], # unverified
	'spectrwm' => ['^spectrwm.*welcome.*wm',5,'-v','spectrwm',0,1,1,'',''],
	# out of stump, 2 --version, but in tries to start new wm instance endless hang
	'stumpwm' => ['^SBCL',0,'--version','StumpWM',0,1,0,'',''], # hangs when run in wm
	'sway' => ['^sway',3,'-v','sway',0,1,0,'',''],
	'swc' => ['^swc',0,'0','swc',0,1,0,'',''], # unverified
	'tinywm' => ['^tinywm',0,'0','TinyWM',0,1,0,'',''], # no version
	'tvtwm' => ['^tvtwm',0,'0','tvtwm',0,1,0,'',''], # unverified
	'twin' => ['^Twin:',2,'--version','Twin',0,0,0,'',''],
	'twm' => ['^twm',0,'0','TWM',0,1,0,'',''], # no version
	'ukui' => ['^ukui-session',2,'--version','UKUI',0,1,0,'',''],
	'ukwm' => ['^ukwm',2,'--version','ukwm',0,1,0,'',''],
	'unagi' => ['^\S',1,'--version','unagi',0,1,0,'',''],
	'unity' => ['^unity',2,'--version','Unity',0,1,0,'',''],
	'unity-system-compositor' => ['^unity-system-compositor',2,'--version',
	 'unity-system-compositor (mir)',0,0,0,'',''],
	'wavy' => ['^wavy',0,'0','wavy',0,1,0,'',''], # unverified
	'waycooler' => ['^way',3,'--version','way-cooler',0,1,0,'',''],
	'way-cooler' => ['^way',3,'--version','way-cooler',0,1,0,'',''],
	'wayfire' => ['^way',0,'0','wayfire',0,1,0,'',''], # unverified
	'wayhouse' => ['^wayhouse',0,'0','wayhouse',0,1,0,'',''], # unverified
	'westford' => ['^westford',0,'0','westford',0,1,0,'',''], # unverified
	'weston' => ['^weston',0,'0','weston',0,1,0,'',''], # unverified
	'windowlab' => ['^windowlab',2,'-about','WindowLab',0,1,0,'',''],
	'wm2' => ['^wm2',0,'0','wm2',0,1,0,'',''], # no version
	'wmaker' => ['^Window[[:space:]]*Maker',-1,'--version','WindowMaker',0,1,0,'',''],
	'wmii' => ['^wmii',1,'-v','wmii',0,1,0,'^wmii[234]?-',''], # wmii is wmii3
	'wmii2' => ['^wmii2',1,'--version','wmii2',0,1,0,'^wmii[234]?-',''],
	'wmx' => ['^wmx',0,'0','wmx',0,1,0,'',''], # no version
	'xcompmgr' => ['^xcompmgr',0,'0','xcompmgr',0,1,0,'',''], # no version
	'xfce4-panel' => ['^xfce4-panel',2,'--version','Xfce',0,1,0,'',''],
	'xfce5-panel' => ['^xfce5-panel',2,'--version','Xfce',0,1,0,'',''],
	'xfdesktop' => ['xfdesktop[[:space:]]version',5,'--version','Xfce',0,1,0,'',''],
	# command: xfdesktop
	'xfdesktop-toolkit' => ['Built[[:space:]]with[[:space:]]GTK',4,'--version','Gtk',0,1,0,'',''],
	'xmonad' => ['^xmonad',2,'--version','XMonad',0,1,0,'',''],
	'yeahwm' => ['^yeahwm',0,'--version','YeahWM',0,1,0,'',''], # unverified
	## Toolkits ##
	'gtk-launch' => ['^\S',1,'--version','GTK',0,1,0,'',''],
	'qmake' => ['^^Using Qt version',4,'--version','Qt',0,0,0,'',''],
	'qtdiag' => ['^qt',2,'--version','Qt',0,1,0,'',''],
	## Display Managers (dm) ##
	'cdm' => ['^cdm',0,'0','CDM',0,1,0,'',''],
	'entrance' => ['^entrance',0,'0','Entrance',0,1,0,'',''],
	'gdm' => ['^gdm',2,'--version','GDM',0,1,0,'',''],
	'gdm3' => ['^gdm',2,'--version','GDM3',0,1,0,'',''],
	'kdm' => ['^kdm',0,'0','KDM',0,1,0,'',''],
	'ldm' => ['^ldm',0,'0','LDM',0,1,0,'',''],
	'lightdm' => ['^lightdm',2,'--version','LightDM',0,1,1,'',''],
	'lxdm' => ['^lxdm',0,'0','LXDM',0,1,0,'',''],
	'ly' => ['^ly',3,'--version','Ly',0,1,0,'',''],
	'mdm' => ['^mdm',0,'0','MDM',0,1,0,'',''],
	'nodm' => ['^nodm',0,'0','nodm',0,1,0,'',''],
	'pcdm' => ['^pcdm',0,'0','PCDM',0,1,0,'',''],
	'sddm' => ['^sddm',0,'0','SDDM',0,1,0,'',''],
	'slim' => ['slim version',3,'-v','SLiM',0,1,0,'',''],
	'tdm' => ['^tdm',0,'0','TDM',0,1,0,'',''],
	'udm' => ['^udm',0,'0','udm',0,1,0,'',''],
	'wdm' => ['^wdm',0,'0','WINGs DM',0,1,0,'',''],
	'xdm' => ['^xdm',0,'0','XDM',0,1,0,'',''],
	'xenodm' => ['^xenodm',0,'0','xenodm',0,1,0,'',''],
	## Shells - not checked: ion, eshell ##
	## See test_shell() for unhandled but known shells
	'ash' => ['',3,'pkg','ash',1,0,0,'',''], # special; dash precursor
	'bash' => ['^GNU[[:space:]]bash',4,'--version','Bash',1,1,0,'',''],
	'busybox' => ['^busybox',0,'0','BusyBox',1,0,0,'',''], # unverified, hush/ash likely
	'cicada' => ['^\s*version',2,'cmd','cicada',1,1,0,'',''], # special
	'csh' => ['^tcsh',2,'--version','csh',1,1,0,'',''], # mapped to tcsh often
	'dash' => ['',3,'pkg','DASH',1,0,0,'',''], # no version, pkg query
	'elvish' => ['^\S',1,'--version','Elvish',1,0,0,'',''],
	'fish' => ['^fish',3,'--version','fish',1,0,0,'',''],
	'fizsh' => ['^fizsh',3,'--version','FIZSH',1,0,0,'',''],
	# ksh/lksh/loksh/mksh/posh//pdksh need to print their own $VERSION info
	'ksh' => ['^\S',1,'cmd','ksh',1,0,0,'^(Version|.*KSH)\s*',''], # special
	'ksh93' => ['^\S',1,'cmd','ksh93',1,0,0,'^(Version|.*KSH)\s*',''], # special
	'lksh' => ['^\S',1,'cmd','lksh',1,0,0,'^.*KSH\s*',''], # special
	'loksh' => ['^\S',1,'cmd','loksh',1,0,0,'^.*KSH\s*',''], # special
	'mksh' => ['^\S',1,'cmd','mksh',1,0,0,'^.*KSH\s*',''], # special
	'nash' => ['^nash',0,'0','Nash',1,0,0,'',''], # unverified; rc based [no version]
	'oh' => ['^oh',0,'0','Oh',1,0,0,'',''], # no version yet
	'oil' => ['^Oil',3,'--version','Oil',1,1,0,'',''], # could use cmd $OIL_SHELL
	'osh' => ['^osh',3,'--version','OSH',1,1,0,'',''], # precursor of oil
	'pdksh' => ['^\S',1,'cmd','pdksh',1,0,0,'^.*KSH\s*',''], # special, in  ksh family
	'posh' => ['^\S',1,'cmd','posh',1,0,0,'',''], # special, in ksh family
	'tcsh' => ['^tcsh',2,'--version','tcsh',1,1,0,'',''], # enhanced csh
	'xonsh' => ['^xonsh',1,'--version','xonsh',1,0,0,'^xonsh[\/-]',''], 
	'yash' => ['^Y',5,'--version','yash',1,0,0,'',''], 
	'zsh' => ['^zsh',2,'--version','Zsh',1,0,0,'',''],
	## Tools ##
	'clang' => ['clang',3,'--version','Clang',1,0,0,'',''],
	'gcc' => ['^gcc',3,'--version','GCC',1,0,0,'',''],
	'gcc-apple' => ['Apple[[:space:]]LLVM',2,'--version','LLVM',1,0,0,'',''],
	'sudo' => ['^Sudo',3,'-V','Sudo',1,1,0,'',''], # sudo pre 1.7 does not have --version
	);
}

# returns array of:
# 0 - match string; 1 - search number; 2 - version string [alt: file]; 
# 3 - Print name; 4 - console 0/1; 
# 5 - 0/1 exit version loop at 1 [alt: if version=file replace value with \s]; 
# 6 - 0/1 write to stderr [alt: if version=file, path for file]
# 7 - replace regex for further cleanup; 8 - extra data
# note: setting index 1 or 2 to 0 will trip flags to not do version
# arg: 1 - program lower case name
sub program_values {
	my ($app) = @_;
	my (@program_data);
	set_program_values() if !%program_values;
	if ( defined $program_values{$app} ){
		@program_data = @{$program_values{$app}};
	}
	#my $debug = Dumper \@program_data;
	log_data('dump',"Program Data",\@program_data) if $b_log;
	return @program_data;
}

# args: 1 - desktop/app command for --version; 2 - search string; 
# 3 - space print number; 4 - [optional] version arg: -v, version, etc
# 5 - [optional] exit first find 0/1; 6 - [optional] 0/1 stderr output
# 7 - replace regex; 8 - extra data
sub program_version {
	eval $start if $b_log;
	my ($app,$search,$num,$version,$exit,$stderr,$replace,$extra) = @_;
	my ($b_no_space,$cmd,$line,$output);
	my $version_nu = '';
	my $count = 0;
	my $app_name = $app;
	$app_name =~ s%^.*/%%;
	# print "app: $app :: appname: $app_name\n";
	$exit ||= 100; # basically don't exit ever
	$version ||= '--version';
	# adjust to array index, not human readable
	$num-- if (defined $num && $num > 0);
	# konvi in particular doesn't like using $ENV{'PATH'} as set, so we need
	# to always assign the full path if it hasn't already been done
	if ( $version ne 'file' && $app !~ /^\// ){
		if (my $program = check_program($app) ){
			$app = $program;
		}
		else {
			log_data('data',"$app not found in path.") if $b_log;
			return 0;
		}
	}
	if ($version eq 'file'){
		return 0 unless $extra && -r $extra;
		my @data = reader($extra,'strip');
		@data = map {s/$stderr/ /;$_} @data if $stderr; # $stderr is the splitter
		$output = join "\n",@data;
		$cmd = '';
	}
	# These will mostly be shells that require running the shell command -c to get info data
	elsif ($version eq 'cmd'){
		($cmd,$b_no_space) = program_version_cmd($app,$app_name,$extra);
		return 0 if !$cmd;
	}
	# slow: use pkg manager to get version, avoid unless you really want version
	elsif ($version eq 'pkg'){
		($cmd,$search) = program_version_pkg($app_name);
		return 0 if !$cmd;
	}
	# note, some wm/apps send version info to stderr instead of stdout
	elsif ($stderr) {
		$cmd = "$app $version 2>&1";
	}
	else {
		$cmd = "$app $version 2>/dev/null";
	}
	log_data('data',"version: $version num: $num search: $search command: $cmd") if $b_log;
	# special case, in rare instances version comes from file
	if ($version ne 'file'){
		$output = qx($cmd);
		log_data('data',"output: $output") if $b_log;
	}
	# print "cmd: $cmd\noutput:\n$output\n";
	# sample: dwm-5.8.2, ©.. etc, why no space? who knows. Also get rid of v in number string
	# xfce, and other, output has , in it, so dump all commas and parentheses
	if ($output){
		open my $ch, '<', \$output or error_handler('open-data',"$cmd", "$!");
		while (<$ch>){
			#chomp;
			last if $count > $exit;
			if ( $_ =~ /$search/i ) {
				$_ = trimmer($_);
				# print "loop: $_ :: num: $num\n";
				$_ =~ s/$replace//i if $replace;
				$_ =~ s/\s/_/g if $b_no_space; # needed for some items with version > 1 word
				my @data = split /\s+/, $_;
				$version_nu = $data[$num];
				last if ! defined $version_nu;
				# some distros add their distro name before the version data, which 
				# breaks version detection. A quick fix attempt is to just add 1 to $num 
				# to get the next value.
				$version_nu = $data[$num+1] if $data[$num+1] && $version_nu =~ /version/i;
				$version_nu =~ s/(\([^)]+\)|,|"|\||\(|\))//g if $version_nu;
				# trim off leading v but only when followed by a number
				$version_nu =~ s/^v([0-9])/$1/i if $version_nu; 
				# print "$version_nu\n";
				last;
			}
			$count++;
		}
		close $ch if $ch;
	}
	log_data('data',"Program version: $version_nu") if $b_log;
	eval $end if $b_log;
	return $version_nu;
}
# print program_version('bash', 'bash', 4) . "\n";

# returns ($cmdd, $b_no_space)
# ksh: Version JM 93t+ 2010-03-05 [OR] Version A 2020.0.0
# mksh: @(#)MIRBSD KSH R56 2018/03/09; lksh/pdksh: @(#)LEGACY KSH R56 2018/03/09
# loksh: @(#)PD KSH v5.2.14 99/07/13.2; posh: 0.13.2
sub program_version_cmd {
	eval $start if $b_log;
	my ($app,$app_name,$extra) = @_;
	my @data = ('',0);
	if ($app_name eq 'cicada') {
		$data[0] = $app . ' -c "' . $extra . '" 2>/dev/null';}
	elsif ($app_name =~ /^(|l|lo|m|pd)ksh(93)?$/){
		$data[0] = $app . ' -c \'printf %s "$KSH_VERSION"\' 2>/dev/null';
		$data[1] = 1;}
	elsif ($app_name eq 'posh'){
		$data[0] =  $app . ' -c \'printf %s "$POSH_VERSION"\' 2>/dev/null'}
	# print "$data[0] :: $data[1]\n";
	eval $end if $b_log;
	return @data;
}
# returns $cmd, $search
sub program_version_pkg  {
	eval $start if $b_log;
	my ($app) = @_;
	my ($program,@data);
	# note: version $num is 3 in dpkg-query/pacman/rpm, which is convenient
	if ($program = check_program('dpkg-query') ){
		$data[0] = "$program -W -f='\${Package}\tversion\t\${Version}\n' $app 2>/dev/null";
		$data[1] = "^$app\\b";
	}
	elsif ($program = check_program('pacman') ){
		$data[0] = "$program -Q --info $app 2>/dev/null";
		$data[1] = '^Version';
	}
	elsif ($program = check_program('rpm') ){
		$data[0] = "$program -qi --nodigest --nosignature $app 2>/dev/null";
		$data[1] = '^Version';
	}
	# print "$data[0] :: $data[1]\n";
	eval $end if $b_log;
	return @data;
}

# arg: 1 - full file path, returns array of file lines.
# 2 - optionsl, strip and clean data
# note: chomp has to chomp the entire action, not just <$fh>
sub reader {
	eval $start if $b_log;
	my ($file,$strip) = @_;
	return if ! $file;
	open( my $fh, '<', $file ) or error_handler('open', $file, $!);
	chomp(my @rows = <$fh>);
	if ($strip && @rows){
		@rows = grep {/^\s*[^#]/} @rows;
		@rows = map {s/^\s+|\s+$//g; $_} @rows if @rows;
	}
	eval $end if $b_log;
	return @rows;
}

# args: 1 - the file to create if not exists
sub toucher {
	my $file = shift;
	if ( ! -e $file ){
		open( my $fh, '>', $file ) or error_handler('create', $file, $!);
	}
}

# calling it trimmer to avoid conflicts with existing trim stuff
# arg: 1 - string to be right left trimmed. Also slices off \n so no chomp needed
# this thing is super fast, no need to log its times etc, 0.0001 seconds or less
sub trimmer {
	#eval $start if $b_log;
	my ($str) = @_;
	$str =~ s/^\s+|\s+$|\n$//g; 
	#eval $end if $b_log;
	return $str;
}

# args: 1 - hash
# send array, assign to hash, return array, uniq values only.
sub uniq {
	my %seen;
	grep !$seen{$_}++, @_;
}

# arg: 1 file full  path to write to; 2 - arrayof data to write. 
# note: turning off strict refs so we can pass it a scalar or an array reference.
sub writer {
	my ($path, $ref_content) = @_;
	my ($content);
	no strict 'refs';
	# print Dumper $ref_content, "\n";
	if (ref $ref_content eq 'ARRAY'){
		$content = join "\n", @$ref_content or die "failed with error $!";
	}
	else {
		$content = scalar $ref_content;
	}
	open(my $fh, ">", $path) or error_handler('open',"$path", "$!");
	print $fh $content;
	close $fh;
}

#### -------------------------------------------------------------------
#### UPDATER
##### -------------------------------------------------------------------

# arg 1: type to return
sub get_defaults {
	my ($type) = @_;
	my %defaults = (
	'ftp-upload' => 'ftp.smxi.org/incoming',
	'inxi-branch-1' => 'https://github.com/smxi/inxi/raw/one/',
	'inxi-branch-2' => 'https://github.com/smxi/inxi/raw/two/',
	'inxi-dev' => 'https://smxi.org/in/',
	'inxi-main' => 'https://github.com/smxi/inxi/raw/master/',
	'inxi-pinxi' => 'https://github.com/smxi/inxi/raw/inxi-perl/',
	'inxi-man' => "https://smxi.org/in/$self_name.1.gz",
	'inxi-man-gh' => "https://github.com/smxi/inxi/raw/master/$self_name.1",
	'pinxi-man' => "https://smxi.org/in/$self_name.1.gz",
	'pinxi-man-gh' => "https://github.com/smxi/inxi/raw/inxi-perl/$self_name.1",
	);
	if ( exists $defaults{$type}){
		return $defaults{$type};
	}
	else {
		error_handler('bad-arg-int', $type);
	}
}

# args: 1 - download url, not including file name; 2 - string to print out
# 3 - update type option
# note that 1 must end in / to properly construct the url path
sub update_me {
	eval $start if $b_log;
	my ( $self_download, $download_id ) = @_;
	my $downloader_error=1;
	my $file_contents='';
	my $output = '';
	$self_path =~ s/\/$//; # dirname sometimes ends with /, sometimes not
	$self_download =~ s/\/$//; # dirname sometimes ends with /, sometimes not
	my $full_self_path = "$self_path/$self_name";
	
	if ( $b_irc ){
		error_handler('not-in-irc', "-U/--update" )
	}
	if ( ! -w $full_self_path ){
		error_handler('not-writable', "$self_name", '');
	}
	$output .= "Starting $self_name self updater.\n";
	$output .= "Using $dl{'dl'} as downloader.\n";
	$output .= "Currently running $self_name version number: $self_version\n";
	$output .= "Current version patch number: $self_patch\n";
	$output .= "Current version release date: $self_date\n";
	$output .= "Updating $self_name in $self_path using $download_id as download source...\n";
	print $output;
	$output = '';
	$self_download = "$self_download/$self_name";
	$file_contents = download_file('stdout', $self_download);
	
	# then do the actual download
	if (  $file_contents ){
		# make sure the whole file got downloaded and is in the variable
		if ( $file_contents =~ /###\*\*EOF\*\*###/ ){
			open(my $fh, '>', $full_self_path);
			print $fh $file_contents or error_handler('write', "$full_self_path", "$!" );
			close $fh;
			qx( chmod +x '$self_path/$self_name' );
			set_version_data();
			$output .= "Successfully updated to $download_id version: $self_version\n";
			$output .= "New $download_id version patch number: $self_patch\n";
			$output .= "New $download_id version release date: $self_date\n";
			$output .= "To run the new version, just start $self_name again.\n";
			$output .= "$line3\n";
			$output .= "Starting download of man page file now.\n";
			print $output;
			$output = '';
			if ($b_man){
				update_man($download_id);
			}
			else {
				print "Skipping man download because branch version is being used.\n";
			}
			exit 0;
		}
		else {
			error_handler('file-corrupt', "$self_name");
		}
	}
	# now run the error handlers on any downloader failure
	else {
		error_handler('download-error', $self_download, $download_id);
	}
	eval $end if $b_log;
}

sub update_man {
	my ($download_id) = @_;
	my $man_file_location=set_man_location();
	my $man_file_path="$man_file_location/$self_name.1" ;
	my ($man_file_url,$output) = ('','');
	
	my $b_downloaded = 0;
	if ( ! -d $man_file_location ){
		print "The required man directory was not detected on your system.\n";
		print "Unable to continue: $man_file_location\n";
		return 0;
	}
	if ( ! -w $man_file_location ){
		print "Cannot write to $man_file_location! Root privileges required.\n";
		print "Unable to continue: $man_file_location\n";
		return 0;
	}
	if ( -f "/usr/share/man/man8/inxi.8.gz" ){
		print "Updating man page location to man1.\n";
		rename "/usr/share/man/man8/inxi.8.gz", "$man_file_location/inxi.1.gz";
		if ( check_program('mandb') ){
			system( 'mandb' );
		}
	}
	 # first choice is inxi.1/pinxi.1 from gh, second gz from smxi.org
	if ( $download_id ne 'dev server' && (my $program = check_program('gzip'))){
		$man_file_url=get_defaults($self_name . '-man-gh'); 
		print "Downloading Man page file...\n";
		$b_downloaded = download_file('file', $man_file_url, $man_file_path);
		if ($b_downloaded){
			print "Download successful. Compressing file...\n";
			system("$program -9 -f $man_file_path > $man_file_path.gz");
			my $err = $?;
			if ($err > 0){
				print "Oh no! Something went wrong compressing the manfile:\n";
				print "Local path: $man_file_path Error: $err\n";
			}
			else {
				print "Download and install of man page successful.\nCheck to make sure it works: man $self_name\n";
			}
		}
	}
	else {
		$man_file_url = get_defaults($self_name . '-man'); 
		# used to use spider tests, but only wget supports that, so no need
		print "Downloading Man page file gz...\n";
		$man_file_path .= '.gz';
		# returns perl, 1 for true, 0 for false, even when using shell tool returns
		$b_downloaded = download_file('file', $man_file_url,  $man_file_path );
		if ($b_downloaded) {
			print "Download and install of man page successful.\nCheck to make sure it works: man $self_name\n";
		}
	}
	if ( !$b_downloaded ){
		print "Oh no! Something went wrong downloading the Man file at:\n$man_file_url\n";
		print "Try -U with --dbg 1 for more information on the failure.\n";
	}
}

sub set_man_location {
	my $location='';
	my $default_location='/usr/share/man/man1';
	my $man_paths=qx(man --path 2>/dev/null);
	my $man_local='/usr/local/share/man';
	my $b_use_local=0;
	if ( $man_paths && $man_paths =~ /$man_local/ ){
		$b_use_local=1;
	}
	# for distro installs
	if ( -f "$default_location/inxi.1.gz" ){
		$location=$default_location;
	}
	else {
		if ( $b_use_local ){
			if ( ! -d "$man_local/man1" ){
				mkdir "$man_local/man1";
			}
			$location="$man_local/man1";
		}
	}
	if ( ! $location ){
		$location=$default_location;
	}
	return $location;
}

# update for updater output version info
# note, this is only now used for self updater function so it can get
# the values from the UPDATED file, NOT the running program!
sub set_version_data {
	open (my $fh, '<', "$self_path/$self_name");
	while( my $row = <$fh>){
		chomp $row;
		$row =~ s/'|;//g;
		if ($row =~ /^my \$self_name/ ){
			$self_name = (split /=/, $row)[1];
		}
		elsif ($row =~ /^my \$self_version/ ){
			$self_version = (split /=/, $row)[1];
		}
		elsif ($row =~ /^my \$self_date/ ){
			$self_date = (split /=/, $row)[1];
		}
		elsif ($row =~ /^my \$self_patch/ ){
			$self_patch = (split /=/, $row)[1];
		}
		elsif ($row =~ /^## END INXI INFO/){
			last;
		}
	}
	close $fh;
}

########################################################################
#### OPTIONS HANDLER / VERSION
########################################################################

sub get_options{
	eval $start if $b_log;
	my (@args) = @_;
	$show{'short'} = 1;
	my ($b_downloader,$b_help,$b_no_man,$b_no_man_force,$b_sensors_default,
	$b_recommends,$b_updater,$b_version,$b_use_man,$self_download, $download_id);
	GetOptions (
	'a|admin' => sub {
		$b_admin = 1;},
	'A|audio' => sub {
		$show{'short'} = 0;
		$show{'audio'} = 1;},
	'b|basic' => sub {
		$show{'short'} = 0;
		$show{'battery'} = 1;
		$show{'cpu-basic'} = 1;
		$show{'raid-basic'} = 1;
		$show{'disk-total'} = 1;
		$show{'graphic'} = 1;
		$show{'graphic-basic'} = 1;
		$show{'info'} = 1;
		$show{'machine'} = 1;
		$show{'network'} = 1;
		$show{'system'} = 1;},
	'B|battery' => sub {
		$show{'short'} = 0;
		$show{'battery'} = 1;
		$show{'battery-forced'} = 1; },
	'c|color:i' => sub {
		my ($opt,$arg) = @_;
		if ( $arg >= 0 && $arg < get_color_scheme('count') ){
			set_color_scheme($arg);
		}
		elsif ( $arg >= 94 && $arg <= 99 ){
			$colors{'selector'} = $arg;
		}
		else {
			error_handler('bad-arg', $opt, $arg);
		} },
	'C|cpu' => sub {
		$show{'short'} = 0;
		$show{'cpu'} = 1; },
	'd|disk-full|optical' => sub {
		$show{'short'} = 0;
		$show{'disk'} = 1;
		$show{'optical'} = 1; },
	'D|disk' => sub {
		$show{'short'} = 0;
		$show{'disk'} = 1; },
	'f|flags|flag' => sub {
		$show{'short'} = 0;
		$show{'cpu'} = 1;
		$show{'cpu-flag'} = 1; },
	'F|full' => sub {
		$show{'short'} = 0;
		$show{'audio'} = 1;
		$show{'battery'} = 1;
		$show{'cpu'} = 1;
		$show{'disk'} = 1;
		$show{'graphic'} = 1;
		$show{'graphic-basic'} = 1;
		$show{'info'} = 1;
		$show{'machine'} = 1;
		$show{'network'} = 1;
		$show{'network-advanced'} = 1;
		$show{'partition'} = 1;
		$show{'raid'} = 1;
		$show{'sensor'} = 1;
		$show{'swap'} = 1;
		$show{'system'} = 1; },
	'G|graphics|graphic' => sub {
		$show{'short'} = 0;
		$show{'graphic'} = 1; 
		$show{'graphic-basic'} = 1; },
	'h|help|?' => sub {
		$b_help = 1; },
	'i|ip' => sub {
		$show{'short'} = 0;
		$show{'ip'} = 1;
		$show{'network'} = 1;
		$show{'network-advanced'} = 1;
		$b_downloader = 1 if ! check_program('dig');},
	'I|info' => sub {
		$show{'short'} = 0;
		$show{'info'} = 1; },
	'j|swap|swaps' => sub {
		$show{'short'} = 0;
		$show{'swap'} = 1; },
	'J|usb' => sub {
		$show{'short'} = 0;
		$show{'usb'} = 1; },
	'l|labels|label' => sub {
		$show{'short'} = 0;
		$show{'label'} = 1;
		$show{'partition'} = 1; },
	'limit:i' => sub {
		my ($opt,$arg) = @_;
		if ($arg != 0){
			$limit = $arg;
		}
		else {
			error_handler('bad-arg',$opt,$arg);
		} },
	'm|memory' => sub {
		$show{'short'} = 0;
		$show{'ram'} = 1; },
	'memory-modules' => sub {
		$show{'short'} = 0;
		$show{'ram'} = 1; 
		$show{'ram-modules'} = 1;},
	'memory-short' => sub {
		$show{'short'} = 0;
		$show{'ram'} = 1; 
		$show{'ram-short'} = 1;},
	'M|machine' => sub {
		$show{'short'} = 0;
		$show{'machine'} = 1; },
	'n|network-advanced' => sub {
		$show{'short'} = 0;
		$show{'network'} = 1;
		$show{'network-advanced'} = 1; },
	'N|network' => sub {
		$show{'short'} = 0;
		$show{'network'} = 1; },
	'o|unmounted' => sub {
		$show{'short'} = 0;
		$show{'unmounted'} = 1; },
	'p|partition-full|partitions-full' => sub {
		$show{'short'} = 0;
		$show{'partition'} = 0;
		$show{'partition-full'} = 1; },
	'P|partitions|partition' => sub {
		$show{'short'} = 0;
		$show{'partition'} = 1; },
	'partition-sort:s' => sub {
		my ($opt,$arg) = @_;
		if ($arg =~ /^(dev-base|fs|id|label|percent-used|size|uuid|used)$/){
			$show{'partition-sort'} = $arg;
		}
		else {
			error_handler('bad-arg',$opt,$arg);
		} },
	'r|repos|repo' => sub {
		$show{'short'} = 0;
		$show{'repo'} = 1; },
	'R|raid' => sub {
		$show{'short'} = 0;
		$show{'raid'} = 1;
		$show{'raid-forced'} = 1; },
	's|sensors|sensor' => sub {
		$show{'short'} = 0;
		$show{'sensor'} = 1; },
	'sleep:s' => sub {
		my ($opt,$arg) = @_;
		$arg ||= 0;
		if ($arg >= 0){
			$cpu_sleep = $arg;
		}
		else {
			error_handler('bad-arg',$opt,$arg);
		} },
	'slots|slot' => sub {
		$show{'short'} = 0;
		$show{'slot'} = 1; },
	'S|system' => sub {
		$show{'short'} = 0;
		$show{'system'} = 1; },
	't|processes|process:s' => sub {
		my ($opt,$arg) = @_;
		$show{'short'} = 0;
		$arg ||= 'cm';
		my $num = $arg;
		$num =~ s/^[cm]+// if $num;
		if ( $arg =~ /^([cm]+)([0-9]+)?$/ && (!$num || $num =~ /^\d+/) ){
			$show{'process'} = 1;
			if ($arg =~ /c/){
				$show{'ps-cpu'} = 1;
			}
			if ($arg =~ /m/){
				$show{'ps-mem'} = 1;
			}
			$ps_count = $num if $num;
		}
		else {
			error_handler('bad-arg',$opt,$arg);
		} },
	'u|uuid' => sub {
		$show{'short'} = 0;
		$show{'partition'} = 1;
		$show{'uuid'} = 1; },
	'v|verbosity:i' => sub {
		my ($opt,$arg) = @_;
		$show{'short'} = 0;
		if ( $arg =~ /^[0-8]$/ ){
			if ($arg == 0 ){
				$show{'short'} = 1;
			}
			if ($arg >= 1 ){
				$show{'cpu-basic'} = 1;
				$show{'disk-total'} = 1;
				$show{'graphic'} = 1;
				$show{'graphic-basic'} = 1;
				$show{'info'} = 1;
				$show{'system'} = 1;
			}
			if ($arg >= 2 ){
				$show{'battery'} = 1;
				$show{'disk-basic'} = 1;
				$show{'raid-basic'} = 1;
				$show{'machine'} = 1;
				$show{'network'} = 1;
			}
			if ($arg >= 3 ){
				$show{'network-advanced'} = 1;
				$show{'cpu'} = 1;
				$extra = 1;
			}
			if ($arg >= 4 ){
				$show{'disk'} = 1;
				$show{'partition'} = 1;
			}
			if ($arg >= 5 ){
				$show{'audio'} = 1;
				$show{'ram'} = 1;
				$show{'label'} = 1;
				$show{'optical-basic'} = 1;
				$show{'ram'} = 1;
				$show{'raid'} = 1;
				$show{'sensor'} = 1;
				$show{'swap'} = 1;
				$show{'uuid'} = 1;
			}
			if ($arg >= 6 ){
				$show{'optical'} = 1;
				$show{'partition-full'} = 1;
				$show{'unmounted'} = 1;
				$show{'usb'} = 1;
				$extra = 2;
			}
			if ($arg >= 7 ){
				$b_downloader = 1 if ! check_program('dig');
				$show{'cpu-flag'} = 1;
				$show{'ip'} = 1;
				$show{'raid-forced'} = 1;
				$extra = 3;
			}
			if ($arg >= 8 ){
				$b_admin = 1;
				$b_downloader = 1;
				$show{'slot'} = 1;
				$show{'process'} = 1;
				$show{'ps-cpu'} = 1;
				$show{'ps-mem'} = 1;
				$show{'repo'} = 1;
				#$show{'weather'} = 1;
			}
		}
		else {
			error_handler('bad-arg',$opt,$arg);
		} },
	'V|version' => sub { 
		$b_version = 1 },
	'w|weather' => sub {
		my ($opt) = @_;
		$show{'short'} = 0;
		$b_downloader = 1;
		if ( $use{'weather'} ){
			$show{'weather'} = 1;
		}
		else {
			error_handler('distro-block', $opt);
		} },
	'W|weather-location:s' => sub {
		my ($opt,$arg) = @_;
		$arg ||= '';
		$arg =~ s/\s//g;
		$show{'short'} = 0;
		$b_downloader = 1;
		if ( $use{'weather'} ){
			if ($arg){
				$show{'weather'} = 1;
				$show{'weather-location'} = $arg;
			}
			else {
				error_handler('bad-arg',$opt,$arg);
			}
		}
		else {
			error_handler('distro-block', $opt);
		} },
	'ws|weather-source:s' => sub {
		my ($opt,$arg) = @_;
		# let api processor handle checks if valid, this
		# future proofs this
		if ($arg =~ /^[1-9]$/){
			$weather_source = $arg;
		}
		else {
			error_handler('bad-arg',$opt,$arg);
		} },
	'weather-unit:s' => sub {
		my ($opt,$arg) = @_;
		$arg ||= '';
		$arg =~ s/\s//g;
		$arg = lc($arg) if $arg;
		if ($arg && $arg =~ /^(c|f|cf|fc|i|m|im|mi)$/){
			my %units = ('c'=>'m','f'=>'i','cf'=>'mi','fc'=>'im');
			$arg = $units{$arg} if defined $units{$arg};
			$weather_unit = $arg;
		}
		else {
			error_handler('bad-arg',$opt,$arg);
		} },
	'x|extra:i' => sub {
		my ($opt,$arg) = @_;
		if ($arg > 0){
			$extra = $arg;
		}
		else {
			$extra++;
		} },
	'y|width:i' => sub {
		my ($opt, $arg) = @_;
		if( defined $arg && $arg == -1){
			$arg = 2000;
		}
		# note: :i creates 0 value if not supplied even though means optional
		elsif (!$arg){
			$arg = 80;
		}
		if ( $arg =~ /\d/ && ($arg == 1 || $arg >= 80) ){
			set_display_width($arg);
		}
		else {
			error_handler('bad-arg', $opt, $arg);
		} },
	'z|filter' => sub {
		$use{'filter'} = 1; },
	'filter-label' => sub {
		$use{'filter-label'} = 1; },
	'Z|filter-override' => sub {
		$use{'filter-override'} = 1; },
	'filter-uuid' => sub {
		$use{'filter-uuid'} = 1; },
	## Start non data options
	'alt:i' => sub { 
		my ($opt,$arg) = @_;
		if ($arg == 40) {
			$dl{'tiny'} = 0;
			$b_downloader = 1;}
		elsif ($arg == 41) {
			$dl{'curl'} = 0;
			$b_downloader = 1;}
		elsif ($arg == 42) {
			$dl{'fetch'} = 0;
			$b_downloader = 1;}
		elsif ($arg == 43) {
			$dl{'wget'} = 0;
			$b_downloader = 1;}
		elsif ($arg == 44) {
			$dl{'curl'} = 0;
			$dl{'fetch'} = 0;
			$dl{'wget'} = 0;
			$b_downloader = 1;}
		else {
			error_handler('bad-arg', $opt, $arg);
		}},
	'arm' => sub {
		$b_arm = 1 },
	'bsd:s' => sub { 
		my ($opt,$arg) = @_;
		if ($arg =~ /^(darwin|dragonfly|freebsd|openbsd|netbsd)$/i){
			$bsd_type = lc($arg);
			$b_fake_bsd = 1;
		}
		else {
			error_handler('bad-arg', $opt, $arg);
		}
	},
	'bsd-data:s' => sub { 
		my ($opt,$arg) = @_;
		if ($arg =~ /^(dboot|pciconf|sysctl|usbdevs)$/i){
			$b_fake_dboot = 1 if $arg eq 'dboot';
			$b_fake_pciconf = 1 if $arg eq 'pciconf';
			$b_fake_sysctl = 1 if $arg eq 'sysctl';
			$b_fake_usbdevs = 1 if $arg eq 'usbdevs';
		}
		else {
			error_handler('bad-arg', $opt, $arg);
		}
	},
	'dbg:i' => sub { 
		my ($opt,$arg) = @_;
		if ($arg > 0) {
			$test[$arg] = 1;
		}
		else {
			error_handler('bad-arg', $opt, $arg);
		}},
	'debug:i' => sub { 
		my ($opt,$arg) = @_;
		if ($arg =~ /^[1-3]|1[0-3]|2[0-4]$/){
			$debug=$arg;
		}
		else {
			error_handler('bad-arg', $opt, $arg);
		} },
	'debug-filter|debug-z' => sub {
		$debugger{'filter'} = 1 },
	'debug-no-eps' => sub {
		$debugger{'no-exit'} = 1;
		$debugger{'no-proc'} = 1;
		$debugger{'sys'} = 0;
	},
	'debug-no-exit' => sub {
		$debugger{'no-exit'} = 1 },
	'debug-no-proc' => sub {
		$debugger{'no-proc'} = 1; },
	'debug-no-sys' => sub {
		$debugger{'sys'} = 0; },
	'debug-proc' => sub {
		$debugger{'proc'} = 1; },
	'debug-proc-print' => sub {
		$debugger{'proc-print'} = 1;},
	'debug-sys-print' => sub {
		$debugger{'sys-print'} = 1; },
	'debug-test-1' => sub {
		$debugger{'test-1'} = 1; },
	'dig' => sub {
		$b_skip_dig = 0; },
	'display:s' => sub { 
		my ($opt,$arg) = @_;
		if ($arg =~ /^:?([0-9]+)?$/){
			$display=$arg;
			$display ||= ':0';
			$display = ":$display" if $display !~ /^:/;
			$b_display = ($b_root) ? 0 : 1;
			$b_force_display = 1;
			$display_opt = "-display $display";
		}
		else {
			error_handler('bad-arg', $opt, $arg);
		} },
	'dmidecode' => sub {
		$b_dmidecode_force = 1 },
	'downloader:s' => sub { 
		my ($opt,$arg) = @_;
		$arg = lc($arg);
		if ($arg =~ /^(curl|fetch|ftp|perl|wget)$/){
			if ($arg eq 'perl' && (!check_module('HTTP::Tiny') || !check_module('IO::Socket::SSL') )){
				error_handler('missing-perl-downloader', $opt, $arg);
			}
			elsif ( !check_program($arg)) {
				error_handler('missing-downloader', $opt, $arg);
			}
			else {
				# this dumps all the other data and resets %dl for only the
				# desired downloader.
				$arg = set_perl_downloader($arg);
				%dl = ('dl' => $arg, $arg => 1);
				$b_downloader = 1;
			}
		}
		else {
			error_handler('bad-arg', $opt, $arg);
		} },
	'fake-dmi' => sub {
		$b_fake_dmidecode = 1 },
	'ftp:s'  => sub { 
		my ($opt,$arg) = @_;
		# pattern: ftp.x.x/x
		if ($arg =~ /^ftp\..+\..+\/[^\/]+$/ ){
			$ftp_alt = $arg;
		}
		else {
			error_handler('bad-arg', $opt, $arg);
		}},
	'host|hostname' => sub {
		$show{'host'} = 1;
		$show{'no-host'} = 0},
	'html-wan' => sub {
		$b_no_html_wan = 0; },
	'indent-min:i' => sub {
		my ($opt,$arg) = @_;
		if ($arg =~ /^\d+$/){
			$size{'indent-min'} = $arg;
		}
		else {
			error_handler('bad-arg', $opt, $arg);
		}},
	'irc' => sub {
		$b_irc = 1; },
	'man' => sub {
		$b_use_man = 1; },
	'mips' => sub {
		$b_mips = 1 },
	'output:s' => sub {
		my ($opt,$arg) = @_;
		if ($arg =~ /^(json|screen|xml)$/){
			if ($arg =~ /json|screen|xml/){
				$output_type = $arg;
			}
			else {
				error_handler('option-feature-incomplete', $opt, $arg);
			}
		}
		else {
			error_handler('bad-arg', $opt, $arg);
		}},
	'no-dig' => sub {
		$b_skip_dig = 1; },
	'no-host|no-hostname' => sub {
		$show{'host'} = 0 ;
		$show{'no-host'} = 1},
	'no-html-wan' => sub {
		$b_no_html_wan= 1;},
	'no-man' => sub {
		$b_no_man_force = 0; },
	'no-ssl' => sub {
		$dl{'no-ssl-opt'}=1 },
	'no-sudo' => sub {
		$b_no_sudo = 1; },
	'output-file:s' => sub {
		my ($opt,$arg) = @_;
		if ($arg){
			if ($arg eq 'print' || check_output_path($arg)){
				$output_file = $arg;
			}
			else {
				error_handler('output-file-bad', $opt, $arg);
			}
		}
		else {
			error_handler('bad-arg', $opt, $arg);
		}},
	'ppc' => sub {
		$b_ppc = 1 },
	'recommends' => sub {
		$b_recommends = 1; },
	'sensors-default' => sub {
		$b_sensors_default = 1; },
	'sensors-exclude:s' => sub {
		my ($opt,$arg) = @_;
		if ($arg){
			@sensors_exclude = split /\s*,\s*/, $arg;
		}
		else {
			error_handler('bad-arg',$opt,$arg);
		}},
	'sensors-use:s' => sub {
		my ($opt,$arg) = @_;
		if ($arg){
			@sensors_use = split /\s*,\s*/, $arg;
		}
		else {
			error_handler('bad-arg',$opt,$arg);
		}},
	'sparc' => sub {
		$b_sparc = 1; },
	'sys-debug' => sub {
		$debugger{'sys-force'} = 1; },
	'tty' => sub { # workaround for ansible running this
		$b_irc = 0; },
	'U|update:s' => sub { # 1,2,3 OR http://myserver/path/inxi
		my ($opt,$arg) = @_;
		$b_downloader = 1;
		if ( $use{'update'} ){
			$b_updater = 1;
			if (!$arg && $self_name eq 'pinxi'){
				$b_man = 1;
				$download_id = 'inxi-perl branch';
				$self_download = get_defaults('inxi-pinxi');
			}
			elsif ($arg && $arg eq '3'){
				$b_man = 1;
				$download_id = 'dev server';
				$self_download = get_defaults('inxi-dev');
			}
			else {
				if (!$arg){
					$download_id = 'main branch';
					$self_download = get_defaults('inxi-main');
					$b_man = 1;
					$b_use_man = 1;
				}
				elsif ( $arg =~ /^[12]$/){
					$download_id = "branch $arg";
					$self_download = get_defaults("inxi-branch-$arg");
				}
				elsif ( $arg =~ /^http/){
					$download_id = 'alt server';
					$self_download = $arg;
				}
			}
			if (!$self_download){
				error_handler('bad-arg', $opt, $arg);
			}
		}
		else {
			error_handler('distro-block', $opt);
		} },
	'usb-sys' => sub {
		$b_usb_sys = 1 },
	'usb-tool' => sub {
		$b_usb_tool = 1 },
	'wan-ip-url:s' => sub {
		my ($opt,$arg) = @_;
		if ($arg && $arg =~ /^(f|ht)tp[s]?:\/\//){
			$wan_url = $arg;
			$b_skip_dig = 1
		}
		else {
			error_handler('bad-arg', $opt, $arg);
		}},
	'wm' => sub { 
		$b_wmctrl = 1 },
	'<>' => sub {
		my ($opt) = @_;
		error_handler('unknown-option', "$opt", "" ); }
	) ; #or error_handler('unknown-option', "@ARGV", '');
	## run all these after so that we can change widths, downloaders, etc
	eval $end if $b_log;
	CheckRecommends::run() if $b_recommends;
	set_downloader() if $b_downloader || $wan_url || ($b_skip_dig && $show{'ip'}); # sets for either config or arg here
	set_xorg_log() if $show{'graphic'};
	show_version() if $b_version;
	show_options() if $b_help;
	$b_man = 0 if (!$b_use_man || $b_no_man_force);
	update_me( $self_download, $download_id ) if $b_updater;
	if ($output_type){
		if ($output_type ne 'screen' && ! $output_file){
			error_handler('bad-arg', '--output', '--output-file not provided');
		}
	}
	$show{'graphic-basic'} = 0 if $b_admin;
	if ($b_sensors_default){
		@sensors_exclude = ();
		@sensors_use = ();
	}
	$b_block_tool = 1 if ( $b_admin && ($show{'partition'} || $show{'partition-full'} ));
	set_sudo() if ( $show{'unmounted'} || ($extra > 0 && $show{'disk'}) );
	$extra = 3 if $b_admin;
	$use{'filter'} = 0 if $use{'filter-override'};
	# override for things like -b or -v2 to -v3
	$show{'cpu-basic'} = 0 if $show{'cpu'};
	$show{'optical-basic'} = 0 if $show{'optical'};
	$show{'partition'} = 0 if $show{'partition-full'};
	$show{'host'} = 0 if $show{'no-host'};
	$show{'host'} = 1 if ($show{'host'} || (!$use{'filter'} && !$show{'no-host'}));
	if ($show{'disk'} || $show{'optical'} ){
		$show{'disk-basic'} = 0;
		$show{'disk-total'} = 0;
	}
	if ( $show{'ram'} || $show{'slot'} || ($show{'cpu'} && $extra > 1) ||
	     ( ( $bsd_type || $b_dmidecode_force ) && ($show{'machine'} || $show{'battery'}) ) ){
		$b_dmi = 1;
	}
	if ($show{'audio'} || $show{'graphic'} || $show{'network'} || $show{'raid'} || $show{'raid-forced'} ){
		$b_pci = 1;
	}
	if ($show{'usb'} || $show{'audio'} || $show{'graphic'} || $show{'network'} ){
		$b_usb = 1;
	}
	if ($bsd_type && ($show{'short'} || $show{'system'} || $show{'battery'} || $show{'cpu'} || $show{'cpu-basic'} || 
	   $show{'info'} || $show{'machine'} || $show{'process'} || $show{'ram'}  || $show{'sensor'} ) ){
		$b_sysctl = 1;
	}
	if ($bsd_type && ($show{'short'} || $show{'disk-basic'} || $show{'disk-total'} || $show{'disk'})){
		$b_dm_boot_disk = 1;
	}
	if ($bsd_type && ($show{'optical-basic'} || $show{'optical'})){
		$b_dm_boot_optical = 1
	}
	if ($b_admin && $show{'disk'}){
		$b_smartctl = 1;
	}
} 

sub show_options {
	error_handler('not-in-irc', 'help') if $b_irc;
	my (@row,@rows,@data);
	my $line = '';
	my $color_scheme_count = get_color_scheme('count') - 1; 
	my $partition_string='partition';
	my $partition_string_u='Partition';
	my $flags = ($b_arm) ? 'features' : 'flags' ;
	if ( $bsd_type ){
		$partition_string='slice';
		$partition_string_u='Slice';
	}
	# fit the line to the screen!
	for my $i ( 0 .. ( ( $size{'max'} / 2 ) - 2 ) ){
		$line = $line . '- ';
	}
	@rows = (
	['0', '', '', "$self_name supports the following options. For more detailed 
	information, see man^$self_name. If you start $self_name with no arguments,
	it will display a short system summary." ],
	['0', '', '', '' ],
	['0', '', '', "You can use these options alone or together, 
	to show or add the item(s) you want to see: A, B, C, D, G, I, J, M, N, P, 
	R, S, W, d, f, i, j, l, m, n, o, p, r, s, t, u, w, --slots. 
	If you use them with -v [level], -b or -F, $self_name will add the requested
	lines to the output." ],
	['0', '', '', '' ],
	['0', '', '', "Examples:^$self_name^-v4^-c6 OR $self_name^-bDc^6 OR
	$self_name^-FzjJxy^80" ],
	['0', '', '', $line ],
	['0', '', '', "Output Control Options:" ],
	['1', '-a', '--admin', "Adds advanced sys admin data (only works with 
	verbose or line output, not short form); check man page for explanations!; 
	also sets --extra=3:" ],
	['2', '-A', '', "If available: list of alternate kernel modules/drivers 
	for device(s)." ],
	['2', '-C', '', "If available: CPU socket type, base/boost speeds 
	(dmidecode+root/sudo required); CPU vulnerabilities (bugs); 
	family, model-id, stepping - format: hex (decimal) if greater 
	than 9, otherwise hex; microcode - format: hex." ],
	['2', '-d,-D', '', "If available: logical and physical block sizes; drive family;
	USB drive specifics; SMART report." ],
	['2', '-G', '', "If available: Xorg Display ID, Screens total, default Screen,
	current Screen; per X Screen: resolution, dpi, size, diagonal; per Monitor: 
	resolution; hz; dpi; size; diagonal; list of alternate kernel modules/drivers
	for device(s)." ],
	['2', '-I', '', "As well as per package manager counts, also adds total
	number of lib files found for each package manager if not -r." ],
	['2', '-j,-p,-P', '', "For swap (if available): swappiness and vfs cache 
	pressure, and if values are default or not." ],
	['2', '-n,-N', '', "If available: list of alternate kernel modules/drivers 
	for device(s)." ],
	['2', '-p,-P', '', "If available: raw size of ${partition_string}s, 
	percent available for user, block size of file system (root required)." ],
	['2', '-r', '', "Packages, see -Ia." ],
	['2', '-S', '', "If available: kernel boot parameters." ],
	['1', '-A', '--audio', "Audio/sound card(s), driver, sound server." ],
	['1', '-b', '--basic', "Basic output, short form. Same as $self_name^-v^2." ],
	['1', '-B', '--battery', "System battery info, including charge and condition, plus 
	extra info (if battery present)." ],
	['1', '-c', '--color', "Set color scheme (0-42). For piped or redirected output,
	you must use an explicit color selector. Example:^$self_name^-c^11" ],
	['1', '', '', "Color selectors let you set the config file value for the 
	selection (NOTE: IRC and global only show safe color set)" ],
	['2', '94', '', "Console, out of X" ],
	['2', '95', '', "Terminal, running in X - like xTerm" ],
	['2', '96', '', "Gui IRC, running in X - like Xchat, Quassel, Konversation etc." ],
	['2', '97', '', "Console IRC running in X - like irssi in xTerm" ],
	['2', '98', '', "Console IRC not in  X" ],
	['2', '99', '', "Global - Overrides/removes all settings. Setting specific 
	removes global." ],
	['1', '-C', '--cpu', "CPU output, including per CPU clock speed and max 
	CPU speed (if available)." ],
	['1', '-d', '--disk-full, --optical', "Optical drive data (and floppy disks, 
	if present). Triggers -D." ],
	['1', '-D', '--disk', "Hard Disk info, including total storage and details 
	for each disk. Disk total used percentage includes swap ${partition_string}
	size(s)." ],
	['1', '-f', '--flags', "All CPU $flags. Triggers -C. Not shown with -F to 
	avoid spamming." ],
	['1', '-F', '--full', "Full output. Includes all Upper Case line letters 
	except -W, plus --swap, -s and -n. Does not show extra verbose options such 
	as -d -f -i -l -m -o -p -r -t -u -x, unless specified." ],
	['1', '-G', '--graphics', "Graphics info (card(s), driver, display protocol 
	(if available), display server/Wayland compositor, resolution, renderer, 
	OpenGL version)." ],
	['1', '-i', '--ip', "WAN IP address and local interfaces (requires ifconfig 
	or ip network tool). Triggers -n. Not shown with -F for user security reasons. 
	You shouldn't paste your local/WAN IP." ],
	['1', '-I', '--info', "General info, including processes, uptime, memory, 
	IRC client or shell type, $self_name version." ],
	['1', '-j', '--swap', "Swap in use. Includes ${partition_string}s, zram, file." ],
	['1', '-J', '--usb', "Show USB data: Hubs and Devices." ],
	['1', '-l', '--label', "$partition_string_u labels. Triggers -P. 
	For full -p output, use -pl." ],
	['1', '-m', '--memory', "Memory (RAM) data. Requires root. Numbers of 
	devices (slots) supported and individual memory devices (sticks of memory etc). 
	For devices, shows device locator, size, speed, type (e.g. DDR3). 
	If neither -I nor -tm are selected, also shows RAM used/total." ],
	['1', '', '--memory-modules', "Memory (RAM) data. Exclude empty module slots." ],
	['1', '', '--memory-short', "Memory (RAM) data. Show only short Memory RAM report, 
	number of arrays, slots, modules, and RAM type." ],
	['1', '-M', '--machine', "Machine data. Device type (desktop, server, laptop, 
	VM etc.), motherboard, BIOS and, if    present, system builder (e.g. Lenovo). 
	Shows UEFI/BIOS/UEFI [Legacy]. Older systems/kernels without the required /sys 
	data can use dmidecode instead, run as root. Dmidecode can be forced with --dmidecode" ],
	['1', '-n', '--network-advanced', "Advanced Network card info. Triggers -N. Shows 
	interface, speed, MAC id, state, etc. " ],
	['1', '-N', '--network', "Network card(s), driver." ],
	['1', '-o', '--unmounted', "Unmounted $partition_string info (includes UUID 
	and Label if available). Shows file system type if you have lsblk installed 
	(Linux) or, for BSD/GNU Linux, if 'file' installed and you are root or if 
	you have added to /etc/sudoers (sudo v. 1.7 or newer)." ],
	['1', '', '', "Example: ^<username>^ALL^=^NOPASSWD:^/usr/bin/file^" ],
	['1', '-p', '--partitions-full', "Full $partition_string information (-P plus all other 
	detected ${partition_string}s)." ],
	['1', '-P', '--partitions', "Basic $partition_string info. Shows, if detected: 
	/ /boot /home /opt /tmp /usr /usr/home /var /var/log /var/tmp. Swap 
	${partition_string}s show if --swap is not used. Use -p to see all 
	mounted ${partition_string}s." ],
	['1', '-r', '--repos', "Distro repository data. Supported repo types: APK, 
	APT, CARDS, EOPKG, PACMAN, PACMAN-G2, PISI, PORTAGE, PORTS (BSDs), SLACKPKG,
	TCE, URPMQ, XBPS, YUM/ZYPP." ],
	['1', '-R', '--raid', "RAID data. Shows RAID devices, states, levels, 
	and components. md-raid: If device is resyncing, also shows resync progress line." ],
	['1', '-s', '--sensors', "Sensors output (if sensors installed/configured): 
	mobo/CPU/GPU temp; detected fan speeds. GPU temp only for Fglrx/Nvidia drivers. 
	Nvidia shows screen number for > 1 screen. IPMI sensors if present." ],
	['1', '', '--slots', "PCI slots: type, speed, status. Requires root." ],
	['1', '-S', '--system', "System info: host name, kernel, desktop environment 
	(if in X/Wayland), distro." ],
	['1', '-t', '--processes', "Processes. Requires extra options: c (CPU), m 
	(memory), cm (CPU+memory). If followed by numbers 1-x, shows that number 
	of processes for each type (default: 5; if in IRC, max: 5). " ],
	['1', '', '', "Make sure that there is no space between letters and 
	numbers (e.g.^-t^cm10)." ],
	['1', '-u', '--uuid', "$partition_string_u UUIDs. Triggers -P. For full -p 
	output, use -pu." ],
	['1', '-v', '--verbosity', "Set $self_name verbosity level (0-8). 
	Should not be used with -b or -F. Example: $self_name^-v^4" ],
	['2', '0', '', "Same as: $self_name" ],
	['2', '1', '', "Basic verbose, -S + basic CPU + -G + basic Disk + -I." ],
	['2', '2', '', "Networking card (-N), Machine (-M), Battery (-B; if present), 
	and, if present, basic RAID (devices only; notes if inactive). 
	Same as $self_name^-b" ],
	['2', '3', '', "Advanced CPU (-C), battery (-B), network (-n); 
	triggers -x. " ],
	['2', '4', '', "$partition_string_u size/used data (-P) for 
	(if present) /, /home, /var/, /boot. Shows full disk data (-D). " ],
	['2', '5', '', "Audio card (-A), sensors (-s), memory/RAM (-m), 
	$partition_string label^(-l), full swap (-j), UUID^(-u), short form 
	of optical drives, standard RAID data (-R). " ],
	['2', '6', '', "Full $partition_string (-p), 
	unmounted $partition_string (-o), optical drive (-d), USB (-J),
	full RAID; triggers -xx." ], 
	['2', '7', '', "Network IP data (-i); triggers -xxx."],
	['2', '8', '', "Everything available, including repos (-r), processes 
	(-tcm), PCI slots (--slots)."],
	);
	push @data, @rows;
	# if distro maintainers don't want the weather feature disable it
	if ( $use{'weather'} ){
		@rows = (
		['1', '-w', '--weather', "Local weather data/time. To check an alternate
		location, see -W. NO AUTOMATED QUERIES ALLOWED!"],
		['1', '-W', '--weather-location', "[location] Supported options for 
		[location]: postal code[,country/country code]; city, state (USA)/country 
		(country/two character country code); latitude, longitude. Only use if you 
		want the weather somewhere other than the machine running $self_name. Use 
		only ASCII characters, replace spaces in city/state/country names with '+'. 
		Example:^$self_name^-W^[new+york,ny^london,gb^madrid,es]"],
		['1', '', '--weather-source', "[1-9] Change weather data source. 1-4 generally 
		active, 5-9 check. See man."],
		['1', '', '--weather-unit', "Set weather units to metric (m), imperial (i), 
		metric/imperial (mi), or imperial/metric (im)."],
		);
		push @data, @rows;
	}
	@rows = (
	['1', '-x', '--extra', "Adds the following extra data (only works with 
	verbose or line output, not short form):" ],
	['2', '-A', '', "Specific vendor/product information (if relevant); 
	PCI Bus ID/USB ID number of card; Version/port(s)/driver version (if available)." ],
	['2', '-B', '', "Vendor/model, status (if available); attached devices 
	(e.g. wireless mouse, keyboard, if present)." ],
	['2', '-C', '', "CPU $flags (short list, use -f to see full list);
	CPU boost (turbo) enabled/disabled, if present; 
	Bogomips on CPU; CPU microarchitecture + 	revision (if found, or 
	unless --admin, then shows as 'stepping')." ],
	['2', '-d', '', "Extra optical drive features data; adds rev version to 
	optical drive." ],
	['2', '-D', '', "HDD temp with disk data if you have hddtemp installed, 
	if you are root, or if you have added to /etc/sudoers (sudo v. 1.7 or newer). 
	Example:^<username>^ALL^=^NOPASSWD:^/usr/sbin/hddtemp" ],
	['2', '-G', '', "Specific vendor/product information (if relevant); 
	PCI Bus ID/USB ID number of card; Direct rendering status (in X); Screen 
	number GPU is running on (Nvidia only)." ],
	['2', '-i', '', "For IPv6, show additional scope addresses: Global, Site, 
	Temporary, Unknown. See --limit for large counts of IP addresses." ],
	['2', '-I', '', "Default system GCC. With -xx, also shows other installed 
	GCC versions. If running in shell, not in IRC client, shows shell version 
	number, if detected. Init/RC type and runlevel (if available). Total
	count of all packages discovered in system and not -r." ],
	['2', '-J', '', "For Device: driver." ],
	['2', '-m,--memory-modules', '', "Max memory module size (if available), device type." ],
	['2', '-N', '', "Specific vendor/product information (if relevant); 
	PCI Bus ID/USB ID number of card; Version/port(s)/driver version (if available)." ],
	['2', '-r', '', "Packages, see -Ix." ],
	['2', '-R', '', "md-raid: second RAID Info line with extra data: 
	blocks, chunk size, bitmap (if present). Resync line, shows blocks 
	synced/total blocks. Hardware RAID driver version, bus ID." ],
	['2', '-s', '', "Basic voltages (ipmi, lm-sensors if present): 12v, 5v, 3.3v, vbat." ],
	['2', '-S', '', "Kernel gcc version; system base of distro (if relevant 
	and detected)" ],
	['2', '-t', '', "Adds memory use output to CPU (-xt c), and CPU use to 
	memory (-xt m)." ],
	);
	push @data, @rows;
	if ( $use{'weather'} ){
		@rows = (['2', '-w -W', '', "Wind speed and direction, humidity, pressure, 
		and time zone, if available." ]);
		push @data, @rows;
	}
	@rows = (
	['1', '-xx', '--extra 2', "Show extra, extra data (only works with verbose 
	or line output, not short form):" ],
	['2', '-A', '', "Chip vendor:product ID for each audio device." ],
	['2', '-B', '', "Serial number, voltage now/minimum (if available)." ],
	['2', '-C', '', "L1/L3 cache (if root and dmidecode installed)." ],
	['2', '-D', '', "Disk transfer speed; NVMe lanes; Disk serial number." ],
	['2', '-G', '', "Chip vendor:product ID for each video card; OpenGL 
	compatibility version, if free drivers and available; Xorg compositor;
	alternate Xorg drivers (if available). Alternate means driver is on automatic 
	driver check list of Xorg for the card vendor, but is not installed on system;
	Xorg dpi." ],
	['2', '-I', '', "Other detected installed gcc versions (if present). System 
	default runlevel. Adds parent program (or tty) for shell info if not in 
	IRC. Adds Init version number, RC (if found). Adds per package manager
	package counts if not -r." ],
	['2', '-j,-p,-P', '', "Swap priority." ],
	['2', '-J', '', "Vendor:chip ID." ],
	['2', '-m,--memory-modules', '', "Manufacturer, part number; single/double bank (if found)." ],
	['2', '-M', '', "Chassis info, BIOS ROM size (dmidecode only), if available." ],
	['2', '-N', '', "Chip vendor:product ID." ],
	['2', '-r', '', "Packages, see -Ixx." ],
	['2', '-R', '', "md-raid: Superblock (if present), algorithm. If resync, 
	shows progress bar. Hardware RAID Chip vendor:product ID." ],
	['2', '-s', '', "DIMM/SOC voltages (ipmi only)." ],
	['2', '-S', '', "Display manager (dm) in desktop output (e.g. kdm, 
	gdm3, lightdm); active window manager if detected; desktop toolkit, 
	if available (Xfce/KDE/Trinity only)." ],
	['2', '--slots', '', "Slot length." ],
	);
	push @data, @rows;
	if ( $use{'weather'} ){
		@rows = (['2', '-w -W', '', "Snow, rain, precipitation, (last observed hour), 
		cloud cover, wind chill, dew point, heat index, if available." ]);
		push @data, @rows;
	}
	@rows = (
	['1', '-xxx', '--extra 3', "Show extra, extra, extra data (only works 
	with verbose or line output, not short form):" ],
	['2', '-A', '', "Serial number." ],
	['2', '-B', '', "Chemistry, cycles, location (if available)." ],
	['2', '-C', '', "CPU voltage, external clock speed (if root and dmidecode installed)." ],
	['2', '-D', '', "Firmware rev. if available; partition scheme, in some cases; disk 
	rotation speed (if detected)." ],
	['2', '-I', '', "For 'Shell:' adds ([su|sudo|login]) to shell name if present; 
	adds default shell+version if different; for 'running in:' adds (SSH) if SSH session;
	adds wakeups: (from suspend) to Uptime." ],
	['2', '-J', '', "For Device: serial number (if present), interface count; USB speed." ],
	['2', '-m,--memory-modules', '', "Width of memory bus, data and total (if present and greater 
	than data); Detail for Type, if present; module voltage, if available; serial 
	number." ],
	['2', '-N', '', "Serial number." ],
	['2', '-R', '', "zfs-raid: portion allocated (used) by RAID devices/arrays. 
	md-raid: system md-raid support types (kernel support, read ahead, RAID events).
	Hardware RAID rev, ports, specific vendor/product information." ],
	['2', '-S', '', "Panel/tray/bar/dock info in desktop output, if in X (like lxpanel, 
	xfce4-panel, mate-panel); (if available) dm version number, window manager
	version number." ],
	);
	push @data, @rows;
	if ( $use{'weather'} ){
		@rows = (['2', '-w -W', '', "Location (uses -z/irc filter), weather observation 
		time, altitude, sunrise/sunset, if available." ] );
		push @data, @rows;
	}
	@rows = (
	['1', '-y', '--width', "Output line width max (integer >= 80). Overrides IRC/Terminal 
	settings or actual widths. If no integer give, defaults to 80. -1 removes line lengths.
	1 switches output to 1 key/value pair per line. Example:^inxi^-y^130" ],
	['1', '-z', '--filter', "Adds security filters for IP/MAC addresses, serial numbers, 
	location (-w), user home directory name, host item. Default on for IRC clients." ],
	['1', '', '--filter-label', "Filters out ${partition_string} labels in -j, 
	-o, -p, -P, -Sa." ],
	['1', '-Z', '--filter-override', "Override for output filters. Useful for 
	debugging networking issues in IRC, for example." ],
	['1', '', '--filter-uuid', "Filters out ${partition_string} UUIDs in -j, 
	-o, -p, -P, -Sa." ],
	[0, '', '', "$line" ],
	[0, '', '', "Additional Options:" ],
	['1', '-h', '--help', "This help menu." ],
 	['1', '', '--recommends', "Checks $self_name application dependencies + recommends, 
 	and directories, then shows what package(s) you need to install to add support 
 	for that feature." ]
	);
	push @data, @rows;
	if ( $use{'update'} ){
		@rows = (
		['1', '-U', '--update', "Auto-update $self_name. Will also install/update man 
		page. Note: if you installed as root, you must be root to update, otherwise 
		user is fine. Man page installs require root. No arguments downloads from 
		main $self_name git repo." ],
		['1', '', '', "Use alternate sources for updating $self_name" ],
		['2', '1', '', "Get the git branch one version." ],
		['2', '2', '', "Get the git branch two version." ],
		['3', '3', '', "Get the dev server (smxi.org) version." ],
		['2', '<http>', '', "Get a version of $self_name from your own server. 
		Use the full download path, e.g.^$self_name^-U^https://myserver.com/inxi" ]
		);
		push @data, @rows;
	}
	@rows = (
	['1', '-V', '--version', "Prints $self_name version info then exits." ],
	['0', '', '', "$line" ],
	['0', '', '', "Advanced Options:" ],
	['1', '', '--alt', "Trigger for various advanced options:" ],
	['2', '40', '', "Bypass Perl as a downloader option." ],
	['2', '41', '', "Bypass Curl as a downloader option." ],
	['2', '42', '', "Bypass Fetch as a downloader option." ],
	['2', '43', '', "Bypass Wget as a downloader option." ],
	['2', '44', '', "Bypass Curl, Fetch, and Wget as downloader options. Forces 
	Perl if HTTP::Tiny present." ],
	['1', '', '--dig', "Overrides configuration item NO_DIG (resets to default)." ],
	['1', '', '--display', "[:[0-9]] Try to get display data out of X (default: display 0)." ],
	['1', '', '--dmidecode', "Force use of dmidecode data instead of /sys where relevant 
	(e.g. -M, -B)." ],
	['1', '', '--downloader', "Force $self_name to use [curl|fetch|perl|wget] for downloads." ],
	['1', '', '--host', "Turn on hostname for -S." ],
	['1', '', '--html-wan', "Overrides configuration item NO_HTML_WAN (resets to default)." ],
	['1', '', '--indent-min', "Set point where $self_name autowraps line starters." ],
	['1', '', '--limit', "[-1; 1-x] Set max output limit of IP addresses for -i 
	(default 10; -1 removes limit)." ],
	);
	push @data, @rows;
	if ( $use{'update'} ){
		@rows = (
		['1', '', '--man', "Install correct man version for dev branch (-U 3) or pinxi using -U." ],
		);
		push @data, @rows;
	}
	@rows = (
	['1', '', '--no-dig', "Skip dig for WAN IP checks, use downloader program." ],
	['1', '', '--no-host', "Turn off hostname for -S. Useful if showing output from servers etc." ],
	['1', '', '--no-html-wan', "Skip HTML IP sources for WAN IP checks, use dig only, 
	or nothing if --no-dig." ],
	);
	push @data, @rows;
	if ( $use{'update'} ){
		@rows = (
		['1', '', '--no-man', "Disable man install for all -U update actions." ],
		);
		push @data, @rows;
	}
	@rows = (
	['1', '', '--no-ssl', "Skip SSL certificate checks for all downloader actions 
	(Wget/Fetch/Curl/Perl-HTTP::Tiny)." ],
	['1', '', '--no-sudo', "Skip internal program use of sudo features (not related 
	to starting $self_name with sudo)." ],
	['1', '', '--output', "[json|screen|xml] Change data output type. Requires --output-file 
	if not screen." ],
	['1', '', '--output-file', "[Full filepath|print] Output file to be used for --output." ],
	['1', '', '--partition-sort', "[dev-base|fs|id|label|percent-used|size|uuid|used] 
	Change sort order of ${partition_string} output. See man page for specifics." ],
	['1', '', '--sensors-default', "Removes configuration item SENSORS_USE and SENSORS_EXCLUDE.
	Same as default behavior." ],
	['1', '', '--sensors-exclude', "[sensor[s] name, comma separated] Exclude supplied sensor 
	array[s] for -s output (lm-sensors, Linux only)." ],
	['1', '', '--sensors-use', "[sensor[s] name, comma separated] Use only supplied sensor 
	array[s] for -s output (lm-sensors, Linux only)." ],
	['1', '', '--sleep', "[0-x.x] Change CPU sleep time, in seconds, for -C 
	(default:^$cpu_sleep). Allows system to catch up and show a more accurate CPU 
	use. Example:^$self_name^-Cxxx^--sleep^0.15" ],
	['1', '', '--tty', "Forces irc flag to false. Generally useful if $self_name is running
	inside of another tool like Chef or MOTD and returns corrupted color codes. Please see
	man page or file an issue if you need to use this flag. Must use -y [width] option if 
	you want a specific output width. Always put this option first in an option list."],
	['1', '', '--usb-sys', "Force USB data to use /sys as data source (Linux only)." ],
	['1', '', '--usb-tool', "Force USB data to use lsusb as data source (Linux only)." ],
	['1', '', '--wan-ip-url', "[URL] Skips dig, uses supplied URL for WAN IP (-i). 
	URL output must end in the IP address. See man. 
	Example:^$self_name^-i^--wan-ip-url^https://yoursite.com/ip.php" ],
	['1', '', '--wm', "Force wm: to use wmctrl as data source. Default uses ps." ],
	['0', '', '', $line ],
	['0', '', '', "Debugging Options:" ],
	['1', '', '--dbg', "Specific debuggers, change often. Only 1 is constant:" ],
	['2', '1', '', "Show downloader output. Turns off quiet mode." ],
	['1', '', '--debug', "Triggers debugging modes." ],
	['2', '1-3', '', "On screen debugger output." ],
	['2', '10', '', "Basic logging." ],
	['2', '11', '', "Full file/system info logging." ],
	['1', '', ,'', "The following create a tar.gz file of system data, plus $self_name 
	output. To automatically upload debugger data tar.gz file 
	to ftp.smxi.org: $self_name^--debug^21" ],
	['2', '20', '', "Full system data collection: /sys; xorg conf and log data, xrandr, 
	xprop, xdpyinfo, glxinfo etc.; data from dev, disks,  
	${partition_string}s, etc." ],
	['2', '21', '', "Upload debugger dataset to $self_name debugger server 
	automatically, removes debugger data directory, leaves tar.gz debugger file." ],
	['2', '22', '', "Upload debugger dataset to $self_name debugger server 
	automatically, removes debugger data directory and debugger tar.gz file." ],
	# ['1', '', '--debug-filter', "Add -z flag to debugger $self_name optiions." ],
	['1', '', '--debug-proc', "Force debugger parsing of /proc as sudo/root." ],
	['1', '', '--debug-proc-print', "To locate file that /proc debugger hangs on." ],
	['1', '', '--debug-no-exit', "Skip exit on error to allow completion." ],
	['1', '', '--debug-no-proc', "Skip /proc debugging in case of a hang." ],
	['1', '', '--debug-no-sys', "Skip /sys debugging in case of a hang." ],
	['1', '', '--debug-sys', "Force PowerPC debugger parsing of /sys as sudo/root." ],
	['1', '', '--debug-sys-print', "To locate file that /sys debugger hangs on." ],
	['1', '', '--ftp', "Use with --debugger 21 to trigger an alternate FTP server for upload. 
	Format:^[ftp.xx.xx/yy]. Must include a remote directory to upload to. 
	Example:^$self_name^--debug^21^--ftp^ftp.myserver.com/incoming" ],
	['0', '', '', "$line" ],
	);
	push @data, @rows;
	print_basic(@data); 
	exit 0; # shell true
}

sub show_version {
	# if not in PATH could be either . or directory name, no slash starting
	my $working_path=$self_path;
	my (@data, @row, @rows, $link, $self_string);
	Cwd->import('getcwd'); # no point loading this on top use, we only use getcwd here
	if ( $working_path eq '.' ){
		$working_path = getcwd();
	}
	elsif ( $working_path !~ /^\// ){
		$working_path = getcwd() . "/$working_path";
	}
	$working_path =~ s%/$%%;
	# handle if it's a symbolic link, rare, but can happen with directories 
	# in irc clients which would only matter if user starts inxi with -! 30 override 
	# in irc client
	if ( -l "$working_path/$self_name" ){
		$link="$working_path/$self_name";
		$working_path = readlink "$working_path/$self_name";
		$working_path =~ s/[^\/]+$//;
	}
	# strange output /./ ending, but just trim it off, I don't know how it happens
	$working_path =~ s%/\./%/%;
	@row = (
	[ 0, '', '', "$self_name $self_version-$self_patch ($self_date)"],
	);
	push @data, @row;
	if ( ! $b_irc ){
		@row = ([ 0, '', '', ''],);
		push @data, @row;
		my $year = (split/-/, $self_date)[0];
		@row = (
		[ 0, '', '', "Copyright^(C)^2008-$year^Harald^Hope^aka^h2"],
		[ 0, '', '', "Forked from Infobash 3.02: Copyright^(C)^2005-2007^Michiel^de^Boer^aka^locsmif." ],
		[ 0, '', '', "Using Perl version: $]"],
		[ 0, '', '', "Program Location: $working_path" ],
		);
		push @data, @row;
		if ( $link ){
			@row = [ 0, '', '', "Started via symbolic link: $link" ];
			push @data, @row;
		}
		@rows = (
		[ 0, '', '', '' ],
		[ 0, '', '', "Website:^https://github.com/smxi/inxi^or^https://smxi.org/" ],
		[ 0, '', '', "IRC:^irc.oftc.net channel:^#smxi" ],
		[ 0, '', '', "Forums:^https://techpatterns.com/forums/forum-33.html" ],
		
		[ 0, '', '', '' ],
		[ 0, '', '', "This program is free software; you can redistribute it and/or modify 
		it under the terms of the GNU General Public License as published by the Free Software 
		Foundation; either version 3 of the License, or (at your option) any later version. 
		(https://www.gnu.org/licenses/gpl.html)" ]
		);
		push @data, @rows;
	}
	print_basic(@data); 
	exit 0; # shell true
}

########################################################################
#### STARTUP DATA
########################################################################

# StartClient
{
package StartClient;
# use warnings;
# use strict;
my $ppid = '';
my $pppid = '';

# NOTE: there's no reason to crete an object, we can just access
# the features statically. 
# args: none
# sub new {
# 	my $class = shift;
# 	my $self = {};
# 	# print "$f\n";
# 	# print "$type\n";
# 	return bless $self, $class;
# }

sub get_client_data {
	eval $start if $b_log;
	$ppid = getppid();
	main::set_ps_aux() if ! @ps_aux;
	if (!$b_irc){
		# we'll run get_shell_data for -I, but only then
		$client{'ppid'} = $ppid;
	}
	else {
		$use{'filter'} = 1; 
		get_client_name();
		if ($client{'konvi'} == 1 || $client{'konvi'} == 3){
			set_konvi_data();
		}
	}
	eval $end if $b_log;
}

sub get_client_name {
	eval $start if $b_log;
	my $client_name = '';
	
	# print "$ppid\n";
	if ($ppid && -e "/proc/$ppid/exe" ){
		$client_name = lc(readlink "/proc/$ppid/exe");
		$client_name =~ s/^.*\///;
		if ($client_name =~ /^bash|dash|sh|python.*|perl.*$/){
			$pppid = (main::grabber("ps -p $ppid -o ppid"))[1];
			#my @temp = (main::grabber("ps -p $ppid -o ppid 2>/dev/null"))[1];
			$pppid =~ s/^\s+|\s+$//g;
			$client_name =~ s/[0-9\.]+$//; # clean things like python2.7
			if ($pppid && -f "/proc/$pppid/exe" ){
				$client_name = lc(readlink "/proc/$pppid/exe");
				$client_name =~ s/^.*\///;
				$client{'native'} = 0;
			}
		}
		$client{'name'} = $client_name;
		get_client_version();
		# print "c:$client_name p:$pppid\n";
		#print "$client{'name-print'}\n";
	}
	else {
		if (! check_modern_konvi() ){
			$ppid = getppid();
			$client_name = (main::grabber("ps -p $ppid"))[1];
			if ($client_name){
				my @data = split /\s+/, $client_name if $client_name;
				if ($bsd_type){
					$client_name = lc($data[5]);
				}
				# gnu/linux uses last value
				else {
					$client_name = lc($data[-1]);
				}
				$client_name =~ s/.*\|-(|)//;
				$client_name =~ s/[0-9\.]+$//; # clean things like python2.7
				$client{'name'} = $client_name;
				$client{'native'} = 1;
				get_client_version();
			}
			else {
				$client{'name'} = "PPID='$ppid' - Empty?";
			}
		}
	}
	if ($b_log){
		my $string = "Client: $client{'name'} :: version: $client{'version'} :: konvi: $client{'konvi'} :: PPID: $ppid";
		main::log_data('data', $string);
	}
	eval $end if $b_log;
}
sub get_client_version {
	eval $start if $b_log;
	@app = main::program_values($client{'name'});
	my (@data,@working,$string);
	if (@app){
		$string = ($client{'name'} =~ /^gribble|limnoria|supybot$/) ? 'supybot' : $client{'name'};
		$client{'version'} = main::program_version($string,$app[0],$app[1],$app[2],$app[4],$app[5],$app[6]);
		$client{'name-print'} = $app[3];
		$client{'console-irc'} = $app[4];
	}
	if ($client{'name'} =~ /^bash|dash|sh$/ ){
		$client{'name-print'} = 'shell wrapper';
		$client{'console-irc'} = 1;
	}
	elsif ($client{'name'} eq 'bitchx') {
		@data = main::grabber("$client{'name'} -v");
		$string = awk(\@data,'Version');
		if ($string){
			$string =~ s/[()]|bitchx-//g; 
			@data = split /\s+/, $string;
			$_=lc for @data;
			$client{'version'} = ($data[1] eq 'version') ? $data[2] : $data[1];
		}
	}
	# 'hexchat' => ['',0,'','HexChat',0,0], # special
	# the hexchat author decided to make --version/-v return a gtk dialogue box, lol...
	# so we need to read the actual config file for hexchat. Note that older hexchats
	# used xchat config file, so test first for default, then legacy. Because it's possible
	# for this file to be user edited, doing some extra checks here.
	elsif ($client{'name'} eq 'hexchat') {
		if ( -f '~/.config/hexchat/hexchat.conf' ){
			@data = main::reader('~/.config/hexchat/hexchat.conf','strip');
		}
		elsif ( -f '~/.config/hexchat/xchat.conf' ){
			@data = main::reader('~/.config/hexchat/xchat.conf','strip');
		}
		if (@data){
			$client{'version'} = main::awk(\@data,'version',2,'\s*=\s*');
		}
		# fingers crossed, hexchat won't open gui!!
		if (!$client{'version'}) {
			@data = main::grabber("$client{'name'} --version 2>/dev/null");
			$client{'version'} = main::awk(\@data,'hexchat',2,'\s+');
		}
		$client{'name-print'} = 'HexChat';
	}
	# note: see legacy inxi konvi logic if we need to restore any of the legacy code.
	elsif ($client{'name'} eq 'konversation') {
		$client{'konvi'} = ( ! $client{'native'} ) ? 2 : 1;
	}
	elsif ($client{'name'} =~ /quassel/) {
		@data = main::grabber("$client{'name'} -v 2>/dev/null");
		foreach (@data){
			if ($_ =~ /^Quassel IRC:/){
				$client{'version'} = (split /\s+/, $_ )[2];
				last;
			}
			elsif ($_ =~ /quassel\s[v]?[0-9]/){
				$client{'version'} = (split /\s+/, $_ )[1];
				last;
			}
		}
		$client{'version'} ||= '(pre v0.4.1)?'; 
	}
	# then do some perl type searches, do this last since it's a wildcard search
	elsif ($client{'name'} =~ /^(perl.*|ksirc|dsirc)$/ ) {
		my @cmdline = main::get_cmdline();
		# Dynamic runpath detection is too complex with KSirc, because KSirc is started from
		# kdeinit. /proc/<pid of the grandparent of this process>/exe is a link to /usr/bin/kdeinit
		# with one parameter which contains parameters separated by spaces(??), first param being KSirc.
		# Then, KSirc runs dsirc as the perl irc script and wraps around it. When /exec is executed,
		# dsirc is the program that runs inxi, therefore that is the parent process that we see.
		# You can imagine how hosed I am if I try to make inxi find out dynamically with which path
		# KSirc was run by browsing up the process tree in /proc. That alone is straightjacket material.
		# (KSirc sucks anyway ;)
		foreach (@cmdline){
			if ( $_ =~ /dsirc/ ){
				$client{'version'} = main::program_version('ksirc','KSirc:',2,'-v',0,0);
				$client{'name'} = 'ksirc';
				$client{'name-print'} = 'KSirc';
			}
		}
		$client{'console-irc'} = 1;
		perl_python_client();
	}
	elsif ($client{'name'} =~ /python/) {
		perl_python_client();
	}
	if (!$client{'name-print'}) {
		# NOTE: these must be empirically determined, not all events that 
		# show no tty are actually IRC.
		my $wl_terms = 'alacritty|evilvte|germinal|guake|hyper|kate|kitty|kmscon|';
		$wl_terms .= 'konsole|minicom|putty|rxvt|sakura|shellinabox|^st$|sudo|term|tilda|';
		$wl_terms .= 'tilix|urvxt|yaft|yakuake';
		my $wl_clients = 'ansible|chef|run-parts|sshd';
		my $whitelist = "$wl_terms|$wl_clients";
		# print "$client{'name'}\n";
		if ($client{'name'} =~ /($whitelist)/i){
			if ($client{'name'} =~ /($wl_terms)/i){
				main::get_shell_data($ppid);
			}
			else {
				$client{'name-print'} = $client{'name'};
			}
			$b_irc = 0;
		}
		else {
			$client{'name-print'} = 'Unknown Client: ' . $client{'name'};
		}
	}
	eval $end if $b_log;
}
sub get_cmdline {
	eval $start if $b_log;
	my @cmdline;
	my $i = 0;
	$ppid = getppid();
	if (! -e "/proc/$ppid/cmdline" ){
		return 1;
	}
	local $\ = '';
	open( my $fh, '<', "/proc/$ppid/cmdline" ) or 
	  print_line("Open /proc/$ppid/cmdline failed: $!");
	my @rows = <$fh>;
	close $fh;
	foreach (@rows){
		push @cmdline, $_;
		$i++;
		last if $i > 31;
	}
	if ( $i == 0 ){
		$cmdline[0] = $rows[0];
		$i = ($cmdline[0]) ? 1 : 0;
	}
	main::log_data('string',"cmdline: @cmdline count: $i") if $b_log;
	eval $end if $b_log;
	return @cmdline;
}
sub perl_python_client {
	eval $start if $b_log;
	return 1 if $client{'version'};
	# this is a hack to try to show konversation if inxi is running but started via /cmd
	# OR via program shortcuts, both cases in fact now
	# main::print_line("konvi: " . scalar grep { $_ =~ /konversation/ } @ps_cmd);
	if ( $b_display && main::check_program('konversation') && 
	 ( grep { $_ =~ /konversation/ } @ps_cmd )){
		@app = main::program_values('konversation');
		$client{'version'} = main::program_version('konversation',$app[0],$app[1],$app[2],$app[5],$app[6]);
		$client{'name'} = 'konversation';
		$client{'name-print'} = $app[3];
		$client{'console-irc'} = $app[4];
	}
	## NOTE: supybot only appears in ps aux using 'SHELL' command; the 'CALL' command
	## gives the user system irc priority, and you don't see supybot listed, so use SHELL
	elsif ( !$b_display && 
	 (main::check_program('supybot') || 
	 main::check_program('gribble') || main::check_program('limnoria')) &&
	 ( grep { $_ =~ /supybot/ } @ps_cmd ) ){
		@app = main::program_values('supybot');
		$client{'version'} = main::program_version('supybot',$app[0],$app[1],$app[2],$app[5],$app[6]);
		if ($client{'version'}){
			if ( grep { $_ =~ /gribble/ } @ps_cmd ){
				$client{'name'} = 'gribble';
				$client{'name-print'} = 'Gribble';
			}
			if ( grep { $_ =~ /limnoria/ } @ps_cmd){
				$client{'name'} = 'limnoria';
				$client{'name-print'} = 'Limnoria';
			}
			else {
				$client{'name'} = 'supybot';
				$client{'name-print'} = 'Supybot';
			}
		}
		else {
			$client{'name'} = 'supybot';
			$client{'name-print'} = 'Supybot';
		}
		$client{'console-irc'} = 1;
	}
	else {
		$client{'name-print'} = "Unknown $client{'name'} client";
	}
	if ($b_log){
		my $string = "namep: $client{'name-print'} name: $client{'name'} version: $client{'version'}";
		main::log_data('data',$string);
	}
	eval $end if $b_log;
}
## try to infer the use of Konversation >= 1.2, which shows $PPID improperly
## no known method of finding Konvi >= 1.2 as parent process, so we look to see if it is running,
## and all other irc clients are not running. As of 2014-03-25 this isn't used in my cases
sub check_modern_konvi {
	eval $start if $b_log;
	return 0 if ! $client{'qdbus'};
	my $b_modern_konvi = 0;
	my $konvi_version = '';
	my $konvi = '';
	my $pid = '';
	my (@temp);
	# main::log_data('data',"name: $client{'name'} :: qdb: $client{'qdbus'} :: version: $client{'version'} :: konvi: $client{'konvi'} :: PPID: $ppid") if $b_log;
	# sabayon uses /usr/share/apps/konversation as path
	if ( -d '/usr/share/kde4/apps/konversation' || -d '/usr/share/apps/konversation' ){
		$pid = main::awk(\@ps_aux,'konversation -session',2,'\s+');
		main::log_data('data',"pid: $pid") if $b_log;
		$konvi = readlink ("/proc/$pid/exe");
		$konvi =~ s/^.*\///; # basename
		@app = main::program_values('konversation');
		if ($konvi){
			@app = main::program_values('konversation');
			$konvi_version = main::program_version($konvi,$app[0],$app[1],$app[2],$app[5],$app[6]);
			@temp = split /\./, $konvi_version;
			$client{'console-irc'} = $app[4];
			$client{'konvi'} = 3;
			$client{'name'} = 'konversation';
			$client{'name-print'} = $app[3];
			$client{'version'} = $konvi_version;
			# note: we need to change this back to a single dot number, like 1.3, not 1.3.2
			$konvi_version = $temp[0] . "." . $temp[1];
			if ($konvi_version > 1.1){
				$b_modern_konvi = 1;
			}
		}
	}
	main::log_data('data',"name: $client{'name'} name print: $client{'name-print'} 
	qdb: $client{'qdbus'} version: $konvi_version konvi: $konvi PID: $pid") if $b_log;
	main::log_data('data',"b_is_qt4: $b_modern_konvi") if $b_log;
	## for testing this module
# 	my $ppid = getppid();
# 	system('qdbus org.kde.konversation', '/irc', 'say', $client{'dserver'}, $client{'dtarget'}, 
# 	"getpid_dir: $konvi_qt4 verNum: $konvi_version pid: $pid ppid: $ppid" );
	eval $end if $b_log;
	return $b_modern_konvi;
}

sub set_konvi_data {
	eval $start if $b_log;
	my $config_tool = '';
	# https://userbase.kde.org/Konversation/Scripts/Scripting_guide
	if ( $client{'konvi'} == 3 ){
		$client{'dserver'} = shift @ARGV;
		$client{'dtarget'} = shift @ARGV;
		$client{'dobject'} = 'default';
	}
	elsif ( $client{'konvi'} == 1 ){
		$client{'dport'} = shift @ARGV;
		$client{'dserver'} = shift @ARGV;
		$client{'dtarget'} = shift @ARGV;
		$client{'dobject'} = 'Konversation';
	}
	# for some reason this logic hiccups on multiple spaces between args
	@ARGV = grep { $_ ne '' } @ARGV;
	# there's no current kde 5 konvi config tool that we're aware of. Correct if changes.
	if ( main::check_program('kde4-config') ){
		$config_tool = 'kde4-config';
	}
	elsif ( main::check_program('kde5-config') ){
		$config_tool = 'kde5-config';
	}
	elsif ( main::check_program('kde-config') ){
		$config_tool = 'kde-config';
	}
	# The section below is on request of Argonel from the Konversation developer team:
	# it sources config files like $HOME/.kde/share/apps/konversation/scripts/inxi.conf
	if ($config_tool){
		my @data = main::grabber("$config_tool --path data 2>/dev/null",':');
		main::get_configs(@data);
	}
	eval $end if $b_log;
}
}

########################################################################
#### OUTPUT
########################################################################

#### -------------------------------------------------------------------
#### FILTERS AND TOOLS
#### -------------------------------------------------------------------

sub apply_filter {
	my ($string) = @_;
	if ($string){
		$string = ( $use{'filter'} ) ? $filter_string : $string;
	}
	else {
		$string = 'N/A';
	}
	return $string;
}
# note, let the print logic handle N/A cases
sub apply_partition_filter {
	my ($source,$string,$type) = @_;
	return $string if !$string || $string eq 'N/A';
	if ($source eq 'system') {
		my $test = ($type eq 'label') ? '=LABEL=': '=UUID=';
		$string =~ s/$test[^\s]+/$test$filter_string/g;
	}
	else {
		$string = $filter_string;
	}
	return $string;
}
sub arm_cleaner {
	my ($item) = @_;
	$item =~ s/(\([^\(]*Device Tree[^\)]*\))//gi;
	$item =~ s/\s\s+/ /g;
	$item =~ s/^\s+|\s+$//g;
	return $item;
}

sub clean_characters {
	my ($data) = @_;
	# newline, pipe, brackets, + sign, with space, then clear doubled
	# spaces and then strip out trailing/leading spaces.
	# etc/issue often has junk stuff like (\l)  \n \l
	return if ! $data;
	$data =~ s/[:\47]|\\[a-z]|\n|,|\"|\*|\||\+|\[\s\]|n\/a|\s\s+/ /g; 
	$data =~ s/\(\s*\)//;
	$data =~ s/^\s+|\s+$//g;
	return $data;
}

sub cleaner {
	my ($item) = @_;
	return $item if !$item;# handle cases where it was 0 or ''
	# note: |nee trips engineering, but I don't know why nee was filtered
	$item =~ s/chipset|company|components|computing|computer|corporation|communications|electronics|electrical|electric|gmbh|group|incorporation|industrial|international|\bnee\b|revision|semiconductor|software|technologies|technology|ltd\.|<ltd>|\bltd\b|inc\.|<inc>|\binc\b|intl\.|co\.|<co>|corp\.|<corp>|\(tm\)|\(r\)|®|\(rev ..\)|\'|\"|\sinc\s*$|\?//gi;
	$item =~ s/,|\*/ /g;
	$item =~ s/\s\s+/ /g;
	$item =~ s/^\s+|\s+$//g;
	return $item;
}

sub disk_cleaner {
	my ($item) = @_;
	return $item if !$item;
	# <?unknown>?|
	$item =~ s/vendor.*|product.*|O\.?E\.?M\.?//gi;
	$item =~ s/\s\s+/ /g;
	$item =~ s/^\s+|\s+$//g;
	return $item;
}

sub dmi_cleaner {
	my ($string) = @_;
	my $cleaner = '^Base Board .*|^Chassis .*|empty|Undefined.*|.*O\.E\.M\..*|.*OEM.*|^Not .*';
	$cleaner .= '|^System .*|.*unknow.*|.*N\/A.*|none|^To be filled.*|^0x[0]+$';
	$cleaner .= '|\[Empty\]|<Bad Index>|<OUT OF SPEC>|Default string|^\.\.$|Manufacturer.*';
	$cleaner .= '|AssetTagNum|Manufacturer| Or Motherboard|PartNum.*|\bOther\b.*|SerNum';
	$string =~ s/$cleaner//i;
	$string =~ s/^\s+|\bbios\b|\bacpi\b|\s+$//gi;
	$string =~ s/http:\/\/www.abit.com.tw\//Abit/i;
	$string =~ s/\s\s+/ /g;
	$string =~ s/^\s+|\s+$//g;
	$string = remove_duplicates($string) if $string;
	return $string;
}

# args: $1 - size in KB, return KB, MB, GB, TB, PB, EB
sub get_size {
	my ($size,$b_int) = @_;
	my (@data);
	return ('','') if ! defined $size;
	if (!is_numeric($size)){
		$data[0] = $size;
		$data[1] = '';
	}
	elsif ($size > 1024**5){
		$data[0] = sprintf("%.2f",$size/1024**5);
		$data[1] = 'EiB';
	}
	elsif ($size > 1024**4){
		$data[0] = sprintf("%.2f",$size/1024**4);
		$data[1] = 'PiB';
	}
	elsif ($size > 1024**3){
		$data[0] = sprintf("%.2f",$size/1024**3);
		$data[1] = 'TiB';
	}
	elsif ($size > 1024**2){
		$data[0] = sprintf("%.2f",$size/1024**2);
		$data[1] = 'GiB';
	}
	elsif ($size > 1024){
		$data[0] = sprintf("%.1f",$size/1024);
		$data[1] = 'MiB';
	}
	else {
		$data[0] = sprintf("%.0f",$size);
		$data[1] = 'KiB';
	}
	$data[0] = int($data[0]) if $b_int && $data[0];
	return @data;
}

# not used, but keeping logic for now
sub increment_starters {
	my ($key,$indexes) = @_;
	my $result = $key;
	if (defined $$indexes{$key} ){
		$$indexes{$key}++;
		$result = "$key-$$indexes{$key}";
	}
	return $result;
}

sub pci_cleaner {
	my ($string,$type) = @_;
	#print "st1 $type:$string\n";
	my $filter = 'and\ssubsidiaries|compatible\scontroller|';
	$filter .= '\b(device|controller|connection|multimedia)\b|\([^)]+\)';
	# \[[^\]]+\]$| not trimming off ending [...] initial type filters removes end
	$filter = '\[[^\]]+\]$|' . $filter if $type eq 'pci';
	$string =~ s/($filter)//ig;
	$string =~ s/\s\s+/ /g;
	$string =~ s/^\s+|\s+$//g;
	#print "st2 $type:$string\n";
	$string = remove_duplicates($string) if $string;
	return $string;
}
sub pci_cleaner_subsystem {
	my ($string) = @_;
	# we only need filters for features that might use vendor, -AGN
	my $filter = 'and\ssubsidiaries|adapter|(hd\s)?audio|definition|desktop|ethernet|';
	$filter .= 'gigabit|graphics|hdmi(\/[\S]+)?|high|integrated|motherboard|network|onboard|';
	$filter .= 'raid|pci\s?express';
	$string =~ s/\b($filter)\b//ig;
	$string =~ s/\s\s+/ /g;
	$string =~ s/^\s+|\s+$//g;
	return $string;
}

sub pci_long_filter {
	my ($string) = @_;
	if ($string =~ /\[AMD(\/ATI)?\]/){
		$string =~ s/Advanced\sMicro\sDevices\s\[AMD(\/ATI)?\]/AMD/;
	}
	return $string;
}

# Use sparingly, but when we need regex type stuff 
# stripped out for reliable string compares, it's better.
# sometimes the pattern comes from unknown strings 
# which can contain regex characters, get rid of those
sub regex_cleaner {
	my ($string) = @_;
	return if ! $string;
	$string =~ s/(\{|\}|\(|\)|\[|\]|\|)/ /g;
	$string =~ s/\s\s+/ /g;
	$string =~ s/^\s+|\s+$//g;
	return $string;
}

sub remove_duplicates {
	my ($string) = @_;
	return if ! $string;
	my $holder = '';
	my (@temp);
	my @data = split /\s+/, $string;
	foreach (@data){
		if ($holder ne $_){
			push @temp, $_;
		}
		$holder = $_;
	}
	$string = join ' ', @temp;
	return $string;
}

sub row_defaults {
	my ($type,$id) = @_;
	$id ||= '';
	my %unfound = (
	'arm-cpu-f' => 'Use -f option to see features',
	'arm-pci' => 'No ARM data found for this feature.',
	'battery-data' => 'No system Battery data found. Is one present?',
	'battery-data-sys' => 'No /sys data found.',
	'cpu-bugs-null' => 'No CPU vulnerability/bugs data available.',
	'cpu-model-null' => 'Model N/A',
	'cpu-speeds' => "No speed data found for $id cores.",
	'darwin-feature' => 'Feature not supported iu Darwin/OSX.',
	'disk-data' => 'No Disk data was found.',
	'disk-data-bsd' => 'No Disk data found for this BSD system.',
	'disk-size-0' => 'Total N/A',
	'display-console' => 'No advanced graphics data found on this system in console.',
	'display-driver-na' => 'display driver n/a',
	'display-null' => 'No advanced graphics data found on this system.',
	'display-root' => 'Advanced graphics data unavailable in console for root.',
	'display-root-x' => 'Advanced graphics data unavailable for root.',
	'display-server' => 'No display server data found. Headless machine?',
	'glxinfo-missing' => 'Unable to show advanced data. Required tool glxinfo missing.',
	'gl-empty' => 'Unset. Missing GL driver?',
	'display-try' => 'Advanced graphics data unavailable in console. Try -G --display',
	'dev' => 'Feature under development',
	'dmesg-boot-permissions' => 'dmesg.boot permissions',
	'dmesg-boot-missing' => 'dmesg.boot not found',
	'IP' => "No $id found. Connected to web? SSL issues?",
	'dmidecode-dev-mem' => 'dmidecode is not allowed to read /dev/mem',
	'dmidecode-smbios' => 'No SMBIOS data for dmidecode to process',
	'IP-dig' => "No $id found. Connected to web? SSL issues? Try --no-dig",
	'IP-no-dig' => "No $id found. Connected to web? SSL issues? Try enabling dig",
	'machine-data' => 'No Machine data: try newer kernel.',
	'machine-data-bsd' => 'No Machine data: Is dmidecode installed? Try -M --dmidecode.',
	'machine-data-dmidecode' => 'No Machine data: try newer kernel. Is dmidecode installed? Try -M --dmidecode.',
	'machine-data-force-dmidecode' => 'No Machine data: try newer kernel. Is dmidecode installed? Try -M --dmidecode.',
	'mips-pci' => 'No MIPS data found for this feature.',
	'optical-data' => 'No Optical or Floppy data was found.',
	'optical-data-bsd' => 'No Optical or Floppy data found for this BSD system.',
	'output-limit' => "Output throttled. IPs: $id; Limit: $limit; Override: --limit [1-x;-1 all]",
	'packages' => 'No packages detected. Unsupported package manager?',
	'partition-data' => 'No Partition data was found.',
	'partition-hidden' => 'N/A (hidden?)',
	'pci-advanced-data' => 'bus/chip ids unavailable',
	'pci-card-data' => 'No Device data found.',
	'pci-card-data-root' => 'Device data requires root.',
	'pci-slot-data' => 'No PCI Slot data found.',
	'ps-data-null' => 'No Process data available.',
	'raid-data' => 'No RAID data was found.',
	'ram-data' => 'No RAM data was found.',
	'root-required' => '<superuser/root required>',
	'root-suggested' => 'try sudo/root',
	'sensors-data-ipmi' => 'No ipmi sensors data was found.',
	'sensors-data-linux' => 'No sensors data was found. Is sensors configured?',
	'sensors-ipmi-root' => 'Unable to run ipmi sensors. Root privileges required.',
	'smartctl-command-failed' => 'A mandatory SMART command failed. Various possible causes.',
	'smartctl-udma-crc' => 'Bad cable/connection?',
	'smartctl-usb' => 'Unknown USB bridge. Flash drive/Unsupported enclosure?',
	'swap-admin' => 'No admin Swap data available.',
	'swap-data' => 'No Swap data was found.',
	'tool-missing-basic' => "<missing: $id>",
	'tool-missing-incomplete' => "Missing system tool: $id. Output will be incomplete",
	'tool-missing-os' => "No OS support. Is a comparable $id tool available?",
	'tool-missing-recommends' => "Required tool $id not installed. Check --recommends",
	'tool-missing-required' => "Required program $id not available",
	'tool-permissions' => "Unable to run $id. Root privileges required.",
	'tool-present' => 'Present and working',
	'tool-unknown-error' => "Unknown $id error. Unable to generate data.",
	'unmounted-data' => 'No Unmounted partitions found.',
	'unmounted-data-bsd' => 'No Unmounted partition data found for this BSD system.',
	'unmounted-file' => 'No /proc/partitions file found.',
	'usb-data' => 'No USB data was found. Server?',
	'unknown-desktop-version' => 'ERR-101',
	'unknown-dev' => 'ERR-102',
	'unknown-shell' => 'ERR-100',
	'weather-error' => "Error: $id",
	'weather-null' => "No $id found. Internet connection working?",
	);
	return $unfound{$type};
}

# convert string passed to KB, based on GB/MB/TB id
# NOTE: K 1024 KB 1000
sub translate_size {
	my ($working) = @_;
	my $size = 0;
	#print ":$working:\n";
	return if ! defined $working;
	my $math = ( $working =~ /B$/) ? 1000: 1024;
	if ( $working =~ /^([0-9\.]+)\s*M[B]?$/i){
		$size = $1 * $math;
	}
	elsif ( $working =~ /^([0-9\.]+)\s*G[B]?$/i){
		$size = $1 * $math**2;
	}
	elsif ( $working =~ /^([0-9\.]+)\s*T[B]?$/i){
		$size = $1 * $math**3;
	}
	elsif ( $working =~ /^([0-9\.]+)\s*P[B]?$/i){
		$size = $1 * $math**4;
	}
	elsif ( $working =~ /^([0-9\.]+)\s*E[B]?$/i){
		$size = $1 * $math**5;
	}
	elsif ( $working =~ /^([0-9\.]+)\s*[kK][B]?$/i){
		$size = $1;
	}
	$size = int($size) if $size;
	return $size;
}

#### -------------------------------------------------------------------
#### GENERATE OUTPUT
#### -------------------------------------------------------------------

sub check_output_path {
	my ($path) = @_;
	my ($b_good,$dir,$file);
	$dir = $path;
	$dir =~ s/([^\/]+)$//;
	$file = $1;
	# print "file: $file : dir: $dir\n";
	$b_good = 1 if (-d $dir && -w $dir && $dir =~ /^\// && $file);
	return $b_good;
}

sub output_handler {
	my (%data) = @_;
	# print Dumper \%data;
	if ($output_type eq 'screen'){
		print_data(%data);
	}
	elsif ($output_type eq 'json'){
		generate_json(%data);
	}
	elsif ($output_type eq 'xml'){
		generate_xml(%data);
	}
}

# NOTE: file has already been set and directory verified
sub generate_json {
	eval $start if $b_log;
	my (%data) = @_;
	my ($json);
	my $b_debug = 1;
	my ($b_cpanel,$b_valid);
	error_handler('not-in-irc', 'help') if $b_irc;
	#print Dumper \%data if $b_debug;
	if (check_module('Cpanel::JSON::XS')){
		Cpanel::JSON::XS->import;
		$json = Cpanel::JSON::XS::encode_json(\%data);
	}
	elsif (check_module('JSON::XS')){
		JSON::XS->import;
		$json = JSON::XS::encode_json(\%data);
	}
	else {
		error_handler('required-module', 'json', 'Cpanel::JSON::XS OR JSON::XS');
	}
	if ($json){
		#$json =~ s/"[0-9]+#/"/g;
		if ($output_file eq 'print'){
			#$json =~ s/\}/}\n/g;
			print "$json";
		}
		else {
			print_line("Writing JSON data to: $output_file\n");
			open(my $fh, '>', $output_file) or error_handler('open',$output_file,"$!");
			print $fh "$json";
			close $fh;
			print_line("Data written successfully.\n");
		}
	}
	eval $end if $b_log;
}

# NOTE: So far xml is substantially more difficult than json, so 
# using a crude dumper rather than making a nice xml file, but at
# least xml has some output now.
sub generate_xml {
	eval $start if $b_log;
	my (%data) = @_;
	my ($xml);
	my $b_debug = 0;
	error_handler('not-in-irc', 'help') if $b_irc;
	#print Dumper \%data if $b_debug;
	if (check_module('XML::Dumper')){
		XML::Dumper->import;
		$xml = XML::Dumper::pl2xml(\%data);
		#$xml =~ s/"[0-9]+#/"/g;
		if ($output_file eq 'print'){
			print "$xml";
		}
		else {
			print_line("Writing XML data to: $output_file\n");
			open(my $fh, '>', $output_file) or error_handler('open',$output_file,"$!");
			print $fh "$xml";
			close $fh;
			print_line("Data written successfully.\n");
		}
	}
	else {
		error_handler('required-module', 'xml', 'XML::Dumper');
	}
	eval $end if $b_log;
}

sub key {
	return sprintf("%03d#%s#%s#%s", $_[0],$_[1],$_[2],$_[3]);
}

sub print_basic {
	my (@data) = @_;
	my $indent = 18;
	my $indent_static = 18;
	my $indent1_static = 5;
	my $indent2_static = 8;
	my $indent1 = 5;
	my $indent2 = 8;
	my $length =  @data;
	my ($start,$aref,$i,$j,$line);
	
	if ( $size{'max'} > 110 ){
		$indent_static = 22;
	}
	elsif ($size{'max'} < 90 ){
		$indent_static = 15;
	}
	# print $length . "\n";
	for my $i (0 .. $#data){
		$aref = $data[$i];
		#print "0: $data[$i][0]\n";
		if ($data[$i][0] == 0 ){
			$indent = 0;
			$indent1 = 0;
			$indent2 = 0;
		}
		elsif ($data[$i][0] == 1 ){
			$indent = $indent_static;
			$indent1 = $indent1_static;
			$indent2= $indent2_static;
		}
		elsif ($data[$i][0] == 2 ){
			$indent = ( $indent_static + 7 );
			$indent1 = ( $indent_static + 5 );
			$indent2 = 0;
		}
		$data[$i][3] =~ s/\n/ /g;
		$data[$i][3] =~ s/\s+/ /g;
		if ($data[$i][1] && $data[$i][2]){
			$data[$i][1] = $data[$i][1] . ', ';
		}
		$start = sprintf("%${indent1}s%-${indent2}s",$data[$i][1],$data[$i][2]);
		if ($indent > 1 && ( length($start) > ( $indent - 1) ) ){
			$line = sprintf("%-${indent}s\n", "$start");
			print_line($line);
			$start = '';
			#print "1-print.\n";
		}
		if ( ( $indent + length($data[$i][3]) ) < $size{'max'} ){
			$data[$i][3] =~ s/\^/ /g;
			$line = sprintf("%-${indent}s%s\n", "$start", $data[$i][3]);
			print_line($line);
			#print "2-print.\n";
		}
		else {
			my $holder = '';
			my $sep = ' ';
			foreach my $word (split / /, $data[$i][3]){
				#print "$word\n";
				if ( ( $indent + length($holder) + length($word) ) < $size{'max'} ) {
					$word =~ s/\^/ /g;
					$holder .= $word . $sep;
					#print "3-hold.\n";
				}
				#elsif ( ( $indent + length($holder) + length($word) ) >= $size{'max'}){
				else {
					$line = sprintf("%-${indent}s%s\n", "$start", $holder);
					print_line($line);
					$start = '';
					$word =~ s/\^/ /g;
					$holder = $word . $sep;
					#print "4-print-hold.\n";
				}
			}
			if ($holder !~ /^[ ]*$/){
				$line = sprintf("%-${indent}s%s\n", "$start", $holder);
				print_line($line);
				#print "5-print-last.\n";
			}
		}
	}
}

# this has to get a hash of hashes, at least for now.
# because perl does not retain insertion order, I use a prefix for each
# hash key to force sorts. 
sub print_data {
	my (%data) = @_;
	my ($array,$counter,$length,$split_count) = (0,0,0,0);
	my ($hash_id,$holder,$start,$start2,$start_holder) = ('','','','','');
	my $indent = $size{'indent'};
	my (@temp,@working,@values,%ids,%row);
	my ($holder2,$key,$line,$val2,$val3);
	# these 2 sets are single logic items
	my $b_single = ($size{'max'} == 1) ? 1: 0;
	my ($b_container,$indent_use,$indentx) = (0,0,0);
	# $size{'max'} = 88;
	# NOTE: indent < 11 would break the output badly in some cases
	if ($size{'max'} < $size{'indent-min'} || $size{'indent'} < 11 ){
		$indent = 2;
	}
	#foreach my $key1 (sort { (split/#/, $a)[0] <=> (split/#/, $b)[0] } keys %data) {
	foreach my $key1 (sort { substr($a,0,3) <=> substr($b,0,3) } keys %data) {
	#foreach my $key1 (sort { $a cmp $b } keys %data) {
		$key = (split/#/, $key1)[3];
		if ($key ne 'SHORT' ) {
			$start = sprintf("$colors{'c1'}%-${indent}s$colors{'cn'}","$key$sep{'s1'}");
			$start_holder = $key;
			if ($indent < 10){
				$line = "$start\n";
				print_line($line);
				$start = '';
				$line = '';
			}
		}
		else {
			$indent = 0;
		}
		next if ref($data{$key1}) ne 'ARRAY';
		# @working = @{$data{$key1}};
		# Line starters that will be -x incremented always
		# It's a tiny bit faster manually resetting rather than using for loop
		%ids = (
		'Array' => 1, # RAM or RAID
		'Battery' => 1,
		'Card' => 1,
		'Device' => 1,
		'Floppy' => 1,
		'Hardware' => 1, # hardware raid report
		'ID' => 1,
		'IF-ID' => 1,
		'Monitor' => 1,
		'Optical' => 1,
		'Screen' => 1,
		'variant' => 1, # arm > 1 cpu type
		);
		foreach my $val1 (@{$data{$key1}}){
			$indent_use = $length = $indent;
			if (ref($val1) eq 'HASH'){
				#%row = %$val1;
				($counter,$split_count) = (0,0);
				#foreach my $key2 (sort { (split/#/, $a)[0] <=> (split/#/, $b)[0] } keys %$val1){
				foreach my $key2 (sort { substr($a,0,3) <=> substr($b,0,3) } keys %$val1){
				#foreach my $key2 (sort { $a cmp $b } keys %$val1){
					($hash_id,$b_container,$indentx,$key) = (split/#/, $key2);
					if ($start_holder eq 'Graphics' && $key eq 'Screen'){
						$ids{'Monitor'} = 1;
					}
					elsif ($start_holder eq 'Memory' && $key eq 'Array'){
						$ids{'Device'} = 1;
					}
					elsif ($start_holder eq 'RAID' && $key eq 'Device'){
						$ids{'Array'} = 1;
					}
					elsif ($start_holder eq 'USB' && $key eq 'Hub'){
						$ids{'Device'} = 1;
					}
					if ($counter == 0 && defined $ids{$key}){
						$key .= '-' . $ids{$key}++;
					}
					$val2 = $$val1{$key2};
					# we have to handle cases where $val2 is 0
					if (!$b_single && $val2 || $val2 eq '0'){
						$val2 .= " ";
					}
					# see: Use of implicit split to @_ is deprecated. Only get this warning
					# in Perl 5.08 oddly enough.
					@temp = split/\s+/, $val2;
					$split_count = scalar @temp;
					if ( !$b_single && ( length( "$key$sep{'s2'} $val2" ) + $length ) < $size{'max'} ) {
						#print "one\n";
						$length += length("$key$sep{'s2'} $val2");
						$holder .= "$colors{'c1'}$key$sep{'s2'}$colors{'c2'} $val2";
					}
					# handle case where the opening key/value pair is > max, and where 
					# there are a lot of terms, like cpu flags, raid types supported. Raid
					# can have the last row have a lot of devices, or many raid types
					elsif ( !$b_single && ( length( "$key$sep{'s2'} $val2" ) + $indent ) > $size{'max'} && 
								!defined $ids{$key} && $split_count > 2 ) {
						#print "two\n";
						@values = split/\s+/, $val2;
						$val3 = shift @values;
						# $length += length("$key$sep{'s2'} $val3 ") + $indent;
						$start2 = "$colors{'c1'}$key$sep{'s2'}$colors{'c2'} $val3 ";
						$holder2 = '';
						$length += length("$key$sep{'s2'} $val3 ");
						# print scalar @values,"\n";
						foreach (@values){
							# my $l =  (length("$_ ") + $length);
							#print "$l\n";
							if ( (length("$_ ") + $length) < $size{'max'} ){
								#print "three.1\n";
								#print "a\n";
								if ($start2){
									$holder2 .= "$start2$_ ";
									$start2 = '';
									#$length += $length2;
									#$length2 = 0;
								}
								else {
									$holder2 .= "$_ ";
								}
								$length += length("$_ ");
							}
							else {
								#print "three.2\n";
								if ($start2){
									$holder2 = "$start2$holder2";
								}
								else {
									$holder2 = "$colors{'c2'}$holder2";
								}
								#print "xx:$holder";
								$line = sprintf("%-${indent}s%s$colors{'cn'}\n","$start","$holder$holder2");
								print_line($line);
								$holder = '';
								$holder2 = "$_ ";
								#print "h2: $holder2\n";
								$length = length($holder2) + $indent;
								$start2 = '';
								$start = '';
								#$length2 = 0;
							}
						}
						if ($holder2 !~ /^\s*$/){
							#print "four\n";
							$holder2 = "$colors{'c2'}$holder2";
							$line = sprintf("%-${indent}s%s$colors{'cn'}\n","$start","$holder$holder2");
							print_line($line);
							$holder = '';
							$holder2 = '';
							$length = $indent;
							$start2 = '';
							$start = '';
							#$length2 = 0;
						}
					}
					# NOTE: only these and the last fallback are used for b_single output
					else {
						#print "H: $counter " . scalar %$val1 . " $indent3 $indent2\n";
						if ($holder){
							#print "five\n";
							$line = sprintf("%-${indent_use}s%s$colors{'cn'}\n",$start,"$holder");
							$length = length("$key$sep{'s2'} $val2") + $indent_use;
							print_line($line);
							$start = '';
						}
						else {
							#print "six\n";
							$length = $indent_use;
							#$holder = '';
						}
						$holder = "$colors{'c1'}$key$sep{'s2'}$colors{'c2'} $val2";
					}
					$counter++;
					$indent_use = ($indent * $indentx) if $b_single;
				}
				if ($holder !~ /^\s*$/){
					#print "seven\n";
					$line = sprintf("%-${indent_use}s%s$colors{'cn'}\n",$start,"$start2$holder");
					print_line($line);
					$holder = '';
					$length = 0;
					$start = '';
				}
			}
			# only for repos currently
			elsif (ref($val1) eq 'ARRAY'){
				#print "eight\n";
				$array=0;
				foreach my $item (@$val1){
					$array++;
					$indent_use = ($b_single) ? $indent + 2: $indent;
					$line = "$colors{'c1'}$array$sep{'s2'} $colors{'c2'}$item$colors{'cn'}";
					$line = sprintf("%-${indent_use}s%s\n","","$line");
					print_line($line);
				}
			}
		}
		# we want a space between data blocks for single
		print_line("\n") if $b_single;
	}
}

sub print_line {
	my ($line) = @_;
	if ($b_irc && $client{'test-konvi'}){
		$client{'konvi'} = 3;
		$client{'dobject'} = 'Konversation';
	}
	if ($client{'konvi'} == 1 && $client{'dcop'} ){
		# konvi doesn't seem to like \n characters, it just prints them literally
		$line =~ s/\n//g;
		#qx('dcop "$client{'dport'}" "$client{'dobject'}" say "$client{'dserver'}" "$client{'dtarget'}" "$line 1");
		system('dcop', $client{'dport'}, $client{'dobject'}, 'say', $client{'dserver'}, $client{'dtarget'}, "$line 1");
	}
	elsif ($client{'konvi'} == 3 && $client{'qdbus'} ){
		# print $line;
		$line =~ s/\n//g;
		#qx(qdbus org.kde.konversation /irc say "$client{'dserver'}" "$client{'dtarget'}" "$line");
		system('qdbus', 'org.kde.konversation', '/irc', 'say', $client{'dserver'}, $client{'dtarget'}, $line);
	}
	else {
		print $line;
	}
}

########################################################################
#### DATA PROCESSORS
########################################################################

#### -------------------------------------------------------------------
#### PRIMARY DATA GENERATORS
#### -------------------------------------------------------------------

## AudioData 
{
package AudioData;

sub get {
	eval $start if $b_log;
	my (@data,@rows);
	my $num = 0;
	if (($b_arm || $b_mips) && !$b_soc_audio && !$b_pci_tool){
		my $type = ($b_arm) ? 'arm' : 'mips';
		my $key = 'Message';
		@data = ({
		main::key($num++,0,1,$key) => main::row_defaults($type . '-pci',''),
		},);
		@rows = (@rows,@data);
	}
	else {
		@data = card_data();
		@rows = (@rows,@data);
	}
	if ( ( (($b_arm || $b_mips) && !$b_soc_audio && !$b_pci_tool) || !@rows ) && 
	   (my $file = main::system_files('asound-cards') ) ){
		@data = asound_data($file);
		@rows = (@rows,@data);
	}
	@data = usb_data();
	@rows = (@rows,@data);
	if (!@rows){
		my $key = 'Message';
		my $type = 'pci-card-data';
		if ($pci_tool && ${$alerts{$pci_tool}}{'action'} eq 'permissions'){
			$type = 'pci-card-data-root';
		}
		@data = ({
		main::key($num++,0,1,$key) => main::row_defaults($type,''),
		},);
		@rows = (@rows,@data);
	}
	@data = sound_server_data();
	@rows = (@rows,@data);
	eval $end if $b_log;
	return @rows;
}

sub card_data {
	eval $start if $b_log;
	my (@rows,@data);
	my ($j,$num) = (0,1);
	foreach (@devices_audio){
		$num = 1;
		my @row = @$_;
		$j = scalar @rows;
		my $driver = $row[9];
		$driver ||= 'N/A';
		my $card = $row[4];
		$card = ($card) ? main::pci_cleaner($card,'output') : 'N/A';
		# have seen absurdly verbose card descriptions, with non related data etc
		if (length($card) > 85 || $size{'max'} < 110){
			$card = main::pci_long_filter($card);
		}
		@data = ({
		main::key($num++,1,1,'Device') => $card,
		},);
		@rows = (@rows,@data);
		if ($extra > 0 && $b_pci_tool && $row[12]){
			my $item = main::get_pci_vendor($row[4],$row[12]);
			$rows[$j]{main::key($num++,0,2,'vendor')} = $item if $item;
		}
		$rows[$j]{main::key($num++,1,2,'driver')} = $driver;
		if ($extra > 0 && !$bsd_type){
			if ($row[9] ){
				my $version = main::get_module_version($row[9]);
				$rows[$j]{main::key($num++,0,3,'v')} = $version if $version;
			}
		}
		if ($b_admin && $row[10]){
			$row[10] = main::get_driver_modules($row[9],$row[10]);
			$rows[$j]{main::key($num++,0,3,'alternate')} = $row[10] if $row[10];
		}
		if ($extra > 0){
			$rows[$j]{main::key($num++,0,2,'bus ID')} = (!$row[2] && !$row[3]) ? 'N/A' : "$row[2].$row[3]";
		}
		if ($extra > 1){
			my $chip_id = 'N/A';
			if ($row[5] && $row[6]){
				$chip_id = "$row[5]:$row[6]";
			}
			elsif ($row[6]){
				$chip_id = $row[6];
			}
			$rows[$j]{main::key($num++,0,2,'chip ID')} = $chip_id;
		}
		#print "$row[0]\n";
	}
	#my $ref = $pci[-1];
	#print $$ref[0],"\n";
	eval $end if $b_log;
	return @rows;
}
# this handles fringe cases where there is no card on pcibus,
# but there is a card present. I don't know the exact architecture
# involved but I know this situation exists on at least one old machine.
sub asound_data {
	eval $start if $b_log;
	my ($file) = @_;
	my (@asound,@rows,@data);
	my ($card,$driver,$j,$num) = ('','',0,1);
	@asound = main::reader($file);
	foreach (@asound){
		# filtering out modems and usb devices like webcams, this might get a
		# usb audio card as well, this will take some trial and error
		if ( !/modem|usb/i && /^\s*[0-9]/ ) {
			$num = 1;
			my @working = split /:\s*/, $_;
			# now let's get 1 2
			$working[1] =~ /(.*)\s+-\s+(.*)/;
			$card = $2;
			$driver = $1;
			if ( $card ){
				$j = scalar @rows;
				$driver ||= 'N/A';
				@data = ({
				main::key($num++,1,1,'Device') => $card,
				main::key($num++,1,2,'driver') => $driver,
				},);
				@rows = (@rows,@data);
				if ($extra > 0){
					my $version = main::get_module_version($driver);
					$rows[$j]{main::key($num++,0,3,'v')} = $version if $version;
					$rows[$j]{main::key($num++,0,2,'message')} = main::row_defaults('pci-advanced-data','');
				}
			}
		}
	}
	# print Data::Dumper:Dumper \s@rows;
	eval $end if $b_log;
	return @rows;
}
sub usb_data {
	eval $start if $b_log;
	my (@rows,@data,@ids,$driver,$path_id,$product,@temp2);
	my ($j,$num) = (0,1);
	if (-d '/proc/asound') {
		# note: this will double the data, but it's easier this way.
		# inxi tested for -L in the /proc/asound files, and used only those.
		my @files = main::globber('/proc/asound/*/usbid');
		foreach (@files){
			my $id = (main::reader($_))[0];
			push @ids, $id if ($id && ! grep {/$id/} @ids);
		}
		# lsusb is a very expensive operation
		if (@ids){
			if (!$bsd_type && !$b_usb_check){
				main::USBData::set();
			}
		}
		main::log_data('dump','@ids',\@ids) if $b_log;
		return if !@usb;
		foreach my $id (@ids){
			$j = scalar @rows;
			foreach my $ref (@usb){
				my @row = @$ref;
				# a device will always be the second or > device on the bus
				if ($row[1] > 1 && $row[7] eq $id){
					$num = 1;
					# makre sure to reset, or second device trips last flag
					($driver,$path_id,$product) = ('','','');
					$product = main::cleaner($row[13]) if $row[13];
					$driver = $row[15] if $row[15];
					$path_id = $row[2] if $row[2];
					$product ||= 'N/A';
					$driver ||= 'snd-usb-audio';
					@data = ({
					main::key($num++,1,1,'Device') => $product,
					main::key($num++,0,2,'type') => 'USB',
					main::key($num++,0,2,'driver') => $driver,
					},);
					@rows = (@rows,@data);
					if ($extra > 0){
						$rows[$j]{main::key($num++,0,2,'bus ID')} = "$path_id:$row[1]";
					}
					if ($extra > 1){
						$row[7] ||= 'N/A';
						$rows[$j]{main::key($num++,0,2,'chip ID')} = $row[7];
					}
					if ($extra > 2 && $row[16]){
						$rows[$j]{main::key($num++,0,2,'serial')} = main::apply_filter($row[16]);
					}
				}
			}
		}
	}
	eval $end if $b_log;
	return @rows;
}

sub sound_server_data {
	eval $start if $b_log;
	my (@data,$server,$version);
	my $num = 0;
	if (my $file = main::system_files('asound-version') ){
		my $content = (main::reader($file))[0];
		# some alsa strings have the build date in (...)
		# remove trailing . and remove possible second line if compiled by user
# 		foreach (@content){
# 			if (!/compile/i){
				#$_ =~ s/Advanced Linux Sound Architecture/ALSA/;
				$version = (split /\s+/, $content)[-1];
				$version =~ s/\.$//; # trim off period
				$server = 'ALSA';
# 			}
# 		}
	}
	elsif (my $program = main::check_program('oss')){
		$server = 'OSS';
		$version = main::program_version('oss','\S',2);
		$version ||= 'N/A';
	}
	if ($server){
		@data = ({
		main::key($num++,1,1,'Sound Server') => $server,
		main::key($num++,0,2,'v') => $version,
		},);
	}
	eval $end if $b_log;
	return @data;
}
}

## BatteryData
{
package BatteryData;
my (@upower_items,$b_upower,$upower);
sub get {
	eval $start if $b_log;
	my (@rows,%battery,$key1,$val1);
	my $num = 0;
	if ($bsd_type || $b_dmidecode_force){
		my $ref = $alerts{'dmidecode'};
		if ( $$ref{'action'} ne 'use'){
			$key1 = $$ref{'action'};
			$val1 = $$ref{$key1};
			$key1 = ucfirst($key1);
			@rows = ({main::key($num++,0,1,$key1) => $val1,});
		}
		else {
			%battery = battery_data_dmi();
			if (!%battery){
				if ($show{'battery-forced'}){
					$key1 = 'Message';
					$val1 = main::row_defaults('battery-data','');
					@rows = ({main::key($num++,0,1,$key1) => $val1,});
				}
			}
			else {
				@rows = create_output(%battery);
			}
		}
	}
	elsif (-d '/sys/class/power_supply/'){
		%battery = battery_data_sys();
		if (!%battery){
			if ($show{'battery-forced'}){
				$key1 = 'Message';
				$val1 = main::row_defaults('battery-data','');
				@rows = ({main::key($num++,0,1,$key1) => $val1,});
			}
		}
		else {
			@rows = create_output(%battery);
		}
	}
	else {
		if ($show{'battery-forced'}){
			$key1 = 'Message';
			$val1 = main::row_defaults('battery-data-sys','');
			@rows = ({main::key($num++,0,1,$key1) => $val1,});
		}
	}
	(@upower_items,$b_upower,$upower) = undef;
	eval $end if $b_log;
	return @rows;
}
# alarm capacity capacity_level charge_full charge_full_design charge_now 
# 	cycle_count energy_full energy_full_design energy_now location manufacturer model_name 
# 	power_now present serial_number status technology type voltage_min_design voltage_now
# 0  name - battery id, not used
# 1  status
# 2  present
# 3  technology
# 4  cycle_count
# 5  voltage_min_design
# 6  voltage_now
# 7  power_now
# 8  energy_full_design
# 9  energy_full
# 10 energy_now
# 11 capacity
# 12 capacity_level
# 13 of_orig
# 14 model_name
# 15 manufacturer
# 16 serial_number
# 17 location
sub create_output {
	eval $start if $b_log;
	my (%battery) = @_;
	my ($key,@data,@rows);
	my $num = 0;
	my $j = 0;
	# print Data::Dumper::Dumper \%battery;
	foreach $key (sort keys %battery){
		$num = 0;
		my ($charge,$condition,$model,$serial,$status,$volts) = ('','','','','','');
		my ($chemistry,$cycles,$location) = ('','','');
		next if !$battery{$key}{'purpose'} || $battery{$key}{'purpose'} ne 'primary';
		# $battery{$key}{''};
		# we need to handle cases where charge or energy full is 0
		if (defined $battery{$key}{'energy_now'} && $battery{$key}{'energy_now'} ne ''){
			$charge = "$battery{$key}{'energy_now'} Wh";
		}
		# better than nothing, shows the charged percent
		elsif (defined $battery{$key}{'capacity'} && $battery{$key}{'capacity'} ne ''){
			$charge = $battery{$key}{'capacity'} . '%'
		}
		else {
			$charge = 'N/A';
		}
		if ($battery{$key}{'energy_full'} || $battery{$key}{'energy_full_design'}){
			$battery{$key}{'energy_full_design'} ||= 'N/A';
			$battery{$key}{'energy_full'}= (defined $battery{$key}{'energy_full'} && $battery{$key}{'energy_full'} ne '') ? $battery{$key}{'energy_full'} : 'N/A';
			$condition = "$battery{$key}{'energy_full'}/$battery{$key}{'energy_full_design'} Wh";
			if ($battery{$key}{'of_orig'}){
				$condition .= " ($battery{$key}{'of_orig'}%)"; 
			}
		}
		$condition ||= 'N/A';
		$j = scalar @rows;
		@data = ({
		main::key($num++,1,1,'ID') => $key,
		main::key($num++,0,2,'charge') => $charge,
		main::key($num++,0,2,'condition') => $condition,
		},);
		@rows = (@rows,@data);
		if ($extra > 0){
			if ($extra > 1){
				if ($battery{$key}{'voltage_min_design'} || $battery{$key}{'voltage_now'}){
					$battery{$key}{'voltage_min_design'} ||= 'N/A';
					$battery{$key}{'voltage_now'} ||= 'N/A';
					$volts = "$battery{$key}{'voltage_now'}/$battery{$key}{'voltage_min_design'}";
				}
				$volts ||= 'N/A';
				$rows[$j]{main::key($num++,0,2,'volts')} = $volts;
			}
			if ($battery{$key}{'manufacturer'} || $battery{$key}{'model_name'}) {
				if ($battery{$key}{'manufacturer'} && $battery{$key}{'model_name'}){
					$model = "$battery{$key}{'manufacturer'} $battery{$key}{'model_name'}";
				}
				elsif ($battery{$key}{'manufacturer'}){
					$model = $battery{$key}{'manufacturer'};
				}
				elsif ($battery{$key}{'model_name'}){
					$model = $battery{$key}{'model_name'};
				}
			}
			else {
				$model = 'N/A';
			}
			$rows[$j]{main::key($num++,0,2,'model')} = $model;
			if ($extra > 2){
				$chemistry = ( $battery{$key}{'technology'} ) ? $battery{$key}{'technology'}: 'N/A';
				$rows[$j]{main::key($num++,0,2,'type')} = $chemistry;
			}
			if ($extra > 1){
				$serial = main::apply_filter($battery{$key}{'serial_number'});
				$rows[$j]{main::key($num++,0,2,'serial')} = $serial;
			}
			$status = ($battery{$key}{'status'}) ? $battery{$key}{'status'}: 'N/A';
			$rows[$j]{main::key($num++,0,2,'status')} = $status;
			if ($extra > 2){
				if ($battery{$key}{'cycle_count'}){
					$rows[$j]{main::key($num++,0,2,'cycles')} = $battery{$key}{'cycle_count'};
				}
				if ($battery{$key}{'location'}){
					$rows[$j]{main::key($num++,0,2,'location')} = $battery{$key}{'location'};
				}
			}
		}
		$battery{$key} = undef;
	}
	# print Data::Dumper::Dumper \%battery;
	# now if there are any devices left, print them out, excluding Mains
	if ($extra > 0){
		$upower = main::check_program('upower');
		foreach $key (sort keys %battery){
			$num = 0;
			next if !defined $battery{$key} || $battery{$key}{'purpose'} eq 'mains';
			my ($charge,$model,$serial,$percent,$status,$vendor) = ('','','','','','');
			my (%upower_data);
			$j = scalar @rows;
			%upower_data = upower_data($key) if $upower;
			if ($upower_data{'percent'}){
				$charge = $upower_data{'percent'};
			}
			elsif ($battery{$key}{'capacity_level'} && lc($battery{$key}{'capacity_level'}) ne 'unknown'){
				$charge = $battery{$key}{'capacity_level'};
			}
			else {
				$charge = 'N/A';
			}
			$model = $battery{$key}{'model_name'} if $battery{$key}{'model_name'};
			$status = ($battery{$key}{'status'} && lc($battery{$key}{'status'}) ne 'unknown') ? $battery{$key}{'status'}: 'N/A' ;
			$vendor = $battery{$key}{'manufacturer'} if $battery{$key}{'manufacturer'};
			if ($vendor || $model){
				if ($vendor && $model){
					$model = "$vendor $model";
				}
				elsif ($vendor){
					$model = $vendor;
				}
			}
			else {
				$model = 'N/A';
			}
			@data = ({
			main::key($num++,1,1,'Device') => $key,
			main::key($num++,0,2,'model') => $model,
			},);
			@rows = (@rows,@data);
			if ($extra > 1){
				$serial = main::apply_filter($battery{$key}{'serial_number'});
				$rows[$j]{main::key($num++,0,2,'serial')} = $serial;
			}
			$rows[$j]{main::key($num++,0,2,'charge')} = $charge;
			if ($extra > 2 && $upower_data{'rechargeable'}){
				$rows[$j]{main::key($num++,0,2,'rechargeable')} = $upower_data{'rechargeable'};
			}
			$rows[$j]{main::key($num++,0,2,'status')} = $status;
		}
	}
	eval $end if $b_log;
	return @rows;
}

# charge: mAh energy: Wh
sub battery_data_sys {
	eval $start if $b_log;
	my ($b_ma,%battery,$file,$id,$item,$path,$value);
	my $num = 0;
	my @batteries = main::globber("/sys/class/power_supply/*");
	# note: there is no 'location' file, but dmidecode has it
	# 'type' is generic, like: Battery, Mains
	# capacity_level is a string, like: Normal
	my @items = qw(alarm capacity capacity_level charge_full charge_full_design charge_now 
	constant_charge_current constant_charge_current_max cycle_count 
	energy_full energy_full_design energy_now location manufacturer model_name 
	power_now present scope serial_number status technology type voltage_min_design voltage_now);
	foreach $item (@batteries){
		$b_ma = 0;
		$id = $item;
		$id =~ s%/sys/class/power_supply/%%g;
		$battery{$id} = ({});
		foreach $file (@items){
			$path = "$item/$file";
			# android shows some files only root readable
			$value = (-r $path) ? (main::reader($path))[0]: '';
			# mains, plus in psu
			if ($file eq 'type' && $value && lc($value) ne 'battery' ){
				$battery{$id}{'purpose'} = 'mains';
			}
			if ($value){
				$value = main::trimmer($value);
				if ($file eq 'voltage_min_design'){
					$value = sprintf("%.1f", $value/1000000);
				}
				elsif ($file eq 'voltage_now'){
					$value = sprintf("%.1f", $value/1000000);
				}
				elsif ($file eq 'energy_full_design'){
					$value = $value/1000000;
				}
				elsif ($file eq 'energy_full'){
					$value = $value/1000000;
				}
				elsif ($file eq 'energy_now'){
					$value = sprintf("%.1f", $value/1000000);
				}
				# note: the following 3 were off, 100000 instead of 1000000
				# why this is, I do not know. I did not document any reason for that
				# so going on assumption it is a mistake. 
				# CHARGE is mAh, which are converted to Wh by: mAh x voltage. 
				# Note: voltage fluctuates so will make results vary slightly.
				elsif ($file eq 'charge_full_design'){
					$value = $value/1000000;
					$b_ma = 1;
				}
				elsif ($file eq 'charge_full'){
					$value = $value/1000000;
					$b_ma = 1;
				}
				elsif ($file eq 'charge_now'){
					$value = $value/1000000;
					$b_ma = 1;
				}
				elsif ($file eq 'manufacturer'){
					$value = main::dmi_cleaner($value);
				}
				elsif ($file eq 'model_name'){
					$value = main::dmi_cleaner($value);
				}
			}
			elsif ($b_root && -e $path && ! -r $path ){
				$value = main::row_defaults('root-required');
			}
			$battery{$id}{$file} = $value;
			# print "$battery{$id}{$file}\n";
		}
		# note, too few data sets, there could be sbs-charger but not sure
		if (!$battery{$id}{'purpose'}){
			# NOTE: known ids: BAT[0-9] CMB[0-9]. arm may be like: sbs- sbm- but just check 
			# if the energy/charge values exist for this item, if so, it's a battery, if not, 
			# it's a device.
			if ($id =~ /^(BAT|CMB).*$/i || 
			    ( $battery{$id}{'energy_full'} || $battery{$id}{'charge_full'} || 
			    $battery{$id}{'energy_now'} || $battery{$id}{'charge_now'} || 
			    $battery{$id}{'energy_full_design'} || $battery{$id}{'charge_full_design'} ) || 
			    $battery{$id}{'voltage_min_design'} || $battery{$id}{'voltage_now'} ){
				$battery{$id}{'purpose'} =  'primary';
			}
			else {
				$battery{$id}{'purpose'} =  'device';
			}
		}
		# note:voltage_now fluctuates, which will make capacity numbers change a bit
		# if any of these values failed, the math will be wrong, but no way to fix that
		# tests show more systems give right capacity/charge with voltage_min_design 
		# than with voltage_now
		if ($b_ma && $battery{$id}{'voltage_min_design'}){
			if ($battery{$id}{'charge_now'}){
				$battery{$id}{'energy_now'} = $battery{$id}{'charge_now'} * $battery{$id}{'voltage_min_design'};
			}
			if ($battery{$id}{'charge_full'}){
				$battery{$id}{'energy_full'} = $battery{$id}{'charge_full'}*$battery{$id}{'voltage_min_design'};
			}
			if ($battery{$id}{'charge_full_design'}){
				$battery{$id}{'energy_full_design'} = $battery{$id}{'charge_full_design'} * $battery{$id}{'voltage_min_design'};
			}
		}
		if ( $battery{$id}{'energy_now'} && $battery{$id}{'energy_full'} ){
			$battery{$id}{'capacity'} = 100 * $battery{$id}{'energy_now'}/$battery{$id}{'energy_full'};
			$battery{$id}{'capacity'} = sprintf( "%.1f", $battery{$id}{'capacity'} );
		}
		if ( $battery{$id}{'energy_full_design'} && $battery{$id}{'energy_full'} ){
			$battery{$id}{'of_orig'} = 100 * $battery{$id}{'energy_full'}/$battery{$id}{'energy_full_design'};
			$battery{$id}{'of_orig'} = sprintf( "%.0f", $battery{$id}{'of_orig'} );
		}
		if ( $battery{$id}{'energy_now'} ){
			$battery{$id}{'energy_now'} = sprintf( "%.1f", $battery{$id}{'energy_now'} );
		}
		if ( $battery{$id}{'energy_full_design'} ){
			$battery{$id}{'energy_full_design'} = sprintf( "%.1f",$battery{$id}{'energy_full_design'} );
		}
		if ( $battery{$id}{'energy_full'} ){
			$battery{$id}{'energy_full'} = sprintf( "%.1f", $battery{$id}{'energy_full'} );
		}
	}
	main::log_data('dump','sys: %battery',\%battery) if $b_log;
	eval $end if $b_log;
	return %battery;
}
# note, dmidecode does not have charge_now or charge_full
sub battery_data_dmi {
	eval $start if $b_log;
	my (%battery,$id);
	my $i = 0;
	foreach (@dmi){
		my @ref = @$_;
		# Portable Battery
		if ($ref[0] == 22){
			$id = "BAT$i";
			$i++;
			$battery{$id} = ({});
			$battery{$id}{'purpose'} = 'primary';
			# skip first three row, we don't need that data
			splice @ref, 0, 3 if @ref;
			foreach my $item (@ref){
				my @value = split /:\s+/, $item;
				next if !$value[0];
				if ($value[0] eq 'Location') {$battery{$id}{'location'} = $value[1] }
				elsif ($value[0] eq 'Manufacturer') {$battery{$id}{'manufacturer'} = main::dmi_cleaner($value[1]) }
				elsif ($value[0] =~ /Chemistry/) {$battery{$id}{'technology'} = $value[1] }
				elsif ($value[0] =~ /Serial Number/) {$battery{$id}{'serial_number'} = $value[1] }
				elsif ($value[0] =~ /^Name/) {$battery{$id}{'model_name'} = main::dmi_cleaner($value[1]) }
				elsif ($value[0] eq 'Design Capacity') {
					$value[1] =~ s/\s*mwh$//i;
					$battery{$id}{'energy_full_design'} = sprintf( "%.1f", $value[1]/1000);
				}
				elsif ($value[0] eq 'Design Voltage') {
					$value[1] =~ s/\s*mv$//i;
					$battery{$id}{'voltage_min_design'} = sprintf( "%.1f", $value[1]/1000);
				}
			}
			if ($battery{$id}{'energy_now'} && $battery{$id}{'energy_full'} ){
				$battery{$id}{'capacity'} = 100 * $battery{$id}{'energy_now'} / $battery{$id}{'energy_full'};
				$battery{$id}{'capacity'} = sprintf( "%.1f%", $battery{$id}{'capacity'} );
			}
			if ($battery{$id}{'energy_full_design'} && $battery{$id}{'energy_full'} ){
				$battery{$id}{'of_orig'} = 100 * $battery{$id}{'energy_full'} / $battery{$id}{'energy_full_design'};
				$battery{$id}{'of_orig'} = sprintf( "%.0f%", $battery{$id}{'of_orig'} );
			}
		}
		elsif ($ref[0] > 22){
			last;
		}
	}
	# print Data::Dumper::Dumper \%battery;
	main::log_data('dump','dmi: %battery',\%battery) if $b_log;
	eval $end if $b_log;
	return %battery;
}
sub upower_data {
	my ($id) = @_;
	eval $start if $b_log;
	my (%data);
	if (!$b_upower && $upower){
		@upower_items = main::grabber("$upower -e",'','strip');
		$b_upower = 1;
	}
	if ($upower && @upower_items){
		foreach (@upower_items){
			if ($_ =~ /$id/){
				my @working = main::grabber("$upower -i $_",'','strip');
				foreach my $row (@working){
					my @temp = split /\s*:\s*/, $row;
					if ($temp[0] eq 'percentage'){
						$data{'percent'} = $temp[1];
					}
					elsif ($temp[0] eq 'rechargeable'){
						$data{'rechargeable'} = $temp[1];
					}
				}
				last;
			}
		}
	}
	main::log_data('dump','upower: %data',\%data) if $b_log;
	eval $end if $b_log;
	return %data;
}

}

## CpuData
{
package CpuData;

sub get {
	eval $start if $b_log;
	my ($type) = @_;
	my (@data,@rows,$single,$key1,$val1);
	my $num = 0;
	if ($type eq 'short' || $type eq 'basic'){
		@rows = data_short($type);
	}
	else {
		@rows = create_output_full();
	}
	eval $end if $b_log;
	return @rows;
}
sub create_output_full {
	eval $start if $b_log;
	my $num = 0;
	my ($b_flags,$b_speeds,$core_speeds_value,$flag_key,@flags,%cpu,@data,@rows);
	my $sleep = $cpu_sleep * 1000000;
	if ($b_hires){
		eval 'Time::HiRes::usleep( $sleep )';
	}
	else {
		select(undef, undef, undef, $cpu_sleep);
	}
	if (my $file = main::system_files('cpuinfo')){
		%cpu = data_cpuinfo($file,'full');
	}
	elsif ($bsd_type ){
		my ($key1,$val1) = ('','');
		if ( $alerts{'sysctl'} ){
			if ( $alerts{'sysctl'}{'action'} eq 'use' ){
# 				$key1 = 'Status';
# 				$val1 = main::row_defaults('dev');
				%cpu = data_sysctl('full');
			}
			else {
				$key1 = ucfirst($alerts{'sysctl'}{'action'});
				$val1 = $alerts{'sysctl'}{$alerts{'sysctl'}{'action'}};
				@data = ({main::key($num++,0,1,$key1) => $val1,});
				return @data;
			}
		}
	}
	my %properties = cpu_properties(%cpu);
	my $type = ($properties{'cpu-type'}) ? $properties{'cpu-type'}: '';
	my $ref = $cpu{'processors'};
	my @processors = @$ref;
	my @speeds = cpu_speeds(@processors);
	my $j = scalar @rows;
	$cpu{'model_name'} ||= 'N/A'; 
	@data = ({
	main::key($num++,1,1,'Info') => $properties{'cpu-layout'},
	main::key($num++,0,2,'model') => $cpu{'model_name'},
	},);
	@rows = (@rows,@data);
	if ($cpu{'system-cpus'}){
		my $ref = $cpu{'system-cpus'};
		my %system_cpus = %$ref;
		my $i = 1;
		my $counter = ( %system_cpus && scalar keys %system_cpus > 1 ) ? '-' : '';
		foreach my $key (keys %system_cpus){
			$counter = '-' . $i++ if $counter;
			$rows[$j]{main::key($num++,0,2,'variant'.$counter)} = $key;
		}
	}
	if ($b_admin && $properties{'socket'}){
		if ($properties{'upgrade'}){
			$rows[$j]{main::key($num++,1,2,'socket')} = $properties{'socket'} . ' (' . $properties{'upgrade'} . ')';
			$rows[$j]{main::key($num++,0,3,'note')} = 'check';
		}
		else {
			$rows[$j]{main::key($num++,0,2,'socket')} = $properties{'socket'};
		}
	}
	$properties{'bits-sys'} ||= 'N/A';
	$rows[$j]{main::key($num++,0,2,'bits')} = $properties{'bits-sys'};
	if ($type){
		$rows[$j]{main::key($num++,0,2,'type')} = $type;
	}
	if ($extra > 0){
		$cpu{'arch'} ||= 'N/A';
		$rows[$j]{main::key($num++,0,2,'arch')} = $cpu{'arch'};
		if ( !$b_admin && $cpu{'arch'} ne 'N/A' && $cpu{'rev'} ){
			$rows[$j]{main::key($num++,0,2,'rev')} = $cpu{'rev'};
		}
	}
	if ($b_admin){
		$rows[$j]{main::key($num++,0,2,'family')} = hex_and_decimal($cpu{'family'});
		$rows[$j]{main::key($num++,0,2,'model-id')} = hex_and_decimal($cpu{'model_id'});
		$rows[$j]{main::key($num++,0,2,'stepping')} = hex_and_decimal($cpu{'rev'});
		$cpu{'microcode'} ||= 'N/A';
		$rows[$j]{main::key($num++,0,2,'microcode')} = $cpu{'microcode'};
	}
	if ($extra > 1 && $properties{'l1-cache'}){
		$rows[$j]{main::key($num++,0,2,'L1 cache')} = $properties{'l1-cache'};
	}
	$properties{'l2-cache'} ||= 'N/A';
	if (!$b_arm || ($b_arm && $properties{'l2-cache'} ne 'N/A')){
		$rows[$j]{main::key($num++,0,2,'L2 cache')} = $properties{'l2-cache'};
	}
	if ($extra > 1 && $properties{'l3-cache'}){
		$rows[$j]{main::key($num++,0,2,'L3 cache')} = $properties{'l3-cache'};
	}
	
	if ($extra > 0 && !$show{'cpu-flag'}){
		$j = scalar @rows;
		@flags = split /\s+/, $cpu{'flags'} if $cpu{'flags'};
		$flag_key = ($b_arm || $bsd_type) ? 'features': 'flags';
		my $flag = 'N/A';
		if (@flags){
			# failure to read dmesg.boot: dmesg.boot permissions; then short -Cx list flags
			@flags = grep {/^(dmesg.boot|permissions|avx[2-9]?|lm|nx|pae|pni|(sss|ss)e([2-9])?([a-z])?(_[0-9])?|svm|vmx)$/} @flags;
			@flags = map {s/pni/sse3/; $_} @flags;
			@flags = sort(@flags);
			$flag = join ' ', @flags if @flags;
		}
		if ($b_arm && $flag eq 'N/A'){
			$flag = main::row_defaults('arm-cpu-f');
		}
		@data = ({
		main::key($num++,0,2,$flag_key) => $flag,
		},);
		@rows = (@rows,@data);
		$b_flags = 1;
	}
	if ($extra > 0 && !$bsd_type){
		my $bogomips = (main::is_numeric($cpu{'bogomips'})) ? int($cpu{'bogomips'}) : 'N/A';
		$rows[$j]{main::key($num++,0,2,'bogomips')} = $bogomips;
	}
	$j = scalar @rows;
	my $core_key = (scalar @speeds > 1) ? 'Core speeds (MHz)' : 'Core speed (MHz)';
	my $speed_key = ($properties{'speed-key'}) ? $properties{'speed-key'}: 'Speed';
	my $min_max = ($properties{'min-max'}) ? $properties{'min-max'}: 'N/A';
	my $min_max_key = ($properties{'min-max-key'}) ? $properties{'min-max-key'}: 'min/max';
	my $speed = (defined $properties{'speed'}) ? $properties{'speed'}: 'N/A';
	# aren't able to get per core speeds in bsds yet
	if (@speeds){
		if (grep {$_ ne '0'} @speeds){
			$core_speeds_value = '';
			$b_speeds = 1;
		}
		else {
			$core_speeds_value = main::row_defaults('cpu-speeds',scalar @speeds);
		}
	}
	else {
		$core_speeds_value = 'N/A';
	}
	$j = scalar @rows;
	@data = ({
	main::key($num++,1,1,$speed_key) => $speed,
	main::key($num++,0,2,$min_max_key) => $min_max,
	});
	@rows = (@rows,@data);
	if ($b_admin && $properties{'dmi-speed'} && $properties{'dmi-max-speed'}){
		$rows[$j]{main::key($num++,0,2,'base/boost')} = $properties{'dmi-speed'} . '/' . $properties{'dmi-max-speed'};
	}
	if ($extra > 0){
		my $boost = get_boost_status();
		$rows[$j]{main::key($num++,0,2,'boost')} = $boost if $boost;
	}
	if ($extra > 2){
		if ($properties{'volts'}){
			$rows[$j]{main::key($num++,0,2,'volts')} = $properties{'volts'} . ' V';
		}
		if ($properties{'ext-clock'}){
			$rows[$j]{main::key($num++,0,2,'ext-clock')} = $properties{'ext-clock'};
		}
	}
	$rows[$j]{main::key($num++,1,2,$core_key)} = $core_speeds_value;
	my $i = 1;
	# if say 96 0 speed cores, no need to print all those 0s
	if ($b_speeds){
		foreach (@speeds){
			$rows[$j]{main::key($num++,0,3,$i++)} = $_;
		}
	}
	if ($show{'cpu-flag'} && !$b_flags){
		$flag_key = ($b_arm || $bsd_type) ? 'Features': 'Flags';
		@flags = split /\s+/, $cpu{'flags'} if $cpu{'flags'};
		my $flag = 'N/A';
		if (@flags){
			@flags = sort(@flags);
			$flag = join ' ', @flags if @flags;
		}
		@data = ({
		main::key($num++,0,1,$flag_key) => $flag,
		},);
		@rows = (@rows,@data);
	}
	if ($b_admin){
		my @bugs = cpu_bugs_sys();
		my $value = '';
		if (!@bugs){
			if ( $cpu{'bugs'}){
				my @proc_bugs = split /\s+/, $cpu{'bugs'};
				@proc_bugs = sort(@proc_bugs);
				$value = join ' ', @proc_bugs;
			}
			else {
				$value = main::row_defaults('cpu-bugs-null');
			}
		}
		@data = ({
		main::key($num++,1,1,'Vulnerabilities') => $value,
		},);
		@rows = (@rows,@data);
		if (@bugs){
			$j = $#rows;
			foreach my $ref (@bugs){
				my @bug = @$ref;
				$rows[$j]{main::key($num++,1,2,'Type')} = $bug[0];
				$rows[$j]{main::key($num++,0,3,$bug[1])} = $bug[2];
				$j++;
			}
		}
	}
	eval $end if $b_log;
	return @rows;
}
sub create_output_short {
	eval $start if $b_log;
	my (@cpu) = @_;
	my @data;
	my $num = 0;
	$cpu[1] ||= main::row_defaults('cpu-model-null');
	$cpu[2] ||= 'N/A';
	@data = ({
	main::key($num++,1,1,'Info') => $cpu[0] . ' ' . $cpu[1] . ' [' . $cpu[2] . ']',
	#main::key($num++,0,2,'type') => $cpu[2],
	},);
	if ($extra > 0){
		$data[0]{main::key($num++,0,2,'arch')} = $cpu[7];
	}
	$data[0]{main::key($num++,0,2,$cpu[3])} = $cpu[4];
	if ($cpu[6]){
		$data[0]{main::key($num++,0,2,$cpu[5])} = $cpu[6];
	}
	eval $end if $b_log;
	return @data;
}
sub data_short {
	eval $start if $b_log;
	my ($type) = @_;
	my $num = 0;
	my (%cpu,@data,%speeds);
	my $sys = '/sys/devices/system/cpu/cpufreq/policy0';
	my $sleep = $cpu_sleep * 1000000;
	if ($b_hires){
		eval 'Time::HiRes::usleep( $sleep )';
	}
	else {
		select(undef, undef, undef, $cpu_sleep);
	}
	# NOTE: : Permission denied, ie, this is not always readable
	# /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_cur_freq
	if (my $file = main::system_files('cpuinfo')){
		%cpu = data_cpuinfo($file,$type);
	}
	elsif ($bsd_type ){
		my ($key1,$val1) = ('','');
		if ( $alerts{'sysctl'} ){
			if ( $alerts{'sysctl'}{'action'} eq 'use' ){
# 				$key1 = 'Status';
# 				$val1 = main::row_defaults('dev');
				%cpu = data_sysctl($type);
			}
			else {
				$key1 = ucfirst($alerts{'sysctl'}{'action'});
				$val1 = $alerts{'sysctl'}{$alerts{'sysctl'}{'action'}};
				@data = ({main::key($num++,0,1,$key1) => $val1,});
				return @data;
			}
		}
	}
	# $cpu{'cur-freq'} = $cpu[0]{'core-id'}[0]{'speed'};
	if ($type eq 'short' || $type eq 'basic'){
		@data = prep_short_data(%cpu);
	}
	if ($type eq 'basic'){
		@data = create_output_short(@data);
	}
	eval $end if $b_log;
	return @data;
}

sub prep_short_data {
	eval $start if $b_log;
	my (%cpu) = @_;
	my %properties = cpu_properties(%cpu);
	my ($cpu,$speed_key,$speed,$type) = ('','speed',0,'');
	$cpu = $cpu{'model_name'} if $cpu{'model_name'};
 	$type = $properties{'cpu-type'} if $properties{'cpu-type'};
 	$speed_key = $properties{'speed-key'} if $properties{'speed-key'};
 	$speed = $properties{'speed'} if $properties{'speed'};
 	my @result = (
 	$properties{'cpu-layout'},
 	$cpu,
 	$type,
 	$speed_key,
 	$speed,
 	$properties{'min-max-key'},
 	$properties{'min-max'},
 	);
 	if ($extra > 0){
		$cpu{'arch'} ||= 'N/A';
		$result[7] = $cpu{'arch'};
 	}
	eval $end if $b_log;
	return @result;
}

sub data_cpuinfo {
	eval $start if $b_log;
	my ($file,$type)=  @_;
	my ($arch,@ids,@line,$b_first,$b_proc_int,$starter);
	# use --arm flag when testing arm cpus
	# $file = "$ENV{'HOME'}/bin/scripts/inxi/data/cpu/arm/arm-4-core-pinebook-1.txt";
	# $file = "$ENV{'HOME'}/bin/scripts/inxi/data/cpu/arm/armv6-single-core-1.txt";
	# $file = "$ENV{'HOME'}/bin/scripts/inxi/data/cpu/arm/armv7-dual-core-1.txt";
	# $file = "$ENV{'HOME'}/bin/scripts/inxi/data/cpu/arm/armv7-new-format-model-name-single-core.txt";
	# $file = "$ENV{'HOME'}/bin/scripts/inxi/data/cpu/arm/arm-2-die-96-core-rk01.txt";
	# $file = "$ENV{'HOME'}/bin/scripts/inxi/data/cpu/amd/16-core-32-mt-ryzen.txt";
	# $file = "$ENV{'HOME'}/bin/scripts/inxi/data/cpu/amd/2-16-core-epyc-abucodonosor.txt";
	# $file = "$ENV{'HOME'}/bin/scripts/inxi/data/cpu/amd/2-core-probook-antix.txt";
	# $file = "$ENV{'HOME'}/bin/scripts/inxi/data/cpu/amd/4-core-jean-antix.txt";
	# $file = "$ENV{'HOME'}/bin/scripts/inxi/data/cpu/amd/4-core-althlon-mjro.txt";
	# $file = "$ENV{'HOME'}/bin/scripts/inxi/data/cpu/amd/4-core-apu-vc-box.txt";
	# $file = "$ENV{'HOME'}/bin/scripts/inxi/data/cpu/amd/4-core-a10-5800k-1.txt";
	# $file = "$ENV{'HOME'}/bin/scripts/inxi/data/cpu/intel/2-core-ht-atom-bruh.txt";
	# $file = "$ENV{'HOME'}/bin/scripts/inxi/data/cpu/intel/core-2-i3.txt";
	# $file = "$ENV{'HOME'}/bin/scripts/inxi/data/cpu/intel/8-core-i7-damentz64.txt";
	# $file = "$ENV{'HOME'}/bin/scripts/inxi/data/cpu/intel/2-10-core-xeon-ht.txt";
	# $file = "$ENV{'HOME'}/bin/scripts/inxi/data/cpu/intel/4-core-xeon-fake-dual-die-zyanya.txt";
	# $file = "$ENV{'HOME'}/bin/scripts/inxi/data/cpu/intel/2-core-i5-fake-dual-die-hek.txt";
	# $file = "$ENV{'HOME'}/bin/scripts/inxi/data/cpu/intel/2-1-core-xeon-vm-vs2017.txt";
	# $file = "$ENV{'HOME'}/bin/scripts/inxi/data/cpu/intel/4-1-core-xeon-vps-frodo1.txt";
	# $file = "$ENV{'HOME'}/bin/scripts/inxi/data/cpu/intel/4-6-core-xeon-no-mt-lathander.txt";
	# $file = "$ENV{'HOME'}/bin/scripts/inxi/data/cpu/mips/mips-mainusg-cpuinfo.txt";
	# $file = "$ENV{'HOME'}/bin/scripts/inxi/data/cpu/ppc/ppc-debian-ppc64-cpuinfo.txt";
	# $file = "$ENV{'HOME'}/bin/scripts/inxi/data/cpu/elbrus/1xE1C-8.txt";
	# $file = "$ENV{'HOME'}/bin/scripts/inxi/data/cpu/elbrus/1xE2CDSP-4.txt";
	# $file = "$ENV{'HOME'}/bin/scripts/inxi/data/cpu/elbrus/1xE2S4-3-monocub.txt";
	# $file = "$ENV{'HOME'}/bin/scripts/inxi/data/cpu/elbrus/1xMBE8C-7.txt";
	# $file = "$ENV{'HOME'}/bin/scripts/inxi/data/cpu/elbrus/4xEL2S4-3.txt";
	# $file = "$ENV{'HOME'}/bin/scripts/inxi/data/cpu/elbrus/4xE8C-7.txt";
	# $file = "$ENV{'HOME'}/bin/scripts/inxi/data/cpu/elbrus/4xE2CDSP-4.txt";
	my %speeds = set_cpu_speeds_sys();
	my @cpuinfo = main::reader($file);
	my @phys_cpus = (0);# start with 1 always
	my ($core_count,$die_holder,$die_id,$phys_id,$proc_count,$speed) = (0,0,0,0,0,0,0);
	my ($phys_holder) = (undef);
	# need to prime for arm cpus, which do not have physical/core ids usually
	# level 0 is phys id, level 1 is die id, level 2 is core id
	#$ids[0] = ([(0)]);
	$ids[0] = ([]);
	$ids[0][0] = ([]);
	my %cpu =  set_cpu_data();
	$cpu{'type'} = cpu_vendor($cpu_arch) if $cpu_arch =~ /e2k/; # already set to lower
	#$cpu{'type'} = 'elbrus';
	# note, there con be a lot of processors, 32 core HT would have 64, for example.
	foreach (@cpuinfo){
		next if /^\s*$/;
		@line = split /\s*:\s*/, $_;
		next if !$line[0];
		$starter = $line[0]; # preserve case for one specific ARM issue
		$line[0] = lc($line[0]);
		if ($b_arm && !$b_first && $starter eq 'Processor' && $line[1] !~ /^\d+$/){
			#print "l1:$line[1]\n";
			$cpu{'model_name'} = main::cleaner($line[1]);
			$cpu{'model_name'} = cpu_cleaner($cpu{'model_name'});
			$cpu{'type'} = 'arm';
			# Processor   : AArch64 Processor rev 4 (aarch64)
			# Processor : Feroceon 88FR131 rev 1 (v5l)
			if ($cpu{'model_name'} && $cpu{'model_name'} =~ /(.*)\srev\s([\S]+)\s(\(([\S]+)\))?/){
				$cpu{'model_name'} = $1;
				$cpu{'rev'} = $2;
				if ($4){
					$cpu{'arch'} = $4;
					$cpu{'model_name'} .= ' ' . $cpu{'arch'} if $cpu{'model_name'} !~ /$cpu{'arch'}/i; 
				}
				$cpu{'processors'}[$proc_count] = 0;
				$b_proc_int = 0;
				$b_first = 1;
				#print "p0:\n";
			}
		}
		elsif ($line[0] eq 'processor'){
			# this protects against double processor lines, one int, one string
			if ($line[1] =~ /^\d+$/){
				$b_proc_int = 1;
				$b_first = 1;
				$cpu{'processors'}[$proc_count] = 0;
				$proc_count++;
				#print "p1: $proc_count\n";
			}
			else {
				if (!$b_proc_int){
					$cpu{'processors'}[$proc_count] = 0;
					$proc_count++;
					#print "p2a: $proc_count\n";
				}
				if (!$b_first ){
					# note: alternate: 
					# Processor	: AArch64 Processor rev 4 (aarch64)
					# but no model name type
					if ( $b_arm || $line[1] =~ /ARM|AArch/i){
						$b_arm = 1;
						$cpu{'type'} = 'arm';
					}
					$cpu{'model_name'} = main::cleaner($line[1]);
					$cpu{'model_name'} = cpu_cleaner($cpu{'model'});
					#print "p2b:\n";
				}
				$b_first = 1;
			}
		}
		elsif (!$cpu{'family'} && 
		       ($line[0] eq 'architecture' || $line[0] eq 'cpu family' || $line[0] eq 'cpu architecture' )){
			if ($line[1] =~ /^\d+$/){
				# translate integers to hex
				$cpu{'family'} = uc(sprintf("%x", $line[1]));
			}
			elsif ($b_arm) {
				$cpu{'arch'} = $line[1];
			}
		}
		elsif (!$cpu{'rev'} && ($line[0] eq 'stepping' || $line[0] eq 'cpu revision')){
			$cpu{'rev'} = uc(sprintf("%x", $line[1]));
		}
		# ppc
		elsif (!$cpu{'rev'} && $line[0] eq 'revision'){
			$cpu{'rev'} = $line[1];
		}
		# this is hex so uc for cpu arch id. raspi 4 has Model rather than Hard
		elsif (!$cpu{'model_id'} && (!$b_ppc && !$b_arm && $line[0] eq 'model') ){
			$cpu{'model_id'} = uc(sprintf("%x", $line[1]));
		}
		elsif (!$cpu{'model_id'} && $line[0] eq 'cpu variant' ){
			$cpu{'model_id'} = uc($line[1]);
			$cpu{'model_id'} =~ s/^0X//;
		}
		# cpu can show in arm
		elsif (!$cpu{'model_name'} && ( $line[0] eq 'model name' || $line[0] eq 'cpu' || $line[0] eq 'cpu model' )){
			$cpu{'model_name'} = main::cleaner($line[1]);
			$cpu{'model_name'} = cpu_cleaner($cpu{'model_name'});
			if ( $b_arm || $line[1] =~ /ARM|AArch/i){
				$b_arm = 1;
				$cpu{'type'} = 'arm';
				if ($cpu{'model_name'} && $cpu{'model_name'} =~ /(.*)\srev\s([\S]+)\s(\(([\S]+)\))?/){
					$cpu{'model_name'} = $1;
					$cpu{'rev'} = $2;
					if ($4){
						$cpu{'arch'} = $4;
						$cpu{'model_name'} .= ' ' . $cpu{'arch'} if $cpu{'model_name'} !~ /$cpu{'arch'}/i;
					}
					#$cpu{'processors'}[$proc_count] = 0;
				}
			}
			elsif ($b_mips || $line[1] =~ /mips/i){
				$b_mips = 1;
				$cpu{'type'} = 'mips';
			}
		}
		elsif ( $line[0] eq 'cpu mhz' || $line[0] eq 'clock' ){
			$speed = speed_cleaner($line[1]);
			$cpu{'processors'}[$proc_count-1] = $speed;
			#$ids[$phys_id][$die_id] = ([($speed)]);
		}
		elsif (!$cpu{'siblings'} && $line[0] eq 'siblings' ){
			$cpu{'siblings'} = $line[1];
		}
		elsif (!$cpu{'cores'} && $line[0] eq 'cpu cores' ){
			$cpu{'cores'} = $line[1];
		}
		# increment by 1 for every new physical id we see. These are in almost all cases
		# separate cpus, not separate dies within a single cpu body.
		elsif ( $line[0] eq 'physical id' ){
			if ( !defined $phys_holder || $phys_holder != $line[1] ){
				# only increment if not in array counter
				push @phys_cpus, $line[1] if ! grep {/$line[1]/} @phys_cpus;
				$phys_holder = $line[1];
				$ids[$phys_holder] = ([]) if ! exists $ids[$phys_holder];
				$ids[$phys_holder][$die_id] = ([]) if ! exists $ids[$phys_holder][$die_id];
				#print "pid: $line[1] ph: $phys_holder did: $die_id\n";
				$die_id = 0;
				#$die_holder = 0;
			}
		}
		elsif ( $line[0] eq 'core id' ){
			#print "ph: $phys_holder did: $die_id l1: $line[1] s: $speed\n";
			# https://www.pcworld.com/article/3214635/components-processors/ryzen-threadripper-review-we-test-amds-monster-cpu.html
			if ($line[1] > 0 ){
				$die_holder = $line[1];
				$core_count++;
			}
			# NOTE: this logic won't work for die detections, unforutnately.
			# ARM uses a different /sys based method, and ryzen relies on math on the cores
			# in process_data
			elsif ($line[1] == 0 && $die_holder > 0 ){
				$die_holder = $line[1];
				$core_count = 0;
				$die_id++ if ($cpu{'type'} ne 'intel' && $cpu{'type'} ne 'amd' );
			}
			$phys_holder = 0 if ! defined $phys_holder;
			$ids[$phys_holder][$die_id][$line[1]] = $speed;
			#print "ph: $phys_holder did: $die_id l1: $line[1] s: $speed\n";
		}
		if (!$cpu{'type'} && $line[0] eq 'vendor_id' ){
			$cpu{'type'} = cpu_vendor($line[1]);
		}
		## this is only for -C full cpu output
		if ( $type eq 'full' ){
			if (!$cpu{'l2-cache'} && ($line[0] eq 'cache size' || $line[0] eq 'l2 cache size' )){
				if ($line[1] =~ /(\d+)\sKB$/){
					$cpu{'l2-cache'} = $1;
				}
				elsif ($line[1] =~ /(\d+)\sMB$/){
					$cpu{'l2-cache'} = ($1*1024);
				}
			}
			elsif (!$cpu{'l1-cache'} && $line[0] eq 'l1 cache size'){
				if ($line[1] =~ /(\d+)\sKB$/){
					$cpu{'l1-cache'} = ($1);
				}
			}
			elsif (!$cpu{'l3-cache'} && $line[0] eq 'l3 cache size'){
				if ($line[1] =~ /(\d+)\sKB$/){
					$cpu{'l3-cache'} = $1;
				}
				elsif ($line[1] =~ /(\d+)\sMB$/){
					$cpu{'l3-cache'} = ($1*1024);
				}
			}
			if (!$cpu{'flags'} && ($line[0] eq 'flags' || $line[0] eq 'features' )){
				$cpu{'flags'} = $line[1];
			}
		}
		if ( $extra > 0 && $type eq 'full' ){
			if ($line[0] eq 'bogomips'){
				# new arm shows bad bogomip value, so don't use it
				$cpu{'bogomips'} += $line[1] if $line[1] > 50;
			}
		}
		if ($b_admin ){
			# note: not used unless maybe /sys data missing?
			if ( !$cpu{'bugs'} && $line[0] eq 'bugs'){
				$cpu{'bugs'} = $line[1];
			}
			# unlike family and model id, microcode appears to be hex already
			if ( !$cpu{'microcode'} && $line[0] eq 'microcode'){
				if ($line[1] =~ /0x/){
					$cpu{'microcode'} = uc($line[1]);
					$cpu{'microcode'} =~ s/^0X//;
				}
				else {
					$cpu{'microcode'} = uc(sprintf("%x", $line[1]));
				}
			}
		}
	}
	$cpu{'phys'} = scalar @phys_cpus;
	$cpu{'dies'} = $die_id++; # count starts at 0, all cpus have 1 die at least
	if ($b_arm || $b_mips){
		if ($cpu{'dies'} <= 1){
			my $arm_dies = cpu_dies_sys();
			# case were 4 core arm returned 4 sibling lists, obviously wrong
			$cpu{'dies'} = $arm_dies if $arm_dies && $proc_count != $arm_dies;
		}
		$cpu{'type'} = ($b_arm) ? 'arm' : 'mips' if !$cpu{'type'};
		if (!$bsd_type){
			my %system_cpus = system_cpu_name();
			$cpu{'system-cpus'} = \%system_cpus if %system_cpus;
		}
	}
	$cpu{'ids'} = (\@ids);
	if ( $extra > 0 && !$cpu{'arch'} && $type ne 'short' ){
		$cpu{'arch'} = cpu_arch($cpu{'type'},$cpu{'family'},$cpu{'model_id'},$cpu{'rev'});
		# cpu_arch comes from set_os()
		$cpu{'arch'} = $cpu_arch if (!$cpu{'arch'} && $cpu_arch && ($b_mips || $b_arm || $b_ppc));
		#print "$cpu{'type'},$cpu{'family'},$cpu{'model_id'},$cpu{'arch'}\n";
	}
	if (!$speeds{'cur-freq'}){
		$cpu{'cur-freq'} = $cpu{'processors'}[0];
		$speeds{'min-freq'} = 0;
		$speeds{'max-freq'} = 0;
	}
	else {
		$cpu{'cur-freq'} = $speeds{'cur-freq'};
		$cpu{'min-freq'} = $speeds{'min-freq'};
		$cpu{'max-freq'} = $speeds{'max-freq'};
	}
	main::log_data('dump','%cpu',\%cpu) if $b_log;
	print Data::Dumper::Dumper \%cpu if $test[8];
	eval $end if $b_log;
	return %cpu;
}

sub data_sysctl {
	eval $start if $b_log;
	my ($type) = @_;
	my %cpu = set_cpu_data();
	my (@ids,@line,%speeds,@working);
	my ($sep) = ('');
	my ($die_holder,$die_id,$phys_holder,$phys_id,$proc_count,$speed) = (0,0,0,0,0,0,0);
	foreach (@sysctl){
		@line = split /\s*:\s*/, $_;
		next if ! $line[0];
		# darwin shows machine, like MacBook7,1, not cpu
		# machdep.cpu.brand_string: Intel(R) Core(TM)2 Duo CPU     P8600  @ 2.40GHz
		if ( ($bsd_type ne 'darwin' && $line[0] eq 'hw.model' ) || $line[0] eq 'machdep.cpu.brand_string' ){
			# cut L2 cache/cpu max speed out of model string, if available
			# openbsd 5.6: AMD Sempron(tm) Processor 3400+ ("AuthenticAMD" 686-class, 256KB L2 cache)
			# freebsd 10: hw.model: AMD Athlon(tm) II X2 245 Processor
			$line[1] = main::cleaner($line[1]);
			$line[1] = cpu_cleaner($line[1]);
			if ( $line[1] =~ /([0-9]+)[-[:space:]]*([KM]B)\s+L2 cache/) {
				my $multiplier = ($2 eq 'MB') ? 1024: 1;
				$cpu{'l2-cache'} = $1 * $multiplier;
			}
			if ( $line[1] =~ /([^0-9\.][0-9\.]+)[-[:space:]]*[MG]Hz/) {
				$cpu{'max-freq'} = $1;
				if ($cpu{'max-freq'} =~ /MHz/i) {
					$cpu{'max-freq'} =~ s/[-[:space:]]*MHz//;
					$cpu{'max-freq'} = speed_cleaner($cpu{'max-freq'},'mhz');
				}
				elsif ($cpu{'max-freq'} =~ /GHz/) {
					$cpu{'max-freq'} =~ s/[-[:space:]]*GHz//i;
					$cpu{'max-freq'} = $cpu{'max-freq'} / 1000;
					$cpu{'max-freq'} = speed_cleaner($cpu{'max-freq'},'mhz');
				}
			}
			if ( $line[1] =~ /\)$/ ){
				$line[1] =~ s/\s*\(.*\)$//;
			}
			$cpu{'model_name'} = $line[1];
			$cpu{'type'} = cpu_vendor($line[1]);
		}
		# NOTE: hw.l1icachesize: hw.l1dcachesize:
		elsif ($line[0] eq 'hw.l1icachesize') {
			$cpu{'l1-cache'} = $line[1]/1024;
		}
		elsif ($line[0] eq 'hw.l2cachesize') {
			$cpu{'l2-cache'} = $line[1]/1024;
		}
		elsif ($line[0] eq 'hw.l3cachesize') {
			$cpu{'l3-cache'} = $line[1]/1024;
		}
		# this is in mghz in samples
		elsif ($line[0] eq 'hw.clockrate' || $line[0] eq 'hw.cpuspeed') {
			$cpu{'cur-freq'} = $line[1];
		}
		# these are in hz: 2400000000
		elsif ($line[0] eq 'hw.cpufrequency') {
			$cpu{'cur-freq'} = $line[1]/1000000;
		}
		elsif ($line[0] eq 'hw.busfrequency_min') {
			$cpu{'min-freq'} = $line[1]/1000000;
		}
		elsif ($line[0] eq 'hw.busfrequency_max') {
			$cpu{'max-freq'} = $line[1]/1000000;
		}
		elsif ($line[0] eq 'machdep.cpu.vendor') {
			$cpu{'type'} = cpu_vendor($line[1]);
		}
		# darwin only?
		elsif ($line[0] eq 'machdep.cpu.features') {
			$cpu{'flags'} = lc($line[1]);
		}
		elsif ($line[0] eq 'hw.ncpu' ) {
			$cpu{'cores'} = $line[1];
		}
		# Freebsd does some voltage hacking to actually run at lowest listed frequencies.
		# The cpu does not actually support all the speeds output here but works in freebsd. 
		elsif ($line[0] eq 'dev.cpu.0.freq_levels') {
			$line[1] =~ s/^\s+|\/[0-9]+|\s+$//g;
			if ( $line[1] =~ /[0-9]+\s+[0-9]+/ ) {
				my @temp = split /\s+/, $line[1];
				$cpu{'max-freq'} = $temp[0];
				$cpu{'min-freq'} = $temp[-1];
				$cpu{'scalings'} = \@temp;
			}
		}
		elsif (!$cpu{'cur-freq'} && $line[0] eq 'dev.cpu.0.freq' ) {
			$cpu{'cur-freq'} = $line[1];
		}
		# the following have only been seen in DragonflyBSD data but thumbs up!
		elsif ($line[0] eq 'hw.cpu_topology.members' ) {
			my @temp = split /\s+/, $line[1];
			my $count = scalar @temp;
			$count-- if $count > 0;
			$cpu{'processors'}[$count] = 0;
			# no way to get per processor speeds yet, so assign 0 to each
			foreach (0 .. $count){
				$cpu{'processors'}[$_] = 0;
			}
		}
		elsif ($line[0] eq 'hw.cpu_topology.cpu1.physical_siblings' ) {
			# string, like: cpu0 cpu1
			my @temp = split /\s+/, $line[1];
			$cpu{'siblings'} = scalar @temp;
		}
		# increment by 1 for every new physical id we see. These are in almost all cases
		# separate cpus, not separate dies within a single cpu body.
		elsif ( $line[0] eq 'hw.cpu_topology.cpu0.physical_id' ){
			if ($phys_holder != $line[1] ){
				$phys_id++;
				$phys_holder = $line[1];
				$ids[$phys_id] = ([(0)]);
				$ids[$phys_id][$die_id] = ([(0)]);
			}
		}
		elsif ( $line[0] eq 'hw.cpu_topology.cpu0.core_id' ){
			if ($line[1] > 0 ){
				$die_holder = $line[1];
			}
			# this handles multi die cpus like 16 core ryzen
			elsif ($line[1] == 0 && $die_holder > 0 ){
				$die_id++ ;
				$die_holder = $line[1];
			}
			$ids[$phys_id][$die_id][$line[1]] = $speed;
			$cpu{'dies'} = $die_id;
		}
	}
	if (!$cpu{'flags'}){
		$cpu{'flags'} = cpu_flags_bsd();
	}
	main::log_data('dump','%cpu',\%cpu) if $b_log;
	print Data::Dumper::Dumper \%cpu if $test[8];
	eval $end if $b_log;
	return %cpu;
}

sub cpu_properties {
	my (%cpu) = @_;
	my ($b_amd_zen,$b_epyc,$b_ht,$b_elbrus,$b_intel,$b_ryzen,$b_xeon);
	if ($cpu{'type'} ){
		if ($cpu{'type'} eq 'intel'){
			$b_intel = 1;
			$b_xeon = 1 if $cpu{'model_name'} =~ /Xeon/i;
		}
		elsif ($cpu{'type'} eq 'amd' ){
			if ( $cpu{'family'} && $cpu{'family'} eq '17' ) {
				$b_amd_zen = 1;
				if ($cpu{'model_name'} ){
					if ($cpu{'model_name'} =~ /Ryzen/i ){ 
						$b_ryzen = 1;
					}
					elsif ($cpu{'model_name'} =~ /EPYC/i){
						$b_epyc = 1;
					}
				}
			}
		}
		elsif ($cpu{'type'} eq 'elbrus') {
			$b_elbrus = 1;
		}
	}
	#my @dies = $phys[0][0];
	my $ref = $cpu{'ids'};
	my @phys = @$ref;
	my $phyical_count = 0;
	#my $phyical_count = scalar @phys;
	my @processors;
	my ($speed,$speed_key);
	# handle case where cpu reports say, phys id 0, 2, 4, 6 [yes, seen it]
	foreach (@phys) {
		$phyical_count++ if $_;
	}
	# count unique processors ##
	# note, this fails for intel cpus at times
	$ref = $cpu{'processors'};
	@processors = @$ref;
	#print ref $cpu{'processors'}, "\n";
	my $processors_count = scalar @processors;
	#print "p count:$processors_count\n";
	#print Data::Dumper::Dumper \@processors;
	# $cpu_cores is per physical cpu
	my ($cpu_layout,$cpu_type,$min_max,$min_max_key) = ('','','','');
	my ($dmi_max_speed,$dmi_speed,$ext_clock,$socket,$upgrade,$volts) = (undef);
	my ($l1_cache,$l2_cache,$l3_cache,$core_count,$cpu_cores,$die_count) = (0,0,0,0,0,0);
	# note: elbrus supports turning off cores, so we need to add one for cases where rounds to 0 or 1 less
	if ($b_elbrus && $processors_count){
		my @elbrus = elbrus_data($cpu{'model_id'},$processors_count,$cpu{'arch'});
		$cpu_cores = $elbrus[0];
		$phyical_count = $elbrus[1];
		$cpu{'arch'} = $elbrus[2];
		# print 'model id: ' . $cpu{'model_id'} . ' arch: ' . $cpu{'arch'} . " cpc: $cpu_cores phyc: $phyical_count proc: $processors_count \n";
	}
	$phyical_count ||= 1; # assume 1 if no id found, as with ARM
	if ($extra > 1){
		# note: dmidecode has one entry per cpu per cache type, so this already 
		# has done the arithmetic on > 1 cpus for L1 and L3. 
		my %cpu_dmi = cpu_dmi_data();
		$l1_cache = $cpu_dmi{'L1'} if $cpu_dmi{'L1'};
		$l3_cache = $cpu_dmi{'L3'} if $cpu_dmi{'L3'};
		# bsd sysctl can have these values so let's check just in case
		$l1_cache = $cpu{'l1-cache'} * $phyical_count if !$l1_cache && $cpu{'l1-cache'};
		$l3_cache = $cpu{'l3-cache'} * $phyical_count if !$l3_cache && $cpu{'l3-cache'};
		$dmi_max_speed = $cpu_dmi{'max-speed'} if $cpu_dmi{'max-speed'};
		$socket = $cpu_dmi{'socket'} if $cpu_dmi{'socket'};
		$upgrade = $cpu_dmi{'upgrade'} if $cpu_dmi{'upgrade'};
		$dmi_speed = $cpu_dmi{'speed'} if $cpu_dmi{'speed'};
		$ext_clock = $cpu_dmi{'ext-clock'} if $cpu_dmi{'ext-clock'};
		$volts = $cpu_dmi{'volts'} if $cpu_dmi{'volts'};
	}
	foreach my $die_ref ( @phys ){
		next if ! $die_ref;
		my @dies = @$die_ref;
		$core_count = 0;
		$die_count = scalar @dies;
		#$cpu{'dies'} = $die_count;
		foreach my $core_ref (@dies){
			next if ref $core_ref ne 'ARRAY';
			my @cores = @$core_ref;
			$core_count = 0;# reset for each die!!
			# NOTE: the counters can be undefined because the index comes from 
			# core id: which can be 0 skip 1 then 2, which leaves index 1 undefined
			# arm cpus do not actually show core id so ignore that counter
			foreach my $id (@cores){
				$core_count++ if defined $id && !$b_arm;
			}
			#print 'cores: ' . $core_count, "\n";
		}
	}
	
	# this covers potentially cases where ARM cpus have > 1 die 
	$cpu{'dies'} = ($b_arm && $die_count <= 1 && $cpu{'dies'} > 1) ? $cpu{'dies'}: $die_count;
	# this is an attempt to fix the amd family 15 bug with reported cores vs actual cores
	# NOTE: amd A6-4400M APU 2 core reports: cores: 1 siblings: 2
	# NOTE: AMD A10-5800K APU 4 core reports: cores: 2 siblings: 4
	if (!$cpu_cores){
		if ($cpu{'cores'} && ! $core_count || $cpu{'cores'} >= $core_count){
			$cpu_cores = $cpu{'cores'};
		}
		elsif ($core_count > $cpu{'cores'}){
			$cpu_cores = $core_count;
		}
	}
	#print "cpu-c:$cpu_cores\n";
	#$cpu_cores = $cpu{'cores'}; 
	# like, intel core duo
	# NOTE: sadly, not all core intel are HT/MT, oh well...
	# xeon may show wrong core / physical id count, if it does, fix it. A xeon
	# may show a repeated core id : 0 which gives a fake num_of_cores=1
	if ($b_intel){
		if ($cpu{'siblings'} && $cpu{'siblings'} > 1 && $cpu{'cores'} && $cpu{'cores'} > 1 ){
			if ( $cpu{'siblings'}/$cpu{'cores'} == 1 ){
				$b_intel = 0;
				$b_ht = 0;
			}
			else {
				$cpu_cores = ($cpu{'siblings'}/2); 
				$b_ht = 1;
			}
		}
	}
	# ryzen is made out of blocks of 8 core dies
	elsif ($b_ryzen){
		$cpu_cores = $cpu{'cores'}; 
		 # note: posix ceil isn't present in Perl for some reason, deprecated?
		my $working = $cpu_cores / 8;
		my @temp = split /\./, $working;
		$cpu{'dies'} = ($temp[1] && $temp[1] > 0) ? $temp[0]++ : $temp[0];
	}
	# these always have 4 dies
	elsif ($b_epyc) {
		$cpu_cores = $cpu{'cores'}; 
		$cpu{'dies'} = 4;
	}
# 	elsif ($b_elbrus){
# 		$cpu_cores = 
# 	}
	# final check, override the num of cores value if it clearly is wrong
	# and use the raw core count and synthesize the total instead of real count
	if ( $cpu_cores == 0 && ($cpu{'cores'} * $phyical_count > 1)){
		$cpu_cores = ($cpu{'cores'} * $phyical_count);
	}
	# last check, seeing some intel cpus and vms with intel cpus that do not show any
	# core id data at all, or siblings.
	if ($cpu_cores == 0 && $processors_count > 0){
		$cpu_cores = $processors_count;
	}
	# this happens with BSDs which have very little cpu data available
	if ( $processors_count == 0 && $cpu_cores > 0 ){
		$processors_count = $cpu_cores;
		if ($bsd_type && ($b_ht || $b_amd_zen) && $cpu_cores > 2 ){
			$cpu_cores = $cpu_cores/2;;
		}
		my $count = $processors_count;
		$count-- if $count > 0;
		$cpu{'processors'}[$count] = 0;
		# no way to get per processor speeds yet, so assign 0 to each
		# must be a numeric value. Could use raw speed from core 0, but 
		# that would just be a hack.
		foreach (0 .. $count){
			$cpu{'processors'}[$_] = 0;
		}
	}
	# last test to catch some corner cases 
	# seen a case where a xeon vm in a dual xeon system actually had 2 cores, no MT
	# so it reported 4 siblings, 2 cores, but actually only had 1 core per virtual cpu
	#print "prc: $processors_count phc: $phyical_count coc: $core_count cpc: $cpu_cores\n";
	if (!$b_arm && $processors_count == $phyical_count*$core_count && $cpu_cores > $core_count){
		$b_ht = 0;
		#$b_xeon = 0;
		$b_intel = 0;
		$cpu_cores = 1;
		$core_count = 1;
		$cpu{'siblings'} = 1;
	}
	#print "pc: $processors_count s: $cpu{'siblings'} cpuc: $cpu_cores corec: $core_count\n";
	# Algorithm:
	# if > 1 processor && processor id (physical id) == core id then Multi threaded (MT)
	# if siblings > 1 && siblings ==  2 * num_of_cores ($cpu{'cores'}) then Multi threaded (MT)
	# if > 1 processor && processor id (physical id) != core id then Multi-Core Processors (MCP)
	# if > 1 processor && processor ids (physical id) > 1 then Symmetric Multi Processing (SMP)
	# if = 1 processor then single core/processor Uni-Processor (UP)
	if ( $processors_count > 1 || ( $b_intel && $cpu{'siblings'} > 0 ) ) {
		# non-multicore MT
		if ($processors_count == ($phyical_count * $cpu_cores * 2)){
			#print "mt:1\n";
			$cpu_type .= 'MT'; 
		}
# 		elsif ($b_xeon && $cpu{'siblings'} > 1){
# 			#print "mt:2\n";
# 			$cpu_type .= 'MT'; 
# 		}
		elsif ($cpu{'siblings'} > 1 && ($cpu{'siblings'} == 2 * $cpu_cores )){
			#print "mt:3\n";
			$cpu_type .= 'MT'; 
		}
		# non-MT multi-core or MT multi-core
		if ( ($processors_count == $cpu_cores ) || ($phyical_count < $cpu_cores)){
			my $sep = ($cpu_type) ? ' ' : '' ;
			$cpu_type .= $sep . 'MCP'; 
		}
		# only solidly known > 1 die cpus will use this, ryzen and arm for now
		if ( $cpu{'dies'} > 1 ){
			my $sep = ($cpu_type) ? ' ' : '' ;
			$cpu_type .= $sep . 'MCM'; 
		}
		# >1 cpu sockets active: Symetric Multi Processing
		if ($phyical_count > 1){
			my $sep = ($cpu_type) ? ' ' : '' ;
			$cpu_type .= $sep . 'SMP'; 
		}
	}
	else {
		$cpu_type = 'UP';
	}
	if ($phyical_count > 1){
		$cpu_layout = $phyical_count . 'x ';
	}
	$cpu_layout .= count_alpha($cpu_cores) . 'Core';
	$cpu_layout .= ' (' . $cpu{'dies'}. '-Die)' if !$bsd_type && $cpu{'dies'} > 1;
	# the only possible change for bsds is if we can get phys counts in the future
	if ($bsd_type){
		$l2_cache = $cpu{'l2-cache'} * $phyical_count;
	}
	# AMD SOS chips appear to report full L2 cache per core
	elsif ($cpu{'type'} eq 'amd' && ($cpu{'family'} eq '14' || $cpu{'family'} eq '15' || $cpu{'family'} eq '16')){
		$l2_cache = $cpu{'l2-cache'} * $phyical_count;
	}
	elsif ($cpu{'type'} ne 'intel'){
		$l2_cache = $cpu{'l2-cache'} * $cpu_cores * $phyical_count;
	}
	## note: this handles how intel reports L2, total instead of per core like AMD does
	# note that we need to multiply by number of actual cpus here to get true cache size
	else {
		$l2_cache = $cpu{'l2-cache'} * $phyical_count;
	}
	if ($l1_cache > 0){
		$l1_cache = "$l1_cache KiB";
	}
	if ($l2_cache > 10000){
		$l2_cache = sprintf("%.01f MiB",$l2_cache/1024); # trim to no decimals?
	}
	elsif ($l2_cache > 0){
		$l2_cache = "$l2_cache KiB";
	}
	if ($l3_cache > 10000){
		$l3_cache = sprintf("%.01f MiB",$l3_cache/1024); # trim to no decimals?
	}
	elsif ($l3_cache > 0){
		$l3_cache = "$l3_cache KiB";
	}
	if ($cpu{'cur-freq'} && $cpu{'min-freq'} && $cpu{'max-freq'} ){
		$min_max = "$cpu{'min-freq'}/$cpu{'max-freq'} MHz";
		$min_max_key = "min/max";
		$speed_key = ($show{'short'} || $show{'cpu-basic'}) ? 'speed' : 'Speed';
		$speed = "$cpu{'cur-freq'} MHz";
 	}
 	elsif ($cpu{'cur-freq'} && $cpu{'max-freq'}){
		$min_max = "$cpu{'max-freq'} MHz";
		$min_max_key = "max";
		$speed_key = ($show{'short'} || $show{'cpu-basic'}) ? 'speed' : 'Speed';
		$speed = "$cpu{'cur-freq'} MHz";
 	}
#  	elsif ($cpu{'cur-freq'} && $cpu{'max-freq'} && $cpu{'cur-freq'} == $cpu{'max-freq'}){
# 		$speed_key = ($show{'short'} || $show{'cpu-basic'}) ? 'speed' : 'Speed';
# 		$speed = "$cpu{'cur-freq'} MHz (max)";
#  	}
 	elsif ($cpu{'cur-freq'} && $cpu{'min-freq'}){
		$min_max = "$cpu{'min-freq'} MHz";
		$min_max_key = "min";
		$speed_key = ($show{'short'} || $show{'cpu-basic'}) ? 'speed' : 'Speed';
		$speed = "$cpu{'cur-freq'} MHz";
 	}
 	elsif ($cpu{'cur-freq'} && !$cpu{'max-freq'}){
		$speed_key = ($show{'short'} || $show{'cpu-basic'}) ? 'speed' : 'Speed';
		$speed = "$cpu{'cur-freq'} MHz";
 	}
 	
 	if ( !$bits_sys && !$b_arm && $cpu{'flags'} ){
		$bits_sys = ($cpu{'flags'} =~ /\blm\b/) ? 64 : 32;
	}
	my %cpu_properties = (
	'bits-sys' => $bits_sys,
	'cpu-layout' => $cpu_layout,
	'cpu-type' => $cpu_type,
	'dmi-max-speed' => $dmi_max_speed,
	'dmi-speed' => $dmi_speed,
	'ext-clock' => $ext_clock,
	'min-max-key' => $min_max_key,
	'min-max' => $min_max,
	'socket' => $socket,
	'speed-key' => $speed_key,
	'speed' => $speed,
	'upgrade' => $upgrade,
	'volts' => $volts,
	'l1-cache' => $l1_cache,
	'l2-cache' => $l2_cache,
	'l3-cache' => $l3_cache,
	);
	main::log_data('dump','%cpu_properties',\%cpu_properties) if $b_log;
	#print Data::Dumper::Dumper \%cpu;
	#print Data::Dumper::Dumper \%cpu_properties;
	#my $dc = scalar @dies;
	#print 'phys: ' . $pc . ' dies: ' . $dc, "\n";
	eval $end if $b_log;
	return %cpu_properties;
}
sub cpu_dmi_data {
	eval $start if $b_log;
	return if !@dmi;
	my %dmi_data = ('L1' => 0, 'L2' => 0,'L3' => 0, 'ext-clock' => undef, 'socket' => undef, 
	'speed' => undef, 'max-speed' => undef, 'upgrade' => undef, 'volts' => undef);
	my ($id,$amount,$socket,$upgrade);
	foreach my $ref (@dmi){
		next if ref $ref ne 'ARRAY';
		my @item = @$ref;
		next if ($item[0] < 4 || $item[0] == 5 || $item[0] == 6);
		last if $item[0] > 7;
		if ($item[0] == 7){
			# skip first three row, we don't need that data
			splice @item, 0, 3;
			($id,$amount) = ('',0);
			foreach my $value (@item){
				next if $value =~ /~/;
				# variants: L3 - Cache; L3 Cache; L3-cache; CPU Internal L1
				if ($value =~ /^Socket Designation:.* (L[1-3])\b/){
					$id = $1;
				}
				# some cpus only show Socket Designation: Internal cache
				elsif (!$id && $value =~ /^Configuration:.* Level.*([1-3])\b/){
					$id = "L$1";
				}
				elsif ($id && $value =~ /^Installed Size:\s+(.*B)$/){
					$amount = main::translate_size($1);
				}
				if ($id && $amount){
					$dmi_data{$id} += $amount;
					last;
				}
			}
		}
		# note: for multi cpu systems, we're hoping that these values are
		# the same for each cpu, which in most pc situations they will be,
		# and ARM etc won't be using dmi data here anyway.
		# Older dmidecode appear to have unreliable Upgrade outputs
		elsif ($item[0] == 4){
			# skip first three row, we don't need that data
			splice @item, 0, 3;
			($socket,$upgrade) = (undef);
			foreach my $value (@item){
				next if $value =~ /~/;
				# note: on single cpu systems, Socket Designation shows socket type,
				# but on multi, shows like, CPU1; CPU Socket #2; Socket 0; so check values a bit.
				# Socket Designation: Intel(R) Core(TM) i5-3470 CPU @ 3.20GHz
				# Sometimes shows as CPU Socket...
				if ($value =~ /^Socket Designation:\s*(CPU\s*Socket|Socket)?[\s-]*(.*)$/i){
					$upgrade = main::dmi_cleaner($2) if $2 !~ /(cpu|[mg]hz|onboard|socket|@|^#?[0-9]$)/i;
					#print "$socket_temp\n";
				}
				# normally we prefer this value, but sometimes it's garbage
				# older systems often show: Upgrade: ZIF Socket which is a generic term, legacy
				elsif ($value =~ /^Upgrade:\s*(CPU\s*Socket|Socket)?[\s-]*(.*)$/i){
					#print "$2\n";
					$socket = main::dmi_cleaner($2) if $2 !~ /(ZIF|\bslot\b)/i;
				}
				# seen: Voltage: 5.0 V 2.9 V
				elsif ($value =~ /^Voltage:\s*([0-9\.]+)\s*(V|Volts)?\b/i){
					$dmi_data{'volts'} = main::dmi_cleaner($1);
				}
				elsif ($value =~ /^Current Speed:\s*([0-9\.]+)\s*([MGK]Hz)?\b/i){
					$dmi_data{'speed'} = main::dmi_cleaner($1);
				}
				elsif ($value =~ /^Max Speed:\s*([0-9\.]+)\s*([MGK]Hz)?\b/i){
					$dmi_data{'max-speed'} = main::dmi_cleaner($1);
				}
				elsif ($value =~ /^External Clock:\s*([0-9\.]+\s*[MGK]Hz)\b/){
					$dmi_data{'ext-clock'} = main::dmi_cleaner($1);
				}
			}
		}
	}
	# Seen older cases where Upgrade: Other value exists
	if ($socket || $upgrade){
		if ($socket && $upgrade){
			$upgrade = undef if $socket eq $upgrade;
		}
		elsif ($upgrade){
			$socket = $upgrade;
			$upgrade = undef;
		}
		$dmi_data{'socket'} = $socket;
		$dmi_data{'upgrade'} = $upgrade;
	}
	main::log_data('dump','%dmi_data',\%dmi_data) if $b_log;
	# print Data::Dumper::Dumper \%dmi_data;
	eval $end if $b_log;
	return %dmi_data;
}
sub cpu_bugs_sys {
	eval $start if $b_log;
	my (@bugs,$type,$value);
	return if ! -d '/sys/devices/system/cpu/vulnerabilities/';
	my @items = main::globber('/sys/devices/system/cpu/vulnerabilities/*');
	if (@items){
		foreach (@items){
			$value = ( -r $_) ? (main::reader($_))[0] : main::row_defaults('root-required');
			$type = ($value =~ /^Mitigation:/) ? 'mitigation': 'status';
			$_ =~ s/.*\/([^\/]+)$/$1/;
			$value =~ s/Mitigation: //;
			@bugs = (@bugs,[($_,$type,$value)]);
		}
	}
	main::log_data('dump','@bugs',\@bugs) if $b_log;
	# print Data::Dumper::Dumper \@bugs;
	eval $end if $b_log;
	return @bugs;
}

sub cpu_speeds {
	eval $start if $b_log;
	my (@processors) = @_;
	my (@speeds);
	my @files = main::globber('/sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq');
	foreach (@files){
		my $speed = (main::reader($_))[0];
		if ($speed || $speed eq '0'){
			$speed = sprintf "%.0f", $speed/1000;
			push @speeds, $speed;
		}
	}
	if (!@speeds){
		foreach (@processors){
			if ($_ || $_ eq '0'){
				$_ = sprintf "%.0f", $_;
				push @speeds, $_;
			}
		}
	}
	#print join '; ', @speeds, "\n";
	eval $end if $b_log;
	return @speeds;
}
sub set_cpu_speeds_sys {
	eval $start if $b_log;
	my (@max_freq,@min_freq,@policies,%speeds);
	my $sys = '/sys/devices/system/cpu/cpufreq/policy0';
	my $sys2 = '/sys/devices/system/cpu/cpu0/cpufreq/';
	my ($cur,$min,$max) = ('scaling_cur_freq','scaling_min_freq','scaling_max_freq');
	if (!-d $sys && -d $sys2){
		$sys = $sys2;
		($cur,$min,$max) = ('scaling_cur_freq','cpuinfo_min_freq','cpuinfo_max_freq');
	}
	if (-d $sys){
		# corner cases, android, will have the files but they may be unreadable
		if (-r "$sys/$cur"){
			$speeds{'cur-freq'} = (main::reader("$sys/$cur"))[0] ;
			$speeds{'cur-freq'} = speed_cleaner($speeds{'cur-freq'},'khz');
		}
		if (-r "$sys/$min"){
			$speeds{'min-freq'} = (main::reader("$sys/$min"))[0];
			$speeds{'min-freq'} = speed_cleaner($speeds{'min-freq'},'khz');
		}
		if (-r "$sys/$max"){
			$speeds{'max-freq'} = (main::reader("$sys/$max"))[0];
			$speeds{'max-freq'} = speed_cleaner($speeds{'max-freq'},'khz');
		}
		if ($b_arm || $b_mips){
			@policies = main::globber('/sys/devices/system/cpu/cpufreq/policy*/');
			# there are arm chips with two dies, that run at different min max speeds!!
			# see: https://github.com/smxi/inxi/issues/128
			# it would be slick to show both die min/max/cur speeds, but this is
			# ok for now.
			if (scalar @policies > 1){
				my ($current,$cur_temp,$max,$max_temp,$min,$min_temp) = (0,0,0,0,0,0);
				foreach (@policies){
					$_ =~ s/\/$//; # strip off last slash in case globs have them
					$max_temp = (-r "$_/cpuinfo_max_freq") ? (main::reader("$_/cpuinfo_max_freq"))[0] : 0;
					if ($max_temp){
						$max_temp = speed_cleaner($max_temp,'khz');
						push @max_freq, $max_temp;
					}
					$max = $max_temp if ($max_temp > $max);
					$min_temp = (-r "$_/cpuinfo_min_freq") ? (main::reader("$_/cpuinfo_min_freq"))[0] : 0;
					if ($min_temp){
						$min_temp = speed_cleaner($min_temp,'khz');
						push @min_freq, $min_temp;
					}
					$min = $min_temp if ($min_temp < $min || $min == 0);
					$cur_temp = (-r "$_/scaling_cur_freq") ? (main::reader("$_/scaling_cur_freq"))[0] : 0;
					$cur_temp = speed_cleaner($cur_temp,'khz') if $cur_temp;
					if ($cur_temp > $current){
						$current = $cur_temp;
					}
				}
				if (@max_freq){
					@max_freq = main::uniq(@max_freq);
					$max = join ':', @max_freq;
				}
				if (@min_freq){
					@min_freq = main::uniq(@min_freq);
					$min = join ':', @min_freq;
				}
				$speeds{'cur-freq'} = $current if $current;
				$speeds{'max-freq'} = $max if $max;
				$speeds{'min-freq'} = $min if $min;
			}
		}
		# policy4/cpuinfo_max_freq:["2000000"] policy0/cpuinfo_max_freq:["1500000"] 
		# policy4/cpuinfo_min_freq:["200000"]
		if ( (scalar @max_freq < 2 && scalar @min_freq < 2 ) && 
		 (defined $speeds{'min-freq'} && defined $speeds{'max-freq'}) &&
		 ($speeds{'min-freq'} > $speeds{'max-freq'} || $speeds{'min-freq'} == $speeds{'max-freq'} )){
			$speeds{'min-freq'} = 0;
		}
	}
	main::log_data('dump','%speeds',\%speeds) if $b_log;
	eval $end if $b_log;
	return %speeds;
}

# right now only using this for ARM cpus, this is not the same in intel/amd
sub cpu_dies_sys {
	eval $start if $b_log;
	my @data = main::globber('/sys/devices/system/cpu/cpu*/topology/core_siblings_list');
	my (@dies);
	foreach (@data){
		my $siblings = (main::reader($_))[0];
		if (! grep {/$siblings/} @dies){
			push @dies, $siblings;
		}
	}
	my $die_count = scalar @dies;
	eval $end if $b_log;
	return $die_count;
}
# needed because no physical_id in cpuinfo, but > 1 cpu systems exist
# returns: 0 - per cpu cores; 1 - phys cpu count; 2 - override model defaul names
sub elbrus_data {
	eval $start if $b_log;
	my ($model_id,$count,$arch) = @_;
	# 0: cores
	my @cores;
	my @return = (0,1,$arch);
	$cores[1] = 1;
	$cores[2] = 1;
	$cores[3] = 4;
	$cores[4] = 2;
	$cores[6] = 1;
	$cores[7] = 8;
	$cores[8] = 1;
	$cores[9] = 8;
	$cores[10] = 12;
	$cores[11] = 16;
	$cores[12] = 2;
	if (main::is_numeric($model_id) && $cores[$model_id]){
		$return[0] = $cores[$model_id] ;
	}
	if ($return[0]){
		$return[1] = ($count % $return[0]) ? int($count/$return[0]) + 1 : $count/$return[0];
	}
	eval $end if $b_log;
	return @return;
}
sub cpu_flags_bsd {
	eval $start if $b_log;
	my ($flags,$sep) = ('','');
	# this will be null if it was not readable
	my $file = main::system_files('dmesg-boot');
	if ( @dmesg_boot){
		foreach (@dmesg_boot){
			if ( /Features/ || ( $bsd_type eq "openbsd" && /^cpu0:\s*[a-z0-9]{2,3}(\s|,)[a-z0-9]{2,3}(\s|,)/i ) ) {
				my @line = split /:\s*/, lc($_);
				# free bsd has to have weird syntax: <....<b23>,<b34>>
				# Features2=0x1e98220b<SSE3,PCLMULQDQ,MON,SSSE3,CX16,SSE4.1,SSE4.2,POPCNT,AESNI,XSAVE,OSXSAVE,AVX>
				$line[1] =~ s/^[^<]*<|>[^>]*$//g;
				# then get rid of <b23> stuff
				$line[1] =~ s/<[^>]+>//g;
				# and replace commas with spaces
				$line[1] =~ s/,/ /g;
				$flags .= $sep . $line[1];
				$sep = ' ';
			}
			elsif (/real mem/){
				last;
			}
		}
		if ($flags){
			$flags =~ s/\s+/ /g;
			$flags =~ s/^\s+|\s+$//g;
		}
	}
	else {
		if ( $file && ! -r $file ){
			$flags = main::row_defaults('dmesg-boot-permissions');
		}
	}
	eval $end if $b_log;
	return $flags;
}

sub cpu_vendor {
	eval $start if $b_log;
	my ($string) = @_;
	my ($vendor) = ('');
	$string = lc($string);
	if ($string =~ /intel/) {
		$vendor = "intel"
	}
	elsif ($string =~ /amd/){
		$vendor = "amd"
	}
	# via
	elsif ($string =~ /centaur/){
		$vendor = "centaur"
	}
	elsif ($string =~ /e2k/){
		$vendor = "elbrus"
	}
	eval $end if $b_log;
	return $vendor;
}
sub get_boost_status {
	eval $start if $b_log;
	my ($boost);
	my $path = '/sys/devices/system/cpu/cpufreq/boost';
	if (-f $path){
		$boost = (main::reader($path))[0];
		if (defined $boost && $boost =~/^[01]$/){
			$boost = ($boost) ? 'enabled' : 'disabled';
		}
	}
	eval $end if $b_log;
	return $boost;
}
sub system_cpu_name {
	eval $start if $b_log;
	my (%cpus,$compat,@working);
	if (@working = main::globber('/sys/firmware/devicetree/base/cpus/cpu@*/compatible')){
		foreach my $file (@working){
			$compat = (main::reader($file))[0];
			next if $compat =~ /timer/; # seen on android
			# these can have non printing ascii... why? As long as we only have the 
			# splits for: null 00/start header 01/start text 02/end text 03
			$compat = (split /\x01|\x02|\x03|\x00/, $compat)[0] if $compat;
			$compat = (split /,\s*/, $compat)[-1] if $compat;
			$cpus{$compat} = ($cpus{$compat}) ? ++$cpus{$compat}: 1;
		}
	}
	# synthesize it, [4] will be like: cortex-a15-timer; sunxi-timer
	# so far all with this directory show soc name, not cpu name for timer
	elsif (! -d '/sys/firmware/devicetree/base' && @devices_timer){
		foreach my $ref (@devices_timer){
			@working = @$ref;
			next if $working[0] ne 'timer' || !$working[4] || $working[4] =~ /timer-mem$/;
			$working[4] =~ s/(-system)?-timer$//;
			$compat = $working[4];
			$cpus{$compat} = ($cpus{$compat}) ? ++$cpus{$compat}: 1;
		}
	}
	main::log_data('dump','%cpus',\%cpus) if $b_log;
	eval $end if $b_log;
	return %cpus;
}

sub cpu_arch {
	eval $start if $b_log;
	my ($type,$family,$model,$stepping) = @_;
	$stepping = 0 if !main::is_numeric($stepping);
	my $arch = '';
	# See: docs/inxi-resources.txt 
	# print "$type;$family;$model\n";
	if ( $type eq 'amd'){
		if ($family eq '4'){
			if ( $model =~ /^(3|7|8|9|A)$/ ) {$arch = 'Am486'}
			elsif ( $model =~ /^(E|F)$/ ) {$arch = 'Am5x86'}
		}
		elsif ($family eq '5'){
			if ( $model =~ /^(0|1|2|3)$/ ) {$arch = 'K5'}
			elsif ( $model =~ /^(6|7)$/ ) {$arch = 'K6'}
			elsif ( $model =~ /^(8)$/ ) {$arch = 'K6-2'}
			elsif ( $model =~ /^(9|D)$/ ) {$arch = 'K6-3'}
			elsif ( $model =~ /^(A)$/ ) {$arch = 'Geode'}
			}
		elsif ($family eq '6'){
			if ( $model =~ /^(1|2)$/ ) {$arch = 'K7'}
			elsif ( $model =~ /^(3|4)$/ ) {$arch = 'K7 Thunderbird'}
			elsif ( $model =~ /^(6|7|8|A)$/ ) {$arch = 'K7 Palomino+'}
			else {$arch = 'K7'}
		}
		elsif ($family eq 'F'){
			if ( $model =~ /^(4|5|7|8|B|C|E|F|14|15|17|18|1B|1C|1F)$/ ) {$arch = 'K8'}
			elsif ( $model =~ /^(21|23|24|25|27|28|2C|2F)$/ ) {$arch = 'K8 rev.E'}
			elsif ( $model =~ /^(41|43|48|4B|4C|4F|5D|5F|68|6B|6C|6F|7C|7F|C1)$/ ) {$arch = 'K8 rev.F+'}
			else {$arch = 'K8'}
		}
		elsif ($family eq '10'){
			if ( $model =~ /^(2|4|5|6|8|9|A)$/ ) {$arch = 'K10'}
			else {$arch = 'K10'}
		}
		elsif ($family eq '11'){
			if ( $model =~ /^(3)$/ ) {$arch = 'Turion X2 Ultra'}
		}
		# might also need cache handling like 14/16
		elsif ($family eq '12'){
			if ( $model =~ /^(1)$/ ) {$arch = 'Fusion'}
			else {$arch = 'Fusion'}
		}
		# SOC, apu
		elsif ($family eq '14'){
			if ( $model =~ /^(1|2)$/ ) {$arch = 'Bobcat'}
			else {$arch = 'Bobcat'}
		}
		elsif ($family eq '15'){
			if ( $model =~ /^(0|1|2|3|4|5|6|7|8|9|A|B|C|D|E|F)$/ ) {$arch = 'Bulldozer'}
			elsif ( $model =~ /^(10|11|12|13|14|15|16|17|18|19|1A|1B|1C|1D|1E|1F)$/ ) {$arch = 'Piledriver'}
			elsif ( $model =~ /^(30|31|32|33|34|35|36|37|38|39|3A|3B|3C|3D|3E|3F)$/ ) {$arch = 'Steamroller'}
			elsif ( $model =~ /^(60|61|62|63|64|65|66|67|68|69|6A|6B|6C|6D|6E|6F|70|71|72|73|74|75|76|77|78|79|7A|7B|7C|7D|7E|7F)$/ ) {$arch = 'Excavator'}
			else {$arch = 'Bulldozer'}
		}
		# SOC, apu
		elsif ($family eq '16'){
			if ( $model =~ /^(0|1|2|3|4|5|6|7|8|9|A|B|C|D|E|F)$/ ) {$arch = 'Jaguar'}
			elsif ( $model =~ /^(30|31|32|33|34|35|36|37|38|39|3A|3B|3C|3D|3E|3F)$/ ) {$arch = 'Puma'}
			else {$arch = 'Jaguar'}
		}
		elsif ($family eq '17'){
			if ( $model =~ /^(1|11)$/ ) {$arch = 'Zen'}
			elsif ( $model =~ /^(8|18)$/ ) {$arch = 'Zen+'}
			# not positive about 2x, main resource shows only 31 and 71 hex 
			elsif ( $model =~ /^(2[0123456789ABCDEF]|31|71)$/ ) {$arch = 'Zen 2'}
			# no info on these yet, but they are coming and are scheduled
			# elsif ( $model =~ /^()$/ ) {$arch = 'Zen 3'}
			# elsif ( $model =~ /^()$/ ) {$arch = 'Zen 4'}
			else {$arch = 'Zen'}
		}
		elsif ($family eq '18'){
			# model #s not known yet
			$arch = 'Hygon Dhyana';
		}
		elsif ($family eq '19'){
			# model #s not known yet
			$arch = 'Zen 3';
		}
		# note: family 20 may be Zen 4 but not known for sure yet
	}
	elsif ( $type eq 'arm'){
		if ($family ne ''){$arch="ARMv$family";}
		else {$arch='ARM';}
	}
# 	elsif ( $type eq 'ppc'){
# 		$arch='PPC';
# 	}
	# aka VIA
	elsif ( $type eq 'centaur'){ 
		if ($family eq '5'){
			if ( $model =~ /^(4)$/ ) {$arch = 'WinChip C6'}
			elsif ( $model =~ /^(8)$/ ) {$arch = 'WinChip 2'}
			elsif ( $model =~ /^(9)$/ ) {$arch = 'WinChip 3'}
		}
		elsif ($family eq '6'){
			if ( $model =~ /^(6)$/ ) {$arch = 'WinChip-based'}
			elsif ( $model =~ /^(7|8)$/ ) {$arch = 'C3'}
			elsif ( $model =~ /^(9)$/ ) {$arch = 'C3-2'}
			elsif ( $model =~ /^(A|D)$/ ) {$arch = 'C7'}
			elsif ( $model =~ /^(F)$/ ) {$arch = 'Isaiah'}
		}
	}
	elsif ( $type eq 'elbrus'){ 
		if ($family eq '4'){
			if ( $model eq '1' ) {$arch = 'Elbrus'}
			elsif ( $model eq '2' ) {$arch = 'Elbrus-S'}
			elsif ( $model eq '3' ) {$arch = 'Elbrus-4C'}
			elsif ( $model eq '4' ) {$arch = 'Elbrus-2C+'}
			elsif ( $model eq '6' ) {$arch = 'Elbrus-2CM'}
			elsif ( $model eq '7' ) {
				if ($stepping >= 2) {$arch = 'Elbrus-8C1';}
				else {$arch = 'Elbrus-8C';}
			} # note: stepping > 1 may be 8C1
			elsif ( $model eq '8' ) {$arch = 'Elbrus-1C+'}
			elsif ( $model eq '9' ) {$arch = 'Elbrus-8CV'}
			elsif ( $model eq '10' ) {$arch = 'Elbrus-12C'}
			elsif ( $model eq '11' ) {$arch = 'Elbrus-16C'}
			elsif ( $model eq '12' ) {$arch = 'Elbrus-2C3'}
			else {$arch = 'Elbrus-??';}
		}
	}
	elsif ( $type eq 'intel'){
		if ($family eq '4'){
			if ( $model =~ /^(0|1|2|3|4|5|6|7|8|9)$/ ) {$arch = '486'}
		}
		elsif ($family eq '5'){
			if ( $model =~ /^(1|2|3|7)$/ ) {$arch = 'P5'}
			elsif ( $model =~ /^(4|8)$/ ) {$arch = 'P5'} # MMX
			elsif ( $model =~ /^(9)$/ ) {$arch = 'Quark'}
		}
		elsif ($family eq '6'){
			if ( $model =~ /^(1)$/ ) {$arch = 'P6 Pro'}
			elsif ( $model =~ /^(15)$/ ) {$arch = 'M Tolapai'} # pentium M system on chip
			elsif ( $model =~ /^(3)$/ ) {$arch = 'P6 II Klamath'}
			elsif ( $model =~ /^(5)$/ ) {$arch = 'P6 II Deschutes'}
			elsif ( $model =~ /^(6)$/ ) {$arch = 'P6 II Mendocino'}
			elsif ( $model =~ /^(7)$/ ) {$arch = 'P6 III Katmai'}
			elsif ( $model =~ /^(8)$/ ) {$arch = 'P6 III Coppermine'}
			elsif ( $model =~ /^(9)$/ ) {$arch = 'M Banias'} # pentium M
			elsif ( $model =~ /^(A)$/ ) {$arch = 'P6 III Xeon'}
			elsif ( $model =~ /^(B)$/ ) {$arch = 'P6 III Tualitin'}
			elsif ( $model =~ /^(D)$/ ) {$arch = 'M Dothan'} # Pentium M
			elsif ( $model =~ /^(E)$/ ) {$arch = 'M Yonah'}
			elsif ( $model =~ /^(F|16)$/ ) {$arch = 'Core Merom'}
			elsif ( $model =~ /^(17|1D)$/ ) {$arch = 'Penryn'}
			elsif ( $model =~ /^(1A|1E|1F|2E|25|2C|2F)$/ ) {$arch = 'Nehalem'}
			elsif ( $model =~ /^(26|1C)$/ ) {$arch = 'Bonnell'} # atom Bonnell? 27?
			elsif ( $model =~ /^(27|35|36)$/ ) {$arch = 'Saltwell'}
			elsif ( $model =~ /^(25|2C|2F)$/ ) {$arch = 'Westmere'}
			elsif ( $model =~ /^(2A|2D)$/ ) {$arch = 'Sandy Bridge'}
			elsif ( $model =~ /^(37|4A|4D|5A|5D)$/ ) {$arch = 'Silvermont'}
			elsif ( $model =~ /^(3A|3E)$/ ) {$arch = 'Ivy Bridge'}
			elsif ( $model =~ /^(3C|3F|45|46)$/ ) {$arch = 'Haswell'}
			elsif ( $model =~ /^(3D|47|4F|56)$/ ) {$arch = 'Broadwell'}
			elsif ( $model =~ /^(4E)$/ ) {$arch = 'Skylake'} # had 9E, cascade lake also 55
			# need to find stepping for cl, guessing stepping 4 is last for sl
			elsif ( $model =~ /^(55)$/ ) {
				if ($stepping > 4){$arch = 'Cascade Lake'}
				else {$arch = 'Skylake'} }
			elsif ( $model =~ /^(5C|5F)$/ ) {$arch = 'Goldmont'}
			elsif ( $model =~ /^(5E)$/ ) {$arch = 'Skylake-S'}
			elsif ( $model =~ /^(4C)$/ ) {$arch = 'Airmont'}
			elsif ( $model =~ /^(7A)$/ ) {$arch = 'Goldmont Plus'} 
			elsif ( $model =~ /^(7D|7E)$/ ) {$arch = 'Ice Lake'}
			elsif ( $model =~ /^(8C)$/ ) {$arch = 'Tiger Lake'}
			elsif ( $model =~ /^(8E|9E)$/ ) {
				if ($model eq '9E' && ($stepping == 10 || $stepping == 11 || $stepping == 12  || $stepping == 13)){$arch = 'Coffee Lake'}
				elsif ($model eq '8E' && $stepping == 10){$arch = 'Coffee Lake'}
				elsif ($model eq '8E' && ($stepping == 11 || $stepping == 12)){$arch = 'Whiskey Lake'}
				elsif ($model eq '8E' && $stepping == 9){$arch = 'Amber Lake'}
				elsif ($stepping > 13){$arch = 'Comet Lake'} # guess, have not seen docs yet
				# elsif ($stepping > 9 && $stepping < 14){$arch = 'Coffee Lake'}
				# NOTE: kaby lake is 8E 9 but so is Amber Lake
				else {$arch = 'Kaby Lake'} }
			#elsif ( $model =~ /^(9E)$/ ) {$arch = 'Coffee Lake'}
			elsif ( $model =~ /^(57)$/ ) {$arch = 'Knights Landing'}
			elsif ( $model =~ /^(66)$/ ) {$arch = 'Cannon Lake'}
			elsif ( $model =~ /^(85)$/ ) {$arch = 'Knights Mill'}
			elsif ( $model =~ /^(86)$/ ) {$arch = 'Tremont'}
			# More info: comet: shares family/model, need to find stepping numbers
			# Coming: meteor lake; alder lake; cooper lake; granite rapids; meteor lake; saphire rapids; 
		}
		# itanium 1 family 7 all recalled
		elsif ($family eq 'B'){
			if ( $model =~ /^(0)$/ ) {$arch = 'Knights Ferry'}
			if ( $model =~ /^(1)$/ ) {$arch = 'Knights Corner'}
		}
		elsif ($family eq 'F'){
			if ( $model =~ /^(0|1)$/ ) {$arch = 'Netburst Willamette'}
			elsif ( $model =~ /^(2)$/ ) {$arch = 'Netburst Northwood'}
			elsif ( $model =~ /^(3)$/ ) {$arch = 'Netburst Prescott'} # 6? Nocona
			elsif ( $model =~ /^(4)$/ ) {$arch = 'Netburst Smithfield'} # 6? Nocona
			elsif ( $model =~ /^(6)$/ ) {$arch = 'Netburst Presler'}
			else {$arch = 'Netburst'}
		}
	}
	eval $end if $b_log;
	return $arch;
}

sub count_alpha {
	my ($count) = @_;
	#print "$count\n";
	my @alpha = qw(Single Dual Triple Quad);
	if ($count > 4){
		$count .= '-';
	}
	else {
		$count = $alpha[$count-1] . ' ' if $count > 0;
	}
	return $count;
}
sub set_cpu_data {
	my %cpu =  (
	'arch' => '',
	'bogomips' => 0,
	'cores' => 0,
	'cur-freq' => 0,
	'dies' => 0,
	'family' => '',
	'flags' => '',
	'ids' => [],
	'l1-cache' => 0, # store in KB
	'l2-cache' => 0, # store in KB
	'l3-cache' => 0, # store in KB
	'max-freq' => 0,
	'min-freq' => 0,
	'model_id' => '',
	'model_name' => '',
	'processors' => [],
	'rev' => '',
	'scalings' => [],
	'siblings' => 0,
	'type' => '',
	);
	return %cpu;
}
# MHZ - cell cpus
sub speed_cleaner {
	my ($speed,$opt) = @_;
	return if ! $speed || $speed eq '0';
	$speed =~ s/[GMK]HZ$//gi;
	$speed = ($speed/1000) if $opt && $opt eq 'khz';
	$speed = sprintf "%.0f", $speed;
	return $speed;
}
sub cpu_cleaner {
	my ($cpu) = @_;
	return if ! $cpu;
	my $filters = '@|cpu |cpu deca|([0-9]+|single|dual|two|triple|three|tri|quad|four|';
	$filters .= 'penta|five|hepta|six|hexa|seven|octa|eight|multi)[ -]core|';
	$filters .= 'ennea|genuine|multi|processor|single|triple|[0-9\.]+ *[MmGg][Hh][Zz]';
	$cpu =~ s/$filters//ig;
	$cpu =~ s/\s\s+/ /g;
	$cpu =~ s/^\s+|\s+$//g;
	return $cpu;
}
sub hex_and_decimal {
	my ($data) = @_; 
	if ($data){
		$data .=  ' (' . hex($data) . ')' if hex($data) ne $data;
	}
	else {
		$data = 'N/A';
	}
	return $data;
}
}

## DiskData
{
package DiskData;
my ($b_hddtemp,$b_nvme,$smartctl_missing);
my ($hddtemp,$nvme) = ('','');
my (@by_id,@by_path,@vendors);
my ($debugger_dir);
# main::writer("$debugger_dir/system-repo-data-urpmq.txt",@data2) if $debugger_dir;
sub get {
	eval $start if $b_log;
	my (@data,@rows,$key1,$val1);
	my ($type) = @_;
	$type ||= 'standard';
	my $num = 0;
	@data = disk_data($type);
	# NOTE: 
	if (@data){
		if ($type eq 'standard'){
			@data = create_output(@data);
			@rows = (@rows,@data);
			if ( $bsd_type && !@dm_boot_disk && $type eq 'standard' && $show{'disk'} ){
				$key1 = 'Drive Report';
				my $file = main::system_files('dmesg-boot');
				if ( $file && ! -r $file){
					$val1 = main::row_defaults('dmesg-boot-permissions');
				}
				elsif (!$file){
					$val1 = main::row_defaults('dmesg-boot-missing');
				}
				else {
					$val1 = main::row_defaults('disk-data-bsd');
				}
				@data = ({main::key($num++,0,1,$key1) => $val1,});
				@rows = (@rows,@data);
			}
		}
		else {
			@rows = @data;
			# print Data::Dumper::Dumper \@rows;
		}
	}
	else {
		$key1 = 'Message';
		$val1 = main::row_defaults('disk-data');
		@rows = ({main::key($num++,0,1,$key1) => $val1,});
	}
	if (!@rows){
		$key1 = 'Message';
		$val1 = main::row_defaults('disk-data');
		@data = ({main::key($num++,0,1,$key1) => $val1,});
	}
	#@rows = (@rows,@data);
	@data = ();
	if ($show{'optical'} || $show{'optical-basic'}){
		@data = OpticalData::get();
		@rows = (@rows,@data);
	}
	($b_hddtemp,$b_nvme,$hddtemp,$nvme) = (undef,undef,undef,undef);
	(@by_id,@by_path) = (undef,undef);
	eval $end if $b_log;
	return @rows;
}
sub create_output {
	eval $start if $b_log;
	my (@disks) = @_;
	#print Data::Dumper::Dumper \@disks;
	my ($b_oldage,$b_prefail,$b_smart,$b_smart_permissions,@data,@rows);
	my ($num,$j) = (0,0);
	my ($id,$model,$size,$used,$percent,$size_holder,
	$used_holder) = ('','','','','','','');
	my @smart_basic =(
	['smart','SMART'],
	['smart-error','SMART Message'],
	['smart-support','state'],
	['smart-status','health'],
	['smart-power-on-hours','on'],
	['smart-cycles','cycles'],
	['smart-units-read','read-units'],
	['smart-units-written','written-units'],
	['smart-read','read'],
	['smart-written','written'],
	);
	my @smart_age =(
	['smart-gsense-error-rate-r','g-sense error rate'],
	['smart-media-wearout-v','media wearout'],
	['smart-media-wearout-t','threshold'],
	['smart-media-wearout-f','alert'],
	['smart-multizone-errors-v','write error rate'],
	['smart-multizone-errors-t','threshold'],
	['smart-udma-crc-errors-r','UDMA CRC errors'],
	['smart-udma-crc-errors-f','alert'],
	);
	my @smart_fail =(
	['smart-end-to-end-v','end-to-end'],
	['smart-end-to-end-t','threshold'],
	['smart-end-to-end-f','alert'],
	['smart-raw-read-error-rate-v','read error rate'],
	['smart-raw-read-error-rate-t','threshold'],
	['smart-raw-read-error-rate-f','alert'],
	['smart-reallocated-sectors-v','reallocated sector'],
	['smart-reallocated-sectors-t','threshold'],
	['smart-reallocated-sectors-f','alert'],
	['smart-retired-blocks-v','retired block'],
	['smart-retired-blocks-t','threshold'],
	['smart-retired-blocks-f','alert'],
	['smart-runtime-bad-block-v','runtime bad block'],
	['smart-runtime-bad-block-t','threshold'],
	['smart-runtime-bad-block-f','alert'],
	['smart-seek-error-rate-v', 'seek error rate'],
	['smart-seek-error-rate-t', 'threshold'],
	['smart-seek-error-rate-f', 'alert'],
	['smart-spinup-time-v','spin-up time'],
	['smart-spinup-time-t','threshold'],
	['smart-spinup-time-f','alert'],
	['smart-ssd-life-left-v','life left'],
	['smart-ssd-life-left-t','threshold'],
	['smart-ssd-life-left-f','alert'],
	['smart-unused-reserve-block-v','unused reserve block'],
	['smart-unused-reserve-block-t','threshold'],
	['smart-unused-reserve-blockf','alert'],
	['smart-used-reserve-block-v','used reserve block'],
	['smart-used-reserve-block-t','threshold'],
	['smart-used-reserve-block-f','alert'],
	['smart-unknown-1-a','attribute'],
	['smart-unknown-1-v','value'],
	['smart-unknown-1-w','worst'],
	['smart-unknown-1-t','threshold'],
	['smart-unknown-1-f','alert'],
	['smart-unknown-2-a','attribute'],
	['smart-unknown-2-v','value'],
	['smart-unknown-2-w','worst'],
	['smart-unknown-2-t','threshold'],
	['smart-unknown-2-f','alert'],
	['smart-unknown-3-a','attribute'],
	['smart-unknown-3-v','value'],
	['smart-unknown-3-w','worst'],
	['smart-unknown-3-t','threshold'],
	['smart-unknown-4-f','alert'],
	['smart-unknown-4-a','attribute'],
	['smart-unknown-4-v','value'],
	['smart-unknown-4-w','worst'],
	['smart-unknown-4-t','threshold'],
	['smart-unknown-4-f','alert'],
	);
	my @sizing = main::get_size($disks[0]{'size'}) if $disks[0]{'size'};
	#print Data::Dumper::Dumper \@disks;
	if (@sizing){
		$size = $sizing[0];
		# note: if a string is returned there will be no Size unit so just use string.
		if (defined $sizing[0] && $sizing[1]){
			$size .= ' ' . $sizing[1];
		}
	}
	$size ||= 'N/A';
	@sizing = ();
	@sizing = main::get_size($disks[0]{'used'}) if defined $disks[0]{'used'};
	if (@sizing){
		$used = $sizing[0];
		if (defined $sizing[0] && $sizing[1]){
			$used .= ' ' . $sizing[1];
			if (( $disks[0]{'size'} && $disks[0]{'size'} =~ /^[0-9]/ ) && 
			    ( $disks[0]{'used'} =~ /^[0-9]/ ) ){
				$used = $used . ' (' . sprintf("%0.1f", $disks[0]{'used'}/$disks[0]{'size'}*100) . '%)';
			}
		}
	}
	$used ||= 'N/A';
	@data = ({
	main::key($num++,1,1,'Local Storage') => '',
	main::key($num++,0,2,'total') => $size,
	main::key($num++,0,2,'used') => $used,
	});
	@rows = (@rows,@data);
	shift @disks;
	if ($smartctl_missing){
		$j = scalar @rows;
		$rows[$j]{main::key($num++,0,1,'SMART Message')} = $smartctl_missing;
	}
	if ( $show{'disk'} && @disks){
		@disks = sort { $a->{'id'} cmp $b->{'id'} } @disks;
		foreach my $ref (@disks){
			($b_oldage,$b_prefail,$b_smart,$id,$model,$size) = (0,0,0,'','','');
			my %row = %$ref;
			$num = 1;
			$model = ($row{'model'}) ? $row{'model'}: 'N/A';
			$id =  ($row{'id'}) ? "/dev/$row{'id'}":'N/A';
			my @sizing = main::get_size($row{'size'});
			#print Data::Dumper::Dumper \@disks;
			if (@sizing){
				$size = $sizing[0];
				# note: if a string is returned there will be no Size unit so just use string.
				if (defined $sizing[0] && $sizing[1]){
					$size .= ' ' . $sizing[1];
					$size_holder = $sizing[0];
				}
				$size ||= 'N/A';
			}
			else {
				$size = 'N/A';
			}
			$j = scalar @rows;
			if (!$b_smart_permissions && $row{'smart-permissions'}){
				$b_smart_permissions = 1;
				$rows[$j]{main::key($num++,0,1,'SMART Message')} = $row{'smart-permissions'};
				$j = scalar @rows;
			}
			@data = ({
			main::key($num++,1,1,'ID') => $id,
			});
			@rows = (@rows,@data);
			if ($row{'type'}){
				$rows[$j]{main::key($num++,0,2,'type')} = $row{'type'};
			}
			if ($row{'vendor'}){
				$rows[$j]{main::key($num++,0,2,'vendor')} = $row{'vendor'};
			}
			$rows[$j]{main::key($num++,0,2,'model')} = $model;
			if ($row{'drive-vendor'}){
				$rows[$j]{main::key($num++,0,2,'drive vendor')} = $row{'drive-vendor'};
			}
			if ($row{'drive-model'}){
				$rows[$j]{main::key($num++,0,2,'drive model')} = $row{'drive-model'};
			}
			if ($row{'family'}){
				$rows[$j]{main::key($num++,0,2,'family')} = $row{'family'};
			}
			$rows[$j]{main::key($num++,0,2,'size')} = $size;
			if ($b_admin && $row{'block-physical'}){
				$rows[$j]{main::key($num++,1,2,'block size')} = '';
				$rows[$j]{main::key($num++,0,3,'physical')} = $row{'block-physical'} . ' B';
				$rows[$j]{main::key($num++,0,3,'logical')} = ($row{'block-logical'}) ? $row{'block-logical'} . ' B' : 'N/A';
			}
			if ($extra > 1 && $row{'speed'}){
				if ($row{'sata'}){
					$rows[$j]{main::key($num++,0,2,'sata')} = $row{'sata'};
				}
				$rows[$j]{main::key($num++,0,2,'speed')} = $row{'speed'};
				$rows[$j]{main::key($num++,0,2,'lanes')} = $row{'lanes'} if $row{'lanes'};
			}
			if ($extra > 2 && $row{'rotation'}){
				$rows[$j]{main::key($num++,0,2,'rotation')} = $row{'rotation'};
			}
			if ($extra > 1){
				my $serial = main::apply_filter($row{'serial'});
				$rows[$j]{main::key($num++,0,2,'serial')} = $serial;
				if ($row{'drive-serial'}){
					$rows[$j]{main::key($num++,0,2,'drive serial')} = main::apply_filter($row{'drive-serial'});
				}
				if ($row{'firmware'}){
					$rows[$j]{main::key($num++,0,2,'rev')} = $row{'firmware'};
				}
				if ($row{'drive-firmware'}){
					$rows[$j]{main::key($num++,0,2,'drive rev')} = $row{'drive-firmware'};
				}
			}
			if ($extra > 0 && $row{'temp'}){
				$rows[$j]{main::key($num++,0,2,'temp')} = $row{'temp'} . ' C';
			}
			# extra level tests already done
			if (defined $row{'partition-table'}){
				$rows[$j]{main::key($num++,0,2,'scheme')} = $row{'partition-table'};
			}
			if ($row{'smart'} || $row{'smart-error'}){
				$j = scalar @rows;
				## Basic SMART and drive info ##
				for (my $i = 0; $i < scalar @smart_basic;$i++){
					if ($row{$smart_basic[$i][0]}){
						if (!$b_smart){
							my $support = ($row{'smart'}) ? $row{'smart'}: $row{'smart-error'};
							$rows[$j]{main::key($num++,1,2,$smart_basic[$i][1])} = $support;
							$b_smart = 1;
							next;
						}
						$rows[$j]{main::key($num++,0,3,$smart_basic[$i][1])} = $row{$smart_basic[$i][0]};
					}
				}
				## Old-Age errors ##
				for (my $i = 0; $i < scalar @smart_age;$i++){
					if ($row{$smart_age[$i][0]}){
						if (!$b_oldage){
							$rows[$j]{main::key($num++,1,3,'Old-Age')} = '';
							$b_oldage = 1;
						}
						$rows[$j]{main::key($num++,0,4,$smart_age[$i][1])} = $row{$smart_age[$i][0]};
					}
				}
				## Pre-Fail errors ##
				for (my $i = 0; $i < scalar @smart_fail;$i++){
					if ($row{$smart_fail[$i][0]}){
						if (!$b_prefail){
							$rows[$j]{main::key($num++,1,3,'Pre-Fail')} = '';
							$b_prefail = 1;
						}
						$rows[$j]{main::key($num++,0,4,$smart_fail[$i][1])} = $row{$smart_fail[$i][0]};
					}
				}
			}
		}
	}
	eval $end if $b_log;
	return @rows;
}
sub disk_data {
	eval $start if $b_log;
	my ($type) = @_;
	my (@rows,@data,@devs);
	my $num = 0;
	my ($used) = (0);
	PartitionData::partition_data() if !$b_partitions;
	foreach my $ref (@partitions){
		my %row = %$ref;
		# don't count remote used, also, some cases mount 
		# panfs is parallel NAS volume manager, need more data
		next if ($row{'fs'} && $row{'fs'} =~ /cifs|iso9660|nfs|panfs|sshfs|smbfs|unionfs/);
		# don't count zfs or file type swap
		next if ($row{'swap-type'} && $row{'swap-type'} ne 'partition');
		# in some cases, like redhat, mounted cdrom/dvds show up in partition data
		next if ($row{'dev-base'} && $row{'dev-base'} =~ /^sr[0-9]+$/);
		# this is used for specific cases where bind, or incorrect multiple mounts 
		# to same partitions, or btrfs sub volume mounts, is present. The value is 
		# searched for an earlier appearance of that partition and if it is present, 
		# the data is not added into the partition used size.
		if ( $row{'dev-base'} !~ /^(\/\/|:\/)/ && ! (grep {/$row{'dev-base'}/} @devs) ){
			$used += $row{'used'} if  $row{'used'};
			push @devs, $row{'dev-base'};
		}
	}
	if (!$bsd_type){
		@data = proc_data($used);
	}
	else {
		@data = dmesg_boot_data($used);
	}
	if ($b_admin){
		my $ref = $alerts{'smartctl'};
		if ( $ref && $$ref{'action'} eq 'use'){
			@data = smartctl_data(@data);
		}
		else {
			$smartctl_missing = $$ref{'missing'};
		}
	}
	print Data::Dumper::Dumper \@data if $test[13];;
	main::log_data('data',"used: $used") if $b_log;
	eval $end if $b_log;
	return @data;
}
sub proc_data {
	eval $start if $b_log;
	my ($used) = @_;
	my (@data,@drives);
	my ($b_hdx,$size,$drive_size) = (0,0,0);
	set_proc_partitions() if !$b_proc_partitions;
	foreach (@proc_partitions){
		next if (/^\s*$/);
		my @row = split /\s+/, $_;
		if ( $row[-1] =~ /^([hsv]d[a-z]+|(ada|mmcblk|n[b]?d|nvme[0-9]+n)[0-9]+)$/) {
			$drive_size = $row[2];
			$b_hdx = 1 if $row[-1] =~ /^hd[a-z]/;
			@data = ({
			'firmware' => '',
			'id' => $row[-1],
			'model' => '',
			'serial' => '',
			'size' => $drive_size,
			'spec' => '',
			'speed' => '',
			'temp' => '',
			'type' => '',
			'vendor' => '',
			});
			@drives = (@drives,@data);
		}
		# See http://lanana.org/docs/device-list/devices-2.6+.txt for major numbers used below
		# See https://www.mjmwired.net/kernel/Documentation/devices.txt for kernel 4.x device numbers
		# if ( $row[0] =~ /^(3|22|33|8)$/ && $row[1] % 16 == 0 )  {
		#	 $size += $row[2];
		# }
		# special case from this data: 8     0  156290904 sda
		# 43        0   48828124 nbd0
		# note: known starters: vm: 252/253/254; grsec: 202; nvme: 259 mmcblk: 179
		# Note: with > 1 nvme drives, the minor number no longer passes the modulus tests,
		# It appears to just increase randomly from the first 0 minor of the first nvme to 
		# nvme partitions to next nvme, so it only passes the test for the first nvme drive.
		if ( $row[0] =~ /^(3|8|22|33|43|179|202|252|253|254|259)$/ && 
		     $row[-1] =~ /(mmcblk[0-9]+|n[b]?d[0-9]+|nvme[0-9]+n[0-9]+|[hsv]d[a-z]+)$/ && 
		     ( $row[1] % 16 == 0 || $row[1] % 16 == 8 || $row[-1] =~ /(nvme[0-9]+n[0-9]+)$/) ) {
			$size += $row[2];
		}
	}
	# print Data::Dumper::Dumper \@drives;
	main::log_data('data',"size: $size") if $b_log;
	@data = ({
	'size' => $size,
	'used' => $used,
	});
	#print Data::Dumper::Dumper \@data;
	if ( $show{'disk'} ){
		@drives = (@data,@drives);
		# print 'drives:', Data::Dumper::Dumper \@drives;
		@data = proc_data_advanced($b_hdx,@drives);
	}
	main::log_data('dump','@data',\@data) if $b_log;
	# print Data::Dumper::Dumper \@data;
	eval $end if $b_log;
	return @data;
}
sub set_proc_partitions {
	eval $start if $b_log;
	$b_proc_partitions = 1;
	if (my $file = main::system_files('partitions')){
		@proc_partitions = main::reader($file,'strip');
		shift @proc_partitions;
	}
	eval $end if $b_log;
}
sub proc_data_advanced {
	eval $start if $b_log;
	my ($b_hdx,@drives) = @_;
	my ($i) = (0);
	my (@data,@disk_data,@rows,@scsi,@temp,@working);
	my ($pt_cmd) = ('unset');
	my ($block_type,$file,$firmware,$model,$path,
	$partition_scheme,$serial,$vendor,$working_path);
	@by_id = main::globber('/dev/disk/by-id/*');
	# these do not contain any useful data, no serial or model name
	# wwn-0x50014ee25fb50fc1 and nvme-eui.0025385b71b07e2e 
	# scsi-SATA_ST980815A_ simply repeats ata-ST980815A_; same with scsi-0ATA_WDC_WD5000L31X
	# we also don't need the partition items
	my $pattern = '^\/dev\/disk\/by-id\/(md-|lvm-|dm-|wwn-|nvme-eui|raid-|scsi-([0-9]ATA|SATA))|-part[0-9]+$';
	@by_id = grep {!/$pattern/} @by_id if @by_id;
	# print join "\n", @by_id, "\n";
	@by_path = main::globber('/dev/disk/by-path/*');
	## check for all ide type drives, non libata, only do it if hdx is in array
	## this is now being updated for new /sys type paths, this may handle that ok too
	## skip the first rows in the loops since that's the basic size/used data
	if ($b_hdx){
		for ($i = 1; $i < scalar @drives; $i++){
			$file = "/proc/ide/$drives[$i]{'id'}/model";
			if ( $drives[$i]{'id'} =~ /^hd[a-z]/ && -e $file){
				$model = (main::reader($file,'strip'))[0];
				$drives[$i]{'model'} = $model;
			}
		}
	}
	# scsi stuff
	if ($file = main::system_files('scsi')){
		@scsi = scsi_data($file);
	}
	# print 'drives:', Data::Dumper::Dumper \@drives;
	for ($i = 1; $i < scalar @drives; $i++){
		#next if $drives[$i]{'id'} =~ /^hd[a-z]/;
		($block_type,$firmware,$model,$partition_scheme,
		$serial,$vendor,$working_path) = ('','','','','','','');
		if ($extra > 2){
			@data = advanced_disk_data($pt_cmd,$drives[$i]{'id'});
			$pt_cmd = $data[0];
			$drives[$i]{'partition-table'} = uc($data[1]) if $data[1];
			$drives[$i]{'rotation'} = "$data[2] rpm" if $data[2];
		}
		#print "$drives[$i]{'id'}\n";
		@disk_data = disk_data_by_id("/dev/$drives[$i]{'id'}");
		main::log_data('dump','@disk_data', \@disk_data) if $b_log;
		if ($drives[$i]{'id'} =~ /[sv]d[a-z]/){
			$block_type = 'sdx';
			$working_path = "/sys/block/$drives[$i]{'id'}/device/";
		}
		elsif ($drives[$i]{'id'} =~ /mmcblk/){
			$block_type = 'mmc';
			$working_path = "/sys/block/$drives[$i]{'id'}/device/";
		}
		elsif ($drives[$i]{'id'} =~ /nvme/){
			$block_type = 'nvme';
			# this results in:
			# /sys/devices/pci0000:00/0000:00:03.2/0000:06:00.0/nvme/nvme0/nvme0n1
			# but we want to go one level down so slice off trailing nvme0n1
			$working_path = Cwd::abs_path("/sys/block/$drives[$i]{'id'}");
			$working_path =~ s/nvme[^\/]*$//;
		}
		main::log_data('data',"working path: $working_path") if $b_log;
		if ($b_admin && -e "/sys/block/"){
			my @working = block_data($drives[$i]{'id'});
			$drives[$i]{'block-logical'} = $working[0];
			$drives[$i]{'block-physical'} = $working[1];
		}
		if ($block_type && @scsi && @by_id && ! -e "${working_path}model" && ! -e "${working_path}name"){
			## ok, ok, it's incomprehensible, search /dev/disk/by-id for a line that contains the
			# discovered disk name AND ends with the correct identifier, sdx
			# get rid of whitespace for some drive names and ids, and extra data after - in name
			SCSI:
			foreach my $ref (@scsi){
				my %row = %$ref;
				if ($row{'model'}){
					$row{'model'} = (split /\s*-\s*/,$row{'model'})[0];
					foreach my $id (@by_id){
						if ($id =~ /$row{'model'}/ && "/dev/$drives[$i]{'id'}" eq Cwd::abs_path($id)){
							$drives[$i]{'firmware'} = $row{'firmware'};
							$drives[$i]{'model'} = $row{'model'};
							$drives[$i]{'vendor'} = $row{'vendor'};
							last SCSI;
						}
					}
				}
			}
		}
		# note: an entire class of model names gets truncated by /sys so that should be the last 
		# in priority re tests.
		elsif ( (!@disk_data || !$disk_data[0] ) && $block_type){
			# NOTE: while path ${working_path}vendor exists, it contains junk value, like: ATA
			$path = "${working_path}model";
			if ( -e $path){
				$model = (main::reader($path,'strip'))[0];
				if ($model){
					$drives[$i]{'model'} = $model;
				}
			}
			elsif ($block_type eq 'mmc' && -e "${working_path}name"){
				$path = "${working_path}name";
				$model = (main::reader($path,'strip'))[0];
				if ($model){
					$drives[$i]{'model'} = $model;
				}
			}
		}
		if (!$drives[$i]{'model'} && @disk_data){
			$drives[$i]{'model'} = $disk_data[0] if $disk_data[0];
			$drives[$i]{'vendor'} = $disk_data[1] if $disk_data[1];
		}
		# maybe rework logic if find good scsi data example, but for now use this
		elsif ($drives[$i]{'model'} && !$drives[$i]{'vendor'}) {
			$drives[$i]{'model'} = main::disk_cleaner($drives[$i]{'model'});
			my @device_data = device_vendor($drives[$i]{'model'},'');
			$drives[$i]{'model'} = $device_data[1] if $device_data[1];
			$drives[$i]{'vendor'} = $device_data[0] if $device_data[0];
		}
		if ($working_path){
			$path = "${working_path}removable";
			$drives[$i]{'type'} = 'Removable' if -e $path && (main::reader($path,'strip'))[0]; # 0/1 value
		}
		my $peripheral = peripheral_data($drives[$i]{'id'});
		# note: we only want to update type if we found a peripheral, otherwise preserve value
		$drives[$i]{'type'} = $peripheral if $peripheral;
		# print "type:$drives[$i]{'type'}\n";
		if ($extra > 0){
			$drives[$i]{'temp'} = hdd_temp("/dev/$drives[$i]{'id'}");
			if ($extra > 1){
				my @speed_data = device_speed($drives[$i]{'id'});
				$drives[$i]{'speed'} = $speed_data[0] if $speed_data[0];
				$drives[$i]{'lanes'} = $speed_data[1] if $speed_data[1];
				if (@disk_data && $disk_data[2]){
					$drives[$i]{'serial'} = $disk_data[2];
				}
				else {
					$path = "${working_path}serial";
					if ( -e $path){
						$serial = (main::reader($path,'strip'))[0];
						$drives[$i]{'serial'} = $serial if $serial;
					}
				}
				if ($extra > 2 && !$drives[$i]{'firmware'} ){
					my @fm = ('rev','fmrev','firmware_rev'); # 0 ~ default; 1 ~ mmc; 2 ~ nvme
					foreach my $firmware (@fm){
						$path = "${working_path}$firmware";
						if ( -e $path){
							$drives[$i]{'firmware'} = (main::reader($path,'strip'))[0];
							last;
						}
					}
				}
			}
		}
	}
	# print Data::Dumper::Dumper \@drives;
	eval $end if $b_log;
	return @drives;
}
# camcontrol identify <device> |grep ^serial (this might be (S)ATA specific)
# smartcl -i <device> |grep ^Serial
# see smartctl; camcontrol devlist; gptid status;
sub dmesg_boot_data {
	eval $start if $b_log;
	my ($used) = @_;
	my (@data,@drives,@temp);
	my ($id_holder,$i,$size,$working) = ('',0,0,0);
	my $file = main::system_files('dmesg-boot');
	if (@dm_boot_disk){
		foreach (@dm_boot_disk){
			my @row = split /:\s*/, $_;
			next if ! defined $row[1];
			if ($id_holder ne $row[0]){
				$i++ if $id_holder;
				# print "$i $id_holder $row[0]\n";
				$id_holder = $row[0];
			}
			# no dots, note: ada2: 2861588MB BUT: ada2: 600.000MB/s 
			if (! exists $drives[$i]){
				$drives[$i] = ({});
				$drives[$i]{'id'} = $row[0];
				$drives[$i]{'firmware'} = '';
				$drives[$i]{'temp'} = '';
				$drives[$i]{'type'} = '';
				$drives[$i]{'vendor'} = '';
			}
			#print "$i\n";
			if ($bsd_type eq 'openbsd'){
				if ($row[1] =~ /(^|,\s*)([0-9\.]+[MGTPE][B]?),.*\ssectors$|^</){
					$working = main::translate_size($2);
					$size += $working if $working;
					$drives[$i]{'size'} = $working;
				}
				if ($row[2] && $row[2] =~ /<([^>]+)>/){
					$drives[$i]{'model'} = $1 if $1;
					$drives[$i]{'type'} = 'removable' if $_ =~ /removable$/;
					# <Generic-, Compact Flash, 1.00>
					my $count = ($drives[$i]{'model'} =~ tr/,//);
					if ($count && $count > 1){
						@temp = split /,\s*/, $drives[$i]{'model'};
						$drives[$i]{'model'} = $temp[1];
					}
				}
				# print "openbsd\n";
			}
			else {
				if ($row[1] =~ /^([0-9]+[KMGTPE][B]?)\s/){
					$working = main::translate_size($1);
					$size += $working if $working;
					$drives[$i]{'size'} = $working;
				}
				if ($row[1] =~ /device$|^</){
					$row[1] =~ s/\sdevice$//g;
					$row[1] =~ /<([^>]*)>\s(.*)/;
					$drives[$i]{'model'} = $1 if $1;
					$drives[$i]{'spec'} = $2 if $2;
				}
				if ($row[1] =~ /^Serial\sNumber\s(.*)/){
					$drives[$i]{'serial'} = $1;
				}
				if ($row[1] =~ /^([0-9\.]+[MG][B]?\/s)/){
					$drives[$i]{'speed'} = $1;
					$drives[$i]{'speed'} =~ s/\.[0-9]+// if $drives[$i]{'speed'};
				}
			}
			$drives[$i]{'model'} = main::disk_cleaner($drives[$i]{'model'});
			my @device_data = device_vendor($drives[$i]{'model'},'');
			$drives[$i]{'vendor'} = $device_data[0] if $device_data[0];
			$drives[$i]{'model'} = $device_data[1] if $device_data[1];
		}
		if (!$size){
			$size = main::row_defaults('data-bsd');
		}
	}
	elsif ( $file && ! -r $file ){
		$size = main::row_defaults('dmesg-boot-permissions');
	}
	elsif (!$file ){
		$size = main::row_defaults('dmesg-boot-missing');
	}
	@data = ({
	'size' => $size,
	'used' => $used,
	});
	#main::log_data('dump','@data',\@data) if $b_log;
	if ( $show{'disk'} ){
		@data = (@data,@drives);
		# print 'drives:', Data::Dumper::Dumper \@drives;
	}
	# print Data::Dumper::Dumper \@data;
	eval $end if $b_log;
	return @data;
}

sub smartctl_data {
	eval $start if $b_log;
	my (@data) = @_;
	my ($b_attributes,$b_intel,$b_kingston,$cmd,%holder,$id,@working,@result,@split);
	my ($splitter,$num,$a,$f,$r,$t,$v,$w,$y) = (':\s*',0,0,8,1,5,3,4,6); # $y is type, $t threashold, etc
	my $smartctl = main::check_program('smartctl');
	for (my $i = 0; $i < scalar @data; $i++){
		next if !$data[$i]{'id'};
		($b_attributes,$b_intel,$b_kingston,$splitter,$num,$a,$r) = (0,0,0,':\s*',0,0,1);
		%holder = ();
		#print $data[$i]{'id'},"\n";
		# m2 nvme failed on nvme0n1 drive id:
		$id = $data[$i]{'id'};
		$id =~ s/n[0-9]+$// if $id =~ /^nvme/;
		$cmd = "$smartctl -AHi /dev/" . $id . ' 2>/dev/null';
		@result = main::grabber("$cmd", '', 'strip');
		main::log_data('dump','@result', \@result) if $b_log; # log before cleanup
		@result = grep {!/^(smartctl|Copyright|==)/} @result;
		print 'Drive:/dev/' . $id . ":\n", Data::Dumper::Dumper\@result if $test[12];
		if (scalar @result < 4 ){
			if (grep {/failed: permission denied/i} @result){
				$data[$i]{'smart-permissions'} = main::row_defaults('tool-permissions','smartctl');
			}
			elsif (grep {/unknown usb bridge/i} @result){
				$data[$i]{'smart-error'} = main::row_defaults('smartctl-usb');
			}
			elsif (grep {/A mandatory SMART command failed/i} @result){
				$data[$i]{'smart-error'} = main::row_defaults('smartctl-command-failed');
			}
			else {
				$data[$i]{'smart-error'} = main::row_defaults('tool-unknown-error','smartctl');
			}
			next;
		}
		else {
			foreach my $row (@result){
				if ($row =~ /^ID#/){
					$splitter = '\s+';
					$b_attributes = 1;
					$a = 1;
					$r = 9;
					next;
				}
				@split = split /$splitter/, $row;
				next if !$b_attributes && ! defined $split[$r];
				# some cases where drive not in db threshhold will be: ---
				# value is usually 0 padded which confuses perl. However this will
				# make subsequent tests easier, and will strip off leading 0s
				if ($b_attributes){
					$split[$t] = (main::is_numeric($split[$t])) ? int($split[$t]) : 0;
					$split[$v] = (main::is_numeric($split[$v])) ? int($split[$v]) : 0;
				}
				## DEVICE INFO ##
				if ($split[$a] eq 'Device Model'){
					$b_intel = 1 if $split[$r] =~/\bintel\b/i;
					$b_kingston = 1 if $split[$r] =~/kingston/i;
					# usb/firewire/thunderbolt
					if ($data[$i]{'type'}){
						@working = device_vendor("$split[$r]");
						$data[$i]{'drive-model'} = $working[1] if $data[$i]{'model'} && $data[$i]{'model'} ne $working[1];
						$data[$i]{'drive-vendor'} = $working[0] if $data[$i]{'vendor'} && $data[$i]{'vendor'} ne $working[0];
					}
				}
				elsif ($split[$a] eq 'Model Family'){
					@working = device_vendor("$split[$r]");
					$data[$i]{'family'} = $working[1];
					# $data[$i]{'family'} =~ s/$data[$i]{'vendor'}\s*// if $data[$i]{'vendor'};
				}
				elsif ($split[$a] eq 'Firmware Version'){
					# 01.01A01 vs 1A01
					if ($data[$i]{'firmware'} && $split[$r] !~ /$data[$i]{'firmware'}/){
						$data[$i]{'drive-firmware'} = $split[$r];
					}
					elsif (!$data[$i]{'firmware'}){
						$data[$i]{'firmware'} = $split[$r];
					}
				}
				elsif ($split[$a] eq 'Rotation Rate'){
					$data[$i]{'rotation'} = $split[$r] if $split[$r] !~ /^Solid/;
				}
				elsif ($split[$a] eq 'Serial Number'){
					if ( !$data[$i]{'serial'}){
						$data[$i]{'serial'} = $split[$r];
					}
					elsif ($data[$i]{'type'} && $split[$r] ne $data[$i]{'serial'}){
						$data[$i]{'drive-serial'} = $split[$r];
					}
				}
				elsif ($split[$a] eq 'SATA Version is'){
					if ( $split[$r] =~ /SATA ([0-9.]+), ([0-9.]+ [^\s]+)( \(current: ([1-9.]+ [^\s]+)\))?/){
						$data[$i]{'sata'} = $1;
						$data[$i]{'speed'} = $2 if !$data[$i]{'speed'};
					}
				}
				elsif ($split[$a] eq 'Sector Sizes'){
					if( $data[$i]{'type'} || !$data[$i]{'block-logical'} || !$data[$i]{'block-physical'} ){
						if ($split[$r] =~ m|^([0-9]+) bytes logical/physical| ){
							$data[$i]{'block-logical'} = $1;
							$data[$i]{'block-physical'} = $1;
						}
						# 512 bytes logical, 4096 bytes physical
						elsif ($split[$r] =~ m|^([0-9]+) bytes logical, ([0-9]+) bytes physical|){
							$data[$i]{'block-logical'} = $1;
							$data[$i]{'block-physical'} = $2;
						}
					}
				}
				## SMART STATUS/HEALTH ##
				elsif ($split[$a] eq 'SMART support is'){
					if ($split[$r] =~ /^(Available|Unavailable) /){
						$data[$i]{'smart'} = $1;
						$data[$i]{'smart'} = ($data[$i]{'smart'} eq 'Unavailable') ? 'no' : 'yes';
					}
					elsif ($split[$r] =~ /^(Enabled|Disabled)/ ){
						$data[$i]{'smart-support'} = lc($1);
					}
				}
				elsif ($split[$a] eq 'SMART overall-health self-assessment test result' ){
					$data[$i]{'smart-status'} = $split[$r];
					# seen nvme that only report smart health, not smart support
					$data[$i]{'smart'} = 'yes' if !$data[$i]{'smart'};
				}
				
				## DEVICE CONDITION: temp/read/write/power on/cycles ##
				# Attributes data fields, sometimes are same syntax as info block:...
				elsif ( $split[$a] eq 'Power_Cycle_Count' || $split[$a] eq 'Power Cycles' ){
					$data[$i]{'smart-cycles'} = $split[$r] if $split[$r];
				}
				elsif ($split[$a] eq 'Power_On_Hours' || $split[$a] eq 'Power On Hours' ||
				 $split[$a] eq 'Power_On_Hours_and_Msec'){
					if ($split[$r]){
						$split[$r] =~ s/,//;
						# trim off: h+0m+00.000s which is useless and at times empty anyway
						$split[$r] =~ s/h\+.*$// if $split[$a] eq 'Power_On_Hours_and_Msec';
						# $split[$r] = 43;
						if ($split[$r] =~ /^([0-9]+)$/){
							if ($1 > 9000){
								$data[$i]{'smart-power-on-hours'} = int($1/(24*365)) . 'y ' . int($1/24)%365 . 'd ' . $1%24 . 'h';
							}
							elsif ($1 > 100){
								$data[$i]{'smart-power-on-hours'} = int($1/24) . 'd ' . $1%24 . 'h';
							}
							else {
								$data[$i]{'smart-power-on-hours'} = $split[$r] . ' hrs';
							}
						}
						else {
							$data[$i]{'smart-power-on-hours'} = $split[$r];
						}
					}
				}
				# 'Airflow_Temperature_Cel' like: 29 (Min/Max 14/43) so can't use -1 index
				# Temperature like 29 Celsisu
				elsif ( $split[$a] eq 'Temperature_Celsius' || $split[$a] eq 'Temperature' ||
				  $split[$a] eq 'Airflow_Temperature_Cel' ) {
					if (!$data[$i]{'temp'} && $split[$r]){
						$data[$i]{'temp'} = $split[$r];
					}
				}
				## DEVICE USE: Reads/Writes ##
				elsif ($split[$a] eq 'Data Units Read'){
					$data[$i]{'smart-units-read'} = $split[$r];
				}
				elsif ($split[$a] eq 'Data Units Written'){
					$data[$i]{'smart-units-written'} = $split[$r];
				}
				elsif ($split[$a] eq 'Host_Reads_32MiB'){
					$split[$r] = $split[$r] * 32 * 1024;
					$data[$i]{'smart-read'} = join ' ', main::get_size($split[$r]);
				}
				elsif ($split[$a] eq 'Host_Writes_32MiB'){
					$split[$r] = $split[$r] * 32 * 1024;
					$data[$i]{'smart-written'} = join ' ', main::get_size($split[$r]);
				}
				elsif ($split[$a] eq 'Lifetime_Reads_GiB'){
					$data[$i]{'smart-read'} = $split[$r] . ' GiB';
				}
				elsif ($split[$a] eq 'Lifetime_Writes_GiB'){
					$data[$i]{'smart-written'} = $split[$r] . ' GiB';
				}
				elsif ($split[$a] eq 'Total_LBAs_Read'){
					if (main::is_numeric($split[$r])){
						# blocks in bytes, so convert to KiB, the internal unit here
						# reports in 32MiB units, sigh
						if ($b_intel){
							$split[$r] = $split[$r] * 32 * 1024;
						}
						# reports in 1 GiB units, sigh
						elsif ($b_kingston){
							$split[$r] = $split[$r] * 1024 * 1024;
						}
						# this is what it's supposed to refer to
						else {
							$split[$r] = int($data[$i]{'block-logical'} * $split[$r] / 1024);
						}
						$data[$i]{'smart-read'} = join ' ', main::get_size($split[$r]);
					}
				}
				elsif ($split[$a] eq 'Total_LBAs_Written'){
					if (main::is_numeric($split[$r])){
						# blocks in bytes, so convert to KiB, the internal unit here
						# reports in 32MoB units, sigh
						if ($b_intel){
							$split[$r] = $split[$r] * 32 * 1024;
						}
						# reports in 1 GiB units, sigh
						elsif ($b_kingston){
							$split[$r] = $split[$r] * 1024 * 1024;
						}
						# this is what it's supposed to refer to, in byte blocks
						else {
							$split[$r] = int($data[$i]{'block-logical'} * $split[$r] / 1024);
						}
						$data[$i]{'smart-written'} = join ' ', main::get_size($split[$r]);
					}
				}
				
				## DEVICE OLD AGE ##
				# 191 G-Sense_Error_Rate 0x0032 001 001 000 Old_age Always - 291
				elsif ($split[$a] eq 'G-Sense_Error_Rate'){
					# $data[$i]{'smart-media-wearout'} = $split[$r];
					if ($b_attributes && $split[$r] > 100){
						$data[$i]{'smart-gsense-error-rate-r'} = $split[$r];
					}
				}
				elsif ($split[$a] eq 'Media_Wearout_Indicator'){
					# $data[$i]{'smart-media-wearout'} = $split[$r];
					# seen case where they used hex numbers becaause values
					# were in 47 billion range in hex. You can't hand perl an unquoted
					# hex number that is > 2^32 without tripping a perl warning
					if ($b_attributes && $split[$r] && !main::is_hex("$split[$r]") && $split[$r] > 0){
						$data[$i]{'smart-media-wearout-v'} = $split[$v];
						$data[$i]{'smart-media-wearout-t'} = $split[$t];
						$data[$i]{'smart-media-wearout-f'} = $split[$f] if $split[$f] ne '-';
					}
				}
				elsif ($split[$a] eq 'Multi_Zone_Error_Rate'){
					# note: all t values are 0 that I have seen
					if ( ($split[$v] - $split[$t]) < 50){
						$data[$i]{'smart-multizone-errors-v'} = $split[$v];
						$data[$i]{'smart-multizone-errors-t'} = $split[$v];
					}
					
				}
				elsif ($split[$a] eq 'UDMA_CRC_Error_Count'){
					if (main::is_numeric($split[$r]) && $split[$r] > 50){
						$data[$i]{'smart-udma-crc-errors-r'} = $split[$r];
						$data[$i]{'smart-udma-crc-errors-f'} = main::row_defaults('smartctl-udma-crc') if $split[$r] > 500;
					}
				}
				
				## DEVICE PRE-FAIL ##
				elsif ($split[$a] eq 'Available_Reservd_Space'){
					# $data[$i]{'smart-available-reserved-space'} = $split[$r];
					if ($b_attributes && $split[$v] && $split[$t] && $split[$t]/$split[$v] > 0.92){
						$data[$i]{'smart-available-reserved-space-v'} = $split[$v];
						$data[$i]{'smart-available-reserved-space-t'} = $split[$t];
						$data[$i]{'smart-available-reserved-space-f'} = $split[$f] if $split[$f] ne '-';
					}
				}
				## nvme splits these into two field/value sets
				elsif ($split[$a] eq 'Available Spare'){
					$split[$r] =~ s/%$//;
					$holder{'spare'} = int($split[$r]) if main::is_numeric($split[$r]);
				}
				elsif ($split[$a] eq 'Available Spare Threshold'){
					$split[$r] =~ s/%$//;
					if ($holder{'spare'} && main::is_numeric($split[$r]) && $split[$r]/$holder{'spare'} > 0.92 ){
						$data[$i]{'smart-available-reserved-space-v'} = $holder{'spare'};
						$data[$i]{'smart-available-reserved-space-t'} = int($split[$r]);
					}
				}
				elsif ($split[$a] eq 'End-to-End_Error'){
					if ($b_attributes && int($split[$r]) > 0 && $split[$t]){
						$data[$i]{'smart-end-to-end-v'} = $split[$v];
						$data[$i]{'smart-end-to-end-t'} = $split[$t];
						$data[$i]{'smart-end-to-end-f'} = $split[$f] if $split[$f] ne '-';
					}
				}
				# seen raw value: 0/8415644
				elsif ($split[$a] eq 'Raw_Read_Error_Rate'){
					if ($b_attributes && $split[$v] && $split[$t] && $split[$t]/$split[$v] > 0.92){
						$data[$i]{'smart-raw-read-error-rate-v'} = $split[$v];
						$data[$i]{'smart-raw-read-error-rate-t'} = $split[$t];
						$data[$i]{'smart-raw-read-error-rate-f'} = $split[$f] if $split[$f] ne '-';
					}
				}
				elsif ($split[$a] eq 'Reallocated_Sector_Ct'){
					if ($b_attributes && int($split[$r]) > 0 && $split[$t]){
						$data[$i]{'smart-reallocated-sectors-v'} = $split[$v];
						$data[$i]{'smart-reallocated-sectors-t'} = $split[$t];
						$data[$i]{'smart-reallocated-sectors-f'} = $split[$f] if $split[$f] ne '-';
					}
				}
				elsif ($split[$a] eq 'Retired_Block_Count'){
					if ($b_attributes && int($split[$r]) > 0 && $split[$t]){
						$data[$i]{'smart-retired-blocks-v'} = $split[$v];
						$data[$i]{'smart-retired-blocks-t'} = $split[$t];
						$data[$i]{'smart-retired-blocks-f'} = $split[$f] if $split[$f] ne '-';
					}
				}
				elsif ($split[$a] eq 'Runtime_Bad_Block'){
					if ($b_attributes && $split[$v] && $split[$t] && $split[$t]/$split[$v] > 0.92 ){
						$data[$i]{'smart-runtime-bad-block-v'} = $split[$v];
						$data[$i]{'smart-runtime-bad-block-t'} = $split[$t];
						$data[$i]{'smart-runtime-bad-block-f'} = $split[$f] if $split[$f] ne '-';
					}
				}
				elsif ($split[$a] eq 'Seek_Error_Rate'){
					# value 72; threshold either 000 or 30
					if ($b_attributes && $split[$v] && $split[$t] && $split[$t]/$split[$v] > 0.92 ){
						$data[$i]{'smart-seek-error-rate-v'} = $split[$v];
						$data[$i]{'smart-seek-error-rate-t'} = $split[$t];
						$data[$i]{'smart-seek-error-rate-f'} = $split[$f] if $split[$f] ne '-';
					}
				}
				elsif ($split[$a] eq 'Spin_Up_Time'){
					# raw will always be > 0 on spinning disks
					if ($b_attributes && $split[$v] && $split[$t] && $split[$t]/$split[$v] > 0.92 ){
						$data[$i]{'smart-spinup-time-v'} = $split[$v];
						$data[$i]{'smart-spinup-time-t'} = $split[$t];
						$data[$i]{'smart-spinup-time-f'} = $split[$f] if $split[$f] ne '-';
					}
				}
				elsif ($split[$a] eq 'SSD_Life_Left'){
					# raw will always be > 0 on spinning disks
					if ($b_attributes && $split[$v] && $split[$t] && $split[$t]/$split[$v] > 0.92 ){
						$data[$i]{'smart-ssd-life-left-v'} = $split[$v];
						$data[$i]{'smart-ssd-life-left-t'} = $split[$t];
						$data[$i]{'smart-ssd-life-left-f'} = $split[$f] if $split[$f] ne '-';
					}
				}
				elsif ($split[$a] eq 'Unused_Rsvd_Blk_Cnt_Tot'){
					# raw will always be > 0 on spinning disks
					if ($b_attributes && $split[$v] && $split[$t] && $split[$t]/$split[$v] > 0.92 ){
						$data[$i]{'smart-unused-reserve-block-v'} = $split[$v];
						$data[$i]{'smart-unused-reserve-block-t'} = $split[$t];
						$data[$i]{'smart-unused-reserve-block-f'} = $split[$f] if $split[$f] ne '-';
					}
				}
				elsif ($split[$a] eq 'Used_Rsvd_Blk_Cnt_Tot'){
					# raw will always be > 0 on spinning disks
					if ($b_attributes && $split[$v] && $split[$t] && $split[$t]/$split[$v] > 0.92 ){
						$data[$i]{'smart-used-reserve-block-v'} = $split[$v];
						$data[$i]{'smart-used-reserve-block-t'} = $split[$t];
						$data[$i]{'smart-used-reserve-block-f'} = $split[$f] if $split[$f] ne '-';
					}
				}
				elsif ($b_attributes ){
					if ( $split[$y] eq 'Pre-fail' && ($split[$f] ne '-' ||
					 ($split[$t] && $split[$v] && $split[$t]/$split[$v] > 0.92 ))) {
						$num++;
						$data[$i]{'smart-unknown-' . $num . '-a'} = $split[$a];
						$data[$i]{'smart-unknown-' . $num . '-v'} = $split[$v];
						$data[$i]{'smart-unknown-' . $num . '-w'} = $split[$v];
						$data[$i]{'smart-unknown-' . $num . '-t'} = $split[$t];
						$data[$i]{'smart-unknown-' . $num . '-f'} = $split[$f] if $split[$f] ne '-';
					}
				}
			}
		}
	}
	print Data::Dumper::Dumper\@data if $test[19];
	eval $end if $b_log;
	return @data;
}

# check for usb/firewire/[and thunderwire when data found]
sub peripheral_data {
	eval $start if $b_log;
	my ($id) = @_;
	my ($type) = ('');
	# print "$id here\n";
	if (@by_id){
		foreach (@by_id) {
			if ("/dev/$id" eq Cwd::abs_path($_)){
				#print "$id here\n";
				if (/usb-/i){
					$type = 'USB';
				}
				elsif (/ieee1394-/i){
					$type = 'FireWire';
				}
				last;
			}
		}
	}
	# note: sometimes with wwn- numbering usb does not appear in by-id but it does in by-path
	if (!$type && @by_path){
		foreach (@by_path) {
			if ("/dev/$id" eq Cwd::abs_path($_)){
				if (/usb-/i){
					$type = 'USB';
				}
				elsif (/ieee1394--/i){
					$type = 'FireWire';
				}
				last;
			}
		}
	}
	eval $end if $b_log;
	return $type;
}
sub advanced_disk_data {
	eval $start if $b_log;
	my ($set_cmd,$id) = @_;
	my ($cmd,$pt,$program,@data,@return);
	if ($set_cmd ne 'unset'){
		$return[0] = $set_cmd;
	}
	else {
		# runs as user, but is SLOW: udisksctl info -b /dev/sda
		# line: org.freedesktop.UDisks2.PartitionTable:
		# Type:               dos
		if ($program = main::check_program('udevadm')){
			$return[0] = "$program info -q property -n ";
		}
		elsif ($b_root && -e "/lib/udev/udisks-part-id") {
			$return[0] = "/lib/udev/udisks-part-id /dev/";
		}
		elsif ($b_root && ($program = main::check_program('fdisk'))) {
			$return[0] = "$program -l /dev/";
		}
		if (!$return[0]) {
			$return[0] = 'na'
		}
	}
	if ($return[0] ne 'na'){
		$cmd = "$return[0]$id 2>&1";
		main::log_data('cmd',$cmd) if $b_log;
		@data = main::grabber($cmd);
		# for pre ~ 2.30 fdisk did not show gpt, but did show gpt scheme error, so
		# if no gpt match, it's dos = mbr
		if ($cmd =~ /fdisk/){
			foreach (@data){
				if (/^WARNING:\s+GPT/){
					$return[1] = 'gpt';
					last;
				}
				elsif (/^Disklabel\stype:\s*(.+)/i){
					$return[1] = $1;
					last;
				}
			}
			$return[1] = 'dos' if !$return[1];
		}
		else {
			foreach (@data){
				if ( /^(UDISKS_PARTITION_TABLE_SCHEME|ID_PART_TABLE_TYPE)/ ){
					my @working = split /=/, $_;
					$return[1] = $working[1];
				}
				elsif (/^ID_ATA_ROTATION_RATE_RPM/){
					my @working = split /=/, $_;
					$return[2] = $working[1];
				}
				last if $return[1] && $return[2];
			}
		}
		$return[1] = 'mbr' if $return[1] && lc($return[1]) eq 'dos';
	}
	eval $end if $b_log;
	return @return;
}
sub scsi_data {
	eval $start if $b_log;
	my ($file) = @_;
	my @temp = main::reader($file);
	my (@scsi);
	my ($firmware,$model,$vendor) = ('','','');
	foreach (@temp){
		if (/Vendor:\s*(.*)\s+Model:\s*(.*)\s+Rev:\s*(.*)/i){
			$vendor = $1;
			$model = $2;
			$firmware = $3;
		}
		if (/Type:/i){
			if (/Type:\s*Direct-Access/i){
				my @working = ({
				'vendor' => $vendor,
				'model' => $model,
				'firmware' => $firmware,
				});
				@scsi = (@scsi,@working);
			}
			else {
				($firmware,$model,$vendor) = ('','','');
			}
		}
	}
	main::log_data('dump','@scsi', \@scsi) if $b_log;
	eval $end if $b_log;
	return @scsi;
}
# @b_id has already been cleaned of partitions, wwn-, nvme-eui
sub disk_data_by_id {
	eval $start if $b_log;
	my ($device) = @_;
	my ($model,$serial,$vendor) = ('','','');
	my (@disk_data);
	foreach (@by_id){
		if ($device eq Cwd::abs_path($_)){
			my @data = split /_/, $_;
			my @device_data = ();
			last if scalar @data < 2; # scsi-3600508e000000000876995df43efa500
			$serial = pop @data if @data;
			# usb-PNY_USB_3.0_FD_3715202280-0:0
			$serial =~ s/-[0-9]+:[0-9]+$//;
			$model = join ' ', @data;
			# get rid of the ata-|nvme-|mmc- etc
			$model =~ s/^\/dev\/disk\/by-id\/([^-]+-)?//;
			$model = main::disk_cleaner($model);
			@device_data = device_vendor($model,$serial);
			$vendor = $device_data[0] if $device_data[0];
			$model = $device_data[1] if $device_data[1];
			# print $device, '::', Cwd::abs_path($_),'::', $model, '::', $vendor, '::', $serial, "\n";
			(@disk_data) = ($model,$vendor,$serial);
			last;
		}
	}
	eval $end if $b_log;
	return @disk_data;
}
# 0 - match pattern; 1 - replace pattern; 2 - vendor print; 3 - serial pattern
sub set_vendors {
	eval $start if $b_log;
	@vendors = (
	## These go first because they are the most likely and common ##
	['(Crucial|^(FC)?CT|-CT|^M4\b|Gizmo!)','Crucial','Crucial',''],
	# H10 HBRPEKNX0202A NVMe INTEL 512GB
	['(\bINTEL\b|^SSD(PAM|SA2))','\bINTEL\b','Intel',''], 
	# note: S[AV][1-9][0-9] can trigger false positives
	['(KINGSTON|DataTraveler|DT\s?(DUO|Microduo|101)|^SMS|^SHS|^SS0|^SUV|^Ultimate CF|HyperX|^S[AV][1234]00|^SKYMEDI)','KINGSTON','Kingston',''], # maybe SHS: SHSS37A SKC SUV
	# must come before samsung MU. NOTE: toshiba can have: TOSHIBA_MK6475GSX: mush: MKNSSDCR120GB_
	['(^MKN|Mushkin)','Mushkin','Mushkin',''], # MKNS
	# MU = Multiple_Flash_Reader too risky: |M[UZ][^L] HD103SI HD start risky
	# HM320II HM320II
	['(SAMSUNG|^MCG[0-9]+GC|^MCC|^MCBOE|\bEVO\b|^[GS]2 Portable|^DS20|^[DG]3 Station|^DUO\b|^P3|^BGN|^[CD]JN|^BJ[NT]|^[BC]WB|^(HM|SP)[0-9]{2}|^MZMPC|^HD[0-9]{3}[A-Z]{2}$)','SAMSUNG','Samsung',''], # maybe ^SM, ^HM
	# Android UMS Composite?
	['(SanDisk|^SDS[S]?[DQ]|^D[AB]4|^SL([0-9]+)G|^AFGCE|^ABLCD|^SDW[1-9]|^U3\b|ULTRA\sFIT|Clip Sport|Cruzer|^Extreme)','SanDisk','SanDisk',''],
	['^STEC\b','^STEC\b','STEC',''], # ssd drive, must come before seagate ST test
	# real, SSEAGATE Backup+; XP1600HE30002 | 024 HN (spinpoint)
	['(^ST[^T]|[S]?SEAGATE|^X[AFP]|^5AS|^BUP|Expansion Desk|^Expansion|FreeAgent|GoFlex|Backup(\+|\s?Plus)\s?(Hub)?|OneTouch)','[S]?SEAGATE','Seagate',''], 
	['^(WD|WL[0]9]|Western Digital|My (Book|Passport)|\d*LPCX|Elements|easystore|MD0|M000|EARX|EFRX|\d*EAVS|0JD|JPVX|[0-9]+(BEV|(00)?AAK|AAV|AZL|EA[CD]S)|3200[AB]|2500[BJ]|5000[AB]|6400[AB]|7500[AB]|i HTS)','(^WDC|Western\s?Digital)','Western Digital',''],
	## Then better known ones ##
	['^(A-DATA|ADATA|AX[MN]|CH11|HV[1-9]|IM2)','^(A-DATA|ADATA)','A-Data',''],
	['^ASUS','^ASUS','ASUS',''],
	# ATCS05 can be hitachi travelstar but not sure
	['^ATP','^ATP\b','ATP',''],
	# Force MP500
	['^(Corsair|Force\s|(Flash\s*)?(Survivor|Voyager))','^Corsair','Corsair',''],
	# MAB3045SP shows as HP or Fujitsu, probably HP branded fujitsu
	['^(FUJITSU|MJA|MH[TVWYZ][0-9]|MP|MAP[0-9])','^FUJITSU','Fujitsu',''],
	# note: 2012:  wdc bought hgst
	['^(HGST|Touro|54[15]0|7250)','^HGST','HGST (Hitachi)',''], # HGST HUA
	['^(Hitachi|HCS|HD[PST]|DK[0-9]|IC|HT|HU|HMS)','^Hitachi','Hitachi',''], 
	# vb: VB0250EAVER but clashes with vbox; HP_SSD_S700_120G ;GB0500EAFYL GB starter too generic?
	# DX110064A5xnNMRI ids as HP and Sandisc, same ID, made by sandisc for hp? not sure
	['^(HP\b|[MV]B[0-6]|G[BJ][01]|DF|0-9]|FK|0-9]|PSS|v[0-9]{3}[bgorw]$|x[0-9]{3}[w]$)','^HP','HP',''], 
	['^(Lexar|LSD|JumpDrive|JD\s?Firefly|WorkFlow)','^Lexar','Lexar',''], # mmc-LEXAR_0xb016546c; JD Firefly;
	# OCZSSD2-2VTXE120G is OCZ-VERTEX2_3.5
	['^(OCZ|APOC|D2|DEN|DEN|DRSAK|EC188|FTNC|GFGC|MANG|MMOC|NIMC|NIMR|PSIR|RALLY2|TALOS2|TMSC|TRSAK)','^OCZ[\s-]','OCZ',''],
	['^OWC','^OWC\b','OWC',''],
	['^(Philips|GoGear)','^Philips','Philips',''],
	['^PIONEER','^PIONEER','Pioneer',''],
	['^(PNY|Hook\s?Attache|SSD2SC)','^PNY\s','PNY','','^PNY'],
	# note: get rid of: M[DGK] becasue mushkin starts with MK
	# note: seen: KXG50ZNV512G NVMe TOSHIBA 512GB | THNSN51T02DUK NVMe TOSHIBA 1024GB
	['(^[S]?TOS|^THN|TOSHIBA|TransMemory|^M[GKQ][0-9]|KBG4)','[S]?TOSHIBA','Toshiba',''], # scsi-STOSHIBA_STOR.E_EDITION_
	## These go last because they are short and could lead to false ID, or are unlikely ##
	# unknown: AL25744_12345678; ADP may be usb 2.5" adapter; udisk unknown: Z1E6FTKJ 00AAKS
	# SSD2SC240G726A10 MRS020A128GTS25C EHSAJM0016GB
	['^5ACE','^5ACE','5ACE',''], # could be seagate: ST316021 5ACE
	['^(AbonMax|ASU[0-9])','^AbonMax','AbonMax',''],
	['^Acasis','^Acasis','Acasis (hub)',''],
	['^Addlink','^Addlink','Addlink',''],
	['^ADTRON','^(ADTRON)','Adtron',''],
	['^(Advantech|SQF)','^Advantech','Advantech',''],
	['^Aireye','^Aireye','Aireye',''],
	['^Alcatel','^Alcatel','Alcatel',''],
	['^Alfawise','^Alfawise','Alfawise',''],
	['^Android','^Android','Android',''],
	['^ANACOMDA','^ANACOMDA','ANACOMDA',''],
	['^Apotop','^Apotop','Apotop',''],
	# must come before AP|Apacer
	['^(APPLE|iPod)','^APPLE','Apple',''],
	['^(AP|Apacer)','^Apacer','Apacer',''],
	['^(A-?RAM|ARSSD)','^A-?RAM','A-RAM',''],
	['^Arch','^Arch(\s*Memory)?','Arch Memory',''],
	['^(Asenno|AS[1-9])','^Asenno','Asenno',''],
	['^Asgard','^Asgard','Asgard',''],
	['^(ASM|2115)','^ASM','ASMedia',''],#asm1153e
	['^(AVEXIR|AVSSD)','^AVEXIR','Avexir',''],
	['^Axiom','^Axiom','Axiom',''],
	['^Bell\b','^Bell','Packard Bell',''],
	['^(BelovedkaiAE|GhostPen)','^BelovedkaiAE','BelovedkaiAE',''],
	['^BHT','^BHT','BHT',''],
	['^BIOSTAR','^BIOSTAR','Biostar',''],
	['^BIWIN','^BIWIN','BIWIN',''],
	['^Blackpcs','^Blackpcs','Blackpcs',''],
	['^(MyDigitalSSD|BP4)','^MyDigitalSSD','MyDigitalSSD',''], # BP4 = BulletProof4
	['^Braveeagle','^Braveeagle','BraveEagle',''],
	['^(BUFFALO|BSC)','^BUFFALO','Buffalo',''], # usb: BSCR05TU2
	['^Bulldozer','^Bulldozer','Bulldozer',''],
	['^BUSlink','^BUSlink','BUSlink',''],
	['^Centerm','^Centerm','Centerm',''],
	['^Centon','^Centon','Centon',''],
	['^CHN\b','','Zheino',''],
	['^Clover','^Clover','Clover',''],
	['^Colorful\b','^Colorful','Colorful',''],
	# note: www.cornbuy.com is both a brand and also sells other brands, like newegg
	# addlink; colorful; goldenfir; kodkak; maxson; netac; teclast; vaseky
	['^Corn','^Corn','Corn',''],
	['^CnMemory|Spaceloop','^CnMemory','CnMemory',''],
	['^CSD','^CSD','CSD',''],
	['^(Dane-?Elec|Z Mate)','^Dane-?Elec','DaneElec',''],
	['^DATABAR','^DATABAR','DataBar',''],
	# Daplink vfs is an ARM software thing
	['^Dataram','^Dataram','Dataram',''],
	# DataStation can be Trekstore or I/O gear
	['^Dell\b','^Dell','Dell',''],
	['^DeLOCK','^Delock(\s?products)?','Delock',''],
	['^Derler','^Derler','Derler',''],
	['^detech','^detech','DETech',''],
	['^DGM','^DGM\b','DGM',''],
	['^Digifast','^Digifast','Digifast',''],
	['^DIGITAL\s?FILM','DIGITAL\s?FILM','Digital Film',''],
	['^(Dogfish|Shark)','^Dogfish(\s*Technology)?','Dogfish Technolgy',''],
	['^DragonDiamond','^DragonDiamond','DragonDiamond',''],
	['^DREVO\b','^DREVO','Drevo',''],
	# DX1100 is probably sandisk, but could be HP, or it could be hp branded sandisk
	['^(Eaget|V8$)','^Eaget','Eaget',''],
	['^EDGE','^EDGE','EDGE Tech',''],
	['^Elecom','^Elecom','Elecom',''],
	['^Eluktro','^Eluktronics','Eluktronics',''],
	['^Emperor','^Emperor','Emperor',''],
	['^Emtec','^Emtec','Emtec',''],
	['^Epson','^Epson','Epson',''],
	['^EXCELSTOR','^EXCELSTOR( TECHNO(LOGY)?)?','ExcelStor',''],
	['^EZLINK','^EZLINK','EZLINK',''],
	['^Fantom','^Fantom( Drive[s]?)?','Fantom Drives',''],
	['^Faspeed','^Faspeed','Faspeed',''],
	['^FASTDISK','^FASTDISK','FASTDISK',''],
	['^Fordisk','^Fordisk','Fordisk',''],
	# FK0032CAAZP/FB160C4081 FK or FV can be HP but can be other things
	['^FORESEE','^FORESEE','Foresee',''],
	['^(FOXLINE|FLD)','^FOXLINE','Foxline',''], # russian vendor?
	['^(GALAX\b|Gamer\s?L)','^GALAX','GALAX',''],
	['^Galaxy\b','^Galaxy','Galaxy',''],
	['^(Garmin|Fenix|Nuvi|Zumo)','^Garmin','Garmin',''],
	['^Geil','^Geil','Geil',''],
	['^Generic','^Generic','Generic',''],
	['^Gigabyte','^Gigabyte','Gigabyte',''], # SSD
	['^Gigastone','^Gigastone','Gigastone',''],
	['^Gloway','^Gloway','Gloway',''],
	['^Goldendisk','^Goldendisk','Goldendisk',''],
	['^Goldenfir','^Goldenfir','Goldenfir',''],
	# Wilk Elektronik SA, poland
	['^(Wilk\s*)?(GOODRAM|GOODDRIVE|IR[\s-]?SSD|IRP|SSDPR)','^GOODRAM','GOODRAM',''],
	# supertalent also has FM: |FM
	['^(G[\.]?SKILL)','^G[\.]?SKILL','G.SKILL',''],
	['^G[\s-]*Tech','^G[\s-]*Technology','G-Technology',''],
	['^HDC','^HDC\b','HDC',''],
	['^Hectron','^Hectron','Hectron',''],
	['^HEMA','^HEMA','HEMA',''],
	['^(Hikvision|HKVSN)','^Hikvision','Hikvision',''],
	['^Hoodisk','^Hoodisk','Hoodisk',''],
	['^HUAWEI','^HUAWEI','Huawei',''],
	['^HyperX','^HyperX','HyperX',''],
	['^Hyundai','^Hyundai','Hyundai',''],
	['^(IBM|DT)','^IBM','IBM',''], 
	['^IEI Tech','^IEI Tech(\.|nology)?( Corp(\.|oration)?)?','IEI Technology',''],
	['^(Imation|Nano\s?Pro|HQT)','^Imation(\sImation)?','Imation',''], # Imation_ImationFlashDrive; TF20 is imation/tdk
	['^(Inca\b|Npenterprise)','^Inca','Inca',''],
	['^INDMEM','^INDMEM','INDMEM',''],
	['^Inland','^Inland','Inland',''],
	['^(InnoDisk|Innolite)','^InnoDisk( Corp.)?','InnoDisk',''],
	['^Innostor','^Innostor','Innostor',''],
	['^Innovation','^Innovation','Innovation',''],
	['^Innovera','^Innovera','Innovera',''],
	['^Intaiel','^Intaiel','Intaiel',''],
	['^(INM|Integral|V\s?Series)','^Integral(\s?Memory)?','Integral Memory',''],
	['^(lntenso|Intenso|(Alu|Basic|Business|Micro|Mobile|Rainbow|Speed|Twister) Line|Rainbow)','^Intenso','Intenso',''],
	['^(Iomega|ZIP\b|Clik!)','^Iomega','Iomega',''], 
	['^JingX','^JingX','JingX',''], #JingX 120G SSD - not confirmed, but guessing
	['^Jingyi','^Jingyi','Jingyi',''],
	# NOTE: ITY2 120GB hard to find
	['^JMicron','^JMicron(\s?Tech(nology)?)?','JMicron Tech',''], #JMicron H/W raid
	['^KimMIDI','^KimMIDI','KimMIDI',''],
	['^Kimtigo','^Kimtigo','Kimtigo',''],
	['^Kingchux[\s-]?ing','^Kingchux[\s-]?ing','Kingchuxing',''],
	['^KingDian','^KingDian','KingDian',''],
	['^Kingfast','^Kingfast','Kingfast',''],
	['^KingMAX','^KingMAX','KingMAX',''],
	['^Kingrich','^Kingrich','Kingrich',''],
	['^KING\s?SHARE','^KING\s?SHARE','KingShare',''],
	['^(KingSpec|ACSC)','^KingSpec','KingSpec',''],
	['^KingSSD','^KingSSD','KingSSD',''],
	# kingwin docking, not actual drive
	['^(EZD|EZ-Dock)','','Kingwin Docking Station',''],
	['(KIOXIA|^K[BX]G[0-9])','KIOXIA','KIOXIA',''], # company name comes after product ID
	['^KLEVV','^KLEVV','KLEVV',''],
	['^Kodak','^Kodak','Kodak',''],
	['^(Lacie|P92|itsaKey|iamaKey)','^Lacie','LaCie',''],
	['^LANBO','^LANBO','LANBO',''],
	['^LDLC','^LDLC','LDLC',''],
	# LENSE30512GMSP34MEAT3TA / UMIS RPITJ256PED2MWX
	['^(LEN|UMIS)','^Lenovo','Lenovo',''],
	['^RPFT','','Lenovo O.E.M.',''],
	['^LG\b','^LG','LG',''],
	['^(LITE[-\s]?ON[\s-]?IT)','^LITE[-]?ON[\s-]?IT','LITE-ON IT',''], # LITEONIT_LSS-24L6G
	['^(LITE[-\s]?ON|PH[1-9])','^LITE[-]?ON','LITE-ON',''], # PH6-CE240-L
	['^LONDISK','^LONDISK','LONDISK',''],
	['^(LSI|MegaRAID)','^LSI\b','LSI',''],
	['^M-Systems','^M-Systems','M-Systems',''],
	['^(Mach\s*Xtreme|MXSSD|MXU)','^Mach\s*Xtreme','Mach Xtreme',''],
	['^Maximus','^Maximus','Maximus',''],
	['^(MAXTOR|Atlas|TM[0-9]{4})','^MAXTOR','Maxtor',''], # note M2 M3 is usually maxtor, but can be samsung
	['^(Memorex|TravelDrive|TD\s?Classic)','^Memorex','Memorex',''],
	# note: C300/400 can be either micron or crucial, but C400 is M4 from crucial
	['(^MT|^M5|^Micron|00-MT|C[34]00)','^Micron','Micron',''],# C400-MTFDDAK128MAM
	['^(MARSHAL\b|MAL[0-9])','^MARSHAL','Marshal',''],
	['^MARVELL','^MARVELL','Marvell',''],
	['^Maxsun','^Maxsun','Maxsun',''],
	['^MDT\b','^MDT','MDT (rebuilt WD/Seagate)',''], # mdt rebuilds wd/seagate hdd
	# MD1TBLSSHD, careful with this MD starter!!
	['^MD[1-9]','^Max\s*Digital','MaxDigital',''],
	['^Medion','^Medion','Medion',''],
	['^(MEDIAMAX|WL[0-9]{2})','^MEDIAMAX','MediaMax',''],
	['^Mengmi','^Mengmi','Mengmi',''],
	['^MidasForce','^MidasForce','MidasForce',''],
	['^MINIX','^MINIX','MINIX',''],
	['^Miracle','^Miracle','Miracle',''],
	# Monster MONSTER DIGITAL
	['^(Monster\s)+Digital','^(Monster\s)+Digital','Monster Digital',''],
	['^Morebeck','^Morebeck','Morebeck',''],
	['^Motorola','^Motorola','Motorola',''],
	['^Moweek','^Moweek','Moweek',''],
	#MRMAD4B128GC9M2C
	['^(MRMA|Memoright)','^Memoright','Memoright',''],
	['^MTASE','^MTASE','MTASE',''],
	['^MSI\b','^MSI\b','MSI',''],
	['^MTRON','^MTRON','MTRON',''],
	['^(Neo\s*Forza|NFS[0-9])','^Neo\s*Forza','Neo Forza',''],
	['^Netac','^Netac','Netac',''],
	['^Nik','^Nikimi','Nikimi',''],
	['^Orico','^Orico','Orico',''],
	['^OSC','^OSC\b','OSC',''],
	['^OWC','^OWC\b','OWC',''],
	['^oyunkey','^oyunkey','Oyunkey',''],
	['^PALIT','PALIT','Palit',''], # ssd 
	['^PERC\b','','Dell PowerEdge RAID Card',''], # ssd 
	['^(PS[8F]|Patriot)','^Patriot([-\s]?Memory)?','Patriot',''],
	['PHISON[\s-]?','PHISON[\s-]?','Phison',''],# E12-256G-PHISON-SSD-B3-BB1
	['^Pioneer','Pioneer','Pioneer',''],
	['^PIX[\s]?JR','^PIX[\s]?JR','Disney',''],
	['^(PLEXTOR|PX-)','^PLEXTOR','Plextor',''],
	['^(PQI|Intelligent\s?Stick)','^PQI','PQI',''],
	['^(Premiertek|QSSD|Quaroni)','^Premiertek','Premiertek',''],
	['^Pretec','Pretec','Pretec',''],
	['QEMU','^[0-9]*QEMU( QEMU)?','QEMU',''], # 0QUEMU QEMU HARDDISK
	['(^Quantum|Fireball)','^Quantum','Quantum',''],
	['^QUMO','^QUMO','Qumo',''],
	['^(R3|AMD\s?(RADEON)?)','AMD\s?(RADEON)?','AMD Radeon',''], # ssd 
	['^(Ramaxel|RT|RM|RPF)','^Ramaxel','Ramaxel',''],
	['^RENICE','^RENICE','Renice',''],
	['^(Ricoh|R5)','^Ricoh','Ricoh',''],
	['^RIM[\s]','^RIM','RIM',''],
	 #RTDMA008RAV2BWL comes with lenovo but don't know brand
	['^Runcore','^Runcore','Runcore',''],
	['^Sabrent','^Sabrent','Sabrent',''],
	['^Sage','^Sage(\s?Micro)?','Sage Micro',''],
	['^SandForce','^SandForce','SandForce',''],
	['^Sannobel','^Sannobel','Sannobel',''],
	# SATADOM can be innodisk or supermirco: dom == disk on module
	# SATAFIRM is an ssd failure message
	['^SigmaTel','^SigmaTel','SigmaTel',''],
	# DIAMOND_040_GB
	['^(SILICON\s?MOTION|SM[0-9])','^SILICON\s?MOTION','Silicon Motion',''],
	['(Silicon[\s-]?Power|^SP[CP]C|^Silicon|^Diamond|^Haspeed)','Silicon[\s-]?Power','Silicon Power',''],
	['^SINTECHI?','^SINTECHI?','SinTech (adapter)',''],
	['Smartbuy','\s?Smartbuy','Smartbuy',''], # SSD Smartbuy 60GB; mSata Smartbuy 3
	# HFS128G39TND-N210A; seen nvme with name in middle
	['(SK\s?HYNIX|^HF[MS]|^H[BC]G)','\s?SK\s?HYNIX','SK Hynix',''], 
	['hynix','hynix','Hynix',''],# nvme middle of string, must be after sk hynix
	['^SH','','Smart Modular Tech.',''],
	['^Skill','^Skill','Skill',''],
	['^(SMART( Storage Systems)?|TX)','^(SMART( Storage Systems)?)','Smart Storage Systems',''],
	['^(S[FR]-|Sony)','^Sony','Sony',''],
	['^STE[CK]','^STE[CK]','sTec',''], # wd bought this one
	['^STmagic','^STmagic','STmagic',''],
	['^STORFLY','^STORFLY','StorFly',''],
	['^SUNEAST','^SUNEAST','SunEast',''],
	['^SuperSSpeed','^SuperSSpeed','SuperSSpeed',''],
	# NOTE: F[MNETU] not reliable, g.skill starts with FM too: 
	# Seagate ST skips STT. 
	['^(Super\s*Talent|STT|F[HTZ]M[0-9]|PicoDrive|Teranova)','','Super Talent',''], 
	['^(SF|Swissbit)','^Swissbit','Swissbit',''],
	# ['^(SUPERSPEED)','^SUPERSPEED','SuperSpeed',''], # superspeed is a generic term
	['^(TakeMS|ColorLine)','^TakeMS','TakeMS',''],
	['^Tammuz','^Tammuz','Tammuz',''],
	['^TANDBERG','^TANDBERG','Tanberg',''],
	['^TC[\s-]*SUNBOW','^TC[\s-]*SUNBOW','TCSunBow',''],
	['^(TDK|TF[1-9][0-9])','^TDK','TDK',''],
	['^TEAC','^TEAC','TEAC',''],
	['^TEAM','^TEAM(\s*Group)?','TeamGroup',''],
	['^(Teclast|CoolFlash)','^Teclast','Teclast',''],
	['^Teleplan','^Teleplan','Teleplan',''],
	['^TEUTONS','^TEUTONS','TEUTONS',''],
	['^Tigo','^Tigo','Tigo',''],
	['^Timetec','^Timetec','Timetec',''],
	['^TKD','^TKD','TKD',''],
	['^TopSunligt','^TopSunligt','TopSunligt',''], # is this a typo? hard to know
	['^TopSunlight','^TopSunlight','TopSunlight',''],
	['^([F]?TS|Transcend|JetDrive|JetFlash|USDU)','^Transcend','Transcend',''], 
	['^(TrekStor|DS maxi)','^TrekStor','TrekStor',''],
	['^UDinfo','^UDinfo','UDinfo',''],
	['^USBTech','^USBTech','USBTech',''],
	['^(UNIC2)','^UNIC2','UNIC2',''],
	['^(UG|Unigen)','^Unigen','Unigen',''],
	['^(OOS[1-9]|Utania)','Utania','Utania',''],
	['^U-TECH','U-TECH','U-Tech',''],
	['^VBOX','','VirtualBox',''],
	['^(Verbatim|STORE N GO|Vi[1-9])','^Verbatim','Verbatim',''],
	['^V-GEN','^V-GEN','V-Gen',''],
	['^(Victorinox|Swissflash)','^Victorinox','Victorinox',''],
	['^(Visipro|SDVP)','^Visipro','Visipro',''],
	['^VISIONTEK','^VISIONTEK','VisionTek',''],
	['^VMware','^VMware','VMware',''],
	['^(Vseky|Vaseky)','^Vaseky','Vaseky',''], # ata-Vseky_V880_350G_
	['^(Walgreen|Infinitive)','^Walgreen','Walgreen',''],
	['^Wilk','^Wilk','Wilk',''],
	['^(Wortmann(\sAG)?|Terra\s?US)','^Wortmann(\sAG)?','Wortmann AG',''],
	['^Xintor','^Xintor','Xintor',''],
	['^XPG','^XPG','XPG',''],
	['^XrayDisk','^XrayDisk','XrayDisk',''],
	['^(XUM|HX[0-9])','^XUM','XUM',''],
	['^XUNZHE','^XUNZHE','XUNZHE',''],
	['^(Yeyian|valk)','^Yeyian','Yeyian',''],
	['^(YUCUN|R880)','^YUCUN','YUCUN',''],
	['^ZALMAN','^ZALMAN','Zalman',''],
	['^ZEUSLAP','^ZEUSLAP','ZEUSLAP',''],
	['^(Zheino|CHN[0-9]|CNM)','^Zheino','Zheino',''],
	['^(Zotac|ZTSSD)','^Zotac','Zotac',''],
	['^ZSPEED','^ZSPEED','ZSpeed',''],
	['^ZTC','^ZTC','ZTC',''],
	['^ZTE','^ZTE','ZTE',''],
	['^(ASMT|2115)','^ASMT','ASMT (case)',''],
	);
	eval $end if $b_log;
}

# receives space separated string that may or may not contain vendor data
sub device_vendor {
	eval $start if $b_log;
	my ($model,$serial) = @_;
	my ($vendor) = ('');
	my (@data);
	return if !$model;
	set_vendors() if !@vendors;
	# 0 - match pattern; 1 - replace pattern; 2 - vendor print; 3 - serial pattern
	# Data URLs: inxi-resources.txt Section: DiskData device_vendor()
	# $model = 'H10 HBRPEKNX0202A NVMe INTEL 512GB';
	# $model = 'Patriot Memory';
	foreach my $row (@vendors){
		if ($model =~ /$row->[0]/i || ($row->[3] && $serial && $serial =~ /$row->[3]/)){
			$vendor = $row->[2];
			# Usually we want to assign N/A at output phase, maybe do this logic there?
			if ($row->[1]){
				if ($model !~ m/$row->[1]$/i){
					$model =~ s/$row->[1]//i;
				}
				else {
					$model = 'N/A';
				}
			}
			$model =~ s/^[\/\[\s_-]+|[\/\s_-]+$//g;
			$model =~ s/\s\s/ /g;
			@data = ($vendor,$model);
			last;
		}
	}
	eval $end if $b_log;
	return @data;
}

# Normally hddtemp requires root, but you can set user rights in /etc/sudoers.
# args: $1 - /dev/<disk> to be tested for
sub hdd_temp {
	eval $start if $b_log;
	my ($device) = @_;
	my ($path) = ('');
	my (@data,$hdd_temp);
	if ($device =~ /nvme/i){
		if (!$b_nvme){
			$b_nvme = 1;
			if ($path = main::check_program('nvme')) {
				$nvme = $path;
			}
		}
		if ($nvme){
			$device =~ s/n[0-9]//;
			@data = main::grabber("$sudo$nvme smart-log $device 2>/dev/null");
			foreach (@data){
				my @row = split /\s*:\s*/, $_;
				next if !$row[0];
				# other rows may have: Temperature sensor 1 :
				if ( $row[0] eq 'temperature') {
					$row[1] =~ s/\s*C//;
					$hdd_temp = $row[1];
					last;
				}
			}
		}
	}
	else {
		if (!$b_hddtemp){
			$b_hddtemp = 1;
			if ($path = main::check_program('hddtemp')) {
				$hddtemp = $path;
			}
		}
		if ($hddtemp){
			$hdd_temp = (main::grabber("$sudo$hddtemp -nq -u C $device 2>/dev/null"))[0];
		}
	}
	eval $end if $b_log;
	return $hdd_temp;
}
# args: 1: block id
sub block_data {
	eval $start if $b_log;
	my ($id) = @_;
	# 0: logical block size 1: disk physical block size/partition block size;
	my @blocks = (0,0); 
	my ($block_log,$block_size) = (0,0);
	#my $path_size = "/sys/block/$id/size";
	my $path_log_block = "/sys/block/$id/queue/logical_block_size";
	my $path_phy_block = "/sys/block/$id/queue/physical_block_size";
	# legacy system path
	if (! -e $path_phy_block && -r "/sys/block/$id/queue/hw_sector_size" ){
		$path_phy_block = "/sys/block/$id/queue/hw_sector_size";
	}
	if ( -r $path_log_block || -r $path_phy_block ){
		$block_log = (main::reader($path_log_block))[0] if  -r $path_log_block;
		$block_size = (main::reader($path_phy_block))[0] if -r $path_phy_block;
	}
	# print "l-b: $block_log p-b: $block_size raw: $size_raw\n";
	@blocks = ($block_log,$block_size); 
	main::log_data('dump','@blocks',\@blocks) if $b_log;
	eval $end if $b_log;
	return @blocks;
}
sub device_speed {
	eval $start if $b_log;
	my ($device) = @_;
	my ($b_nvme,$lanes,$speed,@data);
	my $working = Cwd::abs_path("/sys/class/block/$device");
	#print "$working\n";
	if ($working){
		my ($id);
		# slice out the ata id:
		# /sys/devices/pci0000:00:11.0/ata1/host0/target0:
		if ($working =~ /^.*\/ata([0-9]+)\/.*/){
			$id = $1;
		}
		# /sys/devices/pci0000:00/0000:00:05.0/virtio1/block/vda
		elsif ($working =~ /^.*\/virtio([0-9]+)\/.*/){
			$id = $1;
		}
		# /sys/devices/pci0000:10/0000:10:01.2/0000:13:00.0/nvme/nvme0/nvme0n1
		elsif ($working =~ /^.*\/(nvme[0-9]+)\/.*/){
			$id = $1;
			$b_nvme = 1;
		}
		# do host last because the strings above might have host as well as their search item
		# 0000:00:1f.2/host3/target3: increment by 1 sine ata starts at 1, but host at 0
		elsif ($working =~ /^.*\/host([0-9]+)\/.*/){
			$id = $1 + 1 if defined $1;
		}
		# print "$working $id\n";
		if (defined $id){
			if ($b_nvme){
				$working = "/sys/class/nvme/$id/device/max_link_speed";
				$speed = (main::reader($working))[0] if -f $working;
				if ($speed =~ /([0-9\.]+)\sGT\/s/){
					$speed = $1;
					# pcie1: 2.5 GT/s; pcie2: 5.0 GT/s; pci3: 8 GT/s
					# NOTE: PCIe 3 stopped using the 8b/10b encoding but a sample pcie3 nvme has 
					# rated speed of GT/s * .8 anyway. GT/s * (128b/130b)
					$speed = ($speed <= 5 ) ? $speed * .8 : $speed * 128/130; 
					$speed = sprintf("%.1f",$speed) if $speed;
					$working = "/sys/class/nvme/$id/device/max_link_width";
					$lanes = (main::reader($working))[0] if -f $working;
					$lanes = 1 if !$lanes;
					# https://www.edn.com/electronics-news/4380071/What-does-GT-s-mean-anyway-
					# https://www.anandtech.com/show/2412/2
					# http://www.tested.com/tech/457440-theoretical-vs-actual-bandwidth-pci-express-and-thunderbolt/
					# PCIe 1,2 use “8b/10b” encoding: eight bits are encoded into a 10-bit symbol
					# PCIe 3,4,5 use "128b/130b" encoding: 128 bits are encoded into a 130 bit symbol
					$speed = ($speed * $lanes) . " Gb/s";
				}
			}
			else {
				$working = "/sys/class/ata_link/link$id/sata_spd";
				$speed = (main::reader($working))[0] if -f $working;
				$speed = main::disk_cleaner($speed) if $speed;
				$speed =~ s/Gbps/Gb\/s/ if $speed;
			}
		}
	}
	@data = ($speed,$lanes);
	#print "$working $speed\n";
	eval $end if $b_log;
	return @data;
}
# gptid/c5e940f1-5ce2-11e6-9eeb-d05099ac4dc2     N/A  ada0p1
sub match_glabel {
	eval $start if $b_log;
	my ($gptid) = @_;
	return if !@glabel || ! $gptid;
	#$gptid =~ s/s[0-9]+$//;
	my ($dev_id) = ('');
	foreach (@glabel){
		my @temp = split /\s+/, $_;
		my $gptid_trimmed = $gptid;
		# slice off s[0-9] from end in case they use slice syntax
		$gptid_trimmed =~ s/s[0-9]+$//;
		if (defined $temp[0] && ($temp[0] eq $gptid || $temp[0] eq $gptid_trimmed ) ){
			$dev_id = $temp[2];
			last;
		}
	}
	$dev_id ||= $gptid; # no match? return full string
	eval $end if $b_log;
	return $dev_id;
}
sub set_glabel {
	eval $start if $b_log;
	$b_glabel = 1;
	if (my $path = main::check_program('glabel')){
		@glabel = main::grabber("$path status 2>/dev/null");
	}
	main::log_data('dump','@glabel:with Headers',\@glabel) if $b_log;
	# get rid of first header line
	shift @glabel;
	eval $end if $b_log;
}
}

## GraphicData 
{
package GraphicData;
my $driver = ''; # we need this as a fallback in case no xorg log found
my %graphics;
sub get {
	eval $start if $b_log;
	my (@data,@rows);
	my $num = 0;
	if (($b_arm || $b_mips) && !$b_soc_gfx && !$b_pci_tool){
		my $type = ($b_arm) ? 'arm' : 'mips';
		my $key = 'Message';
		@data = ({
		main::key($num++,0,1,$key) => main::row_defaults($type . '-pci',''),
		},);
		@rows = (@rows,@data);
	}
	else {
		@data = card_data();
		@rows = (@rows,@data);
		if (!@rows){
			my $key = 'Message';
			my $type = 'pci-card-data';
			if ($pci_tool && ${$alerts{$pci_tool}}{'action'} eq 'permissions'){
				$type = 'pci-card-data-root';
			}
			@data = ({
			main::key($num++,0,1,$key) => main::row_defaults($type,''),
			},);
			@rows = (@rows,@data);
		}
	}
	# note: not perfect, but we need usb gfx to show for all types, soc, pci, etc
	@data = usb_data();
	@rows = (@rows,@data);
	@data = display_data();
	@rows = (@rows,@data);
	@data = gl_data();
	@rows = (@rows,@data);
	eval $end if $b_log;
	return @rows;
}

sub card_data {
	eval $start if $b_log;
	my (@rows,@data);
	my ($j,$num) = (0,1);
	foreach (@devices_graphics){
		$num = 1;
		my @row = @$_;
		#print "$row[0] $row[3]\n";
		# not using 3D controller yet, needs research: |3D controller |display controller
		# note: this is strange, but all of these can be either a separate or the same
		# card. However, by comparing bus id, say: 00:02.0 we can determine that the
		# cards are  either the same or different. We want only the .0 version as a valid
		# card. .1 would be for example: Display Adapter with bus id x:xx.1, not the right one
		next if $row[3] != 0;
		#print "$row[0] $row[3]\n";
		$j = scalar @rows;
		$driver = $row[9];
		$driver ||= 'N/A';
		my $card = main::trimmer($row[4]);
		$card = ($card) ? main::pci_cleaner($card,'output') : 'N/A';
		# have seen absurdly verbose card descriptions, with non related data etc
		if (length($card) > 85 || $size{'max'} < 110){
			$card = main::pci_long_filter($card);
		}
		@data = ({
		main::key($num++,1,1,'Device') => $card,
		},);
		@rows = (@rows,@data);
		if ($extra > 0 && $b_pci_tool && $row[12]){
			my $item = main::get_pci_vendor($row[4],$row[12]);
			$rows[$j]{main::key($num++,0,2,'vendor')} = $item if $item;
		}
		$rows[$j]{main::key($num++,1,2,'driver')} = $driver;
		if ($row[9] && !$bsd_type){
			my $version = main::get_module_version($row[9]);
			$version ||= 'N/A';
			$rows[$j]{main::key($num++,0,3,'v')} = $version;
		}
		if ($b_admin && $row[10]){
			$row[10] = main::get_driver_modules($row[9],$row[10]);
			$rows[$j]{main::key($num++,0,3,'alternate')} = $row[10] if $row[10];
		}
		if ($extra > 0){
			$rows[$j]{main::key($num++,0,2,'bus ID')} = (!$row[2] && !$row[3]) ? 'N/A' : "$row[2].$row[3]";
		}
		if ($extra > 1){
			$rows[$j]{main::key($num++,0,2,'chip ID')} = ($row[5]) ? "$row[5]:$row[6]" : $row[6];
		}
		#print "$row[0]\n";
	}
	#my $ref = $pci[-1];
	#print $$ref[0],"\n";
	eval $end if $b_log;
	return @rows;
}
sub usb_data {
	eval $start if $b_log;
	my (@rows,@data,@ids,$driver,$path_id,$product,@temp2);
	my ($j,$num) = (0,1);
	return if !@usb;
	foreach my $ref (@usb){
		my @row = @$ref;
		# these tests only work for /sys based usb data for now
		if ($row[14] && ($row[14] eq 'Audio-Video' || $row[14] eq 'Video' ) ){
			$num = 1;
			$j = scalar @rows;
			# makre sure to reset, or second device trips last flag
			($driver,$path_id,$product) = ('','','');
			$product = main::cleaner($row[13]) if $row[13];
			$driver = $row[15] if $row[15];
			$path_id = $row[2] if $row[2];
			$product ||= 'N/A';
			# note: for real usb video out, no generic drivers? webcams may have one though
			if (!$driver){
				if ($row[14] eq 'Audio-Video'){
					$driver = 'N/A';
				}
				else {
					$driver = 'N/A';
				}
			}
			@data = ({
			main::key($num++,1,1,'Device') => $product,
			main::key($num++,0,2,'type') => 'USB',
			main::key($num++,0,2,'driver') => $driver,
			},);
			@rows = (@rows,@data);
			if ($extra > 0){
				$rows[$j]{main::key($num++,0,2,'bus ID')} = "$path_id:$row[1]";
			}
			if ($extra > 1){
				$row[7] ||= 'N/A';
				$rows[$j]{main::key($num++,0,2,'chip ID')} = $row[7];
			}
			if ($extra > 2 && $row[16]){
				$rows[$j]{main::key($num++,0,2,'serial')} = main::apply_filter($row[16]);
			}
		}
	}
	eval $end if $b_log;
	return @rows;
}
sub display_data(){
	eval $start if $b_log;
	my (@row);
	my ($num,$protocol) = (0,'');
	# note: these may not always be set, they won't be out of X, for example
	$protocol = get_protocol();
	# note, since the compositor is the server with wayland, always show it
	if ($extra > 1 || $protocol eq 'wayland'){
		set_compositor($protocol);
	}
	if ( $b_display){
		x_display_data();
		# currently barebones, wayland needs a lot more work
		if ($protocol && $protocol eq 'wayland' && !$graphics{'screens'}){
			wayland_display_data();
			# it worked! we got screen data
			$graphics{'no-xdpyinfo'} = undef if $graphics{'screens'};
		}
	}
	else {
		$graphics{'tty'} = tty_data();
	}
	# this gives better output than the failure last case, which would only show:
	# for example: X.org: 1.9 instead of: X.org: 1.9.0
	$graphics{'x-version'} = $graphics{'xorg-version'} if $graphics{'xorg-version'};;
	$graphics{'x-version'} = x_version() if !$graphics{'x-version'};
	$graphics{'x-version'} = $graphics{'x-version-id'} if !$graphics{'x-version'};
	#print Data::Dumper::Dumper \%graphics;
	if (%graphics){
		my ($driver_missing,$resolution,$server_string) = ('','','');
		# print "$graphics{'x-vendor'} $graphics{'x-version'} $graphics{'x-vendor-release'}","\n";
		if ($graphics{'x-vendor'}){
			my $version = ($graphics{'x-version'}) ? " $graphics{'x-version'}" : '';
			#$version = (!$version && $graphics{'x-vendor-release'}) ? " $graphics{'x-vendor-release'}" : '';
			$server_string = "$graphics{'x-vendor'}$version";
			#print "$server_string\n";
		}
		elsif ($graphics{'x-version'}) {
			if ($graphics{'x-version'} =~ /^Xvesa/){
				$server_string = $graphics{'x-version'};
			}
			else {
				$server_string = "X.org $graphics{'x-version'}";
			}
		}
		my @drivers = x_drivers();
		if (!$protocol && !$server_string && !$graphics{'x-vendor'} && !@drivers){
			$server_string = main::row_defaults('display-server');
			@row = ({
			main::key($num++,1,1,'Display') => '',
			main::key($num++,0,2,'server') => $server_string,
			});
		}
		else {
			$server_string ||= 'N/A';
			@row = ({
			main::key($num++,1,1,'Display') => $protocol,
			main::key($num++,0,2,'server') => $server_string,
			});
			if ($graphics{'compositor'}){
				$row[0]{main::key($num++,0,2,'compositor')} = $graphics{'compositor'};
				if ($graphics{'compositor-version'}){
					$row[0]{main::key($num++,0,3,'v')} = $graphics{'compositor-version'};
				}
			}
			# note: if no xorg log, and if wayland, there will be no xorg drivers, 
			# obviously, so we use the last driver found on the card section in that case.
			# those come from lscpi kernel drivers so there should be no xorg/wayland issues.
			if (!$drivers[0]){
				# Fallback: specific case: in Arch/Manjaro gdm run systems, their Xorg.0.log is 
				# located inside this directory, which is not readable unless you are root
				# Normally Arch gdm log is here: ~/.local/share/xorg/Xorg.1.log
				# $driver comes from the Device lines, and is just last fallback.
				if ($driver){
					if (-e '/var/lib/gdm' && !$b_root ){
						$driver_missing = main::row_defaults('display-driver-na') . ' - ' . main::row_defaults('root-suggested');
					}
					else {
						$driver_missing = main::row_defaults('display-driver-na');
					}
				}
				else {
					$driver_missing = main::row_defaults('root-suggested') if -e '/var/lib/gdm' && !$b_root;
				}
			}
			else {
				$driver = $drivers[0];
			}
			$driver ||= 'N/A';
			$row[0]{main::key($num++,0,2,'driver')} = $driver;
			if ($driver_missing){
				$row[0]{main::key($num++,0,3,'note')} = $driver_missing;
			}
			if ($drivers[2]){
				$row[0]{main::key($num++,0,3,'FAILED')} = $drivers[2];
			}
			if ($drivers[1]){
				$row[0]{main::key($num++,0,3,'unloaded')} = $drivers[1];
			}
			if ($extra > 1 && $drivers[3]){
				$row[0]{main::key($num++,0,3,'alternate')} = $drivers[3];
			}
		}
		if ($b_admin ){
			if (defined $graphics{'display-id'}){
				$row[0]{main::key($num++,0,2,'display ID')} = $graphics{'display-id'};
			}
			if (defined $graphics{'display-screens'}){
				$row[0]{main::key($num++,0,2,'screens')} = $graphics{'display-screens'};
			}
			if (defined $graphics{'display-default-screen'} && 
			 $graphics{'display-screens'} && $graphics{'display-screens'} > 1){
				$row[0]{main::key($num++,0,2,'default screen')} = $graphics{'display-default-screen'};
			}
		}
		if ($graphics{'no-xdpyinfo'}){
			$row[0]{main::key($num++,0,2,'resolution')} = $graphics{'no-xdpyinfo'};
		}
		elsif ($graphics{'screens'}){
			my ($diag,$dpi,$hz,$size);
			my ($m_count,$basic_count,$row_key,$screen_count) = (0,0,0,0);
			my $s_count = ($graphics{'screens'}) ? scalar @{$graphics{'screens'}}:  0;
			foreach (@{$graphics{'screens'}}){
				my %main = %$_;
				$m_count = scalar @{$main{'monitors'}} if $main{'monitors'};
				$screen_count++;
				($diag,$dpi,$hz,$resolution,$size) = (undef);
				$row_key++ if !$show{'graphic-basic'};
				if ( !$show{'graphic-basic'} || $m_count == 0 ){
					if ( !$show{'graphic-basic'} && defined $main{'screen'} ){
						$row[$row_key]{main::key($num++,1,2,'Screen')} = $main{'screen'};
					}
					$resolution = $main{'res-x'} . 'x' . $main{'res-y'} if $main{'res-x'} && $main{'res-y'};
					$resolution .= '~' . $main{'hz'} . 'Hz' if $show{'graphic-basic'} && $main{'hz'} && $resolution;
					$resolution ||= 'N/A';
					if ($s_count == 1 || !$show{'graphic-basic'}){
						$row[$row_key]{main::key($num++,0,3,'s-res')} = $resolution;
					}
					elsif ($show{'graphic-basic'}) {
						$row[$row_key]{main::key($num++,0,3,'s-res')} = '' if $screen_count == 1;
						$row[$row_key]{main::key($num++,0,3,$screen_count)} = $resolution;
					}
					$resolution = '';
					if ($main{'s-dpi'} && (!$show{'graphic-basic'} || $extra > 1)){
						$row[$row_key]{main::key($num++,0,3,'s-dpi')} = $main{'s-dpi'};
					}
					if ( !$show{'graphic-basic'} ){
						if ($main{'size-x'} && $main{'size-y'}){
							$size = $main{'size-x'} . 'x' . $main{'size-y'} . 
							'mm ('. $main{'size-x-i'} . 'x' . $main{'size-y-i'} . '")';
						}
						$size ||= '';
						$row[$row_key]{main::key($num++,0,3,'s-size')} = $size if $size;
						if ($main{'diagonal'}){
							$diag = $main{'diagonal-m'} . 'mm ('. $main{'diagonal'} . '")';
						}
						$diag ||= '';
						$row[$row_key]{main::key($num++,0,3,'s-diag')} = $diag if $diag;
					}
				}
				if ($main{'monitors'}){
					#print $basic_count . '::' . $m_count, "\n";
					foreach my $ref2 (@{$main{'monitors'}}){
						my %monitor = %$ref2;
						($diag,$dpi,$hz,$resolution,$size) = (undef);
						if ($show{'graphic-basic'}){
							$basic_count++;
							if ($monitor{'res-x'} && $monitor{'res-y'}){
								$resolution = $monitor{'res-x'} . 'x' . $monitor{'res-y'};
							}
							# using main, noit monitor, dpi because we want xorg dpi, not physical screen dpi
							$dpi = $main{'s-dpi'} if $resolution && $extra > 1 && $main{'s-dpi'};
							$resolution .= '~' . $monitor{'hz'} . 'Hz' if $monitor{'hz'} && $resolution;
							$resolution ||= 'N/A';
							if ($basic_count == 1 && $m_count == 1){
								$row[$row_key]{main::key($num++,0,2,'resolution')} = $resolution;
							}
							else {
								$row[$row_key]{main::key($num++,1,2,'resolution')} = '' if $basic_count == 1;
								$row[$row_key]{main::key($num++,0,3,$basic_count)} = $resolution;
							}
							if ($m_count == $basic_count){
								$row[$row_key]{main::key($num++,0,2,'s-dpi')} = $dpi if $dpi;
							}
							next;
						}
						$row_key++;
						$row[$row_key]{main::key($num++,0,3,'Monitor')} = $monitor{'monitor'};
						if ($monitor{'res-x'} && $monitor{'res-y'}){
							$resolution = $monitor{'res-x'} . 'x' . $monitor{'res-y'};
						}
						$resolution ||= 'N/A';
						$row[$row_key]{main::key($num++,0,4,'res')} = $resolution;
						$hz = ($monitor{'hz'}) ? $monitor{'hz'} : '';
						$row[$row_key]{main::key($num++,0,4,'hz')} = $hz if $hz;
						$dpi = ($monitor{'dpi'}) ? $monitor{'dpi'} : '';
						$row[$row_key]{main::key($num++,0,4,'dpi')} = $dpi if $dpi;
						#print "$dpi :: $main{'s-dpi'}\n";
						if ($monitor{'size-x'} && $monitor{'size-y'}){
							$size =  $monitor{'size-x'} . 'x' . $monitor{'size-y'} .
							'mm ('. $monitor{'size-x-i'} . 'x' . $monitor{'size-y-i'} . '")';
						}
						$size ||= '';
						$row[$row_key]{main::key($num++,0,4,'size')} = $size if $size;
						if ($monitor{'diagonal'}){
							$diag = $monitor{'diagonal-m'} . 'mm ('. $monitor{'diagonal'} . '")';
						}
						$diag ||= '';
						$row[$row_key]{main::key($num++,0,4,'diag')} = $diag if $diag;
					}
				}
			}
		}
		else {
			$graphics{'tty'} ||= 'N/A';
			$row[0]{main::key($num++,0,2,'tty')} = $graphics{'tty'};
		}
	}
	eval $end if $b_log;
	return @row;
}

sub x_display_data {
	eval $start if $b_log;
	# X vendor and version detection.
	# new method added since radeon and X.org and the disappearance of 
	# <X server name> version : ...etc. Later on, the normal textual version string 
	# returned, e.g. like: X.Org version: 6.8.2 
	# A failover mechanism is in place: if $version empty, release number parsed instead
	if (my $program = main::check_program('xdpyinfo')){
		my ($diagonal,$diagonal_m,$dpi) = ('','','');
		my ($screen_id,$screen,@working);
		my ($res_x,$res_x_i,$res_y,$res_y_i,$size_x,$size_x_i,$size_y,$size_y_i);
		my @xdpyinfo = main::grabber("$program $display_opt 2>/dev/null","\n",'strip');
		#@xdpyinfo = map {s/^\s+//;$_} @xdpyinfo if @xdpyinfo;
		#print join "\n",@xdpyinfo, "\n";
		foreach (@xdpyinfo){
			@working = split /:\s+/, $_;
			next if ( ($graphics{'screens'} && $working[0] !~ /^(dimensions$|screen\s#)/ ) || !$working[0] );
			#print "$_\n";
			if ($working[0] eq 'vendor string'){
				$working[1] =~ s/The\s|\sFoundation//g;
				# some distros, like fedora, report themselves as the xorg vendor, 
				# so quick check here to make sure the vendor string includes Xorg in string
				if ($working[1] !~ /x/i){
					$working[1] .= ' X.org';
				}
				$graphics{'x-vendor'} = $working[1];
			}
			elsif ($working[0] eq 'name of display'){
				$graphics{'display-id'} = $working[1];
			}
			elsif ($working[0] eq 'version number'){
				$graphics{'x-version-id'} = $working[1];
			}
			# note used, fix that
			elsif ($working[0] eq 'vendor release number'){
				$graphics{'x-vendor-release'} = $working[1];
			}
			elsif ($working[0] eq 'X.Org version'){
				$graphics{'xorg-version'} = $working[1];
			}
			elsif ($working[0] eq 'default screen number'){
				$graphics{'display-default-screen'} = $working[1];
			}
			elsif ($working[0] eq 'number of screens'){
				$graphics{'display-screens'} = $working[1];
			}
			elsif  ($working[0] =~ /^screen #([0-9]+):/){
				$screen_id = $1;
				$graphics{'screens'} = () if !$graphics{'screens'};
			}
			elsif ($working[0] eq 'resolution'){
				$working[1] =~ s/^([0-9]+)x/$1/;
				$graphics{'s-dpi'} = $working[1];
			}
			elsif ($working[0] eq 'dimensions'){
				($dpi,$res_x,$res_y,$size_x,$size_y) = (undef,undef,undef,undef,undef);
				if ($working[1] =~ /([0-9]+)\s*x\s*([0-9]+)\s+pixels\s+\(([0-9]+)\s*x\s*([0-9]+)\s*millimeters\)/){
					$res_x = $1;
					$res_y = $2;
					$size_x = $3;
					$size_y = $4;
					$res_x_i = ($1) ? sprintf("%.1f", ($1/25.4)) : 0;
					$res_y_i = ($2) ? sprintf("%.1f", ($2/25.4)) : 0;
					$size_x_i = ($3) ? sprintf("%.1f", ($3/25.4)) : 0;
					$size_y_i = ($4) ? sprintf("%.1f", ($4/25.4)) : 0;
					$dpi = ($res_x && $size_x) ? sprintf("%.0f", ($res_x*25.4/$size_x)) : '';
					$diagonal = ($res_x && $size_x) ? sprintf("%.1f", (sqrt($size_x**2 + $size_y**2)/25.4 )) : '';
					$diagonal += 0 if $diagonal;# trick to get rid of decimal 0
					$diagonal_m = ($res_x && $size_x) ? sprintf("%.0f", (sqrt($size_x**2 + $size_y**2))) : '';
				}
				$screen = {
				'screen' => $screen_id,
				'res-x' => $res_x,
				'res-x-i' => $res_x_i,
				'res-y' => $res_y,
				'res-y-i' => $res_y_i,
				'size-x' => $size_x,
				'size-x-i' => $size_x_i,
				'size-y' => $size_y,
				'size-y-i' => $size_y_i,
				's-dpi' => $dpi,
				'diagonal' => $diagonal,
				'diagonal-m' => $diagonal_m,
				};
				push @{$graphics{'screens'}}, $screen;
			}
		}
		#print Data::Dumper::Dumper $graphics{'screens'};
		if (my $program = main::check_program('xrandr')){
			($diagonal,$diagonal_m,$dpi) = (undef);
			($screen_id,$screen,@working) = (undef);
			($res_x,$res_x_i,$res_y,$res_y_i,$size_x,$size_x_i,$size_y,$size_y_i) = (undef);
			my ($monitor,@monitors,$monitor_id,$screen,$screen_id,@xrandr_screens);
			my @xrandr = main::grabber("$program $display_opt 2>/dev/null",'','strip');
			#$graphics{'dimensions'} = (\@dimensions);
			# we get a bit more info from xrandr than xdpyinfo, but xrandr fails to handle
			# multiple screens from different video cards
			foreach (@xrandr){
				if (/^Screen ([0-9]+):/){
					$screen_id = $1;
					push @xrandr_screens, \@monitors if @monitors;
					@monitors = ();
				}
				if (/^([^\s]+)\s+connected\s(primary\s)?([0-9]+)\s*x\s*([0-9]+)\+[0-9+]+(\s\([^)]+\))?(\s([0-9]+)mm\sx\s([0-9]+)mm)?/){
					$monitor_id = $1;
					$res_x = $3;
					$res_y = $4;
					$size_x = $7;
					$size_y = $8;
					$res_x_i = ($3) ? sprintf("%.1f", ($3/25.4)) : 0;
					$res_y_i = ($4) ? sprintf("%.1f", ($4/25.4)) : 0;
					$size_x_i = ($7) ? sprintf("%.1f", ($7/25.4)) : 0;
					$size_y_i = ($8) ? sprintf("%.1f", ($8/25.4)) : 0;
					$dpi = ($res_x && $size_x) ? sprintf("%.0f", $res_x * 25.4 / $size_x) : '';
					$diagonal = ($res_x && $size_x) ? sprintf("%.1f", (sqrt($size_x**2 + $size_y**2)/25.4 )) : '';
					$diagonal += 0 if $diagonal; # trick to get rid of decimal 0
					$diagonal_m = ($res_x && $size_x) ? sprintf("%.0f", (sqrt($size_x**2 + $size_y**2))) : '';
					$monitor = {
					'screen' => $screen_id,
					'monitor' => $monitor_id,
					'res-x' => $res_x,
					'res-x-i' => $res_x_i,
					'res-y' => $res_y,
					'res-y-i' => $res_y_i,
					'size-x' => $size_x,
					'size-x-i' => $size_x_i,
					'size-y' => $size_y,
					'size-y-i' => $size_y_i,
					'dpi' => $dpi,
					'diagonal' => $diagonal,
					'diagonal-m' => $diagonal_m,
					};
					push @monitors, $monitor;
					# print "x:$size_x y:$size_y rx:$res_x ry:$res_y dpi:$dpi\n";
					($res_x,$res_x_i,$res_y,$res_y_i,$size_x,$size_x_i,$size_y,$size_y_i) = (0,0,0,0,0,0,0,0);
					
				}
				my @working = split /\s+/,$_;
				# print join "$_\n";
				if ($working[1] =~ /\*/){
					$working[1] =~ s/\*|\+//g;
					$working[1] = sprintf("%.0f",$working[1]);
					$monitors[scalar @monitors - 1]{'hz'} = $working[1] if @monitors;
					($diagonal,$dpi) = ('','');
					# print Data::Dumper::Dumper \@monitors;
				}
			}
			push @xrandr_screens, \@monitors if @monitors;
			#print "xrand: " . Data::Dumper::Dumper \@xrandr_screens;
			my ($i) = (0);
			foreach (@{$graphics{'screens'}}){
				my %main = %$_;
				# print "h: " . Data::Dumper::Dumper \%main;
				#print $main{'screen'}, "\n";
				foreach my $ref2 (@xrandr_screens){
					my @screens = @$ref2;
					# print "d: " . Data::Dumper::Dumper \@screens;
					if ($screens[0]{'screen'} eq $main{'screen'}){
						${$graphics{'screens'}}[$i]{'monitors'} = \@screens;
						last;
					}
				}
				$i++;
			}
			if (!$graphics{'screens'}) {
				$graphics{'tty'} = tty_data();
			}
		}
	}
	else {
		$graphics{'no-xdpyinfo'} = main::row_defaults('tool-missing-basic','xdpyinfo');
	}
	print 'last: ', Data::Dumper::Dumper $graphics{'screens'} if $test[17];
	main::log_data('dump','$graphics{screens}',$graphics{'screens'}) if $b_log;
	eval $end if $b_log;
}
sub wayland_display_data {
	eval $start if $b_log;
	if ($ENV{'WAYLAND_DISPLAY'}){
		$graphics{'display-id'} = $ENV{'WAYLAND_DISPLAY'};
		# return as wayland-0 or 0?
		$graphics{'display-id'} =~ s/wayland-?//i;
	}
	#print 'last: ', Data::Dumper::Dumper $graphics{'screens'} if $test[17];
	#main::log_data('dump','@graphics{screens}',$graphics{'screens'}) if $b_log;
	eval $end if $b_log;
}
sub set_compositor {
	eval $start if $b_log;
	my ($protocol) = @_;
	# initial tests, if wayland, it is certainly a compositor
	$protocol = lc($protocol) if $protocol;
	$graphics{'compositor'} = display_compositor($protocol);
	# gnome-shell is incredibly slow to return version
	if (($extra > 2 || $protocol eq 'wayland') && $graphics{'compositor'} && 
		( !$show{'system'} || $graphics{'compositor'} ne 'gnome-shell' ) ){
		$graphics{'compositor-version'} = (main::program_data($graphics{'compositor'},$graphics{'compositor'},3))[1];
	}
	eval $end if $b_log;
}
sub get_protocol {
	eval $start if $b_log;
	my ($protocol) = ('');
	$protocol = $ENV{'XDG_SESSION_TYPE'} if $ENV{'XDG_SESSION_TYPE'};
	$protocol = $ENV{'WAYLAND_DISPLAY'} if (!$protocol && $ENV{'WAYLAND_DISPLAY'});
	# can show as wayland-0
	$protocol = 'wayland' if $protocol && $protocol =~ /wayland/i;
	# yes, I've seen this in 2019 distros, sigh
	$protocol = '' if $protocol eq 'tty';
	# need to confirm that there's a point to this test, I believe no, fails out of x
	# loginctl also results in the session id
	if (!$protocol && $b_display && $b_force_display){
		if (my $program = main::check_program('loginctl')){
			my $id = '';
			# $id = $ENV{'XDG_SESSION_ID'}; # returns tty session in console
			my @data = main::grabber("$program --no-pager --no-legend 2>/dev/null",'','strip');
			foreach (@data){
				next if /tty[v]?[0-6]$/; # freebsd: ttyv3
				$id = (split /\s+/, $_)[0];
				last; # multiuser? too bad, we'll go for the first one
			}
			if ($id ){
				my $temp = (main::grabber("$program show-session $id -p Type --no-pager --no-legend 2>/dev/null"))[0];
				$temp =~ s/Type=// if $temp;
				# ssh will not show /dev/ttyx so would have passed the first test
				$protocol = $temp if $temp && $temp ne 'tty';
			}
		}
	}
	eval $end if $b_log;
	return $protocol;
}
sub gl_data(){
	eval $start if $b_log;
	my $num = 0;
	my (@row,$arg);
	#print ("$b_display : $b_root\n");
	if ( $b_display){
		if (my $program = main::check_program('glxinfo')){
			# NOTE: glxinfo -B is not always available, unfortunately
			my @glxinfo = main::grabber("$program $display_opt 2>/dev/null");
			#my $file = "$ENV{'HOME'}/bin/scripts/inxi/data/graphics/glxinfo/glxinfo-ssh-centos.txt";
			#my @glxinfo = main::reader($file);
			if (!@glxinfo){
				my $type = 'display-console';
				if ($b_root){
					$type = 'display-root-x';
				}
				else {
					$type = 'display-null';
				}
				@row = ({
				main::key($num++,0,1,'Message') => main::row_defaults($type),
				});
				return @row;
			}
			#print join "\n",@glxinfo,"\n";
			my $compat_version = '';
			my ($b_compat,$b_nogl,@core_profile_version,@direct_render,@renderer,
			@opengl_version,@working);
			foreach (@glxinfo){
				next if /^\s/;
				if (/^opengl renderer/i){
					@working = split /:\s*/, $_;
					if ($working[1]){
						$working[1] = main::cleaner($working[1]);
						# Allow all mesas
						#if ($working[1] =~ /mesa/i){
						#	
						#}
					}
					# note: there are cases where gl drivers are missing and empty 
					# field value occurs.
					else {
						$b_nogl = 1;
						$working[1] = main::row_defaults('gl-empty');
					}
					push @renderer, $working[1];
				}
				# dropping all conditions from this test to just show full mesa information
				# there is a user case where not f and mesa apply, atom mobo
				# /opengl version/ && ( f || $2 !~ /mesa/ ) {
				elsif (/^opengl version/i){
					@working = split /:\s*/, $_;
					if ($working[1]){
						# fglrx started appearing with this extra string, does not appear 
						# to communicate anything of value
						$working[1] =~ s/(Compatibility Profile Context|\(Compatibility Profile\))//;
						$working[1] =~ s/\s\s/ /g;
						$working[1] =~ s/^\s+|\s+$//;
						push @opengl_version, $working[1];
						# note: this is going to be off if ever multi opengl versions appear, 
						# never seen one
						@working = split /\s+/, $working[1];
						$compat_version = $working[0];
					}
					elsif (!$b_nogl) {
						push @opengl_version, main::row_defaults('gl-empty');
					}
				}
				elsif (/^opengl core profile version/i){
					@working = split /:\s*/, $_;
					# note: no need to apply empty message here since we don't have the data
					# anyway
					if ($working[1]){
						# fglrx started appearing with this extra string, does not appear 
						# to communicate anything of value
						$working[1] =~ s/(Compatibility Profile Context|\((Compatibility|Core) Profile\))//;
						$working[1] =~ s/\s\s/ /g;
						$working[1] =~ s/^\s+|\s+$//;
						push @core_profile_version, $working[1];
					}
				}
				elsif (/direct rendering/){
					@working = split /:\s*/, $_;
					push @direct_render, $working[1];
				}
				# if -B was always available, we could skip this, but it is not
				elsif (/GLX Visuals/){
					last;
				}
			}
			my ($direct_render,$renderer,$version) = ('N/A','N/A','N/A');
			$direct_render = join ', ',  @direct_render if @direct_render;
			# non free drivers once filtered and cleaned show the same for core and compat
			# but this stopped for some reason at 4.5/4.6 nvidia
			if (@core_profile_version && @opengl_version && 
			  join ('', @core_profile_version) ne join( '', @opengl_version) &&
			  !(grep {/nvidia/i} @opengl_version ) ){
				@opengl_version = @core_profile_version;
				$b_compat = 1;
			}
			$version = join ', ', @opengl_version if @opengl_version;
			$renderer = join ', ', @renderer if @renderer;
			@row = ({
			main::key($num++,1,1,'OpenGL') => '',
			main::key($num++,1,2,'renderer') => ($renderer) ? $renderer : 'N/A',
			main::key($num++,0,2,'v') => ($version) ? $version : 'N/A',
			});
			if ($b_compat && $extra > 1 && $compat_version){
				$row[0]{main::key($num++,0,2,'compat-v')} = $compat_version;
			}
			if ($extra > 0){
				$row[0]{main::key($num++,0,2,'direct render')} = $direct_render;
			}
		}
		else {
			@row = ({
			main::key($num++,0,1,'Message') => main::row_defaults('glxinfo-missing'),
			});
		}
	}
	else {
		my $type = 'display-console';
		if (!main::check_program('glxinfo')){
			$type = 'glxinfo-missing';
		}
		else {
			if ($b_root){
				$type = 'display-root';
			}
			else {
				$type = 'display-try';
			}
		}
		@row = ({
		main::key($num++,0,1,'Message') => main::row_defaults($type),
		});
	}
	eval $end if $b_log;
	return @row;
}
sub tty_data(){
	eval $start if $b_log;
	my ($tty);
	if ($size{'term-cols'}){
		$tty = "$size{'term-cols'}x$size{'term-lines'}";
	}
	elsif ($b_irc && $client{'console-irc'}){
		my $tty_working = main::get_tty_console_irc('tty');
		if (my $program = main::check_program('stty')){
			my $tty_arg = ($bsd_type) ? '-f' : '-F';
			$tty = (main::grabber("$program $tty_arg /dev/pts/$tty_working size 2>/dev/null"))[0];
			if ($tty){
				my @temp = split /\s+/, $tty;
				$tty = "$temp[1]x$temp[0]";
			}
		}
	}
	eval $end if $b_log;
	return $tty;
}
sub x_drivers {
	eval $start if $b_log;
	my ($driver,@driver_data,,%drivers);
	my ($alternate,$failed,$loaded,$sep,$unloaded) = ('','','','','');
	if (my $log = main::system_files('xorg-log')){
		# $log = "$ENV{HOME}/bin/scripts/inxi/data/xorg-logs/Xorg.0-voyager-serena.log";
		# $log = "$ENV{HOME}/bin/scripts/inxi/data/xorg-logs/loading-unload-failed-all41-mint.txt";
		# $log = "$ENV{HOME}/bin/scripts/inxi/data/xorg-logs/loading-unload-failed-phd21-mint.txt";
		# $log = "$ENV{HOME}/bin/scripts/inxi/data/xorg-logs/Xorg.0-gm10.log";
		# $log = "$ENV{HOME}/bin/scripts/inxi/data/xorg-logs/xorg-multi-driver-1.log";
		my @xorg = main::reader($log);
		# list is from sgfxi plus non-free drivers, plus ARM drivers
		my $list = join '|',qw(amdgpu apm ark armsoc atimisc ati 
		chips cirrus cyrix fbdev fbturbo fglrx geode glide glint 
		i128 i740 i810-dec100 i810e i810 i815 i830 i845 i855 i865 i915 i945 i965 
		iftv imstt intel ivtv mach64 mesa mga modesetting 
		neomagic newport nouveau nsc nvidia nv openchrome r128 radeonhd radeon 
		rendition s3virge s3 savage siliconmotion sisimedia sisusb sis 
		sunbw2 suncg14 suncg3 suncg6 sunffb sunleo suntcx
		tdfx tga trident tseng unichrome v4l vboxvideo vesa vga via vmware vmwgfx
		voodoo);
		# it's much cheaper to grab the simple pattern match then do the expensive one 
		# in the main loop.
		#@xorg = grep {/Failed|Unload|Loading/} @xorg;
		foreach (@xorg){
			next if !/Failed|Unload|Loading/;
			# print "$_\n";
			# note that in file names, driver is always lower case
			if (/\sLoading.*($list)_drv.so$/i ) {
				$driver=lc($1);
				# we get all the actually loaded drivers first, we will use this to compare the
				# failed/unloaded, which have not always actually been truly loaded
				$drivers{$driver}='loaded';
			}
			# openbsd uses UnloadModule: 
			elsif (/(Unloading\s|UnloadModule).*\"?($list)(_drv.so)?\"?$/i ) {
				$driver=lc($2);
				# we get all the actually loaded drivers first, we will use this to compare the
				# failed/unloaded, which have not always actually been truly loaded
				if (exists $drivers{$driver} && $drivers{$driver} ne 'alternate'){
					$drivers{$driver}='unloaded';
				}
			}
			# verify that the driver actually started the desktop, even with false failed messages 
			# which can occur. This is the driver that is actually driving the display.
			# note that xorg will often load several modules, like modesetting,fbdev,nouveau
			# NOTE:
			#(II) UnloadModule: "nouveau"
			#(II) Unloading nouveau
			#(II) Failed to load module "nouveau" (already loaded, 0)
			#(II) LoadModule: "modesetting"
			elsif (/Failed.*($list)\"?.*$/i ) {
				# Set driver to lower case because sometimes it will show as 
				# RADEON or NVIDIA in the actual x start
				$driver=lc($1);
				# we need to make sure that the driver has already been truly loaded, 
				# not just discussed
				if (exists $drivers{$driver} && $drivers{$driver} ne 'alternate'){
					if ( $_ !~ /\(already loaded/){
						$drivers{$driver}='failed';
					}
					# reset the previous line's 'unloaded' to 'loaded' as well
					else {
						$drivers{$driver}='loaded';
					}
				}
				elsif ($_ =~ /module does not exist/){
					$drivers{$driver}='alternate';
				}
			}
		}
		my $sep = '';
		foreach (sort keys %drivers){
			if ($drivers{$_} eq 'loaded') {
				$sep = ($loaded) ? ',' : '';
				$loaded .= $sep . $_;
			}
			elsif ($drivers{$_} eq 'unloaded') {
				$sep = ($unloaded) ? ',' : '';
				$unloaded .= $sep . $_;
			}
			elsif ($drivers{$_} eq 'failed') {
				$sep = ($failed) ? ',' : '';
				$failed .= $sep . $_;
			}
			elsif ($drivers{$_} eq 'alternate') {
				$sep = ($alternate) ? ',' : '';
				$alternate .= $sep . $_;
			}
		}
		@driver_data = ($loaded,$unloaded,$failed,$alternate);
	}
	eval $end if $b_log;
	return @driver_data;
}
# fallback if no glx x version data found
sub x_version {
	eval $start if $b_log;
	my ($version,@data,$program);
	# load the extra X paths, it's important that these are first, because
	# later Xorg versions show error if run in console or ssh if the true path 
	# is not used.
	@paths = ( qw(/usr/lib /usr/lib/xorg /usr/lib/xorg-server /usr/libexec /usr/X11R6/bin), @paths );
	# IMPORTANT: both commands send version data to stderr!
	if ($program = main::check_program('Xorg')){
		@data = main::grabber("$program -version 2>&1");
	}
	elsif ($program = main::check_program('X')){
		@data = main::grabber("$program -version 2>&1");
	}
	elsif ($program = main::check_program('Xvesa')){
		@data = main::grabber("$program -version 2>&1");
	}
	#print join('^ ', @paths), " :: $program\n";
	#print Data::Dumper::Dumper \@data;
	if (@data){
		foreach (@data){
			if (/^X.org X server/i){
				$version = (split /\s+/, $_)[3];
				last;
			}
			elsif (/^X Window System Version/i) {
				$version = (split /\s+/, $_)[4];
				last;
			}
			elsif (/^Xvesa from/i) {
				$version = (split /\s+/, $_)[3];
				$version = "Xvesa $version" if $version;
				last;
			}
		}
	}
	# remove extra X paths
	@paths = grep { !/^\/usr\/lib|xorg|X11R6|libexec/ } @paths;
	eval $end if $b_log;
	return $version;
}
# $1 - protocol: wayland|x11
sub display_compositor {
	eval $start if $b_log;
	my ($protocol) = @_; 
	my ($compositor) = ('');
	main::set_ps_gui() if !$b_ps_gui;
	if (@ps_gui){
		# 1 check program; 2 search; 3 unused version; 4 print
		my @compositors = (
		['asc','asc','','asc'],
		['budgie-wm','budgie-wm','','budgie-wm'],
		# owned by: compiz-core in debian
		['compiz','compiz','','compiz'],
		['compton','compton','','compton'],
		# as of version 20 is wayland compositor
		['enlightenment','enlightenment','','enlightenment'],
		['gnome-shell','gnome-shell','','gnome-shell'],
		['kwin_wayland','kwin_wayland','','kwin_wayland'],
		['kwin_x11','kwin_x11','','kwin_x11'],
		#['kwin','kwin','','kwin'],
		['marco','marco','','marco'],
		['muffin','muffin','','muffin'],
		['mutter','mutter','','mutter'],
		['weston','weston','','weston'],
		# these are more obscure, so check for them last
		['3dwm','3dwm','','3dwm'],
		['dcompmgr','dcompmgr','','dcompmgr'],
		['dwc','dwc','','dwc'],
		['fireplace','fireplace','','fireplace'],
		['grefson','grefson','','grefson'],
		['kmscon','kmscon','','kmscon'],
		['liri','liri','','liri'],
		['metisse','metisse','','metisse'],
		['mir','mir','','mir'],
		['moblin','moblin','','moblin'],
		['motorcar','motorcar','','motorcar'],
		['orbital','orbital','','orbital'],
		['papyros','papyros','','papyros'],
		['perceptia','perceptia','','perceptia'],
		['picom','picom','','picom'],
		['rustland','rustland','','rustland'],
		['sommelier','sommelier','','sommelier'],
		['sway','sway','','sway'],
		['swc','swc','','swc'],
		['ukwm','ukwm','','ukwm'],
		['unagi','unagi','','unagi'],
		['unity-system-compositor','unity-system-compositor','','unity-system-compositor'],
		['way-cooler','way-cooler','','way-cooler'],
		['wavy','wavy','','wavy'],
		['wayfire','wayfire','','wayfire'],
		['wayhouse','wayhouse','','wayhouse'],
		['westford','westford','','westford'],
		['xcompmgr','xcompmgr','','xcompmgr'],
		);
		foreach my $item (@compositors){
			# no need to use check program with short list of ps_gui
			# if (main::check_program($item[0]) && (grep {/^$item[1]$/} @ps_gui ) ){
			if (grep {/^$item->[1]$/} @ps_gui){
				$compositor = $item->[3];
				last;
			}
		}
	}
	main::log_data('data',"compositor: $compositor") if $b_log;
	eval $end if $b_log;
	return $compositor;
}
}

## MachineData
{
package MachineData;

sub get {
	eval $start if $b_log;
	my (%soc_machine,@data,@rows,$key1,$val1,$which);
	my $num = 0;
	if ($bsd_type && @sysctl_machine && !$b_dmidecode_force ){
		@data = machine_data_sysctl();
		if (!@data && !$key1){
			$key1 = 'Message';
			$val1 = main::row_defaults('machine-data-force-dmidecode','');
		}
	}
	elsif ($bsd_type || $b_dmidecode_force){
		my $ref = $alerts{'dmidecode'};
		if ( !$b_fake_dmidecode && $$ref{'action'} ne 'use'){
			$key1 = $$ref{'action'};
			$val1 = $$ref{$key1};
			$key1 = ucfirst($key1);
		}
		else {
			@data = machine_data_dmi();
			if (!@data && !$key1){
				$key1 = 'Message';
				$val1 = main::row_defaults('machine-data','');
			}
		}
	}
	elsif (-d '/sys/class/dmi/id/') {
		@data = machine_data_sys();
		if (!@data){
			$key1 = 'Message';
			$val1 = main::row_defaults('machine-data-dmidecode','');
		}
	}
	elsif (!$bsd_type) {
		# this uses /proc/cpuinfo so only GNU/Linux
		if ($b_arm || $b_mips || $b_ppc){
			%soc_machine = machine_data_soc();
			@data = create_output_soc(%soc_machine) if %soc_machine;
		}
		if (!@data){
			$key1 = 'Message';
			$val1 = main::row_defaults('machine-data-force-dmidecode','');
		}
	}
	# if error case, null data, whatever
	if ($key1) {
		@data = ({main::key($num++,0,1,$key1) => $val1,});
	}
	eval $end if $b_log;
	return @data;
}
## keys for machine data are:
# 0-sys_vendor 1-product_name 2-product_version 3-product_serial 4-product_uuid 
# 5-board_vendor 6-board_name 7-board_version 8-board_serial 
# 9-bios_vendor 10-bios_version 11-bios_date
## with extra data: 
# 12-chassis_vendor 13-chassis_type 14-chassis_version 15-chassis_serial
## unused: 16-bios_rev  17-bios_romsize 18 - firmware type
sub create_output {
	eval $start if $b_log;
	my ($ref) = @_;
	my (%data,@row,@rows);
	%data = %$ref;
	my $firmware = 'BIOS';
	my $num = 0;
	my $j = 0;
	my ($b_chassis,$b_skip_chassis,$b_skip_system);
	my ($bios_date,$bios_rev,$bios_romsize,$bios_vendor,$bios_version,$chassis_serial,
	$chassis_type,$chassis_vendor,$chassis_version, $mobo_model,$mobo_serial,$mobo_vendor,
	$mobo_version,$product_name,$product_serial,$product_version,$system_vendor);
# 	foreach my $key (keys %data){
# 		print "$key: $data{$key}\n";
# 	}
	if (!$data{'sys_vendor'} || ($data{'board_vendor'} && 
       $data{'sys_vendor'} eq $data{'board_vendor'} && !$data{'product_name'} && 
	    !$data{'product_version'} && !$data{'product_serial'})){
		$b_skip_system = 1;
	}
	# found a case of battery existing but having nothing in it on desktop mobo
	# not all laptops show the first. /proc/acpi/battery is deprecated.
	elsif ( !glob('/proc/acpi/battery/*') && !glob('/sys/class/power_supply/*') ){
		# ibm / ibm can be true; dell / quantum is false, so in other words, only do this
		# in case where the vendor is the same and the version is the same and not null, 
		# otherwise the version information is going to be different in all cases I think
		if ( ($data{'sys_vendor'} && $data{'sys_vendor'} eq $data{'board_vendor'} ) &&
			( ($data{'product_version'} && $data{'product_version'} eq $data{'board_version'} ) ||
			(!$data{'product_version'} && $data{'product_name'} && $data{'board_name'} && 
			$data{'product_name'} eq $data{'board_name'} ) ) ){
			$b_skip_system = 1;
		}
	}
	$data{'device'} ||= 'N/A';
	$j = scalar @rows;
	@row = ({
	main::key($num++,0,1,'Type') => ucfirst($data{'device'}),
	},);
	@rows = (@rows,@row);
	if (!$b_skip_system){
		# this has already been tested for above so we know it's not null
		$system_vendor = main::cleaner($data{'sys_vendor'});
		$product_name = ($data{'product_name'}) ? $data{'product_name'}:'N/A';
		$product_version = ($data{'product_version'}) ? $data{'product_version'}:'N/A';
		$product_serial = main::apply_filter($data{'product_serial'});
		$rows[$j]{main::key($num++,1,1,'System')} = $system_vendor;
		$rows[$j]{main::key($num++,0,2,'product')} = $product_name;
		$rows[$j]{main::key($num++,0,2,'v')} = $product_version;
		$rows[$j]{main::key($num++,0,2,'serial')} = $product_serial;
		# no point in showing chassis if system isn't there, it's very unlikely that 
		# would be correct
		if ($extra > 1){
			if ($data{'board_version'} && $data{'chassis_version'} eq $data{'board_version'}){
				$b_skip_chassis = 1;
			}
			if (!$b_skip_chassis && $data{'chassis_vendor'} ){
				if ($data{'chassis_vendor'} ne $data{'sys_vendor'} ){
					$chassis_vendor = $data{'chassis_vendor'};
				}
				# dmidecode can have these be the same
				if ($data{'chassis_type'} && $data{'device'} ne $data{'chassis_type'} ){
					$chassis_type = $data{'chassis_type'};
				}
				if ($data{'chassis_version'}){
					$chassis_version = $data{'chassis_version'};
					$chassis_version =~ s/^v([0-9])/$1/i;
				}
				$chassis_serial = main::apply_filter($data{'chassis_serial'});
				$chassis_vendor ||= '';
				$chassis_type ||= '';
				$rows[$j]{main::key($num++,1,1,'Chassis')} = $chassis_vendor;
				if ($chassis_type){
					$rows[$j]{main::key($num++,0,2,'type')} = $chassis_type;
				}
				if ($chassis_version){
					$rows[$j]{main::key($num++,0,2,'v')} = $chassis_version;
				}
				$rows[$j]{main::key($num++,0,2,'serial')} = $chassis_serial;
			}
		}
		$j++; # start new row
	}
	if ($data{'firmware'}){
		$firmware = $data{'firmware'};
	}
	$mobo_vendor = ($data{'board_vendor'}) ? main::cleaner($data{'board_vendor'}) : 'N/A';
	$mobo_model = ($data{'board_name'}) ? $data{'board_name'}: 'N/A';
	$mobo_version = ($data{'board_version'})? $data{'board_version'} : '';
	$mobo_serial = main::apply_filter($data{'board_serial'});
	$bios_vendor = ($data{'bios_vendor'}) ? main::cleaner($data{'bios_vendor'}) : 'N/A';
	if ($data{'bios_version'}){
		$bios_version = $data{'bios_version'};
		$bios_version =~ s/^v([0-9])/$1/i;
		if ($data{'bios_rev'}){
			$bios_rev = $data{'bios_rev'};
		}
	}
	$bios_version ||= 'N/A';
	if ($data{'bios_date'}){
		$bios_date = $data{'bios_date'};
	}
	$bios_date ||= 'N/A';
	if ($extra > 1 && $data{'bios_romsize'}){
		$bios_romsize = $data{'bios_romsize'};
	}
	$rows[$j]{main::key($num++,1,1,'Mobo')} = $mobo_vendor;
	$rows[$j]{main::key($num++,0,2,'model')} = $mobo_model;
	if ($mobo_version){
		$rows[$j]{main::key($num++,0,2,'v')} = $mobo_version;
	}
	$rows[$j]{main::key($num++,0,2,'serial')} = $mobo_serial;
	if ($extra > 2 && $data{'board_uuid'}){
		$rows[$j]{main::key($num++,0,2,'uuid')} = $data{'board_uuid'};
	}
	$rows[$j]{main::key($num++,1,1,$firmware)} = $bios_vendor;
	$rows[$j]{main::key($num++,0,2,'v')} = $bios_version;
	if ($bios_rev){
		$rows[$j]{main::key($num++,0,2,'rev')} = $bios_rev;
	}
	$rows[$j]{main::key($num++,0,2,'date')} = $bios_date;
	if ($bios_romsize){
		$rows[$j]{main::key($num++,0,2,'rom size')} = $bios_romsize;
	}
	eval $end if $b_log;
	return @rows;
}
sub create_output_soc {
	my (%soc_machine) = @_;
	my ($key,%data,@row,@rows);
	my ($cont_sys,$ind_sys,$j,$num) = (1,1,0,0);
	#print Data::Dumper::Dumper \%soc_machine;
	# this is sketchy, /proc/device-tree/model may be similar to Hardware value from /proc/cpuinfo
	# raspi: Hardware	: BCM2835 model: Raspberry Pi Model B Rev 2
	if ($soc_machine{'device'} || $soc_machine{'model'}){
		if ($b_arm){$key = 'ARM Device'}
		elsif ($b_mips){$key = 'MIPS Device'}
		elsif ($b_ppc){$key = 'PowerPC Device'}
		$rows[$j]{main::key($num++,0,1,'Type')} = $key;
		my $system = 'System';
		if (defined $soc_machine{'model'}){
			$rows[$j]{main::key($num++,1,1,'System')} = $soc_machine{'model'};
			$system = 'details';
			($cont_sys,$ind_sys) = (0,2);
		}
		$soc_machine{'device'} ||= 'N/A';
		$rows[$j]{main::key($num++,$cont_sys,$ind_sys,$system)} = $soc_machine{'device'};
	}
	# we're going to print N/A for 0000 values sine the item was there.
	if ($soc_machine{'firmware'}){
		# most samples I've seen are like: 0000
		$soc_machine{'firmware'} =~ s/^[0]+$//;
		$soc_machine{'firmware'} ||= 'N/A';
		$rows[$j]{main::key($num++,0,2,'rev')} = $soc_machine{'firmware'};
	}
	# sometimes has value like: 0000
	if (defined $soc_machine{'serial'}){
		# most samples I've seen are like: 0000
		$soc_machine{'serial'} =~ s/^[0]+$//;
		$rows[$j]{main::key($num++,0,2,'serial')} = main::apply_filter($soc_machine{'serial'});
	}
	eval $end if $b_log;
	return @rows;
}

sub machine_data_sys {
	eval $start if $b_log;
	my (%data,$path,$vm);
	my $sys_dir = '/sys/class/dmi/id/';
	my $sys_dir_alt = '/sys/devices/virtual/dmi/id/';
	my @sys_files = qw(bios_vendor bios_version bios_date 
	board_name board_serial board_vendor board_version chassis_type 
	product_name product_serial product_uuid product_version sys_vendor
	);
	if ($extra > 1){
		splice @sys_files, 0, 0, qw( chassis_serial chassis_vendor chassis_version);
	}
	$data{'firmware'} = 'BIOS';
	# print Data::Dumper::Dumper \@sys_files;
	if (!-d $sys_dir ){
		if ( -d $sys_dir_alt){
			$sys_dir = $sys_dir_alt;
		}
		else {
			return 0;
		}
	}
	if ( -d '/sys/firmware/efi'){
		$data{'firmware'} = 'UEFI';
	}
	elsif ( glob('/sys/firmware/acpi/tables/UEFI*') ){
		$data{'firmware'} = 'UEFI [Legacy]';
	}
	foreach (@sys_files){
		$path = "$sys_dir$_";
		if (-r $path){
			$data{$_} = (main::reader($path))[0];
			$data{$_} = ($data{$_}) ? main::dmi_cleaner($data{$_}) : '';
		}
		elsif (!$b_root && -e $path && !-r $path ){
			$data{$_} = main::row_defaults('root-required');
		}
		else {
			$data{$_} = '';
		}
	}
	if ($data{'chassis_type'}){
		if ( $data{'chassis_type'} == 1){
			$data{'device'} = get_device_vm($data{'sys_vendor'},$data{'product_name'});
			$data{'device'} ||= 'other-vm?';
		}
		else {
			$data{'device'} = get_device_sys($data{'chassis_type'});
		}
	}
# 	print "sys:\n";
# 	foreach (keys %data){
# 		print "$_: $data{$_}\n";
# 	}
	main::log_data('dump','%data',\%data) if $b_log;
	my @rows = create_output(\%data);
	eval $end if $b_log;
	return @rows;
}
# this will create an alternate machine data source
# which will be used for alt ARM machine data in cases 
# where no dmi data present, or by cpu data to guess at 
# certain actions for arm only.
sub machine_data_soc {
	eval $end if $b_log;
	my (%soc_machine,@temp);
	if (my $file = main::system_files('cpuinfo')){
		#$file = "$ENV{'HOME'}/bin/scripts/inxi/data/cpu/arm/arm-shevaplug-1.2ghz.txt";
		my @data = main::reader($file);
		foreach (@data){
			if (/^(Hardware|machine)\s*:/i){
				@temp = split /\s*:\s*/, $_;
				$temp[1] = main::arm_cleaner($temp[1]);
				$temp[1] = main::dmi_cleaner($temp[1]);
				$soc_machine{'device'} = main::cleaner($temp[1]);
			}
			elsif (/^(system type|model)\s*:/i){
				@temp = split /\s*:\s*/, $_;
				$temp[1] = main::dmi_cleaner($temp[1]);
				$soc_machine{'model'} = main::cleaner($temp[1]);
			}
			elsif (/^Revision/i){
				@temp = split /\s*:\s*/, $_;
				$soc_machine{'firmware'} = $temp[1];
			}
			elsif (/^Serial/i){
				@temp = split /\s*:\s*/, $_;
				$soc_machine{'serial'} = $temp[1];
			}
		}
	}
	if (!$soc_machine{'model'} && -r '/system/build.prop'){
		main::set_build_prop() if !$b_build_prop;
		if ($build_prop{'product-manufacturer'} && $build_prop{'product-model'}){
			my $brand = '';
			if ($build_prop{'product-brand'} && 
			 $build_prop{'product-brand'} ne $build_prop{'product-manufacturer'}) { 
				$brand = $build_prop{'product-brand'} . ' ';
			}
			$soc_machine{'model'} = $brand . $build_prop{'product-manufacturer'} . ' ' . $build_prop{'product-model'};
		}
		elsif ($build_prop{'product-device'} ){
			$soc_machine{'model'} = $build_prop{'product-device'};
		}
		elsif ($build_prop{'product-name'} ){
			$soc_machine{'model'} = $build_prop{'product-name'};
		}
	}
	if (!$soc_machine{'model'} && -f '/proc/device-tree/model'){
		my $model  = (main::reader('/proc/device-tree/model'))[0];
		main::log_data('data',"device-tree-model: $model") if $b_log;
		if ( $model ){
			$model = main::dmi_cleaner($model);
			$model = (split /\x01|\x02|\x03|\x00/, $model)[0] if $model;
			my $device_temp = main::regex_cleaner($soc_machine{'device'});
			if ( !$soc_machine{'device'} || ($model && $model !~ /\Q$device_temp\E/i) ){
				$model = main::arm_cleaner($model);
				$soc_machine{'model'} = $model;
			}
		}
	}
	if (!$soc_machine{'serial'} && -f '/proc/device-tree/serial-number'){
		my $serial  = (main::reader('/proc/device-tree/serial-number'))[0];
		$serial = (split /\x01|\x02|\x03|\x00/, $serial)[0] if $serial;
		main::log_data('data',"device-tree-serial: $serial") if $b_log;
		$soc_machine{'serial'} = $serial if $serial;
	}
	
	#print Data::Dumper::Dumper \%soc_machine;
	eval $end if $b_log;
	return %soc_machine;
}

# bios_date: 09/07/2010
# bios_romsize: dmi only
# bios_vendor: American Megatrends Inc.
# bios_version: P1.70
# bios_rev: 8.14:  dmi only
# board_name: A770DE+
# board_serial: 
# board_vendor: ASRock
# board_version: 
# chassis_serial: 
# chassis_type: 3
# chassis_vendor: 
# chassis_version: 
# firmware: 
# product_name: 
# product_serial: 
# product_uuid: 
# product_version: 
# sys_uuid: dmi/sysctl only
# sys_vendor:
sub machine_data_dmi {
	eval $start if $b_log;
	my (%data,$vm);
	return if ! @dmi;
	$data{'firmware'} = 'BIOS';
	# dmi types:
	# 0 bios; 1 system info; 2 board|base board info; 3 chassis info; 
	# 4 processor info, use to check for hypervisor
	foreach (@dmi){
		my @ref = @$_;
		# bios/firmware
		if ($ref[0] == 0){
			# skip first three row, we don't need that data
			splice @ref, 0, 3 if @ref;
			foreach my $item (@ref){
				if ($item !~ /^~/){ # skip the indented rows
					my @value = split /:\s+/, $item;
					if ($value[0] eq 'Release Date') {$data{'bios_date'} = main::dmi_cleaner($value[1]) }
					elsif ($value[0] eq 'Vendor') {$data{'bios_vendor'} = main::dmi_cleaner($value[1]) }
					elsif ($value[0] eq 'Version') {$data{'bios_version'} = main::dmi_cleaner($value[1]) }
					elsif ($value[0] eq 'ROM Size') {$data{'bios_romsize'} = main::dmi_cleaner($value[1]) }
					elsif ($value[0] eq 'BIOS Revision') {$data{'bios_rev'} = main::dmi_cleaner($value[1]) }
					elsif ($value[0] =~ /^UEFI is supported/) {$data{'firmware'} = 'UEFI';}
				}
			}
			next;
		}
		# system information
		elsif ($ref[0] == 1){
			# skip first three row, we don't need that data
			splice @ref, 0, 3 if @ref;
			foreach my $item (@ref){
				if ($item !~ /^~/){ # skip the indented rows
					my @value = split /:\s+/, $item;
					if ($value[0] eq 'Product Name') {$data{'product_name'} = main::dmi_cleaner($value[1]) }
					elsif ($value[0] eq 'Version') {$data{'product_version'} = main::dmi_cleaner($value[1]) }
					elsif ($value[0] eq 'Serial Number') {$data{'product_serial'} = main::dmi_cleaner($value[1]) }
					elsif ($value[0] eq 'Manufacturer') {$data{'sys_vendor'} = main::dmi_cleaner($value[1]) }
					elsif ($value[0] eq 'UUID') {$data{'sys_uuid'} = main::dmi_cleaner($value[1]) }
				}
			}
			next;
		}
		# baseboard information
		elsif ($ref[0] == 2){
			# skip first three row, we don't need that data
			splice @ref, 0, 3 if @ref;
			foreach my $item (@ref){
				if ($item !~ /^~/){ # skip the indented rows
					my @value = split /:\s+/, $item;
					if ($value[0] eq 'Product Name') {$data{'board_name'} = main::dmi_cleaner($value[1]) }
					elsif ($value[0] eq 'Serial Number') {$data{'board_serial'} = main::dmi_cleaner($value[1]) }
					elsif ($value[0] eq 'Manufacturer') {$data{'board_vendor'} = main::dmi_cleaner($value[1]) }
				}
			}
			next;
		}
		# chassis information
		elsif ($ref[0] == 3){
			# skip first three row, we don't need that data
			splice @ref, 0, 3 if @ref;
			foreach my $item (@ref){
				if ($item !~ /^~/){ # skip the indented rows
					my @value = split /:\s+/, $item;
					if ($value[0] eq 'Serial Number') {$data{'chassis_serial'} = main::dmi_cleaner($value[1]) }
					elsif ($value[0] eq 'Type') {$data{'chassis_type'} = main::dmi_cleaner($value[1]) }
					elsif ($value[0] eq 'Manufacturer') {$data{'chassis_vendor'} = main::dmi_cleaner($value[1]) }
					elsif ($value[0] eq 'Version') {$data{'chassis_version'} = main::dmi_cleaner($value[1]) }
				}
			}
			if ( $data{'chassis_type'} && $data{'chassis_type'} ne 'Other' ){
				$data{'device'} = $data{'chassis_type'};
			}
			next;
		}
		# this may catch some BSD and fringe Linux cases
		# processor information: check for hypervisor
		elsif ($ref[0] == 4){
			# skip first three row, we don't need that data
			splice @ref, 0, 3 if @ref;
			if (!$data{'device'}){
				if (grep {/hypervisor/i} @ref){
					$data{'device'} = 'virtual-machine';
				}
			}
			last;
		}
		elsif ($ref[0] > 4){
			last;
		}
	}
	if (!$data{'device'}){
		$data{'device'} = get_device_vm($data{'sys_vendor'},$data{'product_name'});
		$data{'device'} ||= 'other-vm?';
	}
# 	print "dmi:\n";
# 	foreach (keys %data){
# 		print "$_: $data{$_}\n";
# 	}
	main::log_data('dump','%data',\%data) if $b_log;
	my @rows = create_output(\%data);
	eval $end if $b_log;
	return @rows;
}
# As far as I know, only OpenBSD supports this method.
# it uses hw. info from sysctl -a and bios info from dmesg.boot
sub machine_data_sysctl {
	eval $start if $b_log;
	my (%data,$vm);
	# ^hw\.(vendor|product|version|serialno|uuid)
	foreach (@sysctl_machine){
		next if ! $_;
		my @item = split /:/, $_;
		next if ! $item[1];
		if ($item[0] eq 'hw.vendor'){
			$data{'board_vendor'} = main::dmi_cleaner($item[1]);
		}
		elsif ($item[0] eq 'hw.product'){
			$data{'board_name'} = main::dmi_cleaner($item[1]);
		}
		elsif ($item[0] eq 'hw.version'){
			$data{'board_version'} = $item[1];
		}
		elsif ($item[0] eq 'hw.serialno'){
			$data{'board_serial'} = $item[1];
		}
		elsif ($item[0] eq 'hw.serial'){
			$data{'board_serial'} = $item[1];
		}
		elsif ($item[0] eq 'hw.uuid'){
			$data{'board_uuid'} = $item[1];
		}
		# bios0:at mainbus0: AT/286+ BIOS, date 06/30/06, BIOS32 rev. 0 @ 0xf2030, SMBIOS rev. 2.4 @ 0xf0000 (47 entries)
		# bios0:vendor Phoenix Technologies, LTD version "3.00" date 06/30/2006
		elsif ($item[0] =~ /^bios[0-9]/){
			if ($_ =~ /^^bios[0-9]:at\s.*\srev\.\s([\S]+)\s@.*/){
				$data{'bios_rev'} = $1;
				$data{'firmware'} = 'BIOS' if $_ =~ /BIOS/;
			}
			elsif ($item[1] =~ /^vendor\s(.*)\sversion\s"?([\S]+)"?\sdate\s([\S]+)/ ){
				$data{'bios_vendor'} = $1;
				$data{'bios_version'} = $2;
				$data{'bios_date'} = $3;
				$data{'bios_version'} =~ s/^v//i if $data{'bios_version'} && $data{'bios_version'} !~ /vi/i;
			}
		}
	}
	my @rows = create_output(\%data);
	eval $end if $b_log;
	return @rows;
}

sub get_device_sys {
	eval $start if $b_log;
	my ($chasis_id) = @_;
	my ($device) = ('');
	my @chassis;
	# See inxi-resources MACHINE DATA for data sources
	$chassis[2] = 'unknown';
	$chassis[3] = 'desktop';
	$chassis[4] = 'desktop';
	# 5 - pizza box was a 1 U desktop enclosure, but some old laptops also id this way
	$chassis[5] = 'pizza-box';
	$chassis[6] = 'desktop';
	$chassis[7] = 'desktop';
	$chassis[8] = 'portable';
	$chassis[9] = 'laptop';
	# note: lenovo T420 shows as 10, notebook,  but it's not a notebook
	$chassis[10] = 'laptop';
	$chassis[11] = 'portable';
	$chassis[12] = 'docking-station';
	# note: 13 is all-in-one which we take as a mac type system
	$chassis[13] = 'desktop';
	$chassis[14] = 'notebook';
	$chassis[15] = 'desktop';
	$chassis[16] = 'laptop';
	$chassis[17] = 'server';
	$chassis[18] = 'expansion-chassis';
	$chassis[19] = 'sub-chassis';
	$chassis[20] = 'bus-expansion';
	$chassis[21] = 'peripheral';
	$chassis[22] = 'RAID';
	$chassis[23] = 'server';
	$chassis[24] = 'desktop';
	$chassis[25] = 'multimount-chassis'; # blade?
	$chassis[26] = 'compact-PCI';
	$chassis[27] = 'blade';
	$chassis[28] = 'blade';
	$chassis[29] = 'blade-enclosure';
	$chassis[30] = 'tablet';
	$chassis[31] = 'convertible';
	$chassis[32] = 'detachable';
	$chassis[33] = 'IoT-gateway';
	$chassis[34] = 'embedded-pc';
	$chassis[35] = 'mini-pc';
	$chassis[36] = 'stick-pc';
	$device = $chassis[$chasis_id] if $chassis[$chasis_id];
	eval $end if $b_log;
	return $device;
}

sub get_device_vm {
	eval $start if $b_log;
	my ($manufacturer,$product_name) = @_;
	my $vm;
	if ( my $program = main::check_program('systemd-detect-virt') ){
		my $vm_test = (main::grabber("$program 2>/dev/null"))[0];
		if ($vm_test){
			# kvm vbox reports as oracle, usually, unless they change it
			if (lc($vm_test) eq 'oracle'){
				$vm = 'virtualbox';
			}
			elsif ( $vm_test ne 'none'){
				$vm = $vm_test;
			}
		}
	}
	if (!$vm || lc($vm) eq 'bochs') {
		if (-e '/proc/vz'){$vm = 'openvz'}
		elsif (-e '/proc/xen'){$vm = 'xen'}
		elsif (-e '/dev/vzfs'){$vm = 'virtuozzo'}
		elsif (my $program = main::check_program('lsmod')){
			my @vm_data = main::grabber("$program 2>/dev/null");
			if (@vm_data){
				if (grep {/kqemu/i} @vm_data){$vm = 'kqemu'}
				elsif (grep {/kvm/i} @vm_data){$vm = 'kvm'}
				elsif (grep {/qemu/i} @vm_data){$vm = 'qemu'}
			}
		}
	}
	# this will catch many Linux systems and some BSDs
	if (!$vm || lc($vm) eq 'bochs' ) {
		# $device_vm is '' if nothing detected
		my @vm_data = (@sysctl,@dmesg_boot,$device_vm);
		if (-e '/dev/disk/by-id'){
			my @dev = glob('/dev/disk/by-id/*');
			@vm_data = (@vm_data,@dev);
		}
		if ( grep {/innotek|vbox|virtualbox/i} @vm_data){
			$vm = 'virtualbox';
		}
		elsif (grep {/vmware/i} @vm_data){
			$vm = 'vmware';
		}
		elsif (grep {/Virtual HD/i} @vm_data){
			$vm = 'hyper-v';
		}
		if (!$vm && (my $file = main::system_files('cpuinfo'))){
			my @info = main::reader($file);
			$vm = 'virtual-machine' if grep {/^flags.*hypervisor/} @info;
		}
		if (!$vm && -e '/dev/vda' || -e '/dev/vdb' || -e '/dev/xvda' || -e '/dev/xvdb' ){
			$vm = 'virtual-machine';
		}
	}
	if (!$vm  && $product_name){
		if ($product_name eq 'VMware'){
			$vm = 'vmware';
		}
		elsif ($product_name eq 'VirtualBox'){
			$vm = 'virtualbox';
		}
		elsif ($product_name eq 'KVM'){
			$vm = 'kvm';
		}
		elsif ($product_name eq 'Bochs'){
			$vm = 'qemu';
		}
	}
	if (!$vm && $manufacturer && $manufacturer eq 'Xen'){
		$vm = 'xen';
	}
	eval $end if $b_log;
	return $vm;
}

}

## NetworkData 
{
package NetworkData;
my ($b_ip_run,@ifs_found);
sub get {
	eval $start if $b_log;
	my (@data,@rows);
	my $num = 0;
	if (($b_arm || $b_mips) && !$b_soc_net && !$b_pci_tool){
		# do nothing, but keep the test conditions to force 
		# the non arm case to always run
	}
	else {
		@data = card_data();
		@rows = (@rows,@data) if @data;
	}
	@data = usb_data();
	@rows = (@rows,@data) if @data;
	# note: rasberry pi uses usb networking only 
	if (!@rows && ($b_arm || $b_mips)){
		my $type = ($b_arm) ? 'arm' : 'mips';
		my $key = 'Message';
		@data = ({
		main::key($num++,0,1,$key) => main::row_defaults($type . '-pci',''),
		},);
		@rows = (@rows,@data);
	}
	if ($show{'network-advanced'}){
		# @ifs_found = ();
		# shift @ifs_found;
		# pop @ifs_found;
		if (!$bsd_type){
			@data = advanced_data_sys('check','',0,'','','');
			@rows = (@rows,@data) if @data;
		}
		else {
			@data = advanced_data_bsd('check');
			@rows = (@rows,@data) if @data;
		}
	}
	if ($show{'ip'}){
		@data = wan_ip();
		@rows = (@rows,@data);
	}
	eval $end if $b_log;
	return @rows;
}

sub card_data {
	eval $start if $b_log;
	my ($b_wifi,@rows,@data,%holder);
	my ($j,$num) = (0,1);
	foreach (@devices_network){
		$num = 1;
		my @row = @$_;
		#print "$row[0] $row[3]\n"; 
		#print "$row[0] $row[3]\n";
		$j = scalar @rows;
		my $driver = $row[9];
		my $chip_id = "$row[5]:$row[6]";
		# working around a virtuo bug same chip id is used on two nics
		if (!defined $holder{$chip_id}){
			$holder{$chip_id} = 0;
		}
		else {
			$holder{$chip_id}++; 
		}
		# first check if it's a known wifi id'ed card, if so, no print of duplex/speed
		$b_wifi = check_wifi($row[4]);
		my $card = $row[4];
		$card = ($card) ? main::pci_cleaner($card,'output') : 'N/A';
		#$card ||= 'N/A';
		$driver ||= 'N/A';
		@data = ({
		main::key($num++,1,1,'Device') => $card,
		},);
		@rows = (@rows,@data);
		if ($extra > 0 && $b_pci_tool && $row[12]){
			my $item = main::get_pci_vendor($row[4],$row[12]);
			$rows[$j]{main::key($num++,0,2,'vendor')} = $item if $item;
		}
		if ($row[1] eq '0680'){
			$rows[$j]{main::key($num++,0,2,'type')} = 'network bridge';
		}
		$rows[$j]{main::key($num++,1,2,'driver')} = $driver;
		my $bus_id = 'N/A';
		# note: for arm/mips we want to see the single item bus id, why not?
		# note: we can have bus id: 0002 / 0 which is valid, but 0 / 0 is invalid
		if (defined $row[2] && $row[2] ne '0' && defined $row[3]){$bus_id = "$row[2].$row[3]"}
		elsif (defined $row[2] && $row[2] ne '0'){$bus_id = $row[2]}
		elsif (defined $row[3] && $row[3] ne '0'){$bus_id = $row[3]}
		if ($extra > 0){
			if ($row[9] && !$bsd_type){
				my $version = main::get_module_version($row[9]);
				$version ||= 'N/A';
				$rows[$j]{main::key($num++,0,3,'v')} = $version;
			}
			if ($b_admin && $row[10]){
				$row[10] = main::get_driver_modules($row[9],$row[10]);
				$rows[$j]{main::key($num++,0,3,'modules')} = $row[10] if $row[10];
			}
			$row[8] ||= 'N/A';
			# as far as I know, wifi has no port, but in case it does in future, use it
			$rows[$j]{main::key($num++,0,2,'port')} = $row[8] if (!$b_wifi || ( $b_wifi && $row[8] ne 'N/A') );
			$rows[$j]{main::key($num++,0,2,'bus ID')} = $bus_id;
		}
		if ($extra > 1){
			$rows[$j]{main::key($num++,0,2,'chip ID')} = $chip_id;
		}
		if ($show{'network-advanced'}){
			@data = ();
			if (!$bsd_type){
				@data = advanced_data_sys($row[5],$row[6],$holder{$chip_id},$b_wifi,'',$bus_id);
			}
			else {
				@data = advanced_data_bsd("$row[9]$row[11]",$b_wifi) if defined $row[9] && defined $row[11];
			}
			@rows = (@rows,@data) if @data;
		}
		#print "$row[0]\n";
	}
	# @rows = ();
	# we want to handle ARM errors in main get
	if (!@rows && !$b_arm && !$b_mips){
		my $key = 'Message';
		my $type = 'pci-card-data';
		if ($pci_tool && ${$alerts{$pci_tool}}{'action'} eq 'permissions'){
			$type = 'pci-card-data-root';
		}
		@data = ({
		main::key($num++,0,1,$key) => main::row_defaults($type,''),
		},);
		@rows = (@rows,@data);
		
	}
	#my $ref = $pci[-1];
	#print $$ref[0],"\n";
	eval $end if $b_log;
	return @rows;
}
sub usb_data {
	eval $start if $b_log;
	my (@data,@rows,@temp2,$b_wifi,$driver,
	$path,$path_id,$product,$test,$type);
	my ($j,$num) = (0,1);
	return if !@usb;
	foreach my $ref (@usb){
		my @row = @$ref;
		# a device will always be the second or > device on the bus, except for 
		# daisychained hubs
		if ($row[1] > 1 && $row[4] ne '9'){
			$num = 1;
			($driver,$path,$path_id,$product,$test,$type) = ('','','','','','');
			$product = main::cleaner($row[13]) if $row[13];
			$driver = $row[15] if $row[15];
			$path = $row[3] if $row[3];
			$path_id = $row[2] if $row[2];
			$type = $row[14] if $row[14];
			$test = "$driver $product $type";
			if ($product && network_device($test)){
				$driver ||= 'usb-network';
				@data = ({
				main::key($num++,1,1,'Device') => $product,
				main::key($num++,0,2,'type') => 'USB',
				main::key($num++,0,2,'driver') => $driver,
				},);
				$b_wifi = check_wifi($product);
				@rows = (@rows,@data);
				if ($extra > 0){
					$rows[$j]{main::key($num++,0,2,'bus ID')} = "$path_id:$row[1]";
				}
				if ($extra > 1){
					$rows[$j]{main::key($num++,0,2,'chip ID')} = $row[7];
				}
				if ($extra > 2 && $row[16]){
					$rows[$j]{main::key($num++,0,2,'serial')} = main::apply_filter($row[16]);
				}
				if ($show{'network-advanced'}){
					@data = ();
					if (!$bsd_type){
						my (@temp,$vendor,$chip);
						@temp = split (/:/, $row[7]) if $row[7];
						($vendor,$chip) = ($temp[0],$temp[1]) if @temp;
						@data = advanced_data_sys($vendor,$chip,0,$b_wifi,$path,'');
					}
					# NOTE: we need the driver.number, like wlp0 to get a match, and 
					# we can't get that from usb data, so we have to let it fall back down 
					# to the check function for BSDs.
					#else {
					#	@data = advanced_data_bsd($row[2],$b_wifi);
					#}
					@rows = (@rows,@data) if @data;
				}
				$j = scalar @rows;
			}
		}
	}
	eval $end if $b_log;
	return @rows;
}
sub advanced_data_sys {
	eval $start if $b_log;
	return if ! -d '/sys/class/net';
	my ($vendor,$chip,$count,$b_wifi,$path_usb,$bus_id) = @_;
	my ($cont_if,$ind_if,$num) = (2,3,0);
	my $key = 'IF';
	my ($b_check,$b_usb,$if,$path,@paths,@row,@rows);
	# ntoe: we've already gotten the base path, now we 
	# we just need to get the IF path, which is one level in:
	# usb1/1-1/1-1:1.0/net/enp0s20f0u1/
	if ($path_usb){
		$b_usb = 1;
		@paths = main::globber("${path_usb}*/net/*");
	}
	else {
		@paths = main::globber('/sys/class/net/*');
	}
	@paths = grep {!/\/lo$/} @paths;
	if ( $count > 0 && $count < scalar @paths ){
		@paths = splice @paths, $count, scalar @paths;
	}
	if ($vendor eq 'check'){
		$b_check = 1;
		$key = 'IF-ID';
		($cont_if,$ind_if) = (1,2);
	}
	#print join '; ', @paths,  $count, "\n";
	foreach (@paths){
		my ($data1,$data2,$duplex,$mac,$speed,$state);
		# for usb, we already know where we are
		if (!$b_usb){
			if (( !$b_arm && !$b_ppc) || $b_pci_tool ){
				$path = "$_/device/vendor";
				$data1 = (main::reader($path))[0] if -e $path;
				$data1 =~ s/^0x// if $data1;
				$path = "$_/device/device";
				$data2 = (main::reader($path))[0] if -e $path;
				$data2 =~ s/^0x// if $data2;
				# this is a fix for a redhat bug in virtio 
				$data2 = (defined $data2 && $data2 eq '0001' && defined $chip && $chip eq '1000') ? '1000' : $data2;
			}
			elsif ($b_arm || $b_ppc) {
				$path = Cwd::abs_path($_);
				$path =~ /($chip)/;
				if ($1){
					$data1 = $vendor;
					$data2 = $chip;
				}
			}
		}
		# print "d1:$data1 v:$vendor d2:$data2 c:$chip bus_id: $bus_id\n";
		# print Cwd::abs_path($_), "\n" if $bus_id;
		if ( $b_usb || $b_check || ( $data1 && $data2 && $data1 eq $vendor && $data2 eq $chip && 
		( ($b_arm || $b_mips || $b_ppc || $b_sparc) || check_bus_id($_,$bus_id) ) ) ) {
			$if = $_;
			$if =~ s/^\/.+\///;
			# print "top: if: $if ifs: @ifs_found\n";
			next if ($b_check && grep {/$if/} @ifs_found);
			$path = "$_/duplex";
			$duplex = (main::reader($path))[0] if -e $path;
			$duplex ||= 'N/A';
			$path = "$_/address";
			$mac = (main::reader($path))[0] if -e $path;
			$mac = main::apply_filter($mac);
			$path = "$_/speed";
			$speed = (main::reader($path))[0] if -e $path;
			$speed ||= 'N/A';
			$path = "$_/operstate";
			$state = (main::reader($path))[0] if -e $path;
			$state ||= 'N/A';
			#print "$speed \n";
			@row = ({
			main::key($num++,1,$cont_if,$key) => $if,
			main::key($num++,0,$ind_if,'state') => $state,
			},);
			#my $j = scalar @row - 1;
			push (@ifs_found, $if) if (!$b_check && (! grep {/$if/} @ifs_found));
			# print "push: if: $if ifs: @ifs_found\n";
			# no print out for wifi since it doesn't have duplex/speed data available
			# note that some cards show 'unknown' for state, so only testing explicitly
			# for 'down' string in that to skip showing speed/duplex
			# /sys/class/net/$if/wireless : nont always there, but worth a try: wlan/wl/ww/wlp
			$b_wifi = 1 if !$b_wifi && ( -e "$_$if/wireless" || $if =~ /^(wl|ww)/);
			if (!$b_wifi && $state ne 'down' && $state ne 'no'){
				# make sure the value is strictly numeric before appending Mbps
				$speed = ( main::is_int($speed) ) ? "$speed Mbps" : $speed;
				$row[0]{main::key($num++,0,$ind_if,'speed')} = $speed;
				$row[0]{main::key($num++,0,$ind_if,'duplex')} = $duplex;
			}
			$row[0]{main::key($num++,0,$ind_if,'mac')} = $mac;
			if ($b_check){
				@rows = (@rows,@row);
			}
			else {
				@rows = @row;
			}
			if ($show{'ip'}){
				@row = if_ip($key,$if);
				@rows = (@rows,@row);
			}
			last if !$b_check;
		}
	}
	eval $end if $b_log;
	return @rows;
}

sub advanced_data_bsd {
	eval $start if $b_log;
	return if ! @ifs_bsd;
	my ($if,$b_wifi) = @_;
	my (@data,@row,@rows,$working_if);
	my ($b_check,$state,$speed,$duplex,$mac);
	my ($cont_if,$ind_if,$num) = (2,3,0);
	my $key = 'IF';
	my $j = 0;
	if ($if eq 'check'){
		$b_check = 1;
		$key = 'IF-ID';
		($cont_if,$ind_if) = (1,2);
	}
	foreach my $ref (@ifs_bsd){
		if (ref $ref ne 'ARRAY'){
			$working_if = $ref;
			# print "$working_if\n";
			next;
		} 
 		else {
			@data = @$ref;
 		}
		if ( $b_check || $working_if eq $if){
			$if = $working_if if $b_check;
			# print "top: if: $if ifs: @ifs_found\n";
			next if ($b_check && grep {/$if/} @ifs_found);
			foreach my $line (@data){
				# ($state,$speed,$duplex,$mac)
				$duplex = $data[2];
				$duplex ||= 'N/A';
				$mac = main::apply_filter($data[3]);
				$speed = $data[1];
				$speed ||= 'N/A';
				$state = $data[0];
				$state ||= 'N/A';
				#print "$speed \n";
				@row = ({
				main::key($num++,1,$cont_if,$key) => $if,
				main::key($num++,0,$ind_if,'state') => $state,
				},);
				push (@ifs_found, $if) if (!$b_check && (! grep {/$if/} @ifs_found ));
				# print "push: if: $if ifs: @ifs_found\n";
				# no print out for wifi since it doesn't have duplex/speed data available
				# note that some cards show 'unknown' for state, so only testing explicitly
				# for 'down' string in that to skip showing speed/duplex
				if (!$b_wifi && $state ne 'down' && $state ne 'no'){
					# make sure the value is strictly numeric before appending Mbps
					$speed = ( main::is_int($speed) ) ? "$speed Mbps" : $speed;
					$row[0]{main::key($num++,0,$ind_if,'speed')} = $speed;
					$row[0]{main::key($num++,0,$ind_if,'duplex')} = $duplex;
				}
				$row[0]{main::key($num++,0,$ind_if,'mac')} = $mac;
			}
			@rows = (@rows,@row);
			if ($show{'ip'}){
				@row = if_ip($key,$if) if $if;
				@rows = (@rows,@row) if @row;
			}
		}
	}
	eval $end if $b_log;
	return @rows;
}
## values:
# 0 - ipv 
# 1 - ip 
# 2 - broadcast, if found 
# 3 - scope, if found 
# 4 - scope if, if different from if
sub if_ip {
	eval $start if $b_log;
	my ($type,$if) = @_;
	my (@data,@row,@rows,$working_if);
	my ($cont_ip,$ind_ip) = (3,4);
	my $num = 0;
	my $j = 0;
	$b_ip_run = 1;
	if ($type eq 'IF-ID'){
		($cont_ip,$ind_ip) = (2,3);
	}
	OUTER:
	foreach my $ref (@ifs){
		if (ref $ref ne 'ARRAY'){
			$working_if = $ref;
			# print "if:$if wif:$working_if\n";
			next;
		} 
 		else {
			@data = @$ref;
			# print "ref:$ref\n";
 		}
		if ($working_if eq $if){
			foreach my $ref2 (@data){
				$j = scalar @rows;
				$num = 1;
				if ($limit > 0 && $j >= $limit){
					@row  = ({
					main::key($num++,0,$cont_ip,'Message') => main::row_defaults('output-limit',scalar @data),
					},);
					@rows = (@rows,@row);
					last OUTER;
				}
				my @data2 = @$ref2;
				#print "$data2[0] $data2[1]\n";
				my ($ipv,$ip,$broadcast,$scope,$scope_id);
				$ipv = ($data2[0])? $data2[0]: 'N/A';
				$ip = main::apply_filter($data2[1]);
				$scope = ($data2[3])? $data2[3]: 'N/A';
				# note: where is this ever set to 'all'? Old test condition?
				if ($if ne 'all'){
					if (defined $data2[4] && $working_if ne $data2[4]){
						# scope global temporary deprecated dynamic 
						# scope global dynamic 
						# scope global temporary deprecated dynamic 
						# scope site temporary deprecated dynamic 
						# scope global dynamic noprefixroute enx403cfc00ac68
						# scope global eth0
						# scope link
						# scope site dynamic 
						# scope link 
						# trim off if at end of multi word string if found
						$data2[4] =~ s/\s$if$// if $data2[4] =~ /[^\s]+\s$if$/;
						my $key = ($data2[4] =~ /deprecated|dynamic|temporary|noprefixroute/ ) ? 'type':'virtual' ;
						@row  = ({
						main::key($num++,1,$cont_ip,"IP v$ipv") => $ip,
						main::key($num++,0,$ind_ip,$key) => $data2[4],
						main::key($num++,0,$ind_ip,'scope') => $scope,
						},);
					}
					else {
						@row  = ({
						main::key($num++,1,$cont_ip,"IP v$ipv") => $ip,
						main::key($num++,0,$ind_ip,'scope') => $scope,
						},);
					}
				}
				else {
					@row  = ({
					main::key($num++,1,($cont_ip - 1 ),'IF') => $if,
					main::key($num++,1,$cont_ip,"IP v$ipv") => $ip,
					main::key($num++,0,$ind_ip,'scope') => $scope,
					},);
				}
				@rows = (@rows,@row);
				if ($extra > 1 && $data2[2]){
					$broadcast = main::apply_filter($data2[2]);
					$rows[$j]{main::key($num++,0,$ind_ip,'broadcast')} = $broadcast;
				}
			}
		}
	}
	eval $end if $b_log;
	return @rows;
}
# get ip using downloader to stdout. This is a clean, text only IP output url,
# single line only, ending in the ip address. May have to modify this in the future
# to handle ipv4 and ipv6 addresses but should not be necessary.
# ip=$( echo  2001:0db8:85a3:0000:0000:8a2e:0370:7334 | gawk  --re-interval '
# ip=$( wget -q -O - $WAN_IP_URL | gawk  --re-interval '
# this generates a direct dns based ipv4 ip address, but if opendns.com goes down, 
# the fall backs will still work. 
# note: consistently slower than domain based: 
# dig +short +time=1 +tries=1 myip.opendns.com. A @208.67.222.222
sub wan_ip {
	eval $start if $b_log;
	my (@data,$b_dig,$b_html,$ip,$ua);
	my $num = 0;
	# time: 0.06 - 0.07 seconds
	# cisco opendns.com may be terminating supporting this one, sometimes works, sometimes not: 
	# use -4/6 to force ipv 4 or 6, but generally we want the 'natural' native
	# ip returned.
	# dig +short +time=1 +tries=1 myip.opendns.com @resolver1.opendns.com 
	# dig +short @ns1-1.akamaitech.net ANY whoami.akamai.net
	# this one can take forever, and sometimes requires explicit -4 or -6
	# dig -4 TXT +short o-o.myaddr.l.google.com @ns1.google.com

	if (!$b_skip_dig && (my $program = main::check_program('dig') )){
		$ip = (main::grabber("$program +short +time=1 +tries=1 \@ns1-1.akamaitech.net ANY whoami.akamai.net 2>/dev/null"))[0];
		$b_dig = 1;
	}
	if (!$ip && !$b_no_html_wan) {
		# note: tests: akamai: 0.055 - 0.065 icanhazip.com: 0.177 0.164
		# smxi: 0.525, so almost 10x slower. Dig is fast too
		# leaving smxi as last test because I know it will always be up.
		# --wan-ip-url replaces values with user supplied arg
		# 0.059s: http://whatismyip.akamai.com/
		# 0.255s: https://get.geojs.io/v1/ip
		# 0.371s: http://icanhazip.com/
		# 0.430s: https://smxi.org/opt/ip.php
		my @urls = (!$wan_url) ? qw( http://whatismyip.akamai.com/ 
		 http://icanhazip.com/ https://smxi.org/opt/ip.php) : ($wan_url);
		foreach (@urls){
			$ua = 'ip' if $_ =~ /smxi/;
			$ip = main::download_file('stdout',$_,'',$ua);
			if ($ip){
				# print "$_\n";
				chomp $ip;
				$ip = (split /\s+/, $ip)[-1];
				last;
			}
		}
		$b_html = 1;
	}
	if ($ip && $use{'filter'}){
		$ip = $filter_string;
	}
	if (!$ip){
		# true case trips
		if (!$b_dig){
			$ip = main::row_defaults('IP-no-dig', 'WAN IP'); 
		}
		elsif ($b_dig && !$b_html){
			$ip = main::row_defaults('IP-dig', 'WAN IP');
		}
		else {
			$ip = main::row_defaults('IP', 'WAN IP');
		}
	}
	@data = ({
	main::key($num++,0,1,'WAN IP') => $ip,
	},);
	eval $end if $b_log;
	return @data;
}

### USB networking search string data, because some brands can have other products than
### wifi/nic cards, they need further identifiers, with wildcards.
### putting the most common and likely first, then the less common, then some specifics

# Wi-Fi.*Adapter Wireless.*Adapter Ethernet.*Adapter WLAN.*Adapter 
# Network.*Adapter 802\.11 Atheros Atmel D-Link.*Adapter D-Link.*Wireless Linksys 
# Netgea Ralink Realtek.*Network Realtek.*Wireless Realtek.*WLAN Belkin.*Wireless 
# Belkin.*WLAN Belkin.*Network Actiontec.*Wireless Actiontec.*Network AirLink.*Wireless 
# Asus.*Network Asus.*Wireless Buffalo.*Wireless Davicom DWA-.*RangeBooster DWA-.*Wireless 
# ENUWI-.*Wireless LG.*Wi-Fi Rosewill.*Wireless RNX-.*Wireless Samsung.*LinkStick 
# Samsung.*Wireless Sony.*Wireless TEW-.*Wireless TP-Link.*Wireless 
# WG[0-9][0-9][0-9].*Wireless WNA[0-9][0-9][0-9] WNDA[0-9][0-9][0-9] 
# Zonet.*ZEW.*Wireless
sub network_device {
	eval $start if $b_log;
	my ($device_string) = @_;
	my ($b_network);
	# belkin=050d; d-link=07d1; netgear=0846; ralink=148f; realtek=0bda; 
	# Atmel makes other stuff. NOTE: exclude 'networks': IMC Networks
	my @tests = qw(wifi Wi-Fi.*Adapter Ethernet \bLAN\b WLAN Network\b Networking\b 802\.11 
	Wireless.*Adapter 54\sMbps 100\/1000 Mobile\sBroadband Atheros D-Link.*Adapter 
	Dell.*Wireless D-Link.*Wireless Linksys Netgea Ralink Realtek.*Network Realtek.*Wireless
	Belkin.*Wireless Actiontec.*Wireless AirLink.*Wireless Asus.*Wireless 
	Buffalo.*Wireless Davicom DWA-.*RangeBooster DWA-.*Wireless
	ENUWI-.*Wireless LG.*Wi-Fi Rosewill.*Wireless RNX-.*Wireless Samsung.*LinkStick 
	Samsung.*Wireless Sony.*Wireless TEW-.*Wireless TP-Link.*Wireless 
	WG[0-9][0-9][0-9].*Wireless WNA[0-9][0-9][0-9] WNDA[0-9][0-9][0-9] 
	Zonet.*ZEW.*Wireless 050d:935b 0bda:8189 0bda:8197
	);
	foreach (@tests){
		if ($device_string =~ /$_/i ){
			$b_network = 1;
			last;
		}
	}
	eval $end if $b_log;
	return $b_network;
}
sub check_bus_id {
	eval $start if $b_log;
	my ($path,$bus_id) = @_;
	my ($b_valid);
	if ($bus_id){
		# legacy, not link, but uevent has path: 
		# PHYSDEVPATH=/devices/pci0000:00/0000:00:0a.1/0000:05:00.0
		if (Cwd::abs_path($path) =~ /$bus_id\// || 
		 ( -r "$path/uevent" && -s "$path/uevent" && 
		 (grep {/$bus_id/} main::reader("$path/uevent") ) ) ){
			$b_valid = 1;
		}
	}
	eval $end if $b_log;
	return $b_valid;
}
sub check_wifi {
	my ($item) = @_;
	my $b_wifi = ($item =~ /wireless|wifi|wi-fi|wlan|802\.11|centrino/i) ? 1 : 0;
	return $b_wifi;
}
}

## OpticalData
{
package OpticalData;

sub get {
	eval $start if $b_log;
	my (@data,@rows,$key1,$val1);
	my $num = 0;
	if ($bsd_type){
		#@data = optical_data_bsd();
		$key1 = 'Optical Report';
		$val1 = main::row_defaults('optical-data-bsd');
		@data = ({main::key($num++,0,1,$key1) => $val1,});
		if ( @dm_boot_optical){
			@data = optical_data_bsd();
		}
		else{
			my $file = main::system_files('dmesg-boot');
			if ( $file && ! -r $file ){
				$val1 = main::row_defaults('dmesg-boot-permissions');
			}
			elsif (!$file){
				$val1 = main::row_defaults('dmesg-boot-missing');
			}
			else {
				$val1 = main::row_defaults('optical-data-bsd');
			}
			$key1 = 'Optical Report';
			@data = ({main::key($num++,0,1,$key1) => $val1,});
		}
	}
	else {
		@data = optical_data_linux();
	}
	if (!@data){
		$key1 = 'Message';
		$val1 = main::row_defaults('optical-data');
		@data = ({main::key($num++,0,1,$key1) => $val1,});
	}
	@rows = (@rows,@data);
	eval $end if $b_log;
	return @rows;
}
sub create_output {
	eval $start if $b_log;
	my (%devices) = @_;
	my (@data,@rows);
	my $num = 0;
	my $j = 0;
	# build floppy if any
	foreach my $key (sort keys %devices){
		if ($devices{$key}{'type'} eq 'floppy'){
			@data = ({ main::key($num++,0,1,ucfirst($devices{$key}{'type'})) => "/dev/$key"});
			@rows = (@rows,@data);
			delete $devices{$key};
		}
	}
	foreach my $key (sort keys %devices){
		$j = scalar @rows;
		$num = 1;
		my $vendor = $devices{$key}{'vendor'};
		$vendor ||= 'N/A';
		my $model = $devices{$key}{'model'};
		$model ||= 'N/A';
		@data = ({ 
		main::key($num++,1,1,ucfirst($devices{$key}{'type'})) => "/dev/$key",
		main::key($num++,0,2,'vendor') => $vendor,
		main::key($num++,0,2,'model') => $model,
		});
		@rows = (@rows,@data);
		if ($extra > 0){
			my $rev = $devices{$key}{'rev'};
			$rev ||= 'N/A';
			$rows[$j]{ main::key($num++,0,2,'rev')} = $rev;
		}
		if ($extra > 1 && $devices{$key}{'serial'}){
			$rows[$j]{ main::key($num++,0,2,'serial')} = main::apply_filter($devices{$key}{'serial'});
		}
		my $ref = $devices{$key}{'links'};
		my $links = (@$ref) ? join ',', sort @$ref: 'N/A' ;
		$rows[$j]{ main::key($num++,0,2,'dev-links')} = $links;
		if ($show{'optical'}){
			$j = scalar @rows;
			my $speed = $devices{$key}{'speed'};
			$speed ||= 'N/A';
			my ($audio,$multisession) = ('','');
			if (defined $devices{$key}{'multisession'}){
				$multisession = ( $devices{$key}{'multisession'} == 1 ) ? 'yes' : 'no' ;
			}
			$multisession ||= 'N/A';
			if (defined $devices{$key}{'audio'}){
				$audio = ( $devices{$key}{'audio'} == 1 ) ? 'yes' : 'no' ;
			}
			$audio ||= 'N/A';
			my $dvd = 'N/A';
			my (@rw,$rws);
			if (defined $devices{$key}{'dvd'}){
				$dvd = ( $devices{$key}{'dvd'} == 1 ) ? 'yes' : 'no' ;
			}
			if ($devices{$key}{'cdr'}){
				push @rw, 'cd-r';
			}
			if ($devices{$key}{'cdrw'}){
				push @rw, 'cd-rw';
			}
			if ($devices{$key}{'dvdr'}){
				push @rw, 'dvd-r';
			}
			if ($devices{$key}{'dvdram'}){
				push @rw, 'dvd-ram';
			}
			$rws = (@rw) ? join ',', @rw: 'none' ;
			@data = ({
			main::key($num++,1,2,'Features') => '',
			main::key($num++,0,3,'speed') => $speed,
			main::key($num++,0,3,'multisession') => $multisession,
			main::key($num++,0,3,'audio') => $audio,
			main::key($num++,0,3,'dvd') => $dvd,
			main::key($num++,0,3,'rw') => $rws,
			});
			@rows = (@rows,@data);
			if ($extra > 0 ){
				my $state = $devices{$key}{'state'};
				$state ||= 'N/A';
				$rows[$j]{ main::key($num++,0,3,'state')} = $state;
			}
		}
	}
	#print Data::Dumper::Dumper \%devices;
	eval $end if $b_log;
	return @rows;
}
sub optical_data_bsd {
	eval $start if $b_log;
	my (@data,%devices,@rows,@temp);
	my ($count,$i,$working) = (0,0,'');
	foreach (@dm_boot_optical){
		$_ =~ s/(cd[0-9]+)\(([^:]+):([0-9]+):([0-9]+)\):/$1:$2-$3.$4,/;
		my @row = split /:\s*/, $_;
		next if ! defined $row[1];
		if ($working ne $row[0]){
			# print "$id_holder $row[0]\n";
			$working = $row[0];
		}
		# no dots, note: ada2: 2861588MB BUT: ada2: 600.000MB/s 
		if (! exists $devices{$working}){
			$devices{$working} = ({});
			$devices{$working}{'links'} = ([]);
			$devices{$working}{'model'} = '';
			$devices{$working}{'rev'} = '';
			$devices{$working}{'state'} = '';
			$devices{$working}{'vendor'} = '';
			$devices{$working}{'temp'} = '';
			$devices{$working}{'type'} = ($working =~ /^cd/) ? 'optical' : 'unknown';
		}
		#print "$_\n";
		if ($bsd_type ne 'openbsd'){
			if ($row[1] && $row[1] =~ /^<([^>]+)>/){
				$devices{$working}{'model'} = $1;
				$count = ($devices{$working}{'model'} =~ tr/ //);
				if ($count && $count > 1){
					@temp = split /\s+/, $devices{$working}{'model'};
					$devices{$working}{'vendor'} = $temp[0];
					my $index = ($#temp > 2 ) ? ($#temp - 1): $#temp;
					$devices{$working}{'model'} = join ' ', @temp[1..$index];
					$devices{$working}{'rev'} = $temp[-1] if $count > 2;
				}
				if ($show{'optical'}){
					if (/\bDVD\b/){
						$devices{$working}{'dvd'} = 1;
					}
					if (/\bRW\b/){
						$devices{$working}{'cdrw'} = 1;
						$devices{$working}{'dvdr'} = 1 if $devices{$working}{'dvd'};
					}
				}
			}
			if ($row[1] && $row[1] =~ /^Serial/){
				@temp = split /\s+/,$row[1];
				$devices{$working}{'serial'} = $temp[-1];
			}
			if ($show{'optical'}){
				if ($row[1] =~ /^([0-9\.]+[MGTP][B]?\/s)/){
					$devices{$working}{'speed'} = $1;
					$devices{$working}{'speed'} =~ s/\.[0-9]+//;
				}
				if (/\bDVD[-]?RAM\b/){
					$devices{$working}{'cdr'} = 1;
					$devices{$working}{'dvdram'} = 1;
				}
				if ($row[2] && $row[2] =~ /,\s(.*)$/){
					$devices{$working}{'state'} = $1;
					$devices{$working}{'state'} =~ s/\s+-\s+/, /;
				}
			}
		}
		else {
			if ($row[2] && $row[2] =~ /<([^>]+)>/){
				$devices{$working}{'model'} = $1;
				$count = ($devices{$working}{'model'} =~ tr/,//);
				#print "c: $count $row[2]\n";
				if ($count && $count > 1){
					@temp = split /,\s*/, $devices{$working}{'model'};
					$devices{$working}{'vendor'} = $temp[0];
					$devices{$working}{'model'} = $temp[1];
					$devices{$working}{'rev'} = $temp[2];
				}
				if ($show{'optical'}){
					if (/\bDVD\b/){
						$devices{$working}{'dvd'} = 1;
					}
					if (/\bRW\b/){
						$devices{$working}{'cdrw'} = 1;
						$devices{$working}{'dvdr'} = 1 if $devices{$working}{'dvd'};
					}
					if (/\bDVD[-]?RAM\b/){
						$devices{$working}{'cdr'} = 1;
						$devices{$working}{'dvdram'} = 1;
					}
				}
			}
			if ($show{'optical'}){
				#print "$row[1]\n";
				if (($row[1] =~ tr/,//) > 1){
					@temp = split /,\s*/, $row[1];
					$devices{$working}{'speed'} = $temp[2];
				}
				
			}
		}
	}
	
	main::log_data('dump','%devices',\%devices) if $b_log;
	#print Data::Dumper::Dumper \%devices;
	@rows = create_output(%devices) if %devices;
	eval $end if $b_log;
	return @rows;
}
sub optical_data_linux {
	eval $start if $b_log;
	my (@data,%devices,@info,@rows);
	@data = main::globber('/dev/dvd* /dev/cdr* /dev/scd* /dev/sr* /dev/fd[0-9]');
	# Newer kernel is NOT linking all optical drives. Some, but not all.
	# Get the actual disk dev location, first try default which is easier to run, 
	# need to preserve line breaks
	foreach (@data){
		my $working = readlink($_);
		$working = ($working) ? $working: $_;
		next if $working =~ /random/;
		# possible fix: puppy has these in /mnt not /dev they say
		$working =~ s/\/(dev|media|mnt)\///;
		$_ =~ s/\/(dev|media|mnt)\///;
		if  (! defined $devices{$working}){
			my @temp = ($_ ne $working) ? ([$_]) : ([]);
			$devices{$working} = ({'links' => @temp});
			$devices{$working}{'type'} = ($working =~ /^fd/) ? 'floppy' : 'optical' ;
		}
 		else {
			my $ref = $devices{$working}{'links'};
 			push @$ref, $_ if $_ ne $working;
 		}
		#print "$working\n";
	}
	if ($show{'optical'} && -e '/proc/sys/dev/cdrom/info'){
		@info = main::reader('/proc/sys/dev/cdrom/info','strip');
	}
	#print join '; ', @data, "\n";
	foreach my $key (keys %devices){
		next if $devices{$key}{'type'} eq 'floppy';
		my $device = "/sys/block/$key/device";
		if ( -d $device){
			if (-e "$device/vendor"){
				$devices{$key}{'vendor'} = (main::reader("$device/vendor"))[0];
				$devices{$key}{'vendor'} = main::cleaner($devices{$key}{'vendor'});
				$devices{$key}{'state'} = (main::reader("$device/state"))[0];
				$devices{$key}{'model'} = (main::reader("$device/model"))[0];
				$devices{$key}{'model'} = main::cleaner($devices{$key}{'model'});
				$devices{$key}{'rev'} = (main::reader("$device/rev"))[0];
			}
		}
		elsif ( -e "/proc/ide/$key/model"){
			$devices{$key}{'vendor'} = (main::reader("/proc/ide/$key/model"))[0];
			$devices{$key}{'vendor'} = main::cleaner($devices{$key}{'vendor'});
		}
		if ($show{'optical'} && @info){
			my $index = 0;
			foreach my $item (@info){
				next if $item =~ /^\s*$/;
				my @split = split '\s+', $item;
				if ($item =~ /^drive name:/){
					foreach my $id (@split){
						last if ($id eq $key);
						$index++;
					}
					last if ! $index; # index will be > 0 if it was found
				}
				elsif ($item =~/^drive speed:/) {
					$devices{$key}{'speed'} = $split[$index];
				}
				elsif ($item =~/^Can read multisession:/) {
					$devices{$key}{'multisession'}=$split[$index+1];
				}
				elsif ($item =~/^Can read MCN:/) {
					$devices{$key}{'mcn'}=$split[$index+1];
				}
				elsif ($item =~/^Can play audio:/) {
					$devices{$key}{'audio'}=$split[$index+1];
				}
				elsif ($item =~/^Can write CD-R:/) {
					$devices{$key}{'cdr'}=$split[$index+1];
				}
				elsif ($item =~/^Can write CD-RW:/) {
					$devices{$key}{'cdrw'}=$split[$index+1];
				}
				elsif ($item =~/^Can read DVD:/) {
					$devices{$key}{'dvd'}=$split[$index+1];
				}
				elsif ($item =~/^Can write DVD-R:/) {
					$devices{$key}{'dvdr'}=$split[$index+1];
				}
				elsif ($item =~/^Can write DVD-RAM:/) {
					$devices{$key}{'dvdram'}=$split[$index+1];
				}
			}
		}
	}
	main::log_data('dump','%devices',\%devices) if $b_log;
	#print Data::Dumper::Dumper \%devices;
	@rows = create_output(%devices) if %devices;
	eval $end if $b_log;
	return @rows;
}

}

## PartitionData
{
package PartitionData;

sub get {
	eval $start if $b_log;
	my (@rows,$key1,$val1);
	my $num = 0;
	partition_data() if !$b_partitions;
 	if (!@partitions) {
		$key1 = 'Message';
		#$val1 = ($bsd_type && $bsd_type eq 'darwin') ? 
		# main::row_defaults('darwin-feature') : main::row_defaults('partition-data');
		$val1 = main::row_defaults('partition-data');
		@rows = ({main::key($num++,0,1,$key1) => $val1,});
 	}
 	else {
		@rows = create_output();
 	}
	eval $end if $b_log;
	return @rows;
}
sub create_output {
	eval $start if $b_log;
	my $num = 0;
	my $j = 0;
	my (@data,@data2,%part,@rows,$dev,$dev_type,$fs,$percent,$raw_size,$size,$used);
	# alpha sort for non numerics
	if ($show{'partition-sort'} !~ /^(percent-used|size|used)$/){
		@partitions = sort { $a->{$show{'partition-sort'}} cmp $b->{$show{'partition-sort'}} } @partitions;
	}
	else {
		@partitions = sort { $a->{$show{'partition-sort'}} <=> $b->{$show{'partition-sort'}} } @partitions;
	}
	foreach my $ref (@partitions){
		my %row = %$ref;
		$num = 1;
		next if $row{'type'} eq 'secondary' && $show{'partition'};
		next if $show{'swap'} && $row{'fs'} && $row{'fs'} eq 'swap';
		next if $row{'swap-type'} && $row{'swap-type'} ne 'partition';
		if (!$row{'hidden'}){
			@data2 = main::get_size($row{'size'}) if (defined $row{'size'});
			$size = (@data2) ? $data2[0] . ' ' . $data2[1]: 'N/A';
			@data2 = main::get_size($row{'used'}) if (defined $row{'used'});
			$used = (@data2) ? $data2[0] . ' ' . $data2[1]: 'N/A';
			$percent = (defined $row{'percent-used'}) ? ' (' . $row{'percent-used'} . '%)' : '';
		}
		else {
			$percent = '';
			$used = $size = (!$b_root) ? main::row_defaults('root-required') : main::row_defaults('partition-hidden');
		}
		%part = ();
		$fs = ($row{'fs'}) ? lc($row{'fs'}): 'N/A';
		$dev_type = ($row{'dev-type'}) ? $row{'dev-type'} : 'dev';
		$row{'dev-base'} = '/dev/' . $row{'dev-base'} if $dev_type eq 'dev' && $row{'dev-base'};
		$dev = ($row{'dev-base'}) ? $row{'dev-base'} : 'N/A';
		$row{'id'} =~ s|/home/[^/]+/(.*)|/home/$filter_string/$1| if $use{'filter'};
		$j = scalar @rows;
		@data = ({
		main::key($num++,1,1,'ID') => $row{'id'},
		});
		@rows = (@rows,@data);
		if (($b_admin || $row{'hidden'}) && $row{'raw-size'} ){
			# It's an error! permissions or missing tool
			if (!main::is_numeric($row{'raw-size'})){
				$raw_size = $row{'raw-size'};
			}
			else {
				@data2 = main::get_size($row{'raw-size'});
				$raw_size = (@data2) ? $data2[0] . ' ' . $data2[1]: 'N/A';
			}
			$rows[$j]{main::key($num++,0,2,'raw size')} = $raw_size;
		}
		if ($b_admin && $row{'raw-available'} && $size ne 'N/A'){
			$size .=  ' (' . $row{'raw-available'} . '%)';
		}
		$rows[$j]{main::key($num++,0,2,'size')} = $size;
		$rows[$j]{main::key($num++,0,2,'used')} = $used . $percent;
		$rows[$j]{main::key($num++,0,2,'fs')} = $fs;
		if ($b_admin && $fs eq 'swap' && defined $row{'swappiness'}){
			$rows[$j]{main::key($num++,0,2,'swappiness')} = $row{'swappiness'};
		}
		if ($b_admin && $fs eq 'swap' && defined $row{'cache-pressure'}){
			$rows[$j]{main::key($num++,0,2,'cache pressure')} = $row{'cache-pressure'};
		}
		if ($extra > 1 && $fs eq 'swap' && defined $row{'priority'}){
			$rows[$j]{main::key($num++,0,2,'priority')} = $row{'priority'};
		}
		if ($b_admin && $row{'block-size'}){
			$rows[$j]{main::key($num++,0,2,'block size')} = $row{'block-size'} . ' B';;
			#$rows[$j]{main::key($num++,0,2,'physical')} = $row{'block-size'} . ' B';
			#$rows[$j]{main::key($num++,0,2,'logical')} = $row{'block-logical'} . ' B';
		}
		$rows[$j]{main::key($num++,0,2,$dev_type)} = $dev;
		if ($show{'label'}){
			$row{'label'} = main::apply_partition_filter('part', $row{'label'}, '') if $use{'filter-label'};
			$rows[$j]{main::key($num++,0,2,'label')} = ($row{'label'}) ? $row{'label'}: 'N/A';
		}
		if ($show{'uuid'}){
			$row{'uuid'} = main::apply_partition_filter('part', $row{'uuid'}, '') if $use{'filter-uuid'};
			$rows[$j]{main::key($num++,0,2,'uuid')} = ($row{'uuid'}) ? $row{'uuid'}: 'N/A';
		}
	}
	eval $end if $b_log;
	return @rows;
}

sub partition_data {
	eval $start if $b_log;
	#return if $bsd_type && $bsd_type eq 'darwin'; # darwin has muated output, of course
	my (@data,@rows,@mapper,@mount,@partitions_working,%part,@working);
	my ($b_fake_map,$b_fs,$b_load,$b_space,$cols,$roots) = (0,1,0,0,6,0);
	my ($back_size,$back_used) = (4,3);
	my ($block_size,$blockdev,$dev_base,$dev_type,$fs,$id,$label,$percent_used,
	$raw_size,$replace,$size_available,$size,$test,$type,$uuid,$used);
	$b_partitions = 1;
	if ($b_admin){
		# for partition block size
		$blockdev = main::check_program('blockdev');
		# for raw partition sizes
		DiskData::set_proc_partitions() if !$bsd_type && !$b_proc_partitions;
	}
	set_lsblk() if !$bsd_type && !$b_lsblk;
	# set labels, uuid, gpart
	set_label_uuid() if !$b_label_uuid;
	# most current OS support -T and -k, but -P means different things
	# in freebsd. However since most use is from linux, we make that default
	# android 7 no -T support
	if (!$bsd_type){
		@partitions_working = main::grabber("df -P -T -k 2>/dev/null");
		if (-d '/dev/mapper'){
			@mapper = main::globber('/dev/mapper/*');
		}
	}
	else {
		# this is missing the file system data
		if ($bsd_type ne 'darwin'){
			@partitions_working = main::grabber("df -T -k 2>/dev/null");
		}
		#Filesystem 1024-blocks Used Available Capacity iused ifree %iused Mounted on
		else {
			$cols = 8;
			($back_size,$back_used) = (7,6);
		}
		# turns out freebsd uses this junk too
		$b_fake_map = 1;
	}
	# busybox only supports -k and -P, openbsd, darwin
	if (!@partitions_working){
		@partitions_working = main::grabber("df -k 2>/dev/null");
		$b_fs = 0;
		$cols = 5 if !$bsd_type || $bsd_type ne 'darwin';
		if (my $path = main::check_program('mount')){
			@mount = main::grabber("$path 2>/dev/null");
		}
	}
	# determine positions
	my $row1 = shift @partitions_working;
	# new kernels/df have rootfs and / repeated, creating two entries for the same partition
	# so check for two string endings of / then slice out the rootfs one, I could check for it
	# before slicing it out, but doing that would require the same action twice re code execution
	foreach (@partitions_working){
		$roots++ if /\s\/$/;
	}
	@partitions_working = grep {!/^rootfs/} @partitions_working if $roots > 1;
	# IMPORTANT: check the lsblk completer tool check_partition_data() for matching lsblck
	# filters.
	my $filters = 'aufs|cgroup.*|cgmfs|configfs|debugfs|\/dev|dev|\/dev\/loop[0-9]*|';
	$filters .= 'devfs|devtmpfs|fdescfs|iso9660|linprocfs|none|procfs|\/run(\/.*)?|';
	$filters .= 'run|shm|squashfs|sys|\/sys\/.*|sysfs|tmpfs|type|udev|unionfs|vartmp';
	#push @partitions_working, '//mafreebox.freebox.fr/Disque dur cifs         239216096  206434016  20607496      91% /freebox/Disque dur';
	#push @partitions_working, '//mafreebox.freebox.fr/AllPG      cifs         436616192  316339304 120276888      73% /freebox/AllPG';
	foreach (@partitions_working){
		# apple crap, maybe also freebsd?
		$_ =~ s/^map\s+([\S]+)/map:\/$1/ if $b_fake_map;
		$b_space = 0;
		# handle spaces in remote filesystem names
		# busybox df shows KM, sigh.
		if (/^(.*)(\s[\S]+)\s+[a-z][a-z0-9]+\s+[0-9]+/){
			$replace = $test = "$1$2";
			if ($test =~ /\s/){
				$b_space = 1;
				$replace =~ s/\s/^^/g;
				#print ":$replace:\n";
				$_ =~ s/^$test/$replace/;
				#print "$_\n";
			}
		}
		
		my @row = split /\s+/, $_;
		# autofs is a bsd thing, has size 0
		if ($row[0] =~ /^($filters)$/ || $row[0] =~ /^ROOT/i || 
		   ($b_fs && ($row[2] == 0 || $row[1] =~ /^(autofs|iso9660|tmpfs)$/ ) )){
			next;
		}
		($dev_base,$dev_type,$fs,$id,$label,$type,$uuid) = ('','','','','','');
		($b_load,$block_size,$percent_used,$raw_size,$size_available,
		$size,$used) = (0,0,0,0,0,0,0,0);
		%part = ();
		# NOTE: using -P for linux fixes line wraps, and for bsds, assuming they don't use such long file names
		if ($row[0] =~ /^\/dev\/|:\/|\/\//){
			# this could point to by-label or by-uuid so get that first. In theory, abs_path should 
			# drill down to get the real path, but it isn't always working.
			if ($row[0] eq '/dev/root'){
				$row[0] = get_root();
			}
			# sometimes paths are set using /dev/disk/by-[label|uuid] so we need to get the /dev/xxx path
			if ($row[0] =~ /by-label|by-uuid/){
				$row[0] = Cwd::abs_path($row[0]);
			}
			elsif ($row[0] =~ /mapper\// && @mapper){
				$row[0] = get_mapper($row[0],@mapper);
			}
			$dev_base = $row[0];
			$dev_base =~ s/^\/dev\///;
			%part = check_lsblk($dev_base,0) if @lsblk;
		}
		# this handles zfs type devices/partitions, which do not start with / but contain /
		# note: Main/jails/transmission_1 path can be > 1 deep 
		# Main zfs 3678031340 8156 3678023184 0% /mnt/Main
		if (!$dev_base && ($row[0] =~ /^([^\/]+\/)(.+)/ || ($row[0] =~ /^[^\/]+$/ && $row[1] =~ /^(btrfs|zfs)$/ ) ) ){
			$dev_base = $row[0];
			$dev_type = 'raid';
		}
		# this handles yet another fredforfaen special case where a mounted drive
		# has the search string in its name
		if ($row[-1] =~ /^\/$|^\/boot$|^\/var$|^\/var\/tmp$|^\/var\/log$|^\/home$|^\/opt$|^\/tmp$|^\/usr$|^\/usr\/home$/){
			$b_load = 1;
			# note, older df in bsd do not have file system column
			$type = 'main';
		}
		elsif ($row[$cols] !~ /^\/$|^\/boot$|^\/var$|^\/var\/tmp$|^\/var\/log$|^\/home$|^\/opt$|^\/tmp$|^\/usr$|^\/usr\/home$|^filesystem/){
			$b_load = 1;
			$type = 'secondary';
		}
		if ($b_load){
			if (!$bsd_type){
				if ($b_fs){
					$fs = (%part && $part{'fs'}) ? $part{'fs'} : $row[1];
				}
				else {
					$fs = get_mounts_fs($row[0],@mount);
				}
				if ($show{'label'}) {
					if (%part && $part{'label'}) {
						$label = $part{'label'};
					}
					elsif ( @labels){
						$label = get_label($row[0]);
					}
				}
				if ($show{'uuid'}) {
					if (%part && $part{'uuid'}) {
						$uuid = $part{'uuid'};
					}
					elsif ( @uuids){
						$uuid = get_uuid($row[0]);
					}
				}
			}
			else {
				$fs = ($b_fs) ? $row[1]: get_mounts_fs($row[0],@mount);
				if (@gpart && ($show{'label'} || $show{'uuid'} ) ){
					my @extra = get_bsd_label_uuid("$dev_base");
					if (@extra){
						$label = $extra[0];
						$uuid = $extra[1];
					}
				}
			}
			$id = join ' ', @row[$cols .. $#row];
			$size = $row[$cols - $back_size];
			if ($b_admin && -e "/sys/block/"){
				@working = admin_data($blockdev,$dev_base,$size);
				$raw_size = $working[0];
				$size_available = $working[1];
				$block_size = $working[2];
			}
			$dev_base =~ s/\^\^/ /g if $b_space;
			if (!$dev_type){
				if ($dev_base =~ /^map:\/(.*)/){
					$dev_type = 'mapped';
					$dev_base = $1;
				}
				# note: I have seen this: beta:data/ for sshfs path
				elsif ($dev_base =~ /^\/\/|:\//){
					$dev_type = 'remote';
				}
				# an error has occurred almost for sure
				elsif (!$dev_base){
					$dev_type = 'source';
					$dev_base = main::row_defaults('unknown-dev');
				}
				else {
					$dev_type = 'dev';
				}
			}
			$used = $row[$cols - $back_used];
			$percent_used = sprintf( "%.1f", ( $used/$size )*100 ) if ($size && main::is_numeric($size) );
			@data = ({
			'block-size' => $block_size,
			'id' => $id,
			'dev-base' => $dev_base,
			'dev-type' => $dev_type,
			'fs' => $fs,
			'label' => $label,
			'raw-size' => $raw_size,
			'raw-available' => $size_available,
			'size' => $size,
			'type' => $type,
			'used' => $used,
			'uuid' => $uuid,
			'percent-used' => $percent_used,
			});
			@partitions = (@partitions,@data);
		}
	}
	@data = swap_data();
	@partitions = (@partitions,@data);
	# print Data::Dumper::Dumper \@partitions if $test[16];
	if (!$bsd_type && @lsblk){
		@data = check_partition_data();
		@partitions = (@partitions,@data) if @data;
	}
	main::log_data('dump','@partitions',\@partitions) if $b_log;
	print Data::Dumper::Dumper \@partitions if $test[16];
	eval $end if $b_log;
}

sub swap_data {
	eval $start if $b_log;
	return @swaps if $b_swaps;
	$b_swaps = 1;
	my (@data,@working);
	my ($cache_pressure,$dev_base,$dev_type,$label,$mount,$path,
	$pattern1,$pattern2,$percent_used,$priority,$size,$swap_type,
	$swappiness,$used,$uuid);
	my ($s,$j,$size_id,$used_id) = (1,0,2,3);
	if (!$bsd_type){
		# faster, avoid subshell, same as swapon -s
		if ( -r '/proc/swaps'){
			@working = main::reader("/proc/swaps");
		}
		elsif ( $path = main::check_program('swapon') ){
			# note: while -s is deprecated, --show --bytes is not supported
			# on older systems
			@working = main::grabber("$path -s 2>/dev/null");
		}
		if ($b_admin){
			@data = swap_advanced_data();
			$swappiness = $data[0];
			$cache_pressure = $data[1];
		}
		$pattern1 = 'partition|file|ram';
		$pattern2 = '[^\s].*[^\s]';
	}
	else {
		if ( $path = main::check_program('swapctl') ){
			# output in in KB blocks
			@working = main::grabber("$path -l -k 2>/dev/null");
		}
		($size_id,$used_id) = (1,2);
		$pattern1 = '[0-9]+';
		$pattern2 = '[^\s]+';
	}
	# now add the swap partition data, don't want to show swap files, just partitions,
	# though this can include /dev/ramzswap0. Note: you can also use /proc/swaps for this
	# data, it's the same exact output as swapon -s
	foreach (@working){
		#next if ! /^\/dev/ || /^\/dev\/(ramzwap|zram)/;
		next if /^(Device|Filename)/;
		($dev_base,$dev_type,$label,$mount,$priority,
		$swap_type,$uuid) = ('','','','',undef,'partition','');
		@data = split /\s+/, $_;
		if (/^\/dev\/(block\/)?(compcache|ramzwap|zram)/i){
			$swap_type = 'zram';
			$dev_type = 'dev';
		}
		elsif ($data[1] && $data[1] eq 'ram'){
			$swap_type = 'ram';
		}
		elsif (m|^/dev|){
			$swap_type = 'partition';
			$dev_base = $data[0];
			$dev_base =~ s|^/dev/||;
			if ($show{'label'} && @labels){
				$label = get_label($data[0]);
			}
			if ($show{'uuid'} && @uuids){
				$uuid = get_uuid($data[0]);
			}
			if ($bsd_type && @gpart && ($show{'label'} || $show{'uuid'} ) ){
				my @extra = get_bsd_label_uuid("$dev_base");
				if (@extra){
					$label = $extra[0];
					$uuid = $extra[1];
				}
			}
			$dev_type = 'dev';
		}
		elsif ($data[1] && $data[1] eq 'file' || m|^/|){
			$swap_type = 'file';
		}
		$priority = $data[-1] if !$bsd_type;
		# swpaon -s: /dev/sdb1 partition 16383996 109608  -2
		# swapctl -l -k: /dev/label/swap0.eli     524284     154092
		# users could have space in swapfile name
		if (/^($pattern2)\s+($pattern1)\s+/){
			$mount = main::trimmer($1);
		}
		$size = $data[$size_id];
		$used = $data[$used_id];
		$percent_used = sprintf( "%.1f", ( $used/$size )*100 );
		@data = ({
		'cache-pressure' => $cache_pressure,
		'dev-base' => $dev_base,
		'dev-type' => $dev_type,
		'fs' => 'swap',
		'id' => "swap-$s",
		'label' => $label,
		'mount' => $mount,
		'priority' => $priority,
		'size' => $size,
		'swappiness' => $swappiness,
		'type' => 'main',
		'swap-type' => $swap_type,
		'used' => $used,
		'uuid' => $uuid,
		'percent-used' => $percent_used,
		});
		@swaps = (@swaps,@data);
		$s++;
	}
	main::log_data('dump','@swaps',\@swaps) if $b_log;
	print Data::Dumper::Dumper \@swaps if $test[15];;
	eval $end if $b_log;
	return @swaps;
}
sub swap_advanced_data {
	eval $start if $b_log;
	my ($swappiness,$cache_pressure) = (undef,undef);
	if (-r "/proc/sys/vm/swappiness"){
		$swappiness = (main::reader("/proc/sys/vm/swappiness"))[0];
		if (defined $swappiness){
			$swappiness .= ($swappiness == 60) ? ' (default)' : ' (default 60)' ;
		}
	}
	if (-r "/proc/sys/vm/vfs_cache_pressure"){
		$cache_pressure = (main::reader("/proc/sys/vm/vfs_cache_pressure"))[0];
		if (defined $cache_pressure){
			$cache_pressure .= ($cache_pressure == 100) ? ' (default)' : ' (default 100)' ;
		}
	}
	eval $end if $b_log;
	return ($swappiness,$cache_pressure);
}
sub get_mounts_fs {
	eval $start if $b_log;
	my ($item,@mount) = @_;
	$item =~ s/map:\/(\S+)/map $1/ if $bsd_type && $bsd_type eq 'darwin';
	return 'N/A' if ! @mount;
	my ($fs) = ('');
	# linux: /dev/sdb6 on /var/www/m type ext4 (rw,relatime,data=ordered)
	# /dev/sda3 on /root.dev/ugw type ext3 (rw,relatime,errors=continue,user_xattr,acl,barrier=1,data=journal)
	# bsd: /dev/ada0s1a on / (ufs, local, soft-updates)
	foreach (@mount){
		if ($bsd_type && $_ =~ /^$item\son.*\(([^,\s\)]+)[,\s]*.*\)/){
			$fs = $1;
			last;
		}
		elsif (!$bsd_type && $_ =~ /^$item\son.*\stype\s([\S]+)\s\([^\)]+\)/){
			$fs = $1;
			last;
		}
	}
	eval $end if $b_log;
	main::log_data('data',"fs: $fs") if $b_log;
	return $fs;
}
# 1. Name: ada1p1
#   label: (null)
#   label: ssd-root
#   rawuuid: b710678b-f196-11e1-98fd-021fc614aca9
sub get_bsd_label_uuid {
	eval $start if $b_log;
	my ($item) = @_;
	my (@data,$b_found);
	foreach (@gpart){
		my @working = split /\s*:\s*/, $_;
		if ($_ =~ /^[0-9]+\.\sName:/ && $working[1] eq $item){
			$b_found = 1;
		}
		elsif ($_ =~ /^[0-9]+\.\sName:/ && $working[1] ne $item){
			$b_found = 0;
		}
		if ($b_found){
			if ($working[0] eq 'label'){
				$data[0] = $working[1];
				$data[0] =~ s/\(|\)//g; # eg: label:(null) - we want to show null
			}
			if ($working[0] eq 'rawuuid'){
				$data[1] = $working[1];
				$data[0] =~ s/\(|\)//g; 
			}
		}
	}
	main::log_data('dump','@data',\@data) if $b_log;
	eval $end if $b_log;
	return @data;
}
sub set_label_uuid {
	eval $start if $b_log;
	$b_label_uuid = 1;
	if ( $show{'unmounted'} || $show{'label'} || $show{'uuid'} ){
		if (!$bsd_type){
			if (-d '/dev/disk/by-label'){
				@labels = main::globber('/dev/disk/by-label/*');
			}
			if (-d '/dev/disk/by-uuid'){
				@uuids = main::globber('/dev/disk/by-uuid/*');
			}
		}
		else {
			if ( my $path = main::check_program('gpart')){
				@gpart = main::grabber("$path list 2>/dev/null",'strip');
			}
		}
	}
	eval $end if $b_log;
}
sub set_lsblk {
	eval $start if $b_log;
	$b_lsblk = 1;
	my (@temp,@working);
	if (my $program = main::check_program('lsblk')){
		@working = main::grabber("$program -bP --output NAME,TYPE,RM,FSTYPE,SIZE,LABEL,UUID,SERIAL,MOUNTPOINT,PHY-SEC,LOG-SEC,PARTFLAGS 2>/dev/null");
		foreach (@working){
			if (/NAME="([^"]*)"\s+TYPE="([^"]*)"\s+RM="([^"]*)"\s+FSTYPE="([^"]*)"\s+SIZE="([^"]*)"\s+LABEL="([^"]*)"\s+UUID="([^"]*)"\s+SERIAL="([^"]*)"\s+MOUNTPOINT="([^"]*)"\s+PHY-SEC="([^"]*)"\s+LOG-SEC="([^"]*)"\s+PARTFLAGS="([^"]*)"/){
				my $size = ($5) ? $5/1024: 0;
				# some versions of lsblk do not return serial, fs, uuid, or label
				@temp = ({
				'name' => $1, 
				'type' => $2,
				'rm' => $3, 
				'fs' => $4, 
				'size' => $size,
				'label' => $6,
				'uuid' => $7,
				'serial' => $8,
				'mount' => $9,
				'block-physical' => $10,
				'block-logical' => $11,
				'partition-flags' => $12,
				});
				@lsblk = (@lsblk,@temp);
			}
		}
	}
	#print Data::Dumper::Dumper \@lsblk;
	main::log_data('dump','@lsblk',\@lsblk) if $b_log;
	eval $end if $b_log;
}
sub check_lsblk {
	eval $start if $b_log;
	my ($name,$b_size) = @_;
	my (%part);
	foreach my $ref (@lsblk){
		my %row = %$ref;
		next if ! $row{'name'};
		if ($name eq $row{'name'}){
			%part = %row;
			last;
		}
	}
	# print Data::Dumper::Dumper \%part;
	main::log_data('dump','%part',\%part) if $b_log;
	eval $end if $b_log;
	return %part;
}
# handle cases of hidden file systems
sub check_partition_data {
	eval $start if $b_log;
	my ($b_found,@data,@temp);
	# NOTE: these filters must match the fs filters in the main partition data sub!!
	my $fs_filters = 'aufs|cgmfs|configfs|devfs|devtmpfs|';
	$fs_filters .= 'fdescfs|linprocfs|procfs|squashfs|swap|';
	$fs_filters .= 'sysfs|tmpfs|unionfs';
	foreach my $ref (@lsblk){
		my %row = %$ref;
		$b_found = 0;
		if (!$row{'name'} || !$row{'mount'} || !$row{'type'} || 
		 ($row{'fs'} && $row{'fs'} =~ /^($fs_filters)$/) ||
		 ($row{'type'} =~ /^(disk|loop|rom)$/)){
			next;
		}
		#print "$row{'name'} $row{'mount'}\n";
		foreach my $ref2 (@partitions){
			my %row2 = %$ref2;
			#print "m:$row{'mount'} id:$row2{'id'}\n";
			next if !$row2{'id'};
			if ($row{'mount'} eq $row2{'id'}){
				$b_found = 1;
				last;
			}
		}
		if (!$b_found){
			#print "found: $row{'name'} $row{'mount'}\n";
			@temp = ({
			'dev-base' => $row{'name'},
			'fs' => $row{'fs'},
			'id' => $row{'mount'},
			'hidden' => 1,
			'label' => $row{'label'},
			'raw-size' => $row{'size'},
			'size' => 0,
			'type' => 'secondary',
			'used' => 0,
			'uuid' => $row{'uuid'},
			'percent-used' => 0,
			});
			@partitions = (@partitions,@temp);
			main::log_data('dump','lsblk check: @temp',\@temp) if $b_log;
		}
	}
	eval $end if $b_log;
	return @data;
}
# args: 1: blockdev full path (part only); 2: block id; 3: size (part only)
sub admin_data {
	eval $start if $b_log;
	my ($blockdev,$id,$size) = @_;
	# 0: calc block 1: available percent 2: disk physical block size/partition block size;
	my @sizes = (0,0,0); 
	my ($block_size,$percent,$size_raw) = (0,0,0);
	foreach (@proc_partitions){
		my @row = split /\s+/, $_;
		if ($row[-1] eq $id){
			$size_raw = $row[2];
			last;
		}
	}
	# get the fs block size
	$block_size = (main::grabber("$blockdev --getbsz /dev/$id 2>/dev/null"))[0] if $blockdev;
	if (!$size_raw){
		$size_raw = 'N/A';
	}
	else {
		$percent = sprintf("%.2f", ($size/$size_raw ) * 100) if $size && $size_raw;
	}
	# print "$id size: $size %: $percent p-b: $block_size raw: $size_raw\n";
	@sizes = ($size_raw,$percent,$block_size); 
	main::log_data('dump','@sizes',\@sizes) if $b_log;
	eval $end if $b_log;
	return @sizes;
}
sub get_label {
	eval $start if $b_log;
	my ($item) = @_;
	my $label = '';
	foreach (@labels){
		if ($item eq Cwd::abs_path($_)){
			$label = $_;
			$label =~ s/\/dev\/disk\/by-label\///;
			$label =~ s/\\x20/ /g;
			$label =~ s%\\x2f%/%g;
			last;
		}
	}
	$label ||= 'N/A';
	eval $end if $b_log;
	return $label;
}
# args: $1 - dev item $2 - @mapper
# check for mapper, then get actual dev item if mapped
# /dev/mapper/ will usually be a symbolic link to the real /dev id
sub get_mapper {
	eval $start if $b_log;
	my ($item,@mapper) = @_;
	my $mapped = '';
	foreach (@mapper){
		if ($item eq $_){
			my $temp = Cwd::abs_path($_);
			$mapped = $temp if $temp;
			last;
		}
	}
	$mapped ||= $item;
	eval $end if $b_log;
	return $mapped;
}
sub get_root {
	eval $start if $b_log;
	my ($path) = ('/dev/root');
	# note: the path may be a symbolic link to by-label/by-uuid but not 
	# sure how far in abs_path resolves the path.
	my $temp = Cwd::abs_path($path);
	$path = $temp if $temp;
	# note: it's a kernel config option to have /dev/root be a sym link 
	# or not, if it isn't, path will remain /dev/root, if so, then try mount
	if ($path eq '/dev/root' && (my $program = main::check_program('mount'))){
		my @data = main::grabber("$program 2>/dev/null");
		# /dev/sda2 on / type ext4 (rw,noatime,data=ordered)
		foreach (@data){
			if (/^([\S]+)\son\s\/\s/){
				$path = $1;
				# note: we'll be handing off any uuid/label paths to the next 
				# check tools after get_root() above, so don't trim those.
				$path =~ s/.*\/// if $path !~ /by-uuid|by-label/;
				last;
			}
		}
	}
	eval $end if $b_log;
	return $path;
}

sub get_uuid {
	eval $start if $b_log;
	my ($item) = @_;
	my $uuid = '';
	foreach (@uuids){
		if ($item eq Cwd::abs_path($_)){
			$uuid = $_;
			$uuid =~ s/\/dev\/disk\/by-uuid\///;
			last;
		}
	}
	$uuid ||= 'N/A';
	eval $end if $b_log;
	return $uuid;
}
}

## ProcessData 
{
package ProcessData;

sub get {
	eval $start if $b_log;
	my $num = 0;
	my (@processes,@rows);
	if (@ps_aux){
		if ($show{'ps-cpu'}){
			@rows = cpu_processes();
			@processes = (@processes,@rows);
		}
		if ($show{'ps-mem'}){
			@rows = mem_processes();
			@processes = (@processes,@rows);
		}
	}
	else {
		my $key = 'Message';
		@rows = ({
		main::key($num++,0,1,$key) => main::row_defaults('ps-data-null',''),
		},);
		@processes = (@processes,@rows);
	}
	eval $end if $b_log;
	return @processes;
}
sub cpu_processes {
	eval $start if $b_log;
	my ($j,$num,$cpu,$cpu_mem,$mem,$pid) = (0,0,'','','','');
	my ($pid_col,@processes,@rows);
	my $count = ($b_irc)? 5: $ps_count;
	if ($ps_cols >= 10){
		@rows = sort { 
		my @a = split(/\s+/,$a); 
		my @b = split(/\s+/,$b); 
		$b[2] <=> $a[2] } @ps_aux;
		$pid_col = 1;
	}
	else {
		@rows = @ps_aux;
		$pid_col = 0 if $ps_cols == 2;
	}
	# if there's a count limit, for irc, etc, only use that much of the data
	@rows = splice @rows,0,$count;
	
	$j = scalar @rows;
	# $cpu_mem = ' - Memory: MiB / % used' if $extra > 0;
	my $throttled = throttled($ps_count,$count,$j);
	#my $header = "CPU  % used - Command - pid$cpu_mem - top";
	#my $header = "Top $count by CPU";
	my @data = ({
	main::key($num++,1,1,'CPU top') => "$count$throttled" . ' of ' . scalar @ps_aux,
	},);
	@processes = (@processes,@data);
	my $i = 1;
	foreach (@rows){
		$num = 1;
		$j = scalar @processes;
		my @row = split /\s+/, $_;
		my @command = process_starter(scalar @row, $row[$ps_cols],$row[$ps_cols + 1]);
		$cpu = ($ps_cols >= 10 ) ? $row[2] . '%': 'N/A';
		@data = ({
		main::key($num++,1,2,$i++) => '',
		main::key($num++,0,3,'cpu') => $cpu,
		main::key($num++,1,3,'command') => $command[0],
		},);
		@processes = (@processes,@data);
		if ($command[1]) {
			$processes[$j]{main::key($num++,0,4,'started by')} = $command[1];
		}
		$pid = (defined $pid_col)? $row[$pid_col] : 'N/A';
		$processes[$j]{main::key($num++,0,3,'pid')} = $pid;
		if ($extra > 0 && $ps_cols >= 10){
			my $decimals = ($row[5]/1024 > 10 ) ? 1 : 2;
			$mem = (defined $row[5]) ? sprintf( "%.${decimals}f", $row[5]/1024 ) . ' MiB' : 'N/A';
			$mem .= ' (' . $row[3] . '%)';
			$processes[$j]{main::key($num++,0,3,'mem')} = $mem;
		}
		#print Data::Dumper::Dumper \@processes, "i: $i; j: $j ";
	}
	eval $end if $b_log;
	return @processes;
}
sub mem_processes {
	eval $start if $b_log;
	my ($j,$num,$cpu,$cpu_mem,$mem,$pid) = (0,0,'','','','');
	my (@data,$pid_col,@processes,$memory,@rows);
	my $count = ($b_irc)? 5: $ps_count;
	if ($ps_cols >= 10){
		@rows = sort { 
		my @a = split(/\s+/,$a); 
		my @b = split(/\s+/,$b); 
		$b[5] <=> $a[5] } @ps_aux; # 5
		#$a[1] <=> $b[1] } @ps_aux; # 5
		$pid_col = 1;
	}
	else {
		@rows = @ps_aux;
		$pid_col = 0 if $ps_cols == 2;
	}
	@rows = splice @rows,0,$count;
	#print Data::Dumper::Dumper \@rows;
	@processes = main::get_memory_data_full('process') if !$b_mem;
	$j = scalar @rows;
	my $throttled = throttled($ps_count,$count,$j);
	#$cpu_mem = ' - CPU: % used' if $extra > 0;
	#my $header = "Memory MiB/% used - Command - pid$cpu_mem - top";
	#my $header = "Top $count by Memory";
	@data = ({
	main::key($num++,1,1,'Memory top') => "$count$throttled" . ' of ' . scalar @ps_aux,
	},);
	@processes = (@processes,@data);
	my $i = 1;
	foreach (@rows){
		$num = 1;
		$j = scalar @processes;
		my @row = split /\s+/, $_;
		if ($ps_cols >= 10){
			my $decimals = ($row[5]/1024 > 10 ) ? 1 : 2;
			$mem = (main::is_int($row[5])) ? sprintf( "%.${decimals}f", $row[5]/1024 ) . ' MiB' : 'N/A';
			$mem .= " (" . $row[3] . "%)"; 
		}
		else {
			$mem = 'N/A';
		}
		my @command = process_starter(scalar @row, $row[$ps_cols],$row[$ps_cols + 1]);
		@data = ({
		main::key($num++,1,2,$i++) => '',
		main::key($num++,0,3,'mem') => $mem,
		main::key($num++,1,3,'command') => $command[0],
		},);
		@processes = (@processes,@data);
		if ($command[1]) {
			$processes[$j]{main::key($num++,0,4,'started by')} = $command[1];
		}
		$pid = (defined $pid_col)? $row[$pid_col] : 'N/A';
		$processes[$j]{main::key($num++,0,3,'pid')} = $pid;
		if ($extra > 0 && $ps_cols >= 10){
			$cpu = $row[2] . '%';
			$processes[$j]{main::key($num++,0,3,'cpu')} = $cpu;
		}
		#print Data::Dumper::Dumper \@processes, "i: $i; j: $j ";
	}
	eval $end if $b_log;
	return @processes;
}
sub process_starter {
	my ($count, $row10, $row11) = @_;
	my (@return);
	# note: [migration/0] would clear with a simple basename
	if ($count > ($ps_cols + 1) && $row11 =~ /^\// && $row11 !~ /^\/(tmp|temp)/){
		$row11 =~ s/^\/.*\///;
		$return[0] = $row11;
		$row10 =~ s/^\/.*\///;
		$return[1] = $row10;
	}
	else {
		$row10 =~ s/^\/.*\///;
		$return[0] = $row10;
		$return[1] = '';
	}
	return @return;
}
sub throttled {
	my ($ps_count,$count,$j) = @_;
	my $throttled = '';
	if ($count > $j){
		$throttled = " ( $j processes)"; # space to avoid emoji in irc
	}
	elsif ($count < $ps_count){
		$throttled = " (throttled from $ps_count)";
	}
	return $throttled;
}
}

## RaidData
{
package RaidData;
# debugger switches
my $b_md = 0;
my $b_zfs = 0;

sub get {
	eval $start if $b_log;
	my (@rows,$key1,$val1);
	my $num = 0;
	raid_data() if !$b_raid;
	#print 'get: ', Data::Dumper::Dumper \@raid;
	if (!@raid && !@hardware_raid){
		if ($show{'raid-forced'}){
			$key1 = 'Message';
			$val1 = main::row_defaults('raid-data');
		}
	}
	else {
		@rows = create_output();
	}
	if (!@rows && $key1){
		@rows = ({main::key($num++,0,1,$key1) => $val1,});
	}
	eval $end if $b_log;
	($b_md,$b_zfs,@hardware_raid) = undef;
	return @rows;
}
sub create_output {
	eval $start if $b_log;
	my (@arrays,@arrays_holder,@components,@components_good,@data,@failed,@rows,
	@sizes,@spare,@temp);
	my ($allocated,$available,$blocks_avail,$chunk_raid,$component_string,$raid,
	$ref2,$ref3,$report_size,$size,$status);
	my ($b_row_1_sizes);
	my ($cont_arr,$i,$ind_arr,$j,$num,$status_id) = (2,0,3,0,0,0);
	#print Data::Dumper::Dumper \@raid;
	if (@hardware_raid){
		foreach my $ref (@hardware_raid){
			my %row = %$ref;
			$num = 1;
			my $device = ($row{'device'}) ? $row{'device'}: 'N/A';
			my $driver = ($row{'driver'}) ? $row{'driver'}: 'N/A';
			@data = ({
			main::key($num++,1,1,'Hardware') => $device,
			});
			@rows = (@rows,@data);
			$j = scalar @rows - 1;
			$rows[$j]{main::key($num++,0,2,'vendor')} = $row{'vendor'} if $row{'vendor'};
			$rows[$j]{main::key($num++,1,2,'driver')} = $driver;
			if ($extra > 0){
				my $driver_version = ($row{'driver-version'}) ?  $row{'driver-version'}: 'N/A' ;
				$rows[$j]{main::key($num++,0,3,'v')} = $driver_version;
				if ($extra > 2){
					my $port= ($row{'port'}) ? $row{'port'}: 'N/A' ;
					$rows[$j]{main::key($num++,0,2,'port')} = $port;
				}
				my $bus_id = (defined $row{'bus-id'} && defined $row{'sub-id'}) ?  "$row{'bus-id'}.$row{'sub-id'}": 'N/A' ;
				$rows[$j]{main::key($num++,0,2,'bus ID')} = $bus_id;
			}
			if ($extra > 1){
				my $chip_id = (defined $row{'vendor-id'} && defined $row{'chip-id'}) ?  "$row{'vendor-id'}.$row{'chip-id'}": 'N/A' ;
				$rows[$j]{main::key($num++,0,2,'chip ID')} = $chip_id;
			}
			if ($extra > 2){
				my $rev= (defined $row{'rev'} && $row{'rev'}) ? $row{'rev'}: 'N/A' ;
				$rows[$j]{main::key($num++,0,2,'rev')} = $rev;
			}
		}
	}
	if ($extra > 2 && $raid[0]{'system-supported'}){
		@data = ({
		main::key($num++,0,1,'Supported md-raid types') => $raid[0]{'system-supported'},
		});
		@rows = (@rows,@data);
	}
	foreach my $ref (@raid){
		$j = scalar @rows;
		my %row = %$ref;
		$b_row_1_sizes = 0;
		next if !%row;
		$num = 1;
		@data = ({
		main::key($num++,1,1,'Device') => $row{'id'},
		main::key($num++,0,2,'type') => $row{'type'},
		main::key($num++,0,2,'status') => $row{'status'},
		});
		@rows = (@rows,@data);
		if ($row{'type'} eq 'mdraid'){
			$blocks_avail = 'blocks';
			$chunk_raid = 'chunk size';
			$report_size = 'report';
			if ($extra > 0){
				$available = ($row{'blocks'}) ? $row{'blocks'} : 'N/A';
			}
			$size = ($row{'report'}) ? $row{'report'}: '';
			$size .= " $row{'u-data'}" if $size; 
			$size ||= 'N/A';
			$status_id = 2;
		}
		else {
			$blocks_avail = 'free';
			$chunk_raid = 'allocated';
			$report_size = 'size';
			@sizes = ($row{'size'}) ? main::get_size($row{'size'}) : ();
			$size = (@sizes) ? "$sizes[0] $sizes[1]" : '';
			@sizes = ($row{'free'}) ? main::get_size($row{'free'}) : ();
			$available = (@sizes) ? "$sizes[0] $sizes[1]" : '';
			if ($extra > 2){
				@sizes = ($row{'allocated'}) ? main::get_size($row{'allocated'}) : ();
				$allocated = (@sizes) ? "$sizes[0] $sizes[1]" : '';
			}
			$status_id = 1;
		}
		$ref2 = $row{'arrays'};
		@arrays = @$ref2;
		@arrays = grep {defined $_} @arrays;
		@arrays_holder = @arrays;
		if (($row{'type'} eq 'mdraid' && $extra == 0 ) || !defined $arrays[0]{'raid'} ){
			$raid = (defined $arrays[0]{'raid'}) ? $arrays[0]{'raid'}: 'no-raid';
			$rows[$j]{main::key($num++,0,2,'raid')} = $raid;
		}
		if ( ( $row{'type'} eq 'zfs' || ($row{'type'} eq 'mdraid' && $extra == 0 ) ) && $size){
			#print "here 0\n";
			$rows[$j]{main::key($num++,0,2,$report_size)} = $size;
			$size = '';
			$b_row_1_sizes = 1;
		}
		if ( $row{'type'} eq 'zfs' && $available){
			$rows[$j]{main::key($num++,0,2,$blocks_avail)} = $available;
			$available = '';
			$b_row_1_sizes = 1;
		}
		if ( $row{'type'} eq 'zfs' && $allocated){
			$rows[$j]{main::key($num++,0,2,$chunk_raid)} = $allocated;
			$allocated = '';
		}
		$i = 0;
		my $count = scalar @arrays;
		foreach $ref3 (@arrays){
			my %row2 = %$ref3;
			($cont_arr,$ind_arr) = (2,3);
			if ($count > 1){
				($cont_arr,$ind_arr) = (3,4);
				$j = scalar @rows;
				$num = 1;
				@sizes = ($row2{'size'}) ? main::get_size($row2{'size'}) : ();
				$size = (@sizes) ? "$sizes[0] $sizes[1]" : 'N/A';
				@sizes = ($row2{'free'}) ? main::get_size($row2{'free'}) : ();
				$available = (@sizes) ? "$sizes[0] $sizes[1]" : '';
				$raid = (defined $row2{'raid'}) ? $row2{'raid'}: 'no-raid';
				$status = ($row2{'status'}) ? $row2{'status'}: 'N/A';
				@data = ({
				main::key($num++,1,2,'Array') => $raid,
				main::key($num++,0,3,'status') => $status,
				main::key($num++,0,3,'size') => $size,
				main::key($num++,0,3,'free') => $available,
				});
				@rows = (@rows,@data);
			}
			# items like cache may have one component, with a size on that component
			elsif (!$b_row_1_sizes && $row{'type'} eq 'zfs'){
				#print "here $count\n";
				@sizes = ($row2{'size'}) ? main::get_size($row2{'size'}) : ();
				$size = (@sizes) ? "$sizes[0] $sizes[1]" : '';
				@sizes = ($row2{'free'}) ? main::get_size($row2{'free'}) : ();
				$available = (@sizes) ? "$sizes[0] $sizes[1]" : '';
				$rows[$j]{main::key($num++,0,2,'size')} = $size;
				$rows[$j]{main::key($num++,0,2,'free')} = $available;
				if ($extra > 2){
					@sizes = ($row{'allocated'}) ? main::get_size($row2{'allocated'}) : ();
					$allocated = (@sizes) ? "$sizes[0] $sizes[1]" : '';
					if ($allocated){
						$rows[$j]{main::key($num++,0,2,$chunk_raid)} = $allocated;
					}
				}
			}
			$ref3 = $row2{'components'};
			@components = (ref $ref3 eq 'ARRAY') ? @$ref3 : ();
			@failed = ();
			@spare = ();
			@components_good = ();
			# @spare = split(/\s+/, $row{'unused'}) if $row{'unused'};
			foreach my $item (@components){
				@temp = split /~/, $item;
				if (defined $temp[$status_id] && $temp[$status_id] =~ /^(F|DEGRADED|FAULTED|UNAVAIL)$/){
					$temp[0] = "$temp[0]~$temp[1]" if $status_id == 2;
					push @failed, $temp[0];
				}
				elsif (defined $temp[$status_id] && $temp[$status_id] =~ /(S|OFFLINE)$/){
					$temp[0] = "$temp[0]~$temp[1]" if $status_id == 2;
					push @spare, $temp[0];
				}
				else {
					$temp[0] = ($status_id == 2) ? "$temp[0]~$temp[1]" : $temp[0];
					push @components_good, $temp[0];
				}
			}
			$component_string = (@components_good) ? join ' ', @components_good : 'N/A';
			$rows[$j]{main::key($num++,1,$cont_arr,'Components')} = '';
			$rows[$j]{main::key($num++,0,$ind_arr,'online')} = $component_string;
			if (@failed){
				$rows[$j]{main::key($num++,0,$ind_arr,'FAILED')} = join ' ', @failed;
			}
			if (@spare){
				$rows[$j]{main::key($num++,0,$ind_arr,'spare')} = join ' ', @spare;
			}
			if ($row{'type'} eq 'mdraid' && $extra > 0 ){
				$j = scalar @rows;
				$num = 1;
				#print Data::Dumper::Dumper \@arrays_holder;
				$rows[$j]{main::key($num++,1,$cont_arr,'Info')} = '';
				$raid = (defined $arrays_holder[0]{'raid'}) ? $arrays_holder[0]{'raid'}: 'no-raid';
				$rows[$j]{main::key($num++,0,$ind_arr,'raid')} = $raid;
				$rows[$j]{main::key($num++,0,$ind_arr,$blocks_avail)} = $available;
				if ($size){
					$rows[$j]{main::key($num++,0,$ind_arr,$report_size)} = $size;
				}
				my $chunk = ($row{'chunk-size'}) ? $row{'chunk-size'}: 'N/A';
				$rows[$j]{main::key($num++,0,$ind_arr,$chunk_raid)} = $chunk;
				if ($extra > 1){
					if ($row{'bitmap'}){
						$rows[$j]{main::key($num++,0,$ind_arr,'bitmap')} = $row{'bitmap'};
					}
					if ($row{'super-block'}){
						$rows[$j]{main::key($num++,0,$ind_arr,'super blocks')} = $row{'super-block'};
					}
					if ($row{'algorithm'}){
						$rows[$j]{main::key($num++,0,$ind_arr,'algorithm')} = $row{'algorithm'};
					}
				}
			}
			$i++;
		}
		if ($row{'recovery-percent'}){
			$j = scalar @rows;
			$num = 1;
			my $percent = $row{'recovery-percent'};
			if ($extra > 1 && $row{'progress-bar'}){
				$percent .= " $row{'progress-bar'}"
			}
			$rows[$j]{main::key($num++,1,$cont_arr,'Recovering')} = $percent;
			my $finish = ($row{'recovery-finish'})?$row{'recovery-finish'} : 'N/A';
			$rows[$j]{main::key($num++,0,$ind_arr,'time remaining')} = $finish;
			if ($extra > 0){
				if ($row{'sectors-recovered'}){
					$rows[$j]{main::key($num++,0,$ind_arr,'sectors')} = $row{'sectors-recovered'};
				}
			}
			if ($extra > 1 && $row{'recovery-speed'}){
				$rows[$j]{main::key($num++,0,$ind_arr,'speed')} = $row{'recovery-speed'};
			}
		}
	}
	eval $end if $b_log;
	#print Data::Dumper::Dumper \@rows;
	return @rows;
}
sub raid_data {
	eval $start if $b_log;
	my (@data);
	$b_raid = 1;
	if ($b_hardware_raid){
		hardware_raid();
	}
	if ($b_md || (my $file = main::system_files('mdstat') )){
		@data = mdraid_data($file);
		@raid = (@raid,@data) if @data;
	}
	if ($b_zfs || (my $path = main::check_program('zpool') )){
		@data = zfs_data($path);
		@raid = (@raid,@data) if @data;
	}
	main::log_data('dump','@raid',\@raid) if $b_log;
	#print Data::Dumper::Dumper \@raid;
	eval $end if $b_log;
}
# 0 type
# 1 type_id
# 2 bus_id
# 3 sub_id
# 4 device
# 5 vendor_id
# 6 chip_id
# 7 rev
# 8 port
# 9 driver
# 10 modules
sub hardware_raid {
	eval $start if $b_log;
	my ($driver,$vendor,@data,@working);
	foreach my $ref (@devices_hwraid){
		@working = @$ref;
		$driver = ($working[9]) ? lc($working[9]): '';
		$driver =~ s/-/_/g if $driver;
		my $driver_version = ($driver) ? main::get_module_version($driver): '';
		if ($extra > 2 && $b_pci_tool && $working[11]){
			$vendor = main::get_pci_vendor($working[4],$working[11]);
		}
		@data = ({
		'bus-id' => $working[2],
		'chip-id' => $working[6],
		'device' => $working[4],
		'driver' => $driver,
		'driver-version' => $driver_version,
		'port' => $working[8],
		'rev' => $working[7],
		'sub-id' => $working[3],
		'vendor-id' => $working[5],
		'vendor' => $vendor,
		});
		@hardware_raid = (@hardware_raid,@data);
	}
	# print Data::Dumper::Dumper \@hardware_raid;
	main::log_data('dump','@hardware_raid',\@hardware_raid) if $b_log;
	eval $end if $b_log;
}
sub mdraid_data {
	eval $start if $b_log;
	my ($mdstat) = @_;
	my $j = 0;
	#$mdstat = "$ENV{'HOME'}/bin/scripts/inxi/data/raid/md-4-device-1.txt";
	#$mdstat = "$ENV{'HOME'}/bin/scripts/inxi/data/raid/md-rebuild-1.txt";
	#$mdstat = "$ENV{'HOME'}/bin/scripts/inxi/data/raid/md-2-mirror-fserver2-1.txt";
	#$mdstat = "$ENV{'HOME'}/bin/scripts/inxi/data/raid/md-2-raid10-abucodonosor.txt";
	#$mdstat = "$ENV{'HOME'}/bin/scripts/inxi/data/raid/md-2-raid10-ant.txt";
	my @working = main::reader($mdstat,'strip');
	#print Data::Dumper::Dumper \@working;
	my (@data,@mdraid,@temp,$b_found,$system,$unused);
	# NOTE: a system with empty mdstat will still show these values
	if ($working[0] && $working[0] =~ /^Personalities/){
		$system = ( split /:\s*/,  $working[0])[1];
		$system =~ s/\[|\]//g if $system;
		shift @working;
	}
	if ($working[-1] && $working[-1] =~ /^used\sdevices/){
		$unused = ( split /:\s*/,  $working[0])[1];
		$unused =~ s/<|>|none//g if $unused;
		pop @working;
	}
	foreach (@working){
		$_ =~ s/\s*:\s*/:/;
		# print "$_\n";
		#md126 : active (auto-read-only) raid1 sdq1[0]
		if (/^(md[0-9]+)\s*:\s*([^\s]+)(\s\([^)]+\))?\s([^\s]+)\s(.*)/){
			my $id = $1;
			my $status = $2;
			my $raid = $4;
			my $component_string = $5;
			@temp = ();
			$raid =~ s/^raid1$/mirror/;
			$raid =~ s/^raid/raid-/; 
			$raid = 'mirror' if $raid eq '1';
			# remember, these include the [x] id, so remove that for disk/unmounted
			my @components = split /\s+/, $component_string;
			foreach my $component (@components){
				$component =~ /([\S]+)\[([0-9]+)\]\(?([SF])?\)?/;
				my $string = "$1~";
				$string .= (defined $2) ? "c$2" : '';
				$string .= (defined $3) ? "~$3" : '';
				push @temp, $string;
			}
			@components = @temp;
			#print "$component_string\n";
			$j = scalar @mdraid;
			@data = ({
			'id' => $id,
			'arrays' => ([],),
			'status' => $status,
			'type' => 'mdraid',
			});
			@mdraid = (@mdraid,@data);
			$mdraid[$j]{'arrays'}[0]{'raid'} = $raid;
			$mdraid[$j]{'arrays'}[0]{'components'} = \@components;
		}
		#print "$_\n";
		if ($_ =~ /^([0-9]+)\sblocks/){
			$mdraid[$j]{'blocks'} = $1;
		}
		if ($_ =~ /super\s([0-9\.]+)\s/){
			$mdraid[$j]{'super-block'} = $1;
		}
		if ($_ =~ /algorithm\s([0-9\.]+)\s/){
			$mdraid[$j]{'algorithm'} = $1;
		}
		if ($_ =~ /\[([0-9]+\/[0-9]+)\]\s\[([U_]+)\]/){
			$mdraid[$j]{'report'} = $1;
			$mdraid[$j]{'u-data'} = $2;
		}
		if ($_ =~ /resync=([\S]+)/){
			$mdraid[$j]{'resync'} = $1;
		}
		if ($_ =~ /([0-9]+[km])\schunk/i){
			$mdraid[$j]{'chunk-size'} = $1;
		}
		if ($_ =~ /(\[[=]*>[\.]*\]).*(resync|recovery)\s*=\s*([0-9\.]+%)?(\s\(([0-9\/]+)\))?/){
			$mdraid[$j]{'progress-bar'} = $1;
			$mdraid[$j]{'recovery-percent'} = $3 if $3;
			$mdraid[$j]{'sectors-recovered'} = $5 if $5;
		}
		if ($_ =~ /finish\s*=\s*([\S]+)\s+speed\s*=\s*([\S]+)/){
			$mdraid[$j]{'recovery-finish'} = $1;
			$mdraid[$j]{'recovery-speed'} = $2;
		}
		#print 'mdraid loop: ', Data::Dumper::Dumper \@mdraid;
	}
	if (@mdraid){
		$mdraid[0]{'system-supported'} = $system if $system;
		$mdraid[0]{'unused'} = $unused if $unused;
	}
	#print Data::Dumper::Dumper \@mdraid;
	eval $end if $b_log;
	return @mdraid;
}

sub zfs_data {
	eval $start if $b_log;
	my ($zpool) = @_;
	my (@components,@data,@zfs);
	my ($allocated,$free,$ref,$size,$status);
	my $b_v = 1;
	my ($i,$j,$k) = (0,0,0);
	#my $file = "$ENV{'HOME'}/bin/scripts/inxi/data/raid/zpool-list-1-mirror-main-solestar.txt";
	#my $file = "$ENV{'HOME'}/bin/scripts/inxi/data/raid/zpool-list-2-mirror-main-solestar.txt";
	#my $file = "$ENV{'HOME'}/bin/scripts/inxi/data/raid/zpool-list-v-tank-1.txt";
	#my $file = "$ENV{'HOME'}/bin/scripts/inxi/data/raid/zpool-list-v-gojev-1.txt";
	#my @working = main::reader($file);$zpool = '';
	my @working = main::grabber("$zpool list -v 2>/dev/null");
	DiskData::set_glabel() if $bsd_type && !$b_glabel;
	# bsd sed does not support inserting a true \n so use this trick
	# some zfs does not have -v
	if (!@working){
		@working = main::grabber("$zpool list 2>/dev/null");
		$b_v = 0;
	}
	#print Data::Dumper::Dumper \@working;
	main::log_data('dump','@working',\@working) if $b_log;
	if (!@working){
		main::log_data('data','no zpool list data') if $b_log;
		eval $end if $b_log;
		return ();
	}
	my ($status_i) = (0);
	# NAME   SIZE  ALLOC   FREE  EXPANDSZ   FRAG    CAP  DEDUP  HEALTH  ALTROOT
	my $test = shift @working; # get rid of first header line
	if ($test){
		foreach (split /\s+/, $test){
			last if $_ eq 'HEALTH';
			$status_i++;
		}
	}
	foreach (@working){
		my @row = split /\s+/, $_;
		if (/^[\S]+/){
			@components = ();
			$i = 0;
			$size = ($row[1] && $row[1] ne '-')? main::translate_size($row[1]): '';
			$allocated = ($row[2] && $row[2] ne '-')? main::translate_size($row[2]): '';
			$free = ($row[3] && $row[3] ne '-')? main::translate_size($row[3]): '';
			$status = (defined $row[$status_i] && $row[$status_i] ne '') ? $row[$status_i]: 'no-status';
			$j = scalar @zfs;
			@data = ({
			'id' => $row[0],
			'allocated' => $allocated,
			'arrays' => ([],),
			'free' => $free,
			'size' => $size,
			'status' => $status,
			'type' => 'zfs',
			});
			@zfs = (@zfs,@data);
		}
		#print Data::Dumper::Dumper \@zfs;
		# raid level is the second item in the output, unless it is not, sometimes it is absent
		if ($row[1] =~ /raid|mirror/){
			$row[1] =~ s/^raid1/mirror/;
			#$row[1] =~ s/^raid/raid-/; # need to match in zpool status <device>
			$ref = $zfs[$j]{'arrays'};
			$k = scalar @$ref;
			$zfs[$j]{'arrays'}[$k]{'raid'} = $row[1];
			$i = 0;
			$zfs[$j]{'arrays'}[$k]{'size'} = ($row[2] && $row[2] ne '-') ? main::translate_size($row[2]) : '';
			$zfs[$j]{'arrays'}[$k]{'allocated'} = ($row[3] && $row[3] ne '-') ? main::translate_size($row[3]) : '';
			$zfs[$j]{'arrays'}[$k]{'free'} = ($row[4] && $row[4] ne '-') ? main::translate_size($row[4]) : '';
		}
		# https://blogs.oracle.com/eschrock/entry/zfs_hot_spares
		elsif ($row[1] =~ /spares/){
			next;
		}
		# the first is a member of a raid array
		#    ada2        -      -      -         -      -      -
		# this second is a single device not in an array
		#  ada0s2    25.9G  14.6G  11.3G         -     0%    56%
		#    gptid/3838f796-5c46-11e6-a931-d05099ac4dc2      -      -      -         -      -      -
		elsif ($row[1] =~ /^(sd[a-z]|[a-z0-9]+[0-9]+|([\S]+)\/.*)$/ && 
		       ($row[2] eq '-' || $row[2] =~ /^[0-9\.]+[MGTP]$/ )){
			$row[1] =~ /^(sd[a-z]|[a-z0-9]+[0-9]+|([\S]+)\/.*)\s*(DEGRADED|FAULTED|OFFLINE)?$/;
			my $working = ($1) ? $1 : ''; # note: the negative case can never happen
			my $state = ($3) ? $3 : '';
			if ($working =~ /[\S]+\// && @glabel){
				$working = DiskData::match_glabel($working);
			}
			# kind of a hack, things like cache may not show size/free
			# data since they have no array row, but they might show it in 
			# component row:
			#   ada0s2    25.9G  19.6G  6.25G         -     0%    75%
			if (!$zfs[$j]{'size'} && $row[2] && $row[2] ne '-') {
				$size = ($row[2])? main::translate_size($row[2]): '';
				$zfs[$j]{'arrays'}[$k]{'size'} = $size;
			}
			if (!$zfs[$j]{'allocated'} && $row[3] && $row[3] ne '-') {
				$allocated = ($row[3])? main::translate_size($row[3]): '';
				$zfs[$j]{'arrays'}[$k]{'allocated'} = $allocated;
			}
			if (!$zfs[$j]{'free'} && $row[4] && $row[4] ne '-') {
				$free = ($row[4])? main::translate_size($row[4]): '';
				$zfs[$j]{'arrays'}[$k]{'free'} = $free;
			}
			$zfs[$j]{'arrays'}[$k]{'components'}[$i] = $working . '~' . $state;
			$i++;
		}
	}
	# print Data::Dumper::Dumper \@zfs;
	# clear out undefined arrrays values
	$j = 0;
	foreach $ref (@zfs){
		my %row = %$ref;
		my $ref2 = $row{'arrays'};
		my @arrays = (ref $ref2 eq 'ARRAY' ) ? @$ref2 : ();
		@arrays = grep {defined $_} @arrays;
		$zfs[$j]{'arrays'} = \@arrays;
		$j++;
	}
	@zfs = zfs_status($zpool,@zfs);
	# print Data::Dumper::Dumper \@zfs;
	eval $end if $b_log;
	return @zfs;
}
sub zfs_status {
	eval $start if $b_log;
	my ($zpool,@zfs) = @_;
	my ($cmd,$status,$file,$raid,@arrays,@pool_status,@temp);
	my ($i,$j,$k,$l) = (0,0,0,0);
	foreach my $ref (@zfs){
		my %row = %$ref;
		$i = 0;
		$k = 0;
		#$file = "$ENV{'HOME'}/bin/scripts/inxi/data/raid/zpool-status-1-mirror-main-solestar.txt";
		#$file = "$ENV{'HOME'}/bin/scripts/inxi/data/raid/zpool-status-2-mirror-main-solestar.txt";
		#$file = "$ENV{'HOME'}/bin/scripts/inxi/data/raid/zpool-status-tank-1.txt";
		#@pool_status = main::reader($file,'strip');
		$cmd = "$zpool status $row{'id'} 2>/dev/null";
		@pool_status = main::grabber($cmd,"\n",'strip');
		main::log_data('cmd',$cmd) if $b_log;
		my $ref2 = $row{'arrays'};
		@arrays = (ref $ref2 eq 'ARRAY' ) ? @$ref2 : ();
		#print "$row{'id'} rs:$row{'status'}\n";
		$status = ($row{'status'} && $row{'status'} eq 'no-status') ? check_status($row{'id'},@pool_status): $row{'status'};
		$zfs[$j]{'status'} = $status if $status;
		#@arrays = grep {defined $_} @arrays;
		#print "$row{id} $#arrays\n";
		#print Data::Dumper::Dumper \@arrays;
		foreach my $array (@arrays){
			#print 'ref: ', ref $array, "\n";
			#next if ref $array ne 'HASH';
			my %row2 = %$array;
			my $ref3 = $row2{'components'};
			my @components = (ref $ref3 eq 'ARRAY') ? @$ref3 : ();
			$l = 0;
			# zpool status: mirror-0  ONLINE       2     0     0
			$raid = ($row2{'raid'}) ? "$row2{'raid'}-$i": $row2{'raid'};
			$status = ($raid) ? check_status($raid,@pool_status): '';
			$zfs[$j]{'arrays'}[$k]{'status'} = $status;
			#print "$raid i:$i j:$j k:$k $status\n";
			foreach my $component (@components){
				my @temp = split /~/, $component;
				$status = ($temp[0]) ? check_status($temp[0],@pool_status): '';
				$zfs[$j]{'arrays'}[$k]{'components'}[$l] .= $status if $status;
				$l++;
			}
			$k++;
			# haven't seen a raid5/6 type array yet
			$i++ if $row2{'raid'}; # && $row2{'raid'} eq 'mirror';
		}
		$j++;
	}
	eval $end if $b_log;
	return @zfs;
}
sub check_status {
	eval $start if $b_log;
	my ($item,@pool_status) = @_;
	my ($status) = ('');
	foreach (@pool_status){
		my @temp = split /\s+/, $_;
		if ($temp[0] eq $item){
			last if !$temp[1]; 
			$status = $temp[1];
			last;
		}
	}
	eval $end if $b_log;
	return $status;
}
}

## RamData
{
package RamData;

sub get {
	my (@data,@rows,$key1,@ram,$val1);
	my $num = 0;
	my $ref = $alerts{'dmidecode'};
	@rows = main::get_memory_data_full('ram') if !$b_mem;
	if ( !$b_fake_dmidecode && $$ref{'action'} ne 'use'){
		$key1 = $$ref{'action'};
		$val1 = $$ref{$key1};
		@data = ({
		main::key($num++,1,1,'RAM Report') => '',
		main::key($num++,0,2,$key1) => $val1,
		});
		@rows = (@rows,@data);
	}
	else {
		@ram = dmidecode_data();
		if (@ram){
			@data = create_output(@ram);
		}
		else {
			$key1 = 'message';
			$val1 = main::row_defaults('ram-data');
			@data = ({
			main::key($num++,1,1,'RAM Report') => '',
			main::key($num++,0,2,$key1) => $val1,
			});
		}
		@rows = (@rows,@data);
	}
	eval $end if $b_log;
	return @rows;
}

sub create_output {
	eval $start if $b_log;
	my (@ram) = @_;
	return if !@ram;
	my $num = 0;
	my $j = 0;
	my (@data,@rows,$b_non_system);
	my ($arrays,$modules,$slots,$type_holder) = (0,0,0,'');
	foreach (@ram){
		$j = scalar @rows;
		my %ref = %$_;
		if (!$show{'ram-short'}){
			$b_non_system = ($ref{'use'} && lc($ref{'use'}) ne 'system memory') ? 1:0 ;
			$num = 1;
			@data = ({
			main::key($num++,1,1,'Array') => '',
			main::key($num++,1,2,'capacity') => process_size($ref{'capacity'}),
			});
			@rows = (@rows,@data);
			if ($ref{'cap-qualifier'}){
				$rows[$j]{main::key($num++,0,3,'note')} = $ref{'cap-qualifier'};
			}
			$rows[$j]{main::key($num++,0,2,'use')} = $ref{'use'} if $b_non_system;
			$rows[$j]{main::key($num++,0,2,'slots')} = $ref{'slots'};
			$ref{'eec'} ||= 'N/A';
			$rows[$j]{main::key($num++,0,2,'EC')} = $ref{'eec'};
			if ($extra > 0 && (!$b_non_system || 
				( main::is_numeric($ref{'max-module-size'}) && $ref{'max-module-size'} > 10 ) ) ){
				$rows[$j]{main::key($num++,1,2,'max module size')} = process_size($ref{'max-module-size'});
				if ($ref{'mod-qualifier'}){
					$rows[$j]{main::key($num++,0,3,'note')} = $ref{'mod-qualifier'};
				}
			}
		}
		else {
			$slots += $ref{'slots'} if $ref{'slots'};
			$arrays++;
		}
		foreach my $ref2 ($ref{'modules'}){
			next if ref $ref2 ne 'ARRAY';
			my @modules = @$ref2;
			# print Data::Dumper::Dumper \@modules;
			foreach my $ref3 ( @modules){
				$num = 1;
				$j = scalar @rows;
				# multi array setups will start index at next from previous array
				next if ref $ref3 ne 'HASH';
				my %mod = %$ref3;
				if ($show{'ram-short'}){
					$modules++ if ($mod{'size'} =~ /^\d/);
					$type_holder = $mod{'device-type'} if $mod{'device-type'};
					next;
				}
				next if ($show{'ram-modules'} && $mod{'size'} =~ /\D/);
				$mod{'locator'} ||= 'N/A';
				@data = ({
				main::key($num++,1,2,'Device') => $mod{'locator'},
				main::key($num++,0,3,'size') => process_size($mod{'size'}),
				});
				@rows = (@rows,@data);
				next if ($mod{'size'} =~ /\D/);
				if ($extra > 1 && $mod{'type'} ){
					$rows[$j]{main::key($num++,0,3,'info')} = $mod{'type'};
				}
				$rows[$j]{main::key($num++,0,3,'speed')} = $mod{'speed'};
				if ($extra > 0 ){
					$mod{'device-type'} ||= 'N/A';
					$rows[$j]{main::key($num++,0,3,'type')} = $mod{'device-type'};
					if ($extra > 2 && $mod{'device-type'} ne 'N/A'){
						$mod{'device-type-detail'} ||= 'N/A';
						$rows[$j]{main::key($num++,0,3,'detail')} = $mod{'device-type-detail'};
					}
				}
				if ($extra > 2 ){
					$mod{'data-width'} ||= 'N/A';
					$rows[$j]{main::key($num++,0,3,'bus width')} = $mod{'data-width'};
					$mod{'total-width'} ||= 'N/A';
					$rows[$j]{main::key($num++,0,3,'total')} = $mod{'total-width'};
				}
				if ($extra > 1 ){
					$mod{'manufacturer'} ||= 'N/A';
					$rows[$j]{main::key($num++,0,3,'manufacturer')} = $mod{'manufacturer'};
					$mod{'part-number'} ||= 'N/A';
					$rows[$j]{main::key($num++,0,3,'part-no')} = $mod{'part-number'};
				}
				if ($extra > 2 ){
					$mod{'serial'} = main::apply_filter($mod{'serial'});
					$rows[$j]{main::key($num++,0,3,'serial')} = $mod{'serial'};
				}
			}
		}
	}
	if ($show{'ram-short'}){
		$num = 1;
		$type_holder ||= 'N/A';
		@data = ({
		main::key($num++,1,1,'Report') => '',
		main::key($num++,0,2,'arrays') => $arrays,
		main::key($num++,0,2,'slots') => $slots,
		main::key($num++,0,2,'modules') => $modules,
		main::key($num++,0,2,'type') => $type_holder,
		});
		@rows = (@rows,@data);
	}
	eval $end if $b_log;
	return @rows;
}

sub dmidecode_data {
	eval $start if $b_log;
	my ($b_5,$handle,@ram,@temp);
	my ($derived_module_size,$max_cap_5,$max_cap_16,$max_module_size) = (0,0,0,0);
	my ($i,$j,$k) = (0,0,0);
	foreach (@dmi){
		my @ref = @$_;
		## NOTE: do NOT reset these values, that causes failures
		# ($derived_module_size,$max_cap_5,$max_cap_16,$max_module_size) = (0,0,0,0);
		if ($ref[0] == 5){
			$ram[$k] = ({}) if !$ram[$k];
			foreach my $item (@ref){
				@temp = split /:\s*/, $item;
				next if ! $temp[1];
				if ($temp[0] eq 'Maximum Memory Module Size'){
					$max_module_size = calculate_size($temp[1],$max_module_size);
					$ram[$k]{'max-module-size'} = $max_module_size;
				}
				elsif ($temp[0] eq 'Maximum Total Memory Size'){
					$max_cap_5 = calculate_size($temp[1],$max_cap_5);
					$ram[$k]{'max-capacity-5'} = $max_cap_5;
				}
				elsif ($temp[0] eq 'Memory Module Voltage'){
					$temp[1] =~ s/\s*V.*$//;
					$ram[$k]{'voltage'} = $temp[1];
				}
				elsif ($temp[0] eq 'Associated Memory Slots'){
					$ram[$k]{'slots-5'} = $temp[1];
				}
			}
			$ram[$k]{'modules'} = ([],);
			#print Data::Dumper::Dumper \@ram;
			$b_5 = 1;
		}
		elsif ($ref[0] == 6){
			my ($size,$speed,$type) = (0,0,0);
			foreach my $item (@ref){
				@temp = split /:\s*/, $item;
				next if ! $temp[1];
				if ($temp[0] eq 'Installed Size'){
					# get module size
					$size = calculate_size($temp[1],0);
					# get data after module size
					$temp[1] =~ s/ Connection\)?//;
					$temp[1] =~ s/^[0-9]+\s*[KkMGTP]B\s*\(?//;
					$type = lc($temp[1]);
				}
				elsif ($temp[0] eq 'Current Speed'){
					$speed = $temp[1];
				}
			}
			$ram[$k]{'modules'}[$j] = ({
			'size' => $size,
			'speed-ns' => $speed,
			'type' => $type,
			});
			#print Data::Dumper::Dumper \@ram;
			$j++;
		}
		elsif ($ref[0] == 16){
			$handle = $ref[1];
			$ram[$handle] = $ram[$k] if $ram[$k];
			$ram[$k] = undef;
			$ram[$handle] = ({}) if !$ram[$handle];
			# ($derived_module_size,$max_cap_16) = (0,0);
			foreach my $item (@ref){
				@temp = split /:\s*/, $item;
				next if ! $temp[1];
				if ($temp[0] eq 'Maximum Capacity'){
					$max_cap_16 = calculate_size($temp[1],$max_cap_16);
					$ram[$handle]{'max-capacity-16'} = $max_cap_16;
				}
				# note: these 3 have cleaned data in set_dmidecode_data, so replace stuff manually
				elsif ($temp[0] eq 'Location'){
					$temp[1] =~ s/\sOr\sMotherboard//;
					$temp[1] ||= 'System Board';
					$ram[$handle]{'location'} = $temp[1];
				}
				elsif ($temp[0] eq 'Use'){
					$temp[1] ||= 'System Memory';
					$ram[$handle]{'use'} = $temp[1];
				}
				elsif ($temp[0] eq 'Error Correction Type'){
					$temp[1] ||= 'None';
					$ram[$handle]{'eec'} = $temp[1];
				}
				elsif ($temp[0] eq 'Number Of Devices'){
					$ram[$handle]{'slots-16'} = $temp[1];
				}
				#print "0: $temp[0]\n";
			}
			$ram[$handle]{'derived-module-size'} = 0;
			$ram[$handle]{'device-count-found'} = 0;
			$ram[$handle]{'used-capacity'} = 0;
			#print "s16: $ram[$handle]{'slots-16'}\n";
		}
		elsif ($ref[0] == 17){
			my ($bank_locator,$configured_clock_speed,$data_width) = ('','','');
			my ($device_type,$device_type_detail,$form_factor,$locator,$main_locator) = ('','','','','');
			my ($manufacturer,$part_number,$serial,$speed,$total_width) = ('','','','','');
			my ($device_size,$i_data,$i_total,$working_size) = (0,0,0,0);
			foreach my $item (@ref){
				@temp = split /:\s*/, $item;
				next if ! $temp[1];
				if ($temp[0] eq 'Array Handle'){
					$handle = hex($temp[1]);
				}
				elsif ($temp[0] eq 'Data Width'){
					$data_width = $temp[1];
				}
				elsif ($temp[0] eq 'Total Width'){
					$total_width = $temp[1];
				}
				# do not try to guess from installed modules, only use this to correct type 5 data
				elsif ($temp[0] eq 'Size'){
					# we want any non real size data to be preserved
					if ( $temp[1] =~ /^[0-9]+\s*[KkMTPG]B/ ) {
						$derived_module_size = calculate_size($temp[1],$derived_module_size);
						$working_size = calculate_size($temp[1],0);
						$device_size = $working_size;
					}
					else {
						$device_size = $temp[1];
					}
				}
				elsif ($temp[0] eq 'Locator'){
					$temp[1] =~ s/RAM slot #/Slot/;
					$locator = $temp[1];
				}
				elsif ($temp[0] eq 'Bank Locator'){
					$bank_locator = $temp[1];
				}
				elsif ($temp[0] eq 'Form Factor'){
					$form_factor = $temp[1];
				}
				elsif ($temp[0] eq 'Type'){
					$device_type = $temp[1];
				}
				elsif ($temp[0] eq 'Type Detail'){
					$device_type_detail = $temp[1];
				}
				elsif ($temp[0] eq 'Speed'){
					$speed = $temp[1];
				}
				elsif ($temp[0] eq 'Configured Clock Speed'){
					$configured_clock_speed = $temp[1];
				}
				elsif ($temp[0] eq 'Manufacturer'){
					$temp[1] = main::dmi_cleaner($temp[1]);
					$manufacturer = $temp[1];
				}
				elsif ($temp[0] eq 'Part Number'){
					$temp[1] =~ s/(^[0]+$||.*Module.*|Undefined.*|PartNum.*|\[Empty\]|^To be filled.*)//g;
					$part_number = $temp[1];
				}
				elsif ($temp[0] eq 'Serial Number'){
					$temp[1] =~ s/(^[0]+$|Undefined.*|SerNum.*|\[Empty\]|^To be filled.*)//g;
					$serial = $temp[1];
				}
			}
			# because of the wide range of bank/slot type data, we will just use
			# the one that seems most likely to be right. Some have: Bank: SO DIMM 0 slot: J6A
			# so we dump the useless data and use the one most likely to be visibly correct
			if ( $bank_locator =~ /DIMM/ ) {
				$main_locator = $bank_locator;
			}
			else {
				$main_locator = $locator;
			}
			if ($working_size =~ /^[0-9][0-9]+$/) {
				$ram[$handle]{'device-count-found'}++;
				# build up actual capacity found for override tests
				$ram[$handle]{'used-capacity'} += $working_size;
			}
			# sometimes the data is just wrong, they reverse total/data. data I believe is
			# used for the actual memory bus width, total is some synthetic thing, sometimes missing.
			# note that we do not want a regular string comparison, because 128 bit memory buses are
			# in our future, and 128 bits < 64 bits with string compare
			$data_width =~ /(^[0-9]+).*/;
			$i_data = $1;
			$total_width =~ /(^[0-9]+).*/;
			$i_total = $1;
			if ($i_data && $i_total && $i_data > $i_total){
				my $temp_width = $data_width;
				$data_width = $total_width;
				$total_width = $temp_width;
			}
			$ram[$handle]{'derived-module-size'} = $derived_module_size;
			$ram[$handle]{'modules'}[$i]{'configured-clock-speed'} = $configured_clock_speed;
			$ram[$handle]{'modules'}[$i]{'data-width'} = $data_width;
			$ram[$handle]{'modules'}[$i]{'size'} = $device_size;
			$ram[$handle]{'modules'}[$i]{'device-type'} = $device_type;
			$ram[$handle]{'modules'}[$i]{'device-type-detail'} = lc($device_type_detail);
			$ram[$handle]{'modules'}[$i]{'form-factor'} = $form_factor;
			$ram[$handle]{'modules'}[$i]{'locator'} = $main_locator;
			$ram[$handle]{'modules'}[$i]{'manufacturer'} = $manufacturer;
			$ram[$handle]{'modules'}[$i]{'part-number'} = $part_number;
			$ram[$handle]{'modules'}[$i]{'serial'} = $serial;
			$ram[$handle]{'modules'}[$i]{'speed'} = $speed;
			$ram[$handle]{'modules'}[$i]{'total-width'} = $total_width;
			$i++
		}
		elsif ($ref[0] < 17 ){
			next;
		}
		elsif ($ref[0] > 17 ){
			last;
		}
	}
	@ram = data_processor(@ram) if @ram;
	main::log_data('dump','@ram',\@ram) if $b_log;
	# print Data::Dumper::Dumper \@ram;
	eval $end if $b_log;
	return @ram;
}
sub data_processor {
	eval $start if $b_log;
	my (@ram) = @_;
	my $b_debug = 0;
	my (@return,@temp);
	my $est = 'est.';
	foreach (@ram){
		# because we use the actual array handle as the index, 
		# there will be many undefined keys
		next if ! defined $_;
		my %ref = %$_;
		my ($max_cap,$max_mod_size) = (0,0);
		my ($alt_cap,$est_cap,$est_mod,$unit) = (0,'','','');
		$max_cap = $ref{'max-capacity-16'};
		$max_cap ||= 0;
		# make sure they are integers not string if empty
		$ref{'slots-5'} ||= 0; 
		$ref{'slots-16'} ||= 0; 
		$ref{'max-capacity-5'} ||= 0;
		$ref{'max-module-size'} ||= 0;
		$ref{'used-capacity'} ||= 0;
		#$ref{'max-module-size'} = 0;# debugger
		# 1: if max cap 1 is null, and max cap 2 not null, use 2
		if ($b_debug){
			print "1: mms: $ref{'max-module-size'} :dms: $ref{'derived-module-size'} :mc: $max_cap :uc: $ref{'used-capacity'}\n";
			print "1a: s5: $ref{'slots-5'} s16: $ref{'slots-16'}\n";
		}
		if (!$max_cap && $ref{'max-capacity-5'}) {
			$max_cap = $ref{'max-capacity-5'};
		}
		if ($b_debug){
			print "2: mms: $ref{'max-module-size'} :dms: $ref{'derived-module-size'} :mc: $max_cap :uc: $ref{'used-capacity'}\n";
		}
		# 2: now check to see if actually found module sizes are > than listed max module, replace if >
		if ( $ref{'max-module-size'} && $ref{'derived-module-size'} && 
		     $ref{'derived-module-size'} > $ref{'max-module-size'} ){
			$ref{'max-module-size'} = $ref{'derived-module-size'};
			$est_mod = $est;
		}
		if ($b_debug){
			print "3: dcf: $ref{'device-count-found'} :dms: $ref{'derived-module-size'} :mc: $max_cap :uc: $ref{'used-capacity'}\n";
		}
		# note: some cases memory capacity == max module size, so one stick will fill it
		# but I think only with cases of 2 slots does this happen, so if > 2, use the count of slots.
		if ($max_cap && ($ref{'device-count-found'} || $ref{'slots-16'}) ){
			# first check that actual memory found is not greater than listed max cap, or
			# checking to see module count * max mod size is not > used capacity
			if ($ref{'used-capacity'} && $ref{'max-capacity-16'}){
				if ($ref{'used-capacity'} > $max_cap){
					if ($ref{'max-module-size'} && 
					  $ref{'used-capacity'} < ($ref{'slots-16'} * $ref{'max-module-size'} )){
						$max_cap = $ref{'slots-16'} * $ref{'max-module-size'};
						$est_cap = $est;
						print "A\n" if $b_debug;
					}
					elsif ($ref{'derived-module-size'} && 
					  $ref{'used-capacity'} < ($ref{'slots-16'} * $ref{'derived-module-size'}) ){
						$max_cap = $ref{'slots-16'} * $ref{'derived-module-size'};
						$est_cap = $est;
						print "B\n" if $b_debug;
					}
					else {
						$max_cap = $ref{'used-capacity'};
						$est_cap = $est;
						print "C\n" if $b_debug;
					}
				}
			}
			# note that second case will never really activate except on virtual machines and maybe
			# mobile devices
			if (!$est_cap){
				# do not do this for only single modules found, max mod size can be equal to the array size
				if ($ref{'slots-16'} > 1 && $ref{'device-count-found'} > 1 && 
				  $max_cap < ($ref{'derived-module-size'} * $ref{'slots-16'} ) ){
					$max_cap = $ref{'derived-module-size'} * $ref{'slots-16'};
					$est_cap = $est;
					print "D\n" if $b_debug;
				}
				elsif ($ref{'device-count-found'} > 0 && $max_cap < ( $ref{'derived-module-size'} * $ref{'device-count-found'} )){
					$max_cap = $ref{'derived-module-size'} * $ref{'device-count-found'};
					$est_cap = $est;
					print "E\n" if $b_debug;
				}
				## handle cases where we have type 5 data: mms x device count equals type 5 max cap
				# however do not use it if cap / devices equals the derived module size
				elsif ($ref{'max-module-size'} > 0 &&
				  ($ref{'max-module-size'} * $ref{'slots-16'}) == $ref{'max-capacity-5'} &&
				  $ref{'max-capacity-5'} != $ref{'max-capacity-16'} &&
				  $ref{'derived-module-size'} != ($ref{'max-capacity-16'}/$ref{'slots-16'}) ){
					$max_cap = $ref{'max-capacity-5'};
					$est_cap = $est;
					print "F\n" if $b_debug;
				}
				
			}
			if ($b_debug){
				print "4: mms: $ref{'max-module-size'} :dms: $ref{'derived-module-size'} :mc: $max_cap :uc: $ref{'used-capacity'}\n";
			}
			# some cases of type 5 have too big module max size, just dump the data then since
			# we cannot know if it is valid or not, and a guess can be wrong easily
			if ($ref{'max-module-size'} && $max_cap && $ref{'max-module-size'} > $max_cap){
				$ref{'max-module-size'} = 0;
			}
			if ($b_debug){
				print "5: dms: $ref{'derived-module-size'} :s16: $ref{'slots-16'} :mc: $max_cap\n";
			}
			
			# now prep for rebuilding the ram array data 
			if (!$ref{'max-module-size'}){
				# ie: 2x4gB
				if (!$est_cap && $ref{'derived-module-size'} > 0 && $max_cap > ($ref{'derived-module-size'} * $ref{'slots-16'} * 4) ){
					$est_cap = 'check';
					print "G\n" if $b_debug;
				}
				if ($max_cap && ($ref{'slots-16'} || $ref{'slots-5'})){
					my $slots = 0;
					if ($ref{'slots-16'} && $ref{'slots-16'} >= $ref{'slots-5'}){
						$slots = $ref{'slots-16'};
					}
					elsif ($ref{'slots-5'} && $ref{'slots-5'} > $ref{'slots-16'}){
						$slots = $ref{'slots-5'};
					}
					# print "slots: $slots\n" if $b_debug;
					if ($ref{'derived-module-size'} * $slots > $max_cap){
						$ref{'max-module-size'} = $ref{'derived-module-size'};
						print "H\n" if $b_debug;
					}
					else {
						$ref{'max-module-size'} = sprintf("%.f",$max_cap/$slots);
						print "J\n" if $b_debug;
					}
					$est_mod = $est;
				}
			}
			# case where listed max cap is too big for actual slots x max cap, eg:
			# listed max cap, 8gb, max mod 2gb, slots 2
			else {
				if (!$est_cap && $ref{'max-module-size'} > 0){
					if ($max_cap > ( $ref{'max-module-size'} * $ref{'slots-16'})){
						$est_cap = 'check';
						print "K\n" if $b_debug;
					}
				}
			}
		}
		@temp = ({
		'capacity' => $max_cap,
		'cap-qualifier' => $est_cap,
		'eec' => $ref{'eec'},
		'location' => $ref{'location'},
		'max-module-size' => $ref{'max-module-size'},
		'mod-qualifier' => $est_mod,
		'modules' => $ref{'modules'},
		'slots' => $ref{'slots-16'},
		'use' => $ref{'use'},
		'voltage' => $ref{'voltage'},
		});
		@return = (@return,@temp);
	}
	eval $end if $b_log;
	return @return;
}
sub process_size {
	my ($size) = @_;
	my ($b_trim,$unit) = (0,'');
	#print "size0: $size\n";
	return 'N/A' if ( ! $size );
	#return $size if $size =~ /\D/;
	return $size if !main::is_numeric($size);
	#print "size: $size\n";
	if ( $size < 1024 ){
		$unit='MiB';
	}
	elsif ( $size < 1024000 ){
		$size = $size / 1024;
		$unit='GiB';
		$b_trim = 1;
	}
	elsif ( $size < 1024000000 ){
		$size = $size / 1024000;
		$unit='TiB';
		$b_trim = 1;
	}
	# we only want a max 2 decimal places, and only when it's 
	# a unit > MB
	$size = sprintf("%.2f",$size) if $b_trim;
	$size =~ s/\.[0]+$//;
	$size = "$size $unit";
	return $size;
}
sub calculate_size {
	my ($data, $size) = @_;
	# technically k is KiB, K is KB but can't trust that
	if ( $data =~ /^[0-9]+\s*[kKGMTP]B/) {
		if ( $data =~ /([0-9]+)\s*GB/ ) {
			$data = $1 * 1024;
		}
		elsif ( $data =~ /([0-9]+)\s*MB/ ) {
			$data = $1;
		}
		elsif ( $data =~ /([0-9]+)\s*TB/ ) {
			$data = $1 * 1024 * 1000;
		}
		elsif ( $data =~ /([0-9]+)\s*PB/ ) {
			$data = $1 * 1024 * 1000 * 1000;
		}
		elsif ( $data =~ /([0-9]+)\s*[kK]B/ ) {
			$data = $1/1024;
			#print "d3:$data\n";
		}
		#print "d1a: $data s1: $size\n";
		if (main::is_numeric($data) && $data > $size ) {
		#if ($data =~ /^[0-9][0-9]+$/ && $data > $size ) {
			$size = $data;
		}
		#print "d1b: $data s1: $size\n";
	}
	else {
		$size = 0;
	}
	#print "d2: $data s2: $size\n";
	return $size;
}
}

## RepoData
{
package RepoData;

# easier to keep these package global, but undef after done
my (@dbg_files,$debugger_dir);
my $num = 0;
sub get {
	eval $start if $b_log;
	($debugger_dir) = @_;
	my (@data,@rows,@rows_p,@rows_r);
	if ($extra > 0 && !$b_pkg){
		my %packages = PackageData::get('main',\$num);
		my @data;
		for (keys %packages){
			$rows_p[0]{$_} = $packages{$_};
		}
		$b_pkg = 1;
	}
	$num = 0;
	if ($bsd_type){
		@rows_r = get_repos_bsd();
	}
	else {
		@rows_r = get_repos_linux();
	}
	if ($debugger_dir){
		@rows = @dbg_files;
		undef @dbg_files;
		undef $debugger_dir;
	}
	else {
		if (!@rows_r){
			my $pm = (!$bsd_type) ? 'package manager': 'OS type';
			@data = (
			{main::key($num++,0,1,'Alert') => "No repo data detected. Does $self_name support your $pm?"},
			);
		}
		@rows = (@rows_p,@rows_r,@data);
	}
	eval $end if $b_log;
	return @rows;
}
sub get_repos_linux {
	eval $start if $b_log;
	my (@content,@data,@data2,@data3,@files,$repo,@repos,@rows);
	my ($key,$path);
	my $apk = '/etc/apk/repositories';
	my $apt = '/etc/apt/sources.list';
	my $apt_termux = '/data/data/com.termux/files/usr' . $apt;
	$apt = $apt_termux if -e $apt_termux; # for android termux
	my $cards = '/etc/cards.conf';
	my $eopkg_dir = '/var/lib/eopkg/';
	my $pacman = '/etc/pacman.conf';
	my $pacman_g2 = '/etc/pacman-g2.conf';
	my $pisi_dir = '/etc/pisi/';
	my $portage_dir = '/etc/portage/repos.conf/';
	my $portage_gentoo_dir = '/etc/portage-gentoo/repos.conf/';
	my $slackpkg = '/etc/slackpkg/mirrors';
	my $slackpkg_plus = '/etc/slackpkg/slackpkgplus.conf';
	my $slapt_get = '/etc/slapt-get/';
	my $tce_app = '/usr/bin/tce';
	my $tce_file = '/opt/tcemirror';
	my $tce_file2 = '/opt/localmirrors';
	my $yum_conf = '/etc/yum.conf';
	my $yum_repo_dir = '/etc/yum.repos.d/';
	my $xbps_dir_1 = '/etc/xbps.d/';
	my $xbps_dir_2 = '/usr/share/xbps.d/';
	my $zypp_repo_dir = '/etc/zypp/repos.d/';
	my $b_test = 0;
	# apt - debian, buntus, also sometimes some yum/rpm repos may create 
	# apt repos here as well
	if (-f $apt || -d "$apt.d"){
		my ($apt_arch,$apt_comp,$apt_suites,$apt_types,@apt_urls,@apt_working,
		$b_apt_enabled,$file,$string);
		my $counter = 0;
		@files = main::globber("$apt.d/*.list");
		push @files, $apt;
		main::log_data('data',"apt repo files:\n" . main::joiner(\@files, "\n", 'unset') ) if $b_log;
		foreach ( sort @files){
			# altlinux/pclinuxos use rpms in apt files
			@data = repo_builder($_,'apt','^\s*(deb|rpm)') if -r $_;
			@rows = (@rows,@data);
		}
		#@files = main::globber("$ENV{'HOME'}/bin/scripts/inxi/data/repo/apt/*.sources");
		@files = main::globber("$apt.d/*.sources");
		main::log_data('data',"apt deb822 repo files:\n" . main::joiner(\@files, "\n", 'unset') ) if $b_log;
		foreach $file (@files){
			# critical: whitespace is the separator, no logical ordering of 
			# field names exists within each entry.
			@data2 = main::reader($file);
			#print Data::Dumper::Dumper \@data2;
			if (@data2){
				@data2 = map {s/^\s*$/~/;$_} @data2;
				push @data2, '~';
			}
			push @dbg_files, $file if $debugger_dir;
			#print "$file\n";
			@apt_urls = ();
			@apt_working = ();
			$b_apt_enabled = 1;
			foreach my $row (@data2){
				# NOTE: the syntax of deb822 must be considered a bug, it's sloppy beyond belief.
				# deb822 supports line folding which starts with space
				# BUT: you can start a URIs: block of urls with a space, sigh.
				next if $row =~ /^\s+/ && $row !~ /^\s+[^#]+:\//; 
				# strip out line space starters now that it's safe 
				$row =~ s/^\s+//;
				#print "$row\n";
				if ($row eq '~'){
					if (@apt_working && $b_apt_enabled){
						#print "1: url builder\n";
						foreach $repo (@apt_working){
							$string = $apt_types;
							$string .= ' [arch=' . $apt_arch . ']' if $apt_arch;
							$string .= ' ' . $repo;
							$string .= ' ' . $apt_suites if $apt_suites ;
							$string .= ' ' . $apt_comp if $apt_comp;
							#print "s1:$string\n";
							push @data3, $string;
						}
						#print join "\n",@data3,"\n";
						@apt_urls = (@apt_urls,@data3);
					}
					@data3 = ();
					@apt_working = ();
					$apt_arch = '';
					$apt_comp = '';
					$apt_suites = '';
					$apt_types = '';
					$b_apt_enabled = 1;
				}
				#print "row:$row\n";
				elsif ($row =~ /^Types:\s*(.*)/i){
					#print "ath:$type_holder\n";
					$apt_types = $1;
				}
				elsif ($row =~ /^Enabled:\s*(.*)/i){
					my $status = $1;
					$b_apt_enabled = ($status =~ /\b(disable|false|off|no|without)\b/i) ? 0: 1;
				}
				elsif ($row =~ /^[^#]+:\//){
					my $url = $row;
					$url =~ s/^URIs:\s*//i;
					push @apt_working, $url if $url;
				}
				elsif ($row =~ /^Suites:\s*(.*)/i){
					$apt_suites = $1;
				}
				elsif ($row =~ /^Components:\s*(.*)/i){
					$apt_comp = $1;
				}
				elsif ($row =~ /^Architectures:\s*(.*)/i){
					$apt_arch = $1;
				}
			}
			if (@apt_urls){
				$key = repo_data('active','apt');
				@apt_urls = url_cleaner(@apt_urls);
			}
			else {
				$key = repo_data('missing','apt');
			}
			@data = (
			{main::key($num++,1,1,$key) => $file},
			[@apt_urls],
			);
			@rows = (@rows,@data);
		}
		@files = ();
	}
	# pacman: Arch and derived
	if (-f $pacman || -f $pacman_g2){
		$repo = 'pacman';
		if (-f $pacman_g2 ){
			$pacman = $pacman_g2;
			$repo = 'pacman-g2';
		}
		@files = main::reader($pacman,'strip');
		if (@files){
			@repos = grep {/^\s*Server/i} @files;
			@files = grep {/^\s*Include/i} @files;
		}
		if (@files){
			@files = map {
				my @working = split( /\s+=\s+/, $_); 
				$working[1];
			} @files;
		}
		@files = sort(@files);
		@files = main::uniq(@files);
		unshift @files, $pacman if @repos;
		foreach (@files){
			if (-f $_){
				@data = repo_builder($_,$repo,'^\s*Server','\s*=\s*',1);
				@rows = (@rows,@data);
			}
			else {
				# set it so the debugger knows the file wasn't there
				push @dbg_files, $_ if $debugger_dir;
				@data = (
				{main::key($num++,1,1,'File listed in') => $pacman},
				[("$_ does not seem to exist.")],
				);
				@rows = (@rows,@data);
			}
		}
		if (!@rows){
			@data = (
			{main::key($num++,0,1,repo_data('missing','files')) => $pacman },
			);
			@rows = (@rows,@data);
		}
	}
	# slackware
	if (-f $slackpkg || -f $slackpkg_plus || -d $slapt_get){
		#$slackpkg = "$ENV{HOME}/bin/scripts/inxi/data/repo/slackware/slackpkg-2.conf";
		if (-f $slackpkg){
			@data = repo_builder($slackpkg,'slackpkg','^[[:space:]]*[^#]+');
			@rows = (@rows,@data);
		}
		if (-d $slapt_get){
			@data2 = main::globber("${slapt_get}*");
			foreach my $file (@data2){
				@data = repo_builder($file,'slaptget','^\s*SOURCE','\s*=\s*',1);
				@rows = (@rows,@data);
			}
		}
		if (-f $slackpkg_plus){
			push @dbg_files, $slackpkg_plus if $debugger_dir;
			@data =  main::reader($slackpkg_plus,'strip');
			my (@repoplus_list,$active_repos);
			foreach my $row (@data){
				@data2 = split /\s*=\s*/, $row;
				@data2 = map { $_ =~ s/^\s+|\s+$//g ; $_ } @data2;
				last if $data2[0] =~ /^SLACKPKGPLUS/i && $data2[1] eq 'off';
				# REPOPLUS=( slackpkgplus restricted alienbob ktown multilib slacky)
				if ($data2[0] =~ /^REPOPLUS/i){
					@repoplus_list = split /\s+/, $data2[1];
					@repoplus_list = map {s/\(|\)//g; $_} @repoplus_list;
					$active_repos = join ('|',@repoplus_list);
					
				}
				# MIRRORPLUS['multilib']=http://taper.alienbase.nl/mirrors/people/alien/multilib/14.1/
				if ($active_repos && $data2[0] =~ /^MIRRORPLUS/i){
					$data2[0] =~ s/MIRRORPLUS\[\'|\'\]//ig;
					if ($data2[0] =~ /$active_repos/){
						push @content,"$data2[0] ~ $data2[1]";
					}
				}
			}
			if (! @content){
				$key = repo_data('missing','slackpkg+');
			}
			else {
				@content = url_cleaner(@content);
				$key = repo_data('active','slackpkg+');
			}
			@data = (
			{main::key($num++,1,1,$key) => $slackpkg_plus},
			[@content],
			);
			@data = url_cleaner(@data);
			@rows = (@rows,@data);
			@content = ();
		}
	}
	# redhat/suse
	if (-d $yum_repo_dir || -f $yum_conf || -d $zypp_repo_dir){
		if (-d $yum_repo_dir || -f $yum_conf){
			@files = main::globber("$yum_repo_dir*.repo");
			push @files, $yum_conf if -f $yum_conf;
			$repo = 'yum';
		}
		elsif (-d $zypp_repo_dir){
			@files = main::globber("$zypp_repo_dir*.repo");
			main::log_data('data',"zypp repo files:\n" . main::joiner(\@files, "\n", 'unset')) if $b_log;
			$repo = 'zypp';
		}
 		#$repo = 'yum';
 		#push @files, "$ENV{'HOME'}/bin/scripts/inxi/data/repo/yum/rpmfusion-nonfree-1.repo";
		if (@files){
			foreach (sort @files){
				@data2 = main::reader($_);
				push @dbg_files, $_ if $debugger_dir;
				my ($enabled,$url,$title) = (undef,'','');
				foreach my $line (@data2){
					# this is a hack, assuming that each item has these fields listed, we collect the 3
					# items one by one, then when the url/enabled fields are set, we print it out and
					# reset the data. Not elegant but it works. Note that if enabled was not present
					# we assume it is enabled then, and print the line, reset the variables. This will
					# miss the last item, so it is printed if found in END
					if ($line =~ /^\[(.+)\]/){
						my $temp = $1;
						if ($url && $title && defined $enabled){
							if ($enabled > 0){
								push @content, "$title ~ $url";
							}
							($enabled,$url,$title) = (undef,'','');
						}
						$title = $temp;
					}
					# Note: it looks like enabled comes before url
					elsif ($line =~ /^(metalink|mirrorlist|baseurl)\s*=\s*(.*)/i){
						$url = $2;
					}
					# note: enabled = 1. enabled = 0 means disabled
					elsif ($line =~ /^enabled\s*=\s*(0|1|No|Yes|True|False)/i){
						$enabled = $1;
						$enabled =~ s/(No|False)/0/i;
						$enabled =~ s/(Yes|True)/1/i;
					}
					# print out the line if all 3 values are found, otherwise if a new
					# repoTitle is hit above, it will print out the line there instead
					if ($url && $title && defined $enabled){
						if ($enabled > 0){
 							push @content, "$title ~ $url";
 						}
 						($enabled,$url,$title) = (0,'','');
					}
				}
				# print the last one if there is data for it
				if ($url && $title && $enabled){
					push @content, "$title ~ $url";
				}
				if (! @content){
					$key = repo_data('missing',$repo);
				}
				else {
					@content = url_cleaner(@content);
					$key = repo_data('active',$repo);
				}
				@data = (
				{main::key($num++,1,1,$key) => $_},
				[@content],
				);
				@rows = (@rows,@data);
				@content = ();
			}
		}
		# print Data::Dumper::Dumper \@rows;
	}
	# gentoo 
	if ( (-d $portage_dir || -d $portage_gentoo_dir ) && main::check_program('emerge')){
		@files = (main::globber("$portage_dir*.conf"),main::globber("$portage_gentoo_dir*.conf"));
		$repo = 'portage';
		if (@files){
			foreach (sort @files){
				@data2 = main::reader($_);
				push @dbg_files, $_ if $debugger_dir;
				my ($enabled,$url,$title) = (undef,'','');
				foreach my $line (@data2){
					# this is a hack, assuming that each item has these fields listed, we collect the 3
					# items one by one, then when the url/enabled fields are set, we print it out and
					# reset the data. Not elegant but it works. Note that if enabled was not present
					# we assume it is enabled then, and print the line, reset the variables. This will
					# miss the last item, so it is printed if found in END
					if ($line =~ /^\[(.+)\]/){
						my $temp = $1;
						if ($url && $title && defined $enabled){
							if ($enabled > 0){
								push @content, "$title ~ $url";
							}
							($enabled,$url,$title) = (undef,'','');
						}
						$title = $temp;
					}
					elsif ($line =~ /^(sync-uri)\s*=\s*(.*)/i){
						$url = $2;
					}
					# note: enabled = 1. enabled = 0 means disabled
					elsif ($line =~ /^auto-sync\s*=\s*(0|1|No|Yes|True|False)/i){
						$enabled = $1;
						$enabled =~ s/(No|False)/0/i;
						$enabled =~ s/(Yes|True)/1/i;
					}
					# print out the line if all 3 values are found, otherwise if a new
					# repoTitle is hit above, it will print out the line there instead
					if ($url && $title && defined $enabled){
						if ($enabled > 0){
 							push @content, "$title ~ $url";
 						}
 						($enabled,$url,$title) = (undef,'','');
					}
				}
				# print the last one if there is data for it
				if ($url && $title && $enabled){
					push @content, "$title ~ $url";
				}
				if (! @content){
					$key = repo_data('missing','portage');
				}
				else {
					@content = url_cleaner(@content);
					$key = repo_data('active','portage');
				}
				@data = (
				{main::key($num++,1,1,$key) => $_},
				[@content],
				);
				@rows = (@rows,@data);
				@content = ();
			}
		}
	}
	# Alpine linux
	if (-f $apk){
		@data = repo_builder($apk,'apk','^\s*[^#]+');
		@rows = (@rows,@data);
	}
	# cards/nutyx
	if (-f $cards){
		@data3 = main::reader($cards,'clean');
		push @dbg_files, $cards if $debugger_dir;
		foreach (@data3){
			if ($_ =~ /^dir\s+\/[^\|]+\/([^\/\|]+)\s*(\|\s*((http|ftp).*))?/){
				my $type = ($3) ? $3: 'local';
				push @content, "$1 ~ $type";
			}
		}
		if (! @content){
			$key = repo_data('missing','cards');
		}
		else {
			@content = url_cleaner(@content);
			$key = repo_data('active','cards');
		}
		@data = (
		{main::key($num++,1,1,$key) => $cards},
		[@content],
		);
		@rows = (@rows,@data);
		@content = ();
	}
	# TinyCore 
	if (-e $tce_app || -f $tce_file || -f $tce_file2){
		@data = repo_builder($tce_file,'tce','^\s*[^#]+');
		@rows = (@rows,@data);
		if (-f $tce_file2){
			@data = repo_builder($tce_file2,'tce','^\s*[^#]+');
			@rows = (@rows,@data);
		}
	}
	# Void 
	if (-d $xbps_dir_1 || -d $xbps_dir_2){
		@files = main::globber("$xbps_dir_1*.conf");
		@files = (@files,main::globber("$xbps_dir_2*.conf")) if -d $xbps_dir_2;
		main::log_data('data',"xbps repo files:\n" . main::joiner(\@files, "\n", 'unset') ) if $b_log;
		foreach ( sort @files){
			@data = repo_builder($_,'xbps','^\s*repository\s*=','\s*=\s*',1) if -r $_;
			@rows = (@rows,@data);
		}
	}
	# Mandriva/Mageia using: urpmq
	if ( $path = main::check_program('urpmq') ){
		@data2 = main::grabber("$path --list-media active --list-url","\n",'strip');
		main::writer("$debugger_dir/system-repo-data-urpmq.txt",@data2) if $debugger_dir;
		# now we need to create the structure: repo info: repo path
		# we do that by looping through the lines of the output and then
		# putting it back into the <data>:<url> format print repos expects to see
		# note this structure in the data, so store first line and make start of line
		# then when it's an http line, add it, and create the full line collection.
		# Contrib ftp://ftp.uwsg.indiana.edu/linux/mandrake/official/2011/x86_64/media/contrib/release
		# Contrib Updates ftp://ftp.uwsg.indiana.edu/linux/mandrake/official/2011/x86_64/media/contrib/updates
		# Non-free ftp://ftp.uwsg.indiana.edu/linux/mandrake/official/2011/x86_64/media/non-free/release
		# Non-free Updates ftp://ftp.uwsg.indiana.edu/linux/mandrake/official/2011/x86_64/media/non-free/updates
		# Nonfree Updates (Local19) /mnt/data/mirrors/mageia/distrib/cauldron/x86_64/media/nonfree/updates
		foreach (@data2){
			# need to dump leading/trailing spaces and clear out color codes for irc output
			$_ =~ s/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[m|K]//g;
			$_ =~ s/\e\[([0-9];)?[0-9]+m//g;
			# urpmq output is the same each line, repo name space repo url, can be:
			# rsync://, ftp://, file://, http:// OR repo is locally mounted on FS in some cases
			if (/(.+)\s([\S]+:\/\/.+)/){
				# pack the repo url
				push @content, $1;
				@content = url_cleaner(@content);
				# get the repo
				$repo = $2;
				@data = (
				{main::key($num++,1,1,'urpmq repo') => $repo},
				[@content],
				);
				@rows = (@rows,@data);
				@content = ();
			}
		}
	}
	# Pardus/Solus
	if ( (-d $pisi_dir && ( $path = main::check_program('pisi') ) ) || 
	        (-d $eopkg_dir && ( $path = main::check_program('eopkg') ) ) ){
		#$path = 'eopkg';
		my $which = ($path =~ /pisi$/) ? 'pisi': 'eopkg';
		my $cmd = ($which eq 'pisi') ? "$path list-repo": "$path lr";
		#my $file = "$ENV{HOME}/bin/scripts/inxi/data/repo/solus/eopkg-2.txt";
		#@data2 = main::reader($file,'strip');
		@data2 = main::grabber("$cmd 2>/dev/null","\n",'strip');
		main::writer("$debugger_dir/system-repo-data-$which.txt",@data2) if $debugger_dir;
		# now we need to create the structure: repo info: repo path
		# we do that by looping through the lines of the output and then
		# putting it back into the <data>:<url> format print repos expects to see
		# note this structure in the data, so store first line and make start of line
		# then when it's an http line, add it, and create the full line collection.
		# Pardus-2009.1 [Aktiv]
		# 	http://packages.pardus.org.tr/pardus-2009.1/pisi-index.xml.bz2
		# Contrib [Aktiv]
		# 	http://packages.pardus.org.tr/contrib-2009/pisi-index.xml.bz2
		# Solus [inactive]
		# 	https://packages.solus-project.com/shannon/eopkg-index.xml.xz
		foreach (@data2){
			next if /^\s*$/;
			# need to dump leading/trailing spaces and clear out color codes for irc output
			$_ =~ s/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[m|K]//g;
			$_ =~ s/\e\[([0-9];)?[0-9]+m//g;
			if (/^\/|:\/\//){
				push @content, $_ if $repo;
			}
			# Local [inactive] Unstable [active]
			elsif ( /^(.*)\s\[([\S]+)\]/){
				$repo = $1;
				$repo = ($2 =~ /^activ/i) ? $repo : '';
			}
			if ($repo && @content){
				@content = url_cleaner(@content);
				$key = repo_data('active',$which);
				@data = (
				{main::key($num++,1,1,$key) => $repo},
				[@content],
				);
				@rows = (@rows,@data);
				$repo = '';
				@content = ();
			}
		}
		# last one if present
		if ($repo && @content){
			@content = url_cleaner(@content);
			$key = repo_data('active',$which);
			@data = (
			{main::key($num++,1,1,$key) => $repo},
			[@content],
			);
			@rows = (@rows,@data);
		}
	}
	# print Dumper \@rows;
	eval $end if $b_log;
	return @rows;
}
sub get_repos_bsd {
	eval $start if $b_log;
	my (@content,@data,@data2,@data3,@files,@rows);
	my ($key);
	my $bsd_pkg = '/usr/local/etc/pkg/repos/';
	my $freebsd = '/etc/freebsd-update.conf';
	my $freebsd_pkg = '/etc/pkg/FreeBSD.conf';
	my $netbsd = '/usr/pkg/etc/pkgin/repositories.conf';
	my $openbsd = '/etc/pkg.conf';
	my $openbsd2 = '/etc/installurl';
	my $portsnap =  '/etc/portsnap.conf';
	if ( -f $portsnap || -f $freebsd || -d $bsd_pkg){
		if ( -f $portsnap ) {
			@data = repo_builder($portsnap,'portsnap','^\s*SERVERNAME','\s*=\s*',1);
			@rows = (@rows,@data);
		}
		if ( -f $freebsd ){
			@data = repo_builder($freebsd,'freebsd','^\s*ServerName','\s+',1);
			@rows = (@rows,@data);
		}
# 		if ( -f $freebsd_pkg ){
# 			@data = repo_builder($freebsd_pkg,'freebsd-pkg','^\s*url',':\s+',1);
# 			@rows = (@rows,@data);
# 		}
		if ( -d $bsd_pkg || -f $freebsd_pkg){
			@files = main::globber('/usr/local/etc/pkg/repos/*.conf');
			push @files, $freebsd_pkg if -f $freebsd_pkg;
			if (@files){
				my ($url);
				foreach (@files){
					push @dbg_files, $_ if $debugger_dir;
					# these will be result sets separated by an empty line
					# first dump all lines that start with #
					@content =  main::reader($_,'strip');
					# then do some clean up on the lines
					@content = map { $_ =~ s/{|}|,|\*//g; $_; } @content if @content;
					# get all rows not starting with a # and starting with a non space character
					my $url = '';
					foreach my $line (@content){
						if ($line !~ /^\s*$/){
							my @data2 = split /\s*:\s*/, $line;
							@data2 = map { $_ =~ s/^\s+|\s+$//g; $_; } @data2;
							if ($data2[0] eq 'url'){
								$url = "$data2[1]:$data2[2]";
								$url =~ s/"|,//g;
							}
							#print "url:$url\n" if $url;
							if ($data2[0] eq 'enabled'){
								if ($url && $data2[1] eq 'yes'){
									push @data3, "$url"
								}
								$url = '';
							}
						}
					}
					if (! @data3){
						$key = repo_data('missing','bsd-package');
					}
					else {
						@data3 = url_cleaner(@data3);
						$key = repo_data('active','bsd-package');
					}
					@data = (
					{main::key($num++,1,1,$key) => $_},
					[@data3],
					);
					@rows = (@rows,@data);
					@data3 = ();
				}
			}
		}
	}
	elsif (-f $openbsd || -f $openbsd2) {
		if (-f $openbsd){
			@data = repo_builder($openbsd,'openbsd','^installpath','\s*=\s*',1);
			@rows = (@rows,@data);
		}
		if (-f $openbsd2){
			@data = repo_builder($openbsd2,'openbsd','^(http|ftp)','',1);
			@rows = (@rows,@data);
		}
	}
	elsif (-f $netbsd){
		# not an empty row, and not a row starting with #
		@data = repo_builder($netbsd,'netbsd','^\s*[^#]+$');
		@rows = (@rows,@data);
	}
	# BSDs do not default always to having repo files, so show correct error 
	# mesage in that case
	if (!@rows){
		if ($bsd_type eq 'freebsd'){
			$key = repo_data('missing','freebsd-files');
		}
		elsif ($bsd_type eq 'openbsd'){
			$key = repo_data('missing','openbsd-files');
		}
		elsif ($bsd_type eq 'netbsd'){
			$key = repo_data('missing','netbsd-files');
		}
		else {
			$key = repo_data('missing','bsd-files');
		}
		@data = (
		{main::key($num++,0,1,'Message') => $key},
		[()],
		);
		@rows = (@rows,@data);
	}
	eval $start if $b_log;
	return @rows;
}
sub repo_data {
	eval $start if $b_log;
	my ($status,$type) = @_;
	my %keys = (
	'apk-active' => 'APK repo',
	'apk-missing' => 'No active APK repos in',
	'apt-active' => 'Active apt repos in',
	'apt-missing' => 'No active apt repos in',
	'bsd-files-missing' => 'No BSD pkg server files found',
	'bsd-package-active' => 'BSD enabled pkg servers in',
	'bsd-package-missing' => 'No enabled BSD pkg servers in',
	'cards-active' => 'Active CARDS collections in',
	'cards-missing' => 'No active CARDS collections in',
	'eopkg-active' => 'Active eopkg repo',
	'eopkg-missing' => 'No active eopkg repos found',
	'files-missing' => 'No repo files found in',
	'freebsd-active' => 'FreeBSD update server',
	'freebsd-files-missing' => 'No FreeBSD update server files found',
	'freebsd-missing' => 'No FreeBSD update servers in',
	'freebsd-pkg-active' => 'FreeBSD default pkg server',
	'freebsd-pkg-missing' => 'No FreeBSD default pkg server in',
	'netbsd-active' => 'NetBSD pkg servers',
	'netbsd-files-missing' => 'No NetBSD pkg server files found',
	'netbsd-missing' => 'No NetBSD pkg servers in',
	'openbsd-active' => 'OpenBSD pkg mirror',
	'openbsd-files-missing' => 'No OpenBSD pkg mirror files found',
	'openbsd-missing' => 'No OpenBSD pkg mirrors in',
	'pacman-active' => 'Active pacman repo servers in',
	'pacman-missing' => 'No active pacman repos in',
	'pacman-g2-active' => 'Active pacman-g2 repo servers in',
	'pacman-g2-missing' => 'No active pacman-g2 repos in',
	'pisi-active' => 'Active pisi repo',
	'pisi-missing' => 'No active pisi repos found',
	'portage-active' => 'Enabled portage sources in',
	'portage-missing' => 'No enabled portage sources in',
	'portsnap-active' => 'BSD ports server',
	'portsnap-missing' => 'No ports servers in',
	'slackpkg-active' => 'slackpkg repos in',
	'slackpkg-missing' => 'No active slackpkg repos in',
	'slackpkg+-active' => 'slackpkg+ repos in',
	'slackpkg+-missing' => 'No active slackpkg+ repos in',
	'slaptget-active' => 'slapt-get repos in',
	'slaptget-missing' => 'No active slapt-get repos in',
	'tce-active' => 'tce mirrors in',
	'tce-missing' => 'No tce mirrors in',
	'xbps-active' => 'Active xbps repos in',
	'xbps-missing' => 'No active xbps repos in',
	'yum-active' => 'Active yum repos in',
	'yum-missing' => 'No active yum repos in',
	'zypp-active' => 'Active zypp repos in',
	'zypp-missing' => 'No active zypp repos in',
	);
	eval $end if $b_log;
	return $keys{$type . '-' . $status};
}
sub repo_builder {
	eval $start if $b_log;
	my ($file,$type,$search,$split,$count) = @_;
	my (@content,@data,$key);
	push @dbg_files, $file if $debugger_dir;
	if (-r $file){
		@content =  main::reader($file);
		@content = grep {/$search/i && !/^\s*$/} @content if @content;
		@content = data_cleaner(@content) if @content;
	}
	if ($split && @content){
		@content = map { 
		my @inner = split (/$split/, $_);
		$inner[$count];
		} @content;
	}
	if (!@content){
		$key = repo_data('missing',$type);
	}
	else {
		$key = repo_data('active',$type);
		@content = url_cleaner(@content);
	}
	@data = (
	{main::key($num++,1,1,$key) => $file},
	[@content],
	);
	eval $end if $b_log;
	return @data;
}
sub data_cleaner {
	my (@content) = @_;
	# basics: trim white space, get rid of double spaces
	@content = map { $_ =~ s/^\s+|\s+$//g; $_ =~ s/\s\s+/ /g; $_} @content;
	return @content;
}
# clean if irc
sub url_cleaner {
	my (@content) = @_;
	@content = map { $_ =~ s/:\//: \//; $_} @content if $b_irc;
	return @content;
}
sub file_path {
	my ($filename,$dir) = @_;
	my ($working);
	$working = $filename;
	$working =~ s/^\///;
	$working =~ s/\//-/g;
	$working = "$dir/file-repo-$working.txt";
	return $working;
}
}

## SensorData
{
package SensorData;
my ($b_ipmi) = (0);
sub get {
	eval $start if $b_log;
	my ($key1,$program,$val1,@data,@rows,%sensors);
	my $num = 0;
	my $source = 'sensors';
	# we're allowing 1 or 2 ipmi tools, first the gnu one, then the 
	# almost certain to be present in BSDs
	if ( $b_ipmi || 
	    ( main::globber('/dev/ipmi**') && 
	    ( ( $program = main::check_program('ipmi-sensors') ) ||
	    ( $program = main::check_program('ipmitool') ) ) ) ){
		if ($b_ipmi || $b_root){
			%sensors = ipmi_data($program);
			@data = create_output('ipmi',%sensors);
			if (!@data) {
				$key1 = 'Message';
				$val1 = main::row_defaults('sensors-data-ipmi');
				#$val1 = main::row_defaults('dev');
				@data = ({main::key($num++,0,1,$key1) => $val1,});
			}
			@rows = (@rows,@data);
			$source = 'lm-sensors'; # trips per sensor type output
		}
		else {
			$key1 = 'Permissions';
			$val1 = main::row_defaults('sensors-ipmi-root');
			@data = ({main::key($num++,0,1,$key1) => $val1,});
			@rows = (@rows,@data);
		}
	}
	my $ref = $alerts{'sensors'};
	if ( $$ref{'action'} ne 'use'){
		#print "here 1\n";
		$key1 = $$ref{'action'};
		$val1 = $$ref{$key1};
		$key1 = ucfirst($key1);
		@data = ({main::key($num++,0,1,$key1) => $val1,});
		@rows = (@rows,@data);
	}
	else {
		%sensors = lm_sensors_data();
		@data = create_output($source,%sensors);
		#print "here 2\n";
		if (!@data) {
			$key1 = 'Message';
			$val1 = main::row_defaults('sensors-data-linux');
			@data = ({main::key($num++,0,1,$key1) => $val1,});
		}
		@rows = (@rows,@data);
	}
	eval $end if $b_log;
	return @rows;
}
sub create_output {
	eval $start if $b_log;
	my ($source,%sensors) = @_;
	# note: might revisit this, since gpu sensors data might be present
	return if ! %sensors;
	my (@gpu,@data,@rows,@fan_default,@fan_main);
	my ($data_source) = ('');
	my $fan_number = 0;
	my $num = 0;
	my $j = 0;
	@gpu = gpu_data() if ( $source eq 'sensors' || $source eq 'lm-sensors' );
	my $temp_unit  = (defined $sensors{'temp-unit'}) ? " $sensors{'temp-unit'}": '';
	my $cpu_temp = (defined $sensors{'cpu-temp'}) ? $sensors{'cpu-temp'} . $temp_unit: 'N/A';
	my $mobo_temp = (defined $sensors{'mobo-temp'}) ? $sensors{'mobo-temp'} . $temp_unit: 'N/A';
	my $cpu1_key = ($sensors{'cpu2-temp'}) ? 'cpu-1': 'cpu' ;
	$data_source = $source if ($source eq 'ipmi' || $source eq 'lm-sensors');
	@data = ({
	main::key($num++,1,1,'System Temperatures') => $data_source,
	main::key($num++,0,2,$cpu1_key) => $cpu_temp,
	});
	@rows = (@rows,@data);
	if ($sensors{'cpu2-temp'}){
		$rows[$j]{main::key($num++,0,2,'cpu-2')} = $sensors{'cpu2-temp'} . $temp_unit;
	}
	if ($sensors{'cpu3-temp'}){
		$rows[$j]{main::key($num++,0,2,'cpu-3')} = $sensors{'cpu3-temp'} . $temp_unit;
	}
	if ($sensors{'cpu4-temp'}){
		$rows[$j]{main::key($num++,0,2,'cpu-4')} = $sensors{'cpu4-temp'} . $temp_unit;
	}
	$rows[$j]{main::key($num++,0,2,'mobo')} = $mobo_temp;
	if (defined $sensors{'sodimm-temp'}){
		my $sodimm_temp = $sensors{'sodimm-temp'} . $temp_unit;
		$rows[$j]{main::key($num++,0,2,'sodimm')} = $sodimm_temp;
	}
	if (defined $sensors{'psu-temp'}){
		my $psu_temp = $sensors{'psu-temp'} . $temp_unit;
		$rows[$j]{main::key($num++,0,2,'psu')} = $psu_temp;
	}
	if (defined $sensors{'ambient-temp'}){
		my $ambient_temp = $sensors{'ambient-temp'} . $temp_unit;
		$rows[$j]{main::key($num++,0,2,'ambient')} = $ambient_temp;
	}
	if (scalar @gpu == 1 && defined $gpu[0]{'temp'}){
		my $gpu_temp = $gpu[0]{'temp'};
		my $gpu_type = $gpu[0]{'type'};
		my $gpu_unit = (defined $gpu[0]{'temp-unit'} && $gpu_temp ) ? " $gpu[0]{'temp-unit'}" : ' C';
		$rows[$j]{main::key($num++,1,2,'gpu')} = $gpu_type;
		$rows[$j]{main::key($num++,0,3,'temp')} = $gpu_temp . $gpu_unit;
		if ($extra > 1 && $gpu[0]{'temp-mem'}){
			$rows[$j]{main::key($num++,0,3,'mem')} = $gpu[0]{'temp-mem'} . $gpu_unit;
		}
	}
	$j = scalar @rows;
	my $ref_main = $sensors{'fan-main'};
	my $ref_default = $sensors{'fan-default'};
	@fan_main = @$ref_main if @$ref_main;
	@fan_default = @$ref_default if @$ref_default;
	my $fan_def = ($data_source) ? $data_source : '';
	if (!@fan_main && !@fan_default){
		$fan_def = ($fan_def) ? "$data_source N/A" : 'N/A';
	}
	$rows[$j]{main::key($num++,1,1,'Fan Speeds (RPM)')} = $fan_def;
	my $b_cpu = 0;
	for (my $i = 0; $i < scalar @fan_main; $i++){
		next if $i == 0;# starts at 1, not 0
		if (defined $fan_main[$i]){
			if ($i == 1 || ($i == 2 && !$b_cpu )){
				$rows[$j]{main::key($num++,0,2,'cpu')} = $fan_main[$i];
				$b_cpu = 1;
			}
			elsif ($i == 2 && $b_cpu){
				$rows[$j]{main::key($num++,0,2,'mobo')} = $fan_main[$i];
			}
			elsif ($i == 3){
				$rows[$j]{main::key($num++,0,2,'psu')} = $fan_main[$i];
			}
			elsif ($i == 4){
				$rows[$j]{main::key($num++,0,2,'sodimm')} = $fan_main[$i];
			}
			elsif ($i > 4){
				$fan_number = $i - 4;
				$rows[$j]{main::key($num++,0,2,"case-$fan_number")} = $fan_main[$i];
			}
		}
	}
	for (my $i = 0; $i < scalar @fan_default; $i++){
		next if $i == 0;# starts at 1, not 0
		if (defined $fan_default[$i]){
			$rows[$j]{main::key($num++,0,2,"fan-$i")} = $fan_default[$i];
		}
	}
	$rows[$j]{main::key($num++,0,2,'psu')} = $sensors{'fan-psu'} if defined $sensors{'fan-psu'};
	$rows[$j]{main::key($num++,0,2,'psu-1')} = $sensors{'fan-psu1'} if defined $sensors{'fan-psu1'};
	$rows[$j]{main::key($num++,0,2,'psu-2')} = $sensors{'fan-psu2'} if defined $sensors{'fan-psu2'};
	# note: so far, only nvidia-settings returns speed, and that's in percent
	if (scalar @gpu == 1 && defined $gpu[0]{'fan-speed'}){
		my $gpu_fan = $gpu[0]{'fan-speed'} . $gpu[0]{'speed-unit'};
		my $gpu_type = $gpu[0]{'type'};
		$rows[$j]{main::key($num++,1,2,'gpu')} = $gpu_type;
		$rows[$j]{main::key($num++,0,3,'fan')} = $gpu_fan;
	}
	if (scalar @gpu > 1){
		$j = scalar @rows;
		$rows[$j]{main::key($num++,1,1,'GPU')} = '';
		my $gpu_unit = (defined $gpu[0]{'temp-unit'} ) ? " $gpu[0]{'temp-unit'}" : ' C';
		foreach my $ref (@gpu){
			my %info = %$ref;
			# speed unit is either '' or %
			my $gpu_fan = (defined $info{'fan-speed'}) ? $info{'fan-speed'} . $info{'speed-unit'}: undef ;
			my $gpu_type = $info{'type'};
			my $gpu_temp = (defined $info{'temp'} ) ? $info{'temp'} . $gpu_unit: 'N/A';
			$rows[$j]{main::key($num++,1,2,'device')} = $gpu_type;
			if (defined $info{'screen'} ){
				$rows[$j]{main::key($num++,0,3,'screen')} = $info{'screen'};
			}
			$rows[$j]{main::key($num++,0,3,'temp')} = $gpu_temp;
			if ($extra > 1 && $info{'temp-mem'}){
				$rows[$j]{main::key($num++,0,3,'mem')} = $info{'temp-mem'} . $gpu_unit;
			}
			if (defined $gpu_fan){
				$rows[$j]{main::key($num++,0,3,'fan')} = $gpu_fan;
			}
			if ($extra > 2 && $info{'watts'}){
				$rows[$j]{main::key($num++,0,3,'watts')} = $info{'watts'};
			}
			if ($extra > 2 && $info{'mvolts'}){
				$rows[$j]{main::key($num++,0,3,'mV')} = $info{'mvolts'};
			}
		}
	}
	if ($extra > 0 && ($source eq 'ipmi' || 
	   ($sensors{'volts-12'} || $sensors{'volts-5'} || $sensors{'volts-3.3'} || $sensors{'volts-vbat'}))){
		$j = scalar @rows;
		$sensors{'volts-12'} ||= 'N/A';
		$sensors{'volts-5'} ||= 'N/A';
		$sensors{'volts-3.3'} ||= 'N/A';
		$sensors{'volts-vbat'} ||= 'N/A';
		$rows[$j]{main::key($num++,1,1,'Power')} = $data_source;
		$rows[$j]{main::key($num++,0,2,'12v')} = $sensors{'volts-12'};
		$rows[$j]{main::key($num++,0,2,'5v')} = $sensors{'volts-5'};
		$rows[$j]{main::key($num++,0,2,'3.3v')} = $sensors{'volts-3.3'};
		$rows[$j]{main::key($num++,0,2,'vbat')} = $sensors{'volts-vbat'};
		if ($extra > 1 && $source eq 'ipmi' ){
			$sensors{'volts-dimm-p1'} ||= 'N/A';
			$sensors{'volts-dimm-p2'} ||= 'N/A';
			$rows[$j]{main::key($num++,0,2,'dimm-p1')} = $sensors{'volts-dimm-p1'} if $sensors{'volts-dimm-p1'};
			$rows[$j]{main::key($num++,0,2,'dimm-p2')} = $sensors{'volts-dimm-p2'} if $sensors{'volts-dimm-p2'};
			$rows[$j]{main::key($num++,0,2,'soc-p1')} = $sensors{'volts-soc-p1'} if $sensors{'volts-soc-p1'};
			$rows[$j]{main::key($num++,0,2,'soc-p2')} = $sensors{'volts-soc-p2'} if $sensors{'volts-soc-p2'};
		}
		if (scalar @gpu == 1 && $extra > 2 && ($gpu[0]{'watts'} || $gpu[0]{'mvolts'})){
			$rows[$j]{main::key($num++,1,2,'gpu')} = $gpu[0]{'type'};
			$rows[$j]{main::key($num++,0,3,'watts')} = $gpu[0]{'watts'} if $gpu[0]{'watts'}  ;
			$rows[$j]{main::key($num++,0,3,'mV')} = $gpu[0]{'mvolts'} if $gpu[0]{'mvolts'};
		}
	}
	eval $end if $b_log;
	return @rows;
}
sub ipmi_data {
	eval $start if $b_log;
	my ($program) = @_;
	my ($b_cpu_0,$cmd,$file,@data,$fan_working,%sensors,@row,$sys_fan_nu,
	$temp_working,$working_unit);
	$program ||= 'ipmi-sensors'; # only for debugging, will always exist if reaches here
	my ($b_ipmitool,$i_key,$i_value,$i_unit);
	#$file = "$ENV{'HOME'}/bin/scripts/inxi/data/ipmitool/ipmitool-sensors-archerseven-1.txt";$program='ipmitool';
	#$file = "$ENV{'HOME'}/bin/scripts/inxi/data/ipmitool/ipmitool-sensors-crazy-epyc-1.txt";$program='ipmitool';
	#$file = "$ENV{'HOME'}/bin/scripts/inxi/data/ipmitool/ipmitool-sensors-RK016013.txt";$program='ipmitool';
	#$file = "$ENV{'HOME'}/bin/scripts/inxi/data/ipmitool/ipmi-sensors-crazy-epyc-1.txt";
	#$file = "$ENV{'HOME'}/bin/scripts/inxi/data/ipmitool/ipmi-sensors-lathander.txt";
	#$file = "$ENV{'HOME'}/bin/scripts/inxi/data/ipmitool/ipmi-sensors-zwerg.txt";
	#@data = main::reader($file);
	if ($program =~ /ipmi-sensors$/){
		$cmd = $program;
		($b_ipmitool,$i_key,$i_value,$i_unit) = (0,1,3,4);
	}
	else {
		$cmd = "$program sensors";
		($b_ipmitool,$i_key,$i_value,$i_unit) = (1,0,1,2);
	}
	@data = main::grabber("$cmd 2>/dev/null");
	# print join ("\n", @data), "\n";
	return if ! @data;
	foreach (@data){
		next if /^\s*$/;
		# print "$_\n";
		@row = split /\s*\|\s*/, $_;
		#print "$row[$i_value]\n";
		next if !main::is_numeric($row[$i_value]);
		# print "$row[$i_key] - $row[$i_value]\n";
		if (!$sensors{'mobo-temp'} && $row[$i_key] =~ /^(MB_TEMP[0-9]|System[\s_]Temp|System[\s_]?Board)$/i){
			$sensors{'mobo-temp'} = int($row[$i_value]);
			$working_unit = $row[$i_unit];
			$working_unit =~ s/degrees\s// if $b_ipmitool; 
			$sensors{'temp-unit'} = set_temp_unit($sensors{'temp-unit'},$working_unit) if $working_unit;
		}
		elsif ($row[$i_key] =~ /^(Ambient)$/i){
			$sensors{'ambient-temp'} = int($row[$i_value]);
			$working_unit = $row[$i_unit];
			$working_unit =~ s/degrees\s// if $b_ipmitool; 
			$sensors{'temp-unit'} = set_temp_unit($sensors{'temp-unit'},$working_unit) if $working_unit;
		}
		# Platform Control Hub (PCH), it is the X370 chip on the Crosshair VI Hero.
		# VRM: voltage regulator module
		# NOTE: CPU0_TEMP CPU1_TEMP is possible, unfortunately; CPU Temp Interf 
		elsif ( !$sensors{'cpu-temp'} && $row[$i_key] =~ /^CPU([01])?([\s_]Temp)?$/i) {
			$b_cpu_0 = 1 if defined $1 && $1 == 0;
			$sensors{'cpu-temp'} = int($row[$i_value]);
			$working_unit = $row[$i_unit];
			$working_unit =~ s/degrees\s// if $b_ipmitool; 
			$sensors{'temp-unit'} = set_temp_unit($sensors{'temp-unit'},$working_unit) if $working_unit;
		}
		elsif ($row[$i_key] =~ /^CPU([1-4])([\s_]Temp)?$/i) {
			$temp_working = $1;
			$temp_working++ if $b_cpu_0;
			$sensors{"cpu${temp_working}-temp"} = int($row[$i_value]);
			$working_unit = $row[$i_unit];
			$working_unit =~ s/degrees\s// if $b_ipmitool; 
			$sensors{'temp-unit'} = set_temp_unit($sensors{'temp-unit'},$working_unit) if $working_unit;
		}
		# for temp1/2 only use temp1/2 if they are null or greater than the last ones
		elsif ($row[$i_key] =~ /^(MB[_]?TEMP1|Temp[\s_]1)$/i) {
			$temp_working = int($row[$i_value]);
			$working_unit = $row[$i_unit];
			$working_unit =~ s/degrees\s// if $b_ipmitool; 
			if ( !$sensors{'temp1'} || ( defined $temp_working && $temp_working > 0 ) ) {
				$sensors{'temp1'} = $temp_working;
			}
			$sensors{'temp-unit'} = set_temp_unit($sensors{'temp-unit'},$working_unit) if $working_unit;
		}
		elsif ($row[$i_key] =~ /^(MB[_]?TEMP2|Temp[\s_]2)$/i) {
			$temp_working = int($row[$i_value]);
			$working_unit = $row[$i_unit];
			$working_unit =~ s/degrees\s// if $b_ipmitool; 
			if ( !$sensors{'temp2'} || ( defined $temp_working && $temp_working > 0 ) ) {
				$sensors{'temp2'} = $temp_working;
			}
			$sensors{'temp-unit'} = set_temp_unit($sensors{'temp-unit'},$working_unit) if $working_unit;
		}
		# temp3 is only used as an absolute override for systems with all 3 present
		elsif ($row[$i_key] =~ /^(MB[_]?TEMP3|Temp[\s_]3)$/i) {
			$temp_working = int($row[$i_value]);
			$working_unit = $row[$i_unit];
			$working_unit =~ s/degrees\s// if $b_ipmitool; 
			if ( !$sensors{'temp3'} || ( defined $temp_working && $temp_working > 0 ) ) {
				$sensors{'temp3'} = $temp_working;
			}
			$sensors{'temp-unit'} = set_temp_unit($sensors{'temp-unit'},$working_unit) if $working_unit;
		}
		elsif (!$sensors{'sodimm-temp'} && $row[$i_key] =~ /^(DIMM[-_]([A-Z][0-9][-_])?[A-Z]?[0-9][A-Z]?)$/i){
			$sensors{'sodimm-temp'} = int($row[$i_value]);
			$working_unit = $row[$i_unit];
			$working_unit =~ s/degrees\s// if $b_ipmitool; 
			$sensors{'temp-unit'} = set_temp_unit($sensors{'temp-unit'},$working_unit) if $working_unit;
		}
		# note: can be cpu fan:, cpu fan speed:, etc.
		elsif ($row[$i_key] =~ /^(CPU|Processor)[\s_]Fan/i) {
			$sensors{'fan-main'} = () if !$sensors{'fan-main'};
			$sensors{'fan-main'}[1] = int($row[$i_value]);
		}
		# note that the counters are dynamically set for fan numbers here
		# otherwise you could overwrite eg aux fan2 with case fan2 in theory
		# note: cpu/mobo/ps are 1/2/3
		elsif ($row[$i_key] =~ /^(SYS[\s_])?FAN[\s_]?([0-9A-F]+)/i) {
			$sys_fan_nu = hex($2);
			$fan_working = int($row[$i_value]);
			$sensors{'fan-default'} = () if !$sensors{'fan-default'};
			if ( $sys_fan_nu =~ /^([0-9]+)$/ ) {
				# add to array if array index does not exist OR if number is > existing number
				if ( defined $sensors{'fan-default'}[$sys_fan_nu] ) {
					if ( $fan_working >= $sensors{'fan-default'}[$sys_fan_nu] ) {
						$sensors{'fan-default'}[$sys_fan_nu] = $fan_working;
					}
				}
				else {
					$sensors{'fan-default'}[$sys_fan_nu] = $fan_working;
				}
			}
		}
		elsif ($row[$i_key] =~ /^(FAN PSU|PSU FAN)$/i) {
			$sensors{'fan-psu'} = int($row[$i_value]);
		}
		elsif ($row[$i_key] =~ /^(FAN PSU1|PSU1 FAN)$/i) {
			$sensors{'fan-psu-1'} = int($row[$i_value]);
		}
		elsif ($row[$i_key] =~ /^(FAN PSU2|PSU2 FAN)$/i) {
			$sensors{'fan-psu-2'} = int($row[$i_value]);
		}
		if ($extra > 0){
			if ($row[$i_key] =~ /^(MAIN\s|P[_]?)?12V$/i) {
				$sensors{'volts-12'} = $row[$i_value];
			}
			elsif ($row[$i_key] =~ /^(MAIN\s5V|P5V|5VCC|5V PG)$/i) {
				$sensors{'volts-5'} = $row[$i_value];
			}
			elsif ($row[$i_key] =~ /^(MAIN\s3.3V|P3V3|3.3VCC|3.3V PG)$/i) {
				$sensors{'volts-3.3'} = $row[$i_value];
			}
			elsif ($row[$i_key] =~ /^((P_)?VBAT|CMOS Battery|BATT 3.0V)$/i) {
				$sensors{'volts-vbat'} = $row[$i_value];
			}
			# NOTE: VDimmP1ABC VDimmP1DEF
			elsif (!$sensors{'volts-dimm-p1'} && $row[$i_key] =~ /^(P1_VMEM|VDimmP1|MEM RSR A PG)/i) {
				$sensors{'volts-dimm-p1'} = $row[$i_value];
			}
			elsif (! $sensors{'volts-dimm-p2'} && $row[$i_key] =~ /^(P2_VMEM|VDimmP2|MEM RSR B PG)/i) {
				$sensors{'volts-dimm-p2'} = $row[$i_value];
			}
			elsif (!$sensors{'volts-soc-p1'} && $row[$i_key] =~ /^(P1_SOC_RUN$)/i) {
				$sensors{'volts-soc-p1'} = $row[$i_value];
			}
			elsif (! $sensors{'volts-soc-p2'} && $row[$i_key] =~ /^(P2_SOC_RUN$)/i) {
				$sensors{'volts-soc-p2'} = $row[$i_value];
			}
		}
	}
	# print Data::Dumper::Dumper \%sensors;
	%sensors = data_processor(%sensors) if %sensors;
	main::log_data('dump','ipmi: %sensors',\%sensors) if $b_log;
	eval $end if $b_log;
	# print Data::Dumper::Dumper \%sensors;
	return %sensors;
}
sub lm_sensors_data {
	eval $start if $b_log;
	my (%sensors);
	my ($sys_fan_nu)  = (0);
	my ($adapter,$fan_working,$temp_working,$working_unit)  = ('','','','','');
	lm_sensors_processor() if !$b_sensors;
	foreach $adapter (keys %{$sensors_raw{'main'}}){
		next if !$adapter || ref $sensors_raw{'main'}->{$adapter} ne 'ARRAY';
		# not sure why hwmon is excluded, forgot to add info in comments
		if ((@sensors_use && !(grep {/$adapter/} @sensors_use)) ||
		 (@sensors_exclude && (grep {/$adapter/} @sensors_exclude))){
			next;
		}
		foreach (@{$sensors_raw{'main'}->{$adapter}}){
			my @working = split /:/, $_;
			next if !$working[0];
			#print "$working[0]:$working[1]\n";
			# There are some guesses here, but with more sensors samples it will get closer.
			# note: using arrays starting at 1 for all fan arrays to make it easier overall
			# we have to be sure we are working with the actual real string before assigning
			# data to real variables and arrays. Extracting C/F degree unit as well to use
			# when constructing temp items for array. 
			# note that because of charset issues, no "°" degree sign used, but it is required 
			# in testing regex to avoid error. It might be because I got that data from a forum post,
			# note directly via debugger.
			if ($_ =~ /^(AMBIENT|M\/B|MB|Motherboard|SIO|SYS).*:([0-9\.]+)[\s°]*(C|F)/i) {
				# avoid SYSTIN: 118 C
				if (main::is_numeric($2) && $2 < 90 ){
					$sensors{'mobo-temp'} = $2;
					$working_unit = $3;
					$sensors{'temp-unit'} = set_temp_unit($sensors{'temp-unit'},$working_unit) if $working_unit;
				}
			}
			# issue 58 msi/asus show wrong for CPUTIN so overwrite it if PECI 0 is present
			# http://www.spinics.net/lists/lm-sensors/msg37308.html
			# NOTE: had: ^CPU.*\+([0-9]+): but that misses: CPUTIN and anything not with + in starter
			# However, "CPUTIN is not a reliable measurement because it measures difference to Tjmax,
			# which is the maximum CPU temperature reported as critical temperature by coretemp"
			# NOTE: I've seen an inexplicable case where: CPU:52.0°C fails to match with [\s°] but 
			# does match with: [\s°]*. I can't account for this, but that's why the * is there
			# Tdie is a new k10temp-pci syntax for cpu die temp
			elsif ($_ =~ /^(CPU.*|Tdie.*):([0-9\.]+)[\s°]*(C|F)/i) {
				$temp_working = $2;
				$working_unit = $3;
				if ( !$sensors{'cpu-temp'} || 
					( defined $temp_working && $temp_working > 0 && $temp_working > $sensors{'cpu-temp'} ) ) {
					$sensors{'cpu-temp'} = $temp_working;
				}
				$sensors{'temp-unit'} = set_temp_unit($sensors{'temp-unit'},$working_unit) if $working_unit;
			}
			elsif ($_ =~ /^PECI\sAgent\s0.*:([0-9\.]+)[\s°]*(C|F)/i) {
				$sensors{'cpu-peci-temp'} = $1;
				$working_unit = $2;
				$sensors{'temp-unit'} = set_temp_unit($sensors{'temp-unit'},$working_unit) if $working_unit;
			}
			elsif ($_ =~ /^(P\/S|Power).*:([0-9\.]+)[\s°]*(C|F)/i) {
				$sensors{'psu-temp'} = $2;
				$working_unit = $3;
				$sensors{'temp-unit'} = set_temp_unit($sensors{'temp-unit'},$working_unit) if $working_unit;
			}
			elsif ($_ =~ /^SODIMM.*:([0-9\.]+)[\s°]*(C|F)/i) {
				$sensors{'sodimm-temp'} = $1;
				$working_unit = $2;
				$sensors{'temp-unit'} = set_temp_unit($sensors{'temp-unit'},$working_unit) if $working_unit;
			}
			# for temp1/2 only use temp1/2 if they are null or greater than the last ones
			elsif ($_ =~ /^temp1:([0-9\.]+)[\s°]*(C|F)/i) {
				$temp_working = $1;
				$working_unit = $2;
				if ( !$sensors{'temp1'} || 
					( defined $temp_working && $temp_working > 0 && $temp_working > $sensors{'temp1'} ) ) {
					$sensors{'temp1'} = $temp_working;
				}
				$sensors{'temp-unit'} = set_temp_unit($sensors{'temp-unit'},$working_unit) if $working_unit;
			}
			elsif ($_ =~ /^temp2:([0-9\.]+)[\s°]*(C|F)/i) {
				$temp_working = $1;
				$working_unit = $2;
				if ( !$sensors{'temp2'} || 
					( defined $temp_working && $temp_working > 0 && $temp_working > $sensors{'temp2'} ) ) {
					$sensors{'temp2'} = $temp_working;
				}
				$sensors{'temp-unit'} = set_temp_unit($sensors{'temp-unit'},$working_unit) if $working_unit;
			}
			# temp3 is only used as an absolute override for systems with all 3 present
			elsif ($_ =~ /^temp3:([0-9\.]+)[\s°]*(C|F)/i) {
				$temp_working = $1;
				$working_unit = $2;
				if ( !$sensors{'temp3'} || 
					( defined $temp_working && $temp_working > 0 && $temp_working > $sensors{'temp3'} ) ) {
					$sensors{'temp3'} = $temp_working;
				}
				$sensors{'temp-unit'} = set_temp_unit($sensors{'temp-unit'},$working_unit) if $working_unit;
			}
			# final fallback if all else fails, funtoo user showed sensors putting
			# temp on wrapped second line, not handled
			elsif ($_ =~ /^(core0|core 0|Physical id 0)(.*):([0-9\.]+)[\s°]*(C|F)/i) {
				$temp_working = $3;
				$working_unit = $4;
				if ( !$sensors{'core-0-temp'} || 
					( defined $temp_working && $temp_working > 0 && $temp_working > $sensors{'core-0-temp'} ) ) {
					$sensors{'core-0-temp'} = $temp_working;
				}
				$sensors{'temp-unit'} = set_temp_unit($sensors{'temp-unit'},$working_unit) if $working_unit;
			}
			# note: can be cpu fan:, cpu fan speed:, etc.
			elsif (!$sensors{'fan-main'}[1] && $_ =~ /^(CPU|Processor).*:([0-9]+)[\s]RPM/i) {
				$sensors{'fan-main'} = () if !$sensors{'fan-main'};
				$sensors{'fan-main'}[1] = $2;
			}
			elsif (!$sensors{'fan-main'}[2] && $_ =~ /^(M\/B|MB|SYS|Motherboard).*:([0-9]+)[\s]RPM/i) {
				$sensors{'fan-main'} = () if !$sensors{'fan-main'};
				$sensors{'fan-main'}[2] = $2;
			}
			elsif (!$sensors{'fan-main'}[3] && $_ =~ /(Power|P\/S|POWER).*:([0-9]+)[\s]RPM/i) {
				$sensors{'fan-main'} = () if !$sensors{'fan-main'};
				$sensors{'fan-main'}[3] = $2;
			}
			elsif (!$sensors{'fan-main'}[4] && $_ =~ /(SODIMM).*:([0-9]+)[\s]RPM/i) {
				$sensors{'fan-main'} = () if !$sensors{'fan-main'};
				$sensors{'fan-main'}[4] = $2;
			}
			# note that the counters are dynamically set for fan numbers here
			# otherwise you could overwrite eg aux fan2 with case fan2 in theory
			# note: cpu/mobo/ps/sodimm are 1/2/3/4
			elsif ($_ =~ /^(AUX|CASE|CHASSIS).*:([0-9]+)[\s]RPM/i) {
				$temp_working = $2;
				$sensors{'fan-main'} = () if !$sensors{'fan-main'};
				for ( my $i = 5; $i < 30; $i++ ){
					next if defined $sensors{'fan-main'}[$i];
					if ( !defined $sensors{'fan-main'}[$i] ){
						$sensors{'fan-main'}[$i] = $temp_working;
						last;
					}
				}
			}
			# in rare cases syntax is like: fan1: xxx RPM
			elsif ($_ =~ /^FAN(1)?:([0-9]+)[\s]RPM/i) {
				$sensors{'fan-default'} = () if !$sensors{'fan-default'};
				$sensors{'fan-default'}[1] = $2;
			}
			elsif ($_ =~ /^FAN([2-9]|1[0-9]).*:([0-9]+)[\s]RPM/i) {
				$fan_working = $2;
				$sys_fan_nu = $1;
				$sensors{'fan-default'} = () if !$sensors{'fan-default'};
				if ( $sys_fan_nu =~ /^([0-9]+)$/ ) {
					# add to array if array index does not exist OR if number is > existing number
					if ( defined $sensors{'fan-default'}[$sys_fan_nu] ) {
						if ( $fan_working >= $sensors{'fan-default'}[$sys_fan_nu] ) {
							$sensors{'fan-default'}[$sys_fan_nu] = $fan_working;
						}
					}
					else {
						$sensors{'fan-default'}[$sys_fan_nu] = $fan_working;
					}
				}
			}
			if ($extra > 0){
				if ($_ =~ /^[+]?(12 Volt|12V).*:([0-9\.]+)\sV/i) {
					$sensors{'volts-12'} = $2;
				}
				# note: 5VSB is a field name
				elsif ($_ =~ /^[+]?(5 Volt|5V):([0-9\.]+)\sV/i) {
					$sensors{'volts-5'} = $2;
				}
				elsif ($_ =~ /^[+]?(3\.3 Volt|3\.3V).*:([0-9\.]+)\sV/i) {
					$sensors{'volts-3.3'} = $2;
				}
				elsif ($_ =~ /^(Vbat).*:([0-9\.]+)\sV/i) {
					$sensors{'volts-vbat'} = $2;
				}
			}
		}
	}
	# print Data::Dumper::Dumper \%sensors;
	%sensors = data_processor(%sensors) if %sensors;
	main::log_data('dump','lm-sensors: %sensors',\%sensors) if $b_log;
	# print Data::Dumper::Dumper \%sensors;
	eval $end if $b_log;
	return %sensors;
}
sub lm_sensors_processor {
	eval $start if $b_log;
	my (@data,@sensors_data,@values);
	my ($adapter,$holder,$type) = ('','','');
	@sensors_data = main::grabber(main::check_program('sensors') . " 2>/dev/null");
	#my $file = "$ENV{'HOME'}/bin/scripts/inxi/data/sensors/amdgpu-w-fan-speed-stretch-k10.txt";
	#my $file = "$ENV{'HOME'}/bin/scripts/inxi/data/sensors/peci-tin-geggo.txt";
	#my $file = "$ENV{'HOME'}/bin/scripts/inxi/data/sensors/sensors-w-other-biker.txt";
	#my $file = "$ENV{'HOME'}/bin/scripts/inxi/data/sensors/sensors-asus-chassis-1.txt";
	#my $file = "$ENV{'HOME'}/bin/scripts/inxi/data/sensors/sensors-devnull-1.txt";
	#my $file = "$ENV{'HOME'}/bin/scripts/inxi/data/sensors/sensors-jammin1.txt";
	#my $file = "$ENV{'HOME'}/bin/scripts/inxi/data/sensors/sensors-mx-incorrect-1.txt";
	# my $file = "$ENV{'HOME'}/bin/scripts/inxi/data/sensors/sensors-maximus-arch-1.txt";
	# my $file = "$ENV{'HOME'}/bin/scripts/inxi/data/sensors/kernel-58-sensors-ant-1.txt";
	# my $file = "$ENV{'HOME'}/bin/scripts/inxi/data/sensors/sensors-zenpower-nvme-2.txt";
	# @sensors_data = main::reader($file);		# only way to get sensor array data? Unless using sensors -j, but can't assume json 
	# print join ("\n", @sensors_data), "\n";
	if (@sensors_data){
		@sensors_data = map {$_ =~ s/\s*:\s*\+?/:/;$_} @sensors_data;
		push @sensors_data, 'END';
	}
	#print Data::Dumper::Dumper \@sensors_data;
	foreach (@sensors_data){
		#print 'st:', $_, "\n";
		next if /^\s*$/;
		$_ = main::trimmer($_);
		if (@values && $adapter && (/^Adapter/ || $_ eq 'END')){
			# note: drivetemp: known, but many others could exist
			if ($adapter =~ /^(drive|nvme)/){
				$type = 'disk';
			}
			elsif ($adapter =~ /^(amdgpu|intel|nouveau|radeon)-/){
				$type = 'gpu';
			}
			# ath/iwl: wifi; enp/eno/eth: lan nic
			elsif ($adapter =~ /^(ath|iwl|en[op][0-9]|eth)[\S]+-/){
				$type = 'network';
			}
			elsif ($adapter =~ /^(.*hwmon)-/){
				$type = 'hwmon';
			}
			else {
				$type = 'main';
			}
			$sensors_raw{$type}->{$adapter} = [@values];
			@values = ();
			$adapter = '';
		}
		if (/^Adapter/){
			$adapter = $holder;
		}
		elsif (/\S:\S/){
			push @values, $_;
		}
		else {
			$holder = $_;
		}
	}
	$b_sensors = 1;
	if ($test[18]){
		print 'lm sensors: ' , Data::Dumper::Dumper \%sensors_raw;
	}
	if ($b_log){
		main::log_data('dump','lm-sensors data: %sensors_raw',\%sensors_raw);
	}
	eval $end if $b_log;
	return @data;
}

# oddly, openbsd sysctl actually has hw.sensors data!
sub sysctl_data {
	eval $start if $b_log;
	my (@data,%sensors);
	foreach (@sysctl_sensors){
		if (/^hw.sensors\.([0-9a-z]+)\.(temp|fan|volt)([0-9])/){
			my $sensor = $1;
			my $type = $2;
			my $number = $3;
			my @working = split /:/, $_;
		}
		last if /^(hw.cpuspeed|hw.vendor|hw.physmem)/;
	}
	%sensors = data_processor(%sensors) if %sensors;
	main::log_data('dump','%sensors',\%sensors) if $b_log;
	# print Data::Dumper::Dumper \%sensors;
	eval $end if $b_log;
	return %sensors;
}
sub set_temp_unit {
	my ($sensors,$working) = @_;
	my $return_unit = '';
	if ( !$sensors && $working ){
		$return_unit = $working;
	}
	elsif ($sensors){
		$return_unit = $sensors;
	}
	return $return_unit;
}

sub data_processor {
	eval $start if $b_log;
	my (%sensors) = @_;
	my ($cpu_temp,$cpu2_temp,$cpu3_temp,$cpu4_temp,$index_count_fan_default,
	$index_count_fan_main,$mobo_temp,$psu_temp) = (0,0,0,0,0,0,0,0);
	my ($fan_type,$i,$j) = (0,0,0);
	my $temp_diff = 20; # for C, handled for F after that is determined
	my (@fan_main,@fan_default);
	# first we need to handle the case where we have to determine which temp/fan to use for cpu and mobo:
	# note, for rare cases of weird cool cpus, user can override in their prefs and force the assignment
	# this is wrong for systems with > 2 tempX readings, but the logic is too complex with 3 variables
	# so have to accept that it will be wrong in some cases, particularly for motherboard temp readings.
	if ( $sensors{'temp1'} && $sensors{'temp2'} ){
		if ( $sensors_cpu_nu ) {
			$fan_type = $sensors_cpu_nu;
		}
		else {
			# first some fringe cases with cooler cpu than mobo: assume which is cpu temp based on fan speed
			# but only if other fan speed is 0.
			if ( $sensors{'temp1'} >= $sensors{'temp2'} && 
			     defined $fan_default[1] && defined $fan_default[2] && $fan_default[1] == 0 && $fan_default[2] > 0 ) {
				$fan_type = 2;
			}
			elsif ( $sensors{'temp2'} >= $sensors{'temp1'} && 
			        defined $fan_default[1] && defined $fan_default[2] && $fan_default[2] == 0 && $fan_default[1] > 0 ) {
				$fan_type = 1;
			}
			# then handle the standard case if these fringe cases are false
			elsif ( $sensors{'temp1'} >= $sensors{'temp2'} ) {
				$fan_type = 1;
			}
			else {
				$fan_type = 2;
			}
		}
	}
	# need a case for no temps at all reported, like with old intels
	elsif ( !$sensors{'temp2'} && !$sensors{'cpu-temp'} ){
		if ( !$sensors{'temp1'} && !$sensors{'mobo-temp'} ){
			$fan_type = 1;
		}
		elsif ( $sensors{'temp1'} && !$sensors{'mobo-temp'} ){
			$fan_type = 1;
		}
		elsif ( $sensors{'temp1'} && $sensors{'mobo-temp'} ){
			$fan_type = 1;
		}
	}
	# convert the diff number for F, it needs to be bigger that is
	if ( $sensors{'temp-unit'} && $sensors{'temp-unit'} eq "F" ) {
		$temp_diff = $temp_diff * 1.8
	}
	if ( $sensors{'cpu-temp'} ) {
		# specific hack to handle broken CPUTIN temps with PECI
		if ( $sensors{'cpu-peci-temp'} && ( $sensors{'cpu-temp'} - $sensors{'cpu-peci-temp'} ) > $temp_diff ){
			$cpu_temp = $sensors{'cpu-peci-temp'};
		}
		# then get the real cpu temp, best guess is hottest is real, though only within narrowed diff range
		else {
			$cpu_temp = $sensors{'cpu-temp'};
		}
	}
	else {
		if ($fan_type ){
			# there are some weird scenarios
			if ( $fan_type == 1 ){
				if ( $sensors{'temp1'} && $sensors{'temp2'} && $sensors{'temp2'} > $sensors{'temp1'} ) {
					$cpu_temp = $sensors{'temp2'};
				}
				else {
					$cpu_temp = $sensors{'temp1'};
				}
			}
			else {
				if ( $sensors{'temp1'} && $sensors{'temp2'} && $sensors{'temp1'} > $sensors{'temp2'} ) {
					$cpu_temp = $sensors{'temp1'};
				}
				else {
					$cpu_temp = $sensors{'temp2'};
				}
			}
		}
		else {
			$cpu_temp = $sensors{'temp1'}; # can be null, that is ok
		}
		if ( $cpu_temp ) {
			# using $sensors{'temp3'} is just not reliable enough, more errors caused than fixed imo
			#if ( $sensors{'temp3'} && $sensors{'temp3'} > $cpu_temp ) {
			#	$cpu_temp = $sensors{'temp3'};
			#}
			# there are some absurdly wrong $sensors{'temp1'}: acpitz-virtual-0 $sensors{'temp1'}: +13.8°C
			if ( $sensors{'core-0-temp'} && ($sensors{'core-0-temp'} - $cpu_temp) > $temp_diff ) {
				$cpu_temp = $sensors{'core-0-temp'};
			}
		}
	}
	# if all else fails, use core0/peci temp if present and cpu is null
	if ( !$cpu_temp ) {
		if ( $sensors{'core-0-temp'} ) {
			$cpu_temp = $sensors{'core-0-temp'};
		}
		# note that peci temp is known to be colder than the actual system
		# sometimes so it is the last fallback we want to use even though in theory
		# it is more accurate, but fact suggests theory wrong.
		elsif ( $sensors{'cpu-peci-temp'} ) {
			$cpu_temp = $sensors{'cpu-peci-temp'};
		}
	}
	# then the real mobo temp
	if ( $sensors{'mobo-temp'} ){
		$mobo_temp = $sensors{'mobo-temp'};
	}
	elsif ( $fan_type ){
		if ( $fan_type == 1 ) {
			if ( $sensors{'temp1'} && $sensors{'temp2'} && $sensors{'temp2'} > $sensors{'temp1'} ) {
				$mobo_temp = $sensors{'temp1'};
			}
			else {
				$mobo_temp = $sensors{'temp2'};
			}
		}
		else {
			if ( $sensors{'temp1'} && $sensors{'temp2'} && $sensors{'temp1'} > $sensors{'temp2'} ) {
				$mobo_temp = $sensors{'temp2'};
			}
			else {
				$mobo_temp = $sensors{'temp1'};
			}
		}
		## NOTE: not safe to assume $sensors{'temp3'} is the mobo temp, sad to say
		#if ( $sensors{'temp1'} && $sensors{'temp2'} && $sensors{'temp3'} && $sensors{'temp3'} < $mobo_temp ) {
		#	$mobo_temp = $sensors{'temp3'};
		#}
	}
	else {
		$mobo_temp = $sensors{'temp2'};
	}
	@fan_main = @{$sensors{'fan-main'}} if $sensors{'fan-main'};
	$index_count_fan_main = (@fan_main) ? scalar @fan_main : 0;
	@fan_default = @{$sensors{'fan-default'}} if $sensors{'fan-default'};
	$index_count_fan_default = (@fan_default) ? scalar @fan_default : 0;
	# then set the cpu fan speed
	if ( ! $fan_main[1] ) {
		# note, you cannot test for $fan_default[1] or [2] != "" 
		# because that creates an array item in gawk just by the test itself
		if ( $fan_type == 1 && defined $fan_default[1] ) {
			$fan_main[1] = $fan_default[1];
			$fan_default[1] = undef;
		}
		elsif ( $fan_type == 2 && defined $fan_default[2] ) {
			$fan_main[1] = $fan_default[2];
			$fan_default[2] = undef;
		}
	}
	# clear out any duplicates. Primary fan real trumps fan working always if same speed
	for ($i = 1; $i <= $index_count_fan_main; $i++) {
		if ( defined $fan_main[$i] && $fan_main[$i] ) {
			for ($j = 1; $j <= $index_count_fan_default; $j++) {
				if ( defined $fan_default[$j] && $fan_main[$i] == $fan_default[$j] ) {
					$fan_default[$j] = undef;
				}
			}
		}
	}
	# now see if you can find the fast little mobo fan, > 5000 rpm and put it as mobo
	# note that gawk is returning true for some test cases when $fan_default[j] < 5000
	# which has to be a gawk bug, unless there is something really weird with arrays
	# note: 500 > $fan_default[j] < 1000 is the exact trigger, and if you manually 
	# assign that value below, the > 5000 test works again, and a print of the value
	# shows the proper value, so the corruption might be internal in awk. 
	# Note: gensub is the culprit I think, assigning type string for range 501-1000 but 
	# type integer for all others, this triggers true for >
	for ($j = 1; $j <= $index_count_fan_default; $j++) {
		if ( defined $fan_default[$j] && $fan_default[$j] > 5000 && !$fan_main[2] ) {
			$fan_main[2] = $fan_default[$j];
			$fan_default[$j] = '';
			# then add one if required for output
			if ( $index_count_fan_main < 2 ) {
				$index_count_fan_main = 2;
			}
		}
	}
	# if they are ALL null, print error message. psFan is not used in output currently
	if ( !$cpu_temp && !$mobo_temp && !$fan_main[1] && !$fan_main[2] && !$fan_main[1] && !@fan_default ) {
		%sensors = ();
	}
	else {
		my ($ambient_temp,$psu_fan,$psu1_fan,$psu2_fan,$psu_temp,$sodimm_temp,
		$v_12,$v_5,$v_3_3,$v_dimm_p1,$v_dimm_p2,$v_soc_p1,$v_soc_p2,$v_vbat);
		$psu_temp = $sensors{'psu-temp'} if $sensors{'psu-temp'};
		# sodimm fan is fan_main[4]
		$sodimm_temp = $sensors{'sodimm-temp'} if $sensors{'sodimm-temp'};
		$cpu2_temp = $sensors{'cpu2-temp'} if $sensors{'cpu2-temp'};
		$cpu3_temp = $sensors{'cpu3-temp'} if $sensors{'cpu3-temp'};
		$cpu4_temp = $sensors{'cpu4-temp'} if $sensors{'cpu4-temp'};
		$ambient_temp = $sensors{'ambient-temp'} if $sensors{'ambient-temp'};
		$psu_fan = $sensors{'fan-psu'} if $sensors{'fan-psu'};
		$psu1_fan = $sensors{'fan-psu-1'} if $sensors{'fan-psu-1'};
		$psu2_fan = $sensors{'fan-psu-2'} if $sensors{'fan-psu-2'};
		# so far only for ipmi, sensors data is junk for volts
		if ($extra > 0 && 
		    ($sensors{'volts-12'} || $sensors{'volts-5'} || $sensors{'volts-3.3'} || $sensors{'volts-vbat'}) ){
			$v_12 = $sensors{'volts-12'} if $sensors{'volts-12'};
			$v_5 = $sensors{'volts-5'} if $sensors{'volts-5'};
			$v_3_3 = $sensors{'volts-3.3'} if  $sensors{'volts-3.3'};
			$v_vbat = $sensors{'volts-vbat'} if $sensors{'volts-vbat'};
			$v_dimm_p1 = $sensors{'volts-dimm-p1'} if $sensors{'volts-dimm-p1'};
			$v_dimm_p2 = $sensors{'volts-dimm-p2'} if $sensors{'volts-dimm-p2'};
			$v_soc_p1 = $sensors{'volts-soc-p1'} if $sensors{'volts-soc-p1'};
			$v_soc_p2 = $sensors{'volts-soc-p2'} if $sensors{'volts-soc-p2'};
		}
		%sensors = (
		'ambient-temp' => $ambient_temp,
		'cpu-temp' => $cpu_temp,
		'cpu2-temp' => $cpu2_temp,
		'cpu3-temp' => $cpu3_temp,
		'cpu4-temp' => $cpu4_temp,
		'mobo-temp' => $mobo_temp,
		'psu-temp' => $psu_temp,
		'temp-unit' => $sensors{'temp-unit'},
		'fan-main' => \@fan_main,
		'fan-default' => \@fan_default,
		'fan-psu' => $psu_fan,
		'fan-psu1' => $psu1_fan,
		'fan-psu2' => $psu2_fan,
		);
		if ($psu_temp){
			$sensors{'psu-temp'} = $psu_temp;
		}
		if ($sodimm_temp){
			$sensors{'sodimm-temp'} = $sodimm_temp;
		}
		if ($extra > 0 && ($v_12 || $v_5 || $v_3_3 || $v_vbat) ){
			$sensors{'volts-12'} = $v_12;
			$sensors{'volts-5'} = $v_5;
			$sensors{'volts-3.3'} = $v_3_3;
			$sensors{'volts-vbat'} = $v_vbat;
			$sensors{'volts-dimm-p1'} = $v_dimm_p1;
			$sensors{'volts-dimm-p2'} = $v_dimm_p2;
			$sensors{'volts-soc-p1'} = $v_soc_p1;
			$sensors{'volts-soc-p2'} = $v_soc_p2;
		}
	}
	eval $end if $b_log;
	return %sensors;
}
sub gpu_data {
	eval $start if $b_log;
	return @gpudata if $b_gpudata;
	my ($cmd,@data,@data2,$path,@screens,$temp);
	my ($j) = (0);
	if ($path = main::check_program('nvidia-settings')){
		# first get the number of screens. This only work if you are in X
		if ($b_display) {
			@data = main::grabber("$path -q screens 2>/dev/null");
			foreach (@data){
				if ( /(:[0-9]\.[0-9])/ ) {
					push @screens, $1;
				}
			}
		}
		# do a guess, this will work for most users, it's better than nothing for out of X
		else {
			$screens[0] = ':0.0';
		}
		# now we'll get the gpu temp for each screen discovered. The print out function
		# will handle removing screen data for single gpu systems. -t shows only data we want
		# GPUCurrentClockFreqs: 520,600
		# GPUCurrentFanSpeed: 50 0-100, not rpm, percent I think
		# VideoRam: 1048576
		# CUDACores: 16 
		# PCIECurrentLinkWidth: 16
		# PCIECurrentLinkSpeed: 5000
		# RefreshRate: 60.02 Hz [oer screen]
		# ViewPortOut=1280x1024+0+0}, DPY-1: nvidia-auto-select @1280x1024 +1280+0 {ViewPortIn=1280x1024,
		# ViewPortOut=1280x1024+0+0}
		# ThermalSensorReading: 50
		# PCIID: 4318,2661 - the pci stuff doesn't appear to work
		# PCIBus: 2
		# PCIDevice: 0
		# Irq: 30
		foreach my $screen (@screens){
			my $screen2 = $screen;
			$screen2 =~ s/\.[0-9]$//;
			$cmd = '-q GPUCoreTemp -q VideoRam -q GPUCurrentClockFreqs -q PCIECurrentLinkWidth ';
			$cmd .= '-q Irq -q PCIBus -q PCIDevice -q GPUCurrentFanSpeed';
			$cmd = "$path -c $screen2 $cmd 2>/dev/null";
			@data = main::grabber($cmd);
			main::log_data('cmd',$cmd) if $b_log;
			@data = (@data,@data2);
			$j = scalar @gpudata;
			$gpudata[$j] = ({});
			foreach my $item (@data){
				if ($item =~ /^\s*Attribute\s\'([^']+)\'\s.*:\s*([\S]+)\.$/){
					my $attribute = $1;
					my $value = $2;
					$gpudata[$j]{'type'} = 'nvidia';
					$gpudata[$j]{'speed-unit'} = '%';
					$gpudata[$j]{'screen'} = $screen;
					if (!$gpudata[$j]{'temp'} && $attribute eq 'GPUCoreTemp'){
						$gpudata[$j]{'temp'} = $value;
					}
					elsif (!$gpudata[$j]{'ram'} && $attribute eq 'VideoRam'){
						$gpudata[$j]{'ram'} = $value;
					}
					elsif (!$gpudata[$j]{'clock'} && $attribute eq 'GPUCurrentClockFreqs'){
						$gpudata[$j]{'clock'} = $value;
					}
					elsif (!$gpudata[$j]{'bus'} && $attribute eq 'PCIBus'){
						$gpudata[$j]{'bus'} = $value;
					}
					elsif (!$gpudata[$j]{'bus-id'} && $attribute eq 'PCIDevice'){
						$gpudata[$j]{'bus-id'} = $value;
					}
					elsif (!$gpudata[$j]{'fan-speed'} && $attribute eq 'GPUCurrentFanSpeed'){
						$gpudata[$j]{'fan-speed'} = $value;
					}
				}
			}
		}
	}
	if ($path = main::check_program('aticonfig')){
		# aticonfig --adapter=0 --od-gettemperature
		@data = main::grabber("$path --adapter=all --od-gettemperature 2>/dev/null");
		foreach (@data){
			if (/Sensor [^0-9]*([0-9\.]+) /){
				$j = scalar @gpudata;
				$gpudata[$j] = ({});
				my $value = $1;
				$gpudata[$j]{'type'} = 'amd';
				$gpudata[$j]{'temp'} = $value;
			}
		}
	}
	if ($sensors_raw{'gpu'}){
		#my ($b_found,$holder) = (0,'');
		foreach my $adapter (keys %{$sensors_raw{'gpu'}}){
			$j = scalar @gpudata;
			$gpudata[$j]{'type'} = $adapter;
			$gpudata[$j]{'type'} =~ s/^(amdgpu|intel|nouveau|radeon)-.*/$1/;
			# print "ad: $adapter\n";
			foreach (@{$sensors_raw{'gpu'}->{$adapter}}){
				# print "val: $_\n";
				if (/^[^:]*mem[^:]*:([0-9\.]+).*\b(C|F)\b/i){
					$gpudata[$j]{'temp-mem'} = $1;
					$gpudata[$j]{'unit'} = $2;
					 # print "temp: $_\n";
				}
				elsif (/^[^:]+:([0-9\.]+).*\b(C|F)\b/i){
					$gpudata[$j]{'temp'} = $1;
					$gpudata[$j]{'unit'} = $2;
					 # print "temp: $_\n";
				}
				# speeds can be in percents or rpms, so need the 'fan' in regex
				elsif (/^.*fan.*:([0-9\.]+).*(RPM)?/i){
					$gpudata[$j]{'fan-speed'} = $1;
					# NOTE: we test for nvidia %, everything else stays with nothing
					$gpudata[$j]{'speed-unit'} = '';
				}
				elsif (/^[^:]+:([0-9\.]+)\s+W\s/i){
					$gpudata[$j]{'watts'} = $1;
				}
				elsif (/^[^:]+:([0-9\.]+)\s+mV\s/i){
					$gpudata[$j]{'mvolts'} = $1;
				}
			}
		}
	}
	main::log_data('dump','sensors output: video: @gpudata',\@gpudata);
	# we'll probably use this data elsewhere so make it a one time call
	$b_gpudata = 1;
	print 'gpudata: ', Data::Dumper::Dumper \@gpudata if $test[18];
	eval $end if $b_log;
	return @gpudata;
}
}

## SlotData
{
package SlotData;

sub get {
	eval $start if $b_log;
	my (@data,@rows,$key1,$val1);
	my $num = 0;
	my $ref = $alerts{'dmidecode'};
	if ($b_fake_dmidecode || ( $$ref{'action'} eq 'use' && (!$b_arm || $b_slot_tool ) )){
		@rows = slot_data();
	}
	elsif ($b_arm && !$b_slot_tool){
		$key1 = 'ARM';
		$val1 = main::row_defaults('arm-pci','');
		@rows = ({main::key($num++,0,1,$key1) => $val1,});
	}
	elsif ( $$ref{'action'} ne 'use'){
		$key1 = $$ref{'action'};
		$val1 = $$ref{$key1};
		$key1 = ucfirst($key1);
		@rows = ({main::key($num++,0,1,$key1) => $val1,});
	}
	eval $end if $b_log;
	return @rows;
}
sub slot_data {
	eval $start if $b_log;
	my (@data,@rows);
	my $num = 0;
	foreach (@dmi){
		$num = 1;
		my @ref = @$_;
		if ($ref[0] == 9){
			my ($designation,$id,$length,$type,$usage) = ('','','','','');
			# skip first two row, we don't need that data
			splice @ref, 0, 2 if @ref;
			my $j = scalar @rows;
			foreach my $item (@ref){
				if ($item !~ /^~/){ # skip the indented rows
					my @value = split /:\s+/, $item;
					if ($value[0] eq 'Type'){
						$type = $value[1];
					}
					if ($value[0] eq 'Designation'){
						$designation = $value[1];
					}
					if ($value[0] eq 'Current Usage'){
						$usage = $value[1];
						
					}
					if ($value[0] eq 'ID'){
						$id = $value[1];
					}
					if ($extra > 1 && $value[0] eq 'Length'){
						$length = $value[1];
					}
				}
			}
			if ($type){
				$id = 'N/A' if ($id eq '' );
				if ($type eq 'Other' && $designation){
					$type = $designation;
				}
				elsif ($type && $designation) {
					$type = "$type $designation";
				}
				@data = (
				{
				main::key($num++,1,1,'Slot') => $id,
				main::key($num++,0,2,'type') => $type,
				main::key($num++,0,2,'status') => $usage,
				},
				);
				@rows = (@rows,@data);
				if ($extra > 1 ){
					$rows[$j]{main::key($num++,0,2,'length')} = $length;
				}
			}
		}
	}
	if (!@rows){
		my $key = 'Message';
		@data = ({
		main::key($num++,0,1,$key) => main::row_defaults('pci-slot-data',''),
		},);
		@rows = (@rows,@data);
	}
	eval $end if $b_log;
	return @rows;
}
}

## SwapData 
{
package SwapData;

sub get {
	eval $start if $b_log;
	my (@data,@rows,$key1,$val1);
	my $num = 0;
	@rows =create_output();
	if (!@rows){
		@data = (
		{main::key($num++,0,1,'Alert') => main::row_defaults('swap-data')},
		);
		@rows = (@data);
	}
	eval $end if $b_log;
	return @rows;
}
sub create_output {
	eval $start if $b_log;
	my $num = 0;
	my $j = 0;
	my (@data,@data2,%part,@rows,$dev,$percent,$raw_size,$size,$used);
	my @swap_data = PartitionData::swap_data();
	foreach my $ref (@swap_data){
		my %row = %$ref;
		$num = 1;
		@data2 = main::get_size($row{'size'}) if (defined $row{'size'});
		$size = (@data2) ? $data2[0] . ' ' . $data2[1]: 'N/A';
		@data2 = main::get_size($row{'used'}) if (defined $row{'used'});
		$used = (@data2) ? $data2[0] . ' ' . $data2[1]: 'N/A';
		$percent = (defined $row{'percent-used'}) ? ' (' . $row{'percent-used'} . '%)' : '';
		%part = ();
		$dev = ($row{'swap-type'} eq 'file') ? 'file' : 'dev';
		$row{'swap-type'} = ($row{'swap-type'}) ? $row{'swap-type'} : 'N/A';
		if ($b_admin && !$bsd_type && $j == 0){
			$j = scalar @rows;
			if (defined $row{'swappiness'} || defined $row{'cache-pressure'}){
				$rows[$j]{main::key($num++,1,1,'Kernel')} = '';
				if (defined $row{'swappiness'}){
					$rows[$j]{main::key($num++,0,2,'swappiness')} = $row{'swappiness'};
				}
				if (defined $row{'cache-pressure'}){
					$rows[$j]{main::key($num++,0,2,'cache pressure')} = $row{'cache-pressure'};
				}
			}
			else {
				$rows[$j]{main::key($num++,0,1,'Message')} = main::row_defaults('swap-admin');
			}
		}
		$j = scalar @rows;
		@data = ({
		main::key($num++,1,1,'ID') => $row{'id'},
		main::key($num++,0,2,'type') => $row{'swap-type'},
		});
		@rows = (@rows,@data);
		# not used for swap as far as I know
		if ($b_admin && $row{'raw-size'} ){
			# It's an error! permissions or missing tool
			if (!main::is_numeric($row{'raw-size'})){
				$raw_size = $row{'raw-size'};
			}
			else {
				@data2 = main::get_size($row{'raw-size'});
				$raw_size = (@data2) ? $data2[0] . ' ' . $data2[1]: 'N/A';
			}
			$rows[$j]{main::key($num++,0,2,'raw size')} = $raw_size;
		}
		# not used for swap as far as I know
		if ($b_admin && $row{'raw-available'} && $size ne 'N/A'){
			$size .=  ' (' . $row{'raw-available'} . '%)';
		}
		$rows[$j]{main::key($num++,0,2,'size')} = $size;
		$rows[$j]{main::key($num++,0,2,'used')} = $used . $percent;
		# not used for swap as far as I know
		if ($b_admin && $row{'block-size'}){
			$rows[$j]{main::key($num++,0,2,'block size')} = $row{'block-size'} . ' B';;
			#$rows[$j]{main::key($num++,0,2,'physical')} = $row{'block-size'} . ' B';
			#$rows[$j]{main::key($num++,0,2,'logical')} = $row{'block-logical'} . ' B';
		}
		if ($extra > 1 && defined $row{'priority'}){
			$rows[$j]{main::key($num++,0,2,'priority')} = $row{'priority'};
		}
		$row{'mount'} =~ s|/home/[^/]+/(.*)|/home/$filter_string/$1| if $row{'mount'} && $use{'filter'};
		$rows[$j]{main::key($num++,0,2,$dev)} = ($row{'mount'}) ? $row{'mount'} : 'N/A';
		if ($show{'label'} && ($row{'label'} || $row{'swap-type'} eq 'partition') ){
			$row{'label'} = main::apply_partition_filter('part', $row{'label'}, '') if $use{'filter-label'};
			$rows[$j]{main::key($num++,0,2,'label')} = ($row{'label'}) ? $row{'label'}: 'N/A';
		}
		if ($show{'uuid'} && ($row{'uuid'} || $row{'swap-type'} eq 'partition' )){
			$row{'uuid'} = main::apply_partition_filter('part', $row{'uuid'}, '') if $use{'filter-uuid'};
			$rows[$j]{main::key($num++,0,2,'uuid')} = ($row{'uuid'}) ? $row{'uuid'}: 'N/A';
		}
	}
	eval $end if $b_log;
	return @rows;
}

}

## UnmountedData
{
package UnmountedData;

sub get {
	eval $start if $b_log;
	my (@data,@rows,$key1,$val1);
	my $num = 0;
	if ($bsd_type){
		$key1 = 'Message';
		$val1 = main::row_defaults('unmounted-data-bsd');
	}
 	else {
		if (my $file = main::system_files('partitions')){
			@data = unmounted_data($file);
			if (!@data){
				$key1 = 'Message';
				$val1 = main::row_defaults('unmounted-data');
			}
			else {
				@rows = create_output(@data);
			}
		}
		else {
			$key1 = 'Message';
			$val1 = main::row_defaults('unmounted-file');
		}
 	}
 	if (!@rows && $key1){
		@rows = ({main::key($num++,0,1,$key1) => $val1,});
 	}
	eval $end if $b_log;
	return @rows;
}
sub create_output {
	eval $start if $b_log;
	my (@unmounted) = @_;
	my (@data,@rows,$fs);
	my $num = 0;
	@unmounted = sort { $a->{'dev-base'} cmp $b->{'dev-base'} } @unmounted;
	foreach my $ref (@unmounted){
		my %row = %$ref;
		$num = 1;
		my @data2 = main::get_size($row{'size'}) if (defined $row{'size'});
		my $size = (@data2) ? $data2[0] . ' ' . $data2[1]: 'N/A';
		if ($row{'fs'}){
			$fs = lc($row{'fs'});
		}
		else {
			if (main::check_program('file')){
				$fs = ($b_root) ? 'N/A' : main::row_defaults('root-required');
			}
			else {
				$fs = main::row_defaults('tool-missing-basic','file');
			}
		}
		$row{'label'} = main::apply_partition_filter('part', $row{'label'}, '') if $use{'filter-label'};
		$row{'uuid'} = main::apply_partition_filter('part', $row{'uuid'}, '') if $use{'filter-uuid'};
		@data = ({
		main::key($num++,1,1,'ID') => "/dev/$row{'dev-base'}",
		main::key($num++,0,2,'size') => $size,
		main::key($num++,0,2,'fs') => $fs,
		main::key($num++,0,2,'label') => $row{'label'},
		main::key($num++,0,2,'uuid') => $row{'uuid'},
		});
		@rows = (@rows,@data);
	}
	eval $end if $b_log;
	return @rows;
}
sub unmounted_data {
	eval $start if $b_log;
	my ($file) = @_;
	my ($fs,$label,$size,$uuid,@data,%part,@unmounted);
	# last filters to make sure these are dumped
	my @filters = ('scd[0-9]+','sr[0-9]+','cdrom[0-9]*','cdrw[0-9]*',
	'dvd[0-9]*','dvdrw[0-9]*','fd[0-9]','ram[0-9]*');
	my @mounts = main::reader($file,'strip');
	my $num = 0;
	PartitionData::set_lsblk() if !$bsd_type && !$b_lsblk;
	# set labels, uuid, gpart
	PartitionData::partition_data() if !$b_partitions;
	PartitionData::set_label_uuid() if !$b_label_uuid;
	RaidData::raid_data() if !$b_raid;
	my @mounted = get_mounted();
	#print join("\n",(@filters,@mounted)),"\n";
	foreach (@mounts){
		my @working = split /\s+/, $_;
		($fs,$label,$uuid,$size) = ('','','','');
		# note that size 1 means it is a logical extended partition container
		# lvm might have dm-1 type syntax
		# need to exclude loop type file systems, squashfs for example
		# NOTE: nvme needs special treatment because the main device is: nvme0n1
		# note: $working[2] != 1 is wrong, it's not related
		# note: for zfs using /dev/sda no partitions, this will also remove those from 
		# the unmounted report because sdb is found in sdb1, this is acceptable
		# in arm/android seen /dev/block/mmcblk0p12
		#print "mount: $working[-1] row: $_ \n";
		if ( $working[-1] !~ /^(nvme[0-9]+n|mmcblk|mtdblk|mtdblock)[0-9]+$/ && 
		     $working[-1] =~ /[a-z][0-9]+$|dm-[0-9]+$/ && 
		     $working[-1] !~ /\bloop/ && 
		     !(grep {$working[-1] =~ /$_$/} (@filters,@mounted)) && 
		     !(grep {$_ =~ /(block\/)?$working[-1]$/} @mounted)){
			%part = PartitionData::check_lsblk($working[-1],0) if (@lsblk && $working[-1]);
			if (%part){
				$fs = $part{'fs'};
				$label = $part{'label'};
				$uuid = $part{'uuid'};
				$size = $part{'size'} if $part{'size'} && !$working[2];
			}
			$size ||= $working[2];
		   $fs = unmounted_filesystem($working[-1]) if !$fs;
		   $label = PartitionData::get_label("/dev/$working[-1]") if !$label;
			$uuid = PartitionData::get_uuid("/dev/$working[-1]") if !$uuid;
			@data = ({
			'dev-base' => $working[-1],
			'fs' => $fs,
			'label' => $label,
			'size' => $size,
			'uuid' => $uuid,
			});
			@unmounted = (@unmounted,@data);
		}
	}
	# print Data::Dumper::Dumper @unmounted;
	main::log_data('dump','@unmounted',\@unmounted) if $b_log;
	eval $end if $b_log;
	return @unmounted;
}
sub get_mounted {
	eval $start if $b_log;
	my (@mounted);
	foreach my $ref (@partitions){
		my %row = %$ref;
		push @mounted, $row{'dev-base'} if $row{'dev-base'};
	}
	foreach my $ref (@raid){
		my %row = %$ref;
		my $ref2 = $row{'arrays'};
		# we want to not show md0 etc in unmounted report
		push @mounted, $row{'id'} if $row{'id'}; 
		my @arrays = (ref $ref2 eq 'ARRAY' ) ? @$ref2 : ();
		@arrays = grep {defined $_} @arrays;
		foreach my $array (@arrays){
			my %row2 = %$array;
			my $ref3 = $row2{'components'};
			my @components = (ref $ref3 eq 'ARRAY') ? @$ref3 : ();
			foreach my $component (@components){
				my @temp = split /~/, $component;
				push @mounted, $temp[0];
			}
		}
	}
	eval $end if $b_log;
	return @mounted;
}
sub unmounted_filesystem {
	eval $start if $b_log;
	my ($item) = @_;
	my ($data,%part);
	my ($file,$fs,$path) = ('','','');
	if ($path = main::check_program('file')) {
		$file = $path;
	}
	# order matters in this test!
	my @filesystems = ('ext2','ext3','ext4','ext5','ext','ntfs',
	'fat32','fat16','FAT\s\(.*\)','vfat','fatx','tfat','swap','btrfs',
	'ffs','hammer','hfs\+','hfs\splus','hfs\sextended\sversion\s[1-9]','hfsj',
	'hfs','jfs','nss','reiserfs','reiser4','ufs2','ufs','xfs','zfs');
	if ($file){
		# this will fail if regular user and no sudo present, but that's fine, it will just return null
		# note the hack that simply slices out the first line if > 1 items found in string
		# also, if grub/lilo is on partition boot sector, no file system data is available
		$data = (main::grabber("$sudo$file -s /dev/$item 2>/dev/null"))[0];
		if ($data){
			foreach (@filesystems){
				if ($data =~ /($_)[\s,]/i){
					$fs = $1;
					$fs = main::trimmer($fs);
					last;
				}
			}
		}
	}
	main::log_data('data',"fs: $fs") if $b_log;
	eval $end if $b_log;
	return $fs;
}
}

## UsbData
{
package UsbData;

sub get {
	eval $start if $b_log;
	my (@data,@rows,$key1,$val1);
	my $num = 0;
	my $ref = $alerts{'lsusb'};
	my $ref2 = $alerts{'usbdevs'};
	if ( !@usb && $$ref{'action'} ne 'use' && $$ref2{'action'} ne 'use'){
		if ($os eq 'linux' ){
			$key1 = $$ref{'action'};
			$val1 = $$ref{$key1};
		}
		else {
			$key1 = $$ref2{'action'};
			$val1 = $$ref2{$key1};
		}
		$key1 = ucfirst($key1);
		@rows = ({main::key($num++,0,1,$key1) => $val1,});
	}
	else {
		@rows = usb_data();
		if (!@rows){
			my $key = 'Message';
			@data = ({
			main::key($num++,0,1,$key) => main::row_defaults('usb-data',''),
			},);
			@rows = (@rows,@data);
		}
	}
	eval $end if $b_log;
	return @rows;
}
sub usb_data {
	eval $start if $b_log;
	return if ! @usb;
	my (@data,@rows);
	my ($b_hub,$bus_id,$chip_id,$driver,$ind_sc,$path_id,$ports,$product,$serial,$speed,$type);
	my $num = 0;
	my $j = 0;
	# note: the data has been presorted in set_lsusb_data by:
	# bus id then device id, so we don't need to worry about the order
	foreach my $ref (@usb){
		my @id = @$ref;
		$j = scalar @rows;
		($b_hub,$ind_sc,$num) = (0,3,1);
		$chip_id = $id[7];
		($driver,$path_id,$ports,$product,
		$serial,$speed,$type) = ('','','','','','','');
		$speed  = ( main::is_numeric($id[8]) ) ? sprintf("%1.1f",$id[8]) : $id[8] if $id[8];
		$product = main::cleaner($id[13]) if $id[13];
		$serial = main::apply_filter($id[16]) if $id[16];
		$product ||= 'N/A';
		$speed ||= 'N/A';
		$path_id = $id[2] if $id[2];
		$bus_id = "$path_id:$id[1]";
		# it's a hub
		if ($id[4] eq '9'){
			$ports = $id[10] if $id[10];
			$ports ||= 'N/A';
			#print "pt0:$protocol\n";
			@data = ({
			main::key($num++,1,1,'Hub') => $bus_id,
			main::key($num++,0,2,'info') => $product,
			main::key($num++,0,2,'ports') => $ports,
			main::key($num++,0,2,'rev') => $speed,
			},);
			@rows = (@rows,@data);
			$b_hub = 1;
			$ind_sc =2;
		}
		# it's a device
		else {
			$type = $id[14] if $id[14];
			$driver = $id[15] if $id[15];
			$type ||= 'N/A';
			$driver ||= 'N/A';
			#print "pt3:$class:$product\n";
			$rows[$j]{main::key($num++,1,2,'Device')} = $bus_id;
			$rows[$j]{main::key($num++,0,3,'info')} = $product;
			$rows[$j]{main::key($num++,0,3,'type')} = $type;
			if ($extra > 0){
				$rows[$j]{main::key($num++,0,3,'driver')} = $driver;
			}
			if ($extra > 2 && $id[9]){
				$rows[$j]{main::key($num++,0,3,'interfaces')} = $id[9];
			}
			$rows[$j]{main::key($num++,0,3,'rev')} = $speed;
		}
		# for either hub or device
		if ($extra > 2 && main::is_numeric($id[17])){
			my $speed = $id[17];
			if ($speed >= 1000) {$speed = ($id[17] / 1000 ) . " Gb/s"}
			else {$speed = $id[17] . " Mb/s"}
			$rows[$j]{main::key($num++,0,$ind_sc,'speed')} = $speed;
		}
		if ($extra > 1){
			$rows[$j]{main::key($num++,0,$ind_sc,'chip ID')} = $chip_id;
		}
		if (!$b_hub && $extra > 2){
			if ($serial){
				$rows[$j]{main::key($num++,0,$ind_sc,'serial')} = main::apply_filter($serial);
			}
		}
	}
	#print Data::Dumper::Dumper \@rows;
	eval $end if $b_log;
	return @rows;
}
}

## add metric / imperial (us) switch
## WeatherData
{
package WeatherData;

sub get {
	eval $start if $b_log;
	my (@rows,$key1,$val1);
	my $num = 0;
	@rows = create_output();
	eval $end if $b_log;
	return @rows;
}
sub create_output {
	eval $start if $b_log;
	my ($j,$num) = (0,0);
	my (@data,@location,@rows,$value,%weather,);
	my ($conditions) = ('NA');
	if ($show{'weather-location'}){
		my $location_string;
		$location_string = $show{'weather-location'};
		$location_string =~ s/\+/ /g;
		if ( $location_string =~ /,/){
			my @temp = split /,/, $location_string;
			my $sep = '';
			my $string = '';
			foreach (@temp){
				$_ = ucfirst($_);
				$string .= $sep . $_;
				$sep = ', ';
			}
			$location_string = $string;
		}
		$location_string = main::apply_filter($location_string);
		@location = ($show{'weather-location'},$location_string,'');
	}
	else {
		@location = get_location();
		if (!$location[0]) {
			return @rows = ({
			main::key($num++,0,1,'Message') => main::row_defaults('weather-null','current location'),
			});
		}
	}
	%weather = get_weather(@location);
	if ($weather{'error'}) {
		return @rows = ({
		main::key($num++,0,1,'Message') => main::row_defaults('weather-error',$weather{'error'}),
		});
	}
	if (!$weather{'weather'}) {
		return @rows = ({
		main::key($num++,0,1,'Message') => main::row_defaults('weather-null','weather data'),
		});
	}
	$conditions = "$weather{'weather'}";
	my $temp = unit_output($weather{'temp'},$weather{'temp-c'},'C',$weather{'temp-f'},'F');
	$j = scalar @rows;
	@data = ({
	main::key($num++,1,1,'Report') => '',
	main::key($num++,0,2,'temperature') => $temp,
	main::key($num++,0,2,'conditions') => $conditions,
	},);
	@rows = (@rows,@data);
	if ($extra > 0){
		my $pressure = unit_output($weather{'pressure'},$weather{'pressure-mb'},'mb',$weather{'pressure-in'},'in');
		my $wind = wind_output($weather{'wind'},$weather{'wind-direction'},$weather{'wind-mph'},$weather{'wind-ms'},
		$weather{'wind-gust-mph'},$weather{'wind-gust-ms'});
		$rows[$j]{main::key($num++,0,2,'wind')} = $wind;
		if ($extra > 1){
			if (defined $weather{'cloud-cover'}){
				$rows[$j]{main::key($num++,0,2,'cloud cover')} = $weather{'cloud-cover'} . '%';
			}
			if ($weather{'precip-1h-mm'} && defined $weather{'precip-1h-in'} ){
				$value = unit_output('',$weather{'precip-1h-mm'},'mm',$weather{'precip-1h-in'},'in');
				$rows[$j]{main::key($num++,0,2,'precipitation')} = $value;
			}
			if ($weather{'rain-1h-mm'} && defined $weather{'rain-1h-in'} ){
				$value = unit_output('',$weather{'rain-1h-mm'},'mm',$weather{'rain-1h-in'},'in');
				$rows[$j]{main::key($num++,0,2,'rain')} = $value;
			}
			if ($weather{'snow-1h-mm'} && defined $weather{'snow-1h-in'} ){
				$value = unit_output('',$weather{'snow-1h-mm'},'mm',$weather{'snow-1h-in'},'in');
				$rows[$j]{main::key($num++,0,2,'snow')} = $value;
			}
		}
		$rows[$j]{main::key($num++,0,2,'humidity')} = $weather{'humidity'} . '%';
		if ($extra > 1){
			if ($weather{'dewpoint'} || (defined $weather{'dewpoint-c'} && defined $weather{'dewpoint-f'})){
				$value = unit_output($weather{'dewpoint'},$weather{'dewpoint-c'},'C',$weather{'dewpoint-f'},'F');
				$rows[$j]{main::key($num++,0,2,'dew point')} = $value;
			}
		}
		$rows[$j]{main::key($num++,0,2,'pressure')} = $pressure;
	}
	if ($extra > 1){
		if ($weather{'heat-index'} || (defined $weather{'heat-index-c'} && defined $weather{'heat-index-f'})){
			$value = unit_output($weather{'heat-index'},$weather{'heat-index-c'},'C',$weather{'heat-index-f'},'F');
			$rows[$j]{main::key($num++,0,2,'heat index')} = $value;
		}
		if ($weather{'windchill'} || (defined $weather{'windchill-c'} && defined $weather{'windchill-f'})){
			$value = unit_output($weather{'windchill'},$weather{'windchill-c'},'C',$weather{'windchill-f'},'F');
			$rows[$j]{main::key($num++,0,2,'wind chill')} = $value;
		}
		if ($extra > 2){
			if ($weather{'forecast'}){
				$j = scalar @rows;
				@data = ({
				main::key($num++,1,1,'Forecast') => $weather{'forecast'},
				},);
				@rows = (@rows,@data);
			}
		}
	}
	$j = scalar @rows;
	my $location = '';
	if ($extra > 2 && !$use{'filter'}){
		$location = complete_location($location[1],$weather{'city'},$weather{'state'},$weather{'country'});
	}
	@data = ({
	main::key($num++,1,1,'Locale') => $location,
	},);
	@rows = (@rows,@data);
	if ($extra > 2 && !$use{'filter'} && ($weather{'elevation-m'} || $weather{'elevation-ft'} )){
		$rows[$j]{main::key($num++,0,2,'altitude')} = elevation_output($weather{'elevation-m'},$weather{'elevation-ft'});
	}
	$rows[$j]{main::key($num++,0,2,'current time')} = $weather{'date-time'},;
	if ($extra > 2){
		$weather{'observation-time-local'} = 'N/A' if !$weather{'observation-time-local'};
		$rows[$j]{main::key($num++,0,2,'observation time')} = $weather{'observation-time-local'};
		if ($weather{'sunrise'}){
			$rows[$j]{main::key($num++,0,2,'sunrise')} = $weather{'sunrise'};
		}
		if ($weather{'sunset'}){
			$rows[$j]{main::key($num++,0,2,'sunset')} = $weather{'sunset'};
		}
		if ($weather{'moonphase'}){
			$value = $weather{'moonphase'} . '%';
			$value .= ($weather{'moonphase-graphic'}) ? ' ' . $weather{'moonphase-graphic'} :'';
			$rows[$j]{main::key($num++,0,2,'moonphase')} = $value;
		}
	}
	if ($weather{'api-source'}){
		$rows[$j]{main::key($num++,0,1,'Source')} = $weather{'api-source'};
	}
	eval $end if $b_log;
	return @rows;
}
sub elevation_output {
	eval $start if $b_log;
	my ($meters,$feet) = @_;
	my ($result,$i_unit,$m_unit) = ('','ft','m');
	$feet = sprintf("%.0f", 3.28 * $meters) if defined $meters && !$feet;
	$meters = sprintf("%.1f", $feet / 3.28 ) if defined $feet && !$meters;
	$meters = sprintf("%.0f", $meters) if $meters;
	if ( defined $meters  && $weather_unit eq 'mi' ){
		$result = "$meters $m_unit ($feet $i_unit)";
	}
	elsif (defined $meters && $weather_unit eq 'im' ){
		$result = "$feet $i_unit ($meters $m_unit)";
	}
	elsif (defined $meters && $weather_unit eq 'm' ){
		$result = "$meters $m_unit";
	}
	elsif (defined $feet && $weather_unit eq 'i' ){
		$result = "$feet $i_unit";
	}
	else {
		$result = 'N/A';
	}
	eval $end if $b_log;
	return $result;
}
sub unit_output {
	eval $start if $b_log;
	my ($primary,$metric,$m_unit,$imperial,$i_unit) = @_;
	my $result = '';
	if (defined $metric && defined $imperial && $weather_unit eq 'mi' ){
		$result = "$metric $m_unit ($imperial $i_unit)";
	}
	elsif (defined $metric && defined $imperial && $weather_unit eq 'im' ){
		$result = "$imperial $i_unit ($metric $m_unit)";
	}
	elsif (defined $metric && $weather_unit eq 'm' ){
		$result = "$metric $m_unit";
	}
	elsif (defined $imperial && $weather_unit eq 'i' ){
		$result = "$imperial $i_unit";
	}
	elsif ($primary){
		$result = $primary;
	}
	else {
		$result = 'N/A';
	}
	eval $end if $b_log;
	return $result;
}
sub wind_output {
	eval $start if $b_log;
	my ($primary,$direction,$mph,$ms,$gust_mph,$gust_ms) = @_;
	my ($result,$gust_kmh,$kmh,$i_unit,$m_unit,$km_unit) = ('','','','mph','m/s','km/h');
	# get rid of possible gust values if they are the same as wind values
	$gust_mph = undef if $gust_mph && $mph && $mph eq $gust_mph;
	$gust_ms = undef if $gust_ms && $ms && $ms eq $gust_ms;
	# calculate and round, order matters so that rounding only happens after math done
	$ms = 0.44704 * $mph if defined $mph && !defined $ms;
	$mph = $ms * 2.23694 if defined $ms && !defined $mph;
	$kmh = sprintf("%.0f",  18 * $ms / 5) if defined $ms;
	$ms = sprintf("%.1f", $ms ) if defined $ms; # very low mph speeds yield 0, which is wrong
	$mph = sprintf("%.0f", $mph) if defined $mph;
	$gust_ms = 0.44704 * $gust_mph if $gust_mph && !$gust_ms;
	$gust_kmh = 18 * $gust_ms / 5 if $gust_ms;
	$gust_mph = $gust_ms * 2.23694 if $gust_ms && !$gust_mph;
	$gust_mph = sprintf("%.0f", $gust_mph) if $gust_mph;
	$gust_kmh = sprintf("%.0f", $gust_kmh) if $gust_kmh;
	$gust_ms = sprintf("%.0f", $gust_ms ) if  $gust_ms;
	if (!defined $mph && $primary){
		$result = $primary;
	}
	elsif (defined $mph && defined $direction ){
		if ( $weather_unit eq 'mi' ){
			$result = "from $direction at $ms $m_unit ($kmh $km_unit, $mph $i_unit)";
		}
		elsif ( $weather_unit eq 'im' ){
			$result = "from $direction at $mph $i_unit ($ms $m_unit, $kmh $km_unit)";
		}
		elsif ( $weather_unit eq 'm' ){
			$result = "from $direction at $ms $m_unit ($kmh $km_unit)";
		}
		elsif ( $weather_unit eq 'i' ){
			$result = "from $direction at $mph $i_unit";
		}
		if ($gust_mph){
			if ( $weather_unit eq 'mi' ){
				$result .= ". Gusting to $ms $m_unit ($kmh $km_unit, $mph $i_unit)";
			}
			elsif ( $weather_unit eq 'im' ){
				$result .= ". Gusting to $mph $i_unit ($ms $m_unit, $kmh $km_unit)";
			}
			elsif ( $weather_unit eq 'm' ){
				$result .= ". Gusting to $ms $m_unit ($kmh $km_unit)";
			}
			elsif ( $weather_unit eq 'i' ){
				$result .= ". Gusting to $mph $i_unit";
			}
		}
	}
	elsif ($primary){
		$result = $primary;
	}
	else {
		$result = 'N/A';
	}
	eval $end if $b_log;
	return $result;
}
sub get_weather {
	eval $start if $b_log;
	my (@location) = @_;
	my $now = POSIX::strftime "%Y%m%d%H%M", localtime;
	my ($date_time,$freshness,$tz,@weather_data,%weather);
	my $loc_name = lc($location[0]);
	$loc_name =~ s/-\/|\s|,/-/g;
	$loc_name =~ s/--/-/g;
	my $file_cached = "$user_data_dir/weather-$loc_name-$weather_source.txt";
	if (-f $file_cached){
		@weather_data = main::reader($file_cached);
		$freshness = (split /\^\^/, $weather_data[0])[1];
		#print "$now:$freshness\n";
	}
	if (!$freshness || $freshness < ($now - 60) ) {
		@weather_data = download_weather($now,$file_cached,@location);
	}
	#print join "\n", @weather_data, "\n";
	# NOTE: because temps can be 0, we can't do if value tests
	foreach (@weather_data){
		my @working = split /\s*\^\^\s*/,$_;
		next if ! defined $working[1] || $working[1] eq '';
		if ( $working[0] eq 'api_source' ){
			$weather{'api-source'} = $working[1];
		}
		elsif ( $working[0] eq 'city' ){
			$weather{'city'} = $working[1];
		}
		elsif ( $working[0] eq 'cloud_cover' ){
			$weather{'cloud-cover'} = $working[1];
		}
		elsif ( $working[0] eq 'country' ){
			$weather{'country'} = $working[1];
		}
		elsif ( $working[0] eq 'dewpoint_string' ){
			$weather{'dewpoint'} = $working[1];
			$working[1] =~ /^([0-9\.]+)\sF\s\(([0-9\.]+)\sC\)/;
			$weather{'dewpoint-c'} = $2;;
			$weather{'dewpoint-f'} = $1;;
		}
		elsif ( $working[0] eq 'dewpoint_c' ){
			$weather{'dewpoint-c'} = $working[1];
		}
		elsif ( $working[0] eq 'dewpoint_f' ){
			$weather{'dewpoint-f'} = $working[1];
		}
		# WU: there are two elevations, we want the first one
		elsif (!$weather{'elevation-m'} && $working[0] eq 'elevation'){
			# note: bug in source data uses ft for meters, not 100% of time, but usually
			$weather{'elevation-m'} = $working[1];
			$weather{'elevation-m'} =~ s/\s*(ft|m).*$//;
		}
		elsif ( $working[0] eq 'error' ){
			$weather{'error'} = $working[1];
		}
		elsif ( $working[0] eq 'forecast' ){
			$weather{'forecast'} = $working[1];
		}
		elsif ( $working[0] eq 'heat_index_string' ){
			$weather{'heat-index'} = $working[1];
			$working[1] =~ /^([0-9\.]+)\sF\s\(([0-9\.]+)\sC\)/;
			$weather{'heat-index-c'} = $2;;
			$weather{'heat-index-f'} = $1;
		}
		elsif ( $working[0] eq 'heat_index_c' ){
			$weather{'heat-index-c'} = $working[1];
		}
		elsif ( $working[0] eq 'heat_index_f' ){
			$weather{'heat-index-f'} = $working[1];
		}
		elsif ( $working[0] eq 'relative_humidity' ){
			$working[1] =~ s/%$//;
			$weather{'humidity'} = $working[1];
		}
		elsif ( $working[0] eq 'local_time' ){
			$weather{'local-time'} = $working[1];
		}
		elsif ( $working[0] eq 'local_epoch' ){
			$weather{'local-epoch'} = $working[1];
		}
		elsif ( $working[0] eq 'moonphase' ){
			$weather{'moonphase'} = $working[1];
		}
		elsif ( $working[0] eq 'moonphase_graphic' ){
			$weather{'moonphase-graphic'} = $working[1];
		}
		elsif ( $working[0] eq 'observation_time_rfc822' ){
			$weather{'observation-time-rfc822'} = $working[1];
		}
		elsif ( $working[0] eq 'observation_epoch' ){
			$weather{'observation-epoch'} = $working[1];
		}
		elsif ( $working[0] eq 'observation_time' ){
			$weather{'observation-time-local'} = $working[1];
			$weather{'observation-time-local'} =~ s/Last Updated on //;
		}
		elsif ( $working[0] eq 'precip_mm' ){
			$weather{'precip-1h-mm'} = $working[1];
		}
		elsif ( $working[0] eq 'precip_in' ){
			$weather{'precip-1h-in'} = $working[1];
		}
		elsif ( $working[0] eq 'pressure_string' ){
			$weather{'pressure'} = $working[1];
		}
		elsif ( $working[0] eq 'pressure_mb' ){
			$weather{'pressure-mb'} = $working[1];
		}
		elsif ( $working[0] eq 'pressure_in' ){
			$weather{'pressure-in'} = $working[1];
		}
		elsif ( $working[0] eq 'rain_1h_mm' ){
			$weather{'rain-1h-mm'} = $working[1];
		}
		elsif ( $working[0] eq 'rain_1h_in' ){
			$weather{'rain-1h-in'} = $working[1];
		}
		elsif ( $working[0] eq 'snow_1h_mm' ){
			$weather{'snow-1h-mm'} = $working[1];
		}
		elsif ( $working[0] eq 'snow_1h_in' ){
			$weather{'snow-1h-in'} = $working[1];
		}
		elsif ( $working[0] eq 'state_name' ){
			$weather{'state'} = $working[1];
		}
		elsif ( $working[0] eq 'sunrise' ){
			if ($working[1]){
				if ($working[1] !~ /^[0-9]+$/){
					$weather{'sunrise'} = $working[1];
				}
				# trying to figure out remote time from UTC is too hard
				elsif (!$show{'weather-location'}){
					$weather{'sunrise'} = POSIX::strftime "%T", localtime($working[1]);
				}
			}
		}
		elsif ( $working[0] eq 'sunset' ){
			if ($working[1]){
				if ($working[1] !~ /^[0-9]+$/){
					$weather{'sunset'} = $working[1];
				}
				# trying to figure out remote time from UTC is too hard
				elsif (!$show{'weather-location'}){
					$weather{'sunset'} = POSIX::strftime "%T", localtime($working[1]);
				}
			}
		}
		elsif ( $working[0] eq 'temperature_string' ){
			$weather{'temp'} = $working[1];
			$working[1] =~ /^([0-9\.]+)\sF\s\(([0-9\.]+)\sC\)/;
			$weather{'temp-c'} = $2;;
			$weather{'temp-f'} = $1;
# 			$weather{'temp'} =~ s/\sF/\xB0 F/; # B0
# 			$weather{'temp'} =~ s/\sF/\x{2109}/;
# 			$weather{'temp'} =~ s/\sC/\x{2103}/;
		}
		elsif ( $working[0] eq 'temp_f' ){
			$weather{'temp-f'} = $working[1];
		}
		elsif ( $working[0] eq 'temp_c' ){
			$weather{'temp-c'} = $working[1];
		}
		elsif ( $working[0] eq 'timezone' ){
			$weather{'timezone'} = $working[1];
		}
		elsif ( $working[0] eq 'visibility' ){
			$weather{'visibility'} = $working[1];
		}
		elsif ( $working[0] eq 'visibility_km' ){
			$weather{'visibility-km'} = $working[1];
		}
		elsif ( $working[0] eq 'visibility_mi' ){
			$weather{'visibility-mi'} = $working[1];
		}
		elsif ( $working[0] eq 'weather' ){
			$weather{'weather'} = $working[1];
		}
		elsif ( $working[0] eq 'wind_degrees' ){
			$weather{'wind-degrees'} = $working[1];
		}
		elsif ( $working[0] eq 'wind_dir' ){
			$weather{'wind-direction'} = $working[1];
		}
		elsif ( $working[0] eq 'wind_mph' ){
			$weather{'wind-mph'} = $working[1];
		}
		elsif ( $working[0] eq 'wind_gust_mph' ){
			$weather{'wind-gust-mph'} = $working[1];
		}
		elsif ( $working[0] eq 'wind_gust_ms' ){
			$weather{'wind-gust-ms'} = $working[1];
		}
		elsif ( $working[0] eq 'wind_ms' ){
			$weather{'wind-ms'} = $working[1];
		}
		elsif ( $working[0] eq 'wind_string' ){
			$weather{'wind'} = $working[1];
		}
		elsif ( $working[0] eq 'windchill_string' ){
			$weather{'windchill'} = $working[1];
			$working[1] =~ /^([0-9\.]+)\sF\s\(([0-9\.]+)\sC\)/;
			$weather{'windchill-c'} = $2;
			$weather{'windchill-f'} = $1;
		}
		elsif ( $working[0] eq 'windchill_c' ){
			$weather{'windchill-c'} = $working[1];
		}
		elsif ( $working[0] eq 'windchill_f' ){
			$weather{'windchill_f'} = $working[1];
		}
	}
	if ($show{'weather-location'}){
		if ($weather{'observation-time-local'} && 
		 $weather{'observation-time-local'} =~ /^(.*)\s([a-z_]+\/[a-z_]+)$/i){
			$tz = $2;
		}
		if (!$tz && $weather{'timezone'}){
			$tz = $weather{'timezone'};
			$weather{'observation-time-local'} .= ' (' . $weather{'timezone'} . ')' if $weather{'observation-time-local'};
		}
		# very clever trick, just make the system think it's in the 
		# remote timezone for this local block only
		local $ENV{'TZ'} = $tz if $tz; 
		$date_time = POSIX::strftime "%c", localtime();
		$date_time = test_locale_date($date_time,'','');
		$weather{'date-time'} = $date_time;
		# only wu has rfc822 value, and we want the original observation time then
		if ($weather{'observation-epoch'} && $tz){
			$date_time = POSIX::strftime "%Y-%m-%d %T ($tz %z)", localtime($weather{'observation-epoch'});
			$date_time = test_locale_date($date_time,$show{'weather-location'},$weather{'observation-epoch'});
			$weather{'observation-time-local'} = $date_time;
		}
	}
	else {
		$date_time = POSIX::strftime "%c", localtime();
		$date_time = test_locale_date($date_time,'','');
		$tz = ( $location[2] ) ? " ($location[2])" : ''; 
		$weather{'date-time'} = $date_time . $tz;
	}
	# we get the wrong time using epoch for remote -W location
	if ( !$show{'weather-location'} && $weather{'observation-epoch'}){
		$date_time = POSIX::strftime "%c", localtime($weather{'observation-epoch'});
		$date_time = test_locale_date($date_time,$show{'weather-location'},$weather{'observation-epoch'});
		$weather{'observation-time-local'} = $date_time;
	}
	eval $end if $b_log;
	return %weather;
}
sub download_weather {
	eval $start if $b_log;
	my ($now,$file_cached,@location) = @_;
	my (@weather,$temp,$ua,$url);
	$url = "https://smxi.org/opt/xr2.php?loc=$location[0]&src=$weather_source";
	$ua = 'weather';
# 		{
# 			#my $file2 = "$ENV{'HOME'}/bin/scripts/inxi/data/weather/weather-1.xml";
# 			# my $file2 = "$ENV{'HOME'}/bin/scripts/inxi/data/weather/feed-oslo-1.xml";
# 			local $/;
# 			my $file = "$ENV{'HOME'}/bin/scripts/inxi/data/weather/weather-1.xml";
# 			open my $fh, '<', $file or die "can't open $file: $!";
# 			$temp = <$fh>;
# 		}
	$temp = main::download_file('stdout',$url,'',$ua);
	@weather = split(/\n/, $temp) if $temp;
	unshift (@weather,("timestamp^^$now"));
	main::writer($file_cached,\@weather);
	#print "$file_cached: download/cleaned\n";
	eval $end if $b_log;
	return @weather;
}
# resolve wide character issue, if detected, switch to iso 
# date format, we won't try to be too clever here.
sub test_locale_date {
	my ($date_time,$location,$epoch) = @_;
	# $date_time .= 'дек';
	#print "1: $date_time\n";
	if ($date_time =~ m/[^\x00-\x7f]/){
		if (!$location && $epoch){
			$date_time = POSIX::strftime "%Y-%m-%d %H:%M:%S", localtime($epoch);
		}
		else {
			$date_time = POSIX::strftime "%Y-%m-%d %H:%M:%S", localtime();
		}
	}
	$date_time =~ s/\s+$//;
	#print "2: $date_time\n";
	return $date_time;
}
sub get_location {
	eval $start if $b_log;
	my ($city,$country,$freshness,%loc,$loc_arg,$loc_string,@loc_data,$state);
	my $now = POSIX::strftime "%Y%m%d%H%M", localtime;
	my $file_cached = "$user_data_dir/location-main.txt";
	if (-f $file_cached){
		@loc_data = main::reader($file_cached);
		$freshness = (split /\^\^/, $loc_data[0])[1];
	}
	if (!$freshness || $freshness < $now - 90) {
		my $temp;
		my $url = "http://geoip.ubuntu.com/lookup";
# 		{
# 			local $/;
# 			my $file = "$ENV{'HOME'}/bin/scripts/inxi/data/weather/location-1.xml";
# 			open my $fh, '<', $file or die "can't open $file: $!";
# 			$temp = <$fh>;
# 		}
		$temp  = main::download_file('stdout',$url);
		@loc_data = split /\n/, $temp;
		@loc_data = map {
		s/<\?.*<Response>//;
		s/<\/[^>]+>/\n/g;
		s/>/^^/g;
		s/<//g;
		$_;
		} @loc_data;
		@loc_data = split /\n/, $loc_data[0];
		unshift (@loc_data,("timestamp^^$now"));
		main::writer($file_cached,\@loc_data);
		#print "$file_cached: download/cleaned\n";
	}
	foreach (@loc_data){
		my @working = split /\s*\^\^\s*/,$_;
		#print "$working[0]:$working[1]\n";
		if ($working[0] eq 'CountryCode3' ) {
			$loc{'country3'} = $working[1];
		}
		elsif ($working[0] eq 'CountryCode' ) {
			$loc{'country'} = $working[1];
		}
		elsif ($working[0] eq 'CountryName' ) {
			$loc{'country2'} = $working[1];
		}
		elsif ($working[0] eq 'RegionCode' ) {
			$loc{'region-id'} = $working[1];
		}
		elsif ($working[0] eq 'RegionName' ) {
			$loc{'region'} = $working[1];
		}
		elsif ($working[0] eq 'City' ) {
			$loc{'city'} = $working[1];
		}
		elsif ($working[0] eq 'ZipPostalCode' ) {
			$loc{'zip'} = $working[1];
		}
		elsif ($working[0] eq 'Latitude' ) {
			$loc{'lat'} = $working[1];
		}
		elsif ($working[0] eq 'Longitude' ) {
			$loc{'long'} = $working[1];
		}
		elsif ($working[0] eq 'TimeZone' ) {
			$loc{'tz'} = $working[1];
		}
	}
	#print Data::Dumper::Dumper \%loc;
	# assign location, cascade from most accurate
	# latitude,longitude first
	if ($loc{'lat'} && $loc{'long'}){
		$loc_arg = "$loc{'lat'},$loc{'long'}";
	}
	# city,state next
	elsif ($loc{'city'} && $loc{'region-id'}){
		$loc_arg = "$loc{'city'},$loc{'region-id'}";
	}
	# postal code last, that can be a very large region
	elsif ($loc{'zip'}){
		$loc_arg = $loc{'zip'};
	}
	$country = ($loc{'country3'}) ? $loc{'country3'} : $loc{'country'};
	$city = ($loc{'city'}) ? $loc{'city'} : 'City N/A';
	$state = ($loc{'region-id'}) ? $loc{'region-id'} : 'Region N/A';
	$loc_string = main::apply_filter("$city, $state, $country");
	my @location = ($loc_arg,$loc_string,$loc{'tz'});
	#print ($loc_arg,"\n", join "\n", @loc_data, "\n",scalar @loc_data, "\n");
	eval $end if $b_log;
	return @location;
}
sub complete_location {
	eval $start if $b_log;
	my ($location,$city,$state,$country) = @_;
	if ($location && $location =~ /[0-9+-]/ && $city){
		$location = $country . ', ' . $location if $country && $location !~ m|$country|i;
		$location = $state . ', ' . $location if $state && $location !~ m|$state|i;
		$location = $city . ', ' . $location if $city && $location !~ m|$city|i;
	}
	eval $end if $b_log;
	return $location;
}
}

#### -------------------------------------------------------------------
#### UTILITIES FOR DATA LINES
#### -------------------------------------------------------------------

sub get_compiler_version {
	eval $start if $b_log;
	my (@compiler);
	if (my $file = system_files('version') ) {
		@compiler = get_compiler_version_linux($file);
	}
	elsif ($bsd_type) {
		@compiler = get_compiler_version_bsd();
	}
	eval $end if $b_log;
	return @compiler;
}

sub get_compiler_version_bsd {
	eval $start if $b_log;
	my (@compiler,@working);
	if ($alerts{'sysctl'}{'action'} && $alerts{'sysctl'}{'action'} eq 'use'){
		# for dragonfly, we will use free mem, not used because free is 0
		my @working;
		foreach (@sysctl){
			# freebsd seems to use bytes here
			# Not every line will have a : separator though the processor should make 
			# most have it. This appears to be 10.x late feature add, I don't see it
			# on earlier BSDs
			if (/^kern.compiler_version/){
				@working = split /:\s*/, $_;
				$working[1] =~ /.*(gcc|clang)\sversion\s([\S]+)\s.*/;
				@compiler = ($1,$2);
				last;
			}
		}
	}
	log_data('dump','@compiler',\@compiler) if $b_log;
	eval $end if $b_log;
	return @compiler;
}

sub get_compiler_version_linux {
	eval $start if $b_log;
	my ($file) = @_;
	my (@compiler,$version);
	my @data = reader($file);
	my $result = $data[0] if @data;
	if ($result){
		# $result = $result =~ /\*(gcc|clang)\*eval\*/;
		# $result='Linux version 5.4.0-rc1 (sourav@archlinux-pc) (clang version 9.0.0 (tags/RELEASE_900/final)) #1 SMP PREEMPT Sun Oct 6 18:02:41 IST 2019';
		#$result='Linux version 5.8.3-fw1 (fst@x86_64.frugalware.org) ( OpenMandriva 11.0.0-0.20200819.1 clang version 11.0.0 (/builddir/build/BUILD/llvm-project-release-11.x/clang 2a0076812cf106fcc34376d9d967dc5f2847693a), LLD 11.0.0)';
		#$result='Linux version 5.8.0-18-generic (buildd@lgw01-amd64-057) (gcc (Ubuntu 10.2.0-5ubuntu2) 10.2.0, GNU ld (GNU Binutils for Ubuntu) 2.35) #19-Ubuntu SMP Wed Aug 26 15:26:32 UTC 2020';
		# $result='Linux version 5.8.9-fw1 (fst@x86_64.frugalware.org) (gcc (Frugalware Linux) 9.2.1 20200215, GNU ld (GNU Binutils) 2.35) #1 SMP PREEMPT Tue Sep 15 16:38:57 CEST 2020';
		# $result='Linux version 5.8.0-2-amd64 (debian-kernel@lists.debian.org) (gcc-10 (Debian 10.2.0-9) 10.2.0, GNU ld (GNU Binutils for Debian) 2.35) #1 SMP Debian 5.8.10-1 (2020-09-19)';
		if ($result =~ /(gcc|clang).*version\s([\S]+)/){
			$version = $2;
			$version ||= 'N/A'; 
			@compiler = ($1,$version);
		}
		elsif ($result =~ /\((gcc|clang)[^\(]*\([^\)]+\)\s+([0-9\.]+)(\s[^.]*)?,\s*/){
			$version = $2;
			$version ||= 'N/A'; 
			@compiler = ($1,$version);
		}
	}
	log_data('dump','@compiler',\@compiler) if $b_log;
	eval $end if $b_log;
	return @compiler;
}

## Get DesktopEnvironment
## returns array:
# 0 - desktop name
# 1 - version
# 2 - toolkit
# 3 - toolkit version
# 4 - info extra desktop data
# 5 - wm
# 6 - wm version
{
package DesktopEnvironment;
my ($b_gtk,$b_qt,$b_xprop,$desktop_session,$gdmsession,$kde_session_version,
$xdg_desktop,@desktop,@data,@xprop);
sub get {
	eval $start if $b_log;
	set_desktop_values();
	main::set_ps_gui() if ! $b_ps_gui;
	get_kde_trinity_data();
	if (!@desktop){
		get_env_de_data();
	}
	if (!@desktop){
		get_env_xprop_gnome_based_data();
	}
	if (!@desktop && $b_xprop ){
		get_env_xprop_non_gnome_based_data();
	}
	if (!@desktop){
		get_ps_de_data();
	}
	if ($extra > 2 && @desktop){
		set_info_data();
	}
	if ($b_display && !$b_force_display && $extra > 1){
		get_wm();
	}
	set_gtk_data() if $b_gtk && $extra > 1;
	set_qt_data() if $b_qt && $extra > 1;
	main::log_data('dump','@desktop', \@desktop) if $b_log;
	# ($b_xprop,$kde_session_version,$xdg_desktop,@data,@xprop) = undef;
	eval $end if $b_log;
	return @desktop;
}
sub set_desktop_values {
	# NOTE $XDG_CURRENT_DESKTOP envvar is not reliable, but it shows certain desktops better.
	# most desktops are not using it as of 2014-01-13 (KDE, UNITY, LXDE. Not Gnome)
	$desktop_session = ( $ENV{'DESKTOP_SESSION'} ) ? prep_desktop_value($ENV{'DESKTOP_SESSION'}) : '';
	$xdg_desktop = ( $ENV{'XDG_CURRENT_DESKTOP'} ) ? prep_desktop_value($ENV{'XDG_CURRENT_DESKTOP'}) : '';
	$kde_session_version = ($ENV{'KDE_SESSION_VERSION'}) ? $ENV{'KDE_SESSION_VERSION'} : '';
	# for fallback to fallback protections re false gnome id
	$gdmsession = ( $ENV{'GDMSESSION'} ) ? prep_desktop_value($ENV{'GDMSESSION'}) : '';
}
# note: an ubuntu regresssion replaces or adds 'ubuntu' string to 
# real value. Since ubuntu is the only distro I know that does this, 
# will add more distro type filters as/if we come across them
sub prep_desktop_value {
	$_[0] = lc(main::trimmer($_[0]));
	$_[0] =~ s/\b(arch|debian|fedora|manjaro|mint|opensuse|ubuntu):?\s*//;
	return $_[0];
}
sub get_kde_trinity_data {
	eval $start if $b_log;
	my ($program,@version_data,@version_data2);
	my $kde_full_session = ($ENV{'KDE_FULL_SESSION'}) ? $ENV{'KDE_FULL_SESSION'} : '';
	if ($desktop_session eq 'trinity' || $xdg_desktop eq 'trinity' || (grep {/^tde/} @ps_gui) ){
		$desktop[0] = 'Trinity';
		if ($program = main::check_program('kdesktop')){
			@version_data = main::grabber("$program --version 2>/dev/null");
			$desktop[1] = main::awk(\@version_data,'^TDE:',2,'\s+') if @version_data;
		}
		if ($extra > 1 && @version_data){
			$desktop[2] = 'Qt';
			$desktop[3] = main::awk(\@version_data,'^Qt:',2,'\s+') if @version_data;
		}
	}
	# works on 4, assume 5 will id the same, why not, no need to update in future
	# KDE_SESSION_VERSION is the integer version of the desktop
	# NOTE: as of plasma 5, the tool: about-distro MAY be available, that will show
	# actual desktop data, so once that's in debian/ubuntu, if it gets in, add that test
	elsif ( $xdg_desktop eq 'kde' || $kde_session_version ){
		if ($kde_session_version && $kde_session_version <= 4){
			@data = main::program_values("kded$kde_session_version");
			if (@data){
				$desktop[0] = $data[3];
				$desktop[1] = main::program_version("kded$kde_session_version",$data[0],$data[1],$data[2],$data[5],$data[6]);
				# kded exists, so we can now get the qt data string as well
				if ($desktop[1] && ($program = main::check_program("kded$kde_session_version")) ){
					@version_data = main::grabber("$program --version 2>/dev/null");
				}
			}
			$desktop[0] = 'KDE' if !$desktop[0];
		}
		else {
			# NOTE: this command string is almost certain to change, and break, with next 
			# major plasma desktop, ie, 6. 
			# qdbus org.kde.plasmashell /MainApplication org.qtproject.Qt.QCoreApplication.applicationVersion
			# Qt: 5.4.2
			# KDE Frameworks: 5.11.0
			# kf5-config: 1.0
			# for QT, and Frameworks if we use it
			if (!@version_data && ($program = main::check_program("kf$kde_session_version-config") )){
				@version_data = main::grabber("$program --version 2>/dev/null");
			}
			if (!@version_data && ($program = main::check_program("kded$kde_session_version"))){
				@version_data = main::grabber("$program --version 2>/dev/null");
			}
			if ($program = main::check_program("plasmashell")){
				@version_data2 = main::grabber("$program --version 2>/dev/null");
				$desktop[1] = main::awk(\@version_data2,'^plasmashell',-1,'\s+');
			}
			$desktop[0] = 'KDE Plasma';
		}
		if (!$desktop[1]){
			$desktop[1] = ($kde_session_version) ? $kde_session_version: main::row_defaults('unknown-desktop-version');
		}
		# print Data::Dumper::Dumper \@version_data;
		if ($extra > 1){
			if (@version_data){
				$desktop[3] = main::awk(\@version_data,'^Qt:', 2,'\s+');
			}
			# qmake can have variants, qt4-qmake, qt5-qmake, also qt5-default but not tested
			if (!$desktop[3] && main::check_program("qmake")){
				# note: this program has issues, it may appear to be in /usr/bin, but it 
				# often fails to execute, so the below will have null output, but use as a 
				# fall back test anyway.
				($desktop[2],$desktop[3]) = main::program_data('qmake');
			}
			$desktop[2] ||= 'Qt';
		}
	}
	# KDE_FULL_SESSION property is only available since KDE 3.5.5.
	elsif ($kde_full_session eq 'true'){
		@version_data = main::grabber("kded --version 2>/dev/null");
		$desktop[0] = 'KDE';
		$desktop[1] = main::awk(\@version_data,'^KDE:',2,'\s+') if @version_data;
		if (!$desktop[1]){
			$desktop[1] = '3.5';
		}
		if ($extra > 1 && @version_data){
			$desktop[2] = 'Qt';
			$desktop[3] = main::awk(\@version_data,'^Qt:',2,'\s+') if @version_data;
		}
	}
	eval $end if $b_log;
}
sub get_env_de_data {
	eval $start if $b_log;
	my ($program,@version_data);
	if (!$desktop[0]){
		# 0: 1/0; 1: env var search; 2: data; 3: gtk tk; 4: qt tk; 5: ps_gui search
		my @desktops =(
		[1,'unity','unity',0,0],
		[0,'budgie','budgie-desktop',0,0],
		# debian package: lxde-core. 
		# NOTE: some distros fail to set XDG data for root
		[1,'lxde','lxpanel',0,0,',^lxsession$'],
		[1,'razor','razor-session',0,1,'^razor-session$'],
		# BAD: lxqt-about opens dialogue, sigh. 
		# Checked, lxqt-panel does show same version as lxqt-about
		[1,'lxqt','lxqt-panel',0,1,'^lxqt-session$'],
		[0,'^(razor|lxqt)$','lxqt-variant',0,1,'^(razor-session|lxqt-session)$'],
		# note, X-Cinnamon value strikes me as highly likely to change, so just 
		# search for the last part
		[0,'cinnamon','cinnamon',1,0],
		# these so far have no cli version data
		[1,'deepin','deepin',0,1], # version comes from file read
		[1,'pantheon','pantheon',0,0],
		[1,'lumina','lumina-desktop',0,1],
		[0,'manokwari','manokwari',1,0],
		[1,'ukui','ukui-session',0,1],
		);
		foreach my $item (@desktops){
			# Check if in xdg_desktop OR desktop_session OR if in $item->[6] and in ps_gui
			if ( (($item->[0] && ($xdg_desktop eq $item->[1] || $desktop_session eq $item->[1] )) ||
			   (!$item->[0] && ($xdg_desktop =~ /$item->[1]/ || $desktop_session  =~ /$item->[1]/ )) ) ||
			   ($item->[5] && @ps_gui && (grep {/$item->[5]/} @ps_gui) ) ){
				($desktop[0],$desktop[1]) = main::program_data($item->[2]);
				$b_gtk = $item->[3];
				$b_qt = $item->[4];
				last;
			}
		}
	}
	eval $end if $b_log;
}
sub get_env_xprop_gnome_based_data {
	eval $start if $b_log;
	my ($program,$value,@version_data);
	# NOTE: Always add to set_prop the search term if you add an item!!
	set_xprop();
	# add more as discovered
	return if $xdg_desktop eq 'xfce' || $gdmsession eq 'xfce';
	# note that cinnamon split from gnome, and and can now be id'ed via xprop,
	# but it will still trigger the next gnome true case, so this needs to go 
	# before gnome test eventually this needs to be better organized so all the 
	# xprop tests are in the same section, but this is good enough for now.
	# NOTE: was checking for 'muffin' but that's not part of cinnamon
	if ( $xdg_desktop eq 'cinnamon' || $gdmsession eq 'cinnamon' || 
	 (main::check_program('muffin') || main::check_program('cinnamon-session') ) && 
	     ($b_xprop && main::awk(\@xprop,'_muffin') )){
		($desktop[0],$desktop[1]) = main::program_data('cinnamon','cinnamon',0);
		$b_gtk = 1;
		$desktop[0] ||= 'Cinnamon';
	}
	elsif ($xdg_desktop eq 'mate' || $gdmsession eq 'mate' || 
	 ( $b_xprop && main::awk(\@xprop,'_marco') )){
		# NOTE: mate-about and mate-sesssion vary which has the higher number, neither 
		# consistently corresponds to the actual MATE version, so check both.
		my %versions = ('mate-about' => '','mate-session' => '');
		foreach my $key (keys %versions){
			if ($program = main::check_program($key) ) {
				@data = main::program_data($key,$program,0);
				$desktop[0] = $data[0];
				$versions{$key} = $data[1];
			}
		}
		# no consistent rule about which version is higher, so just compare them and take highest
		$desktop[1] = main::compare_versions($versions{'mate-about'},$versions{'mate-session'});
		# $b_gtk = 1;
		$desktop[0] ||= 'MATE';
	}
	# See sub for logic and comments
	elsif (check_gnome() ){
		if (main::check_program('gnome-about') ) {
			($desktop[0],$desktop[1]) = main::program_data('gnome-about');
		}
		elsif (main::check_program('gnome-shell') ) {
			($desktop[0],$desktop[1]) = main::program_data('gnome','gnome-shell');
		}
		$b_gtk = 1;
		$desktop[0] ||= 'GNOME';
	}
	eval $end if $b_log;
}
# note, GNOME_DESKTOP_SESSION_ID is deprecated so we'll see how that works out
# https://bugzilla.gnome.org/show_bug.cgi?id=542880.
# NOTE: manjaro is leaving XDG data null, which forces the manual check for gnome, sigh...
# some gnome programs can trigger a false xprop gnome ID
# _GNOME_BACKGROUND_REPRESENTATIVE_COLORS(STRING) = "rgb(23,31,35)"
sub check_gnome {
	eval $start if $b_log;
	my ($b_gnome,$detection) = (0,'');
	if ($xdg_desktop && $xdg_desktop =~ /gnome/){
		$detection = 'xdg_current_desktop';
		$b_gnome = 1;
	}
	# should work as long as string contains gnome, eg: peppermint:gnome 
	# filtered explicitly in set_desktop_values
	elsif ($xdg_desktop && $xdg_desktop !~ /gnome/){
		$detection = 'xdg_current_desktop';
	}
	# possible values: lightdm-xsession, only positive match tests will work
	elsif ($gdmsession && $gdmsession eq 'gnome'){
		$detection = 'gdmsession';
		$b_gnome = 1;
	}
	# risky: Debian: $DESKTOP_SESSION = lightdm-xsession; Manjaro/Arch = xfce
	# note that mate/cinnamon would already have been caught so no need to add 
	# explicit tests for them
	elsif ($desktop_session && $desktop_session eq 'gnome'){
		$detection = 'desktop_session';
		$b_gnome = 1;
	}
	# possible value: this-is-deprecated, but I believe only gnome based desktops
	# set this variable, so it doesn't matter what it contains
	elsif ($ENV{'GNOME_DESKTOP_SESSION_ID'}){
		$detection = 'gnome_destkop_session_id';
		$b_gnome = 1;
	}
	# maybe use ^_gnome_session instead? try it for a while
	elsif ($b_xprop && main::check_program('gnome-shell') && main::awk(\@xprop,'^_gnome_session')){
		$detection = 'xprop-root';
		$b_gnome = 1;
	}
	
	main::log_data('data','$detection:$b_gnome>>' . $detection . ":$b_gnome") if $b_log;
	eval $end if $b_log;
	return $b_gnome;
}
sub get_env_xprop_non_gnome_based_data {
	eval $start if $b_log;
	my ($program,@version_data,$version);
	#print join "\n", @xprop, "\n";
	# String: "This is xfdesktop version 4.2.12"
	# alternate: xfce4-about --version > xfce4-about 4.10.0 (Xfce 4.10)
	# note: some distros/wm (e.g. bunsen) set xdg to xfce to solve some other 
	# issues so don't test for that. $xdg_desktop eq 'xfce'
	if ($xdg_desktop eq 'xfce' || $gdmsession eq 'xfce' || 
	 (main::check_program('xfdesktop')) && main::awk(\@xprop,'^(xfdesktop|xfce)' )){
		# this is a very expensive test that doesn't usually result in a find
		# talk to xfce to see what id they will be using for xfce 5
# 		if (main::awk(\@xprop, 'xfce4')){
# 			$version = '4';
# 		}
		if (main::awk(\@xprop, 'xfce5')){
			$version = '5';
		}
		else {
 			$version = '4';
		}
		@data = main::program_values('xfdesktop');
		$desktop[0] = $data[3];
		# xfdesktop --version out of x fails to get display, so no data
		@version_data = main::grabber('xfdesktop --version 2>/dev/null');
		# out of x, this error goes to stderr, so it's an empty result
		$desktop[1] = main::awk(\@version_data,$data[0],$data[1],'\s+');
		#$desktop[1] = main::program_version('xfdesktop',$data[0],$data[1],$data[2],$data[5],$data[6]);
		if ( !$desktop[1] ){
			@data = main::program_values("xfce${version}-panel");
			# print Data::Dumper::Dumper \@data;
			# this returns an error message to stdout in x, which breaks the version
			# xfce4-panel --version out of x fails to get display, so no data
			$desktop[1] = main::program_version("xfce${version}-panel",$data[0],$data[1],$data[2],$data[5],$data[6]);
			# out of x this kicks out an error: xfce4-panel: Cannot open display
			$desktop[1] = '' if $desktop[1] !~ /[0-9]\./; 
		}
		$desktop[0] ||= 'Xfce';
		$desktop[1] ||= ''; # xfce isn't going to be 4 forever
		if ($extra > 1){
			@data = main::program_values('xfdesktop-toolkit');
			#$desktop[3] = main::program_version('xfdesktop',$data[0],$data[1],$data[2],$data[5],$data[6]);
			$desktop[3] = main::awk(\@version_data,$data[0],$data[1],'\s+');
			$desktop[2] = $data[3];
		}
	}
	elsif ( $xdg_desktop eq 'moksha' || $gdmsession eq 'moksha' || 
	 (main::check_program('enlightenment') || main::check_program('moksha') ) && main::awk(\@xprop,'moksha') ){
		# no -v or --version but version is in xprop -root
		# ENLIGHTENMENT_VERSION(STRING) = "Moksha 0.2.0.15989"
		$desktop[0] = 'Moksha';
		$desktop[1] = main::awk(\@xprop,'(enlightenment|moksha)_version',2,'\s+=\s+' );
		$desktop[1] =~ s/"?(Moksha|Enlightenment)\s([^"]+)"?/$2/i if $desktop[1];
	}
	elsif ( $xdg_desktop eq 'enlightenment' || $gdmsession eq 'enlightenment' || 
	 (main::check_program('enlightenment') && main::awk(\@xprop,'enlightenment' ) ) ){
		# no -v or --version but version is in xprop -root
		# ENLIGHTENMENT_VERSION(STRING) = "Enlightenment 0.16.999.49898"
		$desktop[0] = 'Enlightenment';
		$desktop[1] = main::awk(\@xprop,'(enlightenment|moksha)_version',2,'\s+=\s+' );
		$desktop[1] =~ s/"?(Moksha|Enlightenment)\s([^"]+)"?/$2/i if $desktop[1];
	}
	# the sequence here matters, some desktops like icewm, razor, let you set different 
	# wm, so we want to get the main controlling desktop first, then fall back to the wm
	# detections. get_ps_de_data() and get_wm() will handle alternate wm detections.
	if (!$desktop[0]){
		# 0 check program; 1 xprop search; 2: data; 3 - optional: ps_gui search
		my @desktops =(
		['icewm','icewm','icewm'],
		# debian package: i3-wm
		['i3','i3','i3'],
		['mwm','^_motif','mwm'],
		# debian package name: wmaker
		['WindowMaker','^_?windowmaker','wmaker'],
		['wm2','^_wm2','wm2'],
		['herbstluftwm','herbstluftwm','herbstluftwm'],
		['fluxbox','blackbox_pid','fluxbox','^fluxbox$'],
		['blackbox','blackbox_pid','blackbox'],
		['openbox','openbox_pid','openbox'],
		['amiwm','amiwm','amiwm'],
		);
		foreach my $item (@desktops){
			if (main::check_program($item->[0]) && main::awk(\@xprop,$item->[1]) && 
			    (!$item->[4] || (@ps_gui && (grep {/$item->[4]/} @ps_gui ))) ){
				($desktop[0],$desktop[1]) =  main::program_data($item->[2]);
				last;
			}
		}
	}
	# need to check starts line because it's so short
	eval $end if $b_log;
}
sub get_ps_de_data {
	eval $start if $b_log;
	my ($program,@version_data);
	main::set_ps_gui() if !$b_ps_gui;
	if (@ps_gui){
		# 1 check program; 2 ps_gui search; 3 data; 4: trigger alternate values/version
		my @desktops =(
		['9wm','9wm','9wm',''],
		['afterstep','afterstep','afterstep',''],
		['aewm++','aewm\+\+','aewm++',''],
		['aewm','aewm','aewm',''],
		['amiwm','amiwm','amiwm',''],
		['antiwm','antiwm','antiwm',''],
		['awesome','awesome','awesome',''],
		['blackbox','blackbox','blackbox',''],
		['bspwm','bspwm','bspwm',''],
		['cagebreak','cagebreak','cagebreak',''],
		['calmwm','calmwm','calmwm',''],
		['clfswm','.*(sh|c?lisp)?.*clfswm','clfswm',''],
		['cwm','(openbsd-)?cwm','cwm',''],
		['dwm','dwm','dwm',''],
		['echinus','echinus','echinus',''],
		['evilwm','evilwm','evilwm',''],
		['fireplace','fireplace','fireplace',''],
		['fluxbox','fluxbox','fluxbox',''],
		['flwm','flwm','flwm',''],
		['flwm','flwm_topside','flwm',''],
		['fvwm-crystal','fvwm.*-crystal','fvwm-crystal','fvwm'],
		['fvwm1','fvwm1','fvwm1',''],
		['fvwm2','fvwm2','fvwm2',''],
		['fvwm3','fvwm3','fvwm3',''],
		['fvwm95','fvwm95','fvwm95',''],
		['fvwm','fvwm','fvwm',''],
		['glass','glass','glass',''],
		['hackedbox','hackedbox','hackedbox',''],
		['instantwm','instantwm','instantwm',''],
		['ion3','ion3','ion3',''],
		['jbwm','jbwm','jbwm',''],
		['jwm','jwm','jwm',''],
		['larswm','larswm','larswm',''],
		['lwm','lwm','lwm',''],
		['mini','mini','mini',''],
		['musca','musca','musca',''],
		['mvwm','mvwm','mvwm',''],
		['mwm','mwm','mwm',''],
		['nawm','nawm','nawm',''],
		['notion','notion','notion',''],
		['openbox','openbox','openbox',''],
		['orbital','orbital','orbital',''],
		['pekwm','pekwm','pekwm',''],
		['perceptia','perceptia','perceptia',''],
		['qtile','.*(python.*)?qtile','qtile',''],
		['qvwm','qvwm','qvwm',''],
		['ratpoison','ratpoison','ratpoison',''],
		['sawfish','sawfish','sawfish',''],
		['scrotwm','scrotwm','scrotwm',''],
		['spectrwm','spectrwm','spectrwm',''],
		['stumpwm','(sh|c?lisp)?.*stumpwm','stumpwm',''],
		['sway','sway','sway',''],
		['matchbox-window-manager','matchbox-window-manager','matchbox-window-manager',''],
		['tinywm','tinywm','tinywm',''],
		['tvtwm','tvtwm','tvtwm',''],
		['twm','twm','twm',''],
		['waycooler','waycooler','way-cooler',''],
		['way-cooler','way-cooler','way-cooler',''],
		['WindowMaker','WindowMaker','wmaker',''],
		['windowlab','windowlab','windowlab',''],
		# not in debian apt, current is wmii, version 3
		['wmii2','wmii2','wmii2',''],
		['wmii','wmii','wmii',''],
		['wmx','wmx','wmx',''],
		['xmonad','xmonad','xmonad',''],
		## fallback for xfce in case no xprop 
		['xfdesktop','xfdesktop','xfdesktop',''],
		['yeahwm','yeahwm','yeahwm',''],
		);
		foreach my $item (@desktops){
			# no need to use check program with short list of ps_gui
			if (grep {/^$item->[1]$/} @ps_gui){
				($desktop[0],$desktop[1]) =  main::program_data($item->[2],$item->[3]);
				if ($extra > 1 && $item->[0] eq 'xfdesktop'){
					($desktop[2],$desktop[3]) =  main::program_data('xfdesktop-toolkit',$item->[0],1);
				}
				last;
			}
		}
	}
	eval $end if $b_log;
}
# NOTE: used to use a super slow method here, but gtk-launch returns
# the gtk version I believe
sub set_gtk_data {
	eval $start if $b_log;
	if (main::check_program('gtk-launch')){
		($desktop[2],$desktop[3]) = main::program_data('gtk-launch');
	}
	eval $end if $b_log;
}
sub set_qt_data {
	eval $start if $b_log;
	my ($program,@data,@version_data);
	my $kde_version = $kde_session_version;
	$program = '';
	if (!$kde_version){
		if ($program = main::check_program("kded6") ){$kde_version = 6;}
		elsif ($program = main::check_program("kded5") ){$kde_version = 5;}
		elsif ($program = main::check_program("kded4") ){$kde_version = 4;}
		elsif ($program = main::check_program("kded") ){$kde_version = '';}
	}
	# alternate: qt4-default, qt4-qmake or qt5-default, qt5-qmake
	# often this exists, is executable, but actually is nothing, shows error
	if (!$desktop[3] && main::check_program('qmake')){
		($desktop[2],$desktop[3]) = main::program_data('qmake');
	}
	if (!$desktop[3] && main::check_program('qtdiag')){
		($desktop[2],$desktop[3]) = main::program_data('qtdiag');
	}
	if (!$desktop[3] && ($program = main::check_program("kf$kde_version-config") )){
		@version_data = main::grabber("$program --version 2>/dev/null");
		$desktop[2] = 'Qt';
		$desktop[3] = main::awk(\@version_data,'^Qt:',2) if @version_data;
	}
	# note: qt 5 does not show qt version in kded5, sigh
	if (!$desktop[3] && ($program = main::check_program("kded$kde_version"))){
		@version_data = main::grabber("$program --version 2>/dev/null");
		$desktop[2] = 'Qt';
		$desktop[3] = main::awk(\@version_data,'^Qt:',2) if @version_data;
	}
	eval $end if $b_log;
}

sub get_wm {
	eval $start if $b_log;
	if (!$b_wmctrl) {
		get_wm_main();
	}
	# note, some wm, like cinnamon muffin, do not appear in ps aux, but do in wmctrl
	if ( (!$desktop[5] || $b_wmctrl) && (my $program = main::check_program('wmctrl'))){
		get_wm_wmctrl($program);
	}
	eval $end if $b_log;
}
sub get_wm_main {
	eval $start if $b_log;
	my ($wms,$working);
	# xprop is set only if not kde/gnome/cinnamon/mate/budgie/lx..
	if ($b_xprop){
		#KWIN_RUNNING
		$wms = 'amiwm|blackbox|bspwm|compiz|kwin_wayland|kwin_x11|kwin|marco|';
		$wms .= 'motif|muffin|openbox|herbstluftwm|twin|ukwm|wm2|windowmaker|i3';
		foreach (@xprop){
			if (/($wms)/){
				$working = $1;
				$working = 'wmaker' if $working eq 'windowmaker';
				last;
			}
		}
	}
	if (!$desktop[5]){
		main::set_ps_gui() if ! $b_ps_gui;
		# order matters, see above logic
		# due to lisp/python starters, clfswm/stumpwm/qtile will not detect here
		$wms = '9wm|aewm\+\+|aewm|afterstep|amiwm|antiwm|awesome|blackbox|bspwm|budgie-wm|';
		$wms .= 'cagebreak|calmwm|clfswm|compiz|(openbsd-)?cwm|fluxbox|';
		$wms .= 'deepin-wm|dwm|echinus|evilwm|';
		$wms .= 'fireplace|flwm|fvwm-crystal|fvwm1|fvwm2|fvwm3|fvwm95|fvwm|';
		$wms .= 'gala|glass|gnome-shell|hackedbox|i3|instantwm|ion3|jbwm|jwm|';
		$wms .= 'twin|kwin_wayland|kwin_x11|kwin|larswm|lwm|';
		$wms .= 'matchbox-window-manager|marco|mini|muffin|';
		$wms .= 'musca|deepin-mutter|mutter|deepin-metacity|metacity|mvwm|mwm|';
		$wms .= 'nawm|notion|openbox|orbital|perceptia|qtile|qvwm|';
		$wms .= 'ratpoison|sawfish|scrotwm|spectrwm|';
		$wms .= 'stumpwm|sway|tinywm|tvtwm|twm|ukwm|';
		$wms .= 'way-?cooler|windowlab|WindowMaker|wm2|wmii2|wmii|wmx|';
		$wms .= 'xfwm4|xfwm5|xmonad|yeahwm';
		foreach (@ps_gui){
			if (/^($wms)$/){
				$working = $1;
				last;
			}
		}
	}
	get_wm_version('manual',$working) if $working;
	$desktop[5] = $working if !$desktop[5] && $working;
	eval $end if $b_log;
}
sub get_wm_wmctrl {
	eval $start if $b_log;
	my ($program) = @_;
	my $cmd = "$program -m 2>/dev/null";
	my @data = main::grabber($cmd,'','strip');
	main::log_data('dump','@data',\@data) if $b_log;
	$desktop[5] = main::awk(\@data,'^Name',2,'\s*:\s*');
	$desktop[5] = '' if $desktop[5] && $desktop[5] eq 'N/A';
	if ($desktop[5]){
		# variants: gnome shell; 
		# IceWM 1.3.8 (Linux 3.2.0-4-amd64/i686) ; Metacity (Marco) ; Xfwm4
		$desktop[5] =~ s/\d+\.\d\S+|[\[\(].*\d+\.\d.*[\)\]]//g;
		$desktop[5] = main::trimmer($desktop[5]);
		# change Metacity (Marco) to marco
		if ($desktop[5] =~ /marco/i) {$desktop[5] = 'marco'}
		elsif ($desktop[5] =~ /muffin/i) {$desktop[5] = 'muffin'}
		elsif (lc($desktop[5]) eq 'gnome shell') {$desktop[5] = 'gnome-shell'}
		elsif ($desktop_session eq 'trinity' && lc($desktop[5]) eq 'kwin') {$desktop[5] = 'Twin'}
		get_wm_version('wmctrl',$desktop[5]);
	}
	eval $end if $b_log;
}
sub get_wm_version {
	eval $start if $b_log;
	my ($type,$wm) = @_;
	# we don't want the gnome-shell version, and the others have no --version
	# we also don't want to run --version again on stuff we already have tested
	return if ! $wm || $wm =~ /^(budgie-wm|gnome-shell)$/ || ($desktop[0] && lc($desktop[0]) eq lc($wm) );
	my $temp = (split /\s+/, $wm)[0];
	if ($temp){
		$temp = (split /\s+/, $temp)[0];
		$temp = lc($temp);
		$temp = 'wmaker' if $temp eq 'windowmaker';
		my @data = main::program_data($temp,$temp,3);
		return if !$data[0];
		# print Data::Dumper::Dumper \@data;
		$desktop[5] = $data[0] if $type eq 'manual';
		$desktop[6] = $data[1] if $data[1];
	}
	eval $end if $b_log;
}

sub set_info_data {
	eval $start if $b_log;
	main::set_ps_gui() if ! $b_ps_gui;
	my (@data,@info,$item);
	my $pattern = 'alltray|awn|bar|bmpanel|bmpanel2|budgie-panel|cairo-dock|';
	$pattern .= 'dde-dock|dmenu|dockbarx|docker|docky|dzen|dzen2|';
	$pattern .= 'fancybar|fbpanel|fspanel|glx-dock|gnome-panel|hpanel|i3bar|i3status|icewmtray|';
	$pattern .= 'kdocker|kicker|';
	$pattern .= 'latte|latte-dock|lemonbar|ltpanel|lxpanel|lxqt-panel|';
	$pattern .= 'matchbox-panel|mate-panel|ourico|';
	$pattern .= 'perlpanel|plank|plasma-desktop|plasma-netbook|polybar|pypanel|';
	$pattern .= 'razor-panel|razorqt-panel|stalonetray|swaybar|taskbar|tint2|trayer|';
	$pattern .= 'ukui-panel|vala-panel|wbar|wharf|wingpanel|witray|';
	$pattern .= 'xfce4-panel|xfce5-panel|xmobar|yabar';
	if (@data = grep {/^($pattern)$/} @ps_gui ) {
		# only one entry per type, can be multiple
		foreach $item (@data){
			if (! grep {$item =~ /$_/} @info){
				$item = main::trimmer($item);
				$item =~ s/.*\///;
				push @info, (split /\s+/, $item)[0];
			}
		}
	}
	if (@info){
		@info = main::uniq(@info);
		$desktop[4] = join (', ', @info);
	}
	eval $end if $b_log;
}

sub set_xprop {
	eval $start if $b_log;
	if (my $program = main::check_program('xprop')){
		@xprop = main::grabber("xprop -root $display_opt 2>/dev/null");
		if (@xprop){
			# add wm / de as required, but only add what is really tested for above
			# XFDESKTOP_IMAGE_FILE; XFCE_DESKTOP
			my $pattern = '^amiwm|blackbox_pid|bspwm|compiz|enlightenment|^_gnome|';
			$pattern .= 'herbstluftwm|^kwin_|^i3_|icewm|_marco|moksha|^_motif|_muffin|';
			$pattern .= 'openbox_pid|^_ukwm|^_?windowmaker|^_wm2|^(xfdesktop|xfce)';
			# let's only do these searches once
			@xprop = grep {/^\S/ && /($pattern)/i} @xprop;
			$_ = lc for @xprop;
			$b_xprop = 1 if scalar @xprop > 0;
		}
	}
	# print "@xprop\n";
	eval $end if $b_log;
}

}

sub get_display_manager {
	eval $start if $b_log;
	my (@data,@found,$path,$working,$b_run,$b_vrun,$b_vrunrc);
	# ldm - LTSP display manager. Note that sddm does not appear to have a .pid 
	# extension in Arch note: to avoid positives with directories, test for -f 
	# explicitly, not -e. Guessing on cdm.pid
	my @dms = qw(cdm.pid entranced.pid gdm.pid gdm3.pid kdm.pid ldm.pid 
	lightdm.pid lxdm.pid mdm.pid nodm.pid pcdm.pid sddm.pid slim.lock 
	tdm.pid udm.pid wdm.pid xdm.pid xenodm.pid);
	# these are the only one I know of so far that have version info
	my @dms_version = qw(gdm gdm3 lightdm slim);
	$b_run = 1 if -d "/run";
	# in most linux, /var/run is a sym link to /run, so no need to check it twice
	if ( -d "/var/run" ){
		my $rdlink = readlink('/var/run');
		$b_vrun = 1 if !$rdlink || ($rdlink && $rdlink ne '/run');
		$b_vrunrc = 1 if -d "/var/run/rc.d";
	}
	foreach my $id (@dms){
		# note: $working will create a dir name out of the dm $id, then 
		# test if pid is in that note: sddm, in an effort to be unique and special, 
		# do not use a pid/lock file, but rather a random string inside a directory 
		# called /run/sddm/ so assuming the existence of the pid inside a directory named
		# from the dm. Hopefully this change will not have negative results.
		$working = $id;
		$working =~ s/\.\S+$//;
		# note: there were issues with duplicated dm's in inxi, checking @found corrects it
		if ( ( ( $b_run && ( -f "/run/$id" || -d "/run/$working" ) ) || 
		   ( $b_vrun && ( -f "/var/run/$id" || -d "/var/run/$working" ) ) || 
		   ( $b_vrunrc && ( -f "/var/run/rc.d/$working" || -d "/var/run/rc.d/$id" ) ) ) && 
		   ! grep {/$working/} @found ){
			if ($extra > 2 && awk( \@dms_version, $working) && ($path = check_program($working)) ){}
			else {$path = $working;}
			# print "$path $extra\n";
			@data = program_data($working,$path,3);
			$working = $data[0];
			$working .= ' ' . $data[1] if $data[1];
			push @found, $working;
		}
	}
	if (!@found){
		# ly does not have a run/pid file
		if (grep {$_ eq 'ly'} @ps_gui) {
			@data = program_data('ly','ly',3);
			$found[0] = $data[0];
			$found[0] .= ' ' . $data[1] if $data[1];
		}
		elsif (grep {/startx$/} @ps_gui) {
			$found[0] = 'startx';
		}
		elsif (grep {$_ eq 'xinit'} @ps_gui) {
			$found[0] = 'xinit';
		}
	}
	# might add this in, but the rate of new dm's makes it more likely it's an 
	# unknown dm, so we'll keep output to N/A
	log_data('dump','display manager: @found',\@found) if $b_log;
	eval $end if $b_log;
	return join ', ', @found if @found;
}

## Get DistroData
{
package DistroData;
my (@distro_data,@osr);
sub get {
	eval $start if $b_log;
	if ($bsd_type){
		get_bsd_os();
	}
	else {
		get_linux_distro();
	}
	eval $end if $b_log;
	return @distro_data;
}

sub get_bsd_os {
	eval $start if $b_log;
	my ($distro) = ('');
	if ($bsd_type eq 'darwin'){
		my $file = '/System/Library/CoreServices/SystemVersion.plist';
		if (-f $file){
			my @data = main::reader($file);
			@data = grep {/(ProductName|ProductVersion)/} @data if @data;
			@data = grep {/<string>/} @data if @data;
			@data = map {s/<[\/]?string>//g; } @data if @data;
			$distro = join (' ', @data);
		}
	}
	# seen a case without osx file, or was it permissions?
	# this covers all the other bsds anyway, no problem.
	$distro = "$uname[0] $uname[2]" if !$distro;
	@distro_data = ($distro,'');
	eval $end if $b_log;
}

sub get_linux_distro {
	eval $start if $b_log;
	my ($distro,$distro_id,$distro_file,$system_base) = ('','','','');
	my ($b_issue,$b_osr,$b_use_issue,@working);
	# order matters!
	my @derived = qw(antix-version aptosid-version bodhibuilder.conf kanotix-version 
	knoppix-version pclinuxos-release mandrake-release manjaro-release mx-version 
	pardus-release porteus-version q4os_version sabayon-release siduction-version sidux-version 
	slitaz-release solusos-release turbolinux-release zenwalk-version);
	my $derived_s = join "|", @derived;
	my @primary = qw(altlinux-release arch-release gentoo-release redhat-release slackware-version 
	SuSE-release);
	my $primary_s = join "|", @primary;
	my $exclude_s = 'debian_version|devuan_version|ubuntu_version';
	# note, pclinuxos has all these mandrake/mandriva files, careful!
	my $lsb_good_s = 'mandrake-release|mandriva-release|mandrakelinux-release|manjaro-release';
	my $os_release_good_s = 'altlinux-release|arch-release|pclinuxos-release|rpi-issue|SuSE-release';
	# note: always exceptions, so wild card after release/version: 
	# /etc/lsb-release-crunchbang
	# wait to handle since crunchbang file is one of the few in the world that 
	# uses this method
	my @distro_files = main::globber('/etc/*[-_]{[rR]elease,[vV]ersion,issue}*');
	push @distro_files, '/etc/bodhibuilder.conf' if -r '/etc/bodhibuilder.conf';
	my $lsb_release = '/etc/lsb-release';
	my $b_lsb = 1 if -f $lsb_release;
	my ($etc_issue,$issue,$lc_issue) = ('','/etc/issue','');
	$b_issue = 1 if -f $issue;
	# note: OpenSuse Tumbleweed 2018-05 has made /etc/issue created by sym link to /run/issue
	# and then made that resulting file 700 permissions, which is obviously a mistake
	$etc_issue = (main::reader($issue))[0] if -r $issue;
	$etc_issue = main::clean_characters($etc_issue);
	my $os_release = '/etc/os-release';
	@osr = main::reader($os_release) if -r $os_release;
	# debian issue can end with weird escapes like \n \l 
	# antergos: Antergos Linux \r (\l)
	if ($etc_issue){
		$lc_issue = lc($etc_issue) if $etc_issue;
		if ($lc_issue =~ /(antergos|grml|linux lite)/){
			$distro_id = $1;
			$b_use_issue = 1;
		}
		elsif ($lc_issue =~ /(raspbian|peppermint)/){
			$distro_id = $1;
			$distro_file = $os_release if @osr;
		}
	}
	# Note that antergos changed this around 	# 2018-05, and now lists 
	# antergos in os-release, sigh... We want these distros to use os-release 
	# if it contains their names. Last check below
	if ( @osr && ( grep {/(manjaro|antergos|chakra|pclinuxos|zorin)/i} @osr ) ){
		$distro_file = $os_release;
	}
	$distro_id = 'armbian' if grep {/armbian/} @distro_files;
	main::log_data('dump','@distro_files',\@distro_files) if $b_log;
	main::log_data('data',"distro_file-1: $distro_file") if $b_log;
	if (!$distro_file){
		if (scalar @distro_files == 1){
			$distro_file = $distro_files[0];
		}
		elsif (scalar @distro_files > 1) {
			# special case, to force manjaro/antergos which also have arch-release
			# manjaro should use lsb, which has the full info, arch uses os release
			# antergos should use /etc/issue. We've already checked os-release above
			if ($distro_id eq 'antergos' || (grep {/antergos|chakra|manjaro/} @distro_files )){
				@distro_files = grep {!/arch-release/} @distro_files;
				#$system_base = 'Arch Linux';
			}
			my $distro_files_s = join "|", @distro_files;
			@working = (@derived,@primary);
			foreach my $file (@working){
				if ( "/etc/$file" =~ /($distro_files_s)$/){
					# Now lets see if the distro file is in the known-good working-lsb-list
					# if so, use lsb-release, if not, then just use the found file
					# this is for only those distro's with self named release/version files
					# because Mint does not use such, it must be done as below 
					if (@osr && $file =~ /($os_release_good_s)$/){
						$distro_file = $os_release;
					}
					elsif ($b_lsb && $file =~ /$lsb_good_s/){
						$distro_file = $lsb_release;
					}
					else {
						$distro_file = "/etc/$file";
					}
					last;
				}
			}
		}
	}
	main::log_data('data',"distro_file-2: $distro_file") if $b_log;
	# first test for the legacy antiX distro id file
	if ( -f '/etc/antiX'){
		@working = main::reader('/etc/antiX');
		$distro = main::awk(\@working,'antix.*\.iso') if @working;
		$distro = main::clean_characters($distro) if $distro;
	}
	# this handles case where only one release/version file was found, and it's lsb-release. 
	# This would never apply for ubuntu or debian, which will filter down to the following 
	# conditions. In general if there's a specific distro release file available, that's to 
	# be preferred, but this is a good backup.
	elsif ($distro_file && $b_lsb && ($distro_file =~ /\/etc\/($lsb_good_s)$/ || $distro_file eq $lsb_release) ){
		$distro = get_lsb_release();
	}
	elsif ($distro_file && $distro_file eq $os_release){
		$distro = get_os_release();
		$b_osr = 1;
	}
	# if distro id file was found and it's not in the exluded primary distro file list, read it
	elsif ( $distro_file && -s $distro_file && $distro_file !~ /\/etc\/($exclude_s)$/){
		# new opensuse uses os-release, but older ones may have a similar syntax, so just use 
		# the first line
		if ($distro_file eq '/etc/SuSE-release'){
			# leaving off extra data since all new suse have it, in os-release, this file has 
			# line breaks, like os-release  but in case we  want it, it's: 
			# CODENAME = Mantis  | VERSION = 12.2 
			# for now, just take first occurrence, which should be the first line, which does 
			# not use a variable type format
			@working = main::reader($distro_file);
			$distro = main::awk(\@working,'suse');
		}
		elsif ($distro_file eq '/etc/bodhibuilder.conf'){
			@working = main::reader($distro_file);
			$distro = main::awk(\@working,'^LIVECDLABEL',2,'\s*=\s*');
			$distro =~ s/"//g if $distro;
		}
		else {
			$distro = (main::reader($distro_file))[0];
			# only contains version number. Why? who knows.
			if ($distro_file eq '/etc/q4os_version' && $distro !~ /q4os/i){
				$distro = "Q4OS $distro" ;
			}
		}
		$distro = main::clean_characters($distro) if $distro;
	}
	# otherwise try  the default debian/ubuntu /etc/issue file
	elsif ($b_issue){
		if ( !$distro_id && $etc_issue && $lc_issue =~ /(mint|lmde)/ ){
			$distro_id = $1;
			$b_use_issue = 1;
		}
		# os-release/lsb gives more manageable and accurate output than issue, 
		# but mint should use issue for now. Antergos uses arch os-release, but issue shows them
		if (!$b_use_issue && @osr){
			$distro = get_os_release();
			$b_osr = 1;
		}
		elsif (!$b_use_issue && $b_lsb){
			$distro = get_lsb_release();
		}
		elsif ($etc_issue) {
			$distro =  $etc_issue;
			# this handles an arch bug where /etc/arch-release is empty and /etc/issue 
			# is corrupted only older arch installs that have not been updated should 
			# have this fallback required, new ones use os-release
			if ( $distro =~ /arch linux/i){
				$distro = 'Arch Linux';
			}
		}
	}
	# a final check. If a long value, before assigning the debugger output, if os-release
	# exists then let's use that if it wasn't tried already. Maybe that will be better.
	# not handling the corrupt data, maybe later if needed. 10 + distro: (8) + string
	if ($distro && length($distro) > 60 ){
		if (!$b_osr && @osr){
			$distro = get_os_release();
			$b_osr = 1;
		}
	}
	# test for /etc/lsb-release as a backup in case of failure, in cases 
	# where > one version/release file were found but the above resulted 
	# in null distro value. 
	if (!$distro){
		if (!$b_osr && @osr){
			$distro = get_os_release();
			$b_osr = 1;
		}
		elsif ($b_lsb){
			$distro = get_lsb_release();
		}
	}
	# now some final null tries
	if (!$distro ){
		# if the file was null but present, which can happen in some cases, then use 
		# the file name itself to set the distro value. Why say unknown if we have 
		# a pretty good idea, after all?
		if ($distro_file){
			$distro_file =~ s/\/etc\/|[-_]|release|version//g;
			$distro = $distro_file;
		}
	}
	if ($extra > 0){
		my $base_debian_version_distro = 'sidux';
		my $base_debian_version_osr = '\belive|lmde|neptune|parrot|pureos|rescatux|septor|sparky|tails';
		my $base_default = 'antix-version|mx-version'; # osr has base ids
		my $base_issue = 'bunsen'; # base only found in issue
		my $base_manual = 'blankon|deepin|kali'; # synthesize, no direct data available
		my $base_osr = 'aptosid|grml|q4os|siduction|bodhi'; # osr base, distro id in list of distro files
		my $base_osr_issue = 'grml|linux lite'; # osr base, distro id in issue
		# osr has distro name but has ubuntu  ID_LIKE/UBUNTU_CODENAME
		my $base_osr_ubuntu = 'mint|neon|nitrux|pop!_os|zorin'; 
		my $base_upstream_lsb = '/etc/upstream-release/lsb-release';
		my $base_upstream_osr = '/etc/upstream-release/os-release';
		# first: try, some distros have upstream-release, elementary, new mint
		# and anyone else who uses this method for fallback ID
		if ( -r $base_upstream_osr){
			my @osr_working = main::reader($base_upstream_osr);
			if ( @osr_working){
				my (@osr_temp);
				@osr_temp = @osr;
				@osr = @osr_working;
				$system_base = get_os_release();
				@osr = @osr_temp if !$system_base;
				(@osr_temp,@osr_working) = (undef,undef);
			}
		}
		elsif ( -r $base_upstream_lsb){
			$system_base = get_lsb_release($base_upstream_lsb);
		}
		if (!$system_base && @osr){
			my ($base_type) = ('');
			if ($etc_issue && (grep {/($base_issue)/i} @osr)){
				$system_base = $etc_issue;
			}
			# more tests added here for other ubuntu derived distros
			elsif ( @distro_files && (grep {/($base_default)/} @distro_files) ){
				$base_type = 'default';
			}
			# must go before base_osr_ubuntu test
			elsif ( grep {/($base_debian_version_osr)/i} @osr ){
				$system_base = debian_id();
			}
			elsif ( grep {/($base_osr_ubuntu)/i} @osr ){
				$base_type = 'ubuntu';
			}
			elsif ( ( ($distro_id && $distro_id =~ /($base_osr_issue)/ ) || 
			      (@distro_files && (grep {/($base_osr)/} @distro_files) ) ) && 
			      !(grep {/($base_osr)/i} @osr)){
				$system_base = get_os_release();
			}
			if (!$system_base && $base_type){
				$system_base = get_os_release($base_type);
			}
		}
		if (!$system_base && @distro_files && ( grep {/($base_debian_version_distro)/i} @distro_files ) ){
			$system_base = debian_id();
		}
		if (!$system_base && $lc_issue && $lc_issue =~ /($base_manual)/){
			my $id = $1;
			my %manual = (
			'blankon' => 'Debian unstable',
			'deepin' => 'Debian unstable',
			'kali' => 'Debian testing',
			);
			$system_base = $manual{$id};
		}
		if ($distro && -d '/etc/salixtools/' && $distro =~ /Slackware/i){
			$system_base = $distro;
		}
	}
	if ($distro){
		if ($distro_id eq 'armbian'){
			$distro =~ s/Debian/Armbian/;
		}
		elsif (-d '/etc/salixtools/' && $distro =~ /Slackware/i){
			$distro =~ s/Slackware/Salix/;
		}
	}
	else {
		# android fallback, sometimes requires root, sometimes doesn't
		if (-e '/system/build.prop') {
			main::set_build_prop() if !$b_build_prop;;
			$distro = 'Android';
			$distro .= ' ' . $build_prop{'build-version'} if $build_prop{'build-version'};
			$distro .= ' ' . $build_prop{'build-date'} if $build_prop{'build-date'};
			if (!$show{'machine'}){
				if ($build_prop{'product-manufacturer'} && $build_prop{'product-model'}){
					$distro .= ' (' . $build_prop{'product-manufacturer'} . ' ' . $build_prop{'product-model'} . ')';
				}
				elsif ($build_prop{'product-device'}){
					$distro .= ' (' . $build_prop{'product-device'} . ')';
				}
				elsif ($build_prop{'product-name'}){
					$distro .= ' (' . $build_prop{'product-name'} . ')';
				}
			}
		}
	}
	## finally, if all else has failed, give up
	$distro ||= 'unknown';
	@distro_data = ($distro,$system_base);
	eval $end if $b_log;
}

sub get_lsb_release {
	eval $start if $b_log;
	my ($lsb_file) = @_;
	$lsb_file ||= '/etc/lsb-release';
	my ($distro,$id,$release,$codename,$description) = ('','','','','');
	my @content = main::reader($lsb_file);
	main::log_data('dump','@content',\@content) if $b_log;
	@content = map {s/,|\*|\\||\"|[:\47]|^\s+|\s+$|n\/a//ig; $_} @content if @content;
	foreach (@content){
		next if /^\s*$/;
		my @working = split /\s*=\s*/, $_;
		next if !$working[0];
		if ($working[0] eq 'DISTRIB_ID' && $working[1]){
			if ($working[1] =~ /^Manjaro/i){
				$id = 'Manjaro Linux';
			}
			# in the old days, arch used lsb_release
# 			elsif ($working[1] =~ /^Arch$/i){
# 				$id = 'Arch Linux';
# 			}
			else {
				$id = $working[1];
			}
		}
		elsif ($working[0] eq 'DISTRIB_RELEASE' && $working[1]){
			$release = $working[1];
		}
		elsif ($working[0] eq 'DISTRIB_CODENAME' && $working[1]){
			$codename = $working[1];
		}
		# sometimes some distros cannot do their lsb-release files correctly, 
		# so here is one last chance to get it right.
		elsif ($working[0] eq 'DISTRIB_DESCRIPTION' && $working[1]){
			$description = $working[1];
		}
	}
	if (!$id && !$release && !$codename && $description){
		$distro = $description;
	}
	else {
		$distro = "$id $release $codename";
		$distro =~ s/^\s+|\s\s+|\s+$//g; # get rid of double and trailing spaces 
	}
	eval $end if $b_log;
	return $distro;
}
sub get_os_release {
	eval $start if $b_log;
	my ($base_type) = @_;
	my ($base_id,$base_name,$base_version,$distro,$distro_name,$pretty_name,
	$lc_name,$name,$version_name,$version_id) = ('','','','','','','','','','');
	my @content = @osr;
	main::log_data('dump','@content',\@content) if $b_log;
	@content = map {s/\\||\"|[:\47]|^\s+|\s+$|n\/a//ig; $_} @content if @content;
	foreach (@content){
		next if /^\s*$/;
		my @working = split /\s*=\s*/, $_;
		next if !$working[0];
		if ($working[0] eq 'PRETTY_NAME' && $working[1]){
			$pretty_name = $working[1];
		}
		elsif ($working[0] eq 'NAME' && $working[1]){
			$name = $working[1];
			$lc_name = lc($name);
		}
		elsif ($working[0] eq 'VERSION' && $working[1]){
			$version_name = $working[1];
			$version_name =~ s/,//g;
		}
		elsif ($working[0] eq 'VERSION_ID' && $working[1]){
			$version_id = $working[1];
		}
		# for mint/zorin, other ubuntu base system base
		if ($base_type ){
			if ($working[0] eq 'ID_LIKE' && $working[1]){
				if ($base_type eq 'ubuntu'){
					# popos shows debian
					$working[1] =~ s/^(debian|ubuntu\sdebian|debian\subuntu)/ubuntu/; 
					$working[1] = 'ubuntu' if $working[1] eq 'debian';
				}
				$base_name = ucfirst($working[1]);
			}
			elsif ($base_type eq 'ubuntu' && $working[0] eq 'UBUNTU_CODENAME' && $working[1]){
				$base_version = ucfirst($working[1]);
			}
			elsif ($base_type eq 'debian' && $working[0] eq 'DEBIAN_CODENAME' && $working[1]){
				$base_version = $working[1];
			}
		}
	}
	# NOTE: tumbleweed has pretty name but pretty name does not have version id
	# arco shows only the release name, like kirk, in pretty name. Too many distros 
	# are doing pretty name wrong, and just putting in the NAME value there
	if (!$base_type){
		if ($name && $version_name){
			$distro = $name;
			$distro = 'Arco Linux' if $lc_name =~ /^arco/;
			if ($version_id && $version_name !~ /$version_id/){
				$distro .= ' ' . $version_id;
			}
			$distro .= " $version_name";
		}
		elsif ($pretty_name && ($pretty_name !~ /tumbleweed/i && $lc_name ne 'arcolinux') ){
			$distro = $pretty_name;
		}
		elsif ($name){
			$distro = $name;
			if ($version_id){
				$distro .= ' ' . $version_id;
			}
		}
	}
	# note: mint has varying formats here, some have ubuntu as name, 17 and earlier
	else {
		# mint 17 used ubuntu os-release,  so won't have $base_version
		if ($base_name && $base_version){
			$base_id = ubuntu_id($base_version) if $base_type eq 'ubuntu' && $base_version;
			$base_id = '' if $base_id && "$base_name$base_version" =~ /$base_id/;
			$base_id .= ' ' if $base_id;
			$distro = "$base_name $base_id$base_version";
		}
		elsif ($base_type eq 'default' && ($pretty_name || ($name && $version_name) ) ){
			$distro = ($name && $version_name) ? "$name $version_name" : $pretty_name;
		}
		# LMDE 2 has only limited data in os-release, no _LIKE values. 3 has like and debian_codename
		elsif ( $base_type eq 'ubuntu' && $lc_name =~ /^(debian|ubuntu)/ && ($pretty_name || ($name && $version_name))){
			$distro = ($name && $version_name) ? "$name $version_name": $pretty_name;
		}
		elsif ( $base_type eq 'debian' && $base_version ){
			$distro = debian_id($base_version);
		}
	}
	eval $end if $b_log;
	return $distro;
}
# arg: 1 - optional: debian codename
sub debian_id {
	eval $start if $b_log;
	my ($codename) = @_;
	my ($debian_version,$id);
	$debian_version = (main::reader('/etc/debian_version','strip'))[0] if -r '/etc/debian_version';
	$id = 'Debian';
	return if !$debian_version && !$codename;
	# note, 3.0, woody, 3.1, sarge, but after it's integer per version
	my %debians = (
	'4' => 'etch',
	'5' => 'lenny',
	'6' => 'squeeze',
	'7' => 'wheezy',
	'8' => 'jessie',
	'9' => 'stretch',
	'10' => 'buster',
	'11' => 'bullseye',
	'12' => 'bookworm', 
	);
	if (main::is_numeric($debian_version)){
		$id .= " $debian_version $debians{int($debian_version)}";
	}
	elsif ($codename) {
		my %by_value = reverse %debians;
		my $version = (main::is_numeric($debian_version)) ? "$debian_version $codename": $debian_version;
		$id .= " $version";
	}
	# like buster/sid
	elsif ($debian_version) {
		$id .= " $debian_version";
	}
	eval $end if $b_log;
	return $id;
}

# note, these are only for matching derived names, no need to go
# all the way back here, update as new names are known. This is because 
# Mint is using UBUNTU_CODENAME without ID data.
sub ubuntu_id {
	eval $start if $b_log;
	my ($codename) = @_;
	$codename = lc($codename);
	my ($id) = ('');
	my %codenames = (
	'hirsute' => '21.04',
	'groovy' => '20.10',
	'focal' => '20.04 LTS',
	'eoan' => '19.10',
	'disco' => '19.04',
	'cosmic' => '18.10',
	'bionic' => '18.04 LTS',
	'artful' => '17.10',
	'zesty' => '17.04',
	'yakkety' => '16.10',
	'xenial' => '16.04 LTS',
	'wily' => '15.10',
	'vivid' => '15.04',
	'utopic' => '14.10',
	'trusty' => '14.04 LTS ',
	'saucy' => '13.10',
	'raring' => '13.04',
	'quantal' => '12.10',
	'precise' => '12.04 LTS ',
	);
	$id = $codenames{$codename} if defined $codenames{$codename};
	eval $end if $b_log;
	return $id;
}
}
# return all device modules not including driver
sub get_driver_modules {
	eval $start if $b_log;
	my ($driver,$modules) = @_;
	return if ! $modules;
	my @mods = split /,\s+/, $modules;
	if ($driver){
		@mods = grep {!/^$driver$/} @mods;
		$modules = join ',', @mods;
	}
	log_data('data','$modules',$modules) if $b_log;
	eval $end if $b_log;
	return $modules;
}
# 1: driver; 2: modules, comma separated, return only modules 
# which do not equal the driver string itself. Sometimes the module
# name is different from the driver name, even though it's the same thing.
sub get_gcc_data {
	eval $start if $b_log;
	my ($gcc,@data,@gccs,@temp);
	# NOTE: We can't use program_version because we don't yet know where
	# the version number is
	if (my $program = check_program('gcc') ){
		@data = grabber("$program --version 2>/dev/null");
		$gcc = awk(\@data,'^gcc');
	}
	if ($gcc){
		# strip out: gcc (Debian 6.3.0-18) 6.3.0 20170516
		# gcc (GCC) 4.2.2 20070831 prerelease [FreeBSD]
		$gcc =~ s/\([^\)]*\)//g;
		$gcc = get_piece($gcc,2);
	}
	if ($extra > 1){
		# glob /usr/bin for gccs, strip out all non numeric values
		@temp = globber('/usr/bin/gcc-*');
		foreach (@temp){
			if (/\/gcc-([0-9.]+)$/){
				push @gccs, $1;
			}
		}
	}
	unshift @gccs, $gcc;
	log_data('dump','@gccs',\@gccs) if $b_log;
	eval $end if $b_log;
	return @gccs;
}

# rasberry pi only
sub get_gpu_ram_arm {
	eval $start if $b_log;
	my ($gpu_ram) = (0);
	if (my $program = check_program('vcgencmd')){
		# gpu=128M
		# "VCHI initialization failed" - you need to add video group to your user
		my $working = (grabber("$program get_mem gpu 2>/dev/null"))[0];
		$working = (split /\s*=\s*/, $working)[1] if $working;
		$gpu_ram = translate_size($working) if $working;
	}
	log_data('data',"gpu ram: $gpu_ram") if $b_log;
	eval $end if $b_log;
	return $gpu_ram;
}

# standard systems
sub get_gpu_ram {
	eval $start if $b_log;
	my ($gpu_ram) = (0);
	eval $end if $b_log;
	return $gpu_ram;
}

sub get_hostname {
	eval $start if $b_log;
	my $hostname = '';
	if ( $ENV{'HOSTNAME'} ){
		$hostname = $ENV{'HOSTNAME'};
	}
	elsif ( !$bsd_type && -f "/proc/sys/kernel/hostname" ){
		$hostname = (reader('/proc/sys/kernel/hostname'))[0];
	}
	# puppy removed this from core modules, sigh
	# this is faster than subshell of hostname
	elsif (check_module('Sys::Hostname')){
		Sys::Hostname->import;
		$hostname = Sys::Hostname::hostname();
	}
	elsif (my $program = check_program('hostname')) {
		$hostname = (grabber("$program 2>/dev/null"))[0];
	}
	$hostname ||= 'N/A';
	eval $end if $b_log;
	return $hostname;
}

sub get_init_data {
	eval $start if $b_log;
	my $runlevel = get_runlevel_data();
	my $default = ($extra > 1) ? get_runlevel_default() : '';
	my ($init,$init_version,$rc,$rc_version,$program) = ('','','','','');
	my $comm = ( -e '/proc/1/comm' ) ? (reader('/proc/1/comm'))[0] : '';
	my (@data);
	# this test is pretty solid, if pid 1 is owned by systemd, it is systemd
	# otherwise that is 'init', which covers the rest of the init systems.
	# more data may be needed for other init systems.
	if ( $comm ){
		if ( $comm =~ /systemd/ ){
			$init = 'systemd';
			if ( $program = check_program('systemd')){
				$init_version = program_version($program,'^systemd','2','--version');
			}
			if (!$init_version && ($program = check_program('systemctl') ) ){
				$init_version = program_version($program,'^systemd','2','--version');
			}
		}
		# epoch version == Epoch Init System 1.0.1 "Sage"
		elsif ($comm =~ /epoch/){
			$init = 'Epoch';
			$init_version = program_version('epoch', '^Epoch', '4','version');
		}
		# missing data: note, runit can install as a dependency without being the 
		# init system: http://smarden.org/runit/sv.8.html
		# NOTE: the proc test won't work on bsds, so if runit is used on bsds we 
		# will need more datas
		elsif ($comm =~ /runit/){
			$init = 'runit';
		}
		elsif ($comm =~ /^s6/){
			$init = 's6';
		}
	}
	if (!$init){
		# output: /sbin/init --version:  init (upstart 1.1)
		# init (upstart 0.6.3)
		# openwrt /sbin/init hangs on --version command, I think
		if ((!$b_mips && !$b_sparc && !$b_arm) && ($init_version = program_version('init', 'upstart', '3','--version') )){
			$init = 'Upstart';
		}
		elsif (check_program('launchctl')){
			$init = 'launchd';
		}
		elsif ( -f '/etc/inittab' ){
			$init = 'SysVinit';
			if (check_program('strings')){
				@data = grabber('strings /sbin/init');
				$init_version = awk(\@data,'^version\s+[0-9]',2);
			}
		}
		elsif ( -f '/etc/ttys' ){
			$init = 'init (BSD)';
		}
	}
	if ( grep { /openrc/ } globber('/run/*openrc*') ){
		$rc = 'OpenRC';
		# /sbin/openrc --version == openrc (OpenRC) 0.13
		if ($program = check_program('openrc')){
			$rc_version = program_version($program, '^openrc', '3','--version');
		}
		# /sbin/rc --version == rc (OpenRC) 0.11.8 (Gentoo Linux)
		elsif ($program = check_program('rc')){
			$rc_version = program_version($program, '^rc', '3','--version');
		}
		if ( -e '/run/openrc/softlevel' ){
			$runlevel = (reader('/run/openrc/softlevel'))[0];
		}
		elsif ( -e '/var/run/openrc/softlevel'){
			$runlevel = (reader('/var/run/openrc/softlevel'))[0];
		}
		elsif ( $program = check_program('rc-status')){
			$runlevel = (grabber("$program -r 2>/dev/null"))[0];
		}
	}
	my %init = (
	'init-type' => $init,
	'init-version' => $init_version,
	'rc-type' => $rc,
	'rc-version' => $rc_version,
	'runlevel' => $runlevel,
	'default' => $default,
	);
	eval $end if $b_log;
	return %init;
}

sub get_kernel_data {
	eval $start if $b_log;
	my ($kernel,$ksplice) = ('','');
	# Linux; yawn; 4.9.0-3.1-liquorix-686-pae; #1 ZEN SMP PREEMPT liquorix 4.9-4 (2017-01-14); i686
	# FreeBSD; siwi.pair.com; 8.2-STABLE; FreeBSD 8.2-STABLE #0: Tue May 31 14:36:14 EDT 2016     erik5@iddhi.pair.com:/usr/obj/usr/src/sys/82PAIRx-AMD64; amd64
	if (@uname){
		$kernel = $uname[2];
		if ( (my $program = check_program('uptrack-uname')) && $kernel){
			$ksplice = qx($program -rm);
			$ksplice = trimmer($ksplice);
			$kernel = ($ksplice) ? $ksplice . ' (ksplice)' : $kernel;
		}
		$kernel .= ' ' . $uname[-1];
		$kernel = ($bsd_type) ? $uname[0] . ' ' . $kernel : $kernel;
	}
	$kernel ||= 'N/A';
	log_data('data',"kernel: $kernel ksplice: $ksplice") if $b_log;
	eval $end if $b_log;
	return $kernel;
}

sub get_kernel_bits {
	eval $start if $b_log;
	my $bits = '';
	if (my $program = check_program('getconf')){
		$bits = (grabber("$program LONG_BIT 2>/dev/null"))[0];
	}
	# fallback test
	if (!$bits && @uname){
		$bits = $uname[-1];
		$bits = ($bits =~ /64/ ) ? 64 : 32;
	}
	$bits ||= 'N/A';
	eval $end if $b_log;
	return $bits;
}

sub get_kernel_parameters {
	eval $start if $b_log;
	my ($parameters);
	if (my $file = system_files('cmdline') ) {
		$parameters = get_kernel_parameters_linux($file);
	}
	elsif ($bsd_type) {
		$parameters = get_kernel_parameters_bsd();
	}
	eval $end if $b_log;
	return $parameters;
}
sub get_kernel_parameters_linux {
	eval $start if $b_log;
	my ($file) = @_;
	# unrooted android may have file only root readable
	my $line = (reader($file))[0] if -r $file;
	eval $end if $b_log;
	return $line;
}
sub get_kernel_parameters_bsd {
	eval $start if $b_log;
	my ($parameters);
	eval $end if $b_log;
	return $parameters;
}

sub get_memory_data_full {
	eval $start if $b_log;
	my ($source) = @_;
	my $num = 0;
	my ($memory,@rows);
	my ($gpu_ram,$percent,$total,$used) = (0,'','','');
	if ($show{'ram'} || (!$show{'info'} && $show{'process'} )){
		$memory = get_memory_data('splits');
		if ($memory){
			my @temp = split /:/, $memory;
			my @temp2 = get_size($temp[0]);
			$gpu_ram = $temp[3] if $temp[3];
			$total = ($temp2[1]) ? $temp2[0] . ' ' . $temp2[1] : $temp2[0];
			@temp2 = get_size($temp[1]);
			$used = ($temp2[1]) ? $temp2[0] . ' ' . $temp2[1] : $temp2[0];
			$used .= " ($temp[2]%)" if $temp[2];
			if ($gpu_ram){
				@temp2 = get_size($gpu_ram);
				$gpu_ram = $temp2[0] . ' ' . $temp2[1] if $temp2[1];
			}
		}
		my $key = ($source eq 'process') ? 'System RAM': 'RAM';
		$rows[0]{main::key($num++,1,1,$key)} = '';
		$rows[0]{main::key($num++,0,2,'total')} = $total;
		$rows[0]{main::key($num++,0,2,'used')} = $used;
		$rows[0]{main::key($num++,0,2,'gpu')} = $gpu_ram if $gpu_ram;
		$b_mem = 1;
	}
	eval $end if $b_log;
	return @rows;
}

sub get_memory_data {
	eval $start if $b_log;
	my ($type) = @_;
	my ($memory);
	if (my $file = system_files('meminfo') ) {
		$memory = get_memory_data_linux($type,$file);
	}
	else {
		$memory = get_memory_data_bsd($type);
	}
	eval $end if $b_log;
	return $memory;
}

sub get_memory_data_linux {
	eval $start if $b_log;
	my ($type,$file) = @_;
	my ($available,$gpu,$memory,$not_used,$total) = (0,0,'',0,0);
	my @data = reader($file);
	foreach (@data){
		if ($_ =~ /^MemTotal:/){
			$total = get_piece($_,2);
		}
		elsif ($_ =~ /^(MemFree|Buffers|Cached):/){
			$not_used += get_piece($_,2);
		}
		elsif ($_ =~ /^MemAvailable:/){
			$available = get_piece($_,2);
		}
	}
	$not_used = $available if $available;
	$gpu = get_gpu_ram_arm() if $b_arm;
	#$gpu = translate_size('128M');
	$total += $gpu;
	my $used = $total - ($not_used);
	my $percent = ($used && $total) ? sprintf("%.1f", ($used/$total)*100) : '';
	if ($type eq 'string'){
		$percent = " ($percent%)" if $percent;
		$memory = sprintf("%.1f/%.1f MiB", $used/1024, $total/1024) . $percent;
	}
	else {
		$memory = "$total:$used:$percent:$gpu";
	}
	log_data('data',"memory: $memory") if $b_log;
	eval $end if $b_log;
	return $memory;
}

## openbsd/linux
# procs    memory       page                    disks    traps          cpu
# r b w    avm     fre  flt  re  pi  po  fr  sr wd0 wd1  int   sys   cs us sy id
# 0 0 0  55256 1484092  171   0   0   0   0   0   2   0   12   460   39  3  1 96
## openbsd 6.3? added in M, sigh...
# 2 57 55M 590M 789 0 0 0...
## freebsd:
# procs      memory      page                    disks     faults         cpu
# r b w     avm    fre   flt  re  pi  po    fr  sr ad0 ad1   in   sy   cs us sy id
# 0 0 0  21880M  6444M   924  32  11   0   822 827   0   0  853  832  463  8  3 88
# with -H
# 2 0 0 14925812  936448    36  13  10   0    84  35   0   0   84   30   42 11  3 86
## dragonfly
#  procs      memory      page                    disks     faults      cpu
#  r b w     avm    fre  flt  re  pi  po  fr  sr ad0 ad1   in   sy  cs us sy id
#  0 0 0       0  84060 30273993 2845 12742 1164 407498171 320960902   0   0 ....
sub get_memory_data_bsd {
	eval $start if $b_log;
	my ($type) = @_;
	my $memory = '';
	my ($avm,$av_pages,$cnt,$fre,$free_mem,$real_mem,$total) = (3,0,0,4,0,0,0);
	my (@data,$message);
	my $arg = ($bsd_type ne 'openbsd') ? '-H' : '';
	if (my $program = check_program('vmstat')){
		# see above, it's the last line. -H makes it hopefully all in kB so no need 
		# for K/M/G tests
		my @vmstat = grabber("vmstat $arg 2>/dev/null",'\n','strip');
		my @header = split /\s+/, $vmstat[1];
		foreach ( @header){
			if ($_ eq 'avm'){$avm = $cnt}
			elsif ($_ eq 'fre'){$fre = $cnt}
			elsif ($_ eq 'flt'){last;}
			$cnt++;
		}
		my $row = $vmstat[-1];
		if ( $row ){
			@data = split /\s+/, $row;
			# 6.3 introduced an M character, sigh.
			if ($data[$avm] && $data[$avm] =~ /^([0-9]+)M$/){
				$data[$avm] = $1 * 1024;
			}
			if ($data[$fre] && $data[$fre] =~ /^([0-9]+)M$/){
				$data[$fre] = $1 * 1024;
			}
			# dragonfly can have 0 avg, but they may fix that so make test dynamic
			if ($data[$avm] != 0){
				$av_pages = ($bsd_type ne 'openbsd') ? sprintf ('%.1f',$data[$avm]/1024) : $data[$avm];
			}
			elsif ($data[$fre] != 0){
				$free_mem = sprintf ('%.1f',$data[$fre]);
			}
		}
	}
	## code to get total goes here:
	my $ref = $alerts{'sysctl'};
	if ($$ref{'action'} eq 'use'){
		# for dragonfly, we will use free mem, not used because free is 0
		my @working;
		foreach (@sysctl){
			# freebsd seems to use bytes here
			if (!$real_mem && /^hw.physmem:/){
				@working = split /:\s*/,$_;
				#if ($working[1]){
					$working[1] =~ s/^[^0-9]+|[^0-9]+$//g;
					$real_mem = sprintf("%.1f", $working[1]/1024);
				#}
				last if $free_mem;
			}
			# But, it uses K here. Openbsd/Dragonfly do not seem to have this item
			# this can be either: Free Memory OR Free Memory Pages
			elsif (/^Free Memory:/){
				@working = split /:\s*/,$_;
				$working[1] =~ s/[^0-9]+//g;
				$free_mem = sprintf("%.1f", $working[1]);
				last if $real_mem;
			}
		}
	}
	else {
		$message = "sysctl $$ref{'action'}"
	}
	# not using, but leave in place for a bit in case we want it
	# my $type = ($free_mem) ? ' free':'' ;
	# hack: temp fix for openbsd/darwin: in case no free mem was detected but we have physmem
	if (($av_pages || $free_mem) && !$real_mem){
		my $error = ($message) ? $message: 'total N/A';
		my $used = (!$free_mem) ? $av_pages : $real_mem - $free_mem;
		if ($type eq 'string'){
			$used = sprintf("%.1f",$used/1024);
			$memory = "$used/($error) MB";
		}
		else {
			$memory = "$error:$used:";
		}
	}
	# use openbsd/dragonfly avail mem data if available
	elsif (($av_pages || $free_mem) && $real_mem) {
		my $used = (!$free_mem) ? $av_pages : $real_mem - $free_mem;
		my $percent = ($used && $real_mem) ? sprintf("%.1f", ($used/$real_mem)*100) : '';
		if ($type eq 'string'){
			$used = sprintf("%.1f",$used/1024);
			$real_mem = sprintf("%.1f",$real_mem/1024);
			$percent = " ($percent)" if $percent;
			$memory = "$used/$real_mem MB" . $percent;
		}
		else {
			$memory = "$real_mem:$used:$percent:0";
		}
	}
	eval $end if $b_log;
	return $memory;
}

sub get_module_version {
	eval $start if $b_log;
	my ($module) = @_;
	return if ! $module;
	my ($version);
	my $path = "/sys/module/$module/version";
	if (-f $path){
		$version = (reader($path))[0];
	}
	elsif (-f "/sys/module/$module/uevent"){
		$version = 'kernel';
	}
	#print "version:$version\n";
	if (!$version) {
		if (my $path = check_program('modinfo')){
			my @data = grabber("$path $module 2>/dev/null");
			$version = awk(\@data,'^version',2,':\s+') if @data;
		}
	}
	$version ||= '';
	eval $end if $b_log;
	return $version;
}
# Note: this outputs the key/value pairs ready to go and is
# called from either -r or -Ix, -r precedes. 
## Get PackageData
{
package PackageData;
my ($count,%counts,@list,$num,%output,$program,$type);
$counts{'total'} = 0;
sub get {
	eval $start if $b_log;
	# $num passed by reference to maintain incrementing where requested
	($type,$num) = @_; 
	package_counts();
	appimage_counts();
	create_output();
	eval $end if $b_log;
	return %output;
}
sub create_output {
	eval $start if $b_log;
	my $total;
	if ($counts{'total'}){
		$total = $counts{'total'};
	}
	else {
		if ($type eq 'inner'){$total = 'N/A';}
		else {$total = main::row_defaults('packages','');}
	}
	if ($counts{'total'} && $extra > 1){
		delete $counts{'total'};
		my $b_mismatch;
		foreach (keys %counts){
			if ($counts{$_}->[0] && $counts{$_}->[0] != $total){
				$b_mismatch = 1;
				last;
			}
		}
		$total = '' if !$b_mismatch;
	}
	$output{main::key($$num++,1,1,'Packages')} = $total;
	if ($extra > 1 && %counts){
		foreach (sort keys %counts){
			my ($cont,$ind) = (1,2);
			# if package mgr command returns error, this will not be an array
			next if ref $counts{$_} ne 'ARRAY';
			if ($counts{$_}->[0] || $b_admin){
				my $key = $_;
				$key =~ s/^zzz-//; # get rid of the special sorters for items to show last
				$output{main::key($$num++,$cont,$ind,$key)} = $counts{$_}->[0];
				if ($b_admin && $counts{$_}->[1]){
					($cont,$ind) = (0,3);
					$output{main::key($$num++,$cont,$ind,'lib')} = $counts{$_}->[1];
				}
			}
		}
	}
	# print Data::Dumper::Dumper \%output;
	eval $end if $b_log;
}
sub package_counts {
	eval $start if $b_log;
	my ($type) = @_;
	# 0: key; 1: program; 2: p/d; 3: arg/path; 4: 0/1 use lib; 
	# 5: lib slice; 6: lib splitter; 7 - optional eval test
	# needed: cards [nutyx], urpmq [mageia]
	my @pkg_managers = (
	['alps','alps','p','showinstalled',1,0,''],
	['apk','apk','p','info',1,0,''],
	# older dpkg-query do not support -f values consistently: eg ${binary:Package}
	['apt','dpkg-query','p','-W -f=\'${Package}\n\'',1,0,''],
	# ['aptd','dpkg-query','d','/usr/lib/*',1,3,'\\/'],
	# mutyx. do cards test because there is a very slow pkginfo python pkg mgr
	['cards','pkginfo','p','-i',1,1,'','main::check_program(\'cards\')'], 
	['emerge','emerge','d','/var/db/pkg/*/*/',1,5,'\\/'],
	['eopkg','eopkg','d','/var/lib/eopkg/package/*',1,5,'\\/'],
	['guix-sys','guix','p','package -p "/run/current-system/profile" -I',1,0,''],
	['guix-usr','guix','p','package package -I',1,0,''],
	['pacman','pacman','p','-Qq --color never',1,0,''],
	['pacman-g2','pacman-g2','p','-Q',1,0,''],
	['pkg','pkg','d','/var/db/pkg/*',1,0,''], # 'pkg list' returns non programs
	['pkg_info','pkg_info','p','',1,0,''],
	['pkgtool','pkgtool','d','/var/log/packages/*',1,4,'\\/'],
	# way too slow without nodigest/sig!! confirms packages exist
	['rpm','rpm','p','-qa --nodigest --nosignature',1,0,''],
	# note',' slapt-get, spkg, and pkgtool all return the same count
	#['slapt-get','slapt-get','p','--installed',1,0,''],
	#['spkg','spkg','p','--installed',1,0,''],
	['tce','tce-status','p','-i',1,0,''],
	# note: I believe mageia uses rpm internally but confirm
	# ['urpmi','urpmq','p','??',1,0,''], 
	['xbps','xbps-query','p','-l',1,1,''],
	['zzz-flatpak','flatpak','p','list',0,0,''],
	['zzz-snap','snap','p','list',0,0,'','@ps_cmd && (grep {/\bsnapd\b/} @ps_cmd)'],
	);
	my $libs;
	foreach (@pkg_managers){
		if ($program = main::check_program($_->[1])){
			next if $_->[7] && !eval $_->[7];
			if ($_->[2] eq 'p'){
				chomp(@list = qx($program $_->[3] 2>/dev/null));
			}
			else {
				@list = main::globber($_->[3]);
			}
			$libs = undef;
			$count = scalar @list;
			#print Data::Dumper::Dumper \@list;
			if ($b_admin && $count && $_->[4]){
				$libs = count_libs(\@list,$_->[5],$_->[6]);
			}
			$counts{$_->[0]} = ([$count,$libs]);
			$counts{'total'} += $count;
			#print Data::Dumper::Dumper \%counts;
		}
	}
	# print Data::Dumper::Dumper \%counts;
	main::log_data('dump','Packaage managers: %counts',\%counts) if $b_log;
	eval $end if $b_log;
}
sub appimage_counts {
	if (@ps_cmd && (grep {/\bappimaged\b/} @ps_cmd)){
		@list = main::globber($ENV{'HOME'} . '/.local/bin/*.appimage');
		$count = scalar @list;
		$counts{'zzz-appimage'} = ([$$count,undef]) if $count;
		$counts{'total'} += $count;
	}
}
sub count_libs {
	my ($ref,$pos,$split) = @_;
	my (@data);
	my $i = 0;
	$split ||= '\\s+';
	#print scalar @$ref, '::', $split, '::', $pos, "\n";
	foreach (@$ref){
		@data = split /$split/, $_;
		#print scalar @data, '::', $data[$pos], "\n";
		$i++ if $data[$pos] && $data[$pos] =~ m%^lib%;
	}
	return $i;
}
}

# args: 1 - pci device string; 2 - pci cleaned subsystem string
sub get_pci_vendor {
	eval $start if $b_log;
	my ($device, $subsystem) = @_;
	return if !$subsystem;
	my ($vendor,$sep,$temp) = ('','','');
	# get rid of any [({ type characters that will make regex fail
	# and similar matches show as non-match
	$subsystem = regex_cleaner($subsystem);
	my @data = split /\s+/, $subsystem;
	# when using strings in patterns for regex have to escape them
	foreach (@data){
		$temp = $_;
		$temp =~ s/(\+|\$|\?|\^|\*)/\\$1/g;
		if ($device !~ m|\b$temp\b|){
			$vendor .= $sep . $_;
			$sep = ' ';
		}
		else {
			last;
		}
	}
	eval $end if $b_log;
	return $vendor;
}

# # check? /var/run/nologin for bsds?
sub get_runlevel_data {
	eval $start if $b_log;
	my $runlevel = '';
	if ( my $program = check_program('runlevel')){
		$runlevel = (grabber("$program 2>/dev/null"))[0];
		$runlevel =~ s/[^\d]//g if $runlevel;
		#print_line($runlevel . ";;");
	}
	eval $end if $b_log;
	return $runlevel;
}

# note: it appears that at least as of 2014-01-13, /etc/inittab is going 
# to be used for default runlevel in upstart/sysvinit. systemd default is 
# not always set so check to see if it's linked.
sub get_runlevel_default {
	eval $start if $b_log;
	my @data;
	my $default = '';
	my $b_systemd = 0;
	my $inittab = '/etc/inittab';
	my $systemd = '/etc/systemd/system/default.target';
	my $upstart = '/etc/init/rc-sysinit.conf';
	# note: systemd systems do not necessarily have this link created
	if ( -e $systemd){
		$default = readlink($systemd);
		$default =~ s/.*\/// if $default; 
		$b_systemd = 1;
	}
	# http://askubuntu.com/questions/86483/how-can-i-see-or-change-default-run-level
	# note that technically default can be changed at boot but for inxi purposes 
	# that does not matter, we just want to know the system default
	elsif ( -e $upstart){
		# env DEFAULT_RUNLEVEL=2
		@data = reader($upstart);
		$default = awk(\@data,'^env\s+DEFAULT_RUNLEVEL',2,'=');
	}
	# handle weird cases where null but inittab exists
	if (!$default && -e $inittab ){
		@data = reader($inittab);
		$default = awk(\@data,'^id.*initdefault',2,':');
	}
	eval $end if $b_log;
	return $default;
}

sub get_self_version {
	eval $start if $b_log;
	my $patch = $self_patch;
	if ( $patch ne '' ){
		# for cases where it was for example: 00-b1 clean to -b1
		$patch =~ s/^[0]+-?//;
		$patch = "-$patch" if $patch;
	}
	eval $end if $b_log;
	return $self_version . $patch;
}

sub get_shell_data {
	eval $start if $b_log;
	my ($ppid) = @_;
	my $cmd = "ps -p $ppid -o comm= 2>/dev/null";
	my $shell = qx($cmd);
	log_data('cmd',$cmd) if $b_log;
	chomp($shell);
	if ($shell){
		#print "shell pre: $shell\n";
		# when run in debugger subshell, would return sh as shell,
		# and parent as perl, that is, pinxi itself, which is actually right.
		# trim leading /.../ off just in case. ps -p should return the name, not path 
		# but at least one user dataset suggests otherwise so just do it for all.
		$shell =~ s/^.*\///; 
		my $working = $ENV{'SHELL'};
		# NOTE: su -c "inxi -F" results in shell being su
		if ($shell eq 'sudo' || $shell eq 'su' ){
			$client{'su-start'} = $shell;
			$shell = get_shell_parent(get_start_parent($ppid));
		}
		if ($working){
			$working =~ s/^.*\///;
# 			if (($shell eq 'sh' || $shell eq 'sudo' || $shell eq 'su' ) && $shell ne $working){
# 				$client{'su-start'} = $shell if ($shell eq 'sudo' || $shell eq 'su');
# 				$shell = $working;
# 			}
			# a few manual changes for known 
			# Note: parent when fizsh shows as zsh but SHELL is fizsh, but other times
			# SHELL is default shell, but in zsh, SHELL is default shell, not zfs
			if ($shell eq 'zsh' && $working eq 'fizsh' ){
				$shell = $working;
			}
		}
		# print "shell post: $shell working: $working\n";
		# since there are endless shells, we'll keep a list of non program value
		# set shells since there is little point in adding those to program values
		if (test_shell($shell)){
			# do nothing, just leave $shell as is
		}
		# note: not all programs return version data. This may miss unhandled shells!
		elsif ((@app = program_data(lc($shell),lc($shell),1)) && $app[0]){
			$shell = $app[0];
			$client{'version'} = $app[1] if $app[1]; 
			#print "app test $shell v: $client{'version'}\n";
		}
		else {
			# NOTE: we used to guess here with position 2 --version but this cuold lead
			# to infinite loops when inxi called from a script 'infos' that is in PATH and 
			# script does not have any start arg handlers or bad arg handlers: 
			# eg: shell -> infos -> inxi -> sh -> infos --version -> infos -> inxi...
			# Basically here we are hoping that the grandparent is a shell, or at least
			# recognized as a known possible program
			#print "app not shell?: $shell\n";
			if ($shell){
				# print 'shell: ' . $shell .' Start client version type: ', get_shell_parent(get_start_parent(getppid())), "\n";
				my $parent = get_shell_parent(get_start_parent($ppid));
				if ($parent){
					if (test_shell($parent)){
						$shell = $parent;
					}
					elsif ((@app = program_data(lc($parent),lc($parent),0)) && $app[0]){
						$shell = $app[0];
						$client{'version'} = $app[1] if $app[1];
					}
					#print "shell3: $shell version: $client{'version'}\n";
				}
			}
			else {
				$client{'version'} = row_defaults('unknown-shell');
			}
			#print "shell not app version: $client{'version'}\n";
		}
		$client{'version'} ||= '';
		$client{'version'} =~ s/(\(.*|-release|-version)// if $client{'version'};
		$client{'name'} = lc($shell);
		$client{'name-print'} = $shell;
		#print "shell4: $client{'name-print'} version: $client{'version'}\n";
		if ($extra > 2 && $working && lc($shell) ne lc($working)){
			if (@app = program_data(lc($working))){
				$client{'default-shell'} = $app[0];
				$client{'default-shell-v'} = $app[1];
				$client{'default-shell-v'} =~ s/(\(.*|-release|-version)// if $client{'default-shell-v'};
			}
			else {
				$client{'default-shell'} = $working;
			}
		}
	}
	else {
		$client{'name'} = 'shell';
		$client{'name-print'} = 'Unknown Shell';
	}
	$client{'su-start'} = 'sudo' if (!$client{'su-start'} && $ENV{'SUDO_USER'});
	eval $end if $b_log;
}
# list of program_values non-handled shells, or known to have no version
# Move shell to set_program_values for print name, or version if available
sub test_shell {
	my ($test) = @_;
	# not verified or tested
	my $shells = 'apush|ccsh|ch|esh|eshell|heirloom|hush|';
	$shells .= 'ion|imrsh|larryshell|mrsh|msh(ell)?|murex|nsh|nu(shell)?|';
	$shells .= 'psh|pwsh|pysh(ell)?|rush|sash|';
	# tested shells with no version info discovered
	$shells .= 'es|rc|scsh|sh';
	return '|' . $shells if $test eq 'return';
	return ($test =~ /^($shells)$/) ? $test : '';
}

sub get_shell_source {
	eval $start if $b_log;
	my (@data);
	my ($msg,$self_parent,$shell_parent) = ('','','');
	my $ppid = getppid();
	$self_parent = get_start_parent($ppid);
	if ($b_log){
		$msg = ($ppid) ? "self parent: $self_parent ppid: $ppid": "self parent: undefined";
		log_data('data',$msg);
	}
	#print "self parent: $self_parent ppid: $ppid\n";
	if ($self_parent){
		$shell_parent = get_shell_parent($self_parent);
		$client{'su-start'} = $shell_parent if ($shell_parent eq 'su' && !$client{'su-start'});
		#print "shell parent 1: $shell_parent\n";
		if ($b_log){
			$msg = ($shell_parent) ? "shell parent 1: $shell_parent": "shell parent 1: undefined";
			log_data('data',$msg);
		}
		# in case sudo starts inxi, parent is shell (or perl inxi if run by debugger)
		# so: perl (2) started pinxi with sudo (3) in sh (4) in terminal
		my $shells = 'ash|bash|busybox|cicada|csh|dash|elvish|fish|fizsh|ksh|ksh93|';
		$shells .= 'lksh|loksh|mksh|nash|oh|oil|osh|pdksh|perl|posh|';
		$shells .= 'su|sudo|tcsh|xonsh|yash|zsh';
		$shells .= test_shell('return');
		for my $i (2..4){
			if ( $shell_parent && $shell_parent =~ /^($shells)$/ ){
				# no idea why have to do script_parent action twice in su case, but you do.
				$self_parent = get_start_parent($self_parent);
				$shell_parent = get_shell_parent($self_parent);
				#print "self::shell parent 2-${i}: $self_parent :: $shell_parent\n";
				if ($b_log){
					$msg = ($shell_parent) ? "shell parent $i: $shell_parent": "shell parent $i: undefined";
					log_data('data',$msg);
				}
			}
			else {
				last;
			}
		}
		# to work around a ps -p or gnome-terminal bug, which returns 
		# gnome-terminal- trim - off end 
		$shell_parent =~ s/-$// if $shell_parent;
	}
	if ($b_log){
		$self_parent ||= '';
		$shell_parent ||= '';
		log_data('data',"parents: self: $self_parent shell: $shell_parent");
	}
	eval $end if $b_log;
	return $shell_parent;
}

# utilities for get_shell_source 
# arg: 1 - parent id
sub get_start_parent {
	eval $start if $b_log;
	my ($parent) = @_;
	return 0 if !$parent;
	# ps -j -fp : bsds ps do not have -f for PPID, so we can't get the ppid
	my $cmd = "ps -j -fp $parent 2>/dev/null";
	log_data('cmd',$cmd) if $b_log;
	my @data = grabber($cmd);
	#shift @data if @data;
	my $self_parent = awk(\@data,"$parent",3,'\s+');
	eval $end if $b_log;
	return $self_parent;
}

# arg: 1 - parent id
sub get_shell_parent {
	eval $start if $b_log;
	my ($parent) = @_;
	return '' if !$parent;
	my $cmd = "ps -j -p $parent 2>/dev/null";
	log_data('cmd',$cmd) if $b_log;
	my @data = grabber($cmd,'','strip');
	#shift @data if @data;
	my $shell_parent = awk(\@data, "$parent",-1,'\s+');
	eval $end if $b_log;
	return $shell_parent;
}

# this will test against default IP like: (:0) vs full IP to determine 
# ssh status. Surprisingly easy test? Cross platform
sub get_ssh_status {
	eval $start if $b_log;
	my ($b_ssh,$ssh);
	# fred   pts/10       2018-03-24 16:20 (:0.0)
	# fred-remote pts/1        2018-03-27 17:13 (43.43.43.43)
	if (my $program = check_program('who')){
		$ssh = (grabber("$program am i 2>/dev/null"))[0];
		# crude IP validation
		if ($ssh && $ssh =~ /\(([:0-9a-f]{8,}|[1-9][\.0-9]{6,})\)$/){
			$b_ssh = 1;
		}
	}
	eval $end if $b_log;
	return $b_ssh;
}

sub get_tty_console_irc {
	eval $start if $b_log;
	my ($type) = @_;
	return $tty_session if defined $tty_session;
	if ( $type eq 'vtrn' && defined $ENV{'XDG_VTNR'} ){
		$tty_session = $ENV{'XDG_VTNR'};
	}
	else {
		my $ppid = getppid();
		$tty_session = awk(\@ps_aux,".*$ppid.*$client{'name'}",7,'\s+');
		$tty_session =~ s/^[^[0-9]+// if $tty_session;
	}
	$tty_session = '' if ! defined $tty_session;
	log_data('data',"conole-irc-tty:$tty_session") if $b_log;
	eval $end if $b_log;
	return $tty_session;
}

sub get_tty_number {
	eval $start if $b_log;
	my ($tty);
	if ( defined $ENV{'XDG_VTNR'} ){
		$tty = $ENV{'XDG_VTNR'};
	}
	else {
		$tty = POSIX::ttyname(1);
		#variants: /dev/pts/1 /dev/tty1 /dev/ttyp2 /dev/ttyra [hex number a]
		$tty =~ s/.*\/[^0-9]*//g if defined $tty;
	}
	$tty = '' if ! defined $tty;
	log_data('data',"tty:$tty") if $b_log;
	eval $end if $b_log;
	return $tty;
}

# 2:58PM  up 437 days,  8:18, 3 users, load averages: 2.03, 1.72, 1.77
# 04:29:08 up  3:18,  3 users,  load average: 0,00, 0,00, 0,00
# 10:23PM  up 5 days, 16:17, 1 user, load averages: 0.85, 0.90, 1.00
# 05:36:47 up 1 day,  3:28,  4 users,  load average: 1,88, 0,98, 0,62
# 05:36:47 up 1 day,  3 min,  4 users,  load average: 1,88, 0,98, 0,62
# 04:41:23 up  2:16,  load average: 7.13, 6.06, 3.41 # root openwrt
sub get_uptime {
	eval $start if $b_log;
	my ($days,$hours,$minutes,$uptime) = ('','','','');
	if (check_program('uptime')){
		$uptime = qx(uptime);
		$uptime = trimmer($uptime);
		#$uptime = '05:36:47 up 3 min,  4 users,  load average: 1,88, 0,98, 0,62';
		if ($uptime && 
		 $uptime =~ /[\S]+\s+up\s+(([0-9]+)\s+day[s]?,\s+)?(([0-9]{1,2}):([0-9]{1,2})|([0-9]+)\smin[s]?),\s+([0-9]+\s+user|load average)/){
			$days = $2 . 'd' if $2;
			$days .= ' ' if ($days && ($4 || $6));
			if ($4 && $5){
				$hours = $4 . 'h ';
				$minutes = $5 . 'm';
			}
			elsif ($6){
				$minutes = $6 . 'm';
				
			}
			$uptime = $days . $hours . $minutes;
		}
	}
	$uptime ||= 'N/A';
	eval $end if $b_log;
	return $uptime;
}
#  note: seen instance in android where reading file hangs endlessly!!!
sub get_wakeups {
	eval $start if $b_log;
	return if $b_arm || $b_mips || $b_ppc;
	my ($wakeups);
	my $path = '/sys/power/wakeup_count';
	$wakeups = (reader($path,'strip'))[0] if -r $path;
	eval $end if $b_log;
	return $wakeups;
}

#### -------------------------------------------------------------------
#### SET DATA VALUES
#### -------------------------------------------------------------------

# android only, for distro / OS id and machine data
sub set_build_prop {
	eval $start if $b_log;
	my $path = '/system/build.prop';
	$b_build_prop = 1;
	return if ! -r $path;
	my @data = reader($path,'strip');
	foreach (@data){
		my @working = split /=/, $_;
		next if $working[0] !~ /^ro\.(build|product)/;
		if ($working[0] eq 'ro.build.date.utc'){
			$build_prop{'build-date'} = strftime "%F", gmtime($working[1]);
		}
		# ldgacy, replaced by ro.product.device
		elsif ($working[0] eq 'ro.build.product'){
			$build_prop{'build-product'} = $working[1];
		}
		# this can be brand, company, android, it varies, but we don't want android value
		elsif ($working[0] eq 'ro.build.user'){
			$build_prop{'build-user'} = $working[1] if $working[1] !~ /android/i;
		}
		elsif ($working[0] eq 'ro.build.version.release'){
			$build_prop{'build-version'} = $working[1];
		}
		elsif ($working[0] eq 'ro.product.board'){
			$build_prop{'product-board'} = $working[1];
		}
		elsif ($working[0] eq 'ro.product.brand'){
			$build_prop{'product-brand'} = $working[1];
		}
		elsif ($working[0] eq 'ro.product.device'){
			$build_prop{'product-device'} = $working[1];
		}
		elsif ($working[0] eq 'ro.product.manufacturer'){
			$build_prop{'product-manufacturer'} = $working[1];
		}
		elsif ($working[0] eq 'ro.product.model'){
			$build_prop{'product-model'} = $working[1];
		}
		elsif ($working[0] eq 'ro.product.name'){
			$build_prop{'product-name'} = $working[1];
		}
		elsif ($working[0] eq 'ro.product.screensize'){
			$build_prop{'product-screensize'} = $working[1];
		}
	}
	log_data('dump','%build_prop',\%build_prop) if $b_log;
	print Dumper \%build_prop if $test[20];
	eval $end if $b_log;
}

## creates arrays: @devices_audio; @devices_graphics; @devices_hwraid; 
## @devices_network; @devices_timer plus @devices for logging/debugging
# 0 type
# 1 type_id
# 2 bus_id
# 3 sub_id
# 4 device
# 5 vendor_id
# 6 chip_id
# 7 rev
# 8 port
# 9 driver
# 10 modules
# 11 driver_nu [bsd, like: em0 - driver em; nu 0. Used to match IF in -n
# 12 subsystem/vendor
# 13 subsystem vendor_id:chip id
# 14 soc handle
## DeviceData / PCI / SOC
{
package DeviceData;
my (@data,@devices,@files,@full_names,@pcis,@temp,@temp2,@temp3);

my ($busid,$busid_nu,$chip_id,$content,$device,$driver,$driver_nu,$file,
$handle,$modules,$port,$rev,$temp,$type,$type_id,$vendor,$vendor_id);

sub set {
	eval $start if $b_log;
	$_[0] = 1; # check boolean passed by reference
	if ( $b_pci ){
		if (!$bsd_type){
			if ($alerts{'lspci'}{'action'} eq 'use' ){
				lspci_data();
			}
			# ! -d '/proc/bus/pci'
			# this is sketchy, a sbc won't have pci, but a non sbc arm may have it, so 
			# build up both and see what happens
			if ($b_arm || $b_mips || $b_ppc || $b_sparc){
				soc_data();
			}
		}
		else {
			#if (1 == 1){
			if ($alerts{'pciconf'}{'action'} eq 'use'){
				pciconf_data();
			}
			elsif ($alerts{'pcidump'}{'action'} eq 'use'){
				pcidump_data();
			}
		}
		if ($test[9]){
			print Data::Dumper::Dumper \@devices_audio;
			print Data::Dumper::Dumper \@devices_graphics;
			print Data::Dumper::Dumper \@devices_network;
			print Data::Dumper::Dumper \@devices_hwraid;
			print Data::Dumper::Dumper \@devices_timer;
			print "vm: $device_vm\n";
		}
		if ( $b_log){
			main::log_data('dump','@devices_audio',\@devices_audio);
			main::log_data('dump','@devices_graphics',\@devices_graphics);
			main::log_data('dump','@devices_hwraid',\@devices_hwraid);
			main::log_data('dump','@devices_network',\@devices_network);
			main::log_data('dump','@devices_timer',\@devices_timer);
		}
	}
	@devices = undef;
	eval $end if $b_log;
}

sub lspci_data {
	eval $start if $b_log;
	my ($subsystem,$subsystem_id);
	@data = pci_grabber('lspci');
	#print Data::Dumper::Dumper \@data;
	foreach (@data){
		#print "$_\n";
		if ($device){
			if ($_ =~ /^~$/) {
				@temp = ($type,$type_id,$busid,$busid_nu,$device,$vendor_id,$chip_id,
				$rev,$port,$driver,$modules,$driver_nu,$subsystem,$subsystem_id);
				assign_data('pci',@temp);
				$device = '';
				#print "$busid $device_id r:$rev p: $port\n$type\n$device\n";
			}
			elsif ($_ =~ /^Subsystem.*\[([a-f0-9]{4}:[a-f0-9]{4})\]/){
				$subsystem_id = $1;
				$subsystem = (split /^Subsystem:\s*/,$_)[1];
				$subsystem =~ s/(\s?\[[^\]]+\])+$//g;
				$subsystem = main::cleaner($subsystem);
				$subsystem = main::pci_cleaner($subsystem,'pci');
				$subsystem = main::pci_cleaner_subsystem($subsystem);
				#print "ss:$subsystem\n";
			}
			elsif ($_ =~ /^I\/O\sports/){
				$port = (split /\s+/,$_)[3];
				#print "p:$port\n";
			}
			elsif ($_ =~ /^Kernel\sdriver\sin\suse/){
				$driver = (split /:\s*/,$_)[1];
			}
			elsif ($_ =~ /^Kernel\smodules/i){
				$modules = (split /:\s*/,$_)[1];
			}
		}
		# note: arm servers can have more complicated patterns
		# 0002:01:02.0 Ethernet controller [0200]: Cavium, Inc. THUNDERX Network Interface Controller virtual function [177d:a034] (rev 08)
		elsif ($_ =~ /^(([0-9a-f]{2,4}:)?[0-9a-f]{2}:[0-9a-f]{2})[.:]([0-9a-f]+)\s(.*)\s\[([0-9a-f]{4}):([0-9a-f]{4})\](\s\(rev\s([^\)]+)\))?/){
			$busid = $1;
			$busid_nu = hex($3);
			@temp = split /:\s+/, $4;
			$device = $temp[1];
			$type = $temp[0];
			$vendor_id = $5;
			$chip_id = $6;
			$rev = ($8)? $8 : '';
			$device = main::cleaner($device);
			$temp[0] =~ /\[([^\]]+)\]$/;
			$type_id = $1;
			$b_hardware_raid = 1 if $type_id eq '0104';
			$type = lc($type);
			$type = main::pci_cleaner($type,'pci');
			$type =~ s/\s+$//;
			#print "$type\n";
			($driver,$driver_nu,$modules,$subsystem,$subsystem_id) = ('','','','','');
		}
	}
	print Data::Dumper::Dumper \@devices if $test[4];
	main::log_data('dump','lspci @devices',\@devices) if $b_log;
	eval $end if $b_log;
}

# em0@pci0:6:0:0:	class=0x020000 card=0x10d315d9 chip=0x10d38086 rev=0x00 hdr=0x00
#     vendor     = 'Intel Corporation'
#     device     = 'Intel 82574L Gigabit Ethernet Controller (82574L)'
#     class      = network
#     subclass   = ethernet
sub pciconf_data {
	eval $start if $b_log;
	@data = pci_grabber('pciconf');
	foreach (@data){
		if ($driver){
			if ($_ =~ /^~$/) {
				$vendor = main::cleaner($vendor);
				$device = main::cleaner($device);
				# handle possible regex in device name, like [ConnectX-3] 
				# and which could make matches fail
				my $device_temp = main::regex_cleaner($device);
				if ($vendor && $device){
					if (main::regex_cleaner($vendor) !~ /\Q$device_temp\E/i){
						$device = "$vendor $device";
					}
				}
				elsif (!$device){
					$device = $vendor;
				}
				@temp = ($type,$type_id,$busid,$busid_nu,$device,$vendor_id,$chip_id,
				$rev,$port,$driver,$modules,$driver_nu);
				assign_data('pci',@temp);
				$driver = '';
				#print "$busid $device_id r:$rev p: $port\n$type\n$device\n";
			}
			elsif ($_ =~ /^vendor/){
				$vendor = (split /\s+=\s+/,$_)[1];
				#print "p:$port\n";
			}
			elsif ($_ =~ /^device/){
				$device = (split /\s+=\s+/,$_)[1];
			}
			elsif ($_ =~ /^class/i){
				$type = (split /\s+=\s+/,$_)[1];
			}
		}
		elsif (/^([^@]+)\@pci([0-9]{1,3}:[0-9]{1,3}:[0-9]{1,3}):([0-9]{1,3}).*class=([^\s]+)\scard=([^\s]+)\schip=([^\s]+)\srev=([^\s]+)/){
			$driver = $1;
			$busid = $2;
			$busid_nu = $3;
			$type_id = $4;
			#$vendor_id = $5;
			$vendor_id = substr($6,6,4);
			$chip_id = substr($6,2,4);
			$rev = $7;
			$driver =~ /(^[a-z]+)([0-9]+$)/;
			$driver = $1;
			$driver_nu = $2;
			# convert to 4 character, strip off 0x, and last trailing sub sub class.
			$type_id =~ s/^(0x)?([0-9a-f]{4}).*/$2/ if $type_id;
			($device,$type,$vendor) = ('','','');
		}
	}
	print Data::Dumper::Dumper \@devices if $test[4];
	main::log_data('dump','pciconf @devices',\@devices) if $b_log;
	eval $end if $b_log;
}

sub pcidump_data {
	eval $start if $b_log;
	@data = pci_grabber('pcidump');
	foreach (@data){
		if ($_ =~ /^~$/ && $busid && $device) {
			@temp = ($type,$type_id,$busid,$busid_nu,$device,$vendor_id,$chip_id,
			$rev,$port,$driver,$modules,$driver_nu);
			assign_data('pci',@temp);
			($type,$type_id,$busid,$busid_nu,$device,$vendor_id,$chip_id,
			$rev,$port,$driver,$modules,$driver_nu) = undef;
			next;
		}
		if ($_ =~ /^([0-9a-f:]+):([0-9]+):\s([^:]+)$/i){
			$busid = $1;
			$busid_nu = $2;
			$device = main::cleaner($3);
		}
		elsif ($_ =~ /^0x[\S]{4}: Vendor ID: ([0-9a-f]{4}) Product ID: ([0-9a-f]{4})/ ){
			$vendor_id = $1;
			$chip_id = $2;
		}
		elsif ($_ =~ /^0x[\S]{4}: Class: ([0-9a-f]{2}) Subclass: ([0-9a-f]{2}) Interface: ([0-9a-f]+) Revision: ([0-9a-f]+)/){
			$type = pci_class($1);
			$type_id = "$1$2";
		}
	}
	print Data::Dumper::Dumper \@devices if $test[4];
	main::log_data('dump','pcidump @devices',\@devices) if $b_log;
	eval $end if $b_log;
}
sub pci_grabber {
	eval $start if $b_log;
	my ($program) = @_;
	my ($args,$pattern,@working);
	if ($program eq 'lspci'){
		$args = ' -knnv';
		$pattern = '^[0-9a-f]+:';
	}
	elsif ($program eq 'pciconf'){
		$args = ' -lv';
		$pattern = '^([^@]+)\@pci';
	}
	elsif ($program eq 'pcidump'){
		$args = ' -v';
		$pattern = '^[0-9a-f]+:';
	}
	my $path = main::check_program($program);
	@data = main::grabber("$path $args 2>/dev/null",'','strip');
	#my $file = "$ENV{'HOME'}/bin/scripts/inxi/data/pciconf/pci-freebsd-8.2-2";
	#my $file = "$ENV{'HOME'}/bin/scripts/inxi/data/pcidump/pci-openbsd-6.1-vm.txt";
	#my $file = "$ENV{HOME}/bin/scripts/inxi/data/lspci/racermach-1-knnv.txt";
	#my $file = "$ENV{HOME}/bin/scripts/inxi/data/lspci/rk016013-knnv.txt";
	#@data = main::reader($file,'strip');
	if (@data){
		$b_pci_tool = 1 if scalar @data > 10;
		foreach (@data){
			if ($_ =~ /$pattern/i){
				push @working, '~';
			}
			push @working, $_;
		}
		push @working, '~';
	}
	#print Data::Dumper::Dumper \@working;
	eval $end if $b_log;
	return @working;
}

sub soc_data {
	eval $start if $b_log;
	soc_devices_files();
	soc_devices();
	soc_devicetree();
	print Data::Dumper::Dumper \@devices if $test[4];
	main::log_data('dump','soc @devices',\@devices) if $b_log;
	eval $end if $b_log;
}
# 1: /sys/devices/platform/soc/1c30000.ethernet/uevent:["DRIVER=dwmac-sun8i", "OF_NAME=ethernet", 
# "OF_FULLNAME=/soc/ethernet@1c30000", "OF_COMPATIBLE_0=allwinner,sun8i-h3-emac", 
# "OF_COMPATIBLE_N=1", "OF_ALIAS_0=ethernet0", # "MODALIAS=of:NethernetT<NULL>Callwinner,sun8i-h3-emac"]
# 2: /sys/devices/platform/soc:audio/uevent:["DRIVER=bcm2835_audio", "OF_NAME=audio", "OF_FULLNAME=/soc/audio", 
# "OF_COMPATIBLE_0=brcm,bcm2835-audio", "OF_COMPATIBLE_N=1", "MODALIAS=of:NaudioT<NULL>Cbrcm,bcm2835-audio"]
# 3: /sys/devices/platform/soc:fb/uevent:["DRIVER=bcm2708_fb", "OF_NAME=fb", "OF_FULLNAME=/soc/fb", 
# "OF_COMPATIBLE_0=brcm,bcm2708-fb", "OF_COMPATIBLE_N=1", "MODALIAS=of:NfbT<NULL>Cbrcm,bcm2708-fb"]
# 4: /sys/devices/platform/soc/1c40000.gpu/uevent:["OF_NAME=gpu", "OF_FULLNAME=/soc/gpu@1c40000", 
# "OF_COMPATIBLE_0=allwinner,sun8i-h3-mali", "OF_COMPATIBLE_1=allwinner,sun7i-a20-mali", 
# "OF_COMPATIBLE_2=arm,mali-400", "OF_COMPATIBLE_N=3", 
# "MODALIAS=of:NgpuT<NULL>Callwinner,sun8i-h3-maliCallwinner,sun7i-a20-maliCarm,mali-400"]
# 5: /sys/devices/platform/soc/soc:internal-regs/d0018180.gpio/uevent
# 6: /sys/devices/soc.0/1180000001800.mdio/8001180000001800:05/uevent
#  ["DRIVER=AR8035", "OF_NAME=ethernet-phy"
# 7: /sys/devices/soc.0/1c30000.eth/uevent
# 8: /sys/devices/wlan.26/uevent [from pine64]
# 9: /sys/devices/platform/audio/uevent:["DRIVER=bcm2835_AUD0", "OF_NAME=audio"
# 10: /sys/devices/vio/71000002/uevent:["DRIVER=ibmveth", "OF_NAME=l-lan"
# 11: /sys/devices/platform/soc:/soc:i2c-hdmi:/i2c-2/2-0050/uevent:['OF_NAME=hdmiddc'
# 12: /sys/devices/platform/soc:/soc:i2c-hdmi:/uevent:['DRIVER=i2c-gpio', 'OF_NAME=i2c-hdmi'
sub soc_devices_files {
	eval $start if $b_log;
	if (-d '/sys/devices/platform/'){
		@files = main::globber('/sys/devices/platform/soc*/*/uevent');
		@temp2 = main::globber('/sys/devices/platform/soc*/*/*/uevent');
		@files = (@files,@temp2) if @temp2;
		@temp2 = main::globber('/sys/devices/platform/*/uevent');
		@files = (@files,@temp2) if @temp2;
	}
	if (main::globber('/sys/devices/soc*')){
		@temp2 = main::globber('/sys/devices/soc*/*/uevent');
		@files = (@files,@temp2) if @temp2;
		@temp2 = main::globber('/sys/devices/soc*/*/*/uevent');
		@files = (@files,@temp2) if @temp2;
	}
	@temp2 = main::globber('/sys/devices/*/uevent'); # see case 8
	@files = (@files,@temp2) if @temp2;
	@temp2 = main::globber('/sys/devices/*/*/uevent'); # see case 10
	@files = (@files,@temp2) if @temp2;
	@temp2 = undef;
	# not sure why, but even as root/sudo, /subsystem|driver/uevent are unreadable with -r test true
	@files = grep {!/\/(subsystem|driver)\//} @files if @files;
	@files = main::uniq(@files);
	eval $end if $b_log;
}
sub soc_devices {
	eval $start if $b_log;
	my (@working);
	foreach $file (@files){
		next if -z $file;
		$chip_id = $file;
		# variants: /soc/20100000.ethernet/ /soc/soc:audio/ /soc:/ /soc@0/ /soc:/12cb0000.i2c:/
		# mips: /sys/devices/soc.0/1180000001800.mdio/8001180000001800:07/
		# ppc: /sys/devices/vio/71000002/
		$chip_id =~ /\/sys\/devices\/(platform\/)?(soc[^\/]*\/)?([^\/]+\/)?([^\/]+\/)?([^\/\.:]+)([\.:])?([^\/:]+)?:?\/uevent$/;
		$chip_id = $5;
		$temp = $7;
		@working = main::reader($file, 'strip') if -r $file;
		($device,$driver,$handle,$type,$vendor_id) = (undef,undef,undef,undef,undef);
		foreach my $data (@working){
			@temp2 = split /=/, $data;
			if ($temp2[0] eq 'DRIVER'){
				$driver = $temp2[1];
				$driver =~ s/-/_/g if $driver; # kernel uses _, not - in module names
			}
			elsif ($temp2[0] eq 'OF_NAME'){
				$type = $temp2[1];
			}
			# we'll use these paths to test in device tree pci completer
			elsif ($temp2[0] eq 'OF_FULLNAME' && $temp2[1]){
				# we don't want the short names like /soc, /led and so on
				push @full_names, $temp2[1] if (() = $temp2[1] =~ /\//g) > 1;
				$handle = (split /@/, $temp2[1])[-1] if $temp2[1] =~ /@/;
			}
			elsif ($temp2[0] eq 'OF_COMPATIBLE_0'){
				@temp3 = split /,/, $temp2[1];
				$device = $temp3[-1];
				$vendor_id = $temp3[0];
			}
		}
		# it's worthless, we can't use it
		next if ! defined $type;
		$type_id = $type;
		$type = 'display' if $type =~ /mali/i;
		$chip_id = '' if ! defined $chip_id;
		$vendor_id = '' if ! defined $vendor_id;
		$driver = '' if ! defined $driver;
		$handle = '' if ! defined $handle;
		$busid = (defined $temp && main::is_int($temp)) ? $temp: 0;
		$type = soc_type($type,$vendor_id,$driver);
		($busid_nu,$modules,$port,$rev) = (0,'','','');
		@temp3 = ($type,$type_id,$busid,$busid_nu,$device,$vendor_id,$chip_id,$rev,
		$port,$driver,$modules,'','','',$handle);
		assign_data('soc',@temp3);
	}
	eval $end if $b_log;
}
sub soc_devicetree {
	eval $start if $b_log;
	# now we want to fill in stuff that was not in /sys/devices/ 
	if (-d '/sys/firmware/devicetree/base/soc'){
		@files = main::globber('/sys/firmware/devicetree/base/soc/*/compatible');
		my $test = (@full_names) ? join('|', sort @full_names) : 'xxxxxx';
		foreach $file (@files){
			if ( $file !~ m%$test%){
				($handle,$content,$device,$type,$type_id,$vendor_id) = ('','','','','','');
				$content = (main::reader($file, 'strip'))[0] if -r $file;
				$file =~ m%soc/([^@]+)@([^/]+)/compatible$%;
				$type = $1;
				next if !$type || !$content;
				$handle = $2 if $2;
				$type_id = $type;
				$type = 'display' if $type =~ /mali/i;
				if ($content){
					@temp3 = split /,/, $content;
					$vendor_id = $temp3[0];
					$device = $temp3[-1];
					# strip off those weird device tree special characters
					$device =~ s/\x01|\x02|\x03|\x00//g;
				}
				$type = soc_type($type,$vendor_id,'');
				@temp3 = ($type,$type_id,0,0,$device,$vendor_id,'soc','','','','','','','',$handle);
				assign_data('soc',@temp3);
				main::log_data('dump','@devices @temp3',\@temp3) if $b_log;
			}
		}
	}
	eval $end if $b_log;
}
sub assign_data {
	my ($tool,@data) = @_;
	if (check_graphics($data[0],$data[1])){
		@devices_graphics = (@devices_graphics,[@data]);
		$b_soc_gfx = 1 if $tool eq 'soc';
	}
	# for hdmi, we need gfx/audio both
	if (check_audio($data[0],$data[1])){
		@devices_audio = (@devices_audio,[@data]);
		$b_soc_audio = 1 if $tool eq 'soc';
	}
	elsif (check_hwraid($data[0],$data[1])){
		@devices_hwraid = (@devices_hwraid,[@data]);
		$b_soc_net = 1 if $tool eq 'soc';
	}
	elsif (check_network($data[0],$data[1])){
		@devices_network = (@devices_network,[@data]);
		$b_soc_net = 1 if $tool eq 'soc';
	}
	elsif (check_timer($data[0],$data[1])){
		@devices_timer = (@devices_timer,[@data]);
		$b_soc_timer = 1;
	}
	# not used at this point, -M comes before ANG
	# $device_vm = check_vm($data[4]) if ( (!$b_ppc && !$b_mips) && !$device_vm );
	@devices = (@devices,[@data]);
}
# note: for soc, these have been converted in soc_type()
sub check_audio {
	if ( ( $_[1] && length($_[1]) == 4 && $_[1] =~/^04/ ) ||
		( $_[0] && $_[0] =~ /^(audio|hdmi|multimedia|sound)$/i )){
		return 1;
	}
	else {return 0}
}
sub check_graphics {
	# note: multimedia class 04 is viddeo if 0400. 'tv' is risky I think
	if ( ( $_[1] && length($_[1]) == 4 &&  ($_[1] =~/^03/ || $_[1] eq '0400' ) ) ||
	( $_[0] && $_[0] =~ /^(vga|display|hdmi|3d|video|tv|television)$/i)){
		return 1;
	}
	else {return 0}
}
sub check_hwraid {
	return 1 if ( $_[1] && $_[1] eq '0104' );
}
# NOTE: class 06 subclass 80 
# https://www-s.acm.illinois.edu/sigops/2007/roll_your_own/7.c.1.html
sub check_network {
	if ( ( $_[1] && length($_[1]) == 4 && ($_[1] =~/^02/ || $_[1] eq '0680' ) ) ||
		( $_[0] && $_[0] =~  /^(ethernet|network|wifi|wlan)$/i ) ){
		return 1;
	}
	else {return 0}
}
sub check_timer {
	return 1 if ( $_[0] && $_[0] eq 'timer' );
}
sub check_vm {
	if ( $_[0] && $_[0] =~ /(innotek|vbox|virtualbox|vmware|qemu)/i ) {
		return $1
	}
	else {return ''}
}

sub soc_type {
	my ($type,$info,$driver) = @_;
	# I2S or i2s. I2C is i2 controller |[iI]2[Ss]. note: odroid hdmi item is sound only
	# snd_soc_dummy. simple-audio-amplifier driver: speaker_amp
	if ($type =~ /^(daudio|.*hifi.*|.*sound[_-]card|.*dac[0-9]?)$/ ||
	 ($info && $info !~ /amp|codec|dummy/ && $info =~ /(sound|audio)/) || 
	 ($driver && $driver !~ /(codec|dummy)/ && $driver =~ /(audio|snd|sound)/) ){
		$type = 'audio';
	}
	elsif ($type =~ /^((meson-?)?fb|disp|display(-[^\s]+)?|gpu|mali)$/){
		$type = 'display';
	}
	# includes ethernet-phy, meson-eth
	elsif ($type =~ /^(([^\s]+-)?eth|ethernet(-[^\s]+)?|lan|l-lan)$/){
		$type = 'ethernet';
	}
	elsif ($type =~ /^(.*wlan.*|.*wifi.*)$/){
		$type = 'wifi';
	}
	# needs to catch variants like hdmi-tx but not hdmi-connector
	elsif ( (!$driver || $driver !~ /(codec|dummy)/) && $type =~ /^(.*hdmi(-?tx)?)$/){
		$type = 'hdmi';
	}
	elsif ($type =~ /^timer$/){
		$type = 'timer';
	}
	return $type;
}
sub pci_class {
	eval $start if $b_log;
	my ($id) = @_;
	$id = lc($id);
	my %classes = (
	'00' => 'unclassified',
	'01' => 'mass-storage',
	'02' => 'network',
	'03' => 'display',
	'04' => 'audio',
	'05' => 'memory',
	'06' => 'bridge',
	'07' => 'communication',
	'08' => 'peripheral',
	'09' => 'input',
	'0a' => 'docking',
	'0b' => 'processor',
	'0c' => 'serialbus',
	'0d' => 'wireless',
	'0e' => 'intelligent',
	'0f' => 'satellite',
	'10' => 'encryption',
	'11' => 'signal-processing',
	'12' => 'processing-accelerators',
	'13' => 'non-essential-instrumentation',
	'40' => 'coprocessor',
	'ff' => 'unassigned',
	);
	my $type = (defined $classes{$id}) ? $classes{$id}: 'unhandled';
	eval $end if $b_log;
	return $type;
}
}

sub set_dmesg_boot_data {
	eval $start if $b_log;
	my ($file,@temp);
	my ($counter) = (0);
	$b_dmesg_boot_check = 1;
	if (!$b_fake_dboot){
		$file = system_files('dmesg-boot');
	}
	else {
		#$file = "$ENV{'HOME'}/bin/scripts/inxi/data/dmesg-boot/bsd-disks-diabolus.txt";
		#$file = "$ENV{'HOME'}/bin/scripts/inxi/data/dmesg-boot/freebsd-disks-solestar.txt";
		#$file = "$ENV{'HOME'}/bin/scripts/inxi/data/dmesg-boot/freebsd-enceladus-1.txt";
		## matches: toshiba: openbsd-5.6-sysctl-2.txt
		#$file = "$ENV{'HOME'}/bin/scripts/inxi/data/dmesg-boot/openbsd-5.6-dmesg.boot-1.txt";
		## matches: compaq: openbsd-5.6-sysctl-1.txt"
		$file = "$ENV{'HOME'}/bin/scripts/inxi/data/dmesg-boot/openbsd-dmesg.boot-1.txt";
	}
	if ($file){
		return if ! -r $file;
		@dmesg_boot = reader($file);
		# some dmesg repeats, so we need to dump the second and > iterations
		# replace all indented items with ~ so we can id them easily while
		# processing note that if user, may get error of read permissions
		# for some weird reason, real mem and avail mem are use a '=' separator, 
		# who knows why, the others are ':'
		foreach (@dmesg_boot){
			$counter++ if /^(OpenBSD|DragonFly|FreeBSD is a registered trademark)/;
			last if $counter > 1;
			$_ =~ s/\s*=\s*|:\s*/:/;
			$_ =~ s/\"//g;
			$_ =~ s/^\s+/~/;
			$_ =~ s/\s\s/ /g;
			$_ =~ s/^(\S+)\sat\s/$1:at /; # ada0 at ahcich0
			push @temp, $_;
			if (/^bios[0-9]:(at|vendor)/){
				push @sysctl_machine, $_;
			}
		}
		@dmesg_boot = @temp;
		# FreeBSD: 'da*' is a USB device 'ada*' is a SATA device 'mmcsd*' is an SD card
		if ($b_dm_boot_disk && @dmesg_boot){
			@dm_boot_disk = grep {/^(ad|ada|da|mmcblk|mmcsd|nvme[0-9]+n|sd|wd)[0-9]+(:|\sat\s)/} @dmesg_boot;
			log_data('dump','@dm_boot_disk',\@dm_boot_disk) if $b_log;
			print Dumper \@dm_boot_disk if $test[11];
		}
		if ($b_dm_boot_optical && @dmesg_boot){
			@dm_boot_optical = grep {/^(cd)[0-9]+(\([^)]+\))?(:|\sat\s)/} @dmesg_boot;
			log_data('dump','@dm_boot_optical',\@dm_boot_optical) if $b_log;
			print Dumper \@dm_boot_optical if $test[11];
		}
	}
	log_data('dump','@dmesg_boot',\@dmesg_boot) if $b_log;
	#print Dumper \@dmesg_boot if $test[11];
	eval $end if $b_log;
}

# note, all actual tests have already been run in check_tools so if we
# got here, we're good. 
sub set_dmi_data {
	eval $start if $b_log;
	$_[0] = 1; # check boolean passed by reference
	if ($b_fake_dmidecode || $alerts{'dmidecode'}{'action'} eq 'use' ){
		set_dmidecode_data();
	}
	eval $end if $b_log;
}

sub set_dmidecode_data {
	eval $start if $b_log;
	my ($content,@data,@working,$type,$handle);
	if ($b_fake_dmidecode){
		#my $file = "$ENV{'HOME'}/bin/scripts/inxi/data/dmidecode/pci-freebsd-8.2-2";
		# my $file = "$ENV{'HOME'}/bin/scripts/inxi/data/dmidecode/dmidecode-loki-1.txt";
		#my $file = "$ENV{'HOME'}/bin/scripts/inxi/data/dmidecode/dmidecode-t41-1.txt";
		#my $file = "$ENV{'HOME'}/bin/scripts/inxi/data/dmidecode/dmidecode-mint-20180106.txt";
		#my $file = "$ENV{'HOME'}/bin/scripts/inxi/data/dmidecode/dmidecode-vmware-ram-1.txt";
		#open my $fh, '<', $file or die "can't open $file: $!";
		#chomp(@data = <$fh>);
	}
	else {
		my $path = check_program('dmidecode'); 
		$content = qx($path 2>/dev/null) if $path;
		@data = split /\n/, $content;
	}
	# we don't need the opener lines of dmidecode output
	# but we do want to preserve the indentation. Empty lines
	# won't matter, they will be skipped, so no need to handle them.
	# some dmidecodes do not use empty line separators
	splice @data, 0, 5 if @data;
	my $j = 0;
	my $b_skip = 1;
	foreach (@data){
		if (!/^Hand/){
			next if $b_skip;
			if (/^[^\s]/){
				$_ = lc($_);
				$_ =~ s/\s(information)//;
				push @working, $_;
			}
			elsif (/^\t/){
				$_ =~ s/^\t\t/~/;
				$_ =~ s/^\t|\s+$//g;
				push @working, $_;
			}
		}
		elsif (/^Handle\s(0x[0-9A-Fa-f]+).*DMI\stype\s([0-9]+),.*/){
			$j = scalar @dmi;
			$handle = hex($1);
			$type = $2;
			$b_slot_tool = 1 if $type && $type == 9;
			$b_skip = ( $type > 126 )? 1 : 0;
			next if $b_skip;
			# we don't need 32, system boot, or 127, end of table
			if (@working){
				if ($working[0] != 32 && $working[0] < 127){
					$dmi[$j] = (
					[@working],
					);
				}
			}
			@working = ($type,$handle);
		}
	}
	if (@working && $working[0] != 32 && $working[0] != 127){
		$j = scalar @dmi;
		$dmi[$j] = (
		[@working],
		);
	}
	# last by not least, sort it by dmi type, now we don't have to worry
	# about random dmi type ordering in the data, which happens. Also sort 
	# by handle, as secondary sort.
	@dmi = sort { $a->[0] <=> $b->[0] || $a->[1] <=> $b->[1] } @dmi;
	log_data('dump','@dmi',\@dmi) if $b_log;
	print Dumper \@dmi if $test[2];
	eval $end if $b_log;
}

sub set_ip_data {
	eval $start if $b_log;
	if ($alerts{'ip'}{'action'} eq 'use' ){
		set_ip_addr();
	}
	elsif ($alerts{'ifconfig'}{'action'} eq 'use'){
		set_ifconfig();
	}
	eval $end if $b_log;
}

sub set_ip_addr {
	eval $start if $b_log;
	my $program = check_program('ip');
	my @data = grabber("$program addr 2>/dev/null",'\n','strip') if $program;
	# my $file = "$ENV{'HOME'}/bin/scripts/inxi/data/if/scope-ipaddr-1.txt";
	# my $file = "$ENV{'HOME'}/bin/scripts/inxi/data/networking/ip-addr-blue-advance.txt";
	#my @data = reader($file,'strip') or die $!;
	my ($b_skip,$broadcast,$if,$ip,@ips,$scope,$if_id,$type,@temp,@temp2);
	foreach (@data){
		if (/^[0-9]/){
			#print "$_\n";
			if (@ips){
			#print "$if\n";
				@temp = ($if,[@ips]);
				@ifs = (@ifs,@temp);
				@ips = ();
			}
			@temp = split /:\s+/,$_;
			$if = $temp[1];
			if ($if eq 'lo'){
				$b_skip = 1;
				$if = '';
				next;
			}
			$b_skip = 0;
			@temp = ();
		}
		elsif (!$b_skip && /^inet/){
			#print "$_\n";
			@temp = split /\s+/, $_;
			($broadcast,$ip,$scope,$if_id,$type) = ('','','','','');
			$ip = $temp[1];
			$type = ($temp[0] eq 'inet') ? 4 : 6 ;
			if ($temp[2] eq 'brd'){
				$broadcast = $temp[3];
			}
			if (/scope\s([^\s]+)(\s(.+))?/){
				$scope = $1;
				$if_id = $3;
			}
			@temp = ($type,$ip,$broadcast,$scope,$if_id);
			@ips = (@ips,[@temp]);
			#print Dumper \@ips;
		}
	}
	#print Dumper \@ips if $test[4];
	if (@ips){
		@temp = ($if,[@ips]);
		@ifs = (@ifs,@temp);
	}
	log_data('dump','@ifs',\@ifs) if $b_log;
	print Dumper \@ifs if $test[3];
	eval $end if $b_log;
}

sub set_ifconfig {
	eval $start if $b_log;
	my $program = check_program('ifconfig'); # not in user path, sbin
	my @data = grabber("$program 2>/dev/null",'\n','') if $program;
	#my @data = reader("$ENV{'HOME'}/bin/scripts/inxi/data/if/vps-ifconfig-1.txt",'') or die $!;
	my ($b_skip,$broadcast,$if,@ips_bsd,$ip,@ips,$scope,$if_id,$type,@temp,@temp2);
	my ($state,$speed,$duplex,$mac);
	foreach (@data){
		if (/^[\S]/i){
			#print "$_\n";
			if (@ips){
			#print "here\n";
				@temp = ($if,[@ips]);
				@ifs = (@ifs,@temp);
				@ips = ();
			}
			if ($mac){
				@temp = ($if,[($state,$speed,$duplex,$mac)]);
				@ifs_bsd = (@ifs_bsd,@temp);
				($state,$speed,$duplex,$mac,$if_id) = ('','','','','');
			}
			$if = (split /\s+/,$_)[0];
			$if =~ s/:$//; # em0: flags=8843
			$if_id = $if;
			$if = (split /:/, $if)[0] if $if;
			if ($if =~ /^lo/){
				$b_skip = 1;
				$if = '';
				$if_id = '';
				next;
			}
			$b_skip = 0;
		}
		# lladdr openbsd
		elsif (!$b_skip && $bsd_type && /^\s+(ether|media|status|lladdr)/){
			$_ =~ s/^\s+//;
			# media: Ethernet 100baseTX <full-duplex> freebsd 7.3 
			# media: Ethernet autoselect (1000baseT <full-duplex>) Freebsd 8.2
			# 
			if (/^media/){
				# openbsd: media: Ethernet autoselect (1000baseT full-duplex)
				if ($bsd_type && $bsd_type eq 'openbsd'){
					$_ =~ /\s\([\S]+\s([\S]+)\)/;
					$duplex = $1;
				}
				else {
					$_ =~ /<([^>]+)>/;
					$duplex = $1;
				}
				$_ =~ /\s\(([1-9][\S]+\s)/;
				$speed = $1;
				$speed =~ s/\s+$// if $speed;
			}
			elsif (!$mac && /^ether|lladdr/){
				$mac = (split /\s+/, $_)[1];
			}
			elsif (/^status/){
				$state = (split /\s+/, $_)[1];
			}
		}
		elsif (!$b_skip && /^\s+inet/){
			#print "$_\n";
			$_ =~ s/^\s+//;
			$_ =~ s/addr:\s/addr:/;
			@temp = split /\s+/, $_;
			($broadcast,$ip,$scope,$type) = ('','','','');
			$ip = $temp[1];
			# fe80::225:90ff:fe13:77ce%em0
# 			$ip =~ s/^addr:|%([\S]+)//;
			if ($1 && $1 ne $if_id){
				$if_id = $1;
			}
			$type = ($temp[0] eq 'inet') ? 4 : 6 ;
			if (/(Bcast:|broadcast\s)([\S]+)/){
				$broadcast = $2;
			}
			if (/(scopeid\s[^<]+<|Scope:|scopeid\s)([^>]+)[>]?/){
				$scope = $2;
			}
			$scope = 'link' if $ip =~ /^fe80/;
			@temp = ($type,$ip,$broadcast,$scope,$if_id);
			@ips = (@ips,[@temp]);
			#print Dumper \@ips;
		}
	}
	if (@ips){
		@temp = ($if,[@ips]);
		@ifs = (@ifs,@temp);
	}
	if ($mac){
		@temp = ($if,[($state,$speed,$duplex,$mac)]);
		@ifs_bsd = (@ifs_bsd,@temp);
		($state,$speed,$duplex,$mac) = ('','','','');
	}
	print Dumper \@ifs if $test[3];
	print Dumper \@ifs_bsd if $test[3];
	log_data('dump','@ifs',\@ifs) if $b_log;
	log_data('dump','@ifs_bsd',\@ifs_bsd) if $b_log;
	eval $end if $b_log;
}

sub set_ps_aux {
	eval $start if $b_log;
	my ($header,@temp);
	@ps_aux = grabber("ps aux 2>/dev/null",'','strip');
	if (@ps_aux){
		$header = shift @ps_aux; # get rid of header row
		# handle busy box, which has 3 columns, regular ps aux has 11
		# avoid deprecated implicit split error in older Perls
		@temp = split(/\s+/, $header);
	}
	$ps_cols = $#temp;
	if ($ps_cols < 10){
		my $version = qx(ps --version 2>&1);
		$b_bb_ps = 1 if $version =~ /busybox/i;
	}
	return if !@ps_aux; # note: mips/openwrt ps has no 'a'
	$_=lc for @ps_aux; # this is a super fast way to set to lower
	# note: regular perl /.../inxi but sudo /.../inxi is added for sudo start
	# for pinxi, we want to see the useage data for cpu/ram
	@ps_aux = grep {!/\/$self_name\b/} @ps_aux if $self_name eq 'inxi';
	# this is for testing for the presence of the command
	@ps_cmd = grep {!/^\[/} map {
		my @split = split /\s+/, $_;
		# slice out 10th to last elements of ps aux rows
		my $final = $#split;
		# some stuff has a lot of data, chrome for example
		$final = ($final > ($ps_cols + 2) ) ? $ps_cols + 2 : $final;
		@split = @split[$ps_cols .. $final];
		join " ", @split;
	} @ps_aux;
	#@ps_cmd = grep {!/^\[/} @ps_cmd;
	# never, because ps loaded before option handler
	print Dumper \@ps_cmd if $test[5];
	eval $end if $b_log;
}

sub set_ps_gui {
	eval $start if $b_log;
	$b_ps_gui = 1;
	my ($working,@match,@temp);
	# desktops / wm (some wm also compositors)
	if ($show{'system'}){
		@temp=qw(razor-desktop razor-session lxsession lxqt-session 
		tdelauncher tdeinit_phase1);
		@match = (@match,@temp);
		@temp=qw(3dwm 9wm afterstep aewm aewm\+\+ amiwm antiwm awesome
		blackbox bspwm 
		cagebreak calmwm (sh|c?lisp).*clfswm (openbsd-)?cwm dwm evilwm 
		fluxbox flwm flwm_topside fvwm.*-crystal fvwm1 fvwm2 fvwm3 fvwm95 fvwm 
		i3 instantwm ion3 jbwm jwm larswm lwm 
		matchbox-window-manager mini musca mwm nawm notion 
		openbox orbital pekwm perceptia python.*qtile qtile qvwm ratpoison 
		sawfish scrotwm spectrwm (sh|c?lisp).*stumpwm sway 
		tinywm tvtwm twm 
		waycooler way-cooler windowlab WindowMaker wm2 wmii2 wmii wmx 
		xfdesktop xmonad yeahwm);
		@match = (@match,@temp);
	}
	# wm:
	if ($show{'system'} && $extra > 1){
		@temp=qw(budgie-wm compiz deepin-wm gala gnome-shell
		twin kwin_wayland kwin_x11 kwin marco 
		deepin-metacity metacity metisse mir muffin deepin-mutter mutter
		ukwm xfwm4 xfwm5);
		@match = (@match,@temp);
		# startx: /bin/sh /usr/bin/startx
		@temp=qw(ly .*startx xinit); # possible dm values
		@match = (@match,@temp);
	}
	# info: NOTE: glx-dock is cairo-dock
	if ($show{'system'} && $extra > 2){
		@temp=qw(alltray awn bar bmpanel bmpanel2 budgie-panel 
		cairo-dock dde-dock dmenu dockbarx docker docky dzen dzen2
		fbpanel fspanel glx-dock gnome-panel hpanel i3bar icewmtray 
		kdocker kicker latte latte-dock lemonbar ltpanel lxpanel lxqt-panel 
		matchbox-panel mate-panel ourico
		perlpanel plank plasma-desktop plasma-netbook polybar pypanel
		razor-panel razorqt-panel stalonetray swaybar taskbar tint2 trayer
		ukui-panel vala-panel wbar wharf wingpanel witray 
		xfce4-panel xfce5-panel xmobar yabar);
		@match = (@match,@temp);
	}
	# compositors (for wayland these are also the server, note.
	# for wayland always show, so always load these
	if ($show{'graphic'} && $extra > 0){
		@temp=qw(3dwm asc budgie-wm compiz compton deepin-wm dwc dcompmgr 
		enlightenment fireplace gnome-shell grefson kmscon kwin_wayland kwin_x11
		liri marco metisse mir moblin motorcar muffin mutter
		orbital papyros perceptia picom rustland sommelier sway swc
		ukwm unagi unity-system-compositor
		wavy waycooler way-cooler wayfire wayhouse westford weston xcompmgr);
		@match = (@match,@temp);
	}
	@match = uniq(@match);
	my $matches = join '|', @match;
	foreach (@ps_cmd){
		if (/^(|[\S]*\/)($matches)(\/|\s|$)/){
			$working = $2;
			push @ps_gui, $working; # deal with duplicates with uniq
		}
	}
	@ps_gui = uniq(@ps_gui) if @ps_gui;
	print Dumper \@ps_gui if $test[5];
	log_data('dump','@ps_gui',\@ps_gui) if $b_log;
	eval $end if $b_log;
}
sub set_sysctl_data {
	eval $start if $b_log;
	return if $alerts{'sysctl'}{'action'} ne 'use';
	my (@temp);
	# darwin sysctl has BOTH = and : separators, and repeats data. Why? 
	if (!$b_fake_sysctl){
		my $program = check_program('sysctl');
		@temp = grabber("$program -a 2>/dev/null");
	}
	else {
		#my $file = "$ENV{'HOME'}/bin/scripts/inxi/data/sysctl/obsd_6.1_sysctl_soekris6501_root.txt";
		#my $file = "$ENV{'HOME'}/bin/scripts/inxi/data/sysctl/obsd_6.1sysctl_lenovot500_user.txt";
		## matches: compaq: openbsd-dmesg.boot-1.txt
		my $file = "$ENV{'HOME'}/bin/scripts/inxi/data/sysctl/openbsd-5.6-sysctl-1.txt"; 
		## matches: toshiba: openbsd-5.6-dmesg.boot-1.txt
		#my $file = "$ENV{'HOME'}/bin/scripts/inxi/data/sysctl/openbsd-5.6-sysctl-2.txt"; 
		@temp = reader($file);
	}
	foreach (@temp){
		$_ =~ s/\s*=\s*|:\s+/:/;
		$_ =~ s/\"//g;
		push @sysctl, $_;
		# we're building these here so we can use these arrays to test 
		# in each feature if we will try to build the feature for bsds
		if (/^hw\.sensors/ && !/^hw\.sensors\.acpi(bat|cmb)/ && !/^hw.sensors.softraid/){
			push @sysctl_sensors, $_;
		}
		elsif (/^hw\.(vendor|product|version|serialno|uuid)/){
			push @sysctl_machine, $_;
		}
		elsif (/^hw\.sensors\.acpi(bat|cmb)/){
			push @sysctl_battery, $_;
		}
	}
	print Dumper \@sysctl if $test[7];
	# this thing can get really long.
	if ($b_log){
		#main::log_data('dump','@sysctl',\@sysctl);
	}
	eval $end if $b_log;
}

## @usb array indexes
# 0 - bus id / sort id
# 1 - device id
# 2 - path_id
# 3 - path
# 4 - class id
# 5 - subclass id
# 6 - protocol id
# 7 - vendor:chip id
# 8 - usb version
# 9 - interfaces
# 10 - ports
# 11 - vendor 
# 12 - product
# 13 - device-name
# 14 - type string
# 15 - driver
# 16 - serial
# 17 - speed
# 18 - configuration - not used
## USBData
{
package USBData;
my (@working);
my ($b_hub,$addr_id,$bus_id,$bus_id_alpha,$chip_id,$class_id,
$device_id,$driver,$ids,$interfaces,$name,$path,$path_id,$product,
$protocol_id,$serial,$speed,$subclass_id,$type,$version,$vendor,$vendor_id,);
my $b_live = 1; # debugger file data
sub set {
	eval $start if $b_log;
	$b_usb_check = 1;
	# if user config sets USB_SYS you can override with --usb-tool
	if ((!$b_usb_sys || $b_usb_tool) && $alerts{'lsusb'}{'action'} eq 'use' ){
		lsusb_data();
	}
	elsif (-d '/sys/bus/usb/devices'){
		sys_data('main');
	}
	elsif ( $alerts{'usbdevs'}{'action'} eq 'use'){
		usbdevs_data();
	}
	eval $end if $b_log;
}

sub lsusb_data {
	eval $start if $b_log;
	my (@temp);
	my @data = data_grabber('lsusb');
	
	foreach (@data){
		next if /^\s*$|^Couldn't/; # expensive second call: || /UNAVAIL/
		@working = split /\s+/, $_;
		$working[3] =~ s/:$//;
		# Seen FreeBSD lsusb with: 
		# Bus /dev/usb Device /dev/ugen0.3: ID 24ae:1003 Shenzhen Rapoo Technology Co., Ltd. 
		next if !main::is_numeric($working[1]) || !main::is_numeric($working[3]);
		$addr_id = int($working[3]);
		$bus_id = int($working[1]);
		$path_id = "$bus_id-$addr_id";
		$chip_id = $working[5];
		@temp = @working[6..$#working];
		$name = join ' ', @temp;
		$name = $name;
		#print "$name\n";
		$working[0] = $bus_id;
		$working[1] = $addr_id;
		$working[2] = $path_id;
		$working[3] = '';
		$working[4] = 0;
		$working[5] = '';
		$working[6] = '';
		$working[7] = $chip_id;
		$working[8] = '';
		$working[9] = '';
		$working[10] = 0;
		$working[11] = '';
		$working[12] = '';
		$working[13] = $name;
		$working[14] = '';
		$working[15] = '';
		$working[16] = '';
		$working[17] = '';
		$working[18] = '';
		@usb = (@usb,[@working]);
		#print join ("\n",@working),"\n\n=====\n";
	}
	print Data::Dumper::Dumper \@usb if $test[6];
	sys_data('lsusb') if @usb;
	print Data::Dumper::Dumper \@usb if $test[6];
	main::log_data('dump','@usb: plain',\@usb) if $b_log;
	eval $end if $b_log;
}

# Controller /dev/usb2:
# addr 1: full speed, self powered, config 1, UHCI root hub(0x0000), Intel(0x8086), rev 1.00
#  port 1 addr 2: full speed, power 98 mA, config 1, USB Receiver(0xc52b), Logitech(0x046d), rev 12.01
#  port 2 powered
sub usbdevs_data {
	eval $start if $b_log;
	my ($class,$hub_id,$port,$port_value);
	my ($ports,$j,$k) = (0,0,0);
	my @data = data_grabber('usbdevs');
	foreach (@data){
		if (/^Controller\s\/dev\/usb([0-9]+)/){
			# $j = scalar @usb;
			($j,$ports) = (0,0);
			$port_value = '';
			$bus_id = $1;
			@working = ();
		}
		elsif (/^addr\s([0-9]+):\s([^,]+),[^,]+,[^,]+,\s?([^,]+)\(0x([0-9a-f]{4})\),\s?([^,]+)\s?\(0x([0-9a-f]{4})\)/){
			$j = scalar @usb;
			$k = $j;
			$hub_id = $1;
			$addr_id = $1;
			$speed = $2;
			$chip_id = "$4:$6";
			$name="$5 $3";
			#print "p1:$protocol\n";
			$path_id = "$bus_id-$hub_id";
			$port_value = '';
			$working[0] = $bus_id;
			$working[1] = $addr_id;
			$working[2] = $path_id;
			$working[3] = '';
			$working[4] = 9;
			$working[5] = '';
			$working[6] = '';
			$working[7] = $chip_id;
			$working[8] = $speed;
			$working[9] = '';
			$working[10] = 0;
			$working[13] = $name;
			$working[14] = 'Hub';
			$working[15] = '';
			$working[16] = '';
			$working[17] = '';
			$working[18] = '';
			$usb[$j] = ([@working],);
			@working = ();
		}
		elsif (/^\s+port\s([0-9]+)\saddr\s([0-9]+):\s([^,]+),[^,]+,[^,]+,\s?([^,]+)\(0x([0-9a-f]{4})\),\s?([^,]+)\s?\(0x([0-9a-f]{4})\)/){
			$j = scalar @usb;
			$port = $1;
			$addr_id = "$2";
			$speed = "$3";
			$chip_id = "$5:$7";
			$name="$6 $4";
			#print "p2:$protocol\n";
			$ports++;
			$path_id = "$bus_id-$hub_id.$port";
			$working[0] = $bus_id;
			$working[1] = $addr_id;
			$working[2] = $path_id;
			$working[3] = '';
			$working[4] = 1;
			$working[5] = '';
			$working[6] = '';
			$working[7] = $chip_id;
			$working[8] = $speed;
			$working[9] = '';
			$working[10] = 0;
			$working[11] = '';
			$working[12] = '';
			$working[13] = $name;
			$working[14] = '';
			$working[15] = '';
			$working[16] = '';
			$working[17] = '';
			$working[18] = '';
			$usb[$j] = ([@working],);
			${$usb[$k]}[10] = $ports;
			@working = ();
		}
		elsif (/^\s+port\s([0-9]+)\spowered/){
			$ports++;
			${$usb[$k]}[10] = $ports;
		}
	}
	if (@working){
		$j = scalar @usb;
		$usb[$j] = (
		[@working],
		);
	}
	main::log_data('dump','@usb: usbdevs',\@usb) if $b_log;
	print Data::Dumper::Dumper \@usb if $test[6];
	eval $end if $b_log;
}

sub data_grabber {
	eval $start if $b_log;
	my ($program) = @_;
	my %args = ('lsusb' => '', 'usbdevs' => '-v');
	my (@data);
	if ($b_live && !$b_fake_usbdevs){
		my $path = main::check_program($program);
		@data = main::grabber("$path $args{$program} 2>/dev/null") if $path;
	}
	else {
		my $file;
		if ($b_fake_usbdevs){
			$file = "$ENV{'HOME'}/bin/scripts/inxi/data/lsusb/bsd-usbdevs-v-1.txt";
		}
		else {
			$file = "$ENV{'HOME'}/bin/scripts/inxi/data/lsusb/mdmarmer-lsusb.txt";
		}
		@data = main::reader($file);
	}
	#print Data::Dumper::Dumper \@data;
	eval $end if $b_log;
	return @data;
}

sub sys_data {
	eval $start if $b_log;
	my ($source) = @_;
	my ($configuration,$ports,$usb_version);
	my (@drivers,@uevent);
	my $i = 0;
	my @files = main::globber('/sys/bus/usb/devices/*');
	# we want to get rid of the hubs with x-0: syntax, those are hubs found in /usbx
	@files = grep {!/\/[0-9]+-0:/} @files;
	#print join "\n", @files;
	foreach (@files){
		@uevent = main::reader("$_/uevent") if -r "$_/uevent";
		$ids = main::awk(\@uevent,'^(DEVNAME|DEVICE\b)',2,'=');
		if ( $ids){
			@drivers = ();
			($b_hub,$class_id,$protocol_id,$subclass_id) = (0,0,0,0);
			($configuration,$driver,$interfaces,$name,$ports,$product,$serial,$speed,
			$type,$usb_version,$vendor) = ('','','','','','','','','','','');
			#print Cwd::abs_path($_),"\n";
			#print "f1: $_\n";
			$path_id = $_;
			$path_id =~ s/^.*\///;
			$path_id =~ s/^usb([0-9]+)/$1-0/;
			# if DEVICE= then path = /proc/bus/usb/001/001 else: bus/usb/006/001
			$ids =~ s/^\///;
			@working = split /\//, $ids;
			shift @working if $working[0] eq 'proc';
			$bus_id = int($working[2]);
			$bus_id_alpha = bus_id_alpha($path_id);
			$device_id = int($working[3]);
			$class_id = sys_item("$_/bDeviceClass");
			$class_id = hex($class_id) if $class_id;
			@drivers = uevent_data("$_/[0-9]*/uevent");
			@drivers = (@drivers, uevent_data("$_/[0-9]*/*/uevent")) if !$b_hub;
			$ports = sys_item("$_/maxchild") if $b_hub;
			$driver = join ',', sort(main::uniq(@drivers)) if @drivers;
			$interfaces = sys_item("$_/bNumInterfaces");
			$serial = sys_item("$_/serial");
			$usb_version = sys_item("$_/version");
			$speed = sys_item("$_/speed");
			$configuration = sys_item("$_/configuration");
			if ($source eq 'lsusb'){
				for ($i = 0; $i < scalar @usb; $i++){
					if (${$usb[$i]}[0] eq $bus_id && ${$usb[$i]}[1] == $device_id){
						#print $type,"\n";
						${$usb[$i]}[0] = $bus_id_alpha;
						${$usb[$i]}[2] = $path_id;
						${$usb[$i]}[3] = $_;
						${$usb[$i]}[4] = $class_id;
						${$usb[$i]}[5] = $subclass_id;
						${$usb[$i]}[6] = $protocol_id;
						${$usb[$i]}[8] = $usb_version;
						${$usb[$i]}[9] = $interfaces;
						${$usb[$i]}[10] = $ports if $ports;
						if ($type && $b_hub && (!${$usb[$i]}[13] || ${$usb[$i]}[13] =~ /^linux foundation/i )){
							${$usb[$i]}[13] = "$type";
						}
						${$usb[$i]}[14] = $type if ($type && !$b_hub);
						${$usb[$i]}[15] = $driver if $driver;
						${$usb[$i]}[16] = $serial if $serial;
						${$usb[$i]}[17] = $speed if $speed;
						${$usb[$i]}[18] = $configuration;
						#print join("\n",@{$usb[$i]}),"\n\n";# if !$b_hub; 
						last;
					}
				}
			}
			else {
				$chip_id = sys_item("$_/idProduct");
				$vendor_id = sys_item("$_/idVendor");
				# we don't want the device, it's probably a bad path in /sys/bus/usb/devices
				next if !$vendor_id && !$chip_id;
				$product = sys_item("$_/product");
				$product = main::cleaner($product) if $product;
				$vendor = sys_item("$_/manufacturer");
				$vendor = main::cleaner($vendor) if $vendor;
				if (!$b_hub && ($product || $vendor )){
					if ($vendor && $product && $product !~ /$vendor/){
						$name = "$vendor $product";
					}
					elsif ($product){
						$name = $product;
					}
					elsif ($vendor){
						$name = $vendor;
					}
				}
				elsif ($b_hub){
					$name = $type;
				}
				# this isn't that useful, but save in case something shows up
				#if ($configuration){
				#	$name = ($name) ? "$name $configuration" : $configuration;
				#}
				$type = 'Hub' if $b_hub;
				${$usb[$i]}[0] = $bus_id_alpha;
				${$usb[$i]}[1] = $device_id;
				${$usb[$i]}[2] = $path_id;
				${$usb[$i]}[3] = $_;
				${$usb[$i]}[4] = $class_id;
				${$usb[$i]}[5] = $subclass_id;
				${$usb[$i]}[6] = $protocol_id;
				${$usb[$i]}[7] = "$vendor_id:$chip_id";
				${$usb[$i]}[8] = $usb_version;
				${$usb[$i]}[9] = $interfaces;
				${$usb[$i]}[10] = $ports;
				${$usb[$i]}[11] = $vendor;
				${$usb[$i]}[12] = $product;
				${$usb[$i]}[13] = $name;
				${$usb[$i]}[14] = $type;
				${$usb[$i]}[15] = $driver;
				${$usb[$i]}[16] = $serial;
				${$usb[$i]}[17] = $speed;
				${$usb[$i]}[18] = $configuration;
				$i++;
			}
			#print "$path_id ids: $bus_id:$device_id driver: $driver ports: $ports\n==========\n"; # if $test[6];;
		}
	}
	@usb = sort { $a->[0] cmp $b->[0] } @usb;
	print Data::Dumper::Dumper \@usb if $source eq 'main' && $test[6];
	main::log_data('dump','@usb: sys',\@usb) if $source eq 'main' && $b_log;
	eval $end if $b_log;
}
# get driver, interface [type:] data
sub uevent_data {
	my ($path) = @_;
	my ($interface,$interfaces,$temp,@interfaces,@drivers);
	my @files = main::globber($path);
	@files = grep {!/\/(subsystem|driver|ep_[^\/]+)\/uevent$/} @files if @files;
	foreach (@files){
		last if $b_hub;
		# print "f2: $_\n";
		($interface) = ('');
		@working = main::reader($_) if -r $_;
		#print join ("\n",@working), "\n";
		if (@working){
			$driver = main::awk(\@working,'^DRIVER',2,'=');
			$interface = main::awk(\@working,'^INTERFACE',2,'=');
			if ($interface){
				$interface = device_type($interface);
				if ($interface){
					if ($interface ne '<vendor specific>'){
						push @interfaces, $interface;
					}
					# networking requires more data but this test is reliable
					elsif (!@interfaces) {
						$temp = $_;
						$temp =~ s/\/uevent$//;
						push @interfaces, 'Network' if -d "$temp/net/";
					}
					if (!@interfaces){
						push @interfaces, $interface;
					}
				}
			}
		}
		#print "driver:$driver\n";
		$b_hub = 1 if $driver && $driver eq 'hub';
		$driver = '' if $driver && ($driver eq 'usb' || $driver eq 'hub');
		push @drivers,$driver if $driver;
	}
	if (@interfaces){
		@interfaces = main::uniq(@interfaces);
		# clear out values like: <vendor defined>,Printer
		if ( scalar @interfaces > 1 && (grep {/^<vendor/} @interfaces) && (grep {!/^<vendor/} @interfaces) ){
			@interfaces = grep {/^<vendor/} @interfaces;
		}
		$type = join ',', @interfaces;
		# print "type:$type\n";
	}
	return @drivers;
}
sub sys_item {
	my ($path) = @_;
	my ($item);
	$item = (main::reader($path))[0] if -r $path;
	$item = '' if ! defined $item;
	$item = main::trimmer($item) if $item;
	return $item;
}

sub device_type {
	my ($data) = @_;
	my ($type);
	my @types = split /\//, $data if $data;
	#print @types,"\n";
	if (scalar @types == 3){
		$class_id = $types[0];
		$subclass_id = $types[1];
		$protocol_id = $types[2];
	}
	if (!@types || $types[0] eq '0' || scalar @types != 3) {return '';}
	elsif ($types[0] eq '255') { return '<vendor specific>';}
	
	if ($types[0] eq '1'){$type = 'Audio';}
	elsif ($types[0] eq '2'){
		if ($types[1] eq '2'){$type = 'Abstract (modem)';}
		elsif ($types[1] eq '6'){$type = 'Ethernet Network';}
		elsif ($types[1] eq '10'){$type = 'Mobile Direct Line';}
		elsif ($types[1] eq '12'){$type = 'Ethernet Emulation';}
		else {$type = 'Communication';}
	}
	elsif ($types[0] eq '3'){
		if ($types[2] eq '0'){$type = 'HID';} # actual value: None
		elsif ($types[2] eq '1'){$type = 'Keyboard';}
		elsif ($types[2] eq '2'){$type = 'Mouse';}
	}
	elsif ($types[0] eq '6'){$type = 'Still Imaging';}
	elsif ($types[0] eq '7'){$type = 'Printer';}
	elsif ($types[0] eq '8'){$type = 'Mass Storage';}
	elsif ($types[0] eq '9'){
		if ($types[2] eq '0'){$type = 'Full speed (or root) Hub';}
		elsif ($types[2] eq '1'){$type = 'Hi-speed hub with single TT';}
		elsif ($types[2] eq '2'){$type = 'Hi-speed hub with multiple TTs';}
	}
	elsif ($types[0] eq '10'){$type = 'CDC-Data';}
	elsif ($types[0] eq '11'){$type = 'Smart Card';}
	elsif ($types[0] eq '13'){$type = 'Content Security';}
	elsif ($types[0] eq '14'){$type = 'Video';}
	elsif ($types[0] eq '15'){$type = 'Personal Healthcare';}
	elsif ($types[0] eq '16'){$type = 'Audio-Video';}
	elsif ($types[0] eq '17'){$type = 'Billboard';}
	elsif ($types[0] eq '18'){$type = 'Type-C Bridge';}
	elsif ($types[0] eq '88'){$type = 'Xbox';}
	elsif ($types[0] eq '220'){$type = 'Diagnostic';}
	elsif ($types[0] eq '224'){
		if ($types[1] eq '1'){$type = 'Bluetooth';}
		elsif ($types[1] eq '2'){
			if ($types[2] eq '1'){$type = 'Host Wire Adapter';}
			elsif ($types[2] eq '2'){$type = 'Device Wire Adapter';}
			elsif ($types[2] eq '3'){$type = 'Device Wire Adapter';}
		}
	}
	
	return $type;
}
# this is used to create an alpha sortable bus id for main $usb[0]
sub bus_id_alpha {
	my ($id) = @_;
	$id =~ s/^([1-9])-/0$1-/;
	$id =~ s/([-\.:])([0-9])\b/${1}0$2/g;
	return $id;
}
}

########################################################################
#### GENERATE LINES
########################################################################

#### -------------------------------------------------------------------
#### LINE CONTROLLERS
#### -------------------------------------------------------------------

sub assign_data {
	my (%row) = @_;
	return if ! %row;
	if ($output_type eq 'screen'){
		print_data(%row);
	}
	else {
		%rows = (%rows,%row);
	}
}

sub generate_lines {
	eval $start if $b_log;
	my (%row,$b_pci_check,$b_dmi_check);
	set_ps_aux() if ! @ps_aux;
	set_sysctl_data() if $b_sysctl;
	# note: ps aux loads before logging starts, so create debugger data here
	if ($b_log){
		# I don't think we need to see this, it's long, but leave in case we do
		#main::log_data('dump','@ps_aux',\@ps_aux);
		log_data('dump','@ps_cmd',\@ps_cmd);
	}
	if ( $show{'short'} ){
		set_dmesg_boot_data() if ($bsd_type && !$b_dmesg_boot_check);
		%row = generate_short_data();
		assign_data(%row);
	}
	else {
		if ( $show{'system'} ){
			%row = generate_system_data();
			assign_data(%row);
		}
		if ( $show{'machine'} ){
			set_dmi_data($b_dmi_check) if $b_dmi && !$b_dmi_check; 
			set_dmesg_boot_data() if ($bsd_type && !$b_dmesg_boot_check);
			%row = line_handler('Machine','machine');
			assign_data(%row);
		}
		if ( $show{'battery'} ){
			set_dmi_data($b_dmi_check) if $b_dmi && !$b_dmi_check; 
			%row = line_handler('Battery','battery');
			if (%row || $show{'battery-forced'}){
				assign_data(%row);
			}
		}
		if ( $show{'ram'} ){
			set_dmi_data($b_dmi_check) if $b_dmi && !$b_dmi_check; 
			%row = line_handler('Memory','ram');
			assign_data(%row);
		}
		if ( $show{'slot'} ){
			set_dmi_data($b_dmi_check) if $b_dmi && !$b_dmi_check; 
			%row = line_handler('PCI Slots','slot');
			assign_data(%row);
		}
		if ( $show{'cpu'} || $show{'cpu-basic'} ){
			DeviceData::set($b_pci_check) if $b_arm && !$b_pci_check;
			set_dmi_data($b_dmi_check) if $b_dmi && !$b_dmi_check; 
			set_dmesg_boot_data() if ($bsd_type && !$b_dmesg_boot_check);
			my $arg = ($show{'cpu-basic'}) ? 'basic' : 'full' ;
			%row = line_handler('CPU','cpu',$arg);
			assign_data(%row);
		}
		if ( $show{'graphic'} ){
			USBData::set() if !$b_usb_check;
			DeviceData::set($b_pci_check) if !$b_pci_check; 
			%row = line_handler('Graphics','graphic');
			assign_data(%row);
		}
		if ( $show{'audio'} ){
			# Note: USBData is set internally in AudioData because it's only run in one case
			DeviceData::set($b_pci_check) if !$b_pci_check; 
			%row = line_handler('Audio','audio');
			assign_data(%row);
		}
		if ( $show{'network'} ){
			USBData::set() if !$b_usb_check;
			DeviceData::set($b_pci_check) if !$b_pci_check; 
			set_ip_data() if ($show{'ip'} || ($bsd_type && $show{'network-advanced'}));
			%row = line_handler('Network','network');
			assign_data(%row);
		}
		if ( $show{'disk'} || $show{'disk-basic'} || $show{'disk-total'} || $show{'optical'} ){
			set_dmesg_boot_data() if ($bsd_type && !$b_dmesg_boot_check);
			%row = line_handler('Drives','disk');
			assign_data(%row);
		}
		if ( $show{'raid'} ){
			DeviceData::set() if !$b_pci_check; 
			%row = line_handler('RAID','raid');
			assign_data(%row);
		}
		if ( $show{'partition'} || $show{'partition-full'}){
			%row = line_handler('Partition','partition');
			assign_data(%row);
		}
		if ( $show{'swap'} ){
			%row = line_handler('Swap','swap');
			assign_data(%row);
		}
		if ( $show{'unmounted'} ){
			%row = line_handler('Unmounted','unmounted');
			assign_data(%row);
		}
		if ( $show{'usb'} ){
			USBData::set() if !$b_usb_check;
			%row = line_handler('USB','usb');
			assign_data(%row);
		}
		if ( $show{'sensor'} ){
			%row = line_handler('Sensors','sensor');
			assign_data(%row);
		}
		if ( $show{'repo'} ){
			%row = line_handler('Repos','repo');
			assign_data(%row);
		}
		if ( $show{'process'} ){
			%row = line_handler('Processes','process');
			assign_data(%row);
		}
		if ( $show{'weather'} ){
			%row = line_handler('Weather','weather');
			assign_data(%row);
		}
		if ( $show{'info'} ){
			%row = generate_info_data();
			assign_data(%row);
		}
	}
	if ( $output_type ne 'screen' ){
		output_handler(%rows);
	}
	eval $end if $b_log;
}

sub line_handler {
	eval $start if $b_log;
	my ($key,$sub,$arg) = @_;
	my %subs = (
	'audio' => \&AudioData::get,
	'battery' => \&BatteryData::get,
	'cpu' => \&CpuData::get,
	'disk' => \&DiskData::get,
	'graphic' => \&GraphicData::get,
	'machine' => \&MachineData::get,
	'network' => \&NetworkData::get,
	'partition' => \&PartitionData::get,
	'raid' => \&RaidData::get,
	'ram' => \&RamData::get,
	'repo' => \&RepoData::get,
	'process' => \&ProcessData::get,
	'sensor' => \&SensorData::get,
	'slot' => \&SlotData::get,
	'swap' => \&SwapData::get,
	'unmounted' => \&UnmountedData::get,
	'usb' => \&UsbData::get,
	'weather' => \&WeatherData::get,
	);
	my (%data);
	my $data_name = main::key($prefix++,1,0,$key);
	my @rows = $subs{$sub}->($arg);
	if (@rows){
		%data = ($data_name => \@rows,);
	}
	eval $end if $b_log;
	return %data;
}

#### -------------------------------------------------------------------
#### SHORT, DEBUG
#### -------------------------------------------------------------------

sub generate_short_data {
	eval $start if $b_log;
	my $num = 0;
	my $kernel_os = ($bsd_type) ? 'OS' : 'Kernel';
	get_shell_data($client{'ppid'}) if $client{'ppid'};
	my $client = $client{'name-print'};
	my $client_shell = ($b_irc) ? 'Client' : 'Shell';
	if ($client{'version'}){
		$client .= ' ' . $client{'version'};
	}
	my ($cpu_string,$speed,$speed_key,$type) = ('','','speed','');
	my $memory = get_memory_data('string');
 	my @cpu = CpuData::get('short');
 	if (scalar @cpu > 1){
		$type = ($cpu[2]) ? " (-$cpu[2]-)" : '';
		($speed,$speed_key) = ('','');
		if ($cpu[6]){
			$speed_key = "$cpu[3]/$cpu[5]";
			$cpu[4] =~ s/ MHz//;
			$speed = "$cpu[4]/$cpu[6]";
		}
		else {
			$speed_key = $cpu[3];
			$speed = $cpu[4];
		}
		$cpu[1] ||= row_defaults('cpu-model-null');
		$cpu_string = $cpu[0] . ' ' . $cpu[1] . $type;
	}
	elsif ($bsd_type) {
		if ($alerts{'sysctl'}{'action'}){
			if ($alerts{'sysctl'}{'action'} ne 'use'){
				$cpu_string = "sysctl $alerts{'sysctl'}{'action'}";
				$speed = "sysctl $alerts{'sysctl'}{'action'}";
			}
			else {
				$cpu_string = 'bsd support coming';
				$speed = 'bsd support coming';
			}
		}
	}
	my @disk = DiskData::get('short');
	# print Dumper \@disk;
	my $disk_string = 'N/A';
	my ($size,$used,$size_type,$used_type) = ('','','','');
	my (@temp,$size_holder,$used_holder);
	if (@disk){
		$size = $disk[0]{'size'};
		# must be > 0
		if ($disk[0]{'size'} && is_numeric($disk[0]{'size'}) ){
			$size_holder = $disk[0]{'size'};
			@temp = get_size($size);
			$size = $temp[0];
			$size_type = " $temp[1]";
		}
		$used = $disk[0]{'used'};
		if (is_numeric($disk[0]{'used'}) ){
			$used_holder = $disk[0]{'used'};
			@temp = get_size($used);
			$used = $temp[0];
			$used_type = " $temp[1]";
		}
		# in some fringe cases size can be 0 so only assign 'N/A' if no percents etc
		if ($size_holder && $used_holder){
			my $percent = ' (' . sprintf("%.1f", $used_holder/$size_holder*100) . '% used)';
			$disk_string = "$size$size_type$percent";
		}
		else {
			$size ||= row_defaults('disk-size-0');
			$disk_string = "$used$used_type/$size$size_type";
		}
	}
 	#print join '; ', @cpu, " sleep: $cpu_sleep\n";
	$memory ||= 'N/A';
	my @data = ({
		main::key($num++,0,0,'CPU') => $cpu_string,
		main::key($num++,0,0,$speed_key) => $speed,
		main::key($num++,0,0,$kernel_os) => &get_kernel_data(),
		main::key($num++,0,0,'Up') => &get_uptime(),
		main::key($num++,0,0,'Mem') => $memory,
		main::key($num++,0,0,'Storage') => $disk_string,
		# could make -1 for ps aux itself, -2 for ps aux and self
		main::key($num++,0,0,'Procs') => scalar @ps_aux,
		main::key($num++,0,0,$client_shell) => $client,
		main::key($num++,0,0,$self_name) => &get_self_version(),
	},);
	my %row = (
	main::key($prefix,1,0,'SHORT') => [(@data),],
	);
	eval $end if $b_log;
	return %row;
}

#### -------------------------------------------------------------------
#### CONSTRUCTED LINES
#### -------------------------------------------------------------------

sub generate_info_data {
	eval $start if $b_log;
	my $num = 0;
	my $gcc_alt = '';
	my $running_in = '';
	my $data_name = main::key($prefix++,1,0,'Info');
	my ($b_gcc,$gcc,$index,$ref,%row);
	my ($gpu_ram,$parent,$percent,$total,$used) = (0,'','','','');
	my @gccs = get_gcc_data();
	if (@gccs){
		$gcc = shift @gccs;
		if ($extra > 1 && @gccs){
			$gcc_alt = join '/', @gccs;
		}
		$b_gcc = 1;
	}
	$gcc ||= 'N/A';
	get_shell_data($client{'ppid'}) if $client{'ppid'};
	my $client_shell = ($b_irc) ? 'Client' : 'Shell';
	my $client = $client{'name-print'};
	my %data = (
	$data_name => [{
	main::key($num++,0,1,'Processes') => scalar @ps_aux, 
	main::key($num++,1,1,'Uptime') => &get_uptime(),
	},],
	);
	$index = scalar(@{ $data{$data_name} } ) - 1;
	if ($extra > 2){
		my $wakeups = get_wakeups();
		$data{$data_name}[$index]{main::key($num++,0,2,'wakeups')} = $wakeups if defined $wakeups;
	}
	if (!$b_mem){
		my $memory = get_memory_data('splits');
		if ($memory){
			my @temp = split /:/, $memory;
			my @temp2 = get_size($temp[0]);
			$gpu_ram = $temp[3] if $temp[3];
			$total = ($temp2[1]) ? $temp2[0] . ' ' . $temp2[1] : $temp2[0];
			@temp2 = get_size($temp[1]);
			$used = ($temp2[1]) ? $temp2[0] . ' ' . $temp2[1] : $temp2[0];
			$used .= " ($temp[2]%)" if $temp[2];
			if ($gpu_ram){
				@temp2 = get_size($gpu_ram);
				$gpu_ram = $temp2[0] . ' ' . $temp2[1] if $temp2[1];
			}
		}
		$data{$data_name}[$index]{main::key($num++,1,1,'Memory')} = $total;
		$data{$data_name}[$index]{main::key($num++,0,2,'used')} = $used;
	}
	if ($gpu_ram){
		$data{$data_name}[$index]{main::key($num++,0,2,'gpu')} = $gpu_ram;
	}
	if ( (!$b_display || $b_force_display) || $extra > 0 ){
		my %init = get_init_data();
		my $init_type = ($init{'init-type'}) ? $init{'init-type'}: 'N/A';
		$data{$data_name}[$index]{main::key($num++,1,1,'Init')} = $init_type;
		if ($extra > 1 ){
			my $init_version = ($init{'init-version'}) ? $init{'init-version'}: 'N/A';
			$data{$data_name}[$index]{main::key($num++,0,2,'v')} = $init_version;
		}
		if ($init{'rc-type'}){
			$data{$data_name}[$index]{main::key($num++,1,2,'rc')} = $init{'rc-type'};
			if ($init{'rc-version'}){
				$data{$data_name}[$index]{main::key($num++,0,3,'v')} = $init{'rc-version'};
			}
		}
		if ($init{'runlevel'}){
			$data{$data_name}[$index]{main::key($num++,0,2,'runlevel')} = $init{'runlevel'};
		}
		if ($extra > 1 ){
			if ($init{'default'}){
				my $default = ($init{'init-type'} eq 'systemd' && $init{'default'} =~ /[^0-9]$/ ) ? 'target' : 'default';
				$data{$data_name}[$index]{main::key($num++,0,2,$default)} = $init{'default'};
			}
		}
	}
	if ($extra > 0 ){
		my $b_clang;
		my $clang_version = '';
		if (my $path = check_program('clang')){
			$clang_version = program_version($path,'clang',3,'--version');
			$clang_version ||= 'N/A';
			$b_clang = 1;
		}
		my $compiler = ($b_gcc || $b_clang) ? '': 'N/A';
		$data{$data_name}[$index]{main::key($num++,1,1,'Compilers')} = $compiler;
		if ($b_gcc){
			$data{$data_name}[$index]{main::key($num++,1,2,'gcc')} = $gcc;
			if ( $extra > 1 && $gcc_alt){
				$data{$data_name}[$index]{main::key($num++,0,3,'alt')} = $gcc_alt;
			}
		}
		if ($b_clang){
			$data{$data_name}[$index]{main::key($num++,0,2,'clang')} = $clang_version;
		}
	}
	if ($extra > 0 && !$b_pkg){
		my %packages = PackageData::get('inner',\$num);
		for (keys %packages){
			$data{$data_name}[$index]{$_} = $packages{$_};
		}
		$b_pkg = 1;
	}
	if (!$b_irc && $extra > 1 ){
		# bsds don't support -f option to get PPID
		if (($b_display && !$b_force_display) && !$bsd_type){
			$parent = get_shell_source();
		}
		else {
			$parent = get_tty_number();
			$parent = "tty $parent" if $parent ne '';
		}
		if ($parent eq 'login'){
			$client{'su-start'} = $parent if !$client{'su-start'};
			$parent = undef;
		}
		# can be tty 0 so test for defined
		$running_in = $parent if defined $parent;
		if ($extra > 2 && $running_in && get_ssh_status() ){
			$running_in .= ' (SSH)';
		}
	}
	if ($extra > 2 && $client{'su-start'}){
		$client .= " ($client{'su-start'})";
	}
	$data{$data_name}[$index]{main::key($num++,1,1,$client_shell)} =  $client;
	if ($extra > 0 && $client{'version'}){
		$data{$data_name}[$index]{main::key($num++,0,2,'v')} = $client{'version'};
	}
	if ($extra > 2 && $client{'default-shell'}){
		$data{$data_name}[$index]{main::key($num++,1,2,'default')} = $client{'default-shell'};
		$data{$data_name}[$index]{main::key($num++,0,3,'v')} = $client{'default-shell-v'} if $client{'default-shell-v'};
	}
	if ( $running_in ){
		$data{$data_name}[$index]{main::key($num++,0,2,'running in')} = $running_in;
	}
	$data{$data_name}[$index]{main::key($num++,0,1,$self_name)} = &get_self_version();
	
	eval $end if $b_log;
	return %data;
}

sub generate_system_data {
	eval $start if $b_log;
	my ($cont_desk,$ind_dm,$num) = (1,2,0);
	my (%row,$ref,$index,$val1);
	my $data_name = main::key($prefix++,1,0,'System');
	my ($desktop,$desktop_info,$desktop_key,$dm_key,$toolkit,$wm) = ('','','Desktop','dm','','');
	my (@desktop_data,$desktop_version);
	
	my %data = (
	$data_name => [{}],
	);
	$index = scalar(@{ $data{$data_name} } ) - 1;
	if ($show{'host'}){
		$data{$data_name}[$index]{main::key($num++,0,1,'Host')} = get_hostname();
	}
	$data{$data_name}[$index]{main::key($num++,1,1,'Kernel')} = get_kernel_data();
	$data{$data_name}[$index]{main::key($num++,0,2,'bits')} = get_kernel_bits();
	if ($extra > 0){
		my @compiler = get_compiler_version(); # get compiler data
		if (scalar @compiler != 2){
			@compiler = ('N/A', '');
		}
		$data{$data_name}[$index]{main::key($num++,1,2,'compiler')} = $compiler[0];
		# if no compiler, obviously no version, so don't waste space showing.
		if ($compiler[0] ne 'N/A'){
			$compiler[1] ||= 'N/A';
			$data{$data_name}[$index]{main::key($num++,0,3,'v')} = $compiler[1];
		}
	}
	if ($b_admin && (my $params = get_kernel_parameters())){
		$index = scalar(@{ $data{$data_name} } );
		#print "$params\n";
		$params = apply_partition_filter('system', $params, 'label') if $use{'filter-label'};
		$params = apply_partition_filter('system', $params, 'uuid') if $use{'filter-uuid'};
		$data{$data_name}[$index]{main::key($num++,0,2,'parameters')} = $params;
		$index = scalar(@{ $data{$data_name} } );
	}
	# note: tty can have the value of 0 but the two tools 
	# return '' if undefined, so we test for explicit ''
	if ($b_display){
		my @desktop_data = DesktopEnvironment::get();
		$desktop = $desktop_data[0] if $desktop_data[0];
		$desktop_version = $desktop_data[1] if $desktop_data[1];
		$desktop .= ' ' . $desktop_version if $desktop_version;
		if ($extra > 0 && $desktop_data[3]){
			#$desktop .= ' (' . $desktop_data[2];
			#$desktop .= ( $desktop_data[3] ) ? ' ' . $desktop_data[3] . ')' : ')';
			$toolkit = "$desktop_data[2] $desktop_data[3]";
		}
		if ($extra > 2 && $desktop_data[4]){
			$desktop_info = $desktop_data[4];
		}
		# don't print the desktop if it's a wm and the same
		if ($extra > 1 && $desktop_data[5] && 
		    (!$desktop_data[0] || $desktop_data[5] =~ /^(deepin.+|gnome[\s_-]shell|budgie.+)$/i || 
		    index(lc($desktop_data[5]),lc($desktop_data[0])) == -1 )){
			$wm = $desktop_data[5];
			$wm .= ' ' . $desktop_data[6] if $extra > 2 && $desktop_data[6];
		}
	}
	if (!$b_display || ( !$desktop && $b_root)) {
		my $tty = get_tty_number();
		if (!$desktop){
			$desktop_info = '';
		}
		# it is defined, as ''
		if ( $tty eq '' && $client{'console-irc'}){
			$tty = get_tty_console_irc('vtnr');
		}
		$desktop = "tty $tty" if $tty ne '';
		$desktop_key = 'Console';
		$dm_key = 'DM';
		$ind_dm = 1;
		$cont_desk = 0;
	}
	$desktop ||= 'N/A';
	$data{$data_name}[$index]{main::key($num++,$cont_desk,1,$desktop_key)} = $desktop;
	if ($toolkit){
		$data{$data_name}[$index]{main::key($num++,0,2,'tk')} = $toolkit;
	}
	if ($extra > 2){
		if ($desktop_info){
			$data{$data_name}[$index]{main::key($num++,0,2,'info')} = $desktop_info;
		}
	}
	if ($extra > 1){
		$data{$data_name}[$index]{main::key($num++,0,2,'wm')} = $wm if $wm;
		my $dms = get_display_manager();
		if ($dms || $desktop_key ne 'Console'){
			$dms ||= 'N/A';
			$data{$data_name}[$index]{main::key($num++,0,$ind_dm,$dm_key)} = $dms;
		}
	}
	#if ($extra > 2 && $desktop_key ne 'Console'){
	#	my $tty = get_tty_number();
	#	$data{$data_name}[$index]{main::key($num++,0,1,'vc')} = $tty if $tty ne '';
	#}
	my $distro_key = ($bsd_type) ? 'OS': 'Distro';
	my @distro_data = DistroData::get();
	my $distro = $distro_data[0];
	$distro ||= 'N/A';
	$data{$data_name}[$index]{main::key($num++,1,1,$distro_key)} = $distro;
	if ($extra > 0 && $distro_data[1]){
		$data{$data_name}[$index]{main::key($num++,0,2,'base')} = $distro_data[1];
	}
	eval $end if $b_log;
	return %data;
}

#######################################################################
#### LAUNCH
########################################################################

main(); ## From the End comes the Beginning

## note: this EOF is needed for smxi handling, this is what triggers the full download ok
###**EOF**###
