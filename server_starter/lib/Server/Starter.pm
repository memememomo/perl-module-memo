package Server::Starter;

use 5.008;
use strict;
use warnings;
use Carp;
use Fcntl;
use IO::Handle;
use IO::Socket::INET;
use IO::Socket::UNIX;
use List::MoreUtils qw(uniq);
use POSIX qw(:sys_wait_h);
use Proc::Wait3; # 上の方でuse POSIX qw(:sys_wait_h)しておく
use Scope::Guard;

use Exporter qw(import);

my @signals_received;

sub start_server {
    my %opts = {
        (@_ == 1 ? @$_[0] : @_),
    };
    $opts->{interval} = 1
        if not defined $opts->{interval};
    $opts->{signal_on_hup}  ||= 'TERM';
    $opts->{signal_on_term} ||= 'TERM';
    for ($opts->{signal_on_hup}, $opts->{signal_on_term}) {
        # normalize to the one that can be passed to kill
        tr/a-z/A-Z/;
        tr/^SIG//i;
    }

    # prepare args
    my $ports = $opts->{port};
    my $paths = $opts->{path};
    croak "either of ``port`` or ``path'' option is mandatory\n"
        unless $ports || $paths;
    $ports = [ $ports ]
        if ! ref $ports && defined $ports;
    $paths = [ $paths ]
        if ! ref $paths && defined $paths;
    croak "mandatory option ``exec'' is missing or is not an arrayref\n"
        unless $opts->{exec} && ref $opts->{exec} eq 'ARRAY';

    # set envs
    $ENV{ENVDIR} = $opts->{envdir}
        if defined $opts->{envdir};
    $ENV{ENABLE_AUTO_RESTART} = $opts->{enable_auto_restart}
        if defined $opts->{enable_auto_restart};
    $ENV{KILL_OLD_DELAY} = $opts->{kill_old_delay}
        if defined $opts->{kill_old_delay};
    $ENV{AUTO_RESTART_INTERVAL} = $opts->{auto_restart_interval}
        if defined $opts->{auto_restart_interval};

    # open pid file
    my $pid_file_guard = sub {
        return unless $opts->{pid_file};
        open my $fh, '>', $opts->{pid_file}
            or die "failed to open file:$opts->{pid_file}: $!";
        print $fh "$$\n";
        close $fh;
        return Scope::Guard->new(
            sub {
                unlink $opts->{pid_file};
            },
        );
    }->();

    # open Log file
    if ($opts->{log_file}) {
        open my $fh, '>>', $opts->{log_file}
            or die "failed to open log file:$opts->{log_file}: $!";
        STDOUT->flush;
        STDERR->flush;
        open STDOUT, '>&', $fh
            or die "failed to dup STDOUT to file: $!";
        open STDERR, '>&', $fh
            or die "failed to dup STDERR to file: $!";
        close $fh;
    }

    # create guard that remove the status file
    my $status_file_guard = $opts->{status_file} && Scope::Guard->new(
        sub {
            unlink $opts->{status_file};
        },
    );

    print STDERR "start_server (pid:$$) starting now...\n";

    # start Listening, setup envvar
    my @sock;
    my @sockenv;
    for my $port (@$ports) {
        my $sock;
        if ($port =~ /^\s*(\d+)\s*$/) {
            $sock = IO::Socket::INET->new(
                Listen    => Socket::SOMAXCONN(),
                LocalPort => $port,
                Proto     => 'tcp',
                ReuseAddr => 1,
            );
        } elsif ($port =~ /^\s*(.*)\s*:\s*(\d+)\s*$/) {
            $port = "$1:$2";
            $sock = IO::Socket::INET->new(
                Listen    => Socket::SOMAXCONN(),
                LocalAddr => $port,
                Proto     => 'tcp',
                ReuseAddr => 1,
            );
        } else {
            croak "invalid ``port'' value:$port\n";
        }
        die "failed to listen to $port:$!"
            unless $sock;

        # システムコールを実行する
        # fcntl(ファイルハンドル,コマンド,フラグ)
        # F_SETFD: ファイルディスクリプタ・フラグを戻り値として取得する
        # F_DUPFD: ファイルディスクリプタをコピーする
        # F_GETFD: ファイルディスクリプタ・フラグを戻り値として取得
        # F_GETFL: ファイル状態フラグを戻り値として取得する
        # F_SETFL: ファイル状態フラグに第三引数で指定した「フラグ」の値を設定する
        # F_GETLK: レコード・ロックを獲得する
        # F_SETLK: レコード・ロックを開放する
        # F_SETLKW: レコード・ロックをテストする
        fcntl($sock, F_SETFD, my $flags = '')
            or die "fcntl(F_SETFD, 0) failed:$!";
        push @sockenv, "$port=" . $sock->fileno;
        push @sock, $sock;
    }
    my $path_remove_guard = Scope::Guard->new(
        sub {
            -S $_ and unlink $_
                for @$paths;
        },
    );
    for my $path (@$paths) {
        if (-S $path) {
            warn "removing existing socket file:$path";
            unlink $path
                or die "failed to remove existing socket file:$path:$!";
        }
        unlink $path;
        my $saved_umask = umask(0);
        my $sock = IO::Socket::UNIX->new(
            Listen => Socket::SOMAXCONN(),
            Local  => $path,
        ) or die "failed to listen to file $path:$!";
        umask($saved_umask);
        fcntl($sock, F_SETFD, my $flags = '')
            or die "fcntl(F_SETFD, 0) failed:$!";
        push @sockenv, "$path=" . $sock->fileno;
        push @sock, $sock;
    }
    $ENV{SERVER_STARTER_PORT} = join ";", @sockenv;
    $ENV{SERVER_STARTER_GENERATION} = 0;

    # setup signal handlers
    $SIG{$_} = sub {
        push @signals_received, $_[0];
    } for (qw/INT TERM HUP/);
    $SIG{PIPE} = 'IGNORE';

    # setup status monitor
    my ($current_worker, %old_workers);
    my $update_status = $opts->{status_file}
        ? sub {
            my $tmpfn = "$opts->{status_file}.$$";
            open my $tmpfh, '>', $tmpfn
                or die "failed to create temporary file:$tmpfn:$!";
            my %gen_pid = (
                ($current_worker
                  ? ($ENV{SERVER_STARTER_GENERATION} => $current_worker)
                  : ()),
                map { $old_workers{$_} => $_ } keys %old_workers,
            );
            print $tmpfn "$_:$gen_pid{$_}\n"
                for sort keys %gen_pid;
            close $tmpfh;
            rename $tmpfn, $opts->{status_file}
                or die "failed to rename $tmpfn to $opts->{status_file}:$!";
        } : sub {
        };

    # the main loop
    my $term_signal = 0;
    $current_worker = _start_worker($opts);
    $update_status->();
    my $auto_restart_interval = 0;
    my $last_restart_time = time();
    my $restart_flag = 0;
    while (1) {
        _reload_env();

        # 定期的に自動再起動
        if ($ENV{ENABLE_AUTO_RESTART}) {
            # restart workers periodically
            $auto_restart_interval = $ENV{AUTO_RESTART_INTERVAL} ||= 360;
        }
        sleep(1);

        my $died_worker = -1;
        my $status = -1;
        while (1) {
            # 親プロセスは子プロセスが終了していればそのPIDを、
            # 終了していなければ即座に0を返す(子プロセスの終了を待たない)
            $died_worker = waitpid(-1, WNOHANG);

            $status = $?;
            last if ($died_worker <= 0);

            # ワーカーが死んでいたらリスタートする
            if ($died_worker == $current_worker) {
                print STDERR "worker $died_worker died unexpectedly with status:$status, restarting\n";
                $current_worker = _start_worker($opts);
                $last_restart_time = time();
            } else {
                print STDERR "old worker $died_worker died, status:$status\n";
                delete $old_workers{$died_worker};
                # don't update the status file if restart is scheduled and died_worker is the last one
                if ($restart_flag == 0 || scalar(keys %old_workers) != 0) {
                    $update_status->();
                }
            }
        }

        # 自動リスタートチェック
        if ($auto_restart_interval > 0 && scalar(@signals_received) == 0 &&
            time() > $last_restart_time + $auto_restart_interval) {
            print STDERR "autorestart triggered (interval=$auto_restart_interval)\n";
            $restart_flag = 1;
            if (time() > $last_restart_time + $auto_restart_interval * 2) {
                print STDERR "force autorestart triggered\n";
                $restart_flag = 2;
            }
        }

        # 受け取ったシグナルをチェックして、シグナルの種類に応じて処理する
        my $num_old_workers = scalar(keys %old_workers);
        for (; @signals_received; shift @signals_received) {
            if ($signals_received[0] eq 'HUP') {
                print STDERR "received HUP (num_old_workers=$num_old_workers\n";
                $restart_flag = 1;
            } else {
                $term_signal = $signals_received[0] eq 'TERM' ? $opts->{signal_on_term} : 'TERM';
                goto CLEANUP;
            }
        }

        # 再起動処理(自動リスタートやHUPを受け取った場合)
        if ($restart_flag > 1 || ($restart_flag > 0 && $num_old_workers == 0)) {
            print STDERR "spawning a new worker (num_old_workers=$num_old_workers)\n";
            $old_workers{$current_worker} = $ENV{SERVER_STARTER_GENERATION};
            $current_worker = _start_worker($opts);
            $last_restart_time = time();
            $restart_flag = 0;
            $update_status->();
            print STDERR "new worker is now running, sending $opts->{signal_on_hup} to old workers:";
            if (%old_workers) {
                print STDERR join(',', sort keys %old_workers), "\n";
            } else {
                print STDERR "none\n";
            }

            # 古いプロセスをkillする前の待ち時間
            my $kill_old_delay = $ENV{KILL_OLD_DELAY} || 0;
            $kill_old_delay ||= 5 if $ENV{ENABLE_AUTO_RESTART};
            print STDERR "sleep $kill_old_delay secs\n";
            sleep($kill_old_delay) if $kill_old_delay > 0;
            print STDERR "killing old workers\n";
            kill $opts->{signal_on_hup}, $_
                for sort keys %old_workers;
        }
    }

 CLEANUP:
    # clenup
    $old_workers{$current_worker} = $ENV{SERVER_STARTER_GENERATION};
    undef $current_worker;

    print STDERR "received $signals_received[0], sending $term_signal to all workers:",
        join(',', sort keys %old_workers), "\n";
    kill $term_signal, $_
        for sort keys %old_workers;
    while (%old_workers) {

        # perlの wait や waitpid は、シグナルを受け取っても制御が来ないため、
        # Proc::Wait3を使っている。
        # http://labs.cybozu.co.jp/blog/kazuho/archives/2007/10/perl_mp.php
        if (my @r = wait3(1)) {
            my ($died_worker, $status) = @r;
            print STDERR "worker $died_worker died, status:$status";
            delete $old_workers{$died_worker};
            $update_status->();
        }
    }

    print STDERR "exiting\n";
}

sub restart_server {
    my $opts = {
        (@_ == 1 ? @$_[0] : @_),
    };
    die "--restart option requires --pid-file and --status-file to be set as well\n"
        unless $opts->{pid_file} && $opts->{status_file};

    # get pid
    my $pid = do {
        open my $fh, '<', $opts->{pid_file}
            or die "failed to open file:$opts->{pid_file}:$!";
        my $line = <$fh>;
        chomp $line;
        $line;
    };

    # function that returns a list of active generations in sorted order
    my $get_generations = sub {
        open my $fh, '<', $opts->{status_file}
            or die "failed to opne file:$opts->{status_file}:$!";
        uniq sort { $a <=> $b } map { /^(\d+):/ ? ($1) : () } <$fh>;
    };

    # wait for this generation
    my $wait_for = do {
        my @gens = $get_generations->()
            or die "no active process found in the status file";
        pop(@gens) + 1;
    };

    # send HUP
    kill 'HUP', $pid
        or die "failed to send SIGHUP to the server process:$|";

    # wait for the generation
    while (1) {
        my @gens = $get_generations->();
        last if scalar(@gens) == 1 && $gens[0] >= $wait_for;
        sleep 1;
    }
}

sub server_ports {
    die "no environment variable SERVER_STARTER_PORT. Did you start the process using server_starter?",
        unless $ENV{SERVER_STARTER_PORT};
    my %ports = map {
        +(split /=/, $_, 2)
    } split /;/, $ENV{SERVER_STARTER_PORT};
    \%ports;
}

sub _reload_env {
    my $dh = $ENV{ENVDIR};
    return if !defined $dn or !-d $dn;
    my $d;
    opendir($d, $dn) or return;
    while (my $n = readdir($d)) {
        next if $n =~ /^\./;
        open my $fh, '<', "$dn/$n" or next;
        chomp(my $v = <$fh>);
        $ENV{$n} = $v if $v ne '';
    }
}

sub _start_worker {
    my $opts = shift;
    my $pid;
    while (1) {
        $ENV{SERVER_STARTER_GENERATION}++;
        $pid = fork;
        die "fork(2) failed:$!"
            unless defined $pid;
        if ($pid == 0) {
            # 引数で渡されたプログラムのコマンド
            my @args = @{$opts->{exec}};
            # child process
            if (defined $opts->{dir}) {
                chdir $opts->{dir} or die "failed to chdir:$!";
            }
            # プログラム実行
            # exec PROGRAM LIST
            { exec { $args[0] } @args };
            print STDERR "failed to exec $args[0]$!";
            exit(255);
        }

        ## ここからは親プロセス

        # interval秒だけ待って、新しい子プロセスがエラー終了していないかどうかを確認する
        print STDERR "starting new worker $pid\n";
        sleep $opts->{interval};
        if ((grep { $_ ne 'HUP' } @signals_received)
                || waitpid($pid, WNOHANG) <= 0) {
            last;
        }

        # エラー終了していたら再度実行
        print STDERR "new worker $pid seems to have failed to start, exit status:$?\n";
    }
}

1;
