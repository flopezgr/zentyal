# Copyright (C) 2013 Zentyal S.L.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License, version 2, as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

use strict;
use warnings;

use Test::More tests => 14;
use Error qw(:try);

use lib '../../..';

use EBox::TestStub;
use EBox::Config::Redis;
use EBox::Test::RedisMock;

EBox::TestStub::fake();
my $redisMock = EBox::Test::RedisMock->new();

$redisMock->set('foo', 5);
$redisMock->set('bar', 'this is a string');
is ($redisMock->get('foo'), 5);
is ($redisMock->get('bar'), 'this is a string');

my $redis = EBox::Config::Redis->instance(customRedis => $redisMock);

$redis->{redis}->__send_command('set', 'raw-foo', 'rawvalue');
$redis->{redis}->__send_command('get', 'raw-foo');
is ($redis->{redis}->__read_response(), 'rawvalue', 'set & get using lowest-level API');

$redis->_redis_call('set', 'raw-bar', 666);
is ($redis->_redis_call('get', 'raw-bar'), 666, 'set & get using API without cache');

is ($redis->get('unexistent'), undef, 'try to get undefined key');

$redis->set('foo', 5);
$redis->set('bar', 'this is a string');

is ($redis->get('foo'), 5);

$redis->unset('foo');

is ($redis->get('foo'), undef, 'try to get key after deleting it');
is ($redis->get('bar'), 'this is a string', 'get string with spaces');

$redis->begin();
$redis->set('multi1', 1);
$redis->set('multi2', 2);
$redis->set('multi3', 3);
$redis->commit();

is ($redis->get('multi3'), 3, 'get value after successful transaction');

$redis->begin();
$redis->set('multi1', 10);
$redis->set('multi3', 40);
$redis->rollback();

is ($redis->get('multi1'), 1, 'get old value after rollback');

$redis->{redis}->multi();
ok ($redis->{redis}->exec(), 'successful low-level exec after multi');

try {
    $redis->{redis}->exec();
    fail('exec without multi not allowed');
} otherwise {
    pass('exec without multi not allowed');
};

try {
    $redis->rollback();
    fail('discard without multi not allowed');
} otherwise {
    pass('discard without multi not allowed');
};

1;
