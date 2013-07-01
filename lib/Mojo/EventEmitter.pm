package Mojo::EventEmitter;
use Mojo::Base -base;

use Scalar::Util qw(blessed weaken);

use constant DEBUG => $ENV{MOJO_EVENTEMITTER_DEBUG} || 0;

sub emit {
    my ($self, $name) = (shift, shift);

    # $nameに対応するコールバックを実行する
    if (my $s = $self->{events}{$name}) {
        warn "-- Emit $name in @{[blessed($self)]} (@{[scalar(@$s)]})\n" if DEBUG;
        for my $cb (@$s) { $self->$cb(@_) }
    }
    else {
        warn "-- Emit $name in @{[blessed($self)]} (0)\n" if DEBUG;
        warn $_[0] if $name eq 'error';
    }

    return $self;
}

sub emit_safe {
    my ($self, $name) = (shift, shift);

    if (my $s = $self->{events}{$name}) {
        warn "-- Emit $name in @{[blessed($self)]} safely (@{[scalar(@$s)]})\n" if DEBUG;
        for my $cb (@$s) {
            unless (eval { $self->$cb(@_); 1 }) {

                # Error event failed
                if ($name eq 'error') { warn qq{Event "error" failed: $@} }

                # Normal event failed
                else { $self->emit_safe('error', qq{Event "$name" failed: $@}) }
            }
        }
    }
    else {
        warn "-- Emit $name in @{[blessed($self)]} safely (0)\n" if DEBUG;
        warn $_[0] if $name eq 'error';
    }

    return $self;
}

# !!でboolean化している
sub has_subscribers { !!@{shift->subscribers(shift)} }

sub on {
    my ($self, $name, $cb) = @_;

    # コールバックを追加する
    push @{$self->{events}{$name} ||= []}, $cb;

    return $cb;
}

sub once {
    my ($self, $name, $cb) = @_;

    # コールバックをラップして、コールバック削除処理を追加する
    # ラッパーで$selfを参照し、onceメソッドで$wrapperを参照しているので循環参照になる。
    # メモリリークを避けるためにweakenで対応する。
    # http://memememomo.hatenablog.com/entry/20100528/1275005888
    weaken $self;
    my $wrapper;
    $wrapper = sub {
        $self->unsubscribe($name => $wrapper);
        $cb->(@_);
    };
    $self->on($name => $wrapper);
    weaken $wrapper;

    return $wrapper;
}

sub subscribers { shift->{events}{shift()} || [] }

sub unsubscribe {
    my ($self, $name, $cb) = @_;

    # One
    # 1つのコールバックを削除
    if ($cb) {
        $self->{events}{$name} = [grep { $cb ne $_ } @{$self->{events}{$name}}];
    }

    # ALL
    # 名前単位でコールバックを削除
    else { delete $self->{events}{$name} }

    return $self;
}

1;
