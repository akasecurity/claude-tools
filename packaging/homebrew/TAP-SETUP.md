# Homebrew Tap Setup

## One-time setup: create the tap repo

1. Create a new GitHub repo named **`homebrew-tap`** under the `akasecurity` org.
2. Copy `aka-claude-tools.rb` into the repo root as `Formula/aka-claude-tools.rb`.
3. Update the `sha256` field with the value printed in the GitHub Release notes for the current version.

Users can then install with:
```bash
brew tap akasecurity/tap
brew install akasecurity/tap/aka-claude-tools
```

Or in one line:
```bash
brew install akasecurity/tap/aka-claude-tools
```

## Updating the formula on each release

The release workflow (`release.yml`) prints the SHA-256 and the exact `url`/`sha256` lines to paste. Update `Formula/aka-claude-tools.rb` in the tap repo with those values and merge.

For automated tap updates, consider:
- [`dawidd6/action-homebrew-bump-formula`](https://github.com/dawidd6/action-homebrew-bump-formula) — adds a PR to the tap repo on every release
- Requires a `HOMEBREW_TAP_TOKEN` secret with write access to `homebrew-tap`
