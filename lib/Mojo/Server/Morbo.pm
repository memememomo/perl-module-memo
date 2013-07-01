package Mojo::Server::Morbo;
use Mojo::Base -base;

# "Linda: With Haley's Comet out of ice, Earth is experiencing the devastating
#         effects of sudden, intense global warming.
#  Morbo: Morbo is pleased but sticky."
use Mojo::Home;
use Mojo::Server::Daemon;
use POSIX 'WNOHANG';

# 変更を監視するディレクトリ
# morboコマンドでは--watchオプションで指定できる。
has watch => sub { [qw(lib templates)] };

sub check_file {
    my ($self, $file) = @_;

    # check if modify time and/or size have changed
    my ($size, $mtime) = (stat $file)[7, 9];
    return undef unless defined $mtime;

    my $cache = $self->{cache} ||= {};

    # $^Tはプログラムが起動した時間。エポックタイム形式。
    # キャッシュを取る
    my $stats = $cache->{$file} ||= [$^T, $size];

    # 更新時間とサイズを確認する
    return undef if $mtime <= $stats->[0] && $size == $stats->[1];

    # キャッシュに入れている
    # !!はbooleanに変換
    return !!($cache->{$file} = [$mtime, $size]);
}

sub run {
    my ($self, $app) = @_;

    # Clean manager environment

    # SIGCHLDを受け取った場合
    # SIGCHLDは子プロセスが死んだ時に受け取る
    local $SIG{CHLD} = sub { $self->_reap };

    # SIGINT -> Ctrl-CはSIGINTを発生させる
    # SIGTERM -> kill -TERM
    # SIGQUIT -> kill -QUIT
    local $SIG{INT} = local $SIG{TERM} = local $SIG{QUIT} = sub {
        # 終了フラグを立てて、メインループを終了させる
        $self->{finished} = 1;
        # 自身のプロセスにTERMを送る
        kill 'TERM', $self->{running} if $self->{running};
    };

    # アプリファイルを変更監視
    unshift @{$self->watch}, $app;
    $self->{modified} = 1;

    # Prepare and cache Listen sockets for smooth restarting
    my $daemon = Mojo::Server::Daemon->new(silent => 1)->start->stop;

    # 1秒ごとにプロセスの管理処理を行う
    $self->_manage while !$self->{finished} || $self->{running};

    exit 0;
}

sub _manage {
    my $self = shift;

    # Discover files
    my @files;
    for my $watch (@{$self->watch}) {
        if (-d $watch) {
            my $home = Mojo::Home->new->parse($watch);
            push @files, $home->rel_file($_) for @{$home->list_files};
        }
        # -r: 読み込み可能
        elsif (-r $watch) { push @files, $watch }
    }

    # Check files
    for my $file (@files) {
        next unless $self->check_file($file);
        say qq{File "$file" changed, restarting.} if $ENV{MORBO_VERBOSE};

        # 更新ファイルがあったら再起動させる
        kill 'TERM', $self->{running} if $self->{running};
        $self->{modified} = 1;
    }

    # 終了している子プロセスがあるか
    $self->_reap;

    # kill 0で、プロセスの存在確認を行う
    delete $self->{running} if $self->{running} && !kill 0, $self->{running};

    # 修正ファイルがあり、メインループが終わっている場合は子プロセスを生成する
    $self->_spawn if !$self->{running} && delete $self->{modified};
    sleep 1;
}

sub _reap {
    my $self = shift;

    # WNOHANG指定で、
    # 子プロセスが終了していればPIDを、終了していなければ0を返す。
    while ((my $pid = waitpid -1, WNOHANG) > 0) { delete $self->{running} }
}

sub _spawn {
    my $self = shift;

    # Fork
    my $manager = $$;
    $ENV{MORBO_REV}++;
    die "Can't fork: $!" unless defined(my $pid = fork);

    # Manager
    return $self->{running} = $pid if $pid;

    # Worker
    $SIG{CHLD} = 'DEFAULT';
    $SIG{INT} = $SIG{TERM} = $SIG{QUIT} = sub { $self->{finished} = 1 };
    my $daemon = Mojo::Server::Daemon->new;
    $daemon->load_app($self->watch->[0]);
    $daemon->silent(1) if $ENV{MORBO_REV} > 1;
    $daemon->start;
    my $loop = $daemon->ioloop;

    # 1秒毎にmanagerプロセスの存在チェックする。
    # 存在しなかったらstopする。
    $loop->recurring(
        1 => sub { shift->stop if !kill(0, $manager) || $self->{finished} });
    $loop->start;
    exit 0;
}

1;
