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
* **Modern workflow UI** — the Decrypt tab is a lightweight card-based
  `ScrollView` (device → source → progress → options → action), not a nested
  `Form`/`Section` tree. The action button is explicit about why it is disabled;
  advanced install/decrypt toggles live in a collapsed Options card.

Two decrypt input modes:

| Mode | Needs | Notes |
| --- | --- | --- |
| **IPA file** | `appinst` + AppSync Unified | Installs the bundle, decrypts, optionally uninstalls afterwards. |
| **Installed app** | bundle id only | Decrypts an app that is already on the device. Nothing is uploaded. |

Apple ID login and App Store lookup/download are a **separate App Store card** on
the Decrypt screen, not a source-mode selection. It provides sign-in, 2FA,
trusted-number SMS delivery when native attestation is configured, and session
import. The utility opens at the account panel, so sign-in, 2FA, sign-out and
session import are separate from app identifier lookup. The remembered Apple ID
password is saved only when selected and retained correctly after the sign-in
flow completes. A downloaded IPA enters the decrypt workflow only after
explicitly choosing **Use this IPA and decrypt** in the App Store utility.

## App Store by identifier

The separate App Store utility takes any of the three identifiers ipadecrypt
accepts and downloads the encrypted IPA for the existing on-device decrypt
pipeline:

* `com.burbn.instagram` — bundle id
* `389801252` — numeric track id
* `https://apps.apple.com/us/app/instagram/id389801252` — store link

**Resolution** uses the public iTunes lookup API
(`itunes.apple.com/lookup?bundleId=… | id=…`) — no Apple ID needed. It returns
the track id for a bundle id (and the reverse), the current version, price,
`minimumOsVersion`, artwork and size, and the storefront is selectable (25
countries).

**Sign-in** has two paths, chosen automatically:

* **Native + session 2FA** (`auth/v1/native/fast`) when an anisette provider is
  configured — see below.
* **Classic MZFinance** otherwise: the bag is fetched from
  `init.itunes.apple.com/bag.xml`, the authenticate request is an XML plist
  POSTed to `buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate/`,
  and Apple's per-pod redirect is re-posted rather than followed. A `-5000`
  failure retries once.

**Crash fixed in 1.3.6.** The request instrumentation added for the 403 diagnosis
introduced an accidental recursion: `AppStoreClient.perform(_:)` called itself
instead of `http.send(_:)`. The first App Store request recursively allocated
until iOS jetsam-killed the app — matching the sudden 100 MB → 1.4 GB jump in
the latest `appstore.signin` trace. It now delegates to the HTTP transport, and
the logic CI contains a source-level regression guard that fails if the request
funnel is changed back to self-recursion. The same fix also snapshots the
password before clearing transient state, so **Remember password** actually
stores the entered password in Keychain after successful sign-in.

Either way the result is the same account material (`dsPersonId`,
`passwordToken`, `X-Set-Apple-Store-Front`, `pod`), stored in the keychain.

## Apple ID 2FA with delivery options

A refused sign-in now opens a real **two-factor step** instead of an error:

| Mode | What Apple gives us | What the user does |
| --- | --- | --- |
| Session (`auth/v1/native/fast` → 401 + `X-Apple-ID-Session-Id`/`scnt`) | `trustedPhoneNumbers[]` (id, masked number, push mode) and trusted devices | Picks a number → **Text me a code** → types it |
| Legacy (`MZFinance` 2FA gate) | nothing beyond "code required" | Apple already texted the trusted phone; types the code |

Session mode talks to `idmsa.apple.com/appleauth/auth`:

* `GET /auth` — loads the trusted numbers and the code length
* `PUT /auth/verify/phone {"phoneNumber":{"id":N},"mode":"sms"}` — sends the text
* `POST /auth/verify/phone/securitycode` — verifies an SMS code
* `PUT /auth/verify/trusteddevice` + `POST /auth/verify/trusteddevice/securitycode`
  — push prompt + its code

After a successful verification the request is replayed against
`auth/v1/native/fast`, which now yields the password token.

**Anisette.** Apple's modern endpoints require device attestation
(`X-Apple-I-MD*`). The app ships no attestation of its own; instead *Advanced*
in the sign-in sheet accepts any anisette-v3 compatible server
(`GET <url>` → `{"X-Apple-I-MD": …, "X-Apple-I-MD-M": …}`, optional basic auth).
With a provider the app uses native auth and can therefore offer the per-number
SMS choice. Without one it uses the classic flow, where the code still arrives
by text but the number is chosen by Apple. A widget-key override is available for
endpoints that ask for it.

**Licence** — free apps are acquired with `buyProduct` (`X-Token`, `X-Dsid`,
`X-Apple-Store-Front`) before download; `failureType 5002` and HTTP 500 are
treated as "already owned". Paid apps must be owned already.

**Download** asks `volumeStoreDownloadProduct` on the account's pod for a
ticket, then falls back — exactly like `download.go` — to the bag's
`redownloadProduct` and `updateProduct` dispatch endpoints. The ticket carries
the signed CDN URL, the `sinfs` count and the version metadata; the bytes are
streamed straight into `Documents/Imports` with progress. The IPA stays
FairPlay-encrypted, is installed on the device with `appinst`, and is decrypted
there by the same helper as a local file.

### HTTP 403 with an empty body

Apple answers `403` and no body to an **unsigned** `authenticate` request — it
rejects the call before it reads the password. This is the current state of the
App Store API: both desktop implementations (ipatool and ipadecrypt) sign the
request with an SAP action signature produced by running Apple's own macOS
framework under emulation, which a sandboxed iOS app cannot do.

`1.2.1` handles it as a first-class outcome rather than a dead end:

* **Strategy ladder** — native auth (when anisette is configured) → classic
  MZFinance → native auth with local-only headers. Every attempt is logged with
  its URL, status, byte count, `Server`, `Content-Type`, `Location` and
  correlation key.
* **Readable error** — the message says the request itself was refused, not the
  password, and offers "Set up an anisette provider" inline.
* **Copy diagnostics** — one tap exports the request log and app log.
* **Use an existing session** — paste `dsPersonId`, `passwordToken`, storefront
  and pod from a machine that *can* sign (ipatool/ipadecrypt). Apple accepts a
  valid token for licences and downloads, so the rest of the App Store tab works
  from that point on.
* **Decrypt the installed copy** — no Apple account involved at all.

429 responses are surfaced as rate limiting rather than as a credential failure.

### What still needs the desktop

Apple's attested `ent/download` endpoint requires a FairPlay `kbsync` blob that
ipadecrypt produces by emulating the macOS StoreAgent framework, plus a SAP
action signature on authenticate. Neither exists on iOS, so for builds Apple
ships **only** through that endpoint (post-2026-09 releases on many accounts)
the app reports `needsAttestation` — an HTTP 403 from downloaddispatch — and
offers one-tap "decrypt the copy installed on the device" plus the App Store
link. Everything else in the chain (lookup, sign-in, 2FA, licence, legacy
download, install, decrypt, verify) runs on the phone.

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

`.github/workflows/build.yml` uses the `xcode-27` runner (Xcode 27 / iOS SDK 27),
verifies the helper is inside the `.app`, packages `Payload/` and uploads
`DecryptIPA-<version>-unsigned.ipa` as an artifact. Sign it with AltStore,
SideStore, zsign or TrollStore before installing.

Dependencies: [Citadel](https://github.com/orlandos-nl/Citadel) (SwiftNIO SSH
client + SFTP), [swift-crypto](https://github.com/apple/swift-crypto) (ed25519
key parsing, SHA-256 of the helper),
[RemoteAnisette](https://github.com/SideStore/RemoteAnisette) (consent-based
Anisette-v3 provisioning/client, pinned to a reviewed revision), and
[ZIPFoundation](https://github.com/weichsel/ZIPFoundation) (IPA inspection,
patching, verification). Automatic Anisette setup is an explicit user action;
it does not contact a provider until the user approves the in-app consent dialog.

## Crash reports

Library → **⋯ → Diagnostics & crash logs** (or `Documents/Logs`):

* `last-run.txt` — rewritten on every phase change and transport step
  (launch, job start with device/bundle/mode, SSH connect/connected, upload,
  install, stream, verify, save). After a crash it shows the last thing the app
  did.
* `crash-exception-*.txt` — from `NSSetUncaughtExceptionHandler`: name, reason,
  `Thread.callStackSymbols`, plus the breadcrumb tail.
* `crash-signal.txt` — appended by the `SIGABRT/SEGV/BUS/ILL/FPE/TRAP` handlers,
  which only call `write(2)` on a descriptor opened at launch.

Every run is also archived: on launch the previous `last-run.txt` moves to
`Logs/runs/run-<date>.txt` (ten kept), so relaunching after a crash cannot
destroy the trail you need. Diagnostics lists them under **Previous runs**, with
the last recorded step under each name, and a run that disappeared without a
`scenePhase: background`/`clean exit` line gets a `crash-suspected-*.txt` note —
that is the signature of a watchdog kill or jetsam eviction rather than a Swift
exception.

"Share everything" exports all of it in one paste.

## Verification

Two gates run in CI:

* `tools/logic-check` compiles the device-free logic (`MachO.swift`,
  `Events.swift`, `AppStoreLookup.swift`, `AppStoreClient.swift`) into a
  command-line harness and asserts it against synthetic fixtures: `cryptid` in
  `LC_ENCRYPTION_INFO` / `LC_ENCRYPTION_INFO_64`, thin arm64 + armv7 + fat
  images, an encryption command that sits after a large `LC_SEGMENT_64`,
  version ordering (`1.2 < 1.10`), `@evt` parsing with quoted messages, App
  Store identifier forms (bundle id / track id / store link / free text
  rejection), XML plist escaping and integer rendering, `<Document>`-wrapped and
  bare-key/value response normalisation, the auth-endpoint allowlist, 2FA
  challenge parsing (trusted numbers, push modes, string ids, code length,
  session headers, trusted-device fallback) and anisette header handling. It caught two real defects before the first release: a
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
  AppStore/
    AppStoreLookup.swift   identifier parsing + public iTunes lookup
    AppStoreClient.swift   bag, sign-in + 2FA, buyProduct, download tickets,
                           CDN streaming, XML plist encode/normalise
    AppStoreSession.swift  account persistence (keychain), GUID, storefront
    AppStoreView.swift     identifier → account → 2FA → download → hand off
    AppStoreNative.swift   native auth, session 2FA completion, code requests
    TwoFactor.swift        challenge model, trusted-number parsing, idmsa client
    Anisette.swift         anisette provider (remote) + local identity headers
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
