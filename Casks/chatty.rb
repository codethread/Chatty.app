cask "chatty" do
  version "0.3.0"
  sha256 "0814ac941b2dbad1233cfedba5f5a40f19095b721a89463c2001961a8b3cb43f"

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
