# CatWatch 🐈

Turns a spare iPhone into a cat detector. Point it at the backyard, outline the no-go
zone (the grass), and it sends a [Pushover](https://pushover.net) alert with a
snapshot when the cat walks into it. Pushover delivers to Android, Mac, and anything else.

- On-device detection with Apple's Vision framework (`VNRecognizeAnimalsRequest`), with no cloud and no subscription.
- Draw a polygon zone. A cat on the deck is ignored; a cat in the grass triggers an alert.
- Debounced: it needs N sightings within a few seconds, then waits for a cooldown.
- History of every alert with the snapshot.
- Health alerts when the phone is unplugged, the battery is low, it's overheating, the camera stalls, or the app is closed.
- Blanks the OLED screen while watching; tap to wake.

## Installing (free Apple ID, no Xcode needed)

GitHub Actions builds an unsigned `.ipa` on every push to `main` and publishes it as a
release. [AltStore](https://altstore.io) signs it with your free Apple ID and
**re-signs it over Wi-Fi** before the 7-day limit, as long as your Mac is running AltServer.

1. On the Mac, install **AltServer** from altstore.io and follow its setup guide to put
   AltStore on the iPhone. This needs a USB cable once.
2. On the iPhone, turn on Settings › Privacy & Security › **Developer Mode** (iOS 16+).
3. Get the app:
   - **Public repo:** in AltStore › Sources › **+**, add
     `https://github.com/DarkChromaMC/CatWatch/releases/latest/download/source.json`,
     then install CatWatch. Updates show up in AltStore after each new release.
   - **Private repo:** download `CatWatch.ipa` from the latest GitHub release on the Mac,
     then use the AltServer menu › Sideload .ipa. To update, repeat with the new file.
4. Keep AltServer running on the Mac, on the same Wi-Fi as the phone, so AltStore
   can refresh the app in the background.

> Free Apple IDs can have 3 sideloaded apps active at once, and AltStore counts as one.

### Or build with Xcode

```sh
brew install xcodegen
xcodegen generate
open CatWatch.xcodeproj
```
Choose your Apple ID team under Signing & Capabilities and run on the phone. Free-account
installs expire after 7 days.

## Setting up

1. **Pushover:** copy your *User Key* from the pushover.net dashboard. Create an
   application called "CatWatch" to get an *API Token*. Paste both into CatWatch's
   Settings, then tap **Send test notification**.
2. **Mount the phone** facing the yard and keep it on a charger.
3. Tap **Zone** and tap around the grass area to outline it, then **Save**.
   Without a zone, any cat in view triggers an alert.
4. Turn on **Guided Access** (Settings › Accessibility) and triple-click the side button
   to lock the phone into CatWatch. iOS stops the camera if the app leaves the foreground.

## Tuning

| Setting | Default | Notes |
|---|---|---|
| Min confidence | 50% | Lower it if the cat is small or far away; raise it for fewer false alarms. |
| Sightings before alert | 2 | In-zone detections needed within 4 s. |
| Cooldown | 2 min | Minimum time between cat alerts. |
| Checks per second | 3 | Higher catches quick jumps but uses more power and heat. |
| Ultra-wide lens | off | Wider view, but the cat looks smaller. |
| Priority | High | Emergency repeats every minute until you acknowledge it. |

## Project layout

```
CatWatch/App        app entry + MonitorController (wires everything together)
CatWatch/Camera     AVFoundation capture + frame throttling
CatWatch/Detection  Vision detector, zone geometry, debounce gate
CatWatch/Alerts     Pushover client, snapshot rendering
CatWatch/Storage    settings, Keychain, event history
CatWatch/Views      SwiftUI screens
CatWatchTests       unit tests for zone, gate and multipart encoding
```
