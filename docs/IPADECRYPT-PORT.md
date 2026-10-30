# Implementing ipadecrypt inside an iOS app

Analysis of `londek/ipadecrypt` at `849a129` (2026-10-26), mapped onto what this
app already does and what it would take to port the rest.

## 1. What the repository actually contains

| Package | Go lines | Role | Portable to iOS? |
| --- | --- | --- | --- |
| `helper/` (C) | 4,520 | on-device decryption helper: `task_for_pid` + `mach_vm_read`, dyld patch, in-helper zip writer | **Yes** — prebuilt arm64 binary, already embedded |
| `internal/device` | 1,031 | SSH/SFTP client, probe, install, bundle lookup, helper orchestration | **Yes** — pure protocol |
| `internal/pipeline` | 890 | zip surgery: patch-for-install, assemble, verify, Mach-O substitution | **Yes** — archive + plist + Mach-O parsing |
| `internal/macho` | 352 | header/load-command parsing, fat slices, encryption info | **Yes** |
| `internal/fairplay` | 934 | **offline** arm64 FairPlay decryptor: AES + MD5, no device | **Yes** — pure crypto |
| `internal/credmint` | 1,147 | mints the 16-byte account credential by running bundled iOS binaries over SSH | **Yes** — orchestration only |
| `internal/appstore` | 2,372 | bag, authenticate, purchase, download chain | **Partly** — HTTP flows port; authenticate does not work without SAP |
| `internal/apphttp` / `config` | 833 | request plumbing, config | Yes |
| `internal/sap` | 9,207 | Unicorn emulation of Apple's media-services framework (SAP signer, kbsync) | **No** — arm64 macOS binaries under emulation |
| `internal/store` | 65,964 | framework profile / generated asset data feeding that emulation | **No** |

The split is the whole story: everything that talks to the *device* or to a
*file* is portable, and one package — `sap`/`store`, ~75k lines including
generated data — exists solely to make Apple's server accept a signed request
from a Mac. That package is what an iOS app cannot reproduce.

## 2. The four pipelines

### A. On-device decryption (ported)

`decrypt_device.go`: connect → probe → patch a *copy* of the IPA for install →
upload → `appinst` → locate bundle → helper streams decrypted Mach-Os →
assemble into the output IPA → verify. Our engine implements the same sequence
with the helper's whole-IPA mode instead of `--execs-only` + assembly.

### B. Offline decryption (not yet ported)

`internal/fairplay` decrypts arm64 slices with **no device at all**, given:
the encrypted IPA (its `SC_Info/*.sinf` records) and a 16-byte per-account
credential. Constants in `fairplay.go` are a direct port of the public
fairplay-decrypt research; the primitives are `crypto/aes` and `crypto/md5`,
which map to CommonCrypto (`CCCrypt(kCCAlgorithmAES)`) or CryptoKit on iOS.

### C. Credential minting (not yet ported)

`internal/credmint` needs the device once per Apple account. Its steps, from
`mint.go`:

1. push five bundled files (`credential.ios`, `driver.ios`, `trigger.ios`,
   `core4-word-table.bin`, `static-key-table.bin` — 556 KB);
2. `credential.ios device-udid <path>` (identity check);
3. `find /var/containers/Bundle/Application -type f -path '*/SC_Info/*.sinf'`,
   pick the first app whose license format is supported, read that `.sinf`;
4. copy the app to a staging dir, restart `fairplayd`, run `trigger.ios`
   against the copied binary while `credential.ios` observes the UID layer;
5. `credential.ios retrieve <license.sinf> <uid-layer.bin> <credential.bin>`;
6. read back exactly 16 bytes.

All of that is SSH + SFTP work our app already does; the binaries are iOS
arm64 executables built for the device.

### D. App Store download (cannot be ported)

`appstore.Login` builds an SAP config from the bag, then requires an action
signer; `sap` runs the ARM64 **macOS** framework image under Unicorn to sign
the XML plist body. ipatool does the same and refuses to run without it. There
is no pure-Swift equivalent, and `auth/v1/native/fast` rejects every body shape
we can construct (400/406; the slash form is a 404).

## 3. Where this app stands against the reference

| ipadecrypt | DecryptIPA | Status |
| --- | --- | --- |
| `device.Connect`, `Probe`, `LocateAppinst/AppSync` | `SSHTransport`, `DeviceService` | ported |
| `EnsureHelper`, content-addressed upload | `DeviceService.ensureHelper` | ported |
| `FindInstalledByBundleID` (plist parsing) | `DeviceService.findInstalled` + `PlistSupport` | ported (binary plist fixed in 1.5.2) |
| `Install` / `Uninstall` | `DeviceService.install/uninstall` | ported |
| `RunHelper` (whole-IPA mode) | `DeviceService.decrypt` | ported |
| `PatchForInstall` | `IPATool.patchForInstall` | **simplified** — always writes binary plist; family mismatch now fails early (1.6.2) |
| `Verify` | `IPATool.verify` | **now closer**: cryptid, zero-fill region (1.6.2); source byte-compare still missing |
| `Assemble` (`--execs-only`) | — | **missing**, see §4 |
| `fairplay.Decrypt` | — | **missing** |
| `credmint.Mint` | — | **missing** |
| `appstore.*` | `AppStoreClient/Session` | HTTP flows ported; signing impossible |

## 4. The fidelity gap worth fixing next: output should come from the source IPA

`PatchForInstall` writes a temporary copy used **only for installation**.
Upstream then runs the helper with `--execs-only` and fuses the returned Mach-Os
into the **original** IPA, so the artifact keeps its original `Info.plist`,
`Watch/` payload and file layout.

Our app installs the patched copy and has the helper zip the *installed* bundle.
That means the decrypted IPA silently carries the patched `MinimumOSVersion`
(and loses `Watch/` content when the patch stripped it) — an alteration of the
user's artifact.

Two ways to close it:

* **Faithful** — implement `--execs-only`: parse the frame stream
  `[u32be pathLen][path][u64be size][bytes]`, and rewrite the source IPA with
  each frame substituted at the same relative path. We already have the zip
  machinery (`IPATool.patchForInstall` extracts and repacks with ZIPFoundation),
  so this is a bounded change: a frame reader plus a substitution writer.
* **Cheap** — after the helper finishes, replace `Payload/*.app/Info.plist` in
  the produced IPA with the original bytes from the source. Restores the
  metadata, but cannot restore stripped `Watch/` entries.

Recommendation: implement the faithful path; it also removes the need to patch
before install in the common case (min-OS patch is only for `appinst`).

## 5. Port plan: offline decryption (biggest user-visible win)

Inputs: an encrypted IPA, a 16-byte credential. No device, no Apple account.

1. `SinFParser.swift` — read `Payload/*.app/SC_Info/*.sinf`, validate the
   format version the decryptor supports, expose the per-slice key material.
2. `FairPlayDecryptor.swift` — straight port of `fairplay.go`:
   * IV = MD5(name ‖ iviv), AES key = credential XOR `0000000000000000`;
   * per-slice work key via AES over the round tables (`workMask`, `constant`,
     `contextBase`, `roundSelectors`, `roundConstants`, `finalSelectors`,
     `finalConstants`);
   * decrypt the crypt region per 4 KB page, write `cryptid = 0`.
3. `OfflineIPARewriter.swift` — stream the source archive, substitute decrypted
   Mach-Os, keep every other entry byte-identical (this is the same writer the
   assembly path needs).
4. Verification — reuse the strengthened `IPATool.verify` (cryptid, zero fill).

Testing without a device: the algorithm is deterministic, so a single known
triple (ciphertext slice, credential, expected plaintext) is enough. Obtain one
by minting on a device and keeping both the source IPA and the decrypted
output, then asserting byte equality of the crypt region.

Risk: the credential is per Apple account and per device family; a wrong key
produces garbage that only the zero-fill gate will catch — so run verify with a
source comparison and fail loudly.

## 6. Port plan: credential minting

Components: a `CredentialMinter` that reuses `SSHTransport` (upload + exec) and
embeds the five files from `internal/credmint/bundle` in `Resources/`. Steps are
exactly §2C, with these failure modes to surface individually:

* no `.sinf` found → account has no owned App Store app installed;
* unsupported license format → pick another app;
* `fairplayd` restart fails on a rootless jailbreak path → report the path used;
* returned credential length ≠ 16 → abort and delete.

This makes the offline decryptor usable, and it is entirely within reach
because the heavy lifting already runs on the device.

## 7. What stays impossible, and what it costs

`authenticate` requires an SAP action signature from Apple's media-services
framework; `sap` obtains it by emulating an ARM64 macOS binary tree under
Unicorn. Porting that to iOS would mean shipping a macOS framework image and a
CPU emulator — legally and technically out of scope. The practical consequence
is unchanged: App Store downloads need a credential-session minted elsewhere
(import), while everything else — minting, offline decrypt, on-device decrypt —
can run entirely on the phone.

## 8. Suggested order of work

1. `--execs-only` assembly (fixes output fidelity, reuses existing zip code).
2. Offline decryptor + SINF parser (no device needed after one mint).
3. Credential minting (unlocks the offline path).
4. Source-aware verification (byte compare outside the crypt region).
5. Only then revisit App Store UX around imported sessions.
