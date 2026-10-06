--!strict
-- THE ONE authoritative rarity calculation. The server rolls against these functions and
-- the client displays numbers produced by these same functions, so a displayed odd can
-- never drift from the odd actually used.
--
-- MODEL: normalised best-of-Luck.
--
-- Each named ball i has an exact base probability p_i = 1 / BaseOneIn_i. Order the catalog
-- from common to rare and let
--
--     T_i = p_i + p_(i+1) + ... + p_n        -- "this ball or anything rarer"
--     E_i(L) = 1 - (1 - T_i)^L               -- chance of reaching that tail in L tries
--     q_i(L) = E_i(L) - E_(i+1)(L)           -- exact chance of landing on ball i
--     q_n(L) = E_n(L)                        -- rarest ball has no rarer neighbour
--     Basic  = 1 - E_1(L)                    -- the remainder, never a fake denominator
--
-- At L = 1 this collapses to q_i = p_i exactly, so the printed "1 IN X" is literally true
-- at base Luck. For integer L it is identical to taking the rarest of L independent base
-- rolls; fractional Luck interpolates the same curve smoothly.
--
-- Two properties this guarantees, both asserted in the verification suite:
--   * the q_i always sum to exactly 1 -- nothing is normalised after the fact, which would
--     falsify the base odds
--   * E_i is monotonically non-decreasing in L for every i, so "this rarity or better"
--     can never get worse when you buy Luck
--
-- An individual q_i MAY fall as Luck rises: a Luck-30 player lands on Ruby less often
-- because rarer balls have started to displace it. That is correct, not a bug.

local LuckMath = {}

-- expm1 / log1p, because the rarest tails are ~1e-6 and the naive
-- 1 - (1 - T)^L cancels catastrophically at that scale.
local function log1p(x: number): number
	if math.abs(x) < 1e-5 then
		return x - x * x / 2 + x * x * x / 3
	end
	return math.log(1 + x)
end

local function expm1(x: number): number
	if math.abs(x) < 1e-5 then
		return x + x * x / 2 + x * x * x / 6
	end
	return math.exp(x) - 1
end

-- Chance of landing on this tail (this ball or rarer) at the given Luck.
-- E(L) = 1 - (1 - tail)^L, evaluated so tiny tails keep their precision.
function LuckMath.tailChance(tail: number, luck: number): number
	if tail <= 0 then
		return 0
	end
	if tail >= 1 then
		return 1
	end
	local l = math.max(1, luck)
	return -expm1(l * log1p(-tail))
end

-- Cumulative tails for a catalog ordered COMMON -> RARE.
-- Returns tails[i] = p_i + ... + p_n, computed from the rare end so the smallest
-- probabilities are added first and are not lost under the largest.
function LuckMath.tails(entries: { { oneIn: number } }): { number }
	local tails = table.create(#entries)
	local running = 0
	for i = #entries, 1, -1 do
		running += 1 / entries[i].oneIn
		tails[i] = running
	end
	return tails
end

-- Exact per-ball chances at a given Luck, plus the Basic remainder.
-- Returns (chances, basicChance) where chances[i] corresponds to entries[i].
function LuckMath.chances(entries: { { oneIn: number } }, luck: number): ({ number }, number)
	local tails = LuckMath.tails(entries)
	local n = #entries
	local chances = table.create(n)
	local nextE = 0
	for i = n, 1, -1 do
		local e = LuckMath.tailChance(tails[i], luck)
		chances[i] = e - nextE
		nextE = e
	end
	return chances, 1 - nextE
end

-- Chance of "this ball or anything rarer" at a given Luck. This is the number that must
-- never decrease when Luck rises, and the one worth showing a player who is deciding
-- whether to buy Luck.
function LuckMath.chanceOfThisOrBetter(entries: { { oneIn: number } }, index: number, luck: number): number
	local tails = LuckMath.tails(entries)
	return LuckMath.tailChance(tails[index], luck)
end

-- Selects an index from a uniform sample in [0, 1). Returns nil for the Basic fallback.
--
-- Walks from the RAREST end down: the first tail the sample falls inside wins. That makes
-- P(ball i) exactly E_i - E_(i+1) without building a cumulative table, and gives Basic the
-- true remainder rather than a rounded slice.
function LuckMath.selectIndex(entries: { { oneIn: number } }, luck: number, sample: number): number?
	local tails = LuckMath.tails(entries)
	for i = #entries, 1, -1 do
		if sample < LuckMath.tailChance(tails[i], luck) then
			return i
		end
	end
	return nil
end

-- Presentation helper: an effective "1 in X" for the current Luck. Always rendered with a
-- "~" by the UI, because it is a rounded live number and not the ball's identity.
function LuckMath.oneInFromChance(chance: number): number?
	if chance <= 0 then
		return nil
	end
	return 1 / chance
end

return LuckMath
