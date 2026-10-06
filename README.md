# RAFFLE

An incremental pinball prototype for Roblox. Roll balls gacha style, and a hopper feeds them onto a real physics pinball table where bumper hits pay out Tickets for upgrades. It's a private prototype I built to try out ideas, so it isn't published.

## What's in it

- Ball rolls with rarities and mutations, 24 ball variants in all
- A physics pinball table with flippers, bumpers and scoring slots, capped at 10 balls at once
- Upgrades, rebirths, achievements and a collection screen
- Auto roll, and a feeder that takes turns between players on the same table

## How it's built

- About 17,400 lines of Luau in client, server and shared modules, synced into Roblox Studio with Rojo.
- Owned balls are stored as one count per variant, not one object per ball, so a million identical balls is a single number in the save.
- An event bus connects game events without the services knowing about each other.
- The UI uses Vide, a reactive UI library (MIT licensed, included in `src/shared/Vide`), and adapts to phone screens.
- Player data is saved through a profile service.

## Running it

Install Rojo, run `rojo serve`, and connect the Rojo plugin in Roblox Studio. The pinball table itself is built in the place file, which isn't in this repo.

Built solo by Sean Aminov, with AI coding assistants helping along the way.
