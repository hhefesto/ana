# usage: perl mvdef.pl FILE MOVED BEFORE: move the paragraph (blank-line separated) whose
# def is MOVED to just before the paragraph whose def is BEFORE
my ($f, $mv, $bf) = @ARGV;
local $/; open my $h, '<', $f or die; my $s = <$h>; close $h;
my @p = split /\n\n/, $s, -1;
my ($i) = grep { $p[$_] =~ /^def \Q$mv\E\(/m } 0..$#p;
die "no $mv" unless defined $i;
my $blk = splice @p, $i, 1;
my ($j) = grep { $p[$_] =~ /^def \Q$bf\E\(/m } 0..$#p;
die "no $bf" unless defined $j;
splice @p, $j, 0, $blk;
open $h, '>', $f or die; print $h join("\n\n", @p); close $h;
