# Keeping development permission grants stable

Research date: 2026-11-08. These are documented options and recommendations;
no certificate or permission was provisioned for this research. See
[permissions](permissions.md) for the operational reference and
[debug verification](debug-verification.md) for test execution.

The practical approach is to keep most tests below permission boundaries, then
give the small desktop integration suite a stable signed identity. Signing can
preserve an existing authorization across builds; it does not grant initial
consent.

## Why rebuilding causes prompts

Apple explains that macOS records an app's designated requirement (DR) when
authorizing microphone access and checks later versions against that requirement.
Ad-hoc signing, including Xcode's “Sign to Run Locally,” identifies one particular
version of the code. A changed binary can therefore require authorization again.
A stable bundle ID alone does not fix this. Apple Development and Developer ID
builds also have different default requirements; changing distribution channel
can legitimately require fresh consent. [Apple TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)

Chatty currently has several independent sources of churn:

- [package-debug.sh](../scripts/package-debug.sh) defaults to ad-hoc signing but
  accepts `CHATTY_DEBUG_SIGN_IDENTITY`. It verifies the resulting signature and
  fails if an explicitly selected identity cannot be used. It never resets TCC.
- [build-app.sh](../scripts/build-app.sh) signs ad-hoc, gives numbered user builds
  different bundle IDs and paths, and deliberately resets Microphone and
  Accessibility for production builds. Stable signing would not undo those
  explicit resets or make different bundle IDs one app.
- [package-release.sh](../scripts/package-release.sh) signs ad-hoc too. The
  [Xcode UI project](../ChattyUITests.xcodeproj/project.pbxproj) separately sets
  `CODE_SIGN_IDENTITY = "-"`; the debug packaging variable does not configure
  Xcode's runner and paste destination.

## Available signing options

| Option | Practical use and limits |
| --- | --- |
| Reuse the authorized ad-hoc artifact | `test-ui.sh --no-build` preserves the app and runner already built. Useful while investigating permissions, but it cannot verify subsequent source edits. |
| Apple Development identity | Preferred first experiment for the desktop test app and any runner that needs persistent access. Xcode manages development certificates and their private keys. Apple offers free Personal Teams; LinearMouse specifically documents obtaining an Apple Development certificate without payment. Availability still needs checking in this Mac's Xcode account. [Apple account overview](https://developer.apple.com/help/account/basics/about-your-developer-account/), [Xcode certificate management](https://help.apple.com/xcode/mac/current/en.lproj/dev154b28f09.html), [LinearMouse contributing guide](https://github.com/linearmouse/linearmouse/blob/main/CONTRIBUTING.md) |
| Persistent local self-signed code-signing certificate | An alternative without buying Developer Program membership. Apple's archived signing guide describes self-signed identities and subsystem-specific trust. This is a candidate for a local proof, not a verified promise that every current TCC service will retain grants. It does not provide Developer ID notarization or equivalent Gatekeeper distribution trust. Retain the certificate and private key rather than generating a replacement per build. [Apple TN2206](https://developer.apple.com/library/archive/technotes/tn2206/_index.html) |
| Developer ID and notarization | Appropriate for distributing the app outside the Mac App Store. It requires the relevant paid developer account access, and initial privacy consent remains necessary. The Developer Program is currently USD 99 annually, or local currency where offered. Purchasing membership solely to run ordinary unit tests is unnecessary. [Developer ID](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/), [Apple enrollment](https://developer.apple.com/programs/enroll/) |

Use the legitimate signing identity and generated requirement. There is no need
to forge another app's identity or write a permissive custom requirement. A
development app can intentionally have independent permissions from a released
app. [Apple TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)

## Keychain and automation are separate boundaries

Keychain item authorization is separate from Microphone and Accessibility TCC.
Apple documents that the legacy Keychain tracks trusted application access using
code requirements and that each security subsystem applies its own trust
policy. A signing change can consequently affect an existing item's trusted
application relationship too. [Apple TN2206](https://developer.apple.com/library/archive/technotes/tn2206/_index.html)

[KeychainStore](../Sources/Chatty/KeychainStore.swift) uses the login Keychain's
`Chatty.OpenAI` / `apiKey` generic password. Its `LAContext` disables biometric
interaction, but its own contract notes that legacy item access can still need
macOS approval. Granting Accessibility cannot approve that item. Continue using
injected credentials for request variants; a deliberate real-Keychain check
should use an isolated test item rather than broadening access to the user's key.

XCTest's **Enable UI Automation** authorization is also distinct from the app's
permission to call Accessibility APIs or post a production paste event. Apple
documents an additional Xcode Helper Accessibility grant for recording UI tests.
Grant the actual component requesting access, rather than assuming approval of
Chatty covers every runner. [Apple UI recording](https://developer.apple.com/documentation/XCUIAutomation/recording-ui-automation-for-testing)

Appium's Mac2 driver provides a useful project-owned example: ordinary XCTest
element interaction and direct Accessibility operations have different needs.
Its runner documentation recommends a stable Apple Development identity and
describes an old enabled Accessibility entry remaining visible while a rebuilt
runner is no longer trusted. That is supporting experience, not proof that
signing explains every Chatty failure. [Appium Accessibility guide](https://appium.github.io/appium-mac2-driver/v4/guides/accessibility-permission/)

## How projects handle this in practice

LinearMouse warns contributors about Accessibility reauthorization after ad-hoc
rebuilds and recommends Apple Development certificates. Hammerspoon still
documents manual initial Accessibility consent. These examples support stable
development signing plus an explicit setup step; they do not establish that all
projects use the same workflow. [LinearMouse](https://github.com/linearmouse/linearmouse/blob/main/CONTRIBUTING.md),
[Hammerspoon FAQ](https://www.hammerspoon.org/faq/)

For Chatty, keep stable bundle IDs and installation paths **per role**: production,
debug app, UI test app and runner. Reuse the same signing identity within each
role. Fixed paths simplify Launch Services registration and selecting the right
app in Settings; they are not a substitute for compatible signatures.

A dedicated, logged-in GUI test account or Mac is a practical isolation option
for the remaining desktop suite. Provision its own approvals and synthetic
fixtures once, run tests serially, and keep the desktop unlocked. This is a
recommendation based on Chatty's focus/clipboard requirements, not a way to avoid
consent. It prevents unrelated agent work from competing for keyboard focus and
does not give that account access to the developer's login Keychain.

Managed fleets can use PPPC policies through user-approved MDM. On macOS 26,
Accessibility can be managed, but the Microphone payload can only deny access;
it cannot grant it. App identity and code requirements still matter. This is
not a locally installed profile workaround and does not resolve Keychain item
trust. Apple's current schema introduces later OS changes, so recheck the policy
before moving a test host beyond macOS 26. [Apple PPPC schema](https://github.com/apple/device-management/blob/release/mdm/profiles/com.apple.TCC.configuration-profile-policy.yaml)

## Minimal next steps for Chatty

1. Keep controller, HTTP, transcript and supplied-audio variants in focused tests.
   Run desktop paste, global shortcuts, real input capture and live Keychain
   checks only when the changed slice crosses those boundaries. Preserve a
   representative integration check for each mechanism; selecting fewer tests
   is not evidence that an unexecuted boundary passed.
2. Provision one legitimate development identity, preferably through Xcode, and
   exercise the existing `CHATTY_DEBUG_SIGN_IDENTITY` hook. Do not change the
   numbered user-build installation/reset policy as a side effect of test setup.
3. Prove persistence with two genuinely different builds at the same test path
   and bundle ID: approve build A, change and sign build B with the same identity,
   then verify actual capture and paste without regranting. Inspect requirements
   with `codesign --display -r -`; check signatures with `codesign --verify --strict`.
4. Evaluate the Xcode runner's signing separately. Approving the debug app or
   setting its environment variable does not prove runner authorization.
5. Record separate results for Microphone, Accessibility, UI Automation and an
   isolated Keychain item. Certificate availability, self-signed behavior on this
   OS, and any difference between direct launch and XCTest remain unproved until
   that experiment runs.

No TCC database edits, broad access grants, automatic approval of security
dialogs, or signing-requirement spoofing are needed for these steps.
