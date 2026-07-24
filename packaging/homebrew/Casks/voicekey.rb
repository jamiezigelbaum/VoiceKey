cask "voicekey" do
  version "0.2.1"
  sha256 "367b9207c9d5f7fcb45af26670cf9781f978ad1049b85c895408da1a837e3d17"

  url "https://github.com/jamiezigelbaum/VoiceKey/releases/download/v#{version}/VoiceKey-#{version}-macOS.dmg"
  name "VoiceKey"
  desc "Menu bar hotkey for ChatGPT Voice"
  homepage "https://github.com/jamiezigelbaum/VoiceKey"

  auto_updates false
  depends_on macos: ">= :ventura"

  app "VoiceKey.app"

  zap trash: [
    "~/Library/Preferences/com.zigelbaum.VoiceKey.plist",
    "~/Library/WebKit/com.zigelbaum.VoiceKey",
  ]
end
