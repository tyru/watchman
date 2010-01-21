#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use Getopt::Long;
use Pod::Usage;
use WWW::2ch;
use URI;
use File::Spec::Functions qw(catfile);
use LWP::UserAgent;
use URI::Find;

# TODO
# - オプション
#   - datをチェックしにいく間隔
#   - URI::Findを使うか、URI::Find::UTF8を使うか
#   - ログファイル
# - 正規表現をもっとちゃんとする
# - datはShift JIS
#   - URL抜き出すだけだったら別に考慮しなくてもいいけど


### sub ###
sub usage () {
    pod2usage(-verbose => 2);
}

sub d {
    require Data::Dumper;
    no warnings 'once';
    local $Data::Dumper::Terse = 1;
    local $Data::Dumper::Useqq = 1;
    Data::Dumper::Dumper(@_);
}

sub get_ita_dat {
    my ($url) = @_;
    $url =~ m{/test/read.cgi/([^/]+)/([^/]+)/};
    ($1, $2);
}

sub get_dat_url {
    my ($url) = @_;
    my ($ita, $dat) = get_ita_dat($url);
    $url = URI->new($url);
    $url->path("$ita/dat/$dat.dat");
    $url;
}

sub get_dat {
    my ($ua, $url) = @_;

    my $dat_url = get_dat_url($url);
    warn $dat_url;

    my $res = $ua->get($dat_url);
    unless ($res->is_success) {
        die "GET $dat_url: failed.\n";
    }
    $res;
}

sub get_urls_from_body {
    my ($body) = @_;

    # FIXME
    # Don't create URI::Find instance each time.

    my @image_url;
    my $finder = URI::Find->new(sub { push @image_url, @_ });
    $finder->find(\$body);
    @image_url;
}


### main ###
my $down_dir = 'down';
my $needhelp;
my $user_agent = 'Mozilla/5.0';
GetOptions(
    'd|down-dir=s' => \$down_dir,
    'help' => \$needhelp,
    'u|user-agent=s' => \$user_agent,
) or usage;
usage   if $needhelp;


my $url = shift
    || 'http://yutori7.2ch.net/test/read.cgi/news4vip/1263878512/'
    || usage;

# Setup
mkdir $down_dir;
my $ua = LWP::UserAgent->new;
$ua->agent($user_agent);

my $dat_response = get_dat($ua, $url);

my $tempdir = '/tmp/XXX';
my $o = WWW::2ch->new(
    url => $url,
    # TODO
    # cache => catfile(mktemp($tempdir), ''),
);

my $dat = $o->parse_dat($dat_response->content);
my $i = my $j = 1;
for my $res ($dat->reslist) {
    warn sprintf "res %d: %s\n", $i++, $res->body_text;

    for my $url (get_urls_from_body($res->body_text)) {
        warn sprintf "url %d: %s\n", $j++, $url;

        my $res = $ua->get($url);
        unless ($res->is_success) {
            warn "GET $url: failed.\n";
            next;
        }

        # tail path as filename.
        my $filename = (split m{/}, $url)[-1];
        $filename = catfile($down_dir, $filename);
        my $FH = FileHandle->new($filename, 'w') or do {
            warn "$filename: file open failed.\n";
            next;
        };
        binmode $FH;
        $FH->print($res->content);
    }
}
__END__

=head1 NAME

    watch.pl - NO DESCRIPTION YET.


=head1 SYNOPSIS


=head1 OPTIONS


=head1 AUTHOR

tyru <tyru.exe@gmail.com>
