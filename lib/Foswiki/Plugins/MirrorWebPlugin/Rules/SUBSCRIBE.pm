# See bottom of file for license and copyright information

package Foswiki::Plugins::MirrorWebPlugin::Rules::SUBSCRIBE;

use strict;

use Foswiki::Contrib::MailerContrib;

sub execute {
    my ( $topicObject, $mirrorObject, $data ) = @_;

    # Use the MailerContrib to subscribe listed users to changes
    my @who = split( /[\s,]+/, $data->{value} );
    foreach my $name (@who) {
        Foswiki::Contrib::MailerContrib::changeSubscription(
            $mirrorObject->web(), $name, $mirrorObject->topic() );
    }
    return $data;
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
