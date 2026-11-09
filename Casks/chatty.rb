cask "chatty" do
  version "0.5.1"
  sha256 "4cac52e4bda52cf9e742b067c1f4e32f9994f102dfc65313a455ec6512402843"

  url "https://github.com/codethread/Chatty.app/releases/download/v#{version}/Chatty-#{version}-arm64.zip"
  name "Chatty"
  desc "Menu-bar dictation helper"
  homepage "https://github.com/codethread/Chatty.app"

  depends_on arch: :arm64
  depends_on macos: :tahoe

  app "Chatty.app"
  binary "#{appdir}/Chatty.app/Contents/MacOS/Chatty", target: "chatty"

  uninstall quit: "local.chatty.Chatty"

  caveats do
    unsigned_accessibility
    <<~EOS
      Chatty is ad-hoc signed, not notarized. If macOS blocks its first launch,
      allow it in System Settings > Privacy & Security > Open Anyway.

      Launch Chatty from Applications or with: open -a Chatty
      Grant Microphone and Accessibility permissions when prompted.
      Set your OpenAI API key from its menu-bar icon.
    EOS
  end
end
