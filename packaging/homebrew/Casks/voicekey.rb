cask "voicekey" do
  version "0.3.0"
  sha256 "1f47a619b4300c17076569039529020823498f1e1029a8c316d62598e69b6218"

  url "https://github.com/jamiezigelbaum/VoiceKey/releases/download/v#{version}/VoiceKey-#{version}-macOS.dmg"
  name "VoiceKey"
  desc "Menu bar hotkeys for realtime AI voice assistants"
  homepage "https://github.com/jamiezigelbaum/VoiceKey"

  auto_updates false
  depends_on macos: ">= :ventura"

  app "VoiceKey.app"

  zap trash: [
    "~/Library/Preferences/com.zigelbaum.VoiceKey.plist",
    "~/Library/WebKit/com.zigelbaum.VoiceKey",
  ]
end
