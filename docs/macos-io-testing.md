# Testing macOS I/O integrations

Research checked on 2026-11-07. The native XCUITest baseline is now implemented
in [ChattyUITests](../Tests/ChattyUITests/DictationUITests.swift); see
[debug verification](debug-verification.md) for execution and contracts. The
virtual microphone, device routing and permission lanes below remain proposals.

The practical next step is **a virtual Core Audio microphone plus macOS
XCUITest**, running the real Chatty app and a separate paste destination. This
can automate capture, recognition, settings, shortcuts, persistence and paste
without somebody speaking. Keep a small physical-microphone check for acoustics
and real device changes. Apple's UI automation is specifically designed for
user workflows; it is separate from unit tests despite using XCTest assertions.
[Apple's UI automation overview](https://developer.apple.com/videos/play/wwdc2025/344/).

## What each approach verifies

| Approach | Crosses the real microphone I/O boundary? | Useful evidence |
| --- | --- | --- |
| Current clock-paced file replay | No | Recognition, conversion, AAC, cleanup, lifecycle and output together. |
| AVAudioEngine manual rendering | No | Engine graph/format processing driven by deterministic buffers. Apple explicitly disconnects hardware in offline mode. |
| Fixture player → virtual audio device → unchanged input tap | Yes, through Core Audio | Device acquisition, audio clock, real tap callback, capture shutdown, conversion and downstream app behavior. |
| Speaker → physical microphone | Yes, including acoustics | Actual microphone, room, gain, hardware/firmware and device selection. Less repeatable. |

Manual rendering is valuable when testing a graph, but does not replace a live
input-device test. Apple's input node supports both hardware-driven capture and
manual input; those are distinct modes.
[Offline rendering sample](https://developer.apple.com/documentation/avfaudio/performing-offline-audio-processing),
[AVAudioInputNode](https://developer.apple.com/documentation/avfaudio/avaudioinputnode).

## Smallest useful real-input setup

Use **BlackHole 2ch** as test-machine tooling, outside Chatty's production bundle.
Its primary documentation describes routing an application's output to another
application's input through corresponding channels. It supports Apple Silicon,
common audio rates including 16/44.1/48 kHz, and needs no kernel extension or
security weakening. Installation is a one-time machine change; nothing was
installed during this research.
[BlackHole project and setup](https://github.com/ExistentialAudio/BlackHole#route-audio-between-applications).

1. Provision a dedicated Apple Silicon test Mac/account with an unlocked GUI
   session, Xcode and BlackHole. Use one stable test bundle ID/signing identity
   and isolated data directories. Authorize the required test app/helper access
   once; the ordinary loop should not reset TCC on every build.
2. Send a local WAV fixture to BlackHole from a small fixture player. Select
   BlackHole as Chatty's actual input and exercise `MicrophoneDictationService`,
   rather than the file replay input service. Both sides must use compatible
   channel/rate settings. No speaker monitoring or multi-output device is needed.
3. Initially, select the default input on the dedicated machine. For unattended
   runs, prefer explicit device UID selection in the test player/capture setup,
   so the test does not reroute the developer's microphone. Apple's underlying
   audio unit exposes `setDeviceID`; verify the selected UID before starting and
   fail when the virtual device is absent. This is a proposed device-selection
   seam, not an implemented capability.
   [AUAudioUnit device selection](https://developer.apple.com/documentation/audiotoolbox/auaudiounit/setdeviceid(_:)).
4. Launch the signed app with the real microphone source and the local HTTP
   cleanup fake. Use the actual settings and Start/Stop controls. Wait for
   capture readiness before starting playback, then observe levels, visible
   partial text, sentence completion, saved AAC/history and final pasted text.
5. Activate a separate test destination, send the recording shortcut, stream the
   fixture, stop through the shortcut, and inspect the destination's actual text.
   Use the UI suite's owned native paste destination; TextEdit is useful for a manual check.
   Keep the control API for observations, fault injection and cleanup, while UI
   actions drive the acceptance path.
6. Restore any changed audio defaults and clipboard in teardown. Record the
   selected device UID, fixture hash, backend/model, app build and timing data.
   Never classify an unavailable device, denied permission or missing GUI session
   as a passed test.

This setup covers actual capture but still substitutes the physical transducer.
A USB interface with a hardware loopback, or a controlled speaker/microphone rig,
would add physical-device coverage later; it is unnecessary for the first
repeatable capture regression.

## Apple's UI test facilities

The small Xcode **UI Testing Bundle**/scheme now lives alongside the Swift package;
retain the existing package build and app harness. Run this lane with
`xcodebuild test` and retain its `.xcresult` and failure screenshots/video.
Apple documents separate-process UI tests, macOS keyboard/mouse support and
Accessibility-based element queries.
[UI testing architecture](https://developer.apple.com/library/archive/documentation/DeveloperTools/Conceptual/testing_with_xcode/chapters/09-ui_testing.html),
[macOS element interactions](https://developer.apple.com/documentation/xcuiautomation/xcuielement).

Use `XCUIApplication` proxies for Chatty and the destination. Call the
destination's synchronous `activate()` before typing a chord with
`typeKey(_:modifierFlags:)`, then verify Chatty's overlay and the final external
text. Treat delivery through this API as a test to prove, not an assumption that
synthetic events always equal hardware events.
[Application activation](https://developer.apple.com/documentation/xcuiautomation/xcuiapplication/activate()),
[key combinations](https://developer.apple.com/documentation/xcuiautomation/xcuielement/typekey(_:modifierflags:)-9ubn).

**Menu-bar app detail:** `LSUIElement` apps remain `runningBackground` after
launch/activation. Do not wait for `runningForeground` as Chatty's readiness
condition; wait for its menu/overlay or explicit readiness event instead.
[Apple's application-state contract](https://developer.apple.com/documentation/xcuiautomation/xcuiapplication/state-swift.property).

Use stable Accessibility identifiers for automation and predicate/event waits
with deadlines. Measure speech-onset-to-first-visible-word, update gaps and
Stop-to-paste separately from model download/load. Include cold launch and warm
sessions. The ASR benchmark's inference speed alone cannot establish UI latency.

## Permissions and unattended operation

For a dedicated first-run permission suite, Apple's supported
`resetAuthorizationStatus(for: .microphone)` resets the app's decision so that
access prompts again. It does **not** grant consent or inject microphone audio.
The local Xcode macOS SDK confirms the resource and reset API are available from
macOS 10.15.4. Handle expected permission dialogs directly in the test; Apple's
interruption monitors are for unrelated blocking UI, not expected workflow steps.
[Protected microphone resource](https://developer.apple.com/documentation/xcuiautomation/xcuiprotectedresource/microphone),
[authorization reset](https://developer.apple.com/documentation/xcuiautomation/xcuiapplication/resetauthorizationstatus(for:)),
[interruption handling](https://developer.apple.com/documentation/xctest/handling-ui-interruptions).

Microphone authorization still applies to virtual-device capture; BlackHole's
own troubleshooting calls this out. Use the permission UI/approved provisioning,
not direct writes to the TCC database. Apple's macOS documentation describes
`tccutil` as a reset mechanism. The macOS 26 PPPC payload lists microphone denial,
not a general silent microphone-grant mechanism. macOS 27's supervised-device
consent defaults are a different, later deployment feature and still present
consent UI; they are not a solution for an ordinary macOS 26 test account.
[Media authorization on macOS](https://developer.apple.com/documentation/bundleresources/requesting-authorization-for-media-capture-on-macos),
[PPPC payload](https://support.apple.com/en-my/guide/deployment/dep38df53c2a/web),
[managed consent changes](https://support.apple.com/guide/deployment/app-management-updates-depd567c9ffa/web).

For this repository, a dedicated logged-in, unlocked Mac is the smallest reliable
runner recommendation. Validate GUI, permissions, device availability and model
cache in preflight. Do not assume a headless cloud job can provide the same
WindowServer/audio-driver/Neural Engine environment. Whether a particular hosted
runner supports the entire setup requires a separate proof run.

## Phased delivery

- **Next:** one virtual-input smoke workflow for Apple and Nemotron: actual
  capture → recognition → HTTP fake → saved recording → external paste. Add
  Stop, Cancel/restart, quiet lead/tail, stereo right-only and source switching.
  Use the fixed synthetic fixture as the repeatable gate; benchmark private old
  recordings locally without checking their audio/transcripts into the PR.
- **Implemented baseline:** XCUITest owns settings, launch/relaunch, destination activation,
  shortcut, Escape and retry. First-run permission accept/deny remains proposed.
  Preserve results and timing evidence. Keep physical-key confirmation until the UI-test
  runner demonstrates actual cross-app delivery on this host.
- **Later, only if needed:** a custom deterministic virtual driver. Apple's
  minimal Audio Server plug-in sample publishes stereo float PCM at 44.1/48 kHz.
  It entails driver installation and maintenance; the separate DriverKit sample
  adds signing/entitlement requirements. BlackHole is a smaller first experiment.
  [Apple virtual-device sample](https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in),
  [DriverKit-backed sample](https://developer.apple.com/documentation/coreaudio/building-an-audio-server-plug-in-and-driver-extension).

No public Apple XCUI API for supplying a WAV as the system microphone was found
in the researched documentation. That is an evidence limit, not proof that no
private or third-party facility exists. Virtual Core Audio routing is the concrete
way to cover the real input path with the APIs and tools verified here.
