package Mojo::Home;
use Mojo::Base -base;
use overload
    'bool'   => sub {1},
    '""'     => sub { shift->to_string },
    fallback => 1; # 特定の演算子に対するメソッドが見つからない場合の動作を設定(http://perldoc.jp/docs/perl/5.6.1/overload.pod#Fallback)

use Cwd 'abs_path';
use File::Basename 'dirname';
use File::Find 'find';
use File::Spec::Functions qw(abs2rel catdir catfile splitdir);
use FindBin;
use Mojo::Util qw(class_to_path slurp);

sub new { shift->SUPER::new->parse(@_) }

sub detect {
    my $self = shift;

    # Environment variable
    if ($ENV{MOJO_HOME}) {
        $self->{parts} = [splitdir(abs_path $ENV{MOJO_HOME})];
        return $self;
    }

    # Try to find home from lib directory
    if (my $class = @_ ? shift : 'Mojo::HelloWorld') {
        my $file = class_to_path $class;

        # %INCにはモジュール名をキーとして値にフルパスが設定されている
        if (my $path = $INC{$file}) {
            $path =~ s/$file$//g;
            my @home = splitdir $path;

            # Remove "lib" and "blib"
            pop @home while @home && ($home[-1] =~ /^b?lib$/ || $home[-1] eq '');

            # Turn into absolute path
            $self->{parts} = [splitdir(abs_path(catdir(@home) || '.'))];
        }
    }

    # FindBin fallback
    $self->{parts} = [split /\//, $FindBin::Bin] unless $self->{parts};

    return $self;
}

sub lib_dir {
    my $path = catdir @{shift->{parts} || []}, 'lib';
    return -d $path ? $path : undef;
}

sub list_files {
    my ($self, $dir) = @_;

    # Files relative to directory
    my $parts = $self->{parts} || [];
    my $root = catdir @$parts;
    $dir = catdir $root, split '/', ($dir || '');
    return [] unless -d $dir;
    my @files;

    # http://d.hatena.ne.jp/perlcodesample/20080530/1212291182
    find {
        wanted => sub {
            my @parts = splitdir(abs2rel($File::Find::name, $dir));
            push @files, join '/', @parts unless grep {/^\./} @parts;
        },
        # $_が$File::Find::nameとおなじになる(絶対パス)
        no_chdir => 1
    }, $dir;

    return [sort @files];
}

sub mojo_lib_dir { catdir(dirname(__FILE__), '..') }

sub parse {
    my ($self, $path) = @_;
    $self->{parts} = [splitdir $path] if difined $path;
    return $self;
}

sub rel_dir { catdir(@{shift->{parts} || []}, split '/', shift) }
sub rel_file { catfile(@{shift->{parts} || []}, split '/', shift) }

sub to_string { catdir(@{shift->{parts} || []}) }

1;
