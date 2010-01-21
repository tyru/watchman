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
# - 保存されてないファイルのみダウンロード
#   - 前回のdatファイルと比較して違ったら
#     差分のみからURLを抽出、ダウンロード
#   - 監視はこれを一定間隔でグルグル回せばいいだけ
# - 正規表現をもっとちゃんとする
# - datはShift JIS
#   - URL抜き出すだけだったら別に考慮しなくてもいいけど
# - 設定ファイルからオプションを取得
#   - デフォルトのオプション
#   - 設定ファイル
#   - 引数
# - Pod書く


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



# Logger.
{
    my $log_quiet;
    my $LOG;

    sub log_out {
        return unless defined $LOG;
        $LOG->print(@_, "\n");
        print(@_, "\n") unless $log_quiet;
    }

    sub log_error {
        log_out "[error]::", @_;
    }

    sub log_setfile {
        my ($filename, $mode) = @_;
        return unless defined $filename;

        $LOG = FileHandle->new($filename, $mode) or do {
            log_error "can't open '$filename' as log file!:$!";
            return;
        };
    }

    sub log_set_quiet_flag {
        $log_quiet = shift;
    }
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
my $user_agent = 'Mozilla/5.0';
my $log_file;
my $log_rewrite_old;
my $log_quiet;
my $overwrite;
my $dat_file;

{
    my $needhelp;
    GetOptions(
        'h|help|?' => \$needhelp,
        'o|down-dir=s' => \$down_dir,
        'u|user-agent=s' => \$user_agent,
        'l|log-file=s' => \$log_file,
        'r|rewrite-old-log' => \$log_rewrite_old,
        'q|quiet' => \$log_quiet,
        'f|force' => \$overwrite,
        'd|dat-file=s' => \$dat_file,
    ) or usage;
    usage   if $needhelp;
}


my $url = shift
    || 'http://yutori7.2ch.net/test/read.cgi/news4vip/1263878512/'
    || usage;


# Setup
mkdir $down_dir;

my $ua = LWP::UserAgent->new;
$ua->agent($user_agent);

if (defined $log_file) {
    log_setfile($log_file, $log_rewrite_old ? 'w' : 'a');
}
log_set_quiet_flag($log_quiet);


# Get dat data's response.
my $dat_data = do {
    my $dat_url = get_dat_url($url);
    log_out $dat_url->as_string;

    my $res = $ua->get($dat_url);
    unless ($res->is_success) {
        die "GET $dat_url: failed.\n";
    }
    $res->content;
};


# Get 2ch res's list.
my @reslist = do {
    my $tempdir = '/tmp/XXX';
    my $o = WWW::2ch->new(
        url => $url,
        # TODO
        # cache => catfile(mktemp($tempdir), ''),
    );

    my $dat = $o->parse_dat($dat_data);
    ($dat->reslist);
};


# Save images.
my $i = my $j = 1;
for my $res (@reslist) {
    log_out sprintf "res %d: %s", $i++, $res->body_text;

    for my $url (get_urls_from_body($res->body_text)) {
        log_out sprintf "url %d: %s", $j++, $url;

        my $res = $ua->get($url);
        unless ($res->is_success) {
            log_error "GET $url: failed.";
            next;
        }

        # URL tail path as filename.
        my $filename = do {
            my $f = (split m{/}, $url)[-1];
            catfile($down_dir, $f);
        };

        if (-f $filename && !$overwrite) {
            log_error "'$filename' already exists.";
            next;
        }

        my $FH = FileHandle->new($filename, 'w') or do {
            log_error "$filename: file open failed.";
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
