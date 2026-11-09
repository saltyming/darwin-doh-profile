#!/bin/bash
set -euo pipefail

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT="$ROOT_DIR/scripts/create-doh-profile.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/darwin-doh-profile-tests.XXXXXX")

cleanup() {
	rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

assert_eq() {
	local expected="$1"
	local actual="$2"
	local label="$3"
	[ "$expected" = "$actual" ] || fail "$label: expected '$expected', got '$actual'"
}

assert_file() {
	[ -f "$1" ] || fail "expected file to exist: $1"
}

extract_raw() {
	plutil -extract "$1" raw "$2"
}

run_basic_generation_test() {
	local out_dir="$TMP_ROOT/basic"
	local profile="$out_dir/team-lab-doh.mobileconfig"

	"$SCRIPT" \
		--non-interactive \
		--url "https://dns.example.com/dns-query" \
		--name "Team & Lab <DoH>" \
		--identifier "com.example.doh.team-lab" \
		--organization "Example & Co" \
		--output-dir "$out_dir" \
		--unsigned >/dev/null

	assert_file "$profile"
	plutil -lint "$profile" >/dev/null
	assert_eq "Team & Lab <DoH>" "$(extract_raw PayloadDisplayName "$profile")" "profile display name"
	assert_eq "Example & Co" "$(extract_raw PayloadOrganization "$profile")" "organization"
	assert_eq "com.apple.dnsSettings.managed" "$(extract_raw PayloadContent.0.PayloadType "$profile")" "payload type"
	assert_eq "HTTPS" "$(extract_raw PayloadContent.0.DNSSettings.DNSProtocol "$profile")" "DNSProtocol"
	assert_eq "https://dns.example.com/dns-query" "$(extract_raw PayloadContent.0.DNSSettings.ServerURL "$profile")" "ServerURL"
	[ ! -f "$out_dir/team-lab-doh.signed.mobileconfig" ] || fail "signed profile should not be created by --unsigned"
}

run_advanced_options_test() {
	local out_dir="$TMP_ROOT/advanced"
	local profile="$out_dir/advanced-doh.mobileconfig"
	local cert_uuid="7F40E2EA-7D16-45D4-84DB-A5D14D6D9205"

	"$SCRIPT" \
		--non-interactive \
		--url "https://dns.example.com/dns-query{?dns}" \
		--name "Advanced DoH" \
		--identifier "com.example.doh.advanced" \
		--organization "Example" \
		--output-dir "$out_dir" \
		--allow-failover true \
		--server-addresses "192.0.2.53,2001:db8::53" \
		--match-domains "example.com,*.corp.example.com" \
		--prohibit-disablement false \
		--payload-certificate-uuid "$cert_uuid" \
		--unsigned >/dev/null

	assert_file "$profile"
	plutil -lint "$profile" >/dev/null
	assert_eq "true" "$(extract_raw PayloadContent.0.DNSSettings.AllowFailover "$profile")" "AllowFailover"
	assert_eq "192.0.2.53" "$(extract_raw PayloadContent.0.DNSSettings.ServerAddresses.0 "$profile")" "first ServerAddresses entry"
	assert_eq "2001:db8::53" "$(extract_raw PayloadContent.0.DNSSettings.ServerAddresses.1 "$profile")" "second ServerAddresses entry"
	assert_eq "example.com" "$(extract_raw PayloadContent.0.DNSSettings.SupplementalMatchDomains.0 "$profile")" "first SupplementalMatchDomains entry"
	assert_eq "*.corp.example.com" "$(extract_raw PayloadContent.0.DNSSettings.SupplementalMatchDomains.1 "$profile")" "second SupplementalMatchDomains entry"
	assert_eq "false" "$(extract_raw PayloadContent.0.ProhibitDisablement "$profile")" "ProhibitDisablement"
	assert_eq "$cert_uuid" "$(extract_raw PayloadContent.0.DNSSettings.PayloadCertificateUUID "$profile")" "PayloadCertificateUUID"
}

run_interactive_generation_test() {
	local out_dir="$TMP_ROOT/interactive"
	local profile="$out_dir/interactive-doh.mobileconfig"

	printf '%s\n' \
		"https://dns.example.com/dns-query" \
		"Interactive DoH" \
		"com.example.doh.interactive" \
		"Interactive Org" \
		"$out_dir" \
		"y" \
		"true" \
		"192.0.2.54" \
		"" \
		"" \
		"omit" \
		"" \
		"n" \
		| "$SCRIPT" >/dev/null 2>&1

	assert_file "$profile"
	plutil -lint "$profile" >/dev/null
	assert_eq "Interactive DoH" "$(extract_raw PayloadDisplayName "$profile")" "interactive profile display name"
	assert_eq "Interactive Org" "$(extract_raw PayloadOrganization "$profile")" "interactive organization"
	assert_eq "true" "$(extract_raw PayloadContent.0.DNSSettings.AllowFailover "$profile")" "interactive AllowFailover"
	assert_eq "192.0.2.54" "$(extract_raw PayloadContent.0.DNSSettings.ServerAddresses.0 "$profile")" "interactive ServerAddresses entry"
}

run_invalid_url_test() {
	local out_dir="$TMP_ROOT/invalid-url"
	if "$SCRIPT" --non-interactive --url "http://dns.example.com/dns-query" --output-dir "$out_dir" --unsigned >/dev/null 2>&1; then
		fail "invalid URL should fail"
	fi
}

run_invalid_identifier_test() {
	local out_dir="$TMP_ROOT/invalid-identifier"
	if "$SCRIPT" --non-interactive --url "https://dns.example.com/dns-query" --identifier "not valid" --output-dir "$out_dir" --unsigned >/dev/null 2>&1; then
		fail "invalid identifier should fail"
	fi
}

run_invalid_advanced_test() {
	local out_dir="$TMP_ROOT/invalid-advanced"
	if "$SCRIPT" --non-interactive --url "https://dns.example.com/dns-query" --allow-failover maybe --output-dir "$out_dir" --unsigned >/dev/null 2>&1; then
		fail "invalid optional boolean should fail"
	fi
	if "$SCRIPT" --non-interactive --url "https://dns.example.com/dns-query" --server-addresses "999.0.0.1" --output-dir "$out_dir" --unsigned >/dev/null 2>&1; then
		fail "invalid IPv4 server address should fail"
	fi
}

run_basic_generation_test
run_advanced_options_test
run_interactive_generation_test
run_invalid_url_test
run_invalid_identifier_test
run_invalid_advanced_test

printf 'All tests passed.\n'
