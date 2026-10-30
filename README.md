# DecryptIPA

An iPhone app that decrypts IPAs on a **remote jailbroken device** using
[londek/ipadecrypt](https://github.com/londek/ipadecrypt)'s on-device helper.

The app is the "computer" half of ipadecrypt's on-device path: it owns the
SSH/SFTP session, installs the target bundle with `appinst`, pushes the
ipadecrypt arm64 helper, streams the decrypted IPA back and verifies it — all
from the phone, no Mac or desktop in the loop.

```
DecryptIPA (this app) ──ssh/sftp──▶ jailbroken iPhone
        │                              │
        │  upload ipadecrypt-helper    │  task_for_pid + mach_vm_read
        │  appinst install <ipa>       │  per-image decryption
        │  helper decrypt <id> <path> -│  in-helper zip writer
        ◀──── IPA bytes on stdout ─────┘
```

## What it does

* **Device profiles** — host / port / user, password or OpenSSH ed25519 key
  (with passphrase), optional `sudo -S` mode for non-root logins.
* **Probe** — iOS version, model, `arm64`/`arm64e` (read from `launchd`'s
  cputype), jailbreak family from the live `/var/jb` symlink.
* **Tooling check** — locates `appinst` and AppSync Unified and reports what is
  missing before a job starts.
* **Helper push** — uploads the bundled `ipadecrypt-helper-arm64` to
  `/var/mobile/Media/ipadecrypt/helpers/ipadecrypt-helper-arm64-<sha12>.bin`
  (content-addressed, 0755) and reuses it on later jobs.
* **Install path** — reads `Payload/*.app/Info.plist` out of the IPA without
  unpacking it, optionally rewrites `MinimumOSVersion` / `UIDeviceFamily` and
  strips `Watch/`, uploads to `/var/mobile/Media/ipadecrypt/staging/`, runs
  `appinst`, then resolves the installed bundle by parsing every
  `Info.plist` under `/var/containers/Bundle/Application/`.
* **Decrypt** — `helper decrypt <bundle-id> <bundle-path> -`; stdout is the IPA
  byte stream, stderr carries the `@evt` event records which drive the live
  progress view (per-image decrypts, failures, packing).
* **Verify** — walks every Mach-O in the produced IPA, parses
  `LC_ENCRYPTION_INFO(_64)` and reports `cryptid != 0` leftovers.
* **Library** — outputs land in `Documents/Decrypted`, exposed through the
  Files app (`UIFileSharingEnabled`) and shareable from the Library tab.

Both input modes are supported:

| Mode | Needs | Notes |
| --- | --- | --- |
| **IPA file** | `appinst` + AppSync Unified | Installs the bundle, decrypts, optionally uninstalls afterwards. |
| **Installed app** | bundle id only | Decrypts an app that is already on the device. Nothing is uploaded. |

## Device requirements

Install from Sileo on the jailbroken device:

* **OpenSSH** — root login; the default `alpine` password is what most
  jailbreaks ship. Change it, then put the new one in the device profile.
* **AppSync Unified** — required for `appinst` to install unsigned bundles.
* **appinst** — `/usr/bin/appinst` or `/var/jb/usr/bin/appinst`.

Tested helper build: `ipadecrypt-helper-arm64` from ipadecrypt (signs itself
with `ldid -S helper/entitlements.plist`, so it carries
`task_for_pid-allow` / `platform-application`). It is embedded verbatim in the
app bundle as `ipadecrypt-helper-arm64`.

## Build

Unsigned IPA, built in CI (no Mac needed):

```
xcodegen generate
xcodebuild -project DecryptIPA.xcodeproj -scheme DecryptIPA \
  -configuration Release -sdk iphoneos \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

`.github/workflows/build.yml` does exactly that on `macos-15`, verifies the
helper is inside the `.app`, packages `Payload/` and uploads
`DecryptIPA-<version>-unsigned.ipa` as an artifact. Sign it with AltStore,
SideStore, zsign or TrollStore before installing.

Dependencies: [Citadel](https://github.com/orlandos-nl/Citadel) (SwiftNIO SSH
client + SFTP), [swift-crypto](https://github.com/apple/swift-crypto) (ed25519
key parsing, SHA-256 of the helper), and
[ZIPFoundation](https://github.com/weichsel/ZIPFoundation) (IPA inspection,
patching, verification).

## Verification

Two gates run in CI:

* `tools/logic-check` compiles the device-free logic (`MachO.swift`,
  `Events.swift`) into a command-line harness and asserts it against synthetic
  fixtures: `cryptid` in `LC_ENCRYPTION_INFO` / `LC_ENCRYPTION_INFO_64`, thin
  arm64 + armv7 + fat images, an encryption command that sits after a large
  `LC_SEGMENT_64`, version ordering (`1.2 < 1.10`), and `@evt` parsing with
  quoted messages. It caught two real defects before the first release: a
  64-bit header-offset assumption in the fixture and `Version("abc")`
  silently parsing as `0`.
* `ipa` builds the unsigned app, then fails the build unless
  `DecryptIPA.app/ipadecrypt-helper-arm64` exists, is a Mach-O, and the
  executable's `Info.plist` carries `CFBundleIdentifier` and
  `NSLocalNetworkUsageDescription`.

## Layout

```
Sources/DecryptIPA/
  App.swift            entry + tab shell
  Models.swift         device profile, probe, options, job phase, log entries
  Store.swift          devices.json + keychain secrets, Library index
  Keychain.swift       generic-password storage
  SSHTransport.swift   Citadel wrapper: connect, exec, streaming exec, SFTP
  DeviceService.swift  probe, appinst/AppSync lookup, helper push, install,
                       bundle resolution, helper streaming
  Events.swift         @evt record parser (shared with tools/logic-check)
  MachO.swift          LC_ENCRYPTION_INFO(_64) cryptid reader + version compare
  IPA.swift            metadata read, patch-for-install, cryptid verification,
                       Mach-O analyser, version compare
  DecryptEngine.swift  job pipeline + progress state
  DecryptView.swift    main screen
  DevicesView.swift    device list + editor with connection test
  LibraryView.swift    output browser
  Components.swift     log console and small views
Resources/ipadecrypt-helper-arm64
```

## Notes and limits

* Output IPAs are **unsigned and unencrypted**. Re-sign them before installing
  on a non-jailbroken device.
* The offline (credential-minting) path of ipadecrypt cannot run on iOS — it
  emulates the macOS App Store client. This app implements the on-device path
  only, which is the one that needs the jailbroken phone anyway.
* `--execs-only` host-side assembly is not used: decryption first writes the
  complete IPA through the helper's own zip writer, which needs no local
  re-packing and keeps the output layout identical to ipadecrypt's `decrypt`.
* Long jobs: keep the app in the foreground. iOS suspends background sockets
  unless you hold a background task; the SSH channel dies with the process.
* The sudo password is staged as a `0600` file under
  `/var/mobile/Media/ipadecrypt/` for the duration of a session and deleted on
  disconnect. Root logins skip sudo entirely.
