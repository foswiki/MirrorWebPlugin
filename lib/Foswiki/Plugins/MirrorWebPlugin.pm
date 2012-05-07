# See bottom of file for license and copyright information

=begin TML

---+ package Foswiki::Plugins::MirrorWebPlugin

=cut

package Foswiki::Plugins::MirrorWebPlugin;

use strict;
use Assert;

use CGI              ();
use Foswiki::Func    ();
use Foswiki::Plugins ();

our $VERSION = '$Rev: 5154 $';
our $RELEASE = '1.1.6';
our $SHORTDESCRIPTION =
  'Mirror a web to another, with filtering on the topic text and fields.';
our $NO_PREFS_IN_TOPIC = 1;
our %RULES;
our $recursionBlock;
# Enable this to print progress messages to STDOUT. Don't enable it in
# a handler!
our $printProgress = 0;

sub initPlugin {
    my ( $topic, $web, $user, $installWeb ) = @_;

    Foswiki::Func::registerTagHandler( 'UPDATEMIRROR', \&_UPDATEMIRROR );
    Foswiki::Func::registerRESTHandler( 'update', \&_restUPDATEMIRROR );

    return 1;
}

# The rules must observe the following grammar:
# value :: array | hash | string ;
# array :: '[' value ( ',' value )* ']' ;
# hash  :: '{' keydef ( ',' keydef )* ']';
# keydef :: string '=>' value ;
# string ::= single quoted string, use \' to escape a quote, or \w+
sub _loadRules {
    my ( $rules, $tom ) = @_;

    my ( $web, $topic ) =
      Foswiki::Func::normalizeWebTopicName( $tom->web(), $rules );
    my $key = "$web.$topic";
    if ( !$RULES{$key} ) {
        ASSERT( Foswiki::Func::topicExists( $web, $topic ) ) if DEBUG;
        my ( $meta, $text ) = Foswiki::Func::readTopic( $web, $topic );

        # Implicit untaint
        if ( $text =~ m#<verbatim>(.+)<\/verbatim>#s ) {
            my $clean = $1;
            if ( my $s = _rvalue( $clean )) {
                die "Could not parse rules (at: $s) $clean";
            }
            my $FORMS;
            eval "\$FORMS={$clean}";
            die "Unable to load $key: $@" if $@;
            die "Empty ruleset $key" unless $FORMS;
            $RULES{$key} = $FORMS;
        }
        else {
            die "No rules in $text";
        }
    }
    return $RULES{$key};
}

# verify that the string is a legal rvalue according to the grammar
sub _rvalue {
    my ( $s, $term ) = @_;

    $s =~ s/^\s*(.*?)\s*$/$1/s;
    while ( length($s) > 0 && ( !$term || $s !~ s/^\s*$term// ) ) {
        if ( $s =~ s/^\s*'//s ) {
            my $escaped = 0;
            while ( length($s) > 0 && $s =~ s/^(.)//s ) {
                last if ( $1 eq "'" && !$escaped );
                $escaped = $1 eq '\\';
            }
        }
        elsif ( $s =~ s/^\s*(\w+)//s ) {
        }
        elsif ( $s =~ s/^\s*\[//s ) {
            $s = _rvalue( $s, ']' );
        }
        elsif ( $s =~ s/^\s*{//s ) {
            $s = _rvalue( $s, '}' );
        }
        elsif ( $s =~ s/^\s*(,|=>)//s ) {
        }
        else {
            last;
        }
    }
    return $s;
}

sub _synch {
    my ( $topicObject, $mirrorWeb ) = @_;

    my $mirrorObject;
    if ( Foswiki::Func::topicExists( $mirrorWeb, $topicObject->topic() ) ) {
        ( $mirrorObject, my $junk ) =
          Foswiki::Func::readTopic( $mirrorWeb, $topicObject->topic() );
    }
    else {
        $mirrorObject =
          new Foswiki::Meta( $Foswiki::Plugins::SESSION, $mirrorWeb,
            $topicObject->topic() );
    }
    my $ruleset = Foswiki::Func::getPreferencesValue('MIRRORWEBPLUGIN_RULES');
    return 0 unless $ruleset;
    $ruleset = _loadRules( $ruleset, $topicObject );

    my $rules;
    my $form = $topicObject->get('FORM');
    if ($form) {
        $rules = $ruleset->{ $form->{name} };
        $mirrorObject->put( 'FORM', { name => $form->{name} } );
    } else {
        $rules = $ruleset->{'none'};
    }
    unless ($rules) {
        $rules = $ruleset->{'other'};
        return 0 unless $rules;
    }

    foreach my $type ( keys %$rules ) {
        if ( $type eq 'text' ) {
            my $data = $topicObject->text();
            $data =
              _applyFilters( $rules->{text}, $topicObject, $mirrorObject,
                $data );
            $mirrorObject->text($data) if defined $data;
        }
        else {
            # clear old fields
            $mirrorObject->remove($type);
            # Support for all other keyed types
            foreach my $regex ( keys %{ $rules->{$type} } ) {
                # Find fields that match the regex
                foreach my $data ($topicObject->find($type)) {
                    if ($data->{name} =~ /^$regex$/) {
                        $data = _applyFilters(
                            $rules->{$type}->{$regex},
                            $topicObject, $mirrorObject, $data );
                         if (ref($data)) {
                             $mirrorObject->putKeyed( $type, $data );
                             if ($type eq 'FILEATTACHMENT') {
                                 _synchAttachment(
                                     $topicObject, $mirrorWeb, $data->{name});
                             }
                         }
                    }
                }
            }
        }
    }

    Foswiki::Func::saveTopic( $mirrorWeb, $topicObject->topic(), $mirrorObject,
        $mirrorObject->text(), { dontlog => 1, forcenewrevision => 1 } );
    return 1;
}

sub _applyFilters {
    my ( $filters, $topicObject, $mirrorObject, $data ) = @_;
    return $data unless $filters;
    foreach my $f (@$filters) {
        die "Bad rule $f" unless $f =~ /^\w+(\([\w,]*\))?$/;
        my @params = ();
        my $filter = 'Foswiki::Plugins::MirrorWebPlugin::Rules::' . $f;
        if ( $filter =~ s/\((.*)\)$// ) {
            @params = split( ',', $1 );
        }
        eval 'require ' . $filter;
        die $@ if $@;
        $filter .= '::execute';
        no strict 'refs';
        $data = &$filter( $topicObject, $mirrorObject, $data, @params );
        use strict 'refs';
    }
    return $data;
}

sub _synchAttachment {
    my ( $topicObject, $mirrorWeb, $name ) = @_;

    # This came from the FILEATTACHMENT in a topic, so may be
    # polluted. Sanitize it.
    ( $name ) = Foswiki::Sandbox::sanitizeAttachmentName($name);

    # If we are using a file database, do a simple
    # copy, including the history.
    if (-f $Foswiki::cfg{PubDir} . '/' . $topicObject->web() . '/'
          . $topicObject->topic() . '/' . $name) {

        mkdir($Foswiki::cfg{PubDir} . '/' . $mirrorWeb);
        mkdir($Foswiki::cfg{PubDir} . '/' . $mirrorWeb . '/'
          . $topicObject->topic());
        File::Copy::copy(
            $Foswiki::cfg{PubDir} . '/' . $topicObject->web() . '/'
              . $topicObject->topic() . '/' . $name,
            $Foswiki::cfg{PubDir} . '/' . $mirrorWeb . '/'
              . $topicObject->topic() . '/' . $name);
        if (-f $Foswiki::cfg{PubDir} . '/' . $topicObject->web() . '/'
              . $topicObject->topic() . '/' . $name . ',v') {
            File::Copy::copy(
                $Foswiki::cfg{PubDir} . '/' . $topicObject->web() . '/'
                  . $topicObject->topic() . '/' . $name . ',v',
                $Foswiki::cfg{PubDir} . '/' . $mirrorWeb . '/'
                  . $topicObject->topic() . '/' . $name . ',v');
        }
        print "Synched ".$topicObject->topic()."/$name\n" if $printProgress;
    } else {
        # Otherwise copy over the latest
        my $data = Foswiki::Func::readAttachment(
              $topicObject->web(),
              $topicObject->topic(),
              $name);
        my $tmpfile = new File::Temp();
        print $tmpfile($data);
        $tmpfile->close();
        Foswiki::Func::saveAttachment(
            $mirrorWeb,
            $topicObject->topic(),
            $data->{name},
            {
                dontlog       => 1,
                comment       => "synched",
                file          => $tmpfile->filename(),
                notopicchange => 1,
            });
    }
}

# Handle the mirror, if required
sub afterSaveHandler {
    my ( $text, $topic, $web, $error, $meta ) = @_;

    return if $recursionBlock;
    local $recursionBlock = 1;

    my $mirror = Foswiki::Func::getPreferencesValue( 'ALLOWWEBMIRROR', $web );
    return if $mirror;

    $mirror =
      Foswiki::Func::getPreferencesValue( 'MIRRORWEBPLUGIN_MIRROR', $web );
    return unless defined $mirror;

    ASSERT( Foswiki::Func::webExists($mirror) ) if DEBUG;

    # Should not need an afterAttachmentSaveHandler because this handler
    # is called when the topic changes due to the attachment change
    _synch( $meta, $mirror );
}

sub _UPDATEMIRROR {
    my ( $session, $params, $topic, $web, $topicObject ) = @_;

    return
        '<span class="foswikiAlert">'
      . 'The current user is not allowed to mirror the '
      . $web
      . ' web</span>'
      unless Foswiki::Func::checkAccessPermission( 'MIRROR',
        Foswiki::Func::getCanonicalUserID(),
        undef, $topic, $web );

    my $html = CGI::start_form(
        -action => '%SCRIPTURL{rest}%/MirrorWebPlugin/update',
        -method => 'post'
    );
    $html .= CGI::hidden( -name => 'topic', -value => '%WEB%.%TOPIC%' );
    if ($params->{_DEFAULT}) {
        $html .= CGI::hidden(
            -name => 'topics', -value => $params->{_DEFAULT} );
    }
    $html .= CGI::submit( -name => 'Update mirror' );
    $html .= CGI::end_form();
    return $html;
}

sub _restUPDATEMIRROR {
    my ( $session, $plugin, $verb ) = @_;

    my $query = Foswiki::Func::getCgiQuery();
    my $web   = $query->param('web')
      || $Foswiki::Plugins::SESSION->{webName};

    unless (
        Foswiki::Func::checkAccessPermission(
            'MIRROR', Foswiki::Func::getCanonicalUserID(),
            undef,    $Foswiki::cfg{WebPrefsTopicName},
            $web
        )
      )
    {
        print CGI::header(
            -status => 400,
            -type   => 'text/plain',
        );
        print "Access denied";
    }

    print CGI::header(
        -status => 200,
        -type   => 'text/plain',
    );

    my $mirrorWeb =
      Foswiki::Func::getPreferencesValue( 'MIRRORWEBPLUGIN_MIRROR', $web );
    unless ( defined $mirrorWeb ) {
        print(<<HERE);
$web does not have MIRRORWEBPLUGIN_MIRROR defined, so nothing to do
HERE
        return undef;
    }

    my @topics;
    if ($query->param('topics')) {
        my $tl = $query->param('topics');
        $tl =~ /([\w,]*)/; # validate and untaint
        @topics = split(',', $1);
    } else {
        @topics = Foswiki::Func::getTopicList($web);
    }

    local $printProgress = 1;
    foreach my $topic (@topics) {
        my ( $meta, $text ) = Foswiki::Func::readTopic( $web, $topic );
        Foswiki::Func::pushTopicContext( $web, $topic );

        # We have to re-read the topic to get the
        # right session in the $meta. This could be done by patching the
        # $meta object, but this should be longer-lasting.
        ( $meta, $text ) = Foswiki::Func::readTopic( $web, $topic );
        if ( _synch( $meta, $mirrorWeb ) ) {
            print("Synched $topic\n");
        }
        Foswiki::Func::popTopicContext();
    }
    return undef;
}

1;
__END__
Plugin for Foswiki - The Free and Open Source Wiki, http://foswiki.org/

Author: Crawford Currie http://c-dot.co.uk

Copyright (C) 2009 Rental Result
Copyright (C) 2009 Foswiki Contributors
Foswiki Contributors are listed in the AUTHORS file in the root of this
distribution. NOTE: Please extend that file, not this notice. 

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

For licensing info read LICENSE file in the root of this distribution.
