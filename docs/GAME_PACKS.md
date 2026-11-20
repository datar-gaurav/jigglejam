# Writing Jiggle Jam game packs

A **game pack** is a Jiggle Jam game you can share as a single `.jigglegame` file. The app
(the *platform*) does the hard parts — camera, body and hand tracking, jump and walk
detection, the setup screen, "too close" and "looking for you" pauses, speech and effects —
and the pack's JavaScript only has to be the game.

- **Import:** double-click a `.jigglegame` file, or use **➕ Import game…** in the menu.
- **Export / remove:** right-click an imported game's card in the menu.
- **Make a file from a folder:** `scripts/make-pack.sh MyGame` → `MyGame.jigglegame`.

A complete example is [`Packs/StarCatch`](../Packs/StarCatch): catch falling stars with your
hands, jump for a star shower.

## Pack layout

```
MyGame/
  manifest.json   ← required
  game.js         ← your code (name set by "main")
  art/…, sounds/… ← optional images (png, jpg) and sounds (wav, aiff, mp3, m4a)
```

A `.jigglegame` file is a zip of the folder's contents (or of the folder itself). Packs are
limited to 50 MB and 2,000 files, and files are only ever read from inside the pack.

## manifest.json

```json
{
  "format": 1,
  "id": "com.yourname.balloon-catch",
  "title": "Balloon Catch",
  "emoji": "🎈",
  "main": "game.js",
  "color": "#FF9500",
  "author": "Your name",
  "version": "1",
  "description": "Shown when hovering over the game in the menu.",
  "showsCamera": true,
  "background": "#1A1F4D",
  "needsFullBody": false,
  "handTracking": false,
  "setup": {
    "instruction": "Hands up, ready to catch!",
    "checks": ["seen", "hands"]
  }
}
```

| Field | Required | Meaning |
|---|---|---|
| `format` | ✓ | Always `1` for now. |
| `id` | ✓ | Unique id (letters, numbers, `.` and `-`). Importing a pack with the same id replaces it. |
| `title`, `emoji` | ✓ | Shown on the menu card. |
| `main` | ✓ | The script file to run. |
| `color` | | Card color, `#RRGGBB`. |
| `showsCamera` | | `true` (default): the live mirrored camera is the background. `false`: your game draws its own world on `background`, with a small camera window in the corner. |
| `needsFullBody` | | `true` if feet must be in view: turns on the "too close" warning. Default `false`. |
| `handTracking` | | `true` turns on the dedicated hand tracker (better for steering, up close). Fills `input.wheel`. |
| `setup.instruction` | | Spoken and shown on the setup screen. |
| `setup.checks` | | What setup waits for: `seen`, `hands`, `feet`, `knees`, `wholeBody`, `bothHands`, `wheelLevel`. |

## Your script

Define any of these functions; the platform calls them:

```js
function onStart() { }            // once, when the game begins (after setup says "Ready!")
function onTick(dt, input) { }    // every frame (~60×/s); dt = seconds since last frame
function onPause() { }            // the platform paused (player too close or out of view)
function onResume() { }           // play resumed
```

`onTick` isn't called while paused, so time-based logic pauses with it.

### Coordinates

Points on the screen, origin at the **bottom-left**: `x` from 0 to `game.width`, `y` from 0 to
`game.height`. Sizes are in the same units; using fractions of `game.height` keeps games
looking the same on any screen.

### `input` (every tick)

| Field | Meaning |
|---|---|
| `players` | Number of people seen. |
| `hands` | `[{x, y}]` — every visible hand (from body tracking, nudged from the wrist to the palm). |
| `feet` | `[{x, y}]` — every visible foot. |
| `bodies` | `[{ nose, neck, leftShoulder, rightShoulder, leftElbow, rightElbow, leftWrist, rightWrist, leftHip, rightHip, leftKnee, rightKnee, leftAnkle, rightAnkle, … }]` — each joint `{x, y}`, only the ones currently visible. |
| `jumped` | `true` on the one frame a real jump takes off (feet off the ground; squats don't count). |
| `walking` | `0` standing still … `1` brisk marching in place (knees taking turns). |
| `wheel` | With `handTracking`: `{ angle, left, right }` — `angle` in degrees, positive = turned right. Otherwise `null`. |
| `tooClose` | Someone is so close their whole body doesn't fit. |

When the camera stalls, input goes empty straight away (no stale hands or walking).

### `game`

```js
// Sprites (all return a Sprite)
game.emoji("🎈", { x, y, size })
game.text("Score 0", { x, y, size, color: "#FFFFFF" })
game.circle({ x, y, size, color })
game.rect({ x, y, width, height, radius, color })
game.image("art/balloon.png", { x, y, size })        // or width/height

// Sound and voice
game.say("Great job!")          // spoken aloud, kid-friendly voice
game.sound("Pop")               // a file in your pack ("sounds/boing.wav") or a macOS sound:
                                // Basso Blow Bottle Frog Funk Glass Hero Morse Ping Pop Purr Sosumi Submarine Tink
game.confetti()

// Helpers
game.width, game.height
game.random(min, max)           // number
game.pick(["a", "b"])           // random item
game.distance(a, b)             // between two {x, y}
game.log("debug", value)        // shown in the corner tracking window and the Xcode console
```

### Sprites

Set properties and the screen updates: `x`, `y`, `size`, `rotation` (degrees), `alpha`,
`scale`, `visible`, `text`, `color`, `z` (stacking order).

```js
sprite.moveTo(x, y, seconds)   // smooth, linear move; x, y and touches() follow it as it goes
sprite.pulse()                 // quick grow-and-shrink
sprite.burst()                 // splash of dots (great right before remove())
sprite.touches(point, reach)   // is a hand/foot within the sprite (+ reach)?
sprite.remove()
```

### Example: a balloon you pop with your hands

```js
let balloon;

function onStart() {
  balloon = game.emoji("🎈", { x: game.width / 2, y: 0, size: game.height * 0.15 });
  game.say("Pop the balloon!");
}

function onTick(dt, input) {
  balloon.y += game.height * 0.15 * dt;                 // float up
  if (balloon.y > game.height) balloon.y = 0;
  if (input.hands.some(h => balloon.touches(h, 20))) {
    balloon.burst();
    game.sound("Pop");
    balloon.y = 0;
    balloon.x = game.random(game.width * 0.1, game.width * 0.9);
  }
}
```

## Safety and limits

- **Sandboxed code.** Pack code runs in its own JavaScript sandbox on its own thread. It can't
  read or write files, use the network or run timers; it can only use the `game` API above, and
  it only ever sees tracking results (joint positions), never camera images.
- **Time budget.** `onStart` (with loading) gets 2 seconds and every other callback 0.25 seconds.
  A script that runs longer — say, an endless loop — is stopped, and the game shows "This game
  took too long and was stopped" while the app stays responsive (Esc still works). If a frame's
  callback is merely slow, that frame is skipped and its time carries over to the next one.
- **Errors.** If a script throws, the game shows "This game hit a problem" with the message.
- **Import checks.** Before anything is installed, a pack is unpacked with limits enforced as it
  extracts (50 MB, 2,000 files), its manifest and file paths are validated, and its script is
  syntax-checked without running it. Updating a game (same `id`) only replaces the installed
  copy once the new one passes every check, so a broken update keeps the old version.

## Tips for little players

- No losing: reward everything, keep targets big and slow.
- Talk a lot with `game.say` — four-year-olds can't read the screen.
- Ask setup for exactly what your game uses (`hands`, `feet`…), so "Ready!" means ready.
