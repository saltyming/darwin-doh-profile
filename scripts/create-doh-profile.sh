#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
TEMPLATE_PATH="${TEMPLATE_PATH:-$ROOT_DIR/templates/doh-profile.mobileconfig.tpl}"
DEFAULT_OUTPUT_DIR="$ROOT_DIR/out"

PROFILE_NAME=""
PROFILE_IDENTIFIER=""
ORGANIZATION=""
SERVER_URL=""
OUTPUT_DIR=""
SIGN_CERTIFICATE=""
UNSIGNED_ONLY=0
NON_INTERACTIVE=0
ALLOW_FAILOVER="omit"
PROHIBIT_DISABLEMENT="omit"
SERVER_ADDRESSES=""
MATCH_DOMAINS=""
PAYLOAD_CERTIFICATE_UUID=""

usage() {
	cat <<'USAGE'
Usage: create-doh-profile.sh [options]

Creates an iOS/macOS .mobileconfig profile for a custom DNS-over-HTTPS resolver.

Required in non-interactive mode:
  --url URL                    DoH URI template, for example https://dns.example.com/dns-query

Common options:
  --name NAME                  Profile display name
  --identifier IDENTIFIER      Reverse-DNS profile identifier, for example com.example.doh
  --organization NAME          PayloadOrganization value
  --output-dir DIR             Output directory; default: ./out
  --sign CERTIFICATE_NAME      Sign with a macOS Keychain certificate via security cms
  --unsigned                   Do not sign
  --non-interactive            Fail instead of prompting for missing required values

Advanced DNSSettings options:
  --allow-failover true|false|omit
  --server-addresses CSV       Optional resolver IP address strings
  --match-domains CSV          Optional domains; if set, DNS applies only to matching domains
  --prohibit-disablement true|false|omit
  --payload-certificate-uuid UUID

USAGE
}

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

prompt() {
	local label="$1"
	local default_value="${2:-}"
	local value
	if [ -n "$default_value" ]; then
		printf '%s [%s]: ' "$label" "$default_value" >&2
	else
		printf '%s: ' "$label" >&2
	fi
	IFS= read -r value
	if [ -z "$value" ]; then
		printf '%s' "$default_value"
	else
		printf '%s' "$value"
	fi
}

prompt_yes_no() {
	local label="$1"
	local default_value="$2"
	local value
	while :; do
		value=$(prompt "$label" "$default_value")
		case "$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')" in
			y|yes) return 0 ;;
			n|no) return 1 ;;
			*) printf 'Please answer yes or no.\n' >&2 ;;
		esac
	done
}

xml_escape() {
	printf '%s' "$1" \
		| sed \
			-e 's/&/\&amp;/g' \
			-e 's/</\&lt;/g' \
			-e 's/>/\&gt;/g' \
			-e 's/"/\&quot;/g' \
			-e "s/'/\&apos;/g"
}

slugify() {
	printf '%s' "$1" \
		| tr '[:upper:]' '[:lower:]' \
		| sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g'
}

validate_identifier() {
	local value="$1"
	[ -n "$value" ] || die "identifier is required"
	case "$value" in
		*..*|.*|*.) die "identifier must be reverse-DNS-like without empty segments: $value" ;;
	esac
	printf '%s' "$value" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$' \
		|| die "identifier may only contain letters, numbers, dots, and hyphens: $value"
	printf '%s' "$value" | grep -Eq '\.' \
		|| die "identifier should contain at least one dot: $value"
}

validate_url() {
	local value="$1"
	local rest authority path
	[ -n "$value" ] || die "DoH URL is required"
	case "$value" in
		https://*) ;;
		*) die "DoH URL must use https://: $value" ;;
	esac
	case "$value" in
		*' '*|*'	'*|*'#'*) die "DoH URL must not contain whitespace or fragments: $value" ;;
	esac
	rest="${value#https://}"
	authority="${rest%%/*}"
	[ -n "$authority" ] || die "DoH URL must include a host"
	case "$authority" in
		*@*|:*|*:*:*) die "DoH URL authority is invalid: $authority" ;;
	esac
	if [ "$rest" = "$authority" ]; then
		die "DoH URL must include a path, for example /dns-query"
	fi
	path="/${rest#*/}"
	[ "$path" != "/" ] || die "DoH URL path must not be empty"
}

normalize_optional_bool() {
	local value="$1"
	local key="$2"
	case "$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')" in
		""|omit|none|skip) printf 'omit' ;;
		true|yes|y|1) printf 'true' ;;
		false|no|n|0) printf 'false' ;;
		*) die "$key must be true, false, or omit" ;;
	esac
}

validate_uuid() {
	local value="$1"
	local key="$2"
	[ -z "$value" ] && return 0
	printf '%s' "$value" | grep -Eiq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' \
		|| die "$key must be a UUID: $value"
}

trim() {
	printf '%s' "$1" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
}

validate_ipv4() {
	local value="$1"
	local IFS=.
	local a b c d extra
	set -- $value
	a="${1:-}"; b="${2:-}"; c="${3:-}"; d="${4:-}"; extra="${5:-}"
	[ -z "$extra" ] || return 1
	for part in "$a" "$b" "$c" "$d"; do
		printf '%s' "$part" | grep -Eq '^[0-9]{1,3}$' || return 1
		[ "$part" -le 255 ] || return 1
	done
	return 0
}

validate_ip_string() {
	local value="$1"
	[ -n "$value" ] || die "empty ServerAddresses entry"
	if printf '%s' "$value" | grep -q ':'; then
		printf '%s' "$value" | grep -Eq '^[0-9A-Fa-f:.%]+$' \
			|| die "invalid IPv6 address string: $value"
		printf '%s' "$value" | grep -Eq ':' \
			|| die "invalid IPv6 address string: $value"
	else
		validate_ipv4 "$value" || die "invalid IPv4 address string: $value"
	fi
}

validate_domain() {
	local value="$1"
	local stripped label old_ifs
	[ -n "$value" ] || die "empty domain entry"
	stripped="$value"
	case "$stripped" in
		*' '*|*'	'*) die "domain must not contain whitespace: $value" ;;
		\\*.*) die "domain wildcard must be written as *.example.com: $value" ;;
	esac
	case "$stripped" in
		*.) stripped="${stripped%.}" ;;
	esac
	case "$stripped" in
		"*."*) stripped="${stripped#*.}" ;;
	esac
	[ -n "$stripped" ] || die "domain is invalid: $value"
	old_ifs="$IFS"
	IFS=.
	for label in $stripped; do
		IFS="$old_ifs"
		printf '%s' "$label" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$' \
			|| die "domain label is invalid in $value"
		IFS=.
	done
	IFS="$old_ifs"
}

for arg in "$@"; do
	case "$arg" in
		--help|-h) usage; exit 0 ;;
	esac
done

while [ "$#" -gt 0 ]; do
	case "$1" in
		--url) SERVER_URL="${2:-}"; shift 2 ;;
		--name) PROFILE_NAME="${2:-}"; shift 2 ;;
		--identifier) PROFILE_IDENTIFIER="${2:-}"; shift 2 ;;
		--organization) ORGANIZATION="${2:-}"; shift 2 ;;
		--output-dir) OUTPUT_DIR="${2:-}"; shift 2 ;;
		--sign) SIGN_CERTIFICATE="${2:-}"; shift 2 ;;
		--unsigned) UNSIGNED_ONLY=1; shift ;;
		--non-interactive) NON_INTERACTIVE=1; shift ;;
		--allow-failover) ALLOW_FAILOVER="${2:-}"; shift 2 ;;
		--server-addresses) SERVER_ADDRESSES="${2:-}"; shift 2 ;;
		--match-domains) MATCH_DOMAINS="${2:-}"; shift 2 ;;
		--prohibit-disablement) PROHIBIT_DISABLEMENT="${2:-}"; shift 2 ;;
		--payload-certificate-uuid) PAYLOAD_CERTIFICATE_UUID="${2:-}"; shift 2 ;;
		*) die "unknown option: $1" ;;
	esac
done

[ "$UNSIGNED_ONLY" -eq 0 ] || [ -z "$SIGN_CERTIFICATE" ] || die "--unsigned and --sign cannot be used together"

need_cmd uuidgen
need_cmd plutil
[ -f "$TEMPLATE_PATH" ] || die "template not found: $TEMPLATE_PATH"

if [ "$NON_INTERACTIVE" -eq 0 ]; then
	[ -n "$SERVER_URL" ] || SERVER_URL=$(prompt "DoH URL" "https://dns.example.com/dns-query")
	[ -n "$PROFILE_NAME" ] || PROFILE_NAME=$(prompt "Profile name" "Custom DoH")
	default_slug=$(slugify "$PROFILE_NAME")
	[ -n "$default_slug" ] || default_slug="custom-doh"
	[ -n "$PROFILE_IDENTIFIER" ] || PROFILE_IDENTIFIER=$(prompt "Profile identifier" "local.doh.$default_slug")
	[ -n "$ORGANIZATION" ] || ORGANIZATION=$(prompt "Organization" "Personal")
	[ -n "$OUTPUT_DIR" ] || OUTPUT_DIR=$(prompt "Output directory" "$DEFAULT_OUTPUT_DIR")

	if prompt_yes_no "Configure advanced DNSSettings options? (y/N)" "n"; then
		ALLOW_FAILOVER=$(prompt "AllowFailover (true/false/omit)" "$ALLOW_FAILOVER")
		SERVER_ADDRESSES=$(prompt "ServerAddresses, comma separated IPs (blank to omit)" "$SERVER_ADDRESSES")
		MATCH_DOMAINS=$(prompt "SupplementalMatchDomains, comma separated domains (blank for all domains)" "$MATCH_DOMAINS")
		PROHIBIT_DISABLEMENT=$(prompt "ProhibitDisablement (true/false/omit)" "$PROHIBIT_DISABLEMENT")
		PAYLOAD_CERTIFICATE_UUID=$(prompt "PayloadCertificateUUID (blank to omit)" "$PAYLOAD_CERTIFICATE_UUID")
	fi

	if [ "$UNSIGNED_ONLY" -eq 0 ] && [ -z "$SIGN_CERTIFICATE" ]; then
		if prompt_yes_no "Sign profile with a Keychain certificate? (y/N)" "n"; then
			SIGN_CERTIFICATE=$(prompt "Certificate name" "")
		fi
	fi
fi

[ -n "$SERVER_URL" ] || die "--url is required in non-interactive mode"
[ -n "$PROFILE_NAME" ] || PROFILE_NAME="Custom DoH"
[ -n "$PROFILE_IDENTIFIER" ] || PROFILE_IDENTIFIER="local.doh.$(slugify "$PROFILE_NAME")"
[ -n "$ORGANIZATION" ] || ORGANIZATION="Personal"
[ -n "$OUTPUT_DIR" ] || OUTPUT_DIR="$DEFAULT_OUTPUT_DIR"

validate_url "$SERVER_URL"
validate_identifier "$PROFILE_IDENTIFIER"
ALLOW_FAILOVER=$(normalize_optional_bool "$ALLOW_FAILOVER" "AllowFailover")
PROHIBIT_DISABLEMENT=$(normalize_optional_bool "$PROHIBIT_DISABLEMENT" "ProhibitDisablement")
validate_uuid "$PAYLOAD_CERTIFICATE_UUID" "PayloadCertificateUUID"

optional_dns_settings=""
if [ "$ALLOW_FAILOVER" != "omit" ]; then
	optional_dns_settings="${optional_dns_settings}
				<key>AllowFailover</key>
				<$ALLOW_FAILOVER/>"
fi

if [ -n "$SERVER_ADDRESSES" ]; then
	optional_dns_settings="${optional_dns_settings}
				<key>ServerAddresses</key>
				<array>"
	old_ifs="$IFS"
	IFS=,
	for raw_entry in $SERVER_ADDRESSES; do
		IFS="$old_ifs"
		entry=$(trim "$raw_entry")
		validate_ip_string "$entry"
		optional_dns_settings="${optional_dns_settings}
					<string>$(xml_escape "$entry")</string>"
		IFS=,
	done
	IFS="$old_ifs"
	optional_dns_settings="${optional_dns_settings}
				</array>"
fi

if [ -n "$MATCH_DOMAINS" ]; then
	optional_dns_settings="${optional_dns_settings}
				<key>SupplementalMatchDomains</key>
				<array>"
	old_ifs="$IFS"
	IFS=,
	for raw_entry in $MATCH_DOMAINS; do
		IFS="$old_ifs"
		entry=$(trim "$raw_entry")
		validate_domain "$entry"
		optional_dns_settings="${optional_dns_settings}
					<string>$(xml_escape "$entry")</string>"
		IFS=,
	done
	IFS="$old_ifs"
	optional_dns_settings="${optional_dns_settings}
				</array>"
fi

if [ "$PROHIBIT_DISABLEMENT" != "omit" ]; then
	optional_dns_settings="${optional_dns_settings}
				<key>ProhibitDisablement</key>
				<$PROHIBIT_DISABLEMENT/>"
fi

if [ -n "$PAYLOAD_CERTIFICATE_UUID" ]; then
	optional_dns_settings="${optional_dns_settings}
				<key>PayloadCertificateUUID</key>
				<string>$(xml_escape "$PAYLOAD_CERTIFICATE_UUID")</string>"
fi

profile_uuid=$(uuidgen)
payload_uuid=$(uuidgen)
payload_identifier="$PROFILE_IDENTIFIER.dns"
safe_name=$(slugify "$PROFILE_NAME")
[ -n "$safe_name" ] || safe_name="doh-profile"
unsigned_path="$OUTPUT_DIR/$safe_name.mobileconfig"
signed_path="$OUTPUT_DIR/$safe_name.signed.mobileconfig"

mkdir -p "$OUTPUT_DIR"

content=$(cat "$TEMPLATE_PATH")
content=${content//__SERVER_URL__/$(xml_escape "$SERVER_URL")}
content=${content//__OPTIONAL_DNS_SETTINGS__/$optional_dns_settings}
content=${content//__PAYLOAD_DISPLAY_NAME__/$(xml_escape "$PROFILE_NAME")}
content=${content//__PAYLOAD_IDENTIFIER__/$(xml_escape "$payload_identifier")}
content=${content//__PAYLOAD_UUID__/$payload_uuid}
content=${content//__PROFILE_DISPLAY_NAME__/$(xml_escape "$PROFILE_NAME")}
content=${content//__PROFILE_IDENTIFIER__/$(xml_escape "$PROFILE_IDENTIFIER")}
content=${content//__ORGANIZATION__/$(xml_escape "$ORGANIZATION")}
content=${content//__PROFILE_UUID__/$profile_uuid}

printf '%s\n' "$content" > "$unsigned_path"
plutil -lint "$unsigned_path" >/dev/null

printf 'Created unsigned profile: %s\n' "$unsigned_path"

if [ -n "$SIGN_CERTIFICATE" ]; then
	need_cmd security
	if ! security cms -S -N "$SIGN_CERTIFICATE" -H SHA256 -i "$unsigned_path" -o "$signed_path"; then
		printf 'Unsigned profile was kept at: %s\n' "$unsigned_path" >&2
		die "failed to sign profile with Keychain certificate: $SIGN_CERTIFICATE"
	fi
	printf 'Created signed profile: %s\n' "$signed_path"
fi
