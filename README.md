# Brain Bento for iPhone

The App Store version of [playbentobrain.com](https://playbentobrain.com): the same ten games, plus
Apple Music for earworm, Game Center leaderboards, daily reminders, haptics and offline play.

## What's in here

| Path | What it is |
| --- | --- |
| `www/` | The games (one web page, built from the website code) and their fonts, so the app works offline. |
| `ios/` | The Xcode project. `ios/App/App/BBNativePlugin.swift` is the bridge to Apple Music, Game Center, reminders, haptics and the share sheet. |
| `capacitor.config.json` | App id `com.playbentobrain.app`, name, web folder. |
| `codemagic.yaml` | The cloud build: installs Capacitor, copies `www/` into the iOS project, signs, builds and uploads to TestFlight. |

## Updating the app

1. Replace `www/index.html` (and `www/fonts/` if it changed) with the new build.
2. Bump `MARKETING_VERSION` (for example `1.0.1`) in `ios/App/App.xcodeproj/project.pbxproj` (it appears twice).
3. Push to GitHub, then start the **Brain Bento → TestFlight** workflow in Codemagic. Build numbers count up by themselves.

## Leaderboard ids (create these in App Store Connect → Game Center)

`bb.points`, `bb.ear`, `bb.word.streak`, `bb.arrow`, `bb.pitch`, `bb.hue`, `bb.dots`, `bb.echo`, `bb.flash`, `bb.pop`, `bb.clock`
