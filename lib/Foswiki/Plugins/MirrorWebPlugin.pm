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
our $RELEASE = '1.1.1';
our $SHORTDESCRIPTION =
  'Mirror a web to another, with filtering on the topic text and fields.';
our $NO_PREFS_IN_TOPIC = 1;
our %RULES;

sub initPlugin {
    my ( $topic, $web, $user, $installWeb ) = @_;

    Foswiki::Func::registerTagHandler( 'UPDATEMIRROR', \&_UPDATEMIRROR );
    Foswiki::Func::registerRESTHandler( 'update', \&_restUPDATEMIRROR );

    return 1;
}

sub _loadRules {
    my ( $rules, $tom ) = @_;

    my ( $web, $topic ) =
      Foswiki::Func::normalizeWebTopicName( $tom->web(), $rules );
    my $key = "$web.$topic";
    if ( !$RULES{$key} ) {
        ASSERT( Foswiki::Func::topicExists( $web, $topic ) ) if DEBUG;
        my ( $meta, $text ) = Foswiki::Func::readTopic( $web, $topic );

        # Implicit untaint
        if ( $text =~ /<verbatim>([][\s\w=>{}()',]+)<\/verbatim>/s ) {
            my $clean = $1;
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

sub _synch {
    my ( $topicObject, $mirrorWeb, $response ) = @_;

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
    }
    unless ($rules) {
        $rules = $ruleset->{'other'};
        return 0 unless $rules;
    }

    foreach my $field ( keys %$rules ) {
        if ( $field eq 'text' ) {
            my $data = $topicObject->text();
            $data =
              _applyFilters( $rules->{text}, $topicObject, $mirrorObject,
                $data );
            $mirrorObject->text($data) if defined $data;
        }
        else {
            $mirrorObject->remove($field);   # clear old fields
                                             # Support for all other keyed types
            foreach my $name ( keys %{ $rules->{$field} } ) {
                my $data = $topicObject->get( $field, $name );
                $data = _applyFilters( $rules->{$field}->{$name},
                    $topicObject, $mirrorObject, $data );
                $mirrorObject->putKeyed( $field, $data ) if ref($data);
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
        if ( $f =~ s/\((.*)\)$// ) {
            @params = split( ',', $1 );
        }
        my $filter = 'Foswiki::Plugins::MirrorWebPlugin::Rules::' . $f;
        eval 'require ' . $filter;
        die $@ if $@;
        $filter .= '::execute';
        no strict 'refs';
        $data = &$filter( $topicObject, $mirrorObject, $data, @params );
        use strict 'refs';
    }
    return $data;
}

# Handle the mirror, if required
sub afterSaveHandler {
    my ( $text, $topic, $web, $error, $meta ) = @_;

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
    $html .= CGI::submit( -name => 'Update mirror' );
    $html .= CGI::end_form();
    return $html;
}

sub _restUPDATEMIRROR {
    my ( $session, $plugin, $verb, $response ) = @_;

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
        $response->header(
            -status => 400,
            -type   => 'text/plain',
        );
        $response->print("Access denied");
    }

    $response->header(
        -status => 200,
        -type   => 'text/plain',
    );

    my $mirrorWeb =
      Foswiki::Func::getPreferencesValue( 'MIRRORWEBPLUGIN_MIRROR', $web );
    unless ( defined $mirrorWeb ) {
        $response->print(<<HERE);
$web does not have MIRRORWEBPLUGIN_MIRROR defined, so nothing to do
HERE
        return undef;
    }

    my @topics = Foswiki::Func::getTopicList($web);
    foreach my $topic (@topics) {
        my ( $meta, $text ) = Foswiki::Func::readTopic( $web, $topic );
        Foswiki::Func::pushTopicContext( $web, $topic );

        # We have to re-read the topic to get the
        # right session in the $meta. This could be done by patching the
        # $meta object, but this should be longer-lasting.
        ( $meta, $text ) = Foswiki::Func::readTopic( $web, $topic );
        if ( _synch( $meta, $mirrorWeb, $response ) ) {
            $response->print("Synched $topic\n");
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
