#!/usr/bin/perl

use strict;
use warnings;
use autodie;
use Data::Dumper;
use List::MoreUtils qw(firstidx);

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
		die $arg;
	} else {
		warn "$arg\n";
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
		die "Cannot parse $file because no parser routine could be found\n";
	}

	my %rechnung = (
		filename => $file,
		firma => undef,
		datum => undef,
		summe => undef,
		mwst_satz => undef
	);

	if($parser_routine eq "WebServ") {
		$rechnung{firma} = $parser_routine;
		if($str =~ m#Datum:\s+(?<tag>\d+)\s*\.\s*(?<monat>\d+)\s*\.\s*(?<jahr>\d{4})#i) {
			$rechnung{datum} = join(".", $+{tag}, $+{monat}, $+{jahr});
		} else {
			error "Konnte aus der $file kein Datum extrahieren";
		}

		if($str =~ m#zzgl\.\s*(\d+(?:\,\d+)?)\s*%#i) {
			my $satz = $1;
			$satz =~ s#,#.#g;
			$satz += 0;			# Hack um das mit Nachkommastellen zu nem float zu machen
			$rechnung{mwst_satz} = sprintf "%.2f", $satz;
		} else {
			error "Konnte aus der $file keinen MwSt-Satz erkennen";
		}

		if($str =~ m#Gesamtbetrag\s*(\d+(?:,\d+)?)#i) {
			my $summe = $1;
			$summe =~ s#,#.#g;
			$summe += 0;			# Hack um das mit Nachkommastellen zu nem float zu machen
			$rechnung{summe} = sprintf "%.2f", $summe;
		} else {
			error "Konnte aus der $file keinen Gesamtbetrag ermitteln";
		}
	} elsif ($parser_routine eq "Variomedia") {
		$rechnung{firma} = $parser_routine;
		if($str =~ m#Datum:\s+(?<tag>\d+)\s*\.\s*(?<monat>\d+)\s*\.\s*(?<jahr>\d{4})#i) {
			$rechnung{datum} = join(".", $+{tag}, $+{monat}, $+{jahr});
		} else {
			error "Konnte aus der $file kein Datum extrahieren";
		}

		if($str =~ m#zzgl\.\s*MwSt\s*(\d+(?:,\d+)?)\s*%:#i) {
			my $satz = $1;
			$satz =~ s#,#.#g;
			$satz += 0;			# Hack um das mit Nachkommastellen zu nem float zu machen
			$rechnung{mwst_satz} = sprintf "%.2f", $satz;
		} else {
			error "Konnte aus der $file keinen MwSt-Satz erkennen";
		}

		if($str =~ m#Endbetrag:\s*€\s*(\d+(?:,\d+)?)#i) {
			my $summe = $1;
			$summe =~ s#,#.#g;
			$summe += 0;			# Hack um das mit Nachkommastellen zu nem float zu machen
			$rechnung{summe} = sprintf "%.2f", $summe;
		} else {
			error "Konnte aus der $file keinen Gesamtbetrag ermitteln";
		}
	} elsif ($parser_routine eq "Telekom") {
		$rechnung{firma} = $parser_routine;

		if($str =~ m#Datum\s*(\d+\.\d+\.\d+)#) {
			$rechnung{datum} = $1;
		} else {
			error "Konnte kein Datum finden in der Datei $file";
		}

		if($str =~ m#Rechnungsbetrag\s+(\d+(?:,\d+)?)#) {
			my $summe = $1;
			$summe =~ s#,#.#g;
			$summe += 0;			# Hack um das mit Nachkommastellen zu nem float zu machen
			$rechnung{summe} = sprintf "%.2f", $summe;
		} else {
			error "Konnte keine summe finden in $file";
		}

		if($str =~ m#Umsatzsteuer\s*(\d+(?:,\d+)?)\s*%#) {
			my $satz = $1;
			$satz =~ s#,#.#g;
			$satz += 0;			# Hack um das mit Nachkommastellen zu nem float zu machen
			$rechnung{mwst_satz} = sprintf "%.2f", $satz;
		} else {
			error "Konnte keine mwst ermitteln";
		}

	} elsif ($parser_routine eq "Vodafone") {
		$rechnung{firma} = $parser_routine;
		if($string_without_newlines !~ m#^\s*Vodafone#) { # Vodafone Format 1
			$rechnung{firma} = "Vodafone-Mobil";
			if($str =~ m#den Zeitraum\s*vom\s*(\d+\.\d+.\d+)\s*bis\s*(\d+\.\d+.\d+)#) {
				$rechnung{datum} = $2;				# Hier 1 wählen, wenn das Startdatum des Vertrages gewählt werden soll
			} else {
				error "Konnte aus der $file kein Datum ermitteln";
			}

			if($str =~ m#(\d+(?:,\d+)?)\s*%#) {
				my $satz = $1;
				$satz =~ s#,#.#g;
				$satz += 0;			# Hack um das mit Nachkommastellen zu nem float zu machen
				$rechnung{mwst_satz} = sprintf "%.2f", $satz;
			} else {
				error "Konnte aus der $file kein mwst_satz ermitteln";
			}


			if($string_without_newlines =~ m#Zu\s*zahlender\s*Rechnungsbetrag\s*(\d+(?:,\d+)?)\s*€#) {
				my $summe = $1;
				$summe =~ s#,#.#g;
				$summe += 0;			# Hack um das mit Nachkommastellen zu nem float zu machen
				$rechnung{summe} = sprintf "%.2f", $summe;
			} else {
				error "Konnte keinen Gesamtbetrag bestimmen";
			}
		} else { # Vodafone Format 2
			$rechnung{firma} = "Vodafone-Kabel";
			if($str =~ m#MwSt\.\s*\((\d+(?:,\d+)?)%#) {
				my $satz = $1;
				$satz =~ s#,#.#g;
				$satz += 0;			# Hack um das mit Nachkommastellen zu nem float zu machen
				$rechnung{mwst_satz} = sprintf "%.2f", $satz;
			} else {
				error "Konnte aus $file keine MwSt ermitteln";
			}

			if($str =~ m#Summe:\s*\d+,\d+\s*(\d+(?:,\d+))#) {
				my $summe = $1;
				$summe =~ s#,#.#g;
				$summe += 0;			# Hack um das mit Nachkommastellen zu nem float zu machen
				$rechnung{summe} = sprintf "%.2f", $summe;
			} else {
				error "Konnte in $file keine summe finden";
			}

			# Son Blödsinn! Das Datum als Monat reinschreiben statt als Zahl >_<
			my $datum_re = "Datum:?\\s*(\\d+\.\\s*\\w+\\s*\\d+)";
			if($str =~ m#$datum_re#i) {
				my $res = lc $1;
				my ($tag, $monat, $monat_name, $jahr) = (undef, undef, undef, undef);
				if($res =~ m#(\d+)\.\s*(\w+)\s*(\d+)#) {
					($tag, $monat_name, $jahr) = ($1, $2, $3);
				}

				if($monat_name) {
					$monat = firstidx { $_ =~ /$monat_name/  } @monate;
					$monat++;
				}

				$rechnung{datum} = "$tag.$monat.$jahr";
			}
			if(!defined($rechnung{datum})) {
				error "Konnte in $file kein datum finden";
			}
		}
	} else {
		die "Invalid parser routine $parser_routine";
	}

	debug Dumper \%rechnung;

	foreach (keys %rechnung) {
		if(!defined($rechnung{$_})) {
			error "Could not get $_ from $file";
		}
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
	print join(",", @keys);
	foreach my $this_rechnung (@rechnungen) {
		print join(",", map { $this_rechnung->{$_} } @keys);
	}
}

main();
