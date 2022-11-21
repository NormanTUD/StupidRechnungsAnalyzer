#!/usr/bin/perl

use strict;
use warnings;
use autodie;
use Data::Dumper;
use List::MoreUtils qw(firstidx);
use Term::ANSIColor;
use Encode;
use Encode::Detect::Detector;
use utf8;

sub debug (@);

my @valide_firmen = (
	"WebServ",
	"Variomedia",
	"Vodafone",
	"Telekom"
);

my @monate = ["januar", "februar", "märz", "april", "mai", "juni", "juli", "august", "september", "oktober", "november", "dezember"];

my %config = (
	debug => 0,
	die_on_error => 0,
	seperator => ";",
	path => "."
);

# https://stackoverflow.com/questions/35800966/checking-whether-a-program-exists
sub check_exists_command {
	debug "check_exists_command ".$_[0];
	my $check = `sh -c 'command -v $_[0]'`;
	return $check;
}

sub error ($) {
	my $arg = shift;
	if($config{die_on_error}) {
		die color("red").$arg.color("reset");
	} else {
		warn color("red").$arg.color("reset")."\n";
	}
}

sub get_nr ($$\%$) {
	my ($str, $re, $rechnung, $name) = @_;

	if($str =~ m#$re#i) {
		my $val = $1;
		$val =~ s#,#.#g;
		$val += 0;
		$rechnung->{$name} = sprintf "%.2f", $val;
	} else {
		error "Konnte keine $name ermitteln";
	}
}

sub debug (@) {
	return unless $config{debug};

	foreach (@_) {
		warn "DEBUG: $_\n";
	}
}

sub _help ($) {
	print <<EOF;
Rechnungsanalysierer für Jörg

Parameter:
--seperator=;					What the CSV should be seperated by
--path=/absolute/or/relative/path		Path where PDFs lie
--debug						Aktiviert Debug-Outputs
--die_on_error					Stirbt bei jedem Fehler sofort
--help						Diese Hilfe
EOF
	exit shift;
}

sub analyze_args {
	foreach (@_) {
		if(/^--debug$/) {
			$config{debug} = 1;
		} elsif (/^--help$/) {
			_help 0;
		} elsif (/^--die_on_error$/) {
			$config{die_on_error} = 1;
		} elsif (/^--seperator=(.*)$/) {
			$config{seperator} = $1;
		} elsif (/^--path=(.*)$/) {
			$config{path} = $1;
		} else {
			warn "Unknown parameter: $_\n";
			_help 1;
		}
	}

	if(!-d $config{path}) {
		die "--path=$config{path} does not exist.";
	}
}

analyze_args(@ARGV);

sub check_installed_software () {
	check_exists_command 'pdftotext' or die "$0 requires pdftotext";
}

sub get_simple_datum {
	my $file = shift;
	my $str = shift;

	if($str =~ m#Datum:?\s+(?<tag>\d+)\s*\.\s*(?<monat>\d+)\s*\.\s*(?<jahr>\d{4})#i) {
		return join(".", $+{tag}, $+{monat}, $+{jahr});
	} else {
		error "Konnte aus der $file kein Datum extrahieren (A)";
	}
}

sub pdftotext ($) {
	my $fn = shift;
	my $command = "pdftotext -layout $fn -";

	my @lines = grep { $_ !~ /^\s*$/ } map { chomp; $_ } qx($command);

	return @lines;
}

sub parse_rechnung ($) {
	my $file = shift;
	if(!-e $file) {
		error "Cannot find $file";
		return;
	}

	debug "parse_rechnung $file";

	my @contents = pdftotext $file;

	my $str = join("\n", @contents);

	my $encoding_name = Encode::Detect::Detector::detect($str);

	$str = decode($encoding_name, $str);

	my $parser_routine = undef;
	my $re = "((?:".join(")|(?:", @valide_firmen)."))";
	if($str =~ /$re/) {
		$parser_routine = $1;
	}

	my $string_without_newlines = $str;
	$string_without_newlines =~ s#\R# #g;



	my %rechnung = (
		filename => $file =~ s#.*/##gr,
		firma => undef,
		datum => undef,
		summe => undef,
		mwst_satz => undef,
		rechnungsnummer => undef
	);

	if(!defined($parser_routine)) {
		error "Cannot parse $file because no parser routine could be found";
		return \%rechnung;
	}

	$rechnung{firma} = $parser_routine;
	if(!$parser_routine) {
		error "Cannot find parser routine for $file";
	} elsif($parser_routine eq "WebServ") {
		$rechnung{datum} = get_simple_datum($file, $str);
		if($string_without_newlines =~ m#Rechnung\s*Nr\.\s*(\d+)#) {
			$rechnung{rechnungsnummer} = $1;
		}
		get_nr $str, qr#zzgl\.\s*(\d+(?:\,\d+)?)\s*%#, %rechnung, "mwst_satz";
		get_nr $str, qr#Gesamtbetrag\s*(\d+(?:,\d+)?)#, %rechnung, "summe";
	} elsif ($parser_routine eq "Variomedia") {
		$rechnung{datum} = get_simple_datum($file, $str);
		if($string_without_newlines =~ m#Belegnummer:\s*([\d-]+)\s+#) {
			$rechnung{rechnungsnummer} = $1;
		}
		get_nr $str, qr#zzgl\.\s*MwSt\s*(\d+(?:,\d+)?)\s*%:#, %rechnung, "mwst_satz";
		get_nr $str, qr#Endbetrag:\s*€\s*(\d+(?:,\d+)?)#, %rechnung, "summe";
	} elsif ($parser_routine eq "Telekom") {
		$rechnung{datum} = get_simple_datum($file, $str);

		if($string_without_newlines =~ m#Rechnungsnummer:?\s*([\d\s*]+\s*?)\s*\w#) {
			$rechnung{rechnungsnummer} = $1;
			$rechnung{rechnungsnummer} =~ s#\s##g;
		}

		get_nr $str, qr#Rechnungsbetrag\s+(\d+(?:,\d+)?)#, %rechnung, "summe";
		get_nr $str, qr#Umsatzsteuer\s*(\d+(?:,\d+)?)\s*%#, %rechnung, "mwst_satz";
	} elsif ($parser_routine eq "Vodafone") {
		if($string_without_newlines !~ m#^\s*Vodafone#) { # Vodafone Mobil
			$rechnung{firma} = "Vodafone-Mobil";
			if($str =~ m#den Zeitraum\s*vom\s*(\d+\.\d+.\d+)\s*bis\s*(\d+\.\d+.\d+)#) {
				$rechnung{datum} = $2;				# Hier 1 wählen, wenn das Startdatum des Vertrages gewählt werden soll
			} else {
				error "Konnte aus der $file kein Datum extrahieren (D)";
			}

			if($string_without_newlines =~ m#Rechnungsnummer\s*Kundennummer\s*Seite Ihre Vodafone-Rechnung\s*(\d+)#) {
				$rechnung{rechnungsnummer} = $1;
			}
			get_nr $str, qr#(\d+(?:,\d+)?)\s*%#, %rechnung, "mwst_satz";
			get_nr $string_without_newlines, qr#Zu\s*zahlender\s*Rechnungsbetrag\s*(\d+(?:,\d+)?)\s*€#, %rechnung, "summe";
		} else { # Vodafone Kabel
			$rechnung{firma} = "Vodafone-Kabel";

			if($string_without_newlines =~ m#Rechnungsnummer:?\s*(\d+)#) {
				$rechnung{rechnungsnummer} = $1;
			}

			# Son Blödsinn! Das Datum als Monat reinschreiben statt als Zahl >_<
			my $datum_re = qr#Datum:?\s*(\d+\.\s*\w+\s*\d+)#;

			if($str =~ m#$datum_re#i) {
				my $res = lc $1;
				my ($tag, $monat, $monat_name, $jahr) = (undef, undef, undef, undef);
				if($res =~ m#(\d+)\.\s*(\w+)\s*(\d+)#) {
					($tag, $monat_name, $jahr) = ($1, $2, $3);
				}

				if($monat_name =~ m#m# && $monat_name =~ m#rz#) {
					$monat = 3;
				} else {
					if($monat_name) {
						$monat = firstidx { $_ =~ /$monat_name/ } @monate;
						$monat++;
					} else {
						error "Konnte aus der $file keinen Monat extrahieren";
					}
				}

				$rechnung{datum} = "$tag.$monat.$jahr";
			}

			if(!defined($rechnung{datum})) {
				error "Konnte aus der $file kein Datum extrahieren (E)";
			}

			get_nr $str, qr#MwSt\.\s*\((\d+(?:,\d+)?)%#, %rechnung, "mwst_satz";
			get_nr $str, qr#Summe:\s*\d+,\d+\s*(\d+(?:,\d+))#, %rechnung, "summe";
		}
	} else {
		error "Invalid parser routine $parser_routine";
	}

	debug Dumper \%rechnung;

	my @missing = ();
	foreach (keys %rechnung) {
		if(!defined($rechnung{$_})) {
			push @missing, $_;
		}
	}

	if (@missing) {
		error "Missing values for ".($file =~ s#.*/##gr).": ".join(", ", @missing);
	}

	return \%rechnung;
}

sub main {
	debug "main";

	check_installed_software;

	my @rechnungen = ();
	while (my $file = <$config{path}/*.pdf>) {
		push @rechnungen, parse_rechnung $file;
	}

	my @keys = qw/filename rechnungsnummer firma datum summe mwst_satz/;

	$\ = "\n";
	print join($config{seperator}, @keys);
	foreach my $this_rechnung (@rechnungen) {
		print join($config{seperator}, map { /^\d+\.\d+$/ && s#\.#,#g; $_ } map { $_ = "" unless defined $_; $_ } map { $this_rechnung->{$_} } @keys);
	}
}

main();
