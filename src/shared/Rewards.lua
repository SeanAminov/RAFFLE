--!strict
-- EVERY ADJUSTABLE PAYOUT NUMBER IN THE GAME, IN ONE FILE.
--
-- This module is the single place to change what things are worth. Nothing here is baked
-- into the Studio geometry: the server RE-STAMPS every bumper's score and every slot's
-- multiplier, colour and label from this file on startup, so editing a number below and
-- pressing Play is enough. There is no rebuild step and no Studio edit.
--
-- The one thing that is NOT hot-adjustable is the NUMBER of slots, because the pads are
-- Studio-authored geometry. Change SLOTS's length and the server will say so in the output
-- rather than silently paying out against pads that are not there.
--
-- This module deliberately has NO requires, so anything may depend on it.

local Rewards = {}

-- ---------------------------------------------------------------- drain multipliers

-- The bottom band, left to right in PLAYFIELD-LOCAL +X order. Each ball banks the points
-- it earns from bumpers, and the slot it drains through multiplies that bank.
--
-- `mult`  - what the bank is multiplied by.
-- `fill`  - pad colour.
-- `text`  - label colour.
-- `label` - what is printed on the pad. nil means "<mult>x", which is what you want.
Rewards.SLOTS = {
	{ mult = 2, fill = Color3.fromRGB(24, 168, 164), text = Color3.fromRGB(255, 255, 255) },
	{ mult = 1, fill = Color3.fromRGB(44, 60, 104), text = Color3.fromRGB(196, 214, 248) },
	{ mult = 3, fill = Color3.fromRGB(240, 176, 40), text = Color3.fromRGB(48, 30, 0) },
	{ mult = 1, fill = Color3.fromRGB(44, 60, 104), text = Color3.fromRGB(196, 214, 248) },
	{ mult = 5, fill = Color3.fromRGB(232, 70, 152), text = Color3.fromRGB(255, 255, 255) },
	{ mult = 1, fill = Color3.fromRGB(44, 60, 104), text = Color3.fromRGB(196, 214, 248) },
	{ mult = 2, fill = Color3.fromRGB(24, 168, 164), text = Color3.fromRGB(255, 255, 255) },
}

-- Face used for the multiplier numbers. FredokaOne is a rounded display face that sits
-- with the bumper art far better than Gotham's flat geometric caps.
Rewards.SLOT_FONT = Enum.Font.FredokaOne

function Rewards.slotCount(): number
	return #Rewards.SLOTS
end

function Rewards.slot(index: number)
	return Rewards.SLOTS[math.clamp(index, 1, #Rewards.SLOTS)]
end

function Rewards.slotLabel(index: number): string
	local slot = Rewards.slot(index)
	return slot.label or (tostring(slot.mult) .. "x")
end

-- ---------------------------------------------------------------- ticket payouts

-- SETTLEMENT, applied exactly once per ball when it drains:
--
--   payout = floor(bank * drainPadMultiplier * ballRarityValue * ballValueUpgrade * DRAIN_SCALE)
--
-- Each factor appears exactly once. Rarity VALUE is deliberately tiny next to rarity ODDS
-- -- a 1-in-1,000,000 ball pays 75x, not 1,000,000x -- so a lucky roll feels extraordinary
-- without ending the economy.

-- Immediate trickle on every scoring contact, so the machine always feels like it is
-- paying even mid-ball.
Rewards.TICKETS_PER_HIT = 1

-- Converts raw bank points into Tickets. Tuned against measured play, not guessed: at the
-- measured ~11 bumper contacts/second and ~0.7 drains/second this puts income at roughly
-- 29 Tickets/second at the table's steady state.
Rewards.DRAIN_SCALE = 0.010

-- A drain that never touched a bumper still returns the ball; it simply pays nothing.
Rewards.MIN_DRAIN_PAYOUT = 0

-- A ball removed by out-of-bounds cleanup or a disconnect never reaches a drain pad. It
-- still settles, through the WORST pad, so a payout is never silently lost and never
-- silently duplicated. Counted separately in stats so the rate stays visible.
Rewards.FALLBACK_PAD_MULTIPLIER = 1

-- ---------------------------------------------------------------- bumper payouts

-- What one bumper hit is worth before the drain multiplier is applied.
Rewards.BUMPER_SCORE = 50

-- The middle column reads as the "deep" target, so it pays more.
Rewards.BUMPER_CENTRE_SCORE = 75

-- Per-bumper overrides by id, e.g. ["POP_07"] = 250. Anything not listed uses the values
-- above. Ids are POP_01 .. POP_14, numbered row by row from the back of the table.
Rewards.BUMPER_OVERRIDES = {} :: { [string]: number }

-- How long one ball must wait before the SAME bumper can score it again. Also gates the
-- kick, so a ball resting against a bumper is neither farmed nor machine-gunned.
Rewards.BUMPER_HIT_COOLDOWN = 0.22

function Rewards.bumperScore(id: string, isCentre: boolean): number
	local override = Rewards.BUMPER_OVERRIDES[id]
	if type(override) == "number" then
		return override
	end
	return isCentre and Rewards.BUMPER_CENTRE_SCORE or Rewards.BUMPER_SCORE
end

return Rewards
