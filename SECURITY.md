# Security

Luoto reads the clipboard and your screenshots, so we take reports seriously.

## Reporting a vulnerability

Please report it **privately** through [GitHub's private vulnerability reporting](https://github.com/amidamaru940/luoto/security/advisories/new), not in a public issue. Include the Luoto and macOS versions, what an attacker could do, and steps to reproduce.

You will get an answer within a week. Fixes go out in the next release, and you will be credited if you like.

## Supported versions

Only the latest release gets security fixes.

## What Luoto does by default

- No network requests and no listening ports. Every address in the code is listed in `tests/network_allowlist.txt`, and a test enforces it.
- Clipboard history lives in memory only, unless you turn on saving it.
- Concealed clipboard items (from password managers) and apps you exclude are never recorded.

## Known limitations

A security audit on 30 October 2026 led to fixes in 1.1.12. These three items were left as they are, on purpose:

- **HTTPS is not required everywhere.** Some music players hand over plain `http` links to artwork and lyrics, and those would disappear. A network attacker could see or replace those pictures and lyrics.
- **The app is not notarized by Apple.** That needs a paid developer account. macOS asks you to confirm the first launch, and Apple has not scanned the build. Check the SHA-256 published with each release.
- **Two optional features have weaker protection.** LocalSend does not pin the other device's certificate, and third-party extensions talk over distributed notifications, which other local apps can see. Both are off by default.
