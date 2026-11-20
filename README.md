# Jiggle Jam

Movement games for little kids, played on the TV. The Mac's camera (or an iPhone via
Continuity Camera) watches the player, Apple's Vision framework tracks their body, and the
game reacts to their hands and feet. AirPlay the Mac to the TV and play from the couch.

## Games

- **Bubble Pop** — bubbles float up; pop them with hands (white rings) or feet (yellow rings).
  No way to lose; a spoken cheer and confetti every 10 pops.

## Run it

Requires macOS 14+, Xcode, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
xcodegen generate
open JiggleJam.xcodeproj   # then ⌘R
```

## Playing on the TV

1. **Camera:** pick it in the menu. An iPhone appears automatically as a Continuity Camera
   (same Apple ID, Wi‑Fi + Bluetooth on). Mount it in landscape below/above the TV.
2. **TV:** Control Center → Screen Mirroring → your Apple TV / AirPlay TV.
3. Click **Full Screen**, press **Return** to start, **Esc** to go back to the menu.
4. Stand 2–3 m back so the camera sees the whole body (the menu tells you when it does).

## How it works

| File | Role |
| --- | --- |
| `Sources/CameraManager.swift` | Capture session, camera picking, Vision body-pose per frame → hand/foot points |
| `Sources/CameraPreview.swift` | Mirrored live camera background |
| `Sources/BubbleScene.swift` | SpriteKit game: spawning, collisions, effects, sound, speech |
| `Sources/JiggleJamApp.swift` | App, parent menu, game screen |
