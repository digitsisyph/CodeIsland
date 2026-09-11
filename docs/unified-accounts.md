# CodeIsland: app and account CLI in one repository

This fork contains the macOS CodeIsland app and the account-management source
imported from ccswap 0.31.0. `AccountCore` is ordinary tracked source, with its
original MIT license and pinned upstream provenance. There is no submodule,
external ccswap process, or separately installed quota service.

## Use from source

```sh
uv sync --project AccountCore
uv run --project AccountCore codeisland usage
uv run --project AccountCore codeisland usage --json
uv run --project AccountCore codeisland watch
uv run --project AccountCore codeisland claude add
uv run --project AccountCore codeisland codex add
uv run --project AccountCore codeisland claude switch 2
uv run --project AccountCore codeisland codex switch 2
```

Existing Claude profiles use the compatible account store outside this repository.
For Codex logins already saved in CodexBar, preview `codeisland import-codexbar`,
then run it with `--apply` to import. It preserves existing slots, distinguishes
email plus workspace, and never replaces the current Codex login. Once using the
imported accounts here, keep one account manager responsible for refreshing them;
multiple managers refreshing copied OAuth credentials can leave stale copies.

## Build and run

`./build.sh` produces `.build/release/CodeIsland.app`. Its
`Contents/Helpers/codeisland` executable includes Python and its
dependencies, and also serves as the standalone CLI entry point. End users need
only the app bundle. Build prerequisites are uv and the macOS Swift toolchain.
Full Xcode is optional for the enhanced icon assets; the bundled .icns is used
with Command Line Tools alone.

Expand the island and select its **Quota** tab beside **Sessions**. Both views
stay inside the same island; the selected tab is remembered when it collapses.
The menu-bar account action and idle-island gauge also open this inline tab,
including when no coding sessions are running.
The quota view reads the bundled core's versioned, credential-free snapshot
and refreshes once a minute while open. The source build uses this
checkout's virtual environment. The CLI and island display the same remaining
percentages, exact reset timestamps, scoped model windows, Codex reset-credit
counts and earliest expiry, active account, and last measurement time.

Missing values stay unknown. Old values are marked stale after a failed refresh;
identity/credential errors suppress old quota bars. Reading quotas never redeems
reset credits. Account switching remains an explicit CLI operation. Running Codex
processes may need restarting after a switch.

Upstream automatic updates are disabled in the bundled fork so a CodeIsland
update cannot remove the embedded account core. Publish app and core together.

## Verification

```sh
uv run --project AccountCore pytest AccountCore/tests/test_island.py AccountCore/tests/test_island_import.py AccountCore/tests/test_codex_usage.py AccountCore/tests/test_codex.py -n 2
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter AccountQuotaSnapshotTests
./build.sh
```

Python account tests isolate the real account store and Keychain. Never commit
login files, exported profiles, account-store directories, or real usage fixtures.
The XCTest suite requires Xcode; the command explicitly selects it on machines
whose default `xcode-select` points at Command Line Tools.
