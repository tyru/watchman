#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

# 2chの画像ダウンローダ。
# 中途半端なところでやる気がなくなってしまったのでgistの方にうpしておく。

use Getopt::Long;
use Pod::Usage;
use WWW::2ch;
use URI;
use File::Spec::Functions qw(catfile devnull);
use LWP::UserAgent;
use URI::Find;
use IO::Handle;
use FileHandle;
use FindBin qw($Bin);
use YAML;
use Encode qw(find_encoding);
use File::Temp qw/tempdir/;
use File::Path qw/mkpath/;

# TODO
# - オプション
#   - datをチェックしにいく間隔
# - 保存されてないファイルのみダウンロード
#   - 前回のdatファイルと比較して違ったら
#     差分のみからURLを抽出、ダウンロード
#   - 監視はこれを一定間隔でグルグル回せばいいだけ
# - Pod書く
# - 成功した/失敗したURLを最後にまとめて報告してくれるとうれしい
#
#
# XXX
# - URLの前に空白入ってない？
#   - まぁLWPがちゃんとGETできてるようなのでいいんだけど
# - URI::Findで本当にURLを抽出できてる？
#   - $finderを何個か用意して探させたらどうか
#   - 重複したURLはもちろん統一する


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

sub os {
    my ($default, %specific) = @_;
    exists $specific{$^O} ?
        $specific{$^O}
        : $default
}



my $DOWN_DIR = $ENV{WATCHMAN_DOWN_DIR} || $Bin;

my $CONF_DIR = $ENV{WATCHMAN_CONF_DIR} || do {
    my $home = catfile($ENV{HOME}, '.watchman');
    my $mswin32 = catfile($Bin, 'watchman');
    my $current = catfile($Bin, '.watchman');
    os(
        (exists $ENV{HOME} ? $home : $current),
        MSWin32 => $mswin32,
    );
};

my $STDOUT_ENCODING = $ENV{WATCHMAN_STDOUT_ENCODING} || do {
    my $mswin32 = 'cp932';
    my $other = '';
    if (exists $ENV{LANG}) {
        my ($locale, $enc) = split /\./, $ENV{LANG};
        $other = $enc if defined $enc;
    }

    os(
        $other,
        MSWin32 => $mswin32,
    );
};



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

sub get_urls_from_body {
    my ($body, $support_utf8_url, $image_regex) = @_;

    # FIXME
    # Don't create URI::Find instance each time.

    my @image_url;
    my $callback = sub {
        my ($url) = @_;
        if ($url =~ $image_regex) {
            push @image_url, $url;
        }
    };

    my $finder = do {
        if ($support_utf8_url) {
            require URI::Find::UTF8;
            URI::Find::UTF8->new($callback);
        }
        else {
            URI::Find->new($callback);
        }
    };
    $finder->find(\$body);
    @image_url;
}

sub apply_conf {
    my ($conf_file, $opt) = @_;

    return unless -f $conf_file;
    my $conf_data = YAML::LoadFile($conf_file);
    return unless defined $conf_data && ref $conf_data eq 'HASH';

    while (my ($k, $v) = each %$conf_data) {
        next unless exists $opt->{$k};
        ${ $opt->{$k} } = $v;
    }
}

sub validate_regex {
    my ($image_regex, $image_regex_flags) = @_;

    # TODO check if $image_regex contains executable code.

    if ($image_regex_flags =~ '[^gimosx]') {
        die "regex flags contain invalid character(s).\n";
    }
}



### main ###
my $down_dir = tempdir(DIR => catfile($DOWN_DIR, 'down'), CLEANUP => 0);
my $user_agent = 'Mozilla/5.0';
my $log_file;
my $log_rewrite_old;
my $log_quiet;
my $overwrite;
my $dat_file = catfile($DOWN_DIR, 'cache.dat');
my $read_dat_file;
my $support_utf8_url;
my $image_regex_flags = 'i';
my $image_regex = qr/\.(?:jpg|png|gif)$/;

{
    # Build option values as follows:
    # - Default
    # - Config file
    # - Arguments

    my $conf_file = $ENV{WATCHMAN_CONF_FILE} || catfile($CONF_DIR, 'config');
    apply_conf(
        $conf_file,
        {
            down_dir => \$down_dir,
            user_agent => \$user_agent,
            log_file => \$log_file,
            rewrite_old_log => \$log_rewrite_old,
            quiet => \$log_quiet,
            force => \$overwrite,
            dat_file => \$dat_file,
            read_dat_file => \$read_dat_file,
            utf8_url => \$support_utf8_url,
            regex_flags => \$image_regex_flags,
            image_regex => \$image_regex,
        }
    );

    my $needhelp;
    GetOptions(
        'h|help|?' => \$needhelp,
        'o|down-dir=s' => \$down_dir,
        'u|user-agent=s' => \$user_agent,
        'l|log-file=s' => \$log_file,
        'r|rewrite-old-log' => \$log_rewrite_old,
        'q|quiet!' => \$log_quiet,
        'f|force!' => \$overwrite,
        'd|dat-file=s' => \$dat_file,
        'utf8-url!' => \$support_utf8_url,
        'D|read-dat-file!' => \$read_dat_file,
        'F|regex-flags=s' => \$image_regex_flags,
        'R|image-regex=s' => \$image_regex,
    ) or usage;
    usage   if $needhelp;
}


my $url = shift || usage;


# Setup
mkpath $DOWN_DIR;
mkpath $down_dir;

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

my $encode = do {
    my $enc = find_encoding($STDOUT_ENCODING);

    if (defined $enc) {
        sub {
            $enc->encode(@_)
        };
    }
    else {
        log_error "can't determine stdout encoding.";
        log_error "so watchman will not encode output.";
        sub { @_ };
    }
};
my $decode_sjis = do {
    my $enc = find_encoding('sjis');
    sub { $enc->decode(@_) };
};

validate_regex($image_regex, $image_regex_flags);


my ($ita, $dat_number) = get_ita_dat($url);
log_out '$ita = '.$ita;
log_out '$dat_number = '.$dat_number;


# Get dat data's response.
my $dat_data;
unless ($read_dat_file) {
    $dat_data = do {
        my $dat_url = URI->new($url);
        $dat_url->path("$ita/dat/$dat_number.dat");
        log_out "GET $dat_url";

        my $res = $ua->get($dat_url);
        unless ($res->is_success) {
            die "GET $dat_url: failed.\n";
        }
        $res->content;
    };
}


# Get 2ch res's list.
my @reslist = do {
    my $o = WWW::2ch->new(
        url => $url,
        cache => $dat_file,
    );

    my $dat = do {
        if ($read_dat_file) {
            $o->recall_dat($dat_number);
        }
        else {
            $o->parse_dat($dat_data);
        }
    };
    ($dat->reslist);
};


# Save images.
my $i = my $j = 1;
$image_regex = eval sprintf "qr/%s/%s", $image_regex, $image_regex_flags;

for my $res (@reslist) {
    log_out sprintf "res %d: %s", $i++, $encode->($decode_sjis->($res->body_text));

    for my $url (get_urls_from_body($res->body_text, $support_utf8_url, $image_regex)) {
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
        log_out "save '$filename'.";
    }
}
__END__

=head1 NAME

    watch.pl - NO DESCRIPTION YET.


=head1 SYNOPSIS


=head1 OPTIONS


=head1 AUTHOR

tyru <tyru.exe@gmail.com>
