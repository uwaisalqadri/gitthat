class Gitthat < Formula
  desc "Agentic Git CLI that writes commit messages and rewrites history"
  homepage "https://github.com/uwaisalqadri/gitthat"
  head "https://github.com/uwaisalqadri/gitthat.git", branch: "main"

  depends_on xcode: ["15.0", :build]
  depends_on :macos

  def install
    system "swift", "build", "-c", "release", "--disable-sandbox"
    bin.install ".build/release/gitthat"
  end

  def caveats
    <<~EOS
      GITTHAT drives an agent CLI you are already logged in to (claude, codex,
      ollama, ...). Verify one works before using it:

        echo "Reply with the word OK and nothing else." | claude -p
    EOS
  end

  test do
    assert_match "gitthat", shell_output("#{bin}/gitthat --help")
  end
end
