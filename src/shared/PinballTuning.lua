--!strict
-- Every magnitude for the automatic pinball prototype, in one table.
--
-- "Busier" must come from MORE BALLS and MORE TARGETS, never from unbounded velocity.
-- Every speed, force and rate below is a hard ceiling, so a future upgrade tunes a value
-- inside these bounds rather than removing the bound.

local PinballTuning = {}

-- ---------------------------------------------------------------- ball supply

PinballTuning.STARTING_BALL_SUPPLY = 500

-- Hard ceiling on balls in play. The feed stops at this cap and resumes on drain.
PinballTuning.MAX_ACTIVE_BALLS = 10

-- ---------------------------------------------------------------- dropper feed

-- The carriage sweeps a full left-right-left cycle in this many seconds.
PinballTuning.DROPPER_PERIOD = 7.0

-- SMOOTH REVERSAL. The sweep used to be a pure triangle wave, so carriage velocity was a
-- SQUARE wave: at each turnaround it flipped sign instantaneously, and two releases a frame
-- apart at the same place inherited opposite lateral motion. That discontinuity is what made
-- releases near the travel edges read as awkward.
--
-- The profile is now trapezoidal with cosine-blended ends: constant speed across the middle,
-- easing smoothly to exactly zero at each turnaround. It is C1 continuous, has a closed-form
-- derivative, and TableSpec.dropperSweep returns position and velocity FROM THE SAME CURVE,
-- so the two can never disagree.
--
-- EASE is the fraction of each half-sweep spent easing (a quarter at each end). Because the
-- velocity shape integrates to (1 - EASE), peak speed is 4*TRAVEL / (PERIOD * (1 - EASE)):
-- 1/0.75 = 1.333x the old constant speed, in exchange for zero speed at the ends.
PinballTuning.DROPPER_EASE = 0.25

-- How often a ball is released from the carriage at FEED SPEED rank 0. The Feed Speed
-- upgrade owns this number from rank 1 onward; these two bound it.
PinballTuning.DROP_INTERVAL = 1.2
PinballTuning.DROP_INTERVAL_MIN = 0.55

-- Fraction of the carriage's own sweep velocity a released ball inherits, and the small
-- downward kick that goes with it. MEASURED, not guessed: with almost no inheritance the
-- carriage slid ~0.8 studs out from under the ball during its fall to the plate, which is
-- what read as the ball squirting backwards out of the hopper. Matching the carriage
-- outright instead threw the ball at a wall. The pair below leaves the mouth cleanly and
-- still enters the field with modest lateral energy.
PinballTuning.DROP_INHERIT = 0.55
PinballTuning.DROP_DOWN_SPEED = 18

-- Clearance skin around the released sphere. The whole ball plus this margin must be clear
-- of every collider before it is created; if it is not, the release DEFERS and the immutable
-- record stays exactly where it is. Nothing is ever rerolled or discarded to make room.
PinballTuning.RELEASE_SKIN = 0.12
PinballTuning.RELEASE_DEFER_MAX = 0.60

-- ---------------------------------------------------------------- ball physics

-- World gravity, applied by Bootstrap. Above Roblox's 196.2 on purpose: the playfield is
-- tilted 7 degrees, so what actually rolls a ball down the table is g * sin(7) -- 23.9
-- studs/s^2 at the default, which read as sluggish. At 320 it is 39.0, and the drop out of
-- the carriage arrives at ~61 studs/s instead of ~48.
PinballTuning.GRAVITY = 320

-- Lowered from 170: at that ceiling a bumper chain read as balls rocketing rather than
-- bouncing. Pace now comes from gravity down the slope, not from top speed.
PinballTuning.BALL_MAX_SPEED = 115
PinballTuning.BALL_LIFETIME = 45
PinballTuning.BALL_OUT_OF_BOUNDS_Y = -25

-- Angular clamp: a hard bumper hit can otherwise leave a ball visibly spinning forever.
PinballTuning.BALL_MAX_SPIN = 32

-- Coarse server loops. NOT per-ball connections: one loop services every ball.
PinballTuning.SERVICE_HZ = 60

-- Stuck recovery: a ball that has barely moved gets a small impulse DOWN-SLOPE, i.e. the
-- direction gravity already wants. Not a teleport and not steering toward any outcome.
PinballTuning.STUCK_SECONDS = 2.5
PinballTuning.STUCK_DISTANCE = 0.6
PinballTuning.STUCK_NUDGE = 14

-- ---------------------------------------------------------------- flippers

-- Servo angles are RELATIVE to the built home pose: the hub attachment carries the home
-- yaw, so servo 0 IS the resting bat. The per-side sign is applied in FlipperService so
-- both bats sweep inward.
PinballTuning.FLIPPER_REST_ANGLE = 0
PinballTuning.FLIPPER_FLIP_ANGLE = 46
PinballTuning.FLIPPER_SERVO_SPEED = 10
PinballTuning.FLIPPER_SERVO_TORQUE = 1200000

-- How long the bat stays up before dropping back.
PinballTuning.FLIPPER_HOLD = 0.35

-- INTERVAL-DRIVEN flapping. The flippers do not detect anything; they flap on this timer.
-- A later upgrade lowers FLIPPER_INTERVAL, which is the whole progression hook.
PinballTuning.FLIPPER_INTERVAL = 1.3
PinballTuning.FLIPPER_INTERVAL_JITTER = 0.35
PinballTuning.FLIPPER_TICK_HZ = 30

-- ---------------------------------------------------------------- scoring

PinballTuning.DEFAULT_HIT_COOLDOWN = 0.35

-- Kicks, applied server-side and clamped. Gated by the same per-ball/per-target cooldown
-- as the award, so a resting ball is neither scored nor repeatedly kicked.
-- Softened from 135/160. The old values fired hard enough that a ball crossing the bumper
-- field picked up speed on every contact instead of trading it.
PinballTuning.BUMPER_KICK = 92
PinballTuning.BUMPER_KICK_MAX = 112
PinballTuning.SLING_KICK = 96
PinballTuning.SLING_KICK_MAX = 120

-- Vertical share of a pop kick. Kicks were flattened completely into the playfield plane
-- because a lucky ricochet used to clear the 8-stud walls; the one-way plate now roofs the
-- whole field, so vertical energy is contained and a hard hit throws the ball up into the
-- glass instead.
--
-- Expressed as the HEIGHT a full-power pop should throw the ball, not as a raw velocity:
-- the speed is derived from the live gravity, so changing GRAVITY cannot silently change
-- how high balls pop.
--
-- Reaching the underside of the glass needs 3.80 studs of rise from the rolling plane. At
-- 4.6 nearly every solid hit slammed the plate and balls read as rocketing upward, so this
-- is now set just UNDER that: a normal pop stays in the field, and only a hit at full
-- reference speed grazes the glass.
PinballTuning.BUMPER_LIFT_HEIGHT = 3.4
-- Incoming speed at which a pop delivers its full lift. Below it the lift tapers, so a slow
-- dribble stays flat on the surface.
PinballTuning.BUMPER_LIFT_REF = 95
PinballTuning.BUMPER_LIFT_MIN = 0.25

-- Ceiling on score events broadcast per second, so a multiball pile-up cannot flood the
-- client with effects.
PinballTuning.MAX_SCORE_EVENTS_PER_SEC = 30

-- ---------------------------------------------------------------- first-ball saver

-- A solid gate across the centre drain for a short window after the first release. The
-- ball physically bounces off it; nothing is repositioned.
PinballTuning.SAVER_SECONDS = 9
PinballTuning.SAVER_ELASTICITY = 0.72

-- ---------------------------------------------------------------- presentation

PinballTuning.HIT_FLASH_TIME = 0.22
PinballTuning.HIT_FLASH_BRIGHTNESS = 4
PinballTuning.POPUP_RISE = 4.0
PinballTuning.POPUP_TIME = 0.7
PinballTuning.POPUP_POOL_SIZE = 14
PinballTuning.MAX_CONCURRENT_EFFECTS = 14

-- ---------------------------------------------------------------- lighting

-- These constants existed but nothing ever applied them, so the scene ran on the place's
-- default daylight. With a bright sun and 0.27 ambient, the dark ground still washed out to
-- flat grey behind the machine. Bootstrap now applies them: a dim room, so the cabinet's
-- own neon and lamps carry the image instead of sunlight flattening everything.
PinballTuning.LIGHTING_BRIGHTNESS = 1.7
PinballTuning.LIGHTING_EXPOSURE = -0.05
PinballTuning.LIGHTING_AMBIENT = Color3.fromRGB(26, 28, 44)
PinballTuning.LIGHTING_OUTDOOR_AMBIENT = Color3.fromRGB(30, 33, 52)
PinballTuning.LIGHTING_ENV_DIFFUSE = 0.35
PinballTuning.LIGHTING_ENV_SPECULAR = 0.35
PinballTuning.BLOOM_INTENSITY = 0.35
PinballTuning.BLOOM_THRESHOLD = 2.4
PinballTuning.BLOOM_SIZE = 16

PinballTuning.TARGET_LIGHT_BRIGHTNESS = 0.5
PinballTuning.TARGET_LIGHT_RANGE = 9

return PinballTuning
