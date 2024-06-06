#!/usr/bin/perl

# Virtiofs proxmox hook script
#
# Sets up systemd units that run virtiofsd when a VM starts
#
# Usage:
# - Add this script and virtiofs_hook.conf on a pve managed storage location under "snippets"
# - Make this script executable (chmod +x virtiofs_hook.pl)
# - Configure the shares per each VM on virtiofs_hook.conf (on the same folder of this script)
#   - Syntax:
#     vmid_1: path_to_share_1
#     vmid_2: path_to_share_1, path_to_share_2, ...
#     ...
# - Install the hookscript to he desired VMs using `qm set <vmid> --hookscript <storage>:snippets/virtiofs_hook.pl`

use strict;
use warnings;

my $virtiofsd_path = "/usr/libexec/virtiofs"; # The virtiofsd binary path.
my $DEBUG = 0; # enables verbose output of the script
my $virtiofsd_log_level = $DEBUG == 1 ? 'debug' : 'info';

use Cwd;
use File::Basename;

my $script_dir = dirname(Cwd::abs_path($0));
my $conf_file = "$script_dir/virtiofs_hook.conf";
my %vmid_path_map;

open my $cfg, '<', $conf_file or die "Failed to open $conf_file";
while (my $line = <$cfg>) {
    chomp $line;
    my ($vmid, $paths_str) = split /:/, $line;
    my @path = split /,/, $paths_str;
    $vmid_path_map{$vmid} = \@path;
}

close $cfg or warn "Close $conf_file failed: $!";

use PVE::QemuServer;

use Template;
my $tt = Template->new;

print "STARTING VIRTIOFS HOOKSCRIPT: " . join(' ', @ARGV) . "\n";

my $vmid = shift;
my $conf = PVE::QemuConfig->load_config($vmid);
my $vfs_args_file = "/run/$vmid.virtfs";
my $virtiofsd_dir = "/run/virtiofsd/";
my $phase = shift;

my $unit_tpl = "[Unit]
Description=virtiofsd filesystem share at [% share %] for VM %i
StopWhenUnneeded=true

[Service]
Type=simple
RuntimeDirectory=virtiofsd
PIDFile=/run/virtiofsd/.run.virtiofsd.%i-[% share_id %].sock.pid
ExecStart=$virtiofsd_path --log-level $virtiofsd_log_level --socket-path /run/virtiofsd/%i-[% share_id %].sock --shared-dir [% share %] --cache=auto --announce-submounts --inode-file-handles=mandatory

[Install]
RequiredBy=%i.scope\n";

# Given a vmid and a path to share with the vm returns the share id and systemd unit details
sub get_unit_info {
    my ($vmid, $path) = @_;
    my $share_id = $path =~ m/.*\/([^\/]+)/ ? $1 : '';
    my $unit_name = 'virtiofsd-' . $vmid . '-' . $share_id;
    my $unit_file = '/etc/systemd/system/' . $unit_name . '@.service';

    return {
        share_id  => $share_id,
        unit_name => $unit_name,
        unit_file => $unit_file,
    };
}

# Cleanup systemd units for a given vmid
sub cleanup_vm_units {
  my ($vmid) = @_;

  for my $path (@{$vmid_path_map{$vmid}}) {
    my $unit_info = get_unit_info($vmid, $path);

    my $unit_name = $unit_info->{unit_name};
    my $unit_file = $unit_info->{unit_file};

    print "attempting to remove unit $unit_name ...\n";

    system("/usr/bin/systemctl stop $unit_name\@$vmid.service");
    system("/usr/bin/systemctl disable $unit_name\@$vmid.service");
    unlink $unit_file or warn "Could not delete $unit_file: $!";
    system("/usr/bin/systemctl daemon-reload");
  }
}

if ($phase eq 'pre-start') {
  print "$vmid is starting, doing preparations.\n";

  my $vfs_args = "-object memory-backend-memfd,id=mem,size=$conf->{memory}M,share=on -numa node,memdev=mem";
  my $char_id = 0;

  # Create the virtiofsd directory if it doesn't exist
  if (not -d $virtiofsd_dir) {
     print "Creating directory: $virtiofsd_dir\n";
     mkdir $virtiofsd_dir or die "Failed to create $virtiofsd_dir: $!";
    }

  for my $path (@{$vmid_path_map{$vmid}}) {
    my $unit_info = get_unit_info($vmid, $path);

    my $share_id = $unit_info->{share_id};
    my $unit_name = $unit_info->{unit_name};
    my $unit_file = $unit_info->{unit_file};

    print "attempting to install unit $unit_name ...\n";
    if (not -d $virtiofsd_dir) {
        print "ERROR: $virtiofsd_dir does not exist!\nCleaning up...\n";
        cleanup_vm_units($vmid);
        die;
    }

    if (not -e $unit_file) {
      if (!$tt->process(\$unit_tpl, { share => $path, share_id => $share_id }, $unit_file)) {
        cleanup_vm_units($vmid);
        die $tt->error(), "\n";
      }
      system("/usr/bin/systemctl daemon-reload");
      system("/usr/bin/systemctl enable $unit_name\@$vmid.service");
    }

    system("/usr/bin/systemctl start $unit_name\@$vmid.service");
    $vfs_args .= " -chardev socket,id=char$char_id,path=/run/virtiofsd/$vmid-$share_id.sock";
    $vfs_args .= " -device vhost-user-fs-pci,chardev=char$char_id,tag=$vmid-$share_id";
    $char_id += 1;
  }

  open(FH, '>', $vfs_args_file) or die $!;
  print FH $vfs_args;
  close(FH);

  print "VM generated virtiofs arguments: " . $vfs_args . "\n" if $DEBUG;
  if (defined($conf->{args}) && not $conf->{args} =~ /$vfs_args/) {
    print "Appending virtiofs arguments to existing VM args.\n";
    $conf->{args} .= " $vfs_args";
  } else {
    print "Setting VM args to generated virtiofs arguments.\n";
    $conf->{args} = " $vfs_args";
  }
  print "VM arguments: $conf->{args}\n" if $DEBUG;
  PVE::QemuConfig->write_config($vmid, $conf);
}
elsif($phase eq 'post-start') {
  print "$vmid started successfully.\n";
  my $vfs_args = do {
    local $/ = undef;
    open my $fh, "<", $vfs_args_file or die $!;
    <$fh>;
  };
  unlink $vfs_args_file or warn "Could not delete $vfs_args_file: $!";

  if ($conf->{args} =~ /$vfs_args/) {
    print "Removing virtiofs arguments from VM args.\n";
    print "conf->args = $conf->{args}\n" if $DEBUG;
    print "vfs_args = $vfs_args\n" if $DEBUG;
    $conf->{args} =~ s/\ *$vfs_args//g;
    print $conf->{args};
    $conf->{args} = undef if $conf->{args} =~ /^$/;
    print "conf->args = $conf->{args}\n" if $DEBUG;
    PVE::QemuConfig->write_config($vmid, $conf) if defined($conf->{args});
  }
}
elsif($phase eq 'pre-stop') {
  # print "$vmid will be stopped.\n";
}
elsif($phase eq 'post-stop') {
  print "$vmid stopped. Cleaning up virtiofs systemd units.\n";
  cleanup_vm_units($vmid);
} else {
  die "got unknown phase '$phase'\n";
}

print "ENDING VIRTIOFS HOOKSCRIPT\n";
exit(0);
