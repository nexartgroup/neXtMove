# neXtMove

Rotation helper for **WoW Forever** (interface 16001). It shows the best and the second-best next move at a fixed spot on screen, each with the move that follows best after it.

Works for all nine classes, at every level, and adapts to what the character has actually learned.

## What it shows

- **Move 1** (large icon): the best choice right now.
- **Move 2** (second icon): the second-best choice, as an alternative.
- **Small icons below:** what follows best after each of the two moves.
- **Key label:** the key the spell has on your action bars.
- **Red icon on the left:** an alert to interrupt, defend or heal.

Border colors mark what a move is for: healing (green), mana (blue), crafting (yellow), buffs (white). All four colors can be changed in the settings.

## Features

- Reads talents, gear, learned spells and items, and orders the rotation by calculated damage.
- Adapts to the fight: one or several enemies, elite or boss, range, and the makeup of your group.
- Two utility keys with modifier layers (plain, Shift, Alt, Ctrl) for interrupt, stun, healing, escape, trinkets and more.
- Out of combat, the icons of move 1 and 2 can be clicked, which is handy for buffing, summoning pets and conjuring.
- Suggests elixirs, buff food, scrolls and weapon stones when their buff is missing, and eating or drinking when health or mana are low.
- Pre-combat check, cooldown row, action bar glow for move 1, optional alert sounds.
- Animations, which can be switched off.
- Works alongside EllesmereUI.

## Installation

1. Download this repository.
2. Put the folder into `World of Warcraft/_forever_/Interface/AddOns/` and make sure it is named `neXtMove`.
3. Restart the game and enable neXtMove in the addon list.

## Usage

Open the settings with `/nxm`, or through the game menu under Options > AddOns > neXtMove. Settings apply to all characters.

| Command | What it does |
|---|---|
| `/nxm` | Open the settings |
| `/nxm help` | List all commands |
| `/nxm unlock` / `/nxm lock` | Move the display, then fix it in place |
| `/nxm bind 1 KEY` / `/nxm bind 2 KEY` | Set the two utility keys |
| `/nxm keys` | Show what the utility keys are assigned to |
| `/nxm bars` | Put spells without a key onto free action bar slots |
| `/nxm info [spell link]` | Show what the addon knows about a spell |
| `/nxm status` | Print detected talents, spells and items |

## Limits

- The WoW Forever client hides health and mana from addons. Low health and low mana are therefore estimates.
- In combat, the icons cannot be clicked. The game does not allow addons to change what a button does during combat, so use the keys there.
- Healers get suggestions for damage, buffs, dispels and mana, not for whom to heal.

## Credits

The class priorities are derived from the strategies of [mod-playerbots](https://github.com/mod-playerbots/mod-playerbots) and adapted to WoW Forever.

Author: nexartgroup
