# Goblin Gambling Co.

A joke casino for WoW: Forever. Slots now, Texas Hold'em vs. bots later.

**Goblin Gold only.** The addon never reads or moves your real gold, items or
mail, never sends chat messages, and only touches its own SavedVariables
(`GoblinGamblingDB`).

## Commands

| Command | Does |
|---|---|
| `/gg` (backups: `/ggc`, `/goblin`) | Open or close the casino |
| `/gg sound` | Mute or unmute |
| `/gg speed [slow\|medium\|fast]` | Reel speed: Riding Turtle, Kodo Trot or Rocket Boots |
| `/gg soundtest` | Play each casino sound once, with its name |
| `/gg minimap` | Show or hide the minimap button |
| `/gg loan` | Visit Grubnik: +1,000 Goblin Gold, owe 1,250 |
| `/gg repay` | Pay Grubnik back as much as you can (asks first) |
| `/gg reset` | Wipe Goblin Gold, debt and stats (asks first) |

## Tests

Game logic is plain Lua 5.1 and runs outside the client. From this folder:

```
lua tests/test_slots.lua
```

or, with no Lua installed (uses Python's `lupa`):

```
python tests/run.py
```

`test_ui_smoke.lua` runs the whole addon against a fake WoW API
(`tests/wowmock.lua`) to catch Lua errors before they reach the game.
