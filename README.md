# Skill Card List

A World of Warcraft 3.3.5 addon for **Ascension (Wildcard)** that lists every skill card, abilities and talents, and shows what your account owns and what is in your current build. It also shows which talents improve each ability.

## Install

1. Download the latest zip from the **Releases** page (or use Code > Download ZIP).
2. Unzip it so you have a folder named exactly `SkillCardList` containing `SkillCardList.toc`, `SkillCardList.lua` and `SkillCardSeed.lua`.
   (If you used Download ZIP, rename the `SkillCardList-main` folder to `SkillCardList`.)
3. Put the folder in `World of Warcraft/Interface/AddOns/`.
4. Restart the game fully.

## Use

- Type `/cards` or click the book button on the minimap.
- Click **Rescan** the first time (and after you collect new cards).
- Search by name, card ID, item ID or spell ID.
- Filter by owned state, kind (abilities / talents) and normal / golden.
- **Owned** shows account ownership. **In build** shows what the current character has learned.
- Click a card to open a synergy window: talents that improve an ability, abilities a talent improves, and abilities that share modifiers. Hover any entry for its tooltip, click one to follow it.

## Commands

| Command | What it does |
|---|---|
| `/cards` | Open or close the window |
| `/cards <text>` | Open with a search |
| `/cards scan` | Rescan all cards |
| `/cards minimap` | Show or hide the minimap button |
| `/cards synergies` | Print a full synergy report you can copy |
| `/cards build` | Show how many entries are in the current build |
| `/cards index` | Show card counts per list type |
| `/cards why <talent spell> <ability spell>` | Explain why a pair is or is not linked |

## Notes on synergies

Some tooltips only show "This uses X modifiers" while Shift is held. A built-in table (`SkillCardSeed.lua`) already covers these, so no Shift is needed. If Ascension adds new abilities of this kind, hold Shift during a Rescan, or hover them with Shift held, and the addon saves what it reads.

## Companion addon

**Card Export** exports your card list to text and imports it on another account.
