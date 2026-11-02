# Security

Luoto reads the clipboard and your screenshots, so we take reports seriously.

## Reporting a vulnerability

Please report it **privately** through [GitHub's private vulnerability reporting](https://github.com/amidamaru940/luoto/security/advisories/new), not in a public issue. Include the Luoto and macOS versions, what an attacker could do, and steps to reproduce.

You will get an answer within a week. Fixes go out in the next release, and you will be credited if you like.

## Supported versions

Only the latest release gets security fixes.

## What Luoto does by default

- No network requests and no listening ports. Every address in the code is listed in `tests/network_allowlist.txt`, and a test enforces it. Spotify and YouTube Music covers come from addresses the player gives, once you let Luoto use that player; the README's network table says so.
- Clipboard history lives in memory only, unless you turn on saving it.
- Concealed clipboard items (from password managers) and apps you exclude are never recorded.
- Nothing runs as root. The one exception is optional and described next.

## The lid-closed helper

**With the lid closed** in Keep Awake is off until you turn it on. System sleep can only be turned off as root, so turning it on installs a small helper, once, through macOS's own password dialog. Luoto never sees the password.

- **Where it lives.** A root-owned copy at `/Library/PrivilegedHelperTools/io.github.amidamaru940.luoto.lidguard`, started by launchd from `/Library/LaunchDaemons/io.github.amidamaru940.luoto.lidguard.plist`. Root never runs a file from the app bundle. In a release, the copy stays unreadable to other users until its signature is checked against the app's own certificate, and only then is it put in place.
- **What it does.** It runs `/usr/bin/pmset` with fixed arguments: `-a disablesleep 1`, `-a disablesleep 0` and `sleepnow`. To remove itself it also deletes its own files by name and runs `launchctl bootout` on itself. launchd starts it at boot and whenever the session folder changes; it checks, and with no session it exits at once, or within 30 seconds if the app's path has just gone missing.
- **How the app talks to it.** There is no socket, XPC or network code. During a session the app keeps replacing an empty file, `/Library/Application Support/Luoto/session/lease`. The helper only calls `lstat` on it: a regular file with a recent date means the session is alive. It also checks whether one of four fixed names exists there (`floor-10`, `floor-20`, `floor-30`, `floor-50`), which is how your chosen battery limit reaches it. It never opens or parses anything in that folder, and it does not delete it recursively.
- **What another program running as you could do, in a release.** Keep the Mac awake within the limits below, lower the battery limit as far as 10%, or make the helper remove itself. The helper gives it no way to root. A program that has already taken over your account could still show you a password dialog of its own, with any app; that is not specific to Luoto.
- **A build you sign ad-hoc yourself** has no certificate to check the helper against. Anyone who can change the app's files before you type the password could then run their code as root. Set the helper up only from a copy you trust. A running release refuses to set the helper up if the app on disk has been changed under it. That does not help if a re-signed copy is what you start next.
- **Limits.** From reading the kernel source (`IOPMrootDomain.cpp` in xnu), not from a test, the kernel skips its own low-battery and overheating sleep while sleep is off, so the helper enforces both itself: at the level you choose on battery (10, 20, 30 or 50%, 20% unless you change it; there is no "never"), if the battery cannot be read for 2 minutes, at once on critical heat, and after 2 minutes of serious heat. It then turns sleep back on and puts a Mac with a closed lid to sleep. These stops have been tested with simulated readings and a fake `pmset`, not on a real low battery or real overheating. If another tool had already turned sleep off, the helper leaves that setting alone, so these limits do not apply; the panel says so. A hung `pmset` is killed after 10 seconds, so it cannot stop these checks.
- **Failure.** If the app quits, crashes or hangs, the lease goes stale and the helper turns sleep back on within about a minute. It reads the setting back, and if sleep is still off it retries for about two minutes, then again at the next session, the next boot or the next start of Luoto. After a power cut it does the same at boot. If it is switched off in Login Items while running, launchd stops it and it turns sleep back on first. If it was dead when that happened, or could not turn sleep back on, Luoto says so at its next launch or when the session ends, and offers a fix that asks for the password. The panel says the lid can be closed only while the helper is alive and the setting reads back as on.
- **Removal.** **Remove Helper** in Settings needs no password. If the app is gone, the helper removes itself at the next restart. The README has the commands to do it by hand.
- **What Apple does not promise.** The `disablesleep` setting is not in the `pmset` manual, and a macOS update could change it. So Luoto says the lid can be closed only after reading the setting back from the system, and otherwise says that it can't.

## Known limitations

An internal security review on 30 October 2026 (not an independent audit) led to fixes in 1.1.12. These four items were left as they are, on purpose:

- **HTTPS is not required everywhere.** Some music players hand over plain `http` links to artwork and lyrics, and those would disappear. A network attacker could see or replace those pictures and lyrics.
- **The app is not notarized by Apple.** That needs a paid developer account. macOS asks you to confirm the first launch, and Apple has not scanned the build. Check the SHA-256 published with each release.
- **Library validation is off.** The signature carries `disable-library-validation`, because a self-signed certificate has no Apple team ID, and that check relies on one. So macOS does not check who signed the code Luoto loads. The hardened runtime stays on and `DYLD_*` variables stay blocked.
- **Two optional features have weaker protection.** LocalSend does not pin the other device's certificate, and third-party extensions talk over distributed notifications, which other local apps can see. Both are off by default.
