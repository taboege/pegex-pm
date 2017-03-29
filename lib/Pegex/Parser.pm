package Pegex::Parser;
use Pegex::Base;
no warnings qw( recursion );

use Pegex::Input;
use Pegex::Optimizer;
use Pegex::Errors;
use Scalar::Util;

#------------------------------------------------------------------------------
# Parser attributes:
#------------------------------------------------------------------------------

# Singleton object pointers:
has grammar => (required => 1);
has receiver => (required => 1);
has optimizer => ();

has input => ();
has error => ();

has start => ();                    # Start rule name
has return => 0;                    # return() on error
has partial => 0;                   # Allow a partial parse

has position => ();                 # Current parse position
has farthest => ();                 # Farthest parse position
has length => ();                   # Length of input to parse
has continue => 0;                  # Continue parsing from previous partial

has recursion_count => 0;
has iteration_count => 0;
has recursion_limit => ();
has recursion_warn_limit => ();
has iteration_limit => ();

has debug => ();
has debug_indent => ();
has debug_color => ();
has debug_got_color => ();
has debug_not_color => ();

#------------------------------------------------------------------------------
# Object construction.
#------------------------------------------------------------------------------

sub BUILD {
    my ($self) = @_;

    $self->_check_deprecated;
    $self->_set_debug;
    $self->_set_limits;
}

sub reset {
    my ($self) = @_;
    $self->{position} = 0;
    $self->{farthest} = 0;
    return $self;
}

#------------------------------------------------------------------------------
# Parser API.
#------------------------------------------------------------------------------

sub parse {
    my $self = shift;

    local *match_next;
    $self->_setup_parser(@_);

    # TODO: Don't reset on 'continue'. Trigger continue from parse().
    $self->reset;

    my $start = $self->{start};

    my $match = $self->debug
        ? do {
            my $method = $self->{optimizer}->make_trace_wrapper(\&match_ref);
            $self->$method($start, {'+asr' => 0});
        }
        : $self->match_ref($start, {});
    my $completed = $self->completed;

    $self->{input}->close if $completed;

    if (not ($match and ($completed or $self->{partial}))) {
        $self->throw_error("Parse document failed for some reason");
        return;  # In case $self->return is on
    }

    if ($self->{receiver}->can("final")) {
        $self->{rule} = $start;
        $self->{parent} = {};
        $match = [ $self->{receiver}->final(@$match) ];
    }

    return $match->[0];
}

sub completed {
    my ($self) = @_;
    return $self->{position} >= $self->{length} ? 1 : 0;
}

#------------------------------------------------------------------------------
# Match logic functions.
#------------------------------------------------------------------------------
sub match_next_normal {
    my ($self, $next) = @_;

    my ($rule, $method, $kind, $min, $max, $assertion) =
        @{$next}{'rule', 'method', 'kind', '+min', '+max', '+asr'};

    my ($position, $match, $count) =
        ($self->{position}, [], 0);

    while (my $return = $method->($self, $rule, $next)) {
        $position = $self->{position} unless $assertion;
        $count++;
        push @$match, @$return;
        last if $max == 1;
    }
    if (not $count and $min == 0 and $kind eq 'all') {
        $match = [[]];
    }
    if ($max != 1) {
        if ($next->{-flat}) {
            $match = [ map { (ref($_) eq 'ARRAY') ? (@$_) : ($_) } @$match ];
        }
        else {
            $match = [$match]
        }
    }
    my $result = ($count >= $min and (not $max or $count <= $max))
        ^ ($assertion == -1);
    if (not($result) or $assertion) {
        $self->{farthest} = $position
            if ($self->{position} = $position) > $self->{farthest};
    }

    ($result ? $next->{'-skip'} ? [] : $match : 0);
}

sub match_next_with_limit {
    my ($self, $next) = @_;

    $self->{iteration_count}++;
    $self->{recursion_count}++;

    if (
        $self->{recursion_limit} and
        $self->{recursion_count} >= $self->{recursion_limit}
    ) { die err_deep_recursion $self->{recursion_count} }
    elsif (
        $self->{recursion_warn_limit} and
        not ($self->{recursion_count} % $self->{recursion_warn_limit})
    ) { warn err_deep_recursion $self->{recursion_count} }
    elsif (
        $self->{iteration_limit} and
        $self->{iteration_count} > $self->{iteration_limit}
    ) { die err_iteration_limit $self->{iteration_limit} }

    my $result = $self->match_next_normal($next);

    $self->{recursion_count}--;

    return $result;
}

sub match_rule {
    my ($self, $position, $match) = (@_, []);
    $self->{position} = $position;
    $self->{farthest} = $position
        if $position > $self->{farthest};
    $match = [ $match ] if @$match > 1;
    my ($ref, $parent) = @{$self}{'rule', 'parent'};
    my $rule = $self->{grammar}{tree}{$ref}
        or die err_no_rule_defined $ref;

    [ $rule->{action}->($self->{receiver}, @$match) ];
}

sub match_ref {
    my ($self, $ref, $parent) = @_;
    my $rule = $self->{grammar}{tree}{$ref}
        or die err_no_rule_defined $ref;
    my $match = $self->match_next($rule) or return;
    return $Pegex::Constant::Dummy unless $rule->{action};
    @{$self}{'rule', 'parent'} = ($ref, $parent);

    # XXX Possible API mismatch.
    # Not sure if we should "splat" the $match.
    [ $rule->{action}->($self->{receiver}, @$match) ];
}

sub match_rgx {
    my ($self, $regexp) = @_;
    my $buffer = $self->{buffer};

    pos($$buffer) = $self->{position};
    $$buffer =~ /$regexp/g or return;

    $self->{position} = pos($$buffer);

    $self->{farthest} = $self->{position}
        if $self->{position} > $self->{farthest};

    no strict 'refs';
    my $captures = [ map $$_, 1..$#+ ];
    $captures = [ $captures ] if $#+ > 1;

    return $captures;
}

sub match_all {
    my ($self, $list) = @_;
    my $position = $self->{position};
    my $set = [];
    my $len = 0;
    for my $elem (@$list) {
        if (my $match = $self->match_next($elem)) {
            if (not ($elem->{'+asr'} or $elem->{'-skip'})) {
                push @$set, @$match;
                $len++;
            }
        }
        else {
            $self->{farthest} = $position
                if ($self->{position} = $position) > $self->{farthest};
            return;
        }
    }
    $set = [ $set ] if $len > 1;
    return $set;
}

sub match_any {
    my ($self, $list) = @_;
    for my $elem (@$list) {
        if (my $match = $self->match_next($elem)) {
            return $match;
        }
    }
    return;
}

sub match_err {
    my ($self, $error) = @_;
    $self->throw_error($error);
}

#------------------------------------------------------------------------------
# Error handing and debugging code.
#------------------------------------------------------------------------------

sub throw_error {
    my ($self, $msg) = @_;
    $@ = $self->{error} = $self->format_error($msg);
    return () if $self->{return};
    require Carp;
    Carp::croak($self->{error});
}

sub format_error {
    my ($self, $msg) = @_;
    my $buffer = $self->{buffer};
    my $position = $self->{farthest};
    my $real_pos = $self->{position};

    my $line = $self->line($position);
    my $column = $position - rindex($$buffer, "\n", $position);

    my $pretext = substr(
        $$buffer,
        $position < 50 ? 0 : $position - 50,
        $position < 50 ? $position : 50
    );
    my $context = substr($$buffer, $position, 50);
    $pretext =~ s/.*\n//gs;
    $context =~ s/\n/\\n/g;

    return <<"...";
Error parsing Pegex document:
  msg:      $msg
  line:     $line
  column:   $column
  context:  $pretext$context
  ${\ (' ' x (length($pretext) + 10) . '^')}
  position: $position ($real_pos pre-lookahead)
...
}

# TODO Move this to a Parser helper role/subclass
sub line_column {
    my ($self, $position) = @_;
    $position ||= $self->{position};
    my $buffer = $self->{buffer};
    my $line = $self->line($position);
    my $column = $position - rindex($$buffer, "\n", $position);
    return [$line, $column];
}

sub line {
    my ($self, $position) = @_;
    $position ||= $self->{position};
    my $buffer = $self->{buffer};
    my $last_line = $self->{last_line};
    my $last_line_pos = $self->{last_line_pos};
    my $len = $position - $last_line_pos;
    if ($len == 0) {
        return $last_line;
    }
    my $line;
    if ($len < 0) {
        $line = $last_line - scalar substr($$buffer, $position, -$len) =~ tr/\n//;
    } else {
        $line = $last_line + scalar substr($$buffer, $last_line_pos, $len) =~ tr/\n//;
    }
    $self->{last_line} = $line;
    $self->{last_line_pos} = $position;
    return $line;
}

sub trace {
    my ($self, $action) = @_;
    my $indent = ($action =~ /^try_/) ? 1 : 0;
    $self->{indent} ||= 0;
    $self->{indent}-- unless $indent;

    $action = (
        $action =~ m/got_/ ?
            Term::ANSIColor::colored($self->{debug_got_color}, $action) :
        $action =~ m/not_/ ?
            Term::ANSIColor::colored($self->{debug_not_color}, $action) :
        $action
    ) if $self->{debug_color};

    print STDERR ' ' x ($self->{indent} * $self->{debug_indent});
    $self->{indent}++ if $indent;
    my $snippet = substr(${$self->{buffer}}, $self->{position});
    $snippet = substr($snippet, 0, 30) . "..."
        if length $snippet > 30;
    $snippet =~ s/\n/\\n/g;
    print STDERR sprintf("%-30s", $action) .
        ($indent ? " >$snippet<\n" : "\n");
}

#------------------------------------------------------------------------------
# Private methods.
#------------------------------------------------------------------------------

sub _check_deprecated {
    my ($self) = @_;

    die err_throw_on_error_deprecated
        if exists $self->{throw_on_error};
}

sub _setup_parser {
    my $self = shift;

    my ($input, $options) = (undef, {});
    $self->{continue} = 0;
    # Possible call signatures:
    # * $parser->parse($input);
    # * $parser->parse($input, $options_hash_ref);
    # * $parser->parse();
    # * $parser->parse($input, $start_rule);
    if (@_ == 0) {
        die err_no_previous_parse unless defined $self->position;
        $self->{continue} = 1;
    }
    elsif (@_ == 1) {
        die err_first_arg_not_input
            unless not(ref $_[0]) or ref($_[0]) eq 'Pegex::Input';
        $input = shift;
    }
    elsif (@_ == 2) {
        $input = shift;
        if (not ref $_[0]) {
            $options->{start} = shift;
        }
        else {
            $options = shift;
            die err_second_arg_not_options
                unless ref $options eq 'HASH';
        }
    }
    else {
        die err_invalid_parse_args;
    }

    # Get an open Pegex::Input object:
    if (defined $input) {
        $self->{input} = (not ref $input)
        ? Pegex::Input->new(string => $input)
        : $input;
    }

    die err_invalid_parse_input
        unless defined $self->{input} and
            ref($self->{input}) eq 'Pegex::Input' and
            $self->{input}->open;

    # Check that options are valid:
    for my $key (keys %$options) {
        die err_invalid_parse_option $key unless $key =~
            /^(start|return|partial)$/;
    }

    # Make sure grammar tree is built:
    $self->{grammar}{tree} ||= $self->{grammar}->make_tree;

    # Get the desired start rule:
    $self->{start} =
        $options->{start} ||
        $self->{start} ||
        $self->{grammar}->{tree}{'+toprule'} ||
        $self->{grammar}->{tree}{'TOP'} && 'TOP' or
        die err_no_starting_rule;
    $self->{start} =~ s/-/_/g;

    if (not defined $self->{optimizer}) {
        $self->{optimizer} = Pegex::Optimizer->new(
            parser => $self,
            grammar => $self->{grammar},
            receiver => $self->{receiver},
        );
        # XXX this should optimize all rules, not just the tree starting at
        # $start. Otherwise we can reuse the parser with differing start rules.
        $self->optimizer->optimize_grammar($self->{start});

        $self->{position} = 0;
        $self->{farthest} = 0;
    }
    else {
        # This is a subsequent $parser->parse() call:
    }


    # Add circular ref and weaken it.
    $self->{receiver}{parser} = $self;
    Scalar::Util::weaken($self->{receiver}{parser});

    if ($self->{receiver}->can("initial")) {
        $self->{rule} = $self->{start};
        $self->{parent} = {};
        $self->{receiver}->initial();
    }

    {
        no warnings 'redefine';
        *match_next = (
            $self->{recursion_warn_limit} or
            $self->{recursion_limit} or
            $self->{iteration_limit}
         )
            ? \&match_next_with_limit
            : \&match_next_normal;
    }

    $self->{input}->open
        unless $self->{input}{_is_open};
    my $buffer = $self->{buffer} = $self->{input}->read;
    $self->{length} = length $$buffer;
    $self->{last_line_pos} = 0;
    $self->{last_line} = 1;
}

sub _set_debug {
    my ($self) = @_;

    $self->{debug} //=
        $ENV{PERL_PEGEX_DEBUG} //
        $Pegex::Parser::Debug // 0;

    $self->{debug_indent} //=
        $ENV{PERL_PEGEX_DEBUG_INDENT} //
        $Pegex::Parser::DebugIndent // 1;
    $self->{debug_indent} = 1 if (
        not length $self->{debug_indent}
        or $self->{debug_indent} =~ tr/0-9//c
        or $self->{debug_indent} < 0
    );

    if ($self->{debug}) {
        $self->{debug_color} //=
            $ENV{PERL_PEGEX_DEBUG_COLOR} //
            $Pegex::Parser::DebugColor // 1;
        my ($got, $not);
        ($self->{debug_color}, $got, $not) =
            split / *, */, $self->{debug_color};
        $got ||= 'bright_green';
        $not ||= 'bright_red';
        $_ = [split ' ', $_] for ($got, $not);
        $self->{debug_got_color} = $got;
        $self->{debug_not_color} = $not;
        my $c = $self->{debug_color} // 1;
        $self->{debug_color} =
            $c eq 'always' ? 1 :
            $c eq 'auto' ? (-t STDERR ? 1 : 0) :
            $c eq 'never' ? 0 :
            $c =~ /^\d+$/ ? $c : 0;
        if ($self->{debug_color}) {
            require Term::ANSIColor;
            if ($Term::ANSIColor::VERSION < 3.00) {
                s/^bright_// for
                    @{$self->{debug_got_color}},
                    @{$self->{debug_not_color}};
            }
        }
    }
}

sub _set_limits {
    my ($self) = @_;

    $self->{recursion_limit} //=
        $ENV{PERL_PEGEX_RECURSION_LIMIT} //
        $Pegex::Parser::RecursionLimit // 0;
    $self->{recursion_warn_limit} //=
        $ENV{PERL_PEGEX_RECURSION_WARN_LIMIT} //
        $Pegex::Parser::RecursionWarnLimit // 0;
    $self->{iteration_limit} //=
        $ENV{PERL_PEGEX_ITERATION_LIMIT} //
        $Pegex::Parser::IterationLimit // 0;
}


#------------------------------------------------------------------------------
# Constants.
#------------------------------------------------------------------------------

# XXX Need to figure out what uses this. (sample.t)
{
    package Pegex::Constant;
    our $Null = [];
    our $Dummy = [];
}

1;
