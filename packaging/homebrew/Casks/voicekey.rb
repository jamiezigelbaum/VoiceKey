cask "voicekey" do
  version "0.1.0"
  sha256 "fd5f665d518a245d6640a9002c41cf9671692761b224b7e24ea993152fddf288"

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
