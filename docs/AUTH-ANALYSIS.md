# Apple authentication: how the reference tools do it, and where this app stands

This note records what `ipatool`, `ipadecrypt` and `SideStore` actually send when
they sign in, what this app now matches, and the one thing no sandboxed iOS app
can reproduce.

## The three requests that matter

| Stage | Endpoint | What Apple checks |
| --- | --- | --- |
| Sign-in | `POST buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate` | XML plist body **plus** `X-Apple-ActionSignature` |
| Licence | `POST p<NN>-buy.itunes.apple.com/…/buyProduct` | `iCloud-DSID`, `X-Dsid`, `X-Apple-Store-Front`, `X-Token` |
| Download | `POST …/volumeStoreDownloadProduct`, then the bag's `redownloadProduct` / `updateProduct`; attested `…/ent/download` needs `kbsync` | storefront + token; the attested path additionally needs a FairPlay blob |

## What ipatool and ipadecrypt do

Both wrap the same flow, and both sign the authenticate call:

* **ipatool** — `Login` fetches the bag, builds an SAP config, and refuses to run
  without an action signer: *"Login always uses the SAP configuration from
  Apple's current bag so unsigned or caller-selected fallbacks are impossible."*
  The signer lives in `internal/sap` and runs Apple's own media-services
  framework under Unicorn (`machimage`, `unicorn`, extracted `assets`).
* **ipadecrypt** — identical shape in `internal/sap` + `internal/store`, plus
  `kbsync` generation from a StoreAgent guest for `ent/download`.
* **SideStore** — uses SideSign/AltSign, which emulates the same framework for
  the design-time flow, and only needs an anisette server for the device
  attestation headers.

Anisette supplies `X-Apple-I-MD*` headers. It is **not** the SAP signature, and
no anisette server substitutes for it: `authenticate` answers `403` with an empty
body, before it looks at the password. That is what this app shows as
"Apple rejected the sign-in request itself".

`auth/v1/native/fast` was the other hope. Measured directly: with a trailing
slash Apple returns an HTML `404`; without it the endpoint answers `406` for
`Accept: application/json` and `400` with an empty body for JSON, XML plist,
`application/x-apple-plist` and form payloads alike. It is attested too.

## Parity fixes applied in this app

Kernel-level signing is out of reach here, but several behaviours were genuinely
wrong compared with the reference clients and are now fixed:

1. **Download auth headers** — `volumeStoreDownloadProduct` and the dispatch
   fallbacks now send `X-Token` and `X-Apple-Store-Front` alongside the DSID, as
   the desktop clients do. Previously a valid imported token could be rejected
   purely for missing headers.
2. **Retry-After** — a `429` is parsed (delta seconds or HTTP date, clamped to
   900 s) and the sign-in cooldown follows Apple's own instruction instead of a
   fixed guess.
3. **Rate-limit semantics** — a `429` ends the attempt immediately; the previous
   ladder retried classic sign-in and a second native call, which is what turned
   one rejection into a burst of `429`/`400` responses.
4. **Storefront hint for phone-number Apple IDs** — Apple expects an
   `X-Apple-Store-Front` hint for `+86` / `+91` account names, exactly as
   ipatool does before it sends the plist.
5. **Configurator user agent** — aligned with the current
   `Configurator/2.18 (Macintosh; OS X 15.3.2; 24D81)` string.
6. **Native-auth host** — the primary host is tried once, then
   `buy.itunes.apple.com/auth/v1/native/fast`; never after a `429`.
7. **Diagnostics** — each attempt logs status and body prefix
   (`Native auth · HTTP 400 · no body`), so the failure mode is visible without
   repeating the explanation.

## What remains impossible on-device

* **Signing `authenticate`.** Requires the SAP action signature. Only framework
  emulation produces it; the reference tools ship a Unicorn guest and a pinned
  macOS image for precisely this.
* **Minting a FairPlay credential / `kbsync`.** Same class of problem.
* Therefore: **direct Apple ID sign-in and App Store download cannot be completed
  from a sandboxed iOS app today.** The routes that work are the ones the UI
  offers — import a session token minted by a signing client, or decrypt a copy
  already installed on the jailbroken device (which needs no Apple account at
  all).

## What the app still does correctly

* Public catalogue access: search and lookup (`itunes.apple.com/search`,
  `/lookup`) — no account needed.
* Licence + download for a **valid imported session**: `buyProduct` body and
  headers match ipatool field for field, and the download chain matches
  ipadecrypt's `download.go` ordering.
* On-device decryption, verification and packaging, which never touch Apple.
