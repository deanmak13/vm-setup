#!/usr/bin/perl
# tests/needrestart-decide.pl <conf> <unit> — the verdict needrestart derives
# for <unit> after loading <conf> alone: "restart" or "skip", then how many
# $nrconf{override_rc} regexes matched. Mirrors /usr/sbin/needrestart's
# override_rc loop (first matching regex sets $restart); the match count is
# reported because needrestart iterates a hash, so two matches with different
# values would make the verdict order-dependent.
use strict;
use warnings;

our %nrconf;
my ($conf, $unit) = @ARGV;
my $loaded = do $conf;   # the conf's last statement is an assignment, so its value is 0
die "conf did not parse: $@" if $@;
die "conf not readable: $!" if !defined $loaded && $!;

my ($restart, $matches) = (1, 0);
foreach my $re (keys %{ $nrconf{override_rc} }) {
    next unless $unit =~ /$re/;
    $restart = $nrconf{override_rc}->{$re};
    $matches++;
}
print(($restart ? 'restart' : 'skip'), " $matches\n");
