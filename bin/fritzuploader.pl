#!/usr/bin/perl
# fritzuploader is (C) 2010 by Jan-Piet Mens
# The contents of this file are subject to the Mozilla Public License Version
# 1.1 (the "License"); you may not use this file except in compliance with
# the License. You may obtain a copy of the License at
# http://www.mozilla.org/MPL/
# 
# Software distributed under the License is distributed on an "AS IS" basis,
# WITHOUT WARRANTY OF ANY KIND, either express or implied. See the License
# for the specific language governing rights and limitations under the
# License.
#
# Based on information gleaned from project Thunder!Box by
# Christoph Linder.
# Portions created by the Initial Developer are Copyright (C) 2009
# the Initial Developer. All Rights Reserved.

use warnings;
use strict;
use LWP;
use XML::Simple;
use Digest::MD5 qw(md5 md5_hex);
use Encode;

##### use config file instead of command line argiments 
# added config file routine by Kai Ellinger <coding@blicke.de>
# START modification
my $cfg;
my $cFile = 'fritzuploader.conf';
### fritzuploader.conf example
#----------------------------------------------------
############################################
### config parameters for fritzuploader.pl
############################################
#FRITZUPLOADER_FRITZBOX_IP = fritz.box
#FRITZUPLOADER_FRITZBOX_PW = <fbox_admin_password>
#FRITZUPLOADER_XML_FILE = /path/to/phonebook.xml
#----------------------------------------------------
if($ENV{FRITZUPLOADERCFG}) { $cFile = $ENV{FRITZUPLOADERCFG}; }
sub parse_config {
	open (CONFIG, "$cFile") or die "could not open config file '$cFile': $!";
	
	while(defined(my $line = <CONFIG>) )
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
	close CONFIG;
}

my $fritz = $cfg->{FRITZUPLOADER_FRITZBOX_IP};	# or IP address '192.168.1.1'
my $password = $cfg->{FRITZUPLOADER_FRITZBOX_PW};
my $phonebookFile = $cfg->{FRITZUPLOADER_XML_FILE};
print "--$password--$phonebookFile--$fritz\n";
#my $password = $ARGV[0] or die "Usage: $0 fritzbox-password\n";
# END modification

my $webcmurl = "http://$fritz/cgi-bin/webcm";
my $firmwurl = "http://$fritz/cgi-bin/firmwarecfg";

my $successmsg = 'Das Telefonbuch der FRITZ!Box wurde wiederhergestellt'; # German

my $ua = LWP::UserAgent->new;
my $resp = $ua->get( "$webcmurl?getpage=../html/login_sid.xml");
die "Can't access $webcmurl: " . $resp->status_line() . "\n" unless $resp->is_success();

my $content = $resp->content();

#  <SessionInfo>
#  <iswriteaccess>0</iswriteaccess>
#  <SID>0000000000000000</SID>
#  <Challenge>fb6138de</Challenge>
#  </SessionInfo>

my $challenge = XMLin($content)->{Challenge};

# FIXME: clear-text password's character points > 255 must be '.'

my $input = $challenge . '-' . $password;
Encode::from_to($input, 'ascii', 'utf16le');

my $challengeresponse = $challenge . '-' . lc(md5_hex($input));

# print $challengeresponse, "\n";

$resp = HTTP::Request->new(POST => $webcmurl);
$resp->content_type("application/x-www-form-urlencoded");
$resp->content("login:command/response=${challengeresponse}&getpage=../html/login_sid.xml");

my $loginresp = $ua->request($resp);
die "Can't get SID " . $loginresp->status_line() . "\n" unless $loginresp->is_success();

# print $xx->content();
#	<SessionInfo>
#	<iswriteaccess>1</iswriteaccess>
#	<SID>166ef35a5f4b4577</SID>
#	<Challenge>2a91cc5f</Challenge>
#	</SessionInfo>

my $SID = XMLin($loginresp->content)->{SID};

die "Authentication failed. (Password incorrect?)\n" if $SID eq '0000000000000000';

# print "SID == $SID\n";

$resp = $ua->post($firmwurl,
	[
		'sid' => [ undef, undef, 'Content' => "$SID", ],
		'PhonebookId'	=> [
			undef,
			undef,
			'Content' => " 0",	# space on purpose; needs zero
			],
		'PhonebookImportFile'	=> [
			$phonebookFile,
			$phonebookFile,
			'Content_Type' => 'text/xml'
			]
	],
	'Content_Type' => 'form-data');

die "Error: ", $resp->status_line, "\n" unless $resp->is_success;

my $html = $resp->as_string();
if ($html =~ /$successmsg/) {
	print "Success: phonebook uploaded\n";
	exit;
}

die "Phonebook probably NOT uploaded: $html\n";


