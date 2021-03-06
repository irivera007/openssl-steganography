#! /usr/bin/env perl
# Copyright 2015-2016 The OpenSSL Project Authors. All Rights Reserved.
#
# Licensed under the OpenSSL license (the "License").  You may not use
# this file except in compliance with the License.  You can obtain a copy
# in the file LICENSE in the source distribution or at
# https://www.openssl.org/source/license.html

use strict;
use OpenSSL::Test qw/:DEFAULT cmdstr srctop_file bldtop_dir/;
use OpenSSL::Test::Utils;
use TLSProxy::Proxy;
use File::Temp qw(tempfile);

use constant {
    LOOK_ONLY => 0,
    EMPTY_EXTENSION => 1,
    MISSING_EXTENSION => 2,
    NO_ACCEPTABLE_KEY_SHARES => 3,
    NON_PREFERRED_KEY_SHARE => 4,
    ACCEPTABLE_AT_END => 5,
    NOT_IN_SUPPORTED_GROUPS => 6,
    GROUP_ID_TOO_SHORT => 7,
    KEX_LEN_MISMATCH => 8,
    ZERO_LEN_KEX_DATA => 9,
    TRAILING_DATA => 10,
    SELECT_X25519 => 11
};

use constant {
    CLIENT_TO_SERVER => 1,
    SERVER_TO_CLIENT => 2
};


use constant {
    X25519 => 0x1d,
    P_256 => 0x17
};

my $testtype;
my $direction;
my $selectedgroupid;

my $test_name = "test_key_share";
setup($test_name);

plan skip_all => "TLSProxy isn't usable on $^O"
    if $^O =~ /^(VMS|MSWin32)$/;

plan skip_all => "$test_name needs the dynamic engine feature enabled"
    if disabled("engine") || disabled("dynamic-engine");

plan skip_all => "$test_name needs the sock feature enabled"
    if disabled("sock");

plan skip_all => "$test_name needs TLS1.3 enabled"
    if disabled("tls1_3");

$ENV{OPENSSL_ia32cap} = '~0x200000200000000';

my $proxy = TLSProxy::Proxy->new(
    undef,
    cmdstr(app(["openssl"]), display => 1),
    srctop_file("apps", "server.pem"),
    (!$ENV{HARNESS_ACTIVE} || $ENV{HARNESS_VERBOSE})
);

#We assume that test_ssl_new and friends will test the happy path for this,
#so we concentrate on the less common scenarios

#Test 1: An empty key_shares extension should not succeed
$testtype = EMPTY_EXTENSION;
$direction = CLIENT_TO_SERVER;
$proxy->filter(\&modify_key_shares_filter);
$proxy->start() or plan skip_all => "Unable to start up Proxy for tests";
plan tests => 17;
#TODO(TLS1.3): Actually this should succeed after a HelloRetryRequest - but
#we've not implemented that yet, so for now we look for a fail
ok(TLSProxy::Message->fail(), "Empty key_shares");

#Test 2: A missing key_shares extension should not succeed
$proxy->clear();
$testtype = MISSING_EXTENSION;
$proxy->start();
#TODO(TLS1.3): As above this should really succeed after a HelloRetryRequest,
#but we look for fail for now
ok(TLSProxy::Message->fail(), "Missing key_shares extension");

#Test 3: No acceptable key_shares should fail
$proxy->clear();
$testtype = NO_ACCEPTABLE_KEY_SHARES;
$proxy->start();
#TODO(TLS1.3): Again this should go around the loop of a HelloRetryRequest but
#we fail for now
ok(TLSProxy::Message->fail(), "No acceptable key_shares");

#Test 4: A non preferred but acceptable key_share should succeed
$proxy->clear();
$proxy->filter(undef);
$proxy->clientflags("-curves P-256");
$proxy->start();
ok(TLSProxy::Message->success(), "Non preferred key_share");
$proxy->filter(\&modify_key_shares_filter);

#Test 5: An acceptable key_share after a list of non-acceptable ones should
#succeed
$proxy->clear();
$testtype = ACCEPTABLE_AT_END;
$proxy->start();
ok(TLSProxy::Message->success(), "Acceptable key_share at end of list");

#Test 6: An acceptable key_share but for a group not in supported_groups should
#fail
$proxy->clear();
$testtype = NOT_IN_SUPPORTED_GROUPS;
$proxy->start();
ok(TLSProxy::Message->fail(), "Acceptable key_share not in supported_groups");

#Test 7: Too short group_id should fail
$proxy->clear();
$testtype = GROUP_ID_TOO_SHORT;
$proxy->start();
ok(TLSProxy::Message->fail(), "Group id too short");

#Test 8: key_exchange length mismatch should fail
$proxy->clear();
$testtype = KEX_LEN_MISMATCH;
$proxy->start();
ok(TLSProxy::Message->fail(), "key_exchange length mismatch");

#Test 9: Zero length key_exchange should fail
$proxy->clear();
$testtype = ZERO_LEN_KEX_DATA;
$proxy->start();
ok(TLSProxy::Message->fail(), "zero length key_exchange data");

#Test 10: Trailing data on key_share list should fail
$proxy->clear();
$testtype = TRAILING_DATA;
$proxy->start();
ok(TLSProxy::Message->fail(), "key_share list trailing data");

#Test 11: Multiple acceptable key_shares - we choose the first one
$proxy->clear();
$direction = SERVER_TO_CLIENT;
$testtype = LOOK_ONLY;
$proxy->clientflags("-curves P-256:X25519");
$proxy->start();
ok(TLSProxy::Message->success() && ($selectedgroupid == P_256),
   "Multiple acceptable key_shares");

#Test 12: Multiple acceptable key_shares - we choose the first one (part 2)
$proxy->clear();
$proxy->clientflags("-curves X25519:P-256");
$proxy->start();
ok(TLSProxy::Message->success() && ($selectedgroupid == X25519),
   "Multiple acceptable key_shares (part 2)");

#Test 13: Server sends key_share that wasn't offerred should fail
$proxy->clear();
$testtype = SELECT_X25519;
$proxy->clientflags("-curves P-256");
$proxy->start();
ok(TLSProxy::Message->fail(), "Non offered key_share");

#Test 14: Too short group_id in ServerHello should fail
$proxy->clear();
$testtype = GROUP_ID_TOO_SHORT;
$proxy->start();
ok(TLSProxy::Message->fail(), "Group id too short in ServerHello");

#Test 15: key_exchange length mismatch in ServerHello should fail
$proxy->clear();
$testtype = KEX_LEN_MISMATCH;
$proxy->start();
ok(TLSProxy::Message->fail(), "key_exchange length mismatch in ServerHello");

#Test 16: Zero length key_exchange in ServerHello should fail
$proxy->clear();
$testtype = ZERO_LEN_KEX_DATA;
$proxy->start();
ok(TLSProxy::Message->fail(), "zero length key_exchange data in ServerHello");

#Test 17: Trailing data on key_share in ServerHello should fail
$proxy->clear();
$testtype = TRAILING_DATA;
$proxy->start();
ok(TLSProxy::Message->fail(), "key_share trailing data in ServerHello");


sub modify_key_shares_filter
{
    my $proxy = shift;

    # We're only interested in the initial ClientHello
    if (($direction == CLIENT_TO_SERVER && $proxy->flight != 0)
            || ($direction == SERVER_TO_CLIENT && $proxy->flight != 1)) {
        return;
    }

    foreach my $message (@{$proxy->message_list}) {
        if ($message->mt == TLSProxy::Message::MT_CLIENT_HELLO
                && $direction == CLIENT_TO_SERVER) {
            my $ext;
            my $suppgroups;

            #Setup supported groups to include some unrecognised groups
            $suppgroups = pack "C8",
                0x00, 0x06, #List Length
                0xff, 0xfe, #Non existing group 1
                0xff, 0xff, #Non existing group 2
                0x00, 0x1d; #x25519

            if ($testtype == EMPTY_EXTENSION) {
                $ext = pack "C2",
                    0x00, 0x00;
            } elsif ($testtype == NO_ACCEPTABLE_KEY_SHARES) {
                $ext = pack "C12",
                    0x00, 0x0a, #List Length
                    0xff, 0xfe, #Non existing group 1
                    0x00, 0x01, 0xff, #key_exchange data
                    0xff, 0xff, #Non existing group 2
                    0x00, 0x01, 0xff; #key_exchange data
            } elsif ($testtype == ACCEPTABLE_AT_END) {
                $ext = pack "C11H64",
                    0x00, 0x29, #List Length
                    0xff, 0xfe, #Non existing group 1
                    0x00, 0x01, 0xff, #key_exchange data
                    0x00, 0x1d, #x25519
                    0x00, 0x20, #key_exchange data length
                    "155155B95269ED5C87EAA99C2EF5A593".
                    "EDF83495E80380089F831B94D14B1421";  #key_exchange data
            } elsif ($testtype == NOT_IN_SUPPORTED_GROUPS) {
                $suppgroups = pack "C4",
                    0x00, 0x02, #List Length
                    0x00, 0xfe; #Non existing group 1
            } elsif ($testtype == GROUP_ID_TOO_SHORT) {
                $ext = pack "C6H64C1",
                    0x00, 0x25, #List Length
                    0x00, 0x1d, #x25519
                    0x00, 0x20, #key_exchange data length
                    "155155B95269ED5C87EAA99C2EF5A593".
                    "EDF83495E80380089F831B94D14B1421";  #key_exchange data
                    0x00;       #Group id too short
            } elsif ($testtype == KEX_LEN_MISMATCH) {
                $ext = pack "C8",
                    0x00, 0x06, #List Length
                    0x00, 0x1d, #x25519
                    0x00, 0x20, #key_exchange data length
                    0x15, 0x51; #Only two bytes of data, but length should be 32
            } elsif ($testtype == ZERO_LEN_KEX_DATA) {
                $ext = pack "C10H64",
                    0x00, 0x28, #List Length
                    0xff, 0xfe, #Non existing group 1
                    0x00, 0x00, #zero length key_exchange data is invalid
                    0x00, 0x1d, #x25519
                    0x00, 0x20, #key_exchange data length
                    "155155B95269ED5C87EAA99C2EF5A593".
                    "EDF83495E80380089F831B94D14B1421";  #key_exchange data
            } elsif ($testtype == TRAILING_DATA) {
                $ext = pack "C6H64C1",
                    0x00, 0x24, #List Length
                    0x00, 0x1d, #x25519
                    0x00, 0x20, #key_exchange data length
                    "155155B95269ED5C87EAA99C2EF5A593".
                    "EDF83495E80380089F831B94D14B1421", #key_exchange data
                    0x00; #Trailing garbage
            }

            $message->set_extension(
                TLSProxy::Message::EXT_SUPPORTED_GROUPS, $suppgroups);

            if ($testtype == MISSING_EXTENSION) {
                $message->delete_extension(
                    TLSProxy::Message::EXT_KEY_SHARE);
            } elsif ($testtype != NOT_IN_SUPPORTED_GROUPS) {
                $message->set_extension(
                    TLSProxy::Message::EXT_KEY_SHARE, $ext);
            }

            $message->repack();
        } elsif ($message->mt == TLSProxy::Message::MT_SERVER_HELLO
                     && $direction == SERVER_TO_CLIENT) {
            my $ext;
            my $key_share =
                ${$message->extension_data}{TLSProxy::Message::EXT_KEY_SHARE};
            $selectedgroupid = unpack("n", $key_share);

            if ($testtype == LOOK_ONLY) {
                return;
            }
            if ($testtype == SELECT_X25519) {
                $ext = pack "C4H64",
                    0x00, 0x1d, #x25519
                    0x00, 0x20, #key_exchange data length
                    "155155B95269ED5C87EAA99C2EF5A593".
                    "EDF83495E80380089F831B94D14B1421";  #key_exchange data
            } elsif ($testtype == GROUP_ID_TOO_SHORT) {
                $ext = pack "C1",
                    0x00;
            } elsif ($testtype == KEX_LEN_MISMATCH) {
                $ext = pack "C6",
                    0x00, 0x1d, #x25519
                    0x00, 0x20, #key_exchange data length
                    0x15, 0x51; #Only two bytes of data, but length should be 32
            } elsif ($testtype == ZERO_LEN_KEX_DATA) {
                $ext = pack "C4",
                    0x00, 0x1d, #x25519
                    0x00, 0x00, #zero length key_exchange data is invalid
            } elsif ($testtype == TRAILING_DATA) {
                $ext = pack "C4H64C1",
                    0x00, 0x1d, #x25519
                    0x00, 0x20, #key_exchange data length
                    "155155B95269ED5C87EAA99C2EF5A593".
                    "EDF83495E80380089F831B94D14B1421", #key_exchange data
                    0x00; #Trailing garbage
            }
            $message->set_extension( TLSProxy::Message::EXT_KEY_SHARE, $ext);

            $message->repack();
        }
    }
}


