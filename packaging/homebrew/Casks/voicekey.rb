cask "voicekey" do
  version "0.2.2"
  sha256 "f2ae698c59bdc8fdd83d801ad59496f46589bf9925eea30c3f9b4d66189f3fb0"

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
