cask "chatty" do
  version "0.2.0"
  sha256 "9ff91f8ae8853db2b2cd8bde6d342fd53946681c937e5ca8f7e62040e7161f28"

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
