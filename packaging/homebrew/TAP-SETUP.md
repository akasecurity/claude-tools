# Homebrew Tap Setup

The tap is live at **[akasecurity/homebrew-tap](https://github.com/akasecurity/homebrew-tap)**
(`Formula/aka-claude-tools.rb`). Users install with:

```bash
brew install akasecurity/tap/aka-claude-tools
```

## How the formula is sourced (decoupled from npm)

The formula installs from the **auto-generated git tag tarball**
(`https://github.com/akasecurity/claude-tools/archive/refs/tags/vX.Y.Z.tar.gz`), which GitHub
creates for every tag. This has **no dependency on npm or a published GitHub Release** — Homebrew
works the moment a tag exists. `aka-claude-tools.rb` in this repo is the source of truth; the tap
holds a copy.

## Updating the formula on a new release

After tagging `vX.Y.Z` on the public repo, compute the sha256 of the tag tarball and update both
`url` and `sha256` (here and in the tap repo):

```bash
VER=X.Y.Z
URL="https://github.com/akasecurity/claude-tools/archive/refs/tags/v${VER}.tar.gz"
curl -sL "$URL" | shasum -a 256   # paste into the formula's sha256
```

For automated tap updates, consider
[`dawidd6/action-homebrew-bump-formula`](https://github.com/dawidd6/action-homebrew-bump-formula)
(adds a PR to the tap repo on each release; needs a `HOMEBREW_TAP_TOKEN` with write access to
`homebrew-tap`).
