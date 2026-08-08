class Chatty < Formula
  desc "Menu-bar dictation helper for macOS"
  homepage "https://github.com/codethread/Chatty.app"
  url "https://github.com/codethread/Chatty.app.git",
      branch:   "main",
      revision: "0311040f1732cafe1f16a72570ad80adca18924d"
  version "0.1.0"

  depends_on macos: :sequoia

  def install
    system "swift", "build", "-c", "release"

    app = prefix/"Chatty.app"
    (app/"Contents/MacOS").mkpath
    cp ".build/release/Chatty", app/"Contents/MacOS/Chatty"
    cp "Sources/Chatty/Info.plist", app/"Contents/Info.plist"

    (bin/"chatty").write <<~EOS
      #!/usr/bin/env bash
      exec "#{app}/Contents/MacOS/Chatty" "$@"
    EOS
  end

  def caveats
    <<~EOS
      Run Chatty with:
        chatty

      Or open its app bundle with:
        open #{prefix}/Chatty.app

      On first launch, grant Chatty Microphone and Accessibility permissions in
      System Settings. Set your OpenAI API key from its menu-bar icon.
    EOS
  end

  test do
    assert_predicate prefix/"Chatty.app", :directory?
    assert_predicate prefix/"Chatty.app/Contents/MacOS/Chatty", :executable?
  end
end
