# S1S release notes

<!--
Newest version first. Each release is a "## <version>" heading followed by "- " bullets.
The app bundles this file and shows the section for its own version in
Settings > About > What's New, and opens that page once after an update.
Bullets support inline Markdown (**bold**, `code`, links). Do not use em dashes.
-->

## 0.1.5.1

- Moves Macs still set to an older model to the recommended Qwen3.5 model. Custom models you entered are kept.

## 0.1.5

- Switches to the newer Qwen3.5 models, and picks one that suits your Mac's chip and memory.
- Adds three simple model choices in Settings: Fastest, Balanced, and Most accurate, with estimated speed and memory fit for your Mac.
- Adds Gemma 4 12B for Macs with 32 GB or more of memory.
- Stops suggestions and autocorrect when you type outside a text field, such as in games, Finder, or web-page shortcuts.
- Removes inline `/` macros (date, units, arithmetic). `:emoji` and autocorrect remain.
- Updates the menu-bar icon.

## 0.1.4

- Asks for a short writing profile on first run, and uses it to personalize suggestions.
- Reorganizes Settings into four pages: Suggestions, Apps, Model & Power, and About.
- Keeps the ghost text visible after **Tab** accepts a word.
- Places ghost text correctly in Claude Desktop: over the placeholder, at the start of a line, and in multi-paragraph messages.
- Removes the gap between the caret and the ghost text, and stops one-letter restatements of the word you are typing.
- Adds this What's New page. It opens once after each update.

## 0.1.3

- Caps the MLX GPU buffer cache to stop memory growth over long sessions.
- Reads the Claude Desktop conversation (not the sidebar) for screen context.
- Extends app coverage: chat apps, Superhuman, Chromium browsers, and safety gaps.
- Wraps long suggestions correctly in Claude Desktop.
- Fixes a stale first-ghost caret, a false incomplete-download error, and mid-word cutoffs.
- New app icon.
