# CatWatch — planning notes

Goal: a spare iPhone 13 Pro Max points at the backyard. When the cat jumps the deck
fence into the grassy (chicken) area, send an alert with a photo to an Android phone
and a Mac.

## Requirements (agreed so far)
- Detect a cat on-device; no cloud vision service.
- Optional user-drawn "no-go zone" (the grass). Alert only when the cat is inside it.
  With no zone, any cat in frame alerts.
- Alerts: Pushover (Android + desktop), ntfy as a free alternative.
- Attach a snapshot with the cat boxed. Cooldown between alerts.
- Event history with thumbnails on the phone.
- Keep the screen awake and dimmed; the phone runs plugged in and locked open with Guided Access.
- Later: short video clip, live view over the LAN.

## Open decisions
- Native Swift app vs. Safari web app (see trade-offs below).
- Native only: free Apple ID (re-sign every 7 days) vs. paid developer account.

## Native app vs. Safari web app

| | Native (Swift, Vision) | Safari web app (TF.js COCO-SSD) |
|---|---|---|
| Install | Needs a Mac + Xcode; free signing expires every 7 days | Open a URL; no Mac, no expiry |
| Hosting | None | Needs HTTPS hosting (camera access requires it) |
| Detection | Apple Vision on the Neural Engine: efficient, accurate | Runs on the GPU in WebGL: hotter, more battery, lower frame rate |
| Reliability | Stable when left open | Safari may reload the tab or drop the camera after hours or a memory spike; needs a watchdog |
| Camera control | Full: exposure, low light, lens choice | Basic `getUserMedia`; less low-light control |
| Secrets | Stored in the Keychain | Pushover token sits in the page's storage |
| Update | Rebuild in Xcode | Push to the repo |
