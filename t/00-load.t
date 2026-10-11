#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;

for (qw(
  SICK::Target::Proxmox::Client
  SICK::Target::Proxmox::Role
  SICK::Target::ProxmoxVE
  SICK::Target::ProxmoxBS
)) {
  use_ok($_);
}

is( $_->VERSION, SICK::Target::ProxmoxVE->VERSION, $_.' carries the version of the distribution' )
  for qw( SICK::Target::Proxmox::Client SICK::Target::Proxmox::Role SICK::Target::ProxmoxBS );

for my $class (qw( SICK::Target::ProxmoxVE SICK::Target::ProxmoxBS )) {
  ok( $class->isa('SICK::Target'), $class.' is a SICK::Target' );
  ok( $class->DOES('SICK::Target::Proxmox::Role'), $class.' does the shared role' );
}

use SICK::Target;
is( SICK::Target->class_for('proxmox-ve'), 'SICK::Target::ProxmoxVE', 'type proxmox-ve' );
is( SICK::Target->class_for('proxmoxve'),  'SICK::Target::ProxmoxVE', 'type proxmoxve, as the acme.sh hook is named' );
is( SICK::Target->class_for('proxmox-bs'), 'SICK::Target::ProxmoxBS', 'type proxmox-bs' );
ok( !eval { SICK::Target->class_for('proxmox'); 1 }, 'the shared part below SICK/Target/Proxmox/ is no type of its own' );

done_testing;
