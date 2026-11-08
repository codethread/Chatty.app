# Permissions and test prerequisites

Read this when the [agent testing guide](testing.md) selects a desktop, capture or
live-service check, or when resolving its blocked access. This reference owns the
permission requirements and grant-recovery procedure; the guide owns test scope,
execution order and reporting.

## Using Chatty

| Access | Purpose | When needed |
| --- | --- | --- |
| Microphone | `AVAudioEngine` captures your voice. Apple and Nemotron share this grant. | Actual microphone input in the installed app or debug app. File replay and supplied-buffer tests bypass capture. |
| Accessibility | Observe the default double-left-Shift gesture and send production Command-V into another app. | Installed Chatty; the UI-test app also needs its own authorization for the external-paste workflow. |
| Keychain item access | Read the saved OpenAI API key from the login Keychain. This is separate from Microphone/Accessibility TCC. | Live cleanup or saved-audio uploads using Keychain credentials. Injected credentials and the HTTP fake do not need it. |
| Gatekeeper launch approval | Allow an app downloaded outside the App Store to launch when macOS blocks it. Current releases are ad-hoc signed, not notarized. | If macOS requests **Open Anyway** after installation. This is launch approval, not a privacy grant. |

Production startup requests Microphone and Accessibility. Keychain access starts
asynchronously on first live use and the key is cached in memory. Each app
identity has its own grants: `/Applications/Chatty.app`, numbered builds, and the
debug/UI-test apps are distinct. A rebuilt ad-hoc-signed app may need fresh trust
even when its name, path and Settings switch look unchanged.

Chatty currently requests no Input Monitoring, Full Disk Access, Screen Recording
or Apple Events Automation permission, and no separate Speech Recognition grant.
It uses `SpeechAnalyzer`, not `SFSpeechRecognizer`. Avoid introducing `CGEventTap`
just to observe keys: that can add Input Monitoring requirements.

## Which tests can be blocked?

| Selected slice | Prerequisites | Boundary substituted or left unverified |
| --- | --- | --- |
| Swift logic/component tests: default `check.sh`, optionally `--filter` | Swift/macOS build environment and writable temporary storage; no privacy grants, live key or model weights. | Capture, model inference, desktop controls and external paste. HTTP/files/AVFoundation processing still run where named by the tests. |
| Core AppKit: `--with-ui` | Unlocked desktop, Xcode **Enable UI Automation** authorization. | Speech snapshots and HTTP replies are supplied; clipboard/paste target are private. No physical microphone, Keychain key or downloaded model is used. |
| External paste: `--with-paste` | Core UI prerequisites plus Accessibility for the exact signed UI-test app. | Uses real activation, Command-V, a separate editor and the general clipboard; teardown restores the clipboard. |
| Global shortcuts: `--with-global-shortcuts` | UI Automation, unlocked desktop and uncontested keyboard focus. | Current workflow exercises a custom Carbon hotkey and Escape from another app. The default modifier-monitor/double-Shift path still has a separate Accessibility/manual check. |
| Recognizers: `--with-audio` | UI Automation, Apple speech assets and the fixed Nemotron model already cached. | Clock-paced file replay uses the real recognizers/conversion/AAC, but bypasses the microphone tap. Nemotron weights must be cached; Apple's API may download missing speech assets on first use. No microphone access is requested. |
| Archive: `--with-release` | Swift release build and local ad-hoc signing tools. | No desktop UI or privacy grants. Checks the extracted production artifact. |
| Live OpenAI check | Network, valid API credentials and item trust when loading from Keychain. | A deliberate additional check, never part of the fake-service default or `--all`. Use synthetic speech/text; keep keys out of arguments, files and logs. |
| Physical/virtual microphone check | Microphone consent, input hardware/routing; Accessibility too if exercising default shortcuts or external paste. | Separate manual/proposed capture lane. `--with-audio` does not prove this boundary. |

**UI Automation belongs to the test runner.** It lets XCUITest click, type and
inspect AppKit controls. It is distinct from the tested app's Accessibility
grant and from Apple Events Automation. Approve the expected Xcode system prompt
with Touch ID/password; keep the Mac unlocked while tests run. Agent desktop
inspection tools have their own authorization, which does not authorize Chatty.

GitHub repository/release credentials and Homebrew's installation privileges are
separate release prerequisites, not app privacy permissions. A certificate's
private-key approval, if stable signing is configured, is also separate from
access to the OpenAI Keychain item.

## Identifying and refreshing the right grant

The maintained test target is `build/Chatty UITest.app`, bundle ID
`local.chatty.Chatty.uitest`; it may display as **Chatty Debug**. In System Settings
→ Privacy & Security → Accessibility, **Show in Finder** reveals which copy an
entry refers to. Check the path, not just a repeated app name. The Xcode runner
is a different executable under `build/UITests/Build/Products/Debug/`.

When an enabled entry still fails, quit that test app and have the user refresh
the exact entry; if toggling is insufficient, remove and re-add the current
bundle. Then reuse those artifacts. A successful permission probe alone does
not prove paste delivery: the external-editor assertion must pass too.

`--no-build` does not test app source changes: rebuild first when those change,
then authorize the new artifact. For UI-test-only changes, the
[harness reference](debug-verification.md#native-execution-and-authorized-artifacts) explains
how to rebuild the runner without replacing the authorized app. Ordinary test
scripts do not reset or edit TCC. `tccutil reset` revokes decisions; it cannot
grant consent. The numbered production installer currently resets permissions
by design, so it is not the ordinary agent test loop.

## Reducing repeated prompts

Use focused tests below permission boundaries, stable bundle IDs/paths per app
role, and a stable signing identity for the small desktop suite. The existing
`CHATTY_DEBUG_SIGN_IDENTITY` hook signs the debug app; the Xcode runner needs
separate consideration. It does not create certificates or grant consent.

See the sourced [grant-persistence research](permission-grants-research.md) for
Apple Development, local signing, Developer ID/notarization, dedicated GUI test
hosts and MDM options, their limits, and a two-build proof before relying on
persistent grants.
