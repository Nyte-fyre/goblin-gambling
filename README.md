# Goblin Gambling Co.

A joke casino for WoW: Forever. Slots and Texas Hold'em, against bots or with friends.

**Goblin Gold only.** The addon never reads or moves your real gold, items or
mail, never sends chat messages, and only touches its own SavedVariables
(`GoblinGamblingDB`).

## Commands

| Command | Does |
|---|---|
| `/gg` (backups: `/ggc`, `/goblin`) | Open or close the casino |
| `/gg sound` | Mute or unmute |
| `/gg speed [slow\|medium\|fast]` | Reel speed: Riding Turtle, Kodo Trot or Rocket Boots |
| `/gg suits` | Show card suits as letters (s h d c) instead of symbols |
| `/gg soundtest` | Play each casino sound once, with its name |
| `/gg minimap` | Show or hide the minimap button |
| `/gg loan` | Visit Grubnik: +1,000 Goblin Gold, owe 1,250 |
| `/gg repay` | Pay Grubnik back as much as you can (asks first) |
| `/gg reset` | Wipe Goblin Gold, debt and stats (asks first) |

## Playing Hold'em with friends

Poker tab, **Play with friends**, then tick **Enable multiplayer for this
session** (it is off every time you log in). One player opens a table for
their group or guild; others see it in the list and join between hands.

- Messages use hidden addon messages (prefix `GGCASINO`) on the party, raid
  or guild channel. Nothing is ever posted in chat.
- The host's client runs the game and any bots. Your hole cards are sent
  only to you, and everyone's cards are revealed only at showdown.
- Everyone buys in and cashes out with their own Goblin Gold.
- Take longer than 45 seconds on your turn and you auto-check or fold; do
  it twice in a row and you are removed with your stack.
- If the host closes the table or disappears mid-hand, everyone gets back
  the stack they had when that hand started.

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
