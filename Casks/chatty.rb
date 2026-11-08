cask "chatty" do
  version "0.4.1"
  sha256 "088022c614c0dd48fa44b6663d9b899f20c59289cdd5e68910d8d0514a25f5f5"

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
