requires 'perl', '5.020';

requires 'Carp';
requires 'HTTP::Tiny';
requires 'IO::Socket::SSL', '2.089';
requires 'JSON::MaybeXS';
requires 'Moo';
requires 'namespace::autoclean', '0.16';
requires 'Path::Tiny';
requires 'SICK', '0.001';
requires 'Type::Tiny';

on test => sub {
  requires 'Exporter';
  requires 'File::Temp';
  requires 'IO::Select';
  requires 'IO::Socket::INET';
  requires 'Net::SSLeay';
  requires 'POSIX';
  requires 'Socket';
  requires 'Test::More', '0.96';
  requires 'Time::HiRes';
  requires 'Time::Local';
};
