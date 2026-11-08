# Land a Chatty release

Use this when the user asks to land, release, or merge and update their Homebrew
install. It covers commit → merge → version/archive → push/publish → upgrade →
cleanup. Test scope and evidence rules live in [testing](testing.md); permission
setup lives in [permissions](permissions.md).

## Commit and merge

Inspect Git status, remotes, default branch and other worktrees. Review and commit
the task's changes, fetch `origin`, and integrate the branch into `main`, preferring
a fast-forward. Keep unrelated edits out of commits and preserve published history.

Read the current [verification evidence](verification.md). Reuse checks for
unchanged source and complete missing affected checks. Record any known limitation
the user has accepted for release; an incomplete full gate remains incomplete.

## Bump and package

Choose the next version from the latest published release and repository metadata;
use a patch for fixes unless directed otherwise. `Sources/Chatty/Info.plist` owns
both `CFBundleShortVersionString` and `CFBundleVersion`. The root
`Casks/chatty.rb` owns the Homebrew version and archive SHA256. The app repository
is also the tap source; there is no separate release workflow.

After updating the plist, build the real production archive. For an example
version of `0.4.1` (substitute the selected version throughout):

```sh
qlock exec --lock /tmp/agent-cpu.lock -w 60 -- ./scripts/package-release.sh 0.4.1
```

Extract `build/Chatty-0.4.1-arm64.zip` to a fresh staging directory and run
`swift scripts/verify-release.swift /path/to/extracted/Chatty.app` and
`codesign --verify --strict /path/to/extracted/Chatty.app`. Verify the extracted
version and compute the ZIP's SHA256. Update the cask with that exact version and
checksum, review the diff, and commit the release metadata. Packaging must not
use `CHATTY_DEBUG_PANEL` or the numbered installer.

## Push and publish

Push `main`, create/push `v0.4.1` at the release commit, and publish the verified
archive with `gh release create --verify-tag --notes-file ...`. Release notes
describe resulting behavior, validation and known limitations. Check GitHub's
published version and asset digest against the local ZIP before upgrading.

Inspect state before retrying a partial release. Resume missing steps for the same
version; preserve already published tags and asset bytes.

## Upgrade Homebrew

The cask is `codethread/chatty/chatty`. Discover the local tap with
`brew --repository codethread/chatty`. Inspect its status before fetching and
fast-forwarding its `main` to the published release commit; preserve any unrelated
local edits. Since this is the app repository itself, no second cask commit/push
is needed.

```sh
brew upgrade --cask codethread/chatty/chatty
brew list --cask --versions chatty
open -a Chatty
```

Verify `/Applications/Chatty.app` has the selected version, production menu-bar
identity and no debug harness. Check its signature, compare its executable with
the verified archive, and check the `chatty` launcher resolves to that installed
binary. Confirm the installed app process launches. Preserve existing privacy
decisions; macOS may still request trust after an ad-hoc signed update.
Startup also runs the documented five-day recording retention. Distinguish that
normal pruning from explicit debug cleanup when checking data preservation.

## Remove test/debug artifacts

After the Homebrew install is verified, summarize verification in committed
documentation/release notes before removing raw evidence. Inventory the current
and other Chatty worktrees, installed app metadata and test-runner temporary
storage. Stop only identified project test/debug processes.

Remove owned `build/` output, synthetic debug data/control files, UI DerivedData
and numbered `/Applications/Chatty <N>.app` test installs after confirming their
`local.chatty.Chatty.build<N>` identifiers. Use `swift package clean` in each
affected checkout to remove compiled products while retaining dependency caches.
Remove test-runner synthetic workspaces only from its identified container/temp
location. Apply Homebrew cleanup to obsolete cask versions.
Remove preferences, caches and HTTP storage only for the identified test/debug
bundle IDs; keep the production `local.chatty.Chatty` domains.

Keep the source worktrees and `/Applications/Chatty.app`. Preserve
`~/Library/Application Support/Chatty/` (production recordings/config and the
numbered-build counter), the login Keychain, privacy grants and the shared
`~/Library/Application Support/FluidAudio/Models/` cache. Numbered builds can use
that same production store. Separately identified debug-only stores can be removed.

Verify the production app still runs, the intended Git changes are pushed, and
the inventoried test/debug bundles and data are gone. Report the release/install,
cleanup and remaining verification gaps.
