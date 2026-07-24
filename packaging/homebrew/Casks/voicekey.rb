cask "voicekey" do
  version "0.2.0"
  sha256 "df88a7b7701dd74a7450e07c7af6eea20de236a9760779359db54807eb3deff7"

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
