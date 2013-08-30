package Mailfull::Utils::Locker;

use strict;
use warnings;

# 警告やエラーで出力されるメッセージをより詳細なものにする
use diagnostics;


##############################
# Lock
##############################
sub my_lock {
    my $self = shift;

    while ( !symlink($$, "$Mailfull::Core::Cfg->{path_lockfile}") ) {
        my $pid = readlink("$Mailfull::Core::Cfg->{path_lockfile}") or die "$!";

        if ( kill(0, $pid) ) {
            print STDERR "pid $pid is running. wait 1 sec.\n";
            sleep 1;
        } else {
            $self->my_unlock;
        }
    }
}



##############################
# unLock
##############################
sub my_unlock {
    my $self = shift;

    unlink("$Mailfull::Core::Cfg->{path_lockfile}") or die "$!";
}



1;
