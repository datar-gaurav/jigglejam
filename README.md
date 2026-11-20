# Jiggle Jam

Movement games for little kids, played on the TV. The Mac's camera (or an iPhone via
Continuity Camera) watches the player, Apple's Vision framework tracks their body, and the
game reacts to their hands and feet. AirPlay the Mac to the TV and play from the couch.

<p align="center">
  <img src="docs/screenshots/menu.jpg" width="49%" alt="Jiggle Jam menu: colorful game cards with a status pill and a control bar">
  <img src="docs/screenshots/setup.jpg" width="49%" alt="Setup screen: big instruction with a checklist of hands, feet and distance">
</p>

<sub>Screenshots use a placeholder where the live camera appears. Regenerate them with
`JiggleJam -snapshot docs/screenshots` (debug builds).</sub>

## Games

- **Bubble Pop** — bubbles float up; pop them with hands (white rings) or feet (yellow rings).
  No way to lose; a spoken cheer and confetti every 10 pops.
- **Freeze Dance** — built-in music plays and sparkles fly off the hands while dancing; when the
  music stops, freeze! Holding still earns a star. A wobbly freeze is just "let's try again".
- **Rocket Jump** — every jump moves the rocket one step closer to the Moon (10 jumps), then
  Saturn, then the stars. Jumps are counted out loud; no timing needed.
- **Vroom Vroom** — hold a dinner plate like a steering wheel and turn it to drive a car down a
  curvy country road, collecting stars and splashing through puddles. Steering is the tilt of the
  line between the wrists, so any plate (or an imaginary wheel) works. Leaving the road just
  slows down. No camera feed is shown; only the hands need to be in view.
- **Fox Trail** — a side-scrolling walk with an original fox hero. March in place to walk
  (knees taking turns), jump to jump. No enemies or pits: crates block the way until you jump
  over or onto them, fruit to collect, and a party at home at the end of each level.

Every game starts with a short **setup**: a big mirrored view with what the camera sees, one
spoken instruction and a checklist (hands, feet, wheel held flat…). It says "Ready!" once
everything is ✅ for a second, or starts anyway after 10 seconds; Return skips it.

Fox Trail's first level begins with practice ("March to walk!", then "Now jump!"). In the
jumping games, three "almost jumps" in a row make jumping easier ("Little jumps work too!").

If a player gets so close that their feet leave the frame, the game pauses with a
"take a big step back" warning. Turn it off with **Warn when too close** in the menu.

If nobody can be seen for a moment, or the camera stops sending frames, the game pauses on
"👀 Looking for you…" and picks up again with "There you are!" once the player is back. Stale
camera frames are never used as input: movement stops the moment the picture goes stale.

## Game packs

Games can also come as **`.jigglegame` files**: a manifest plus JavaScript, run in a sandbox
on top of the platform's tracking, setup and effects. Double-click one (or **➕ Import game…**)
to add it; right-click an imported game to export or remove it. The sample **Star Catch** 🌟
installs on first launch. Write your own with [docs/GAME_PACKS.md](docs/GAME_PACKS.md).

## Run it

Requires macOS 14+, Xcode, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
xcodegen generate
open JiggleJam.xcodeproj   # then ⌘R
```

## Tests

[![CI](https://github.com/datar-gaurav/jigglejam/actions/workflows/ci.yml/badge.svg)](https://github.com/datar-gaurav/jigglejam/actions/workflows/ci.yml)

```sh
xcodebuild -project JiggleJam.xcodeproj -scheme JiggleJam test
```

`Tests/MotionDetectorTests.swift` replays synthetic players through the real jump and walk
detectors: jumps, squats, marching, single-knee lifts, tracking gaps and player swaps.

## Playing on the TV

1. **Camera:** pick it in the menu. An iPhone appears automatically as a Continuity Camera
   (same Apple ID, Wi‑Fi + Bluetooth on). Mount it in landscape below/above the TV.
2. **TV:** Control Center → Screen Mirroring → your Apple TV / AirPlay TV.
3. Click **Full Screen**, press **1**–**5** (or click a game) to start, **Esc** to go back to the menu.
4. Stand 2–3 m back so the camera sees the whole body (the menu tells you when it does).

## Display delay test

Menu → **📏 Display delay test** is a *display-to-camera loopback*. Point the camera at the TV and
the screen flashes. Each flash is timed until the camera sees it: drawing, display, capture and
pose tracking. Save a result labelled "HDMI", switch to AirPlay, and save another to compare.

It leaves out gesture recognition, steering smoothing and the game's next frame, so the delay a
player feels is somewhat longer. To measure that, film a hand movement and the TV's response in
one slow-motion clip, then count the frames between them.

## How it works

The code is split into the **platform** and the **games**:

| Folder | Role |
| --- | --- |
| `Sources/Platform/` | Camera, pose tracking (`PoseTypes`, `CameraManager`), motion detectors, `GameScene` base (pausing, speech, effects), setup screen, game library and menu |
| `Sources/Platform/Packs/` | Game packs: format and import/export (`GamePack`), JavaScript sandbox (`ScriptHost`), and the scene that runs packs (`ScriptedGameScene`) |
| `Sources/Games/` | Built-in Swift games, registered in `BuiltInGames.swift` |
| `Packs/` | Sample game packs shipped with the app |
| `Tests/` | Pose replay tests for the detectors; pack format and script host tests |

Built-in games subclass `GameScene` and implement `tick(dt:pose:)`; see `BubbleScene.swift` for
the simplest example. Pack games use the JavaScript API instead.

## Privacy

Everything runs on the Mac. Camera frames are analysed in memory by Apple's Vision framework
and are never recorded, saved or sent anywhere. Game packs only see the tracking results
(joint positions), never camera images.

## Contributing

Ideas, new games and fixes are welcome — open an issue or a pull request. New games can be
built-in Swift games or game packs; a pack is the easiest way to share one.

## License

[MIT](LICENSE)
