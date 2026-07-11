class AkaClaudeTools < Formula
  desc "Security defaults for Claude Code — clean context, locked-down credentials, guarded egress"
  homepage "https://github.com/akasecurity/claude-tools"
  url "https://github.com/akasecurity/claude-tools/releases/download/v0.4.0/aka-claude-tools-0.4.0.tar.gz"
  sha256 "PLACEHOLDER_SHA256_UPDATE_ON_RELEASE"
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
