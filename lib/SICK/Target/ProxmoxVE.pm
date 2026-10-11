package SICK::Target::ProxmoxVE;
# ABSTRACT: SICK target for the web interface and API of Proxmox VE nodes

use Moo;
extends 'SICK::Target';
with 'SICK::Target::Proxmox::Role';
use Carp qw( croak );
use JSON::MaybeXS qw( JSON );
use namespace::autoclean;

our $VERSION = '0.001';

=head1 SYNOPSIS

In the device list of L<SICK>:

    devices:
      pve1:
        type: proxmox-ve
        host: pve1.example.internal
        port: 8006
        names: [pve1.example.internal]
        node: pve1                                # the node name as in the GUI
        token_id: sick@pve!sick
        token_file: /etc/sick/pve1.token          # one line: the secret
        ca:
          - /etc/sick/pve-root-ca.pem             # the cluster CA, for the first upload
          - /etc/sick/root.pem                    # our root, from then on

Then

    sick check pve1
    sick run pve1

=head1 DESCRIPTION

Puts the certificate of the web interface and API of a Proxmox VE node - the
one C<pveproxy> serves on port 8006 - onto the node, through the API of the
node itself: C<POST /api2/json/nodes/E<lt>nodeE<gt>/certificates/custom>
with certificate, chain and key, C<force> and C<restart> set. The node writes
C<pveproxy-ssl.pem> and C<pveproxy-ssl.key> and reloads C<pveproxy>; L<SICK>
then asks the port until it presents the new certificate.

It replaces the deploy hook C<proxmoxve> of acme.sh, which sends the token
and the key without checking whose certificate the node presents. Here the
connection is checked during the handshake against the anchors of the device
list, and the token and the key go nowhere else (see L</HOW THE NODE IS
TRUSTED>). What the API does, call by call and with the source of each
statement, is in F<docs/api-notes.md> of the distribution.

B<Tried against:> the stand-in under F<t/> (the unit suite), and end to end
through C<sick run> against the real API of Proxmox VE 9.2.21 in a container,
with the lab CA (F<t/e2e/device-proxmox.sh>). In that container C<pveproxy>
is restarted through a C<systemctl> shim; there is no systemd and no
cluster. Not tried: a node under systemd, a cluster, a node across a real
network (F<docs/hq-checklist.md>).

=head1 OPTIONS

=over 4

=item C<node>

Required. The name of the node as Proxmox VE knows it (C</nodes/pve1>); not
derived from C<host>, because in a cluster the wrong name uploads to another
node.

=item C<token_id>

Required. The API token, C<user@realm!tokenname>, for instance
C<sick@pve!sick>. Not secret; it is never quoted in a message all the same.

=item C<token_file>

Required. A file whose first line is the secret of the token (mode C<0600>).
It is read when there is something to upload, put into the C<Authorization>
header in memory (C<PVEAPIToken=E<lt>token_idE<gt>=E<lt>secretE<gt>>), and
nowhere else.

=item C<ca>

A file, or a list of files, with CA certificates. The certificate of the
node has to chain up to one of them and carry C<host> as a name.

=item C<fingerprint>

A SHA-256 fingerprint, or a list, of the certificate the node presents; hex,
colons allowed, any case. A match is enough on its own, the name is not
checked then.

=back

At least one of C<ca> and C<fingerprint> is required. C<port> has to be
set: the default of SICK is 443, and C<port: 443> is refused with a message
that names 8006. The common settings of a device (C<host>, C<names>,
C<lifetime>, C<key>, ...) apply as for every type.

=head1 HOW THE NODE IS TRUSTED

By the anchors of the device list and by nothing else: no "accept once", no
trust on first use, no store of the system, no switch or environment
variable that turns the check off. A node that passes neither anchor gets
no request, no token, no key; the device fails with a message that names
the fingerprint the node presents and the anchors that were tried.

A fresh node presents C<pve-ssl.pem>, signed by the cluster's own CA
(F</etc/pve/pve-root-ca.pem>), with the node name, the node name with the
search domain, and the cluster address as names. So, for the first upload:

=over 4

=item *

copy F</etc/pve/pve-root-ca.pem> from the node over a path you trust (C<scp>
with a known host key, say) and name it in C<ca>, next to our root, and use
as C<host> one of the names of C<pve-ssl.pem>; or

=item *

pin the fingerprint of C<pve-ssl.pem> (GUI: node, System, Certificates) in
C<fingerprint>. The pin breaks when C<pveupdate> renews C<pve-ssl.pem>, so
the cluster CA is the better first anchor.

=back

After the first upload the node presents our certificate, and our root in
C<ca> is what matches. Remove a pin then. During a change of our root, name
the old and the new root in C<ca>.

=head1 THE TOKEN

The upload needs C<Sys.Modify> on C</nodes/E<lt>nodeE<gt>>, which only the
built-in role C<Administrator> holds; a role of its own with nothing else is
the smallest. It is still wide: on that node it also allows services,
network, DNS, time, APT, firewall and ACME. One token per node.

These commands were run as written on Proxmox VE 9.2.21 in a container
(F<docs/real-node-trial.md>):

    pveum user add sick@pve --comment 'SICK certificate upload'
    pveum role add SICKCertificate --privs Sys.Modify
    pveum user token add sick@pve sick --privsep 1 --expire <epoch> --comment 'SICK'
    pveum acl modify /nodes/pve1 --roles SICKCertificate --users sick@pve
    pveum acl modify /nodes/pve1 --roles SICKCertificate --tokens 'sick@pve!sick'

The token is privilege-separated, so it needs both ACL lines. C<token add>
prints the secret once; put it into C<token_file>.

=head1 THE WAY BACK

=over 4

=item 1.

Take the device out of the device list, or the next run uploads again.

=item 2.

Delete the custom certificate: in the GUI (node, System, Certificates,
"Delete custom certificate"), or with
C<DELETE /api2/json/nodes/E<lt>nodeE<gt>/certificates/custom?restart=1>
(parameters in the query string; with C<curl>, take the header from a file
with C<-H @file>, never from the command line). The node goes back to
C<pve-ssl.pem> of the cluster CA - trusted again only through the cluster CA
or a pin, not through our root.

=item 3.

Remove the token, the ACL lines and the user (C<pveum user token remove>,
C<pveum user delete>).

=back

This distribution does not do the delete for you. The commands above were
not run.

=cut

sub product  { 'Proxmox VE' }
sub api_port { 8006 }

sub type_required_options { qw( node ) }

sub api_node { $_[0]->option('node') }

=method api_node

The value of C<node>.

=cut

sub token_id_valid {
  my ( $self, $token_id ) = @_;
  return $token_id =~ /\A[^\s!=:;@]+@[^\s!=:;@]+![A-Za-z][A-Za-z0-9._-]+\z/ ? 1 : 0;
}

=method token_id_valid

    $target->token_id_valid('sick@pve!sick');    # 1

True for C<user@realm!tokenname> with a token name of a letter and at least
one more letter, digit, C<.>, C<_> or C<->.

=cut

sub validate_type_options {
  my ( $self, $where ) = @_;
  my $node = $self->option('node');
  croak $where.': invalid \'node\' (letters, digits and -, as the node is named in Proxmox VE)'
    unless defined $node && !ref $node && $node =~ /\A[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?\z/;
  return;
}

=method validate_type_options

Croaks unless C<node> is a node name of Proxmox VE.

=cut

sub authorization {
  my ( $self, $token_id, $secret ) = @_;
  return 'PVEAPIToken='.$token_id.'='.$secret;
}

=method authorization

The value of the C<Authorization> header: C<PVEAPIToken=E<lt>idE<gt>=E<lt>secretE<gt>>.

=cut

sub upload_fields {
  my ( $self, $bundle ) = @_;
  return {
    certificates => $bundle->fullchain,
    key          => $bundle->key,
    force        => JSON->true,
    restart      => JSON->true,
  };
}

=method upload_fields

The body: C<certificates> (certificate first, then its chain), C<key>, and
C<force> and C<restart> as JSON C<true> - C<force> because a custom
certificate from the last run is there already, C<restart> because without
it C<pveproxy> keeps serving the old one.

=cut

sub answer_certificate {
  my ( $self, $data ) = @_;
  return ref $data eq 'HASH' ? $data : undef;
}

=method answer_certificate

C<data> of the answer: one object, the info of the uploaded certificate.

=cut

sub api_message {
  my ( $self, $response ) = @_;
  my $answer = $self->_decode_json_body($response);
  return undef unless $answer;
  # A parameter error can repeat the value: only the names of the parameters.
  if ( $response->{status} eq '400' ) {
    my $errors = $answer->{errors};
    return undef unless ref $errors eq 'HASH' && %$errors;
    return 'parameters '.join( ', ', grep { /\A[a-z][a-z0-9_-]*\z/ } sort keys %$errors );
  }
  return $answer->{message};
}

=method api_message

What of an error answer of Proxmox VE may be quoted: the C<message> of its
JSON body, and for C<400> only the names under C<errors>.

=cut

1;
