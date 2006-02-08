package XMLTV::ValidateGrabber;

use strict;

BEGIN {
    use Exporter   ();
    our (@ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
    
    @ISA         = qw(Exporter);
    @EXPORT      = qw( );
    %EXPORT_TAGS = ( );     # eg: TAG => [ qw!name1 name2! ],
    @EXPORT_OK   = qw/ConfigureGrabber ValidateGrabber/;
}
our @EXPORT_OK;

my $CMD_TIMEOUT = 600;

=head1 NAME

XMLTV::ValidateGrabber

=head1 DESCRIPTION

Utility library that validates that a grabber properly implements the
capabilities described at

http://membled.com/twiki/bin/view/Main/XmltvCapabilities

The ValidateGrabber call first asks the grabber which capabilities it
claims to support and then validates that it actually does support
these capabilities.

=head1 EXPORTED FUNCTIONS

All these functions are exported on demand.

=over 4

=cut

use XMLTV::ValidateFile qw/ValidateFile/;

use File::Slurp qw/read_file/;
use List::Util qw(min);

# Parameters to call grabbers with.
my $offset=1;
my $days=2;

my $runfh;

sub w;
sub run;
sub run_capture;

=item ConfigureGrabber

    ConfigureGrabber( "./tv_grab_new", "./tv_grab_new.conf" )

=cut

sub ConfigureGrabber {
    my( $exe, $conf ) = @_;

    if ( run( "$exe --configure --config-file $conf" ) ) {
	w "Error returned from grabber during configure.";
	return 1;
    }
    
    return 1;
}

=item ValidateGrabber

Run the validation for a grabber.

    ValidateGrabber( "tv_grab_new", "./tv_grab_new", "./tv_grab_new.conf", 
		     "/tmp/new_", "./blib/share", 0 )

ValidateGrabber takes the following parameters:

=over

=item *

a short name for the grabber. This is only used when printing error messages.

=item *

the command to run the grabber.

=item *

the name of a configuration-file for the grabber.

=item *

a file-prefix that is added to all output-files.

=item *

a path to a directory with metadata for the grabber. This path
is passed to the grabber via the --share option if the grabber
supports the capability 'share'. undef if no --share parameter shall
be used.

=item *

a boolean specifying if the --cache parameter shall be used for grabbers
that support the 'cache' capability.

=back

ValidateGrabber returns a list of errors that it found with the grabber. Each
error takes the form of a keyword:  

=over

=item noparamcheck

The grabber accepts any parameter without returning an error-code.

=item noversion

The grabber returns an error when run with --version.

=item nodescription

The grabber returns an error when run with --description.

=item nocapabilities

The grabber returns an error when run with --capabilities.

=item nobaseline

The grabber does not list 'baseline' as one of its supported capabilities.

=item nomanualconfig

The grabber does not list 'manualconfig' as one of its supported capabilities.

=item noconfigurationfile

The specified configuration-file does not exist.

=item graberror

The grabber returned with an error-code when asked to grab data.
 
=item notquiet

The grabber printed something to STDERR even though the --quiet option 
was used.

=item outputdiffers

The grabber produced different output when called with different combinations
of --output and --quiet.

=item caterror

tv_cat returned an error-code when we asked it to process the output from
the grabber.

=item sorterror

tv_sort returned an error-code when we asked it to process the output from
the grabber.

=item overlap

tv_sort found overlapping programmes in the data generated by the grabber.

=back

Additionally, the list of errors will contain error keywords from 
XMLTV::ValidateFile if the xmltv-file generated by the grabber was not
valid. 

If no errors are found, an empty list is returned.

=cut

sub ValidateGrabber {
    my( $shortname, $exe, $conf, $op, $sharedir, $usecache ) = @_;

    my @errors;
    open( $runfh, ">${op}commands.log" )
	or die "Failed to write to ${op}commands.log";

    if (not run( "$exe --ahdmegkeja > /dev/null 2>&1" )) {
      w "$shortname with --ahdmegkeja did not fail. The grabber seems to "
	  . "accept any command-line parameter without returning an error.";
      push @errors, "noparamcheck";
    }

    if (run( "$exe --version > /dev/null 2>&1" )) {
      w "$shortname with --version failed: $?, $!";
      push @errors, "noversion";
    }

    if (run( "$exe --description > /dev/null 2>&1" )) {
      w "$shortname with --description failed: $?, $!";
      push @errors, "nodescription";
    }

    my $cap = run_capture( "$exe --capabilities 2>/dev/null" );
    if (not defined $cap) {
      w "$shortname with --capabilities failed: $?, $!";
      push @errors, "nocapabilities";
    }

    my @capabilities = split( /\s+/, $cap );
    my %capability;
    foreach my $c (@capabilities) {
	$capability{$c} = 1;
    }

    if (not defined( $capability{baseline} )) {
	w "The grabber does not claim to support the 'baseline' capability.";
	push @errors, "nobaseline";
    }

    if (not defined( $capability{manualconfig} )) {
	w "The grabber does not claim to support the 'manualconfig' capability.";
	push @errors, "nomanualconfig";
    }

    my $extraop = "";
    $extraop .= "--cache  ${op}cache " 
	if $capability{cache} and $usecache;
    $extraop .= "--share $sharedir "
	if $capability{share} and defined( $sharedir );

    if (not -f $conf) {
	w "Configuration file $conf does not exist. Aborting.";
	close( $runfh );
	push @errors, "noconfigurationfile";
	goto bailout;
    }

    # Should we test for --list-channels?

    my $cmd = "$exe --config-file $conf --offset $offset --days $days " .
	"$extraop";

    my $output = "${op}${offset}_$days.xml";

    if (run "$cmd > $output 2>${op}1.log") {
	w "$cmd failed: $?, $!";
	push @errors, "graberror";
    }
    else {
	# Okay, it ran, and we have the result in $output.  Validate.
	my @xmlerr = ValidateFile( $output, $offset, $days );
	if (scalar(@xmlerr) > 0) {
	    w "Errors found in $output";
	    close( $runfh );
	    push @errors, @xmlerr;
	    goto bailout;
	}
	w "$output validates ok";
	
	# Run through tv_cat, which makes sure the data looks like XMLTV.
	# What kind of errors does this catch that ValidateFile misses?
	if (run "tv_cat $output >/dev/null") {
	    w "$output makes tv_cat choke, so probably has semantic errors";
	    push @errors, "caterror";
	    goto bailout;
	}
	
	# Do tv_sort sanity checks.  One day it would be better to put
	# this stuff in a Perl library.
	my $sort_errors = "$output.sort_errors";
	if (run "tv_sort $output >$output.sorted 2>$sort_errors") {
	    # This would indicate a bug in tv_sort.
	    w "tv_sort failed on $output for some reason, " 
		. "see $sort_errors";
	    push @errors, "sorterror";
	}
	
	if (my @lines = read_file $sort_errors) {
	    w "$output has funny start or stop times: some errors are:\n"
		. join('', @lines[0 .. min(9, $#lines)]);
	    push @errors, "overlap";
	}
    }

    # Run the same command again to see that --output and --quiet works.
    my $cmd2 = "$cmd --output ${output}2 2>${op}2.log";
    
    if (run $cmd2) {
	w "$shortname with --output failed: $?, $!";
	push @errors, "graberror";
    }
    else {
	if ( ! compare_files( $output, "${output}2" ) ) {
	    w "$output and ${output}2 differ.";
	    push @errors, "outputdiffers";
	}
	else {
	    unlink( "${output}2" );
	}
    }
    
    my $cmd3 = "$cmd --quiet > ${output}3 2>${op}3.log";

    if (run $cmd3 ) {
	w "$shortname with --quiet failed: $?, $!";
	push @errors, "graberror";
    }
    else {
	if ( -s "${op}3.log" ) {
	    w "$shortname with --quiet produced output to STDERR when it shouldn't have. " 
		. "See ${op}3.log";
	    push @errors, "notquiet";
	}
	else {
	    unlink( "${op}3.log" );
	}
	
	if ( ! compare_files( $output, "${output}3" ) ) {
	    w "$output and ${output}3 differ.";
	    push @errors, "outputdiffers";
	}
	else {
	    unlink( "${output}3" );
	}
    }
    
    my $cmd4 = "$cmd --quiet --output ${output}4 2>${op}4.log";

    if (run $cmd4 ) {
	w "$shortname with --quiet and --output failed: $?, $!";
	push @errors, "graberror";
    }
    else {
	if ( -s "${op}4.log" ) {
	    w "$shortname with --quiet and --output produced output to STDERR " .
		"when it shouldn't have. See ${op}4.log";
	    push @errors, "notquiet";
	}
	else {
	    unlink( "${op}4.log" );
	}
	
	if ( ! compare_files( $output, "${output}4" ) ) {
	    w "$output and ${output}4 differ.";
	    push @errors, "outputdiffers";
	}
	else {
	    unlink( "${output}4" );
	}
    }

  bailout:
    close( $runfh );
    $runfh = undef;

    # Remove duplicate entries.
    my $lasterror = "nosucherror";
    my @ferrors;
    foreach my $err (@errors) {
	push( @ferrors, $err ) if $err ne $lasterror;
	$lasterror = $err;
    }

    if (scalar( @ferrors )) {
	w "$shortname did not validate ok. See ${op}commands.log for a " 
	    . "list of the commands that were used";
    }
    else {
	w "$shortname validated ok.";
    }

    return @ferrors;
}

sub w {
    print "$_[0]\n";
}

# Run an external command. Exit if the command is interrupted with ctrl-c.
sub run {
    my( $cmd ) = @_;

    print $runfh "$cmd\n"
	if defined $runfh;

    my $killed = 0;

    # Set a timer and run the real command.
    eval {
	local $SIG{ALRM} =
            sub {
		# ignore SIGHUP here so the kill only affects children.
		local $SIG{HUP} = 'IGNORE';
		kill 1,(-$$);
		$killed = 1;
	    };
	alarm $CMD_TIMEOUT;
	system ( $cmd );
	alarm 0;
    };
    $SIG{HUP} = 'DEFAULT';    

    if ($killed) {
	w "Timeout";
	return 1;
    }

    if ($? == -1) {
	w "Failed to execute $cmd: $!";
	return 1;
    }
    elsif ($? & 127) {
	w "Terminated by signal " . ($? & 127);
	exit 1;
    }

    return $? >> 8;
}

# Run an external command and return the output. Exit if the command is 
# interrupted with ctrl-c.
sub run_capture {
    my( $cmd ) = @_;

#    print "Running $cmd\n";

    my $killed = 0;
    my $result;

    # Set a timer and run the real command.
    eval {
	local $SIG{ALRM} =
            sub {
		# ignore SIGHUP here so the kill only affects children.
		local $SIG{HUP} = 'IGNORE';
		kill 1,(-$$);
		$killed = 1;
	    };
	alarm $CMD_TIMEOUT;
	$result = qx/$cmd/;
	alarm 0;
    };
    $SIG{HUP} = 'DEFAULT';    

    if ($killed) {
	w "Timeout";
	return undef;
    }

    if ($? == -1) {
	w "Failed to execute $cmd: $!";
	return undef;
    }
    elsif ($? & 127) {
	w "Terminated by signal " . ($? & 127);
	exit 1;
    }

    if ($? >> 8) {
	return undef;
    }
    else {
	return $result;
    }
}

# Compare two files. Return true if they have the same contents.
sub compare_files {
    my( $file1, $file2 ) = @_;

    run("diff $file1 $file2 > /dev/null");
    return $? ? 0 : 1;
}

1;


=back 
   
=head1 COPYRIGHT

Copyright (C) 2006 Mattias Holmlund.

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

=cut

### Setup indentation in Emacs
## Local Variables:
## perl-indent-level: 4
## perl-continued-statement-offset: 4
## perl-continued-brace-offset: 0
## perl-brace-offset: -4
## perl-brace-imaginary-offset: 0
## perl-label-offset: -2
## cperl-indent-level: 4
## cperl-brace-offset: 0
## cperl-continued-brace-offset: 0
## cperl-label-offset: -2
## cperl-extra-newline-before-brace: t
## cperl-merge-trailing-else: nil
## cperl-continued-statement-offset: 2
## indent-tabs-mode: t
## End:
