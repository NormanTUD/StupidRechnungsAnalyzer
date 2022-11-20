#!/usr/bin/perl

use strict;
use warnings;
use autodie;
use Data::Dumper;
use List::MoreUtils qw(firstidx);
use Term::ANSIColor;

sub debug (@);

my @valide_firmen = (
	"WebServ",
	"Variomedia",
	"Vodafone",
	"Telekom"
);

my @monate = qw/januar februar märz april mai juni juli august september oktober november dezember/;

my %config = (
	debug => 0,
	die_on_error => 0
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

sub get_nr ($$\%$$) {
	my $str = shift;
	my $re = shift;
	my $rechnung = shift;
	my $name = shift;
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
		} else {
			warn "Unknown parameter: $_\n";
			_help 1;
		}
	}
}

analyze_args(@ARGV);

sub check_installed_software () {
	check_exists_command 'pdftotext' or die "$0 requires pdftotext";
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

	my $parser_routine = undef;
	my $re = "((?:".join(")|(?:", @valide_firmen)."))";
	if($str =~ /$re/) {
		$parser_routine = $1;
	}

	my $string_without_newlines = $str;
	$string_without_newlines =~ s#\R# #g;

	if(!defined($parser_routine)) {
		error "Cannot parse $file because no parser routine could be found";
	}

	my %rechnung = (
		filename => $file,
		firma => undef,
		datum => undef,
		summe => undef,
		mwst_satz => undef
	);

	if(!$parser_routine) {
		error "Cannot find parser routine for $file";
	} elsif($parser_routine eq "WebServ") {
		$rechnung{firma} = $parser_routine;
		if($str =~ m#Datum:\s+(?<tag>\d+)\s*\.\s*(?<monat>\d+)\s*\.\s*(?<jahr>\d{4})#i) {
			$rechnung{datum} = join(".", $+{tag}, $+{monat}, $+{jahr});
		} else {
			error "Konnte aus der $file kein Datum extrahieren";
		}

		get_nr $str, qr#zzgl\.\s*(\d+(?:\,\d+)?)\s*%#, %rechnung, "mwst_satz", $1;
		get_nr $str, qr#Gesamtbetrag\s*(\d+(?:,\d+)?)#, %rechnung, "summe", $1;
	} elsif ($parser_routine eq "Variomedia") {
		$rechnung{firma} = $parser_routine;
		if($str =~ m#Datum:\s+(?<tag>\d+)\s*\.\s*(?<monat>\d+)\s*\.\s*(?<jahr>\d{4})#i) {
			$rechnung{datum} = join(".", $+{tag}, $+{monat}, $+{jahr});
		} else {
			error "Konnte aus der $file kein Datum extrahieren";
		}

		get_nr $str, qr#zzgl\.\s*MwSt\s*(\d+(?:,\d+)?)\s*%:#, %rechnung, "mwst_satz", $1;
		get_nr $str, qr#Endbetrag:\s*€\s*(\d+(?:,\d+)?)#, %rechnung, "summe", $1;
	} elsif ($parser_routine eq "Telekom") {
		$rechnung{firma} = $parser_routine;

		if($str =~ m#Datum\s*(\d+\.\d+\.\d+)#) {
			$rechnung{datum} = $1;
		} else {
			error "Konnte kein Datum finden in der Datei $file";
		}

		get_nr $str, qr#Rechnungsbetrag\s+(\d+(?:,\d+)?)#, %rechnung, "summe", $1;
		get_nr $str, qr#Umsatzsteuer\s*(\d+(?:,\d+)?)\s*%#, %rechnung, "mwst_satz", $1;
	} elsif ($parser_routine eq "Vodafone") {
		$rechnung{firma} = $parser_routine;
		if($string_without_newlines !~ m#^\s*Vodafone#) { # Vodafone Format 1
			$rechnung{firma} = "Vodafone-Mobil";
			if($str =~ m#den Zeitraum\s*vom\s*(\d+\.\d+.\d+)\s*bis\s*(\d+\.\d+.\d+)#) {
				$rechnung{datum} = $2;				# Hier 1 wählen, wenn das Startdatum des Vertrages gewählt werden soll
			} else {
				error "Konnte aus der $file kein Datum ermitteln";
			}

			get_nr $str, qr#(\d+(?:,\d+)?)\s*%#, %rechnung, "mwst_satz", $1;
			get_nr $string_without_newlines, qr#Zu\s*zahlender\s*Rechnungsbetrag\s*(\d+(?:,\d+)?)\s*€#, %rechnung, "summe", $1;
		} else { # Vodafone Format 2
			$rechnung{firma} = "Vodafone-Kabel";
			get_nr $str, qr#MwSt\.\s*\((\d+(?:,\d+)?)%#, %rechnung, "mwst_satz", $1;
			get_nr $str, qr#Summe:\s*\d+,\d+\s*(\d+(?:,\d+))#, %rechnung, "summe", $1;

			# Son Blödsinn! Das Datum als Monat reinschreiben statt als Zahl >_<
			my $datum_re = "Datum:?\\s*(\\d+\.\\s*\\w+\\s*\\d+)";
			if($str =~ m#$datum_re#i) {
				my $res = lc $1;
				my ($tag, $monat, $monat_name, $jahr) = (undef, undef, undef, undef);
				if($res =~ m#(\d+)\.\s*(\w+)\s*(\d+)#) {
					($tag, $monat_name, $jahr) = ($1, $2, $3);
				}

				if($monat_name) {
					$monat = firstidx { $_ =~ /$monat_name/ } @monate;
					$monat++;
				} else {
					error "Monat name could not be found in $file";
				}

				$rechnung{datum} = "$tag.$monat.$jahr";
			}
			if(!defined($rechnung{datum})) {
				error "Konnte in $file kein datum finden";
			}
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
		error "Missing values for $file: ".join(", ", @missing);
	}

	return \%rechnung;
}

sub main {
	debug "main";

	check_installed_software;

	my @rechnungen = ();
	while (my $file = <*.pdf>) {
		push @rechnungen, parse_rechnung $file;
	}

	my @keys = qw/filename firma datum summe mwst_satz/;

	$\ = "\n";
	print join(";", @keys);
	foreach my $this_rechnung (@rechnungen) {
		print join(";", map { /^\d+\.\d+$/ && s#\.#,#g; $_ } map { $_ = "" unless defined $_; $_ } map { $this_rechnung->{$_} } @keys);
	}
}

main();
