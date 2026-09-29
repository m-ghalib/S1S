---
name: release
description: |
  Cuts a S1S release: bumps the version (release 0.1.4 -> 0.1.5, or hotfix
  0.1.4 -> 0.1.4.1), writes the in-app release notes, builds the signed Release
  app and DMG into dist/, replaces the installed copy in /Applications, and, only
  when the user asks, tags and publishes a GitHub release.
  USE WHEN the user says "release", "cut a release", "ship 0.1.5", "hotfix
  release", "new dist and install it", "bump the version", "/release", or asks to
  publish a GitHub release of S1S. Not for a plain dev rebuild; use
  ./Scripts/build.sh app for that.
argument-hint: "[release|hotfix|current] [github]"
---

# Release S1S

Run everything from the repo root. Scripts live in `.claude/skills/release/scripts/`.

## Version rule

| Kind | Effect | Example |
|------|--------|---------|
| `release` | Third number +1; any fourth number is dropped. | 0.1.4 → 0.1.5, 0.1.4.2 → 0.1.5 |
| `hotfix` | Adds or increments a fourth number. | 0.1.4 → 0.1.4.1 → 0.1.4.2 |
| `current` | Keeps the `Info.plist` version; only the build number increases. | 0.1.4 → 0.1.4 |

`current` exists because fix commits sometimes bump `Resources/Info.plist` without a release. The version is then untagged and has never shipped.

The build number (`CFBundleVersion`) increases by 1 on every run of `Scripts/release.sh`.

## 1. Decide the scope

1. Read the requested kind from the arguments or the request. Use `release` when the user says "minor", "normal", or "next". Use `hotfix` when the user says "hotfix", "patch on top", or gives a four-part version.
2. Run `.claude/skills/release/scripts/next-version.sh <kind>`. Its stderr reports the current version, whether that version is tagged, and the latest tag.
3. If no kind was given and the current version is untagged (`tagged=no`), ask the user one question: release the current version as it is, or bump. Otherwise use `release`.
4. Publish to GitHub only when the user asked for it ("github", "publish", "git release", "tag it"). Otherwise stop after the local install and offer it in one line.

## 2. Preflight

Stop and report if any check fails.

1. `git status --porcelain` is empty, and the branch is `main`. Uncommitted work would ship in the build without being in the tagged commit.
2. `security find-identity -v -p codesigning | grep "TabType Dev"` finds the identity. Never run `Scripts/setup-signing.sh` to fix a missing identity; that creates a different certificate and resets every user's Accessibility grant (see `RELEASING.md`).
3. `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` passes.

## 3. Write the release notes

The app bundles `Sources/S1S/Resources/CHANGELOG.md` and shows the section for its own version in **Settings ▸ About ▸ What's New**. It opens that page once after an update. `Scripts/release.sh` refuses to build a version that has no section.

1. Collect the changes since the latest tag:
   ```sh
   git log <latest_tag>..HEAD --no-merges --format='- %s%n%b'
   ```
   For a `current` release, this range covers the whole untagged version. For TT-### references, read the matching entries in `docs/ISSUES.md` to learn the user-visible effect.
2. If the changelog already has a `## <version>` section (for example, one seeded earlier), start from it and add what is missing.
3. Draft 3 to 8 bullets for users, not developers:
   - Start each bullet with a present-tense verb: "Adds", "Fixes", "Keeps", "Speeds up".
   - Describe what the user sees, not the mechanism. Name the app when a fix is app-specific ("in Claude Desktop").
   - Leave out `tidy:`, `docs:`, `test:` and refactor commits, TT-### IDs, file names, and internal type names.
   - Do not use em dashes. TT-021 removed them from all in-app text.
   - Inline Markdown works (`**Tab**`, `` `code` ``). Nested lists and headings inside a section do not render.
4. Show the draft in chat and ask the user to approve or edit it. The text ships inside the app, so do not skip this step.
5. Insert the approved section at the top of the changelog, below the HTML comment and above the newest existing section:
   ```markdown
   ## 0.1.5

   - Adds ...
   - Fixes ...
   ```

## 4. Build the dist

1. Run the release script. It takes several minutes; use a 600000 ms timeout or run it in the background.
   ```sh
   ./Scripts/release.sh <version>
   ```
   The script checks the changelog section, stamps the version and build number into `Resources/Info.plist`, builds with `CONFIG=Release`, refuses ad-hoc signatures, and writes `dist/S1S.app` and `dist/S1S-<version>.dmg`. Keep the SHA-256 it prints for step 7.
2. Verify the bundle:
   ```sh
   plutil -extract CFBundleShortVersionString raw dist/S1S.app/Contents/Info.plist   # expect <version>
   find dist/S1S.app -name CHANGELOG.md                                              # expect one match
   codesign -dvv dist/S1S.app 2>&1 | grep Authority=                                 # expect TabType Dev
   ```

## 5. Replace the installed app

This step quits S1S and moves every installed copy (`/Applications/S1S.app`, `~/Applications/S1S.app`) to the Trash. The Accessibility grant survives, because the new copy has the same signing identity.

1. Run:
   ```sh
   .claude/skills/release/scripts/install-app.sh --open
   ```
2. Check the launch line in `~/Library/Logs/S1S/s1s.log`:
   ```sh
   grep "S1S launched" ~/Library/Logs/S1S/s1s.log | tail -1
   ```
   Expect `version=<version>` and `ax=true`. If the installed version was older, also expect an `announcing release notes for <version>` line, and the Settings window opens on What's New.
3. Capture the What's New page with `screencapture -x "$S/whatsnew.png"` (`$S` is the session scratchpad) and read it. Confirm the version and the bullets. If the page did not open by itself, open it from the menu-bar item **What's New**.

## 6. Commit

Commit the version stamp and the notes together:

```sh
git add Resources/Info.plist Sources/S1S/Resources/CHANGELOG.md
git commit -m "chore: release <version>"
```

End the message with the attribution lines required by the session. Do not push unless step 7 runs.

## 7. GitHub release (only when requested)

Pushing a tag and publishing a release are outward-facing. Confirm with the user before this step, even when they asked for a release earlier, unless they said to publish without asking.

1. Resolve the repository from `origin`. Do not rely on the `gh` default; `upstream` (nilava/TabType) is a different repository.
   ```sh
   REPO="$(git remote get-url origin | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')"
   ```
2. Push the commit and the tag:
   ```sh
   git push origin main
   git tag v<version>
   git push origin v<version>
   ```
3. Write the body to `$S/release-body.md`. Use this template. Copy the bullets from the changelog section, and fill in the version and the SHA-256:
   ```markdown
   ### What's new

   - <bullets from the changelog>

   ### Install

   S1S is not notarized (it is free and non-commercial), so macOS shows a warning the first time.

   1. Download `S1S-<version>.dmg` below, open it, and drag **S1S** to **Applications**.
   2. Launch it. macOS says it "cannot be opened." Click **Done**.
   3. Open **System Settings ▸ Privacy & Security**, and click **Open Anyway** next to S1S. Confirm.
      - Or in Terminal: `xattr -dr com.apple.quarantine /Applications/S1S.app`
   4. Grant **Accessibility** when asked (required). Screen Recording is optional.
   5. First launch downloads the model (~0.3–4.3 GB, depending on RAM). The menu-bar icon shows progress.

   Updating? Drag the new copy over the old one. Permissions and downloaded models are kept.

   **Requirements:** Apple Silicon Mac (M1 or later), macOS 14+.

   SHA-256: `<sha256>`
   ```
4. Publish as a pre-release, like earlier releases. Make the title tagline a few words from the top bullets:
   ```sh
   gh release create v<version> dist/S1S-<version>.dmg --repo "$REPO" --prerelease \
     --title "S1S v<version>: <tagline>" --notes-file "$S/release-body.md"
   ```
5. Report the release URL that `gh` prints.

## Report

State what happened, in this order: version and build, DMG path and SHA-256, the old version moved to the Trash, the installed version and the launch check, the commit hash, and the GitHub release URL or "not published". Report any skipped step and why.
