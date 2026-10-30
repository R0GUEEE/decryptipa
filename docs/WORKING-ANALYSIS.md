# What has to be true for a decrypt job to succeed

Tracing `DecryptEngine.run` end to end, a job has exactly four hard gates. Any
one of them fails the run, and each fails differently.

| Gate | Requirement | How it fails today | Handling |
| --- | --- | --- | --- |
| 1. Reachability | SSH to the device, password or ed25519, root or sudo | Timeout / auth error | surfaced as a connect error, transport closed |
| 2. Install tooling | `appinst` present **and** AppSync Unified active | `appinst` missing → bundle never installs | located up front, warned in step 1 and in the log |
| 3. Helper execution | embedded helper runs as root with its ldid entitlements | `exec` denied / kills immediately | content-addressed upload, 0755, usage probe |
| 4. Bundle spawn | the installed bundle can be launched (SBS) or attached (ptrace) | helper emits `bundle.spawn_failed` | reported as an event, but the job continued |

Gates 1–3 are checkable without a device; gate 4 depends on the app itself.

# Defects found in this pass, and the patches

### 1. No way to name the app to decrypt (blocking usability)

The "Installed" source required typing a reverse-DNS bundle identifier. With the
App Store path blocked by Apple's signing wall, that is the *primary* route — so
the app was effectively asking users to guess.

**Patch:** `DeviceService.listInstalledApps()` walks
`/var/containers/Bundle/Application/*/*.app/Info.plist` with `PlistBuddy` in one
shell round trip and returns name, identifier and version; `InstalledAppsSheet`
presents a searchable picker and fills the field.

### 2. A truncated stream was saved as a finished IPA

`helper decrypt … -` streams the IPA over stdout. If the SSH session ends early
(network drop, device kill, helper crash) the file is non-empty, so the old check
(`bytes > 0`) passed, verification ran on a partial archive, and the user got a
broken IPA with a "Saved" message.

**Patch:** `IPATool.looksComplete()` reopens the stream and requires at least one
`Payload/` entry; failure deletes the partial file and names the byte count.

### 3. Version mismatch failed late and cryptically

Installing an IPA whose `MinimumOSVersion` exceeds the device only fails inside
`appinst`, after the upload, with an opaque exit code. If patching is disabled the
user waits minutes for nothing.

**Patch:** a preflight before upload compares versions and fails with
"needs iOS X but the device runs Y — enable Patch Info.plist".

### 4. Earlier this session (already shipped)

* Binary `Info.plist` reads were destroyed by a UTF-8 round trip → installed-app
  detection and the post-install lookup always failed (1.5.2).
* 2FA method selection never reached the session (1.5.2).
* Staging cleanup raced the transport close (1.5.2).
* Native-auth endpoint 404 and the unreadable error wall (1.4.2).
* Recursive request dispatch that jetsam-killed the app on first sign-in (1.3.6).

# Remaining risks that only a device can settle

1. **Helper spawn on iOS 27.** Gate 4 depends on `SBSLaunchApplicationWithIdentifier`
   or the ptrace fallback. The embedded helper is upstream's build; nothing in
   this app can improve it, but a `bundle.spawn_failed` in the log means the bundle
   is not launchable on that OS version — try an older IPA build of the same app.
2. **`appinst` on rootless jailbreaks.** The binary is found at `/usr/bin/appinst`
   or `/var/jb/usr/bin/appinst`; if the device only ships a different installer the
   gate 2 warning is what you will see.
3. **Large IPA memory.** The engine aborts above 900 MB footprint on purpose.
   Writes are streamed to disk, so this should not trigger; if it does, the log's
   `step:` lines say where it grew.
4. **Apple ID / App Store download.** Not a bug: `authenticate` requires an SAP
   action signature produced by Apple's media-services framework, and
   `auth/v1/native/fast` answers 400/406 to every body we can build. Import a
   session token or use the installed-copy route.

# Verification checklist for a real device

1. Step 1 → Test connection: expect `iOS x · arm64/arm64e · model · jailbreak`,
   `appinst ready`, `AppSync ready`.
2. Step 3 → Installed → Choose from installed apps: a list appears. Picking one
   fills the bundle id.
3. Decrypt with **Verify output** on: the log should reach
   `Saved …ipa` and report `N/N Mach-O images are plaintext`.
4. Re-run the same job: the log should say `Already installed with the same
   version — decrypting in place` and skip the upload.
5. Pull the resulting IPA out of the Library and check it installs on a
   non-jailbroken device after signing.
