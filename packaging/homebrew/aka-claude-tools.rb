class AkaClaudeTools < Formula
  desc "Security defaults for Claude Code — clean context, locked-down credentials, guarded egress"
  homepage "https://akasecurity.io"
  url "https://github.com/akasecurity/claude-tools/archive/refs/tags/v0.4.0.tar.gz"
  sha256 "15b3e91e46a8bdb20bbdfff57f8bcf8226191abdad6e599fe48292ed5f571685"
  license "MIT"
  version "0.4.0"

  depends_on "jq"
  depends_on "bun"

  def install
    libexec.install Dir["*"]
    (bin/"aka-claude-tools").write <<~BASH
      #!/usr/bin/env bash
      exec "#{libexec}/install.sh" "$@"
    BASH
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/aka-claude-tools --version")
  end
end
