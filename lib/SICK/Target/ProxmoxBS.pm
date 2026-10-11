package SICK::Target::ProxmoxBS;
# ABSTRACT: SICK target for the web interface and API of Proxmox Backup Server

use Moo;
extends 'SICK::Target';
with 'SICK::Target::Proxmox::Role';
use namespace::autoclean;

our $VERSION = '0.001';

=head1 SYNOPSIS

In the device list of L<SICK>:

    devices:
      pbs1:
        type: proxmox-bs
        host: pbs1.example.internal
        port: 8007
        names: [pbs1.example.internal]
        token_id: sick@pbs!sick
        token_file: /etc/sick/pbs1.token          # one line: the secret
        fingerprint: 'ab:cd:...:ef'               # the self-signed certificate, for the first upload
        ca: /etc/sick/root.pem                    # our root, from then on

Then

    sick check pbs1
    sick run pbs1

=head1 DESCRIPTION

Puts the certificate of the web interface and API of a Proxmox Backup
Server - the one C<proxmox-backup-proxy> serves on port 8007 - onto the
host, through its own API:
C<POST /api2/json/nodes/localhost/certificates/custom> with certificate,
chain and key. The host writes C<proxy.pem> and C<proxy.key> and has the
proxy load them before it answers; L<SICK> then asks the port whether it
presents the new certificate.

It replaces the deploy hook C<proxmoxbs> of acme.sh, which sends the token
and the key without checking whose certificate the host presents. Here the
connection is checked during the handshake against the anchors of the device
list, and the token and the key go nowhere else (see L</HOW THE HOST IS
TRUSTED>). What the API does, call by call and with the source of each
statement, is in F<docs/api-notes.md> of the distribution.

Proxmox Backup Server does not refuse a key that does not belong to the
certificate: it answers C<200>, keeps serving the old certificate and fails
at its next start. This type therefore checks the pair before anything is
sent, and SICK checks the port afterwards.

B<Tried against:> the stand-in under F<t/> (the unit suite), and end to end
through C<sick run> against a real Proxmox Backup Server 4.2.8-1 in a
container, with the lab CA (F<t/e2e/device-proxmox.sh>). Not tried: a host
under systemd, a host across a real network (F<docs/hq-checklist.md>).

=head1 OPTIONS

=over 4

=item C<token_id>

Required. The API token, C<user@realm!tokenname>, for instance
C<sick@pbs!sick>. Not secret; it is never quoted in a message all the same.

=item C<token_file>

Required. A file whose first line is the secret of the token (mode C<0600>).
It is read when there is something to upload, put into the C<Authorization>
header in memory (C<PBSAPIToken=E<lt>token_idE<gt>:E<lt>secretE<gt>>), and
nowhere else.

=item C<ca>

A file, or a list of files, with CA certificates. The certificate of the
host has to chain up to one of them and carry C<host> as a name.

=item C<fingerprint>

A SHA-256 fingerprint, or a list, of the certificate the host presents; hex,
colons allowed, any case. A match is enough on its own, the name is not
checked then.

=back

At least one of C<ca> and C<fingerprint> is required. C<port> has to be
set: the default of SICK is 443, and C<port: 443> is refused with a message
that names 8007. The node in the path is always C<localhost>, as in the GUI
of Proxmox Backup Server. The common settings of a device (C<host>,
C<names>, C<lifetime>, C<key>, ...) apply as for every type.

=head1 HOW THE HOST IS TRUSTED

By the anchors of the device list and by nothing else: no "accept once", no
trust on first use, no store of the system, no switch or environment
variable that turns the check off. A host that passes neither anchor gets
no request, no token, no key; the device fails with a message that names
the fingerprint the host presents and the anchors that were tried.

A fresh Proxmox Backup Server presents a self-signed C<proxy.pem>, made at
installation, that names the host by DNS names only (no address). There is
no CA to anchor on; pin its fingerprint for the first upload. It is shown on
the dashboard ("Show Fingerprint") and by
C<proxmox-backup-manager cert info> on the host - Proxmox's own clients pin
exactly that. Name our root in C<ca> next to it.

After the first upload the host presents our certificate and our root in
C<ca> is what matches; the pinned certificate is gone (C<proxy.pem> is
overwritten). Remove the pin then. During a change of our root, name the old
and the new root in C<ca>.

=head1 THE TOKEN

The upload needs C<Sys.Modify> on C</system/certificates>. Proxmox Backup
Server has fixed roles, and only C<Admin> holds it; on that path it also
covers the ACME accounts and plugins, including the credentials of the DNS
plugins. Narrow path, wide role on it.

These commands were run on Proxmox Backup Server 4.2.8 in a container
(F<docs/real-node-trial.md>), as written except that C<generate-token> ran
without C<--expire> and C<--comment>:

    proxmox-backup-manager user create sick@pbs --comment 'SICK certificate upload'
    proxmox-backup-manager user generate-token sick@pbs sick --expire <epoch> --comment 'SICK'
    proxmox-backup-manager acl update /system/certificates Admin --auth-id sick@pbs
    proxmox-backup-manager acl update /system/certificates Admin --auth-id 'sick@pbs!sick'

Tokens are always privilege-separated, so both ACL lines are needed.
C<generate-token> prints the secret once; put it into C<token_file>.

=head1 THE WAY BACK

=over 4

=item 1.

Take the device out of the device list, or the next run uploads again.

=item 2.

Delete the certificate:
C<DELETE /api2/json/nodes/localhost/certificates/custom> (with C<curl>, take
the header from a file with C<-H @file>, never from the command line). The
host makes a B<new> self-signed certificate with a new key and loads it; its
fingerprint is new, and an old pin does not match it.

=item 3.

Remove the token, the ACL lines and the user
(C<proxmox-backup-manager user delete-token>, C<proxmox-backup-manager user
remove>).

=back

This distribution does not do the delete for you. The commands above were
not run.

=cut

sub product  { 'Proxmox Backup Server' }
sub api_port { 8007 }

sub api_node { 'localhost' }

=method api_node

C<localhost>: Proxmox Backup Server does not look at the node of the path.

=cut

sub token_id_valid {
  my ( $self, $token_id ) = @_;
  return $token_id =~ /\A[^\s!=:;@]+@[^\s!=:;@]+![A-Za-z0-9_][A-Za-z0-9._-]*\z/ ? 1 : 0;
}

=method token_id_valid

    $target->token_id_valid('sick@pbs!sick');    # 1

True for C<user@realm!tokenname> with a token name of letters, digits,
C<.>, C<_> and C<->, not starting with C<.> or C<->.

=cut

sub validate_type_options { return }

=method validate_type_options

Nothing on top of the shared checks.

=cut

sub authorization {
  my ( $self, $token_id, $secret ) = @_;
  return 'PBSAPIToken='.$token_id.':'.$secret;
}

=method authorization

The value of the C<Authorization> header: C<PBSAPIToken=E<lt>idE<gt>:E<lt>secretE<gt>>.

=cut

sub upload_fields {
  my ( $self, $bundle ) = @_;
  return {
    certificates => $bundle->fullchain,
    key          => $bundle->key,
  };
}

=method upload_fields

The body: C<certificates> (certificate first, then its chain) and C<key>.
C<force> and C<restart> are left out: Proxmox Backup Server ignores both.

=cut

sub answer_certificate {
  my ( $self, $data ) = @_;
  return undef unless ref $data eq 'ARRAY' && @$data == 1;
  return ref $data->[0] eq 'HASH' ? $data->[0] : undef;
}

=method answer_certificate

C<data> of the answer: a list with one object, the info of the uploaded
certificate.

=cut

sub api_message {
  my ( $self, $response ) = @_;
  # Errors are plain text. A parameter error (400) can repeat the value it
  # refused: never quoted.
  return undef if $response->{status} eq '400';
  return $response->{content};
}

=method api_message

What of an error answer of Proxmox Backup Server may be quoted: its plain
text body, except for C<400>, which can repeat a value of the request.

=cut

1;
