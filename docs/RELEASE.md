# Release Process

VoiceKey ships as a signed and notarized macOS app distributed through GitHub
Releases. Homebrew should install the same DMG via a cask.

## First-Time Apple Setup

1. Join the Apple Developer Program.
2. Create or install a `Developer ID Application` certificate in Keychain.
3. Create a notarytool keychain profile:

```zsh
xcrun notarytool store-credentials voicekey-notary \
  --apple-id "you@example.com" \
  --team-id "TEAMID1234" \
  --password "app-specific-password"
```

## Build A Local Release

Unsigned local release:

```zsh
./scripts/package-release.zsh
```

Signed and notarized public release:

```zsh
export VOICEKEY_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID1234)"
export VOICEKEY_NOTARY_KEYCHAIN_PROFILE="voicekey-notary"
./scripts/package-release.zsh
```

The script creates:

- `dist/VoiceKey-0.1.0/VoiceKey-0.1.0-macOS.dmg`
- `dist/VoiceKey-0.1.0/VoiceKey-0.1.0-macOS.zip`
- `dist/VoiceKey-0.1.0/SHA256SUMS.txt`

## Publish A GitHub Release

After packaging:

```zsh
./scripts/github-release.zsh
```

The script tags the current commit as `v0.1.0`, pushes the tag, and creates a
draft GitHub Release with the DMG, ZIP, and checksums attached.

Review the draft release in GitHub before publishing.

## Homebrew Cask

After the DMG exists:

```zsh
./scripts/update-homebrew-cask.zsh
```

This writes `packaging/homebrew/Casks/voicekey.rb` with the correct version,
GitHub Release URL, and SHA-256 checksum.

For public distribution, put that cask in a tap repository, for example:

```zsh
brew tap jamiezigelbaum/voicekey
brew install --cask voicekey
```

Later, once the project has enough usage, submit the cask to Homebrew Cask.
