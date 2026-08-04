# Morning Brief — iOS

A native iOS app that does what the Morning Brief skill does — one calm view of
the shape of your day — and **reads it out loud at a time you set, with no
Shortcut and no tapping.**

<img src="MorningBrief/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png" width="120" alt="">

Built for TestFlight distribution. SwiftUI, no third-party dependencies, iOS 17+.

---

## How the readout works without a Shortcut

This is the part that needed designing, so it's worth being precise. iOS gives no
app a general "wake up at 7am and start talking" primitive. What it does give is
three narrower mechanisms, and the app uses all three so they cover each other's
gaps.

### Tier 1 — the notification's *sound* is the spoken brief

The app renders the brief to speech **ahead of time** with
`AVSpeechSynthesizer.write(_:toBufferCallback:)`, writes the PCM to
`Library/Sounds/brief-a.caf`, and attaches that file as the sound of a repeating
`UNCalendarNotificationTrigger`. At the set time, iOS plays it.

- ✅ Fires whether or not the app is running — **survives a force-quit and a
  reboot**.
- ✅ Zero interaction.
- ⚠️ **iOS caps notification sounds at 30 seconds.** A longer file is silently
  swapped for the default alert tone, so `BriefScript.teaser` trims the script to
  fit and `SpokenSoundRenderer` hard-stops the render at 29 seconds.
- ⚠️ **Silenced by the ringer switch and by Silent Mode**, like any notification
  sound. Nothing an app can do about that.
- The notification is `.timeSensitive`, so it breaks through Focus and scheduled
  summary delivery.

### Tier 2 — hands-free full readout (opt-in)

With **Hands-free** on, the app keeps an `AVAudioSession` alive playing a
near-silent loop, with `UIBackgroundModes: audio` declared. iOS therefore doesn't
suspend the process, so a `Timer` can fire at the set time and speak the
**entire** brief.

This is the alarm-clock pattern. Honest trade-offs:

- ✅ The whole brief, not 30 seconds. Works from the background and the lock
  screen.
- ⚠️ **Uses more battery** — which is why it's a setting, off by default.
- ⚠️ **Does not survive a force-quit or a reboot.** Tier 1 covers those.

### Tier 3 — tapping the notification

Opening the notification (the banner, or the "Read it to me" action) reads the
full brief immediately.

### Keeping the audio current

A `BGAppRefreshTask` re-gathers the day and re-renders the audio a couple of
hours before the readout. Background refresh is opportunistic — iOS decides
whether it runs at all — which is exactly why tier 1 never depends on it. If the
refresh doesn't run, the notification still fires with the last rendered audio.

---

## Where the content comes from

The skill pulls from Gmail / Slack / Google Calendar connectors. An iOS app can't
reach those without a server and an OAuth backend, so this reads the device
instead, via **EventKit**:

| Skill role | Here |
|---|---|
| Calendar | Apple Calendar — today's events (drawn and classified) and tomorrow's (context and prep) |
| Email / chat asks | Apple Reminders — what's overdue or due today |
| Resolved | Reminders completed in the last two days, plus meetings the organizer cancelled |

No server, no account, nothing leaves the phone. If you later want the connector
sources, `EventKitStore` is the only place to change — `GatheredContext` is the
seam everything downstream depends on.

The brief keeps the skill's structure: day-date line, one serif headline, one
unbroken terrain stroke with meeting dots and a single clay accent, three acts,
then Needs attention above Already sorted.

## Optional: let Claude write the prose

Off by default. `BriefBuilder` decides *what* the brief says and where every fact
came from; with a key in Settings, `ClaudeBriefWriter` sends the day's titles and
times to the Messages API (`claude-opus-5`) and gets back replacement sentences.

The merge is deliberately narrow: **only sentences and the headline** are taken
from the response, keyed by ids the app sent. Titles, links, source phrases, and
structure always stay as built on device — so a bad response degrades the writing
and cannot invent a task or a link. Gathered text is passed as data, with an
explicit instruction that any command inside it is content, not direction.

There is no official Anthropic SDK for Swift, so this is a direct HTTPS call. The
key is stored in the Keychain, never in `UserDefaults`.

---

## Build and ship to TestFlight

Requires **Xcode 16 or newer** (the project uses synchronized folder groups).

`MorningBrief.xcodeproj` is generated, not committed — `project.yml` is the
source of truth. Generate it first:

```bash
brew install xcodegen && xcodegen generate
open MorningBrief.xcodeproj
```

Then:

1. **Signing** — the bundle ID is `com.anotherwolf.closure`. To ship under your
   own, change `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml` **and** `BUNDLE_ID`
   in both `codemagic.yaml` and `.github/workflows/testflight.yml`; either CI
   config fails fast if it disagrees with the spec. Select the `MorningBrief`
   target › Signing & Capabilities and pick your team.
2. **Archive** — Product › Archive, then Distribute App › TestFlight.
3. Export compliance is pre-answered: `ITSAppUsesNonExemptEncryption` is `false`
   in `Support/Info.plist` (HTTPS via system libraries only), so uploads don't
   prompt for it.

### Shipping from CI

There are two equivalent paths, and they do the same six things: XcodeGen →
verify bundle ID → pick a build number → fetch signing files → build → upload.

| | Where | Trigger |
|---|---|---|
| `codemagic.yaml` | Codemagic | On push, per the Codemagic UI |
| `.github/workflows/testflight.yml` | GitHub Actions, `macos-15` runner | Manual — Actions tab › TestFlight › Run workflow |

The GitHub Actions one exists so a Codemagic outage or account problem isn't a
hard block on shipping. It installs `codemagic-cli-tools` from pip — the same
`app-store-connect`, `keychain` and `xcode-project` commands Codemagic runs
internally — so the two configs stay behaviourally identical and a fix to one
usually ports to the other verbatim. It's `workflow_dispatch` only on purpose:
macOS runner minutes bill at 10× on private repos, so builds shouldn't fire on
every push.

Either way, **an Apple ID password is never used**. Uploading with an Apple ID
means handing full account access to a build machine and getting stopped by 2FA;
an App Store Connect API key is scoped to one role, works unattended, and can be
revoked on its own without touching the account.

#### Secrets for the GitHub Actions workflow

Four, under Settings › Secrets and variables › Actions:

| Secret | Where it comes from |
|---|---|
| `APP_STORE_CONNECT_ISSUER_ID` | App Store Connect › Users and Access › Integrations › App Store Connect API — the UUID above the key table |
| `APP_STORE_CONNECT_KEY_IDENTIFIER` | The 10-character Key ID of that key |
| `APP_STORE_CONNECT_PRIVATE_KEY` | Full contents of `AuthKey_<KeyID>.p8`, `BEGIN`/`END` lines included — Apple lets you download it exactly once |
| `CERTIFICATE_PRIVATE_KEY` | The same RSA PEM described below |

The first three are the key already wired into Codemagic as the
`code magic_api_key` integration. If that `.p8` is still on disk, reuse it; if
not, mint a new key with **App Manager** access — old keys keep working, so
there's no cleanup needed.

The workflow checks all four up front and names the ones that are missing,
rather than failing later inside the keychain step where the error reads like
something else entirely.

#### Shipping on Codemagic

`codemagic.yaml` runs the whole path on Codemagic: XcodeGen → fetch signing
files for `$BUNDLE_ID` → build → upload to TestFlight.

It needs two secrets, not one. The App Store Connect API key (wired up as the
`code magic_api_key` integration) authenticates the API calls, but Apple only
returns the *public* half of a distribution certificate — the private key never
leaves the machine that made it. So the signing step also needs
`CERTIFICATE_PRIVATE_KEY`: a 2048-bit RSA key in PEM form, added as a secret
variable in a Codemagic variable group named `appstore_credentials`.

```bash
ssh-keygen -t rsa -b 2048 -m PEM -f codemagic_cert_key -q -N ''
```

Paste the whole of `codemagic_cert_key`, `-----BEGIN`/`-----END` lines included.
On the first build, `--create` mints a distribution certificate from that key;
later builds reuse it. Apple caps you at two Apple Distribution certificates, so
if creation is refused, revoke an unused one or export the private key of an
existing certificate from Keychain Access and use that instead.

Two more things CI handles that are easy to get wrong by hand:

- **Build number.** `CURRENT_PROJECT_VERSION` in `project.yml` stays at `1`;
  CI overwrites it in the generated project with `last TestFlight build + 1`.
  App Store Connect rejects a build number it has already seen, so a fixed
  value only ever works once.
- **Bundle ID drift.** The signing profile is fetched by bundle ID. If
  `BUNDLE_ID` doesn't match the project, the profile that comes back doesn't
  match the app being built and the archive fails to sign.

### Time-sensitive notifications

The app asks for `.timeSensitive` interruption level so the readout pierces
Focus. That needs the `com.apple.developer.usernotifications.time-sensitive`
entitlement, which isn't currently requested — the notification arrives at the
`.active` level instead. It still plays the spoken sound. To turn it on, add an
`entitlements` block to the `MorningBrief` target in `project.yml`; the
provisioning profile picks the capability up on the next `fetch-signing-files`.

### First run

Grant Calendar, Reminders, and Notifications when asked, then set your time in
Settings. Two things worth doing:

- **Download a better voice.** Settings › Accessibility › Spoken Content ›
  Voices — Enhanced and Premium voices are free and sound markedly better than
  the default. The app picks the best installed voice automatically.
- **Check the voice language.** The brief is written in English, so the app
  defaults to an English voice rather than following the device language — a
  voice built for another language reads English through that language's
  phonetics and sounds stilted. Settings › Voice › Language picks the accent
  (English (United Kingdom), English (Australia), …) and the Voice picker below
  it then lists only that language's voices.
- **Check the ringer isn't silenced** before relying on tier 1.

### Testing the readout without waiting until morning

Set the time two minutes out, background the app, and lock the phone. To test
tier 2 specifically, turn Hands-free on first. To test tier 1 in isolation, force
quit the app after scheduling — the notification should still fire and speak.

---

## Layout

```
MorningBrief/
├── Model/
│   ├── Brief.swift             Brief, Act, BriefItem, MeetingDot, DayShape, Motif
│   └── Settings.swift          UserDefaults-backed settings + Keychain for the API key
├── Data/
│   ├── EventKitStore.swift     Calendar + Reminders -> Sendable value types
│   ├── BriefBuilder.swift      Day classification, acts, dots, sorting, on-device prose
│   └── BriefStore.swift        Coordinates gather -> build -> polish -> cache -> schedule
├── Speech/
│   ├── BriefScript.swift       Brief -> spoken script (full, and a 30s teaser)
│   ├── BriefNarrator.swift     Live readout via AVSpeechSynthesizer
│   ├── SpokenSoundRenderer.swift  Offline TTS -> Library/Sounds/*.caf  (tier 1)
│   └── AudioKeepAlive.swift    Background audio session               (tier 2)
├── Scheduling/
│   └── BriefScheduler.swift    Notifications, hands-free timer, BGAppRefreshTask
├── Writer/
│   └── ClaudeBriefWriter.swift Optional Messages API prose pass
└── Views/
    ├── BriefView.swift         The two bands
    ├── TerrainView.swift       The day as one unbroken stroke
    ├── SettingsView.swift
    └── Theme.swift             Palette and type
```

### Fonts

The headline asks for `Fraunces-SemiBold` and falls back to the system serif,
which is a clean fallback rather than a broken one. For the real face, drop
`Fraunces-SemiBold.ttf` into `MorningBrief/Resources/Fonts/` and add a
`UIAppFonts` array to `Support/Info.plist` listing it.

## Known limits

- Notification sounds obey the ringer switch and Silent Mode (tier 1), and 30
  seconds is a hard iOS cap.
- Hands-free (tier 2) doesn't survive a force-quit or a reboot, and costs
  battery.
- Background refresh timing is at iOS's discretion; nothing breaks when it
  doesn't run.
- Reminders stand in for the skill's email and chat asks. There's no "have I
  already replied to this thread" check, because there's no thread to look at.
