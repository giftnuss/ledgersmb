
=head1 NAME

LedgerSMB::Template - Template support module for LedgerSMB 

=head1 SYNOPSIS

This module renders templates.

=head1 METHODS

=over

=item new(user => \%myconfig, template => $string, format => $string, [locale => $locale] [language => $string], [include_path => $path], [no_auto_output => $bool], [method => $string], [no_escape => $bool], [debug => $bool], [output_file => $string] );

This command instantiates a new template:

=over

=item template

The template to be processed.  This can either be a reference to the template
in string form or the name of the file that is the template to be processed.

=item format

The format to be used.  Currently HTML, PS, PDF, TXT and CSV are supported.

=item format_options (optional)

A hash of format-specific options.  See the appropriate LSMB::T::foo for
details.

=item output_options (optional)

A hash of output-specific options.  See the appropriate output method for
details.

=item locale (optional)

The locale object to use for regular gettext lookups.  Having this option adds
the text function to the usable list for the templates.  Has no effect on the
gettext function.

=item language (optional)

The language for template selection.

=item include_path (optional)

Overrides the template directory.  Used with user interface templates.

=item no_auto_output (optional)

Disables the automatic output of rendered templates.

=item no_escape (optional)

Disables escaping on the template variables.

=item debug (optional)

Enables template debugging.

With the TT-based renderers, HTML, PS, PDF, TXT, and CSV, the portion of the
template to get debugging messages is to be surrounded by
<?lsmb DEBUG format 'foo' ?> statements.  Example:

    <tr><td colspan="<?lsmb columns.size ?>"></td></tr>
    <tr class="listheading">
  <?lsmb FOREACH column IN columns ?>
  <?lsmb DEBUG format '$file line $line : [% $text %]' ?>
      <th class="listtop"><?lsmb heading.$column ?></th>
  <?lsmb DEBUG format '' ?>
  <?lsmb END ?>
    </tr>

=item method/media (optional)

The output method to use, defaults to HTTP.  Media is a synonym for method

=item output_file (optional)

The base name of the file for output.

=back

=item new_UI(user => \%myconfig, locale => $locale, template => $file, ...)

Wrapper around the constructor that sets the path to 'UI', format to 'HTML',
and leaves auto-output enabled.

=item render($hashref)

This command renders the template.  If no_auto_output was not specified during
instantiation, this also writes the result to standard output and exits.
Otherwise it returns the name of the output file if a file was created.  When
no output file is created, the output is held in $self->{output}.

Currently email and server-side printing are not supported.

=item output

This function outputs the rendered file in an appropriate manner.

=item my $bool = _valid_language()

This command checks for valid langages.  Returns 1 if the language is valid, 
0 if it is not.

=item column_heading() 

Apply locale settings to column headings and add sort urls if necessary.

=item escape($string)

Escapes a scalar string if the format supports such escaping and returns the
sanitized version.

=back

=head1 Copyright 2007, The LedgerSMB Core Team

This file is licensed under the GNU General Public License version 2, or at your
option any later version.  A copy of the license should have been included with
your software.

=cut

package LedgerSMB::Template;

use warnings;
use strict;
use Carp;

use Error qw(:try);
use LedgerSMB::CancelFurtherProcessing;
use LedgerSMB::Sysconfig;
use LedgerSMB::Mailer;
use LedgerSMB::Company_Config;
use LedgerSMB::Locale;

my $logger = Log::Log4perl->get_logger('LedgerSMB::Template');

sub new {
	my $class = shift;
	my $self = {};
	my %args = @_;

	$self->{myconfig} = $args{user};
	$self->{template} = $args{template};
	$self->{format} = $args{format};
	$self->{language} = $args{language};
	$self->{no_escape} = $args{no_escape};
	$self->{debug} = $args{debug};
        $self->{binmode} = undef;
	$self->{outputfile} =
		"${LedgerSMB::Sysconfig::tempdir}/$args{output_file}" if
		$args{output_file};
	$self->{include_path} = $args{path};
	$self->{locale} = $args{locale};
	$self->{noauto} = $args{no_auto_output};
	$self->{method} = $args{method};
	$self->{method} ||= $args{media};
	$self->{format_args} = $args{format_options};
	$self->{output_args} = $args{output_options};
        if ($self->{language}){ # Language takes precedence over locale
             $self->{locale} = LedgerSMB::Locale->get_handle($self->{language});
        }

	# SC: Muxing pre-format_args LaTeX format specifications.  Now with
	#     DVI support.
	if (lc $self->{format} eq 'dvi') {
		$self->{format} = 'LaTeX';
		$self->{format_args}{filetype} = 'dvi';
	} elsif (lc $self->{format} eq 'pdf') {
		$self->{format} = 'LaTeX';
		$self->{format_args}{filetype} = 'pdf';
	} elsif (lc $self->{format} eq 'ps' or lc $self->{format} eq 'postscript') {
		$self->{format} = 'LaTeX';
		$self->{format_args}{filetype} = 'ps';
	}	
	bless $self, $class;

	if ($self->{format} !~ /^\p{IsAlnum}+$/) {
		throw Error::Simple "Invalid format";
	}
	if (!$self->{include_path}){
		$self->{include_path} = $self->{'myconfig'}->{'templates'};
		$self->{include_path} ||= 'templates/demo';
		if (defined $self->{language}){
			if (!$self->_valid_language){
				throw Error::Simple 'Invalid language';
				return undef;
			}
			$self->{include_path_lang} = "$self->{'include_path'}"
					."/$self->{language}";
                        $self->{locale} 
                             = LedgerSMB::Locale->get_handle($self->{language});
		}
	}

	return $self;
}

sub new_UI {
	my $class = shift;
	return $class->new(@_, no_auto_ouput => 0, format => 'HTML', path => 'UI');
}

sub _valid_language {
	my $self = shift;
	if ($self->{language} =~ m#(/|\\|:|\.\.|^\.)#){
		return 0;
	}
	return 1;
}

sub _preprocess {
	my ($self, $vars) = @_;
	return unless $self->{myconfig};
	use LedgerSMB;
	my $type = ref($vars);

	if ($type eq 'SCALAR' || !$type){
		return;
	}
	if ($type eq 'ARRAY'){
		for (@$vars){
			if (ref($_)){
				$self->_preprocess($_);
			}
		}
	}
	else {
		for my $key (keys %$vars){
			$self->_preprocess($vars->{$key});
		}
	}
}

sub render {
	my $self = shift;
	my $vars = shift;
	if ($self->{format} !~ /^\p{IsAlnum}+$/) {
		throw Error::Simple "Invalid format";
	}
	my $format = "LedgerSMB::Template::$self->{format}";

#	if ($self->{myconfig}){
#	        $self->_preprocess($vars);
#	}
	eval "require $format";
	if ($@) {
		throw Error::Simple $@;
	}

	my $cleanvars;
	if ($self->{no_escape}) {
		carp 'no_escape mode enabled in rendering';
		$cleanvars = $vars;
	} else {
		$cleanvars = $format->can('preprocess')->($vars);
	}
        $cleanvars->{escape} = sub { return $format->escape(@_)};
	if (UNIVERSAL::isa($self->{locale}, 'LedgerSMB::Locale')){
		$cleanvars->{text} = sub { return $self->escape($self->{locale}->text(@_))};
	} 
	else {
            $cleanvars->{text} = sub { return $self->escape(shift @_) };
	
        }
        $cleanvars->{tt_url} = sub {
               my $str  = shift @_;

               my $regex = qr/([^a-zA-Z0-9_.-])/;
               $str =~ s/$regex/sprintf("%%%02x", ord($1))/ge;
               return $str;
        };

	$format->can('process')->($self, $cleanvars);
	#return $format->can('postprocess')->($self);
	my $post = $format->can('postprocess')->($self);
        #$logger->debug("\$format=$format \$self->{'noauto'}=$self->{'noauto'} \$self->{rendered}=$self->{rendered}");
	if (!$self->{'noauto'}) {
		# Clean up
                $logger->debug("before self output");
		$self->output(%$vars);
                $logger->debug("after self output,but does not seem to return here!");
		if ($self->{rendered}) {
			unlink($self->{rendered}) or
				throw Error::Simple 'Unable to delete output file';
		}
	}
	return $post;
}

sub escape {
    my ($self, $vars) = @_;
    my $format = "LedgerSMB::Template::$self->{format}";
    return $format->can('escape')->($vars) || $vars;
} 

sub output {
	my $self = shift;
	my %args = @_;

        for ( keys %args ) { $self->{output_args}->{$_} = $args{$_}; };

	my $method = $self->{method} || $args{method} || $args{media};
        $method = '' if !defined $method;
	if ('email' eq lc $method) {
		$self->_email_output;
	} elsif ('print' eq lc $method) {
		$self->_lpr_output;
	} elsif (defined $self->{output} or lc $method eq 'screen') {
		$self->_http_output;
		throw CancelFurtherProcessing();
	} elsif (defined $method) {
		$self->_lpr_output;
	} else {
		$self->_http_output_file;
	}
}

sub _http_output {
	my ($self, $data) = @_;
	$data ||= $self->{output};
	if ($self->{format} !~ /^\p{IsAlnum}+$/) {
		throw Error::Simple "Invalid format";
	}

	if (!defined $data and defined $self->{rendered}){
		$data = "";
                $logger->trace("begin DATA < self->{rendered}=$self->{rendered} \$self->{format}=$self->{format}");
		open (DATA, '<', $self->{rendered});
                binmode DATA, $self->{binmode};
		while (my $line = <DATA>){
			$data .= $line;
		}
                $logger->trace("end DATA < self->{rendered}");
	        unlink($self->{rendered}) or throw Error::Simple 'Unable to delete output file';
	}

	my $format = "LedgerSMB::Template::$self->{format}";
	my $disposition = "";
	my $name = $format->can('postprocess')->($self);

	if ($name) {
		$name =~ s#^.*/##;
		$disposition .= qq|\nContent-Disposition: attachment; filename="$name"|;
	}
        if (!$ENV{LSMB_NOHEAD}){
 	    if ($self->{mimetype} =~ /^text/) {
		print "Content-Type: $self->{mimetype}; charset=utf-8$disposition\n\n";
	    } else {
		print "Content-Type: $self->{mimetype}$disposition\n\n";
	    }
        }
	binmode STDOUT, $self->{binmode};
	print $data;
        $logger->trace("end print to STDOUT");
}

sub _http_output_file {
	my $self = shift;
	my $FH;

	open($FH, '<:bytes', $self->{rendered}) or
		throw Error::Simple 'Unable to open rendered file';
	my $data;
	{
		local $/;
		$data = <$FH>;
	}
	close($FH);
	
	$self->_http_output($data);
	
	unlink($self->{rendered}) or
		throw Error::Simple 'Unable to delete output file';
	throw CancelFurtherProcessing();
}

sub _email_output {
	my $self = shift;
	my $args = $self->{output_args};

	my @mailmime;
	if (!$self->{rendered} and !$args->{attach}) {
		$args->{message} .= $self->{output};
		@mailmime = ('contenttype', $self->{mimetype});
	}

        # User default for email from
        $args->{from} ||= $self->{user}->{email};

        # Default addresses
        my $csettings = $LedgerSMB::Company_Config::settings;
        $args->{from} ||= $csettings->{default_email_from};
        $args->{to} ||= $csettings->{default_email_to};
        $args->{cc} ||= $csettings->{default_email_cc};
        $args->{bcc} ||= $csettings->{default_email_bcc};


        # Mailer stuff
	my $mail = new LedgerSMB::Mailer(
		from => $args->{from},
		to => $args->{to},
		cc => $args->{cc},
		bcc => $args->{bcc},
		subject => $args->{subject},
		notify => $args->{notify},
		message => $args->{message},
		@mailmime,
	);
	if ($args->{attach} or $self->{mimetype} !~ m#^text/# or $self->{rendered}) {
		my @attachment;
		my $name = $args->{filename};
		if ($self->{rendered}) {
			@attachment = ('file', $self->{rendered});
			$name ||= $self->{rendered};
		} else {
			@attachment = ('data', $self->{output});
		}
		$mail->attach(
			mimetype => $self->{mimetype},
			filename => $name,
			strip => $$,
			@attachment,
			);
	}
	$mail->send;
}

sub _lpr_output {
	my ($self, $in_args) = shift;
	my $args = $self->{output_args};
	if ($self->{format} ne 'LaTeX') {
		throw Error::Simple "Invalid Format";
	}
	my $lpr = $LedgerSMB::Sysconfig::printer{$args->{media}};

	open (LPR, '|-', $lpr);

	# Output is not defined here.  In the future we should consider
	# changing this to use the system command and hit the file as an arg.
	#  -- CT
	open (FILE, '<', "$self->{rendered}");
	while (my $line = <FILE>){
		print LPR $line;
	}
	close(LPR);
}

# apply locale settings to column headings and add sort urls if necessary.
sub column_heading {
	
	my $self = shift;
	my ($names, $sortby) = @_; 
	my %sorturls;
	
	if ($sortby) {
		%sorturls = map 
		{ $_ => $sortby->{href}."=$_"} @{$sortby->{columns}};
	}
		
	foreach my $attname (keys %$names) {
		
		# process 2 cases - simple name => value, and complex name => hash
		# pairs. The latter is used to include urls in column headers.
		
		if (ref $names->{$attname} eq 'HASH') {
			my $t = $self->{locale}->text($names->{$attname}{text});
			$names->{$attname}{text} = $t;
		} else {
			my $t = $self->{locale}->text($names->{$attname});
			if (defined $sorturls{$attname}) {
				$names->{$attname} = 
				{
					text => $t,
				 	href => $sorturls{$attname} 
				};
			} else {
				$names->{$attname} = $t;
			}
		}
	}
	
	return $names;
}

1;
