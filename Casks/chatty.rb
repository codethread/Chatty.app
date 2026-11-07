cask "chatty" do
  version "0.4.0"
  sha256 "060054014458ef1e00b74eda868a066fc1bb6918d2c18e45bf5651738a525698"

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
