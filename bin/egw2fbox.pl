#!/usr/bin/perl
### FILE
#       egw2fbox.pl - reads addresses from eGroupware database
#                   - exports them to a XML file that can be imported to
#                     the Fritz Box phone book via Fritz Box web interface
#                   - exports them to the Round Cube web mailer address
#                     inside the Round Cube database
#
### COPYRIGHT
#       Copyright 2011  Christian Anton <mail@christiananton.de>
#                       Kai Ellinger <coding@blicke.de>
#
#       This program is free software; you can redistribute it and/or modify
#       it under the terms of the GNU General Public License as published by
#       the Free Software Foundation; either version 2 of the License, or
#       (at your option) any later version.
#       
#       This program is distributed in the hope that it will be useful,
#       but WITHOUT ANY WARRANTY; without even the implied warranty of
#       MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#       GNU General Public License for more details.
#       
#       You should have received a copy of the GNU General Public License
#       along with this program; if not, write to the Free Software
#       Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston,
#       MA 02110-1301, USA.
#
### CHANGELOG
#
# 0.5.2 2011-03-08 Kai Ellinger <coding@blicke.de>
#                  - started implementing round cube address book sync because I feel it is urgent ;-)
#                    did not touch any SQL code, need to update all TODOs with inserting SQL code
#                  - remove need for $FRITZXML being a global variable
#
# 0.5.1 2011-03-04 Christian Anton <mail@christiananton.de>
#                  - tidy up code to fulfill Perl::Critic tests at "gentle" severity:
#                    http://www.perlcritic.org/
#
# 0.5.0 2011-03-04 Christian Anton <mail@christiananton.de>, Kai Ellinger <coding@blicke.de>
#                  - data is requested from DB in UTF8 and explicitly converted in desired encoding
#                    inside of fbox_write_xml_contact function
#                  - mutt export function now writes aliases file in UTF-8 now. If you use anything
#                    different - you're wrong!
#                  - fixed bug: for private contact entries in FritzBox the home number was taken from
#                    database field tel_work instead of tel_home
#                  - extended fbox_reformatTelNr to support local phone number annotation to work around
#                    inability of FritzBox to rewrite phone number for incoming calls
#
# 0.4.0 2011-03-02 Kai Ellinger <coding@blicke.de>
#                  - added support for mutt address book including an example file showing 
#                    how to configure ~/.muttrc to support a local address book and a global
#                    EGW address book
#                  - replaced time stamp in fritz box xml with real time stamp from database
#                    this feature is more interesting for round cube integration where we have
#                    a time stamp field in the round cube database
#                  - added some comments
#
# 0.3.0 2011-02-26 Kai Ellinger <coding@blicke.de>
#                  - Verbose function:
#                    * only prints if data was provided
#                    * avoiding unnecessary verbose function calls
#                    * avoiding runtime errors due to uninitialized data in verbose mode
#                  - Respect that Fritzbox address book names can only have 25 characters
#                  - EGW address book to Fritz Box phone book mapping:
#                    The Fritz Box Phone book knows 3 different telephone number types:
#                      'work', 'home' and 'mobile'
#                    Each Fritz Box phone book entry can have up to 3 phone numbers.
#                    All 1-3 phone numbers can be of same type or different types.
#                    * Compact mode (if one EGW address has 1-3 phone numbers):
#                       EGW field tel_work          -> FritzBox field type 'work'
#                       EGW field tel_cell          -> FritzBox field type 'mobile'
#                       EGW field tel_assistent     -> FritzBox field type 'work'
#                       EGW field tel_home          -> FritzBox field type 'home'
#                       EGW field tel_cell_private  -> FritzBox field type 'mobile'
#                       EGW field tel_other         -> FritzBox field type 'home'
#                      NOTE: Because we only have 3 phone numbers, we stick on the right number types.
#                    * Business Fritz Box phone book entry (>3 phone numbers):
#                       EGW field tel_work          -> FritzBox field type 'work'
#                       EGW field tel_cell          -> FritzBox field type 'mobile'
#                       EGW field tel_assistent     -> FritzBox field type 'home'
#                      NOTE: On hand sets, the list order is work, mobile, home. That's why the
#                            most important number is 'work' and the less important is 'home' here.
#                    * Private Fritz Box phone book entry (>3 phone numbers):
#                       EGW field tel_home          -> FritzBox field type 'work'
#                       EGW field tel_cell_private  -> FritzBox field type 'mobile'
#                       EGW field tel_other         -> FritzBox field type 'home'
#                      NOTE: On hand sets, the list order is work, mobile, home. That's why the
#                            most important number is 'work' and the less important is 'home' here.
#                   - Added EGW DB connect string check
#                   - All EGW functions have now prefix 'egw_', all Fritz Box functions prefix
#                     'fbox_' and all Round Cube functions 'rcube_' to prepare the source for
#                     adding the round cube sync.
#
# 0.2.0 2011-02-25 Christian Anton <mail@christiananton.de>
#                  implementing XML-write as an extra function and implementing COMPACT_MODE which
#                  omits creating two contact entries for contacts which have only up to three numbers
#
# 0.1.0 2011-02-24 Kai Ellinger <coding@blicke.de>, Christian Anton <mail@christiananton.de>
#                  Initial version of this script, ready for world domination ;-)

#### modules
use warnings;     # installed by default via perlmodlib
use strict;       # installed by default via perlmodlib
use Getopt::Long; # installed by default via perlmodlib
use DBI;          # not included in perlmodlib: DBI and DBI::Mysql needs to be installed if not already done
use Data::Dumper;            # installed by default via perlmodlib
use List::Util qw [min max]; # installed by default via perlmodlib
use Encode;       # installed by default via perlmodlib

#### global variables
## config
my $o_verbose;
my $o_configfile = "egw2fbox.conf";
my $cfg;

## eGroupware
my $egw_address_data;

## fritz box config parameters we don't like to be modified without thinking
# the maximum number of characters that a Fritz box phone book name can have
my $FboxMaxLenghtForName = 32;
# Maybe the code page setting changes based on Fritz Box language settings
# and must vary for characters other than germany special characters.
# This variable can be used to specify the code page used at the exported XML.
my $FboxAsciiCodeTable = "iso-8859-1"; #


#### functions
sub check_args {
				Getopt::Long::Configure ("bundling");
				GetOptions(
					'v'   => \$o_verbose,     'verbose'   => \$o_verbose,
					'c:s' => \$o_configfile,  'config:s'  => \$o_configfile
		);
}

sub parse_config {
	# - we are not using perl module Config::Simple here because it was not installed
	#   on our server by default and we saw compile errors when trying to install it via CPAN
	# - we decided to implement our own config file parser to keep the installation simple 
	#   and let the script run with as less dependencies as possible
	open (my $CFGFILE, '<', "$o_configfile") or die "could not open config file: $!";

	while(defined(my $line = <$CFGFILE>) )
	{
		chomp $line;
		$line =~ s/#.*//g;
		$line =~ s/\s+$//;
		next if $line !~ /=/;
		$line =~ s/\s*=\s*/=/;
		$line =~ /^([^=]+)=(.*)/;
		my $key = $1;
		my $value = $2;

		$cfg->{$key} = $value;
	}
	close $CFGFILE;

}

sub verbose{
	my $msg = shift;
	if ($o_verbose && $msg) {
		print "$msg\n";
	}
}

sub egw_read_db {
	my $dbh;
	my $sth;
	my $sql;

	my @res;

	# default values for DB connect
	if (!$cfg->{EGW_DBHOST}) { $cfg->{EGW_DBHOST} = 'localhost'; }
	if (!$cfg->{EGW_DBPORT}) { $cfg->{EGW_DBPORT} = 3306; }
	if (!$cfg->{EGW_DBNAME}) { $cfg->{EGW_DBNAME} = 'egroupware'; }
	# don't set default values for DB user and password
	die "ERROR: EGW database can't be accessed without DB user name or password set!"
		if( !($cfg->{EGW_DBUSER}) || !($cfg->{EGW_DBPASS}) );

	my $dsn = "dbi:mysql:$cfg->{EGW_DBNAME}:$cfg->{EGW_DBHOST}:$cfg->{EGW_DBPORT}";
	$dbh = DBI->connect($dsn, $cfg->{EGW_DBUSER}, $cfg->{EGW_DBPASS}) or die "could not connect db: $!";
	# read database via UTF8; convert in print function if needed
	$dbh->do("SET NAMES utf8");
	# convert UTF8 values inside EGW DB to latin1 because Fritz Box expects German characters in iso-8859-1
	#$dbh->do("SET NAMES latin1");  # latin1 is good at least for XML files created with iso-8859-1
	
	#  mysql> describe egw_addressbook;
	#  +----------------------+--------------+------+-----+---------+----------------+
	#  | Field                | Type         | Null | Key | Default | Extra          |
	#  +----------------------+--------------+------+-----+---------+----------------+
	#  | contact_id           | int(11)      | NO   | PRI | NULL    | auto_increment | 
	#  | contact_tid          | varchar(1)   | YES  |     | n       |                | 
	#  | contact_owner        | bigint(20)   | NO   | MUL | NULL    |                | 
	#  | contact_private      | tinyint(4)   | YES  |     | 0       |                | 
	#  | cat_id               | varchar(255) | YES  | MUL | NULL    |                | 
	#  | n_family             | varchar(64)  | YES  | MUL | NULL    |                | 
	#  | n_given              | varchar(64)  | YES  | MUL | NULL    |                | 
	#  | n_middle             | varchar(64)  | YES  |     | NULL    |                | 
	#  | n_prefix             | varchar(64)  | YES  |     | NULL    |                | 
	#  | n_suffix             | varchar(64)  | YES  |     | NULL    |                | 
	#  | n_fn                 | varchar(128) | YES  |     | NULL    |                | 
	#  | n_fileas             | varchar(255) | YES  | MUL | NULL    |                | 
	#  | contact_bday         | varchar(12)  | YES  |     | NULL    |                | 
	#  | org_name             | varchar(128) | YES  | MUL | NULL    |                | 
	#  | org_unit             | varchar(64)  | YES  |     | NULL    |                | 
	#  | contact_title        | varchar(64)  | YES  |     | NULL    |                | 
	#  | contact_role         | varchar(64)  | YES  |     | NULL    |                | 
	#  | contact_assistent    | varchar(64)  | YES  |     | NULL    |                | 
	#  | contact_room         | varchar(64)  | YES  |     | NULL    |                | 
	#  | adr_one_street       | varchar(64)  | YES  |     | NULL    |                | 
	#  | adr_one_street2      | varchar(64)  | YES  |     | NULL    |                | 
	#  | adr_one_locality     | varchar(64)  | YES  |     | NULL    |                | 
	#  | adr_one_region       | varchar(64)  | YES  |     | NULL    |                | 
	#  | adr_one_postalcode   | varchar(64)  | YES  |     | NULL    |                | 
	#  | adr_one_countryname  | varchar(64)  | YES  |     | NULL    |                | 
	#  | contact_label        | text         | YES  |     | NULL    |                | 
	#  | adr_two_street       | varchar(64)  | YES  |     | NULL    |                | 
	#  | adr_two_street2      | varchar(64)  | YES  |     | NULL    |                | 
	#  | adr_two_locality     | varchar(64)  | YES  |     | NULL    |                | 
	#  | adr_two_region       | varchar(64)  | YES  |     | NULL    |                | 
	#  | adr_two_postalcode   | varchar(64)  | YES  |     | NULL    |                | 
	#  | adr_two_countryname  | varchar(64)  | YES  |     | NULL    |                | 
	#  | tel_work             | varchar(40)  | YES  |     | NULL    |                | 
	#  | tel_cell             | varchar(40)  | YES  |     | NULL    |                | 
	#  | tel_fax              | varchar(40)  | YES  |     | NULL    |                | 
	#  | tel_assistent        | varchar(40)  | YES  |     | NULL    |                | 
	#  | tel_car              | varchar(40)  | YES  |     | NULL    |                | 
	#  | tel_pager            | varchar(40)  | YES  |     | NULL    |                | 
	#  | tel_home             | varchar(40)  | YES  |     | NULL    |                | 
	#  | tel_fax_home         | varchar(40)  | YES  |     | NULL    |                | 
	#  | tel_cell_private     | varchar(40)  | YES  |     | NULL    |                | 
	#  | tel_other            | varchar(40)  | YES  |     | NULL    |                | 
	#  | tel_prefer           | varchar(32)  | YES  |     | NULL    |                | 
	#  | contact_email        | varchar(128) | YES  |     | NULL    |                | 
	#  | contact_email_home   | varchar(128) | YES  |     | NULL    |                | 
	#  | contact_url          | varchar(128) | YES  |     | NULL    |                | 
	#  | contact_url_home     | varchar(128) | YES  |     | NULL    |                | 
	#  | contact_freebusy_uri | varchar(128) | YES  |     | NULL    |                | 
	#  | contact_calendar_uri | varchar(128) | YES  |     | NULL    |                | 
	#  | contact_note         | text         | YES  |     | NULL    |                | 
	#  | contact_tz           | varchar(8)   | YES  |     | NULL    |                | 
	#  | contact_geo          | varchar(32)  | YES  |     | NULL    |                | 
	#  | contact_pubkey       | text         | YES  |     | NULL    |                | 
	#  | contact_created      | bigint(20)   | YES  |     | NULL    |                | 
	#  | contact_creator      | int(11)      | NO   |     | NULL    |                | 
	#  | contact_modified     | bigint(20)   | NO   |     | NULL    |                | 
	#  | contact_modifier     | int(11)      | YES  |     | NULL    |                | 
	#  | contact_jpegphoto    | longblob     | YES  |     | NULL    |                | 
	#  | account_id           | int(11)      | YES  | UNI | NULL    |                | 
	#  | contact_etag         | int(11)      | YES  |     | 0       |                | 
	#  | contact_uid          | varchar(255) | YES  | MUL | NULL    |                | 
	#  +----------------------+--------------+------+-----+---------+----------------+

	$sql = "
		SELECT
			`contact_id`,
			`n_prefix`,
			`n_fn`,
			`n_given`,
			`n_middle`,
			`n_family`,
			`tel_work`,
			`tel_cell`,
			`tel_assistent`,
			`tel_home`,
			`tel_cell_private`,
			`tel_other`,
			`contact_email`,
			`contact_email_home`,
			`contact_modified`
		FROM
			`egw_addressbook`
		WHERE
			`contact_owner` IN ( $cfg->{EGW_ADDRBOOK_OWNERS} )
	";

	$sth = $dbh->prepare($sql);
	$sth->execute;

	$egw_address_data = $sth->fetchall_hashref('contact_id');

	#print "Name for id 57 is $egw_address_data->{57}->{n_fn}\n";
	my $amountData = keys(%{$egw_address_data});
	verbose("found $amountData data rows in egw addr book");

	die "no data for owner(s) $cfg->{ADDRBOOK_OWNERS} found" if ( 0 == $amountData );
}

sub fbox_reformatTelNr {
	my $nr = shift;

	# this function will most likely _not_ work in countries using the north american numbering plan
	# if you use a FritzBox in one of these states, fix this function and submit changes to us
	# http://en.wikipedia.org/wiki/North_American_Numbering_Plan

	# first rewrite all phone numbers to international format: 
	# 004912345678 (where 00 is FBOX_INTERNATIONAL_ACCESS_CODE)
	$nr =~ s/^\+/$cfg->{FBOX_INTERNATIONAL_ACCESS_CODE}/;

	# dele all non-decimals
	$nr =~ s/[^\d]+//g;

	# change national numbers starting with FBOX_NATIONAL_ACCESS_CODE + FBOX_MY_AREA_CODE to the same 
	# format (i.e. 08935350 -> 004935350)
	if(!($nr =~ /^$cfg->{FBOX_INTERNATIONAL_ACCESS_CODE}/) && ($nr =~ /^$cfg->{FBOX_NATIONAL_ACCESS_CODE}/) ) {
		$nr =~  s/^$cfg->{FBOX_NATIONAL_ACCESS_CODE}/$cfg->{FBOX_INTERNATIONAL_ACCESS_CODE}$cfg->{FBOX_MY_COUNTRY_CODE}/;
	}

	# change all local numbers NOT starting with FBOX_INTERNATIONAL_ACCESS_CODE to be in the same format
	# i.e. 12345 -> 00498912345
	if(!($nr =~ /^$cfg->{FBOX_INTERNATIONAL_ACCESS_CODE}/) ) {
		$nr =~ s/^/$cfg->{FBOX_INTERNATIONAL_ACCESS_CODE}$cfg->{FBOX_MY_COUNTRY_CODE}$cfg->{FBOX_MY_AREA_CODE}/;
	}

	# from here on we have universal peace! All phone numbers are in same format!
	# depending on configuration options we reformat numbers now to ensure that FritzBox can resolve phone numbers
	# of incoming calls to real names

	if ($cfg->{FBOX_DELETE_MY_COUNTRY_CODE}) {

		# numbers of my area
		if ($cfg->{FBOX_DELETE_MY_AREA_CODE}) {
			$nr =~ s/^$cfg->{FBOX_INTERNATIONAL_ACCESS_CODE}$cfg->{FBOX_MY_COUNTRY_CODE}$cfg->{FBOX_MY_AREA_CODE}//;
		}

		# numbers of my country
		$nr =~ s/^$cfg->{FBOX_INTERNATIONAL_ACCESS_CODE}$cfg->{FBOX_MY_COUNTRY_CODE}/$cfg->{FBOX_NATIONAL_ACCESS_CODE}/;
	}
	

	return $nr;
}

sub fbox_write_xml_contact {
	my $FRITZXML = shift;
	my $contact_name = shift;
	my $contact_name_suffix = shift;
	my $numbers_array_ref = shift;
	my $now_timestamp = shift;
	my $name_length;
	my $output_name;

	# convert output name to character encoding as defined in $FboxAsciiCodeTable
	# only contact name and contact name's suffix can contain special chars
	Encode::from_to($contact_name, "utf8", $FboxAsciiCodeTable);
	Encode::from_to($contact_name_suffix, "utf8", $FboxAsciiCodeTable);
	
	# reformat name according to max length and suffix
	if ($contact_name_suffix) {
		$name_length = min($cfg->{FBOX_TOTAL_NAME_LENGTH},$FboxMaxLenghtForName) - 1 - length($contact_name_suffix);
		$output_name = substr($contact_name,0,$name_length);
		$output_name =~ s/\s+$//;
		$output_name = $output_name . " " . $contact_name_suffix;
	} else {
		$name_length = min($cfg->{FBOX_TOTAL_NAME_LENGTH},$FboxMaxLenghtForName);
		$output_name = substr($contact_name,0,$name_length);
		$output_name =~ s/\s+$//;
	}
	
	# print the top XML wrap for the contact's entry
	print $FRITZXML "<contact>\n<category>0</category>\n<person><realName>$output_name</realName></person>\n";
	print $FRITZXML "<telephony>\n";

	foreach my $numbers_entry_ref (@$numbers_array_ref) {
		# not defined values causing runtime errors
		$o_verbose && verbose ("   type: ". ($numbers_entry_ref->{'type'} || "<undefined>") . " , number: ". ($numbers_entry_ref->{'nr'}|| "<undefined>")  );
		if ($$numbers_entry_ref{'nr'}) {
			print $FRITZXML "<number type=\"$$numbers_entry_ref{'type'}\" vanity=\"\" prio=\"0\">" .
				fbox_reformatTelNr($$numbers_entry_ref{'nr'}) .
				"</number>\n";
		}
	}

	# print the bottom XML wrap for the contact's entry
	print $FRITZXML "</telephony>\n";
	print $FRITZXML "<services /><setup /><mod_time>$now_timestamp</mod_time></contact>";
}

sub fbox_count_contacts_numbers {
	my $key = shift;
	my $count = 0;

	$count++ if ($egw_address_data->{$key}->{'tel_work'});
	$count++ if ($egw_address_data->{$key}->{'tel_cell'});
	$count++ if ($egw_address_data->{$key}->{'tel_assistent'});
	$count++ if ($egw_address_data->{$key}->{'tel_home'});
	$count++ if ($egw_address_data->{$key}->{'tel_cell_private'});
	$count++ if ($egw_address_data->{$key}->{'tel_other'});

	return $count;
}

sub fbox_gen_fritz_xml {
	my $now_timestamp = time();

	# make file descriptor for XML output file global
	my $FRITZXML;
	
	# open file
	open ($FRITZXML, '>', $cfg->{FBOX_OUTPUT_XML_FILE}) or die "could not open file! $!";
	print $FRITZXML <<EOF;
<?xml version="1.0" encoding="${FboxAsciiCodeTable}"?>
<phonebooks>
<phonebook name="Telefonbuch">
EOF
	# data should look like this:
	# <contact>
	#   <category>0</category>
	#   <person>
	#     <realName>test user</realName>
	#   </person>
	#   <telephony>
	#     <number type="home" vanity="" prio="0">08911111</number>
	#     <number type="mobile" vanity="" prio="0">08911112</number>
	#     <number type="work" vanity="" prio="0">08911113</number>
	#   </telephony>
	#   <services />
	#   <setup />
	#   <mod_time>1298300800</mod_time>
	# </contact>

	## start iterate

	foreach my $key ( keys(%{$egw_address_data}) ) {
		my $contact_name = $egw_address_data->{$key}->{'n_fn'};
		verbose ("generating XML snippet for contact $contact_name");
		if ($egw_address_data->{$key}->{'n_prefix'}) {
			$contact_name =~ s/^$egw_address_data->{$key}->{'n_prefix'}\s*//;
		}

		my $number_of_numbers = 0;
		# counting phone numbers is only in compact mode needed
		if($cfg->{FBOX_COMPACT_MODE}) {
			$number_of_numbers = fbox_count_contacts_numbers($key);
			verbose ("contact has $number_of_numbers phone numbers defined");
			}

		if ( ($cfg->{FBOX_COMPACT_MODE}) && ($number_of_numbers <= 3) ){

			verbose ("entering compact mode for this contact entry");
			my @numbers_array;


			# tel_work belongs to business phone numbers in EGW
			if ($egw_address_data->{$key}->{'tel_work'}) {
				push @numbers_array, { type=>'work', nr=>$egw_address_data->{$key}->{'tel_work'} };
			}


			# tel_cell belongs to business phone numbers in EGW (work mobile)
			# setting type to 'mobile'; others might like to set it to 'work' instead
			if ($egw_address_data->{$key}->{'tel_cell'}) {
				push @numbers_array, { type=>'mobile', nr=>$egw_address_data->{$key}->{'tel_cell'} };
			}


			# tel_assistent belongs to business phone numbers in EGW
			if ($egw_address_data->{$key}->{'tel_assistent'}) {
				push @numbers_array, { type=>'work', nr=>$egw_address_data->{$key}->{'tel_assistent'} };
			}

			# tel_home belongs to private phone numbers in EGW
			if ($egw_address_data->{$key}->{'tel_home'}) {
				push @numbers_array, { type=>'home', nr=>$egw_address_data->{$key}->{'tel_home'} };
			}

			# tel_cell_private belongs to private phone numbers in EGW
			# setting type to 'mobile'; others might like to set it to 'home' instead
			if ($egw_address_data->{$key}->{'tel_cell_private'}) {
				push @numbers_array, { type=>'mobile', nr=>$egw_address_data->{$key}->{'tel_cell_private'} };
			}

			# tel_other belongs to private phone numbers in EGW
			if ($egw_address_data->{$key}->{'tel_other'}) {
				push @numbers_array, { type=>'home', nr=>$egw_address_data->{$key}->{'tel_other'} };
			}

			fbox_write_xml_contact($FRITZXML, $contact_name, '', \@numbers_array, $egw_address_data->{$key}->{'contact_modified'});

		} else {

			verbose ("entering non-compact mode for this contact entry");

			# start print the business contact entry
			if (
				($egw_address_data->{$key}->{'tel_work'}) ||
				($egw_address_data->{$key}->{'tel_cell'}) ||
				($egw_address_data->{$key}->{'tel_assistent'})
			 ) {

				verbose ("  start writing the business contact entry");
				my @numbers_array;

				push @numbers_array, { type=>'home',   nr=>$egw_address_data->{$key}->{'tel_work'} };
				push @numbers_array, { type=>'mobile', nr=>$egw_address_data->{$key}->{'tel_cell'} };
				push @numbers_array, { type=>'work',   nr=>$egw_address_data->{$key}->{'tel_assistent'} };

				fbox_write_xml_contact($FRITZXML, $contact_name, $cfg->{FBOX_BUSINESS_SUFFIX_STRING}, \@numbers_array, $egw_address_data->{$key}->{'contact_modified'});
			}
			# end print the business contact entry

			# start print the private contact entry
			if (
				($egw_address_data->{$key}->{'tel_home'}) ||
				($egw_address_data->{$key}->{'tel_cell_private'}) ||
				($egw_address_data->{$key}->{'tel_other'})
			) {

				verbose ("  start writing the private contact entry");
				my @numbers_array;

				push @numbers_array, { type=>'home',   nr=>$egw_address_data->{$key}->{'tel_home'} };
				push @numbers_array, { type=>'mobile', nr=>$egw_address_data->{$key}->{'tel_cell_private'} };
				push @numbers_array, { type=>'work',   nr=>$egw_address_data->{$key}->{'tel_other'} };

				fbox_write_xml_contact($FRITZXML, $contact_name, $cfg->{FBOX_PRIVATE_SUFFIX_STRING}, \@numbers_array, $egw_address_data->{$key}->{'contact_modified'});
			}
			# end print the private contact entry
		}
		# end non-compact mode
	}
	## end iterate


	print $FRITZXML <<EOF;
</phonebook>
</phonebooks>
EOF
	close $FRITZXML;
}

sub rcube_update_address_book {
	verbose ("updating round cube address book");
	my $dbh;
	my $sql; # the SQL statement should use bind variables for better performance
	my $sth;
	
	## we don't need any more because we have EGW field contact_modified
	#my $now_timestamp = time();
	#  mysql> describe contacts;
	#  +------------+------------------+------+-----+---------------------+----------------+
	#  | Field      | Type             | Null | Key | Default             | Extra          |
	#  +------------+------------------+------+-----+---------------------+----------------+
	#  | contact_id | int(10) unsigned | NO   | PRI | NULL                | auto_increment | 
	#  | changed    | datetime         | NO   |     | 1000-01-01 00:00:00 |                | 
	#  | del        | tinyint(1)       | NO   |     | 0                   |                | 
	#  | name       | varchar(128)     | NO   |     |                     |                | 
	#  | email      | varchar(255)     | NO   |     | NULL                |                | 
	#  | firstname  | varchar(128)     | NO   |     |                     |                | 
	#  | surname    | varchar(128)     | NO   |     |                     |                | 
	#  | vcard      | text             | YES  |     | NULL                |                | 
	#  | user_id    | int(10) unsigned | NO   | MUL | 0                   |                | 
	#  +------------+------------------+------+-----+---------------------+----------------+
	### Round Cube table to EGW table field mapping:
	# contact_id = auto
	# changed = contact_modified
	# name = n_fn - n_prefix + (RCUBE_BUSINESS_SUFFIX_STRING|RCUBE_PRIVATE_SUFFIX_STRING according to type of e-mail address)
	# email = (contact_email|contact_email_home)
	# firstname = n_given + n_middle
	# surname = n_family
	# vcard = null
	# user_id = RCUBE_ADDRBOOK_OWNERS per each value (can be multiple)
	###
	# NOTE: Need to cut strings to place into name, email, firstname, surname
	###
	
	# TODO - connect to the RCUBE database
	
	# Delete old contacts for specified users
	foreach my $userId ( split(',', $cfg->{RCUBE_ADDRBOOK_OWNERS} ) ) {
		# TODO - SQL DELETE FROM `contacts` WHERE `user_id` = $userId
	}
	
	# Insert contact details for contacts having mail addresses specified
	foreach my $key ( keys(%{$egw_address_data}) ) {
		my $contact_name = $egw_address_data->{$key}->{'n_fn'};
		verbose ("generating rcube address book for contact $contact_name");
		
		# if there is a prefix such as Mr, Mrs, Herr Frau, remove it
		if ($egw_address_data->{$key}->{'n_prefix'}) {
			$contact_name =~ s/^$egw_address_data->{$key}->{'n_prefix'}\s*//;
		}
		
		# if first name exists
		my $first_name = "";
		if($egw_address_data->{$key}->{'n_given'}) { $first_name = $egw_address_data->{$key}->{'n_given'}; }
		if($egw_address_data->{$key}->{'n_middle'}) { $first_name = " " . $egw_address_data->{$key}->{'n_middle'}; }
			
		# each round cube user has his own address book
		foreach my $userId ( split(',', $cfg->{RCUBE_ADDRBOOK_OWNERS}) ) {
		
			# the business e-mail address
			if($egw_address_data->{$key}->{'contact_email'}) {
				my $full_name = $contact_name;
				# if suffix exists
				if($cfg->{RCUBE_BUSINESS_SUFFIX_STRING}) { $full_name .= " " . $cfg->{RCUBE_BUSINESS_SUFFIX_STRING}; }
				rcube_insert_address(
					$sth,
					$egw_address_data->{$key}->{'contact_email'},
					$full_name,
					$first_name,
					$egw_address_data->{$key}->{'n_family'},
					$userId,
					$egw_address_data->{$key}->{'contact_modified'}
				);
			}
			
			# the private e-mail address
			if($egw_address_data->{$key}->{'contact_email_home'}) {
				my $full_name = $contact_name;
				# if suffix exists
				if($cfg->{RCUBE_PRIVATE_SUFFIX_STRING}) { $full_name .= " " . $cfg->{RCUBE_PRIVATE_SUFFIX_STRING}; }
				rcube_insert_address(
					$sth,
					$egw_address_data->{$key}->{'contact_email_home'},
					$full_name,
					$first_name,
					$egw_address_data->{$key}->{'n_family'},
					$userId,
					$egw_address_data->{$key}->{'contact_modified'}
				);
			}
		} #END: foreach my $userId ( split(',',) $cfg->{RCUBE_ADDRBOOK_OWNERS} )
		
		
	} # END: foreach my $key ( keys(%{$egw_address_data}) )
	
	# TODO - close RCUBE database
}


sub rcube_insert_address() {
		my $sth       = shift;
		my $email     = shift;
		my $name      = shift;
		my $firstName = shift;
		my $familyName= shift;
		my $userId    = shift;
		my $changed   = shift;

		verbose ("INSERT data for: rcube RQ user id '$userId' contact '$name' mail '$email'");
		
		# TODO - check field size before inserting anyhing into table
		
		# TODO insert into table; use the already prepared statement $sth and insert the values via bind variables
		# See DBI - http://search.cpan.org/~timb/DBI-1.616/DBI.pm
		# Example: 
		# $sth = $dbh->prepare("SELECT foo, bar FROM table WHERE baz=?"); # in rcube_update_address_book
		# $sth->execute( $baz ); # in rcube_insert_address
		
		# INSERT INTO `contacts` (`email`, `name`, `firstname`, `surname`, `user_id`, `changed`)
		# VALUES ($email, $name, $firstName, $familyName, $userId, $changed)
		
}


sub mutt_update_address_book {
	verbose ("updating mutt address book");
	my $index = 0;

	open (my $MUTT, ">", $cfg->{MUTT_EXPORT_FILE}) or die "could not open file! $!";

	foreach my $key ( keys(%{$egw_address_data}) ) {
		
		# contact name is full contact name - prefix
		my $contact_name = $egw_address_data->{$key}->{'n_fn'};
		if ($egw_address_data->{$key}->{'n_prefix'}) {
			$contact_name =~ s/^$egw_address_data->{$key}->{'n_prefix'}\s*//;
		}

		# Alias | Name | eMailAdresse |
		#
		#alias Maxi Max Mustermann <MaxMustermann@mail.de>
		#alias SuSE Susi Mustermann <SusiMustermann@mail.de>
		
		# this is the business e-mail address
		if($egw_address_data->{$key}->{'contact_email'}) {
			$index++;
			printf $MUTT "alias %03d %s %s <%s>\n", $index, $contact_name, $cfg->{MUTT_BUSINESS_SUFFIX_STRING},$egw_address_data->{$key}->{'contact_email'};
		}
		
		# this is the private e-mail address
		if($egw_address_data->{$key}->{'contact_email_home'}) {
			$index++;
			printf $MUTT "alias %03d %s %s <%s>\n", $index, $contact_name, $cfg->{MUTT_PRIVATE_SUFFIX_STRING},$egw_address_data->{$key}->{'contact_email_home'};
		}

	}
	#end: foreach my $key ( keys(%{$egw_address_data}) )
	
	close $MUTT;
}


#### MAIN
check_args;
parse_config;
egw_read_db();
if($cfg->{FBOX_EXPORT_ENABLED}) { 
	fbox_gen_fritz_xml; 
}
if($cfg->{RCUBE_EXPORT_ENABLED}) { 
	rcube_update_address_book; 
}
if($cfg->{MUTT_EXPORT_ENABLED}) { 
	mutt_update_address_book; 
}
