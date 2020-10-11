use strict;
use warnings;

use Test::More tests => 4;
use Test::Deep;
use Pegex;

my $grammar = <<'...';
date: /( \d{4} )/ sep? /( \d{2} )/ sep? /( \d{2} )/
sep: /( '/' | '-' )/
...

my $parser = pegex($grammar, 'Pegex::Tree');

cmp_deeply $parser->parse('2020/11/10'), ['2020',  '/',  '11',  '/',  '10'], 'all optionals given 1/2';
cmp_deeply $parser->parse('2020-10-11'), ['2020',  '-',  '10',  '-',  '11'], 'all optionals given 2/2';
cmp_deeply $parser->parse('202010-11'),  ['2020', undef, '10',  '-',  '11'], 'one optional undef';
cmp_deeply $parser->parse('20201011'),   ['2020', undef, '10', undef, '11'], 'all optional undef';
