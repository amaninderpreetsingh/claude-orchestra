# iOS native recipe (Capacitor apps on the Simulator)

Default recipe for slices/criteria marked `native` when the repo has none of its own (a repo `CLAUDE.md` or repo skill wins). Proof = **committed Maestro flows run on your own simulator clone**. cmux-cua is for exploration and extra screenshots only, never the proof.

**Shell rules.** Every Bash tool call is a fresh shell (zsh here, not bash): variables and `trap`s do not survive to the next call, and `PIPESTATUS` doesn't exist. So: set `SIM`, `OWNER`, `ARTIFACTS`, `DD` and `UDID` at the top of **every** call (re-running `acquire` is idempotent and instant once the clone exists), never rely on a `trap` for cleanup, and use `set -o pipefail` (works in zsh and bash) to get a pipeline's exit code. A cold `acquire` (create + boot) or an `xcodebuild` can exceed the default 2-min tool timeout — pass a 10-min timeout or run it in the background.

## 1. Your own simulator — `orch-sim`
```bash
SIM=~/.claude/orchestra/bin/orch-sim
UDID=$($SIM acquire --owner "$OWNER" [--device "iPhone 16"])   # clone orch-$OWNER, booted; idempotent
```
- One clone per owner (verifier uses `<owner>-verify`), so two native verifications run at once. Never use a shared/base device, never `simctl erase`/`delete` anything not yours.
- **Release is an explicit last step on every exit path** (pass, fail, or giving up): `$SIM release --owner "$OWNER"`. `$SIM reap` is only the backstop — it deletes clones whose owner (or `<owner>-…`) has no active worker. `$SIM list` shows clones; `reap --dry-run` previews.

## 2. Build — output to a log, only the summary to the agent
```bash
npm run build && npx cap sync ios
LOG=$ARTIFACTS/xcodebuild.log; DD=/tmp/$OWNER-dd                  # per-owner derived data, never shared
set -o pipefail
xcodebuild -workspace ios/App/App.xcworkspace -scheme App -configuration Debug -destination "id=$UDID" -derivedDataPath "$DD" build 2>&1 | tee "$LOG" | xcbeautify --quieter > "$LOG.errors"
rc=$?; echo "xcodebuild exit $rc (full log: $LOG)"; [ "$rc" = 0 ] || grep -m1 'error:' "$LOG"
```
- That prints two lines at most: the exit summary and the first `error:`. Read more from `$LOG` / `$LOG.errors` (xcbeautify's errors-only view) with `grep`/`tail` only when you need it — never let raw xcodebuild or warning lists into the conversation.
- No `App.xcworkspace` (Capacitor SPM projects) → `-project ios/App/App.xcodeproj`.
- xcbeautify missing → `brew install xcbeautify`; until then drop `| xcbeautify … > "$LOG.errors"` (the `tee` to `$LOG` stays) and use the same summary + first-error line.

## 3. Install + launch via simctl
```bash
APP=$(ls -d "$DD"/Build/Products/Debug-iphonesimulator/*.app | head -1)
BUNDLE=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Info.plist")
xcrun simctl install "$UDID" "$APP" && xcrun simctl launch "$UDID" "$BUNDLE"
xcrun simctl openurl "$UDID" "<scheme>://path"                    # deep links, when the criterion needs one
xcrun simctl io "$UDID" screenshot "$ARTIFACTS/<state>.png"
```

## 4. Maestro flows — the committed proof
- One flow per native criterion under `.maestro/`, named for it (e.g. `.maestro/c3-add-todo.yaml`). Worker writes it first and watches it fail; verifier runs it. A native criterion without a flow is a FAILURE.
```yaml
appId: com.example.app        # capacitor.config appId
---
- launchApp: { clearState: true }
- tapOn: "Add todo"
- inputText: "Buy milk"
- pressKey: Enter
- assertVisible: "Buy milk"
- takeScreenshot: c3-added
```
- Run: `maestro --device "$UDID" test .maestro/ --format junit --output "$ARTIFACTS/maestro.xml" > "$ARTIFACTS/maestro.log" 2>&1; echo "maestro exit $?"` — then report pass/fail counts + the first failing step from the log, not the whole log.
- Prefer text/accessibility ids (`id:`) over coordinates; WebView content is matched by visible text.
- Done (any outcome) → `$SIM release --owner "$OWNER"`.

## 5. Native Swift tests (only if the repo has a test target)
`set -o pipefail; xcodebuild test -workspace … -scheme App -destination "id=$UDID" -derivedDataPath "$DD" 2>&1 | tee "$ARTIFACTS/xctest.log" | xcbeautify --quieter > "$ARTIFACTS/xctest.errors"; rc=$?` — same summary + first error rule. No test target, or it can't run headless → report **NOT EXERCISED** ("no Swift test target"), never PASS.

## 6. Exploration (optional)
cmux-cua (`start_session` with session `<owner>-verify`, always `end_session`) to look around or capture extra screenshots. Its observations are evidence for the report, never a substitute for a flow.
