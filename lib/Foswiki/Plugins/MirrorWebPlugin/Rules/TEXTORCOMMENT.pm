# See bottom of file for license and copyright information

package Foswiki::Plugins::MirrorWebPlugin::Rules::TEXTORCOMMENT;

use strict;

# If there is existing text in the mirror topic, retain it. Otherwise
# add %COMMENT%.
# The text from the topicObject is discarded.
sub execute {
    my ( $topicObject, $mirrorObject, $data ) = @_;
    return $mirrorObject->text() || '%COMMENT%';
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
