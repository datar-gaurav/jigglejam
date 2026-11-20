// Star Catch — a sample Jiggle Jam game pack.
// Catch falling stars with your hands; jump to make a star shower.
// See docs/GAME_PACKS.md for the full API.

let stars = [];
let caught = 0;
let scoreLabel;
let nextStar = 0;

function onStart() {
  scoreLabel = game.text("🌟 0", { x: game.width / 2, y: game.height * 0.88, size: game.height * 0.08 });
  game.say("Star Catch! Catch the falling stars with your hands. Jump for a star shower!");
}

function dropStar() {
  const size = game.height * game.random(0.07, 0.1);
  stars.push({
    sprite: game.emoji(game.pick(["⭐️", "🌟", "✨"]), {
      x: game.random(game.width * 0.1, game.width * 0.9),
      y: game.height + size,
      size: size,
    }),
    speed: game.height * game.random(0.12, 0.2), // slow: 5–8 seconds to fall
    spin: game.random(-90, 90),
  });
}

function onTick(dt, input) {
  // New stars only while someone is playing.
  nextStar -= dt;
  if (input.players > 0 && nextStar <= 0) {
    dropStar();
    nextStar = game.random(0.8, 1.4);
  }
  if (input.jumped) {
    for (let i = 0; i < 6; i++) dropStar();
    game.say("Star shower!");
  }

  for (const star of stars) {
    star.sprite.y -= star.speed * dt;
    star.sprite.rotation += star.spin * dt;
  }

  stars = stars.filter((star) => {
    const reach = game.height * 0.04;
    if (input.hands.some((hand) => star.sprite.touches(hand, reach))) {
      star.sprite.burst();
      star.sprite.remove();
      caught += 1;
      scoreLabel.text = "🌟 " + caught;
      scoreLabel.pulse();
      game.sound("Pop");
      if (caught % 10 === 0) {
        game.say("Wow! " + caught + " stars!");
        game.confetti();
      }
      return false;
    }
    if (star.sprite.y < -star.sprite.size) {
      star.sprite.remove();
      return false;
    }
    return true;
  });
}
