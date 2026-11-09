# Darwin DoH Profile Generator

Generate iOS, iPadOS, macOS, and visionOS configuration profiles for a custom
DNS-over-HTTPS resolver. The main use case is a private resolver such as
Technitium DNS Server, where the user already owns the DoH endpoint and needs a
valid `.mobileconfig` file.

The generated profile uses Apple's `com.apple.dnsSettings.managed` payload with
`DNSProtocol` set to `HTTPS` and `ServerURL` set to the URL you provide.

## Quick Start

Run the interactive generator:

```sh
scripts/create-doh-profile.sh
```

For a Technitium-style endpoint, enter the full HTTPS DoH URL:

```text
https://dns.example.com/dns-query
```

By default the script writes an unsigned profile to `out/`. It does not install
the profile and it does not make a network request to the resolver.

## Non-Interactive Usage

```sh
scripts/create-doh-profile.sh \
  --non-interactive \
  --url https://dns.example.com/dns-query \
  --name "Home DoH" \
  --identifier "com.example.doh.home" \
  --organization "Example"
```

## Advanced DNSSettings Options

The default profile applies the DoH resolver to all DNS queries. Optional Apple
`DNSSettings` keys can be injected either through the interactive advanced
prompt or through flags:

```sh
scripts/create-doh-profile.sh \
  --non-interactive \
  --url https://dns.example.com/dns-query \
  --name "Home DoH" \
  --identifier "com.example.doh.home" \
  --allow-failover true \
  --server-addresses "192.0.2.53,2001:db8::53" \
  --match-domains "example.com,*.corp.example.com" \
  --prohibit-disablement false
```

Supported advanced keys:

- `AllowFailover`: lets the device fall back to the default system DNS resolver.
  Apple marks this key available on iOS 26, iPadOS 26, macOS 26, and visionOS 26
  or later.
- `ServerAddresses`: optional resolver IP address strings.
- `SupplementalMatchDomains`: optional domain strings. When present, DNS
  settings apply only to matching domains; leave it unset for full-device DNS.
- `--exclude-domains`: optional domain strings that never use this resolver.
  The profile gets one `OnDemandRules` entry (`EvaluateConnection` with
  `NeverConnect` for these domains), so queries for them go to the system's
  other resolvers, such as a VPN's, while every other name still uses DoH.
- `ProhibitDisablement`: prevents disabling DNS settings on supervised devices.
  It is a key of the payload itself, beside `DNSSettings`.
- `PayloadCertificateUUID`: references an identity certificate payload. Only set
  this when that certificate payload is available in the same deployment context.

## Signing

Unsigned profiles are useful for personal installation but may show trust
warnings. To sign with a certificate in the macOS Keychain:

```sh
scripts/create-doh-profile.sh \
  --non-interactive \
  --url https://dns.example.com/dns-query \
  --name "Home DoH" \
  --identifier "com.example.doh.home" \
  --sign "Developer ID Application: Example"
```

Signing uses:

```sh
security cms -S -N "<certificate name>" -H SHA256
```

If signing fails, the unsigned profile remains in the output directory and the
script exits with an error.

## Installing

On macOS, open the generated `.mobileconfig` file and approve it in System
Settings. On iOS or iPadOS, transfer the file to the device, open it, and approve
the downloaded profile in Settings.

When installed manually, Apple's DNS Settings payload can apply beyond managed
Wi-Fi. When installed through MDM, Apple documents different managed-network
behavior; confirm your MDM deployment policy before distributing at scale.

## Validation

The generator validates local structure only:

- DoH URL must use `https://`, include a host, and include a non-empty path.
- Profile identifiers must be reverse-DNS-like.
- Optional booleans must be `true`, `false`, or `omit`.
- Optional UUID fields must be UUIDs.
- The generated plist must pass `plutil -lint`.

The script intentionally does not probe the DoH server. Private resolvers,
split-horizon DNS, VPN-only endpoints, and development servers often reject
public network checks even when the profile is correct.

Run tests with:

```sh
tests/run.sh
```

## License

MIT License. Copyright (c) 2026 Hamin Sung.
