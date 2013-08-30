package Mojo::Server;
use Mojo::Base 'Mojo::EventEmitter';

use Carp 'croak';
use FindBin;
use Mojo::Loader;
use Mojo::Util 'md5_sum';
use Scalar::Util 'blessed';


has app => sub { shift->build_app('Mojo::HelloWorld') };

sub new {
    my $self = shift->SUPER::new(@_);

    # requestイベントが発火されたら、appのhandlerメソッドを呼び出す
    $self->on(request => sub { shift->app->handler(shift) });

    return $self;
}

sub build_app {
    my ($self, $app) = @_;
    local $ENV{MOJO_EXE};
    return $app->new unless my $e = Mojo::Loader->new->load($app);
    die ref $e ? $e : qq{Couldn't find application class "$app".\n};
}

sub build_tx { shift->app->build_tx }

sub load_app {
    my ($self, $path) = @_;

    # Clean environment (reset FindBin)
    {
        local $0 = $path;

        # https://metacpan.org/module/FindBin#KNOWN-ISSUES
        # 同じプロセス内でFindBinを異なるディレクトリで複数回呼び出すと動作しない。
        # これを解決するためにagainメソッドを呼び出す。
        #  delete $INC{'FindBin.pm'};
        #  require FindBin;
        # と同じ処理。
        FindBin->again;

        local $ENV{MOJO_APP_LOADER} = 1;
        local $ENV{MOJO_EXE};

        # Try to load application from script into sandbox
        my $app = eval sprintf <<'EOF', md5_sum($path . $$);
package Mojo::Server::Sandbox::%s;
my $app = do $path;
if (!$app && (my $e = $@ || $!)) { die $e }
$app;
EOF
        die qq{Couldn't load application from file file "$path": $@} if !$app && $@;
        die qq{File "$path" did not return an application object.\n}
           unless blessed $app && $app->isa('Mojo');
        $self->app($app);
    };
    FindBin->again;

    return $self->app;
}

sub run { croak 'Method "run" not implemented by subclass' }

1;
