#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use Getopt::Long;
use Pod::Usage;
use WWW::2ch;
use URI;
use File::Spec::Functions qw(catfile devnull);
use LWP::UserAgent;
use URI::Find;
use IO::Handle;
use FileHandle;

# TODO
# - オプション
#   - datをチェックしにいく間隔
# - 保存されてないファイルのみダウンロード
#   - 前回のdatファイルと比較して違ったら
#     差分のみからURLを抽出、ダウンロード
#   - 監視はこれを一定間隔でグルグル回せばいいだけ
# - 正規表現をもっとちゃんとする
# - datはShift JIS
#   - URL抜き出すだけだったら別に考慮しなくてもいいけど
# - 設定ファイルからオプションを取得
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
    my $LOG;

    sub log_out {
        return unless defined $LOG;
        $LOG->print(@_, "\n");
    }

    sub log_error {
        log_out "[error]::", @_;
    }

    sub log_set_fh {
        $LOG = shift;
    }

    sub log_set_path {
        my ($filename, $mode) = @_;

        my $fh = FileHandle->new($filename, $mode) or do {
            warn "can't open '$filename' as log file!:$!";
            return;
        };
        log_set_fh $fh;
    }
}



sub get_ita_dat {
    my ($url) = @_;
    $url =~ m{/test/read\.cgi/([^/]+)/([^/]+)/};
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
    my ($body, $support_utf8_url) = @_;

    # FIXME
    # Don't create URI::Find instance each time.

    my @image_url;
    my $finder = do {
        if ($support_utf8_url) {
            require URI::Find::UTF8;
            URI::Find::UTF8->new(sub { push @image_url, shift });
        }
        else {
            URI::Find->new(sub { push @image_url, shift });
        }
    };
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
my $dat_file = './cache.dat';
my $support_utf8_url;

{
    # Build option values as follows:
    # - Default
    # - Config file
    # - Arguments

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
        'utf8-url' => \$support_utf8_url,
    ) or usage;
    usage   if $needhelp;
}


my $url = shift || usage;


# Setup
mkdir $down_dir;

my $ua = LWP::UserAgent->new;
$ua->agent($user_agent);

if (defined $log_file) {
    log_set_path($log_file, $log_rewrite_old ? 'w' : 'a');
}
else {
    log_set_fh(\*STDOUT);
}

if ($log_quiet) {
    log_set_path(devnull, $log_rewrite_old ? 'w' : 'a');
}


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
    my $o = WWW::2ch->new(
        url => $url,
        cache => $dat_file,
    );

    my $dat = $o->parse_dat($dat_data);
    ($dat->reslist);
};


# Save images.
my $i = my $j = 1;
for my $res (@reslist) {
    log_out sprintf "res %d: %s", $i++, $res->body_text;

    for my $url (get_urls_from_body($res->body_text, $support_utf8_url)) {
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
