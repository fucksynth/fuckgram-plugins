-- Пиксельный котик: живёт в окне клиента. Рисуется на холсте плашки
-- (tg.ui.overlay), которая ездит за ним по окну; кадры собираются из
-- частей ниже. Щелчок — погладить, перетаскивание — понести (клиент
-- двигает плашку сам; где перетаскивания ещё нет, щелчок работает как
-- раньше). Окрас (и свой), размер, видимость, характер и где котик живёт —
-- в настройках; каждая читается на ходу. Что котик говорит и как
-- называются пункты — в locales/*.json (plugin.t).

------------------------------------------------------------------- art

-- A frame is a grid of W x H cells. Poses are put together from the parts
-- below, then finish() outlines the silhouette. The cat faces right and is
-- mirrored to face left. Cell keys:
--   o outline, lines     l closed eyes    f fur       s shade
--   h highlight          t stripes        u tail rings
--   x points (Siamese)   b chest, cheeks  m muzzle    p paws
--   i inner ears, pads   n nose, blush    r tongue    k eyes   w shine
-- ":" in a part clears the cell. Calico patches are a second layer (see
-- PATCHES): "a" orange and "c" black over the fur keys.
local W, H = 32, 24

local PARTS = {
	head = {
		".x.........x.",
		".xi.......ix.",
		".fii.....iif.",
		".fiif...fiif.",
		"ffffhhthhffff",
		"ffffthfhtffff",
		"fffffffffffff",
		"ffffffnffffff",
		"fffbbomobbfff",
		".ffbbmmmbbff.",
		"..fffffffff..",
	},
	-- Standing and walking.
	body = {
		"...hhhhhhhhhh...",
		".hhfftffftffftf.",
		"ffffftffftffftfb",
		"fffftffftffftfbb",
		"sfffffffffffffbb",
		"ssffffffffffffb.",
		".sssssbbbbbbbb..",
	},
	tail_up = {
		"...xx",
		"..xx.",
		".uf..",
		".ff..",
		"ff...",
		"uu...",
		"ff...",
		"ff...",
		".uu..",
		".fff.",
		"..fff",
	},
	tail_back = {
		"xx.......",
		".xuf.....",
		"..ffu....",
		"....fuf..",
		"......fff",
	},
	leg = { "ff", "ff", "ff", "pp" },
	leg5 = { "ff", "ff", "ff", "ff", "pp" },
	leg_fwd = { "ff.", ".ff", ".ff", ".pp" },
	leg_back = { ".ff", "ff.", "ff.", "pp." },
	run_reach = { "ff...", ".ff..", "..ff.", "...pp" },
	run_push = { "...ff", "..ff.", ".ff..", "pp..." },
	run_tuck = { "ff..", "fff.", ".fpp" },
	run_tuck_back = { "..ff", ".fff", "ppf." },
	-- Sitting; the head goes on top at (16, 1).
	sit = {
		"...............hhffffffff.......",
		".............hhfftfffffffb......",
		"...........hhtffftffffbbb.......",
		"..........hffftffftffffbbb......",
		"..........ftfftffffffbbbb.......",
		".........ffftfftffffbbbbb.......",
		".........ffftfffffffsbbbf.......",
		".........ftfftfffffffssfff......",
		".........fftffftffffsssfff......",
		".........fftffftffffossfff......",
		".........ffffffftfffossfff......",
		".........ffffffftfffossfff......",
		".........sffffffffffossfff......",
		"..........sssssppppposspppp.....",
	},
	sit_tail1 = { ".xx......", "xxf......", "uu.......", "ff.......", "ffu......", ".ffufffff" },
	sit_tail2 = { ".........", ".........", "xx.......", "xu.......", "ffu......", ".ffufffff" },
	sit_tail3 = { ".........", "xx.......", "xuf......", ".ff......", "uff......", ".ffufffff" },
	sit_tail_up = { "..xx", ".xx.", ".uf.", "ff..", "uu..", "ff..", "ff..", "uu..", ".ff.", ".fff" },
	sit_tail_up2 = { "xx..", ".xx.", "..fu", "..ff", ".uu.", ".ff.", "ff..", "uu..", ".ff.", ".fff" },
	-- The near front leg lifted for washing; the standing one is cleared.
	leg_gone = { "::::", "::::", "::::", "::::", "::::", "::::", "::::" },
	paw_lick = { ".oooo.", "oppppo", "opiipo", "oppppo", ".offo.", "offo..", "offo..", "ffo..." },
	paw_wipe = {
		".oo..",
		"oiio.",
		"oppfo",
		".offo",
		".offo",
		".offo",
		".offo",
		".offo",
		".offo",
		"offo.",
		"off..",
	},
	-- Lying curled up; the tail wraps around the front.
	sleep = {
		".......hhhhhhhh.......",
		".....htffftffftffhh...",
		"...hfftffftffftffff...",
		"..ffftffftffftffffff..",
		".ffffffffffffffffffff.",
		"fffffffffffffffffffff.",
		"fffffffffffffffffffff.",
		"sffffffffffffffffffff.",
		".ssssssssssssssssss...",
	},
	sleep_tail = { "oooooooooooo....", "ssussuussusxxo..", "sssssssssssssxx." },
	breath = { "hhhhhhhhhh" },
	-- Held by the scruff, seen from the front.
	hang = {
		"..fffffffff..",
		".fffbbbbbfff.",
		".ffbbbbbbbff.",
		".ffbbbbbbbff.",
		".ffbbbbbbbff.",
		".ffbbbbbbbff.",
		".fffbbbbbfff.",
		".sfffbbbfffs.",
		"..sssssssss..",
	},
	hang_leg = { "fs", "fs", "fs", "fs", "fs", "fs", "fs", "pp" },
	hang_leg_r = { "sf", "sf", "sf", "sf", "sf", "sf", "sf", "pp" },
	hang_leg_out = { "fs.", "fs.", "fs.", "fs.", ".fs", ".fs", ".fs", ".pp" },
	hang_leg_out_r = { ".sf", ".sf", ".sf", ".sf", "sf.", "sf.", "sf.", "pp." },
	hang_back = { ".ff", "ff.", "ff.", "pp." },
	hang_back_r = { "ff.", ".ff", ".ff", ".pp" },
	hang_back_out = { "..ff", ".ff.", "ff..", "pp.." },
	hang_back_out_r = { "ff..", ".ff.", "..ff", "..pp" },
	hang_tail = { "fu", "ff", "fu", ".f", ".x" },
	hang_tail2 = { "uf", "ff", "uf", "f.", "x." },
	scruff = { "..f..", ".fff.", "fffff" },
	-- A play bow: the rear up, the chest and the paws down.
	stretch = {
		"..hhhhh..................",
		".hffffffhh...............",
		"fftfffftffhh.............",
		"fffftffffftfhh...........",
		"ffffffftfffffffh.........",
		"sffffffffffffffff........",
		"ssffffffffffffffff.......",
		".sffffffffffffffffbb.....",
		"..sfff.....ssfffbbbb.....",
		"..sff..........bbbbb.....",
		"..sff....................",
		"..sff....................",
		"..sff....................",
		".sspp....................",
	},
	stretch_legs = { "fffffffffpp.", "sssssssssspp" },
	-- Crouching before a pounce.
	crouch = {
		"....hhhhhhhh.....",
		"..hhfffttfffhhh..",
		".fffftffffftffff.",
		"ffffffffffffffffb",
		"sfffffffffffffbbb",
		"ssssssbbbbbbbbbb.",
	},
	crouch_front = { "ffffpp", "sssspp" },
	crouch_back = { "ffff.", "sspp." },
	paw_bat = {
		"..oooo.",
		".oppppo",
		".opiipo",
		".oppppo",
		"..offo.",
		".offo..",
		".offo..",
		"offo...",
		"ffo....",
	},
	land_back = { "ff...", "fff..", ".pp.." },
	land_front = { "..ff.", ".fff.", ".pp.." },
	land_far = { "...ff", "..fff", "..pp." },
}

-- Calico patches: rows as wide as the part's (missing rows have none), or
-- one key for the whole part.
local PATCHES = {
	head = {
		".a.........c.",
		".aa.......cc.",
		".aaa.....ccc.",
		".aaaa...cccc.",
		"aaaaa...cccc.",
		"aaa......ccc.",
		"aa.........c.",
		"a............",
	},
	body = {
		"...cccc.aaaaa...",
		".ccccc..aaaaaa..",
		"cccc...aaaaaa...",
		"ccc.....aaaa....",
		"cc..............",
	},
	sit = {
		"................aaaa............",
		"..............aaaaaaa...........",
		"............aaaaaaa.............",
		"...........aaaaaa...............",
		"...........aaaa.................",
		"................................",
		"..........ccc...................",
		".........ccccc..................",
		".........cccccc.................",
		".........ccccc..................",
		".........cccc...................",
	},
	sleep = {
		"..........aaaaa.......",
		"........aaaaaaaa......",
		"...cc..aaaaaaaaa......",
		"..cccc..aaaaaaa.......",
		".ccccc..........cc....",
		"cccc...........cccc...",
		"ccc.............cc....",
	},
	crouch = {
		"....cccc.aaaa....",
		"..ccccc.aaaaaa...",
		".cccc..aaaaaa....",
		"ccc.....aaa......",
	},
	stretch = {
		"..ccccc..................",
		".cccccc..................",
		"ccccc.....aaaa...........",
		"cccc.....aaaaaa..........",
		"ccc.....aaaaaaa..........",
		"..........aaaa...........",
	},
	hang = {
		"..aaa........",
		".aaaa........",
		".aaa.........",
		".aa..........",
		".............",
		".........cc..",
		"........ccc..",
		".........cc..",
	},
	breath = { ".....aaaaa" },
	tail_up = "a",
	tail_back = "a",
	sit_tail1 = "a",
	sit_tail2 = "a",
	sit_tail3 = "a",
	sit_tail_up = "a",
	sit_tail_up2 = "a",
	sleep_tail = "a",
	hang_tail = "a",
	hang_tail2 = "a",
}

local EYES = {
	open = { "kw", "kk" },
	blink = { "..", "ll" },
	wide = { "ww", "wk" },
	half = { "ll", "kk" },
}
local HAPPY_EYES = { ".ll.", "l..l" }
local MOUTHS = {
	talk = { "oro" },
	yawn = { "ooo", "oro", "oro" },
	lick = { "omor" },
}

local function grid()
	local g = { patch = {} }
	for y = 1, H do
		local row = {}
		for x = 1, W do
			row[x] = "."
		end
		g[y] = row
		g.patch[y] = {}
	end
	return g
end

-- Puts a part (its name or its rows) with the top-left cell at x, y
-- (0-based); "." keeps what is under it, `map` swaps keys.
local function put(g, part, x, y, map)
	local patch
	if type(part) == "string" then
		patch = PATCHES[part]
		part = PARTS[part]
	end
	for r = 1, #part do
		local line = part[r]
		local row, prow = g[y + r], g.patch[y + r]
		if row then
			local pline = type(patch) == "table" and patch[r] or nil
			for col = 1, #line do
				local ch = line:sub(col, col)
				local gx = x + col
				if ch ~= "." and gx >= 1 and gx <= W then
					if ch == ":" then
						row[gx] = "."
						prow[gx] = nil
					else
						row[gx] = map and map[ch] or ch
						local pc = type(patch) == "string" and patch
							or (pline and pline:sub(col, col))
						prow[gx] = (pc and pc ~= "." and pc ~= "") and pc or nil
					end
				end
			end
		end
	end
end

-- Outlines the silhouette and packs the grid into strings.
local function finish(g)
	local marks = {}
	local function solid(y, x)
		local row = g[y]
		local ch = row and row[x]
		return ch ~= nil and ch ~= "." and ch ~= "o"
	end
	for y = 1, H do
		for x = 1, W do
			if g[y][x] == "."
				and (solid(y - 1, x) or solid(y + 1, x) or solid(y, x - 1) or solid(y, x + 1)) then
				marks[#marks + 1] = { y, x }
			end
		end
	end
	for _, m in ipairs(marks) do
		g[m[1]][m[2]] = "o"
	end
	local rows, patch = {}, {}
	local feet_l, feet_r = W, -1
	for y = 1, H do
		rows[y] = table.concat(g[y])
		local p = {}
		for x = 1, W do
			p[x] = g.patch[y][x] or "."
			if y >= H - 1 and g[y][x] ~= "." then
				feet_l = math.min(feet_l, x - 1)
				feet_r = math.max(feet_r, x - 1)
			end
		end
		patch[y] = table.concat(p)
	end
	return {
		rows = rows,
		patch = patch,
		head = g.head or { 16, 2 },
		feet = feet_r >= feet_l and { feet_l, feet_r } or nil,
	}
end

local function head(g, x, y, eyes, mouth, blush)
	put(g, "head", x, y)
	if eyes == "happy" then
		put(g, HAPPY_EYES, x + 1, y + 6)
		put(g, HAPPY_EYES, x + 8, y + 6)
	else
		local e = EYES[eyes] or EYES.open
		put(g, e, x + 2, y + 6)
		put(g, e, x + 9, y + 6)
	end
	if mouth then
		put(g, MOUTHS[mouth], x + 5, y + 8)
	end
	if blush then
		put(g, { "nn" }, x + 1, y + 8)
		put(g, { "nn" }, x + 10, y + 8)
	end
	g.head = { x + 6, y }
end

local FAR = { f = "s", h = "s", p = "s", t = "s" }

-- Recipes: function(eyes, mouth) -> a frame.
local POSES = {}

local function walk_pose(nf, ff, nb, fb, up)
	return function(eyes, mouth)
		local g = grid()
		local u = up and -1 or 0
		local legs = up and 18 or 19
		put(g, "tail_up", 1, 2 + u)
		put(g, fb, 6, legs, FAR)
		put(g, ff, 16, legs, FAR)
		put(g, "body", 5, 12 + u)
		put(g, nb, 8, legs)
		put(g, nf, 18, legs)
		head(g, 17, 2 + u, eyes, mouth)
		return finish(g)
	end
end
POSES.walk1 = walk_pose("leg_fwd", "leg_back", "leg_back", "leg_fwd")
POSES.walk2 = walk_pose("leg5", "leg5", "leg5", "leg5", true)
POSES.walk3 = walk_pose("leg_back", "leg_fwd", "leg_fwd", "leg_back")
POSES.walk4 = POSES.walk2

POSES.run1 = function(eyes, mouth) -- stretched out
	local g = grid()
	put(g, "tail_back", 1, 9)
	put(g, "run_push", 3, 18, FAR)
	put(g, "run_reach", 21, 18, FAR)
	put(g, "body", 6, 12)
	put(g, "run_push", 5, 18)
	put(g, "run_reach", 23, 18)
	head(g, 18, 3, eyes, mouth)
	return finish(g)
end
POSES.run2 = function(eyes, mouth) -- gathered
	local g = grid()
	put(g, "tail_back", 1, 8)
	put(g, "run_tuck", 12, 19, FAR)
	put(g, "run_tuck_back", 15, 19, FAR)
	put(g, "body", 6, 12)
	put(g, "run_tuck", 10, 19)
	put(g, "run_tuck_back", 17, 19)
	head(g, 18, 3, eyes, mouth)
	return finish(g)
end

local function sit_pose(tail)
	return function(eyes, mouth)
		local g = grid()
		put(g, tail, 2, 17)
		put(g, "sit", 0, 9)
		head(g, 16, 1, eyes, mouth)
		return finish(g)
	end
end
POSES.sit1 = sit_pose("sit_tail1")
POSES.sit2 = sit_pose("sit_tail2")
POSES.sit3 = sit_pose("sit_tail3")
POSES.yawn = function()
	return POSES.sit1("blink", "yawn")
end

local function happy_pose(tail)
	return function()
		local g = grid()
		put(g, tail, 6, 8)
		put(g, "sit", 0, 9)
		head(g, 16, 1, "happy", nil, true)
		return finish(g)
	end
end
POSES.happy1 = happy_pose("sit_tail_up")
POSES.happy2 = happy_pose("sit_tail_up2")

local function wash_pose(paw, mouth)
	return function()
		local g = grid()
		put(g, "sit_tail1", 2, 17)
		put(g, "sit", 0, 9)
		put(g, "leg_gone", 23, 16)
		head(g, 16, 1, "blink", mouth)
		if paw == "paw_lick" then
			put(g, paw, 25, 8)
		else
			put(g, paw, 24, 4)
		end
		return finish(g)
	end
end
POSES.lick1 = wash_pose("paw_lick", "lick")
POSES.lick2 = wash_pose("paw_lick")
POSES.wipe = wash_pose("paw_wipe")

local function sleep_pose(breath)
	return function()
		local g = grid()
		put(g, "sleep", 3, 14)
		if breath then
			put(g, "breath", 8, 13)
		end
		put(g, "sleep_tail", 5, 20)
		head(g, 17, 11, "blink")
		return finish(g)
	end
end
POSES.sleep1 = sleep_pose(false)
POSES.sleep2 = sleep_pose(true)

local function hang_pose(out, tail2)
	return function(eyes)
		local g = grid()
		put(g, tail2 and "hang_tail2" or "hang_tail", 15, 18)
		if out then
			put(g, "hang_back_out", 9, 18, FAR)
			put(g, "hang_back_out_r", 19, 18, FAR)
		else
			put(g, "hang_back", 10, 18, FAR)
			put(g, "hang_back_r", 19, 18, FAR)
		end
		put(g, "hang", 9, 10)
		if out then
			put(g, "hang_leg_out", 11, 12)
			put(g, "hang_leg_out_r", 17, 12)
		else
			put(g, "hang_leg", 12, 12)
			put(g, "hang_leg_r", 17, 12)
		end
		put(g, "scruff", 13, 2)
		local calm = (eyes == "half")
		head(g, 9, 1, eyes or "wide", not calm and "talk" or nil)
		return finish(g)
	end
end
POSES.hang1 = hang_pose(false, false)
POSES.hang2 = hang_pose(true, true)

POSES.stretch = function()
	local g = grid()
	put(g, "tail_up", 1, 1)
	put(g, "stretch", 3, 9)
	put(g, "stretch_legs", 19, 21)
	head(g, 17, 9, "blink")
	return finish(g)
end

local function crouch_pose(up, bat)
	return function(eyes)
		local g = grid()
		local u = up and -1 or 0
		put(g, "tail_up", 1, 7 + u)
		put(g, "crouch", 4, 16 + u)
		put(g, "crouch_back", 5, 21)
		put(g, "crouch_front", 18, 21)
		head(g, 17, 9, eyes or (bat and "open" or "wide"))
		if bat then
			put(g, "paw_bat", 24, 12)
		end
		return finish(g)
	end
end
POSES.crouch1 = crouch_pose(false)
POSES.crouch2 = crouch_pose(true)
POSES.bat = crouch_pose(false, true)

POSES.land = function()
	local g = grid()
	put(g, "tail_up", 1, 6)
	put(g, "land_back", 5, 20, FAR)
	put(g, "land_far", 17, 20, FAR)
	put(g, "body", 5, 15)
	put(g, "land_back", 7, 20)
	put(g, "land_front", 18, 20)
	head(g, 17, 6, "blink")
	return finish(g)
end

-- Frames are built on first use. "_b" blinks, "_c" looks calm (half-closed
-- eyes), "_m" opens the mouth: "sit2_b", "walk1_b", "hang1_c", "sit1_m".
local FRAMES = {}
local function frame(name)
	local f = FRAMES[name]
	if f then
		return f
	end
	local base, suffix = name:match("^(.-)_(%a)$")
	base = base or name
	local recipe = POSES[base] or POSES.sit1
	if suffix == "b" then
		f = recipe("blink")
	elseif suffix == "c" then
		f = recipe("half")
	elseif suffix == "m" then
		f = recipe(nil, "talk")
	else
		f = recipe()
	end
	FRAMES[name] = f
	return f
end

--------------------------------------------------------------- settings

-- Every setting is read when it is needed, so a change works at once.
local function setting(key, default)
	return plugin.settings.get(key, default)
end

-- A selector's value: 1..count, or the default.
local function choice(key, default, count)
	local value = math.floor(tonumber(setting(key, default)) or default)
	if value < 1 or value > count then
		return default
	end
	return value
end

-- Switches that are on by default.
local function flag(key)
	return setting(key, true) ~= false
end

local function scale()
	local value = math.floor(tonumber(setting("size", 3)) or 3)
	return math.max(1, math.min(6, value))
end

local function speed()
	return math.max(0.25, (tonumber(setting("speed", 2)) or 2) / 2)
end

local function opacity()
	return math.max(0.4, math.min(1, (tonumber(setting("opacity", 100)) or 100) / 100))
end

-- Lazy .. restless: how long it rests and how often it moves.
local ACTIVITY = {
	{ rest = 1.8, move = 0.45 },
	{ rest = 1.35, move = 0.7 },
	{ rest = 1, move = 1 },
	{ rest = 0.7, move = 1.4 },
	{ rest = 0.45, move = 1.9 },
}
local function activity()
	return ACTIVITY[choice("activity", 3, #ACTIVITY)]
end

-- Silent .. chatty: how likely a phrase is said.
local TALK = { 0, 0.4, 1, 1.8 }
local function talkativeness()
	return TALK[choice("talk", 3, #TALK)]
end

local HOME_ANYWHERE, HOME_FLOOR, HOME_SPOT = 1, 2, 3
local function home()
	return choice("home", HOME_ANYWHERE, 3)
end

------------------------------------------------------------------ coats

-- In the order of the "Coat" selector; "Custom" comes after them.
local COATS = {
	{ -- ginger tabby
		o = "#4a2410", f = "#f0a04b", s = "#d27d2c", h = "#ffc27a", t = "#c86a1e",
		b = "#fff1dc",
	},
	{ -- grey
		o = "#28313b", f = "#9aa6b2", s = "#7a8794", h = "#c3ccd5", t = "#87939f",
		b = "#e9edf1",
	},
	{ -- black
		o = "#07070a", l = "#8c8c9e", f = "#383844", s = "#272731", h = "#5a5a6c",
		b = "#44444f", i = "#d77a92", n = "#d77a92", k = "#ffd43b",
	},
	{ -- white
		o = "#6b6f7a", f = "#f7f7f4", s = "#d9dbe2", h = "#ffffff", b = "#ffffff",
		k = "#3d7be0",
	},
	{ -- Siamese
		o = "#3d2a1f", f = "#f2e4cc", s = "#d8c2a0", h = "#fff7e8", u = "#d8c2a0",
		x = "#5b3a29", b = "#fffaf0", m = "#6b4532", p = "#5b3a29", k = "#3b7fd9",
	},
	{ -- brown tabby
		o = "#2e2117", f = "#a88d6a", s = "#8c7354", h = "#c9ad87", t = "#5a4430",
		x = "#5a4430", b = "#efe3cf",
	},
	{ -- tuxedo
		o = "#07070a", l = "#8c8c9e", f = "#2c2c35", s = "#1f1f27", h = "#4c4c5a",
		b = "#f4f4f1", p = "#f4f4f1", i = "#d77a92", k = "#9bd35a",
	},
	{ -- calico
		o = "#5a4636", f = "#faf6ef", s = "#e3dccf", h = "#ffffff", b = "#ffffff",
		a = "#e8923a", as = "#c9752a", c = "#3b3431", cs = "#2a2421",
	},
}
local CUSTOM = #COATS + 1

-- What a key falls back to when a coat does not set it.
local FALLBACK = { l = "o", t = "f", u = "t", x = "f", m = "b", p = "f" }
local COMMON = { i = "#ff9fb2", n = "#ff7896", r = "#e8506e", k = "#1e1a18", w = "#ffffff" }
local function complete(coat)
	for key, value in pairs(COMMON) do
		if coat[key] == nil then
			coat[key] = value
		end
	end
	return coat
end
for _, coat in ipairs(COATS) do
	complete(coat)
end

-- The custom coat: a fur colour (in the order of the "Fur colour"
-- selector; dark ones get light lines for closed eyes), a pattern and eyes.
local FURS = {
	{ "#2f2f38", dark = true }, -- black
	{ "#5d5f69", dark = true }, -- smoky
	{ "#9aa6b2" }, -- grey
	{ "#8394ad" }, -- blue
	{ "#b9a6b8" }, -- lilac
	{ "#f7f7f4" }, -- white
	{ "#f3dfbf" }, -- cream
	{ "#d6bb94" }, -- fawn
	{ "#e9b85a" }, -- golden
	{ "#ec8f3e" }, -- ginger
	{ "#8b6243", dark = true }, -- brown
	{ "#5a3828", dark = true }, -- chocolate
}
local PATTERN_NONE, PATTERN_STRIPES, PATTERN_PATCHES, PATTERN_TUXEDO, PATTERN_POINTS = 1, 2, 3, 4, 5
local EYE_COLORS = { "#1e1a18", "#5fae3a", "#a88a35", "#e0a526", "#d0702a", "#3b7fd9" }

local BLACK, WHITE = "#000000", "#ffffff"

-- a + (b - a) * t for two "#rrggbb" colours.
local function mix(a, b, t)
	local function part(color, i)
		return tonumber(color:sub(i, i + 1), 16)
	end
	local function blend(i)
		return math.floor(part(a, i) + (part(b, i) - part(a, i)) * t + 0.5)
	end
	return string.format("#%02x%02x%02x", blend(2), blend(4), blend(6))
end

local function custom_coat(fur, pattern, eyes)
	local entry = FURS[fur] or FURS[3]
	local base = entry[1]
	local coat = {
		f = base,
		s = mix(base, BLACK, 0.18),
		h = mix(base, WHITE, 0.28),
		o = mix(base, BLACK, 0.72),
		b = mix(base, WHITE, entry.dark and 0.1 or 0.55),
		k = EYE_COLORS[eyes] or EYE_COLORS[1],
	}
	if entry.dark then
		coat.l, coat.i, coat.n = "#8c8c9e", "#d77a92", "#d77a92"
	end
	if pattern == PATTERN_STRIPES then
		coat.t = mix(base, BLACK, 0.38)
		coat.x = coat.t
		coat.b = mix(base, "#fff6e8", 0.65)
	elseif pattern == PATTERN_PATCHES then -- patches on white
		coat.f, coat.s, coat.h, coat.b = "#faf6ef", "#e3dccf", WHITE, WHITE
		coat.o, coat.l = mix(base, BLACK, 0.6), nil
		coat.i, coat.n = nil, nil
		coat.a, coat.as = base, mix(base, BLACK, 0.18)
		coat.c, coat.cs = mix(base, BLACK, 0.55), mix(base, BLACK, 0.65)
	elseif pattern == PATTERN_TUXEDO then
		coat.b, coat.m, coat.p = "#f4f4f1", "#f4f4f1", "#f4f4f1"
	elseif pattern == PATTERN_POINTS then -- light body, dark face, ears, paws, tail
		local light = mix(base, "#fff8ec", 0.78)
		coat.f, coat.s, coat.h = light, mix(light, BLACK, 0.12), mix(light, WHITE, 0.4)
		coat.u = mix(base, light, 0.25) -- a darker, ringed tail
		coat.x, coat.p, coat.m = base, base, mix(base, light, 0.2)
		coat.b = mix(light, WHITE, 0.5)
		coat.o, coat.l = mix(base, BLACK, 0.55), nil
		coat.i, coat.n = nil, nil
	end
	return complete(coat)
end

-- The chosen coat: an index of COATS, or "c<fur>.<pattern>.<eyes>".
local function coat_key()
	local index = choice("coat", 1, CUSTOM)
	if index == CUSTOM then
		return "c" .. choice("fur", 10, #FURS) .. "." .. choice("pattern", PATTERN_STRIPES, 5)
			.. "." .. choice("eyes", 2, #EYE_COLORS)
	end
	return index
end

local CUSTOM_COATS = {}
local function palette(key)
	if type(key) == "number" then
		return COATS[key] or COATS[1]
	end
	local coat = CUSTOM_COATS[key]
	if not coat then
		local fur, pattern, eyes = key:match("^c(%d+)%.(%d+)%.(%d+)$")
		coat = custom_coat(tonumber(fur), tonumber(pattern), tonumber(eyes))
		CUSTOM_COATS[key] = coat
	end
	return coat
end

local FUR = { f = true, s = true, h = true, t = true, u = true, x = true }

local function cell_color(coat, ch, patch)
	if ch == "." then
		return nil
	end
	if patch ~= "." and coat.a and FUR[ch] then
		return coat[ch == "s" and (patch .. "s") or patch]
	end
	local value = coat[ch]
	while not value do
		ch = FALLBACK[ch]
		if not ch then
			return nil
		end
		value = coat[ch]
	end
	return value
end

-- One rectangle per run of a colour in a row: few calls per paint.
local RUNS = {}
local function runs(key, name)
	local cache = RUNS[key]
	if not cache then
		cache = {}
		RUNS[key] = cache
	end
	local list = cache[name]
	if list then
		return list
	end
	local f = frame(name)
	local coat = palette(key)
	list = {}
	for y = 1, H do
		local line, pline = f.rows[y], f.patch[y]
		local colors = {}
		for x = 1, W do
			colors[x] = cell_color(coat, line:sub(x, x), pline:sub(x, x)) or false
		end
		local x = 1
		while x <= W do
			local color = colors[x]
			local n = 1
			while x + n <= W and colors[x + n] == color do
				n = n + 1
			end
			if color then
				list[#list + 1] = { y - 1, x - 1, n, color }
			end
			x = x + n
		end
	end
	cache[name] = list
	return list
end

-- Draws a frame with its top-left at ox, oy; `shift` moves rows sideways
-- (in cells, for the swing of a carried cat).
local function draw_frame(c, name, key, ox, oy, s, dir, shift)
	local list = runs(key, name)
	for i = 1, #list do
		local run = list[i]
		local row, col, n = run[1], run[2], run[3]
		if dir < 0 then
			col = W - col - n
		end
		if shift then
			col = col + (shift[row] or 0)
		end
		c:rect(ox + col * s, oy + row * s, n * s, s, run[4])
	end
end

-- Small pixel pictures for the effects, outlined like the cat unless plain.
local function glyph(rows, colors, plain)
	local w, h = #rows[1] + 2, #rows + 2
	local cells = {}
	for y = 1, h do
		local line = rows[y - 1]
		local row = {}
		for x = 1, w do
			local ch = line and line:sub(x - 1, x - 1) or ""
			row[x] = (ch ~= "" and ch ~= ".") and ch or false
		end
		cells[y] = row
	end
	local marks = {}
	for y = 1, h do
		for x = 1, w do
			if not cells[y][x] and not plain then
				local up, down = cells[y - 1], cells[y + 1]
				if (up and up[x]) or (down and down[x]) or cells[y][x - 1] or cells[y][x + 1] then
					marks[#marks + 1] = { y, x }
				end
			end
		end
	end
	for _, m in ipairs(marks) do
		cells[m[1]][m[2]] = "o"
	end
	local list = {}
	for y = 1, h do
		local x = 1
		while x <= w do
			local ch = cells[y][x]
			local n = 1
			while x + n <= w and cells[y][x + n] == ch do
				n = n + 1
			end
			if ch then
				list[#list + 1] = { y - 1, x - 1, n, colors[ch] }
			end
			x = x + n
		end
	end
	return { w = w, h = h, runs = list }
end

local GLYPHS = {
	heart = glyph({ "HH.HH", "HWHHH", "HHHHH", ".HHH.", "..H.." },
		{ o = "#8f1d43", H = "#ff5c8a", W = "#ffd1de" }),
	z = glyph({ "ZZZZZ", "...Z.", "..Z..", ".Z...", "ZZZZZ" }, { Z = "#7fa6ef" }, true),
	bang = glyph({ "EE", "EE", "EE", "..", "EE" }, { o = "#5a4300", E = "#ffd43b" }),
	ball1 = glyph({ ".yyy.", "yzzyy", "yyyzz", "zzyyy", ".yyz." },
		{ o = "#5c1a28", y = "#e85d75", z = "#b8364f" }),
	ball2 = glyph({ ".zyy.", "yyzzy", "yyyyz", "yzzyy", ".yyy." },
		{ o = "#5c1a28", y = "#e85d75", z = "#b8364f" }),
}

local function draw_glyph(c, g, x, y, q)
	for i = 1, #g.runs do
		local run = g.runs[i]
		c:rect(x + run[2] * q, y + run[1] * q, run[3] * q, q, run[4])
	end
end

-------------------------------------------------------------- the cat

local function rnd(a, b)
	return a + math.random() * (b - a)
end

-- One of the arguments, at random.
local function pick(...)
	return (select(math.random(select("#", ...)), ...))
end

local cat = {
	x = 140, -- the sprite's top-left in the window, unscaled px
	y = 220,
	dir = 1,
	mode = "walk",
	t0 = 0,
	until_ms = 0,
	tx = 140,
	ty = 220,
	after = nil, -- what to do when the walk or the yawn is over
	pose = "walk1",
	travelled = 0, -- px walked: drives the legs
	blink_at = 0,
	blink_until = 0,
	swish_at = 0,
	swish_until = 0,
	bubble = nil,
	bubble_until = 0,
	bubble_w = nil, -- measured text widths, from the last paint
	tag_w = nil,
	tag_text = nil,
	mouth_until = 0,
	next_z = 0,
	fx = {},
	ball = nil,
	bats = 0,
	lean = 0, -- carried: how far the lowest row swings, in cells
	swing = 0,
	vy = 0, -- falling to the floor, px per ms
	bounced = false,
	drag = nil,
	box = nil, -- the overlay: { x, y, width, height } in the window
}

local overlay
local overlay_interactive
local last_tick = 0

local function begin(mode, ms)
	cat.mode = mode
	cat.t0 = tg.now()
	cat.until_ms = ms and (cat.t0 + ms) or 0
end

local BUBBLE_FONT = { size = 11, bold = true }
local BUBBLE_MAX = 170
local TAG_FONT = { size = 10, bold = true }

-- Says a phrase; `chance` (1 if not given) is scaled by the
-- talkativeness, a silent cat says nothing.
local function say(text, ms, chance)
	local talk = talkativeness()
	if talk == 0 or math.random() >= (chance or 1) * talk then
		return
	end
	cat.bubble = text
	cat.bubble_until = tg.now() + (ms or 1800)
	cat.bubble_w = nil
	cat.mouth_until = tg.now() + 380
end

-- Hearts, z's, dust: only with the effects on.
local function spawn(kind, x, y, vx, vy, life, delay)
	if not flag("effects") then
		return
	end
	cat.fx[#cat.fx + 1] = {
		kind = kind,
		x = x,
		y = y,
		vx = vx,
		vy = vy,
		t0 = tg.now() + (delay or 0),
		life = life,
	}
end

local function dust()
	for i = 0, 2 do
		spawn("dust", 8 - i * 2, 23, -0.005, -0.002, 420 + i * 90)
		spawn("dust", 25 + i * 2, 23, 0.005, -0.002, 420 + i * 90)
	end
end

local function sprite_size()
	local s = scale()
	return W * s, (H + 1) * s
end

-- Night is from the "from" hour up to the "to" hour, across midnight too.
local function night()
	if not flag("night") then
		return false
	end
	local from = choice("night_from", 24, 24) - 1
	local to = choice("night_to", 8, 24) - 1
	local hour = tonumber(os.date("%H")) or 12
	if from == to then
		return false
	elseif from < to then
		return hour >= from and hour < to
	end
	return hour >= from or hour < to
end

local function head_anchor(name)
	local f = frame(name)
	local cx, top = f.head[1], f.head[2]
	if cat.dir < 0 then
		cx = W - 1 - cx
	end
	return cx + 0.5, top
end

-- The floor: the cat's top when its paws touch the window's bottom edge.
local function floor_y()
	local _, wh = tg.ui.window_size()
	local _, sh = sprite_size()
	return wh and math.max(0, wh - sh) or cat.y
end

-- Where the cat was put last ("stays where it was put"), kept between runs
-- as a share of the room it has in the window.
local function remember_spot(x, y)
	local ww, wh = tg.ui.window_size()
	if not ww then
		return
	end
	local sw, sh = sprite_size()
	plugin.settings.set("spot_x", math.max(0, math.min(1, x / math.max(ww - sw, 1))))
	plugin.settings.set("spot_y", math.max(0, math.min(1, y / math.max(wh - sh, 1))))
end

local function spot()
	local ww, wh = tg.ui.window_size()
	local fx, fy = tonumber(setting("spot_x", nil)), tonumber(setting("spot_y", nil))
	if not ww or not fx or not fy then
		return cat.x, cat.y
	end
	local sw, sh = sprite_size()
	return fx * math.max(ww - sw, 0), fy * math.max(wh - sh, 0)
end

local function spot_radius()
	return 30 + 12 * scale()
end

-- Somewhere to walk to, as the home setting allows.
local function pick_target(far)
	local ww, wh = tg.ui.window_size()
	if not ww then
		return
	end
	local sw, sh = sprite_size()
	local where = home()
	local distance = far and rnd(200, 500) or rnd(80, 340)
	local x, y
	if where == HOME_SPOT then
		local sx, sy = spot()
		local r = spot_radius()
		x, y = sx + rnd(-r, r), sy + rnd(-r, r) * 0.4
	elseif where == HOME_FLOOR then
		x = cat.x + (math.random() < 0.5 and -distance or distance)
		y = wh - sh
	else
		local angle = math.random() * math.pi * 2
		x = cat.x + math.cos(angle) * distance
		y = cat.y + math.sin(angle) * distance * 0.6
	end
	cat.tx = math.max(0, math.min(x, ww - sw))
	if where == HOME_FLOOR then
		cat.ty = math.max(0, wh - sh)
	else
		cat.ty = math.max(where == HOME_SPOT and 0 or 40, math.min(y, wh - sh))
	end
end

local function walk_somewhere(run)
	pick_target(run)
	begin(run and "run" or "walk")
	cat.fx = {}
end

local function choose(options)
	local total = 0
	for _, option in ipairs(options) do
		total = total + option[2]
	end
	local roll = math.random() * total
	for _, option in ipairs(options) do
		roll = roll - option[2]
		if option[2] > 0 and roll <= 0 then
			return option[1]
		end
	end
	return options[1][1]
end

-- Where the ball is when it lies right in front of the paws.
local function ball_offset()
	local s = scale()
	return cat.dir > 0 and 34 * s or -2 * s
end

local PLAY = { crouch = true, bat = true, watch = true, chase = true }

local function start_play()
	local ww = tg.ui.window_size()
	if not ww or not flag("yarn") then
		begin("sit", 3000)
		return
	end
	local s = scale()
	-- The ball lands in front of the paws, or behind if there is no room.
	local x = cat.x + ball_offset()
	if x < 5 * s or x > ww - 5 * s then
		cat.dir = -cat.dir
		x = cat.x + ball_offset()
	end
	cat.ball = { x = x, vx = 0, spin = 0, fade = nil }
	cat.bats = 0
	cat.fx = {}
	begin("crouch", rnd(900, 1500))
end

-- What to do next when nothing is going on.
local function idle()
	local a = activity()
	local what = choose{
		{ "walk", 30 * a.move },
		{ "sit", 24 * a.rest },
		{ "groom", 12 * a.rest },
		{ "stretch", 7 },
		{ "nap", (night() and 45 or 9) * a.rest },
		{ "play", flag("yarn") and 9 * a.move or 0 },
	}
	if what == "walk" then
		walk_somewhere(a.move > 1.5 and math.random() < 0.3)
	elseif what == "sit" then
		begin("sit", rnd(3000, 7000) * a.rest)
		say(pick(plugin.t("say.idle1"), plugin.t("say.idle2"), plugin.t("say.idle3")), nil, 0.18)
	elseif what == "groom" then
		begin("groom", rnd(2600, 4400) * math.min(a.rest, 1.3))
	elseif what == "stretch" then
		begin("stretch", 1700)
	elseif what == "nap" then
		begin("yawn", 1400)
		cat.after = "sleep"
	else
		start_play()
	end
end

local function sleep_ms()
	return (night() and rnd(25000, 60000) or rnd(9000, 20000)) * activity().rest
end

-- A timed mode is over.
local function finish_mode()
	local m = cat.mode
	if m == "yawn" and cat.after == "sleep" then
		cat.after = nil
		begin("sleep", sleep_ms())
	elseif m == "sleep" or m == "wake" then
		begin("stretch", 1700)
		cat.after = "walk"
	elseif m == "stretch" and cat.after == "walk" then
		cat.after = nil
		walk_somewhere(false)
	elseif m == "happy" then
		if math.random() < 0.5 then
			walk_somewhere(true) -- zoomies
		else
			begin("sit", rnd(2500, 5000))
		end
	elseif m == "land" then
		local next_one = choose{ { "groom", 45 }, { "sit", 35 }, { "run", 20 } }
		if next_one == "groom" then
			begin("groom", rnd(2200, 3600))
		elseif next_one == "sit" then
			begin("sit", rnd(2000, 4000))
		else
			walk_somewhere(true)
		end
	elseif m == "hello" then
		begin("sit", rnd(3000, 6000))
	elseif m == "crouch" then
		begin("bat", 360)
	elseif m == "bat" then
		local ball = cat.ball
		if ball then
			ball.vx = cat.dir * rnd(0.16, 0.26)
			cat.bats = cat.bats + 1
			say(pick(plugin.t("say.play1"), plugin.t("say.play2")), 1300, 0.3)
		end
		begin("watch", 500)
	elseif m == "watch" then
		if cat.ball and cat.bats < 3 and math.random() < 0.8 then
			begin("chase")
		else
			if cat.ball then
				cat.ball.fade = tg.now()
			end
			begin("sit", rnd(2500, 4500))
		end
	else
		idle()
	end
end

local function pet()
	if cat.mode == "carried" or cat.mode == "fall" then
		return
	end
	cat.after = nil
	if cat.mode == "sleep" then
		say(pick(plugin.t("say.sleepy1"), plugin.t("say.sleepy2")))
		begin("wake", 1400)
		return
	end
	if cat.mode ~= "happy" then
		local name = setting("name", "")
		if type(name) == "string" and name ~= "" and math.random() < 0.45 then
			say(plugin.t("say.name", name))
		else
			say(pick(plugin.t("say.pet1"), plugin.t("say.pet2"), plugin.t("say.pet3"),
				plugin.t("say.pet4")))
		end
	end
	if cat.ball and not cat.ball.fade then
		cat.ball.fade = tg.now()
	end
	begin("happy", 2400)
	cat.pose = "happy1"
	local cx, top = head_anchor("happy1")
	for i = 0, 2 do
		local side = (i % 2 == 0) and -1 or 1
		spawn("heart", cx - 2.5 + side * rnd(7, 9), top + 5, side * 0.0025, -0.009 - i * 0.001,
			1500 + i * 200, i * 350)
	end
end

-- Falls down to the floor and bounces a little (the "bottom edge" home).
local function start_fall()
	begin("fall")
	cat.vy = 0
	cat.bounced = false
	cat.pose = "hang2"
end

------------------------------------------------------------ the frame

local function tag_text()
	if setting("name_tag", false) ~= true then
		return nil
	end
	local name = setting("name", "")
	if type(name) ~= "string" or name == "" then
		return nil
	end
	return name
end

local function estimate(text, per_char)
	return (utf8.len(text) or #text) * per_char
end

-- The name tag and the bubble over the head, in the window: { x, y, w, h }.
-- tag_w and bubble_w are text widths (nil: not shown).
local function labels(tag_w, bubble_w)
	local s = scale()
	local cx, top = head_anchor(cat.pose)
	local ww = tg.ui.window_size() or 4096
	local center = cat.x + cx * s
	local bottom = cat.y + top * s - 3
	local tag, bubble
	if tag_w then
		local w, h = tag_w + 12, 15
		tag = { math.max(1, math.min(center - w / 2, ww - w - 1)), math.max(0, bottom - h), w, h }
		bottom = tag[2] - 2
	end
	if bubble_w then
		local w = math.min(bubble_w + 16, BUBBLE_MAX)
		local lines = (bubble_w + 16 > BUBBLE_MAX) and 2 or 1
		local h = lines * 15 + 6
		bubble = { math.max(2, math.min(center - w / 2, ww - w - 2)), math.max(0, bottom - h - 6), w, h, lines }
	end
	return tag, bubble
end

local function fx_size(p, q)
	local g = GLYPHS[p.kind]
	if g then
		return g.w * q, g.h * q
	end
	return 5 * q, 5 * q -- dust
end

-- The overlay covers the sprite and whatever floats around it.
local function layout()
	local s = scale()
	local q = math.max(1, s - 1)
	local sw, sh = sprite_size()
	local x1, y1 = cat.x, cat.y
	local x2, y2 = cat.x + sw, cat.y + sh
	local function add(x, y, w, h)
		x1, y1 = math.min(x1, x), math.min(y1, y)
		x2, y2 = math.max(x2, x + w), math.max(y2, y + h)
	end
	local now = tg.now()
	for _, p in ipairs(cat.fx) do
		local w, h = fx_size(p, q)
		-- Where it is now and where it will be in a few frames.
		local age = math.max(0, now - p.t0)
		for _, a in ipairs({ age, math.min(age + 160, p.life) }) do
			local x = cat.x + (p.x + p.vx * a) * s
			local y = cat.y + (p.y + p.vy * a) * s
			add(x - 2 * s, y - h - 2, w + 4 * s, 2 * h + 4)
		end
	end
	if cat.ball then
		local g = GLYPHS.ball1
		add(cat.ball.x - g.w * s / 2 - 4 * s, cat.y + (H - g.h) * s, (g.w + 8) * s, g.h * s + 2)
	end
	local name = tag_text()
	local tag_w = name and (name == cat.tag_text and cat.tag_w or estimate(name, 6.5)) or nil
	local bubble_w = cat.bubble and (cat.bubble_w or estimate(cat.bubble, 7)) or nil
	local tag, bubble = labels(tag_w, bubble_w)
	if tag then
		add(tag[1], tag[2], tag[3], tag[4])
	end
	if bubble then
		add(bubble[1], bubble[2], bubble[3], bubble[4] + 6)
	end
	local x, y = math.floor(x1) - 1, math.floor(y1) - 1
	return x, y, math.ceil(x2) + 1 - x, math.ceil(y2) + 1 - y
end

-- Which frame to show now.
local function animate(now)
	local m = cat.mode
	local t = now - cat.t0
	local s = scale()
	local blink = now < cat.blink_until
	local talk = now < cat.mouth_until
	local pose
	if m == "walk" or m == "run" or m == "chase" then
		if m == "walk" then
			pose = "walk" .. (math.floor(cat.travelled / (3 * s)) % 4 + 1)
			if talk then
				pose = pose .. "_m"
			elseif blink then
				pose = pose .. "_b"
			end
		else
			pose = "run" .. (math.floor(cat.travelled / (5 * s)) % 2 + 1)
		end
	elseif m == "sit" or m == "hello" or m == "watch" then
		local tail = 1
		if now < cat.swish_until then
			local order = { 1, 3, 2, 3 }
			tail = order[(now // 170) % 4 + 1]
		end
		pose = "sit" .. tail
		if talk then
			pose = pose .. "_m"
		elseif blink then
			pose = pose .. "_b"
		end
	elseif m == "wake" then
		pose = (t < 700) and "sit1_c" or "sit1_b"
	elseif m == "groom" then
		local phase = (t // 230) % 9
		if phase < 6 then
			pose = (phase % 2 == 0) and "lick1" or "lick2"
		else
			pose = "wipe"
		end
	elseif m == "stretch" then
		pose = (t < 1450) and "stretch" or "sit1_b"
	elseif m == "yawn" then
		pose = (t > 180 and t < 1150) and "yawn" or "sit1_b"
	elseif m == "sleep" then
		pose = ((now // 1100) % 2 == 0) and "sleep1" or "sleep2"
	elseif m == "happy" then
		pose = ((t // 320) % 2 == 0) and "happy1" or "happy2"
	elseif m == "carried" then
		local moving = math.abs(cat.swing) > 0.25 or math.abs(cat.lean) > 2.2
		pose = moving and "hang2" or "hang1"
		if cat.drag and now - cat.drag.moved_at > 2600 then
			pose = pose .. "_c"
		end
	elseif m == "fall" then
		pose = cat.bounced and "land" or "hang2"
	elseif m == "land" then
		pose = (t < 200) and "land" or "sit1_b"
	elseif m == "crouch" then
		pose = ((t // 150) % 2 == 0) and "crouch1" or "crouch2"
	elseif m == "bat" then
		pose = "bat"
	else
		pose = "sit1"
	end
	cat.pose = pose
end

local function update_fx(now)
	if not flag("effects") then
		cat.fx = {}
		return
	end
	local alive = {}
	for _, p in ipairs(cat.fx) do
		if now - p.t0 < p.life then
			alive[#alive + 1] = p
		end
	end
	cat.fx = alive
end

local function update_ball(now, dt, ww)
	local ball = cat.ball
	if not ball then
		return
	end
	if not ball.fade and not PLAY[cat.mode] and cat.mode ~= "sit" then
		ball.fade = now -- the cat lost interest
	end
	if ball.fade and now - ball.fade > 900 then
		cat.ball = nil
		return
	end
	if ball.vx ~= 0 then
		local r = 4 * scale()
		ball.x = ball.x + ball.vx * dt
		ball.spin = ball.spin + math.abs(ball.vx) * dt
		if ball.x < r then
			ball.x, ball.vx = r, math.abs(ball.vx)
		elseif ball.x > ww - r then
			ball.x, ball.vx = ww - r, -math.abs(ball.vx)
		end
		ball.vx = ball.vx * (0.93 ^ (dt / 40))
		if math.abs(ball.vx) < 0.01 then
			ball.vx = 0
		end
	end
end

-- Walks or runs towards x, y; true on arrival.
local function step_to(x, y, v, dt)
	local dx, dy = x - cat.x, y - cat.y
	local distance = math.sqrt(dx * dx + dy * dy)
	local step = v * dt / 1000
	if math.abs(dx) > 1 then
		cat.dir = dx > 0 and 1 or -1
	end
	if distance <= step then
		cat.x, cat.y = x, y
		cat.travelled = cat.travelled + distance
		return true
	end
	cat.x = cat.x + dx / distance * step
	cat.y = cat.y + dy / distance * step
	cat.travelled = cat.travelled + step
	return false
end

-- Carried: the body lags behind the cursor and swings like a pendulum.
local function swing(dt)
	local drag = cat.drag
	if not drag then
		return
	end
	local vx = (drag.x - drag.last) / math.max(dt, 1) -- px per ms
	drag.last = drag.x
	local target = math.max(-6, math.min(6, -vx * 16))
	cat.swing = (cat.swing + (target - cat.lean) * 0.32) * 0.8
	cat.lean = math.max(-7, math.min(7, cat.lean + cat.swing))
end

local function chase(ww, v, dt)
	local ball = cat.ball
	if not ball then
		begin("sit", 3000)
		return
	end
	local s = scale()
	cat.dir = (ball.x > cat.x + 16 * s) and 1 or -1
	local x = math.max(0, math.min(ball.x - ball_offset(), ww - W * s))
	local arrived = step_to(x, cat.y, v, dt)
	if arrived and ball.vx == 0 then
		cat.dir = (ball.x > cat.x + 16 * s) and 1 or -1
		begin("crouch", rnd(700, 1300))
	end
end

local function fall(dt)
	local floor = floor_y()
	cat.vy = cat.vy + 0.0022 * dt
	cat.y = cat.y + cat.vy * dt
	if cat.y < floor then
		return
	end
	cat.y = floor
	if not cat.bounced and cat.vy > 0.2 then
		cat.bounced = true
		cat.vy = -cat.vy * 0.3
		dust()
	else
		if not cat.bounced then
			dust()
		end
		begin("land", 900)
	end
end

-- The home setting: the floor keeps the cat on the bottom edge, the spot
-- needs a place to stay at.
local function keep_home()
	local where = home()
	local m = cat.mode
	if where == HOME_FLOOR and m ~= "carried" and m ~= "fall" then
		local floor = floor_y()
		if cat.y < floor - 1 then
			start_fall()
		else
			cat.y = floor
			cat.ty = floor
		end
	elseif where == HOME_SPOT and tonumber(setting("spot_x", nil)) == nil then
		remember_spot(cat.x, cat.y)
	end
end

local function tick()
	local now = tg.now()
	local dt = math.min(math.max(now - last_tick, 1), 200)
	last_tick = now
	local ww, wh = tg.ui.window_size()
	if not ww then
		return
	end
	local m = cat.mode

	if now > cat.blink_at then
		cat.blink_until = now + 140
		cat.blink_at = now + (math.random() < 0.2 and 320 or rnd(2200, 5200))
	end
	if (m == "sit" or m == "hello" or m == "watch") and now > cat.swish_at then
		cat.swish_until = now + rnd(600, 1800)
		cat.swish_at = cat.swish_until + rnd(1200, 3800)
	end
	if cat.bubble and (now > cat.bubble_until or talkativeness() == 0) then
		cat.bubble = nil
	end
	if PLAY[m] and not flag("yarn") then
		if cat.ball then
			cat.ball.fade = cat.ball.fade or now
		end
		begin("sit", 2000)
		m = cat.mode
	end

	if m == "carried" then
		swing(dt)
	elseif m == "fall" then
		fall(dt)
	elseif m == "walk" or m == "run" then
		local v = (m == "run" and 120 or 38) * speed()
		if step_to(cat.tx, cat.ty, v, dt) then
			if cat.after == "hello" then
				cat.after = nil
				begin("hello", 1600)
				say(pick(plugin.t("say.here1"), plugin.t("say.here2")))
			else
				idle()
			end
		end
	elseif m == "chase" then
		chase(ww, 100 * speed(), dt)
	elseif m == "sleep" and now > cat.next_z then
		cat.next_z = now + 1300
		spawn("z", cat.dir > 0 and 27 or 0, 8, cat.dir * 0.003, -0.006, 2400)
	end
	if cat.until_ms > 0 and now >= cat.until_ms and cat.mode == m then
		finish_mode()
	end
	if not cat.drag then
		keep_home()
	end

	update_ball(now, dt, ww)
	update_fx(now)
	animate(now)

	-- The window may have become smaller, or the cat bigger.
	if not cat.drag then
		local sw, sh = sprite_size()
		cat.x = math.max(0, math.min(cat.x, ww - sw))
		cat.y = math.max(0, math.min(cat.y, wh - sh))
	end
end

------------------------------------------------------------- painting

local function draw_fx(c, ox, oy, s, now, base)
	local q = math.max(1, s - 1)
	for _, p in ipairs(cat.fx) do
		local age = now - p.t0
		if age >= 0 then
			local k = age / p.life
			local x = ox + (p.x + p.vx * age) * s
			local y = oy + (p.y + p.vy * age) * s
			local g = GLYPHS[p.kind]
			if g then
				x = x + math.sin(age / (p.kind == "z" and 300 or 180)) * s
				c:opacity(base * (k < 0.7 and 1 or (1 - k) / 0.3))
				draw_glyph(c, g, math.floor(x), math.floor(y - g.h * q), q)
			else -- dust
				local size = math.floor((2 + k * 3) * q)
				c:opacity(base * 0.75 * (1 - k))
				c:rect(math.floor(x - size / 2), math.floor(y - size), size, size, "#d6cdbf", q)
			end
		end
	end
	c:opacity(base)
end

-- A rectangle from the window into the canvas, kept inside it; nil if it
-- does not fit (the overlay is held as it was while the cat is carried).
local function to_canvas(rect, box, w, h, below)
	local x = math.max(0, math.min(rect[1] - box[1], w - rect[3]))
	local y = math.max(0, rect[2] - box[2])
	if rect[3] > w or y + rect[4] + (below or 0) > h then
		return nil
	end
	return x, y
end

local function draw_labels(c, w, h, box, base)
	local name = tag_text()
	if name then
		cat.tag_w = c:measure(name, TAG_FONT)
		cat.tag_text = name
	end
	if cat.bubble then
		cat.bubble_w = c:measure(cat.bubble, BUBBLE_FONT)
	end
	local tag, bubble = labels(name and cat.tag_w or nil, cat.bubble and cat.bubble_w or nil)
	if tag then
		local x, y = to_canvas(tag, box, w, h)
		if x then
			c:opacity(base * 0.9)
			c:rect(x, y, tag[3], tag[4], "windowBg", 7)
			c:opacity(base)
			c:stroke(x, y, tag[3], tag[4], "windowSubTextFg", 1, 7)
			c:text(x + 6, y + 1, name, {
				size = TAG_FONT.size,
				bold = true,
				color = "windowFg",
				width = tag[3] - 12,
				height = 13,
				align = "center",
			})
		end
	end
	if bubble then
		local x, y = to_canvas(bubble, box, w, h, 6)
		if x then
			c:opacity(1) -- what the cat says stays readable
			local cx = head_anchor(cat.pose)
			local tip = math.floor(cat.x) - box[1] + cx * scale()
			tip = math.max(x + 9, math.min(tip, x + bubble[3] - 9))
			local bottom = y + bubble[4]
			c:polygon({ tip - 5, bottom - 1, tip + 5, bottom - 1, tip, bottom + 6 }, "windowSubTextFg")
			c:rect(x, y, bubble[3], bubble[4], "windowBg", 9)
			c:stroke(x, y, bubble[3], bubble[4], "windowSubTextFg", 1, 9)
			c:polygon({ tip - 4, bottom - 1.5, tip + 4, bottom - 1.5, tip, bottom + 4.5 }, "windowBg")
			c:text(x + 8, y + 3, cat.bubble, {
				size = BUBBLE_FONT.size,
				bold = true,
				color = "windowFg",
				width = bubble[3] - 16,
				height = bubble[5] * 15,
				align = "center",
			})
		end
	end
end

local function draw_ball(c, ox, oy, s, base)
	local ball = cat.ball
	if not ball then
		return
	end
	local g = (math.floor(ball.spin / (3 * s)) % 2 == 0) and GLYPHS.ball1 or GLYPHS.ball2
	local x = math.floor(ox + (ball.x - math.floor(cat.x)) - g.w * s / 2)
	local y = oy + (H - g.h) * s
	local fade = ball.fade and math.max(0, 1 - (tg.now() - ball.fade) / 900) or 1
	c:opacity(base * fade)
	-- A loose end of the yarn on the floor, behind the ball.
	local tail_x = (ball.vx >= 0) and (x - 3 * s) or (x + g.w * s)
	c:rect(tail_x, y + (g.h - 2) * s, 3 * s, s, "#b8364f")
	draw_glyph(c, g, x, y, s)
	c:opacity(base)
end

local function draw_shadow(c, f, x, y, s, dir, base)
	if not f.feet then
		return
	end
	local l, r = f.feet[1], f.feet[2]
	if dir < 0 then
		l, r = W - 1 - r, W - 1 - l
	end
	l, r = math.max(0, l - 1), math.min(W, r + 2)
	c:opacity(0.22 * base)
	c:rect(x + l * s, y + (H - 1) * s + s / 2, (r - l) * s, s * 1.4, "#000000", s * 0.7)
	c:opacity(base)
end

local function paint(c)
	local w, h = c:size()
	local box = cat.box
	if not box then
		return
	end
	local s = scale()
	local base = opacity()
	local now = tg.now()
	local ox = math.floor(cat.x) - box[1]
	local oy = math.floor(cat.y) - box[2]
	c:opacity(base)
	local shift
	if cat.mode == "carried" then
		shift = {}
		for row = 0, H - 1 do
			shift[row] = math.floor(cat.lean * math.max(0, row - 3) / (H - 4) + 0.5)
		end
	elseif cat.mode ~= "fall" and flag("shadow") then
		draw_shadow(c, frame(cat.pose), ox, oy, s, cat.dir, base)
	end
	local purr = (cat.mode == "happy" and (now // 70) % 2 == 0) and 1 or 0
	draw_frame(c, cat.pose, coat_key(), ox + purr, oy, s, cat.dir, shift)
	if cat.mode == "carried" and cat.drag and now - cat.drag.started < 1500 and flag("effects") then
		draw_glyph(c, GLYPHS.bang, ox + 23 * s, oy + 2 * s, math.max(1, s - 1))
	end
	draw_ball(c, ox, oy, s, base)
	draw_fx(c, ox, oy, s, now, base)
	draw_labels(c, w, h, box, base)
	c:opacity(1)
end

------------------------------------------------------------- overlay

local function close_overlay()
	if overlay then
		overlay:close()
		overlay = nil
	end
	cat.box = nil
	if cat.drag then
		cat.drag = nil
		begin("land", 900)
	end
end

-- The client moves the overlay after the cursor and tells where its
-- top-left is; the cat keeps its place inside the overlay.
local function drag_start(x, y)
	local now = tg.now()
	local box = cat.box
	cat.drag = {
		dx = cat.x - (box and box[1] or x),
		dy = cat.y - (box and box[2] or y),
		x = x,
		last = x,
		started = now,
		moved_at = now,
	}
	if box then
		box[1], box[2] = x, y
	end
	cat.x, cat.y = x + cat.drag.dx, y + cat.drag.dy
	cat.fx = {}
	cat.ball = nil
	cat.lean, cat.swing = 0, 0
	cat.after = nil
	begin("carried")
	cat.pose = "hang1"
	if cat.bubble then
		-- There is room above the head: the overlay already holds a bubble.
		say(pick(plugin.t("say.carry1"), plugin.t("say.carry2"), plugin.t("say.carry3")), 1400)
	end
end

local function drag_move(x, y)
	local drag = cat.drag
	if not drag then
		return
	end
	if x ~= drag.x or y + drag.dy ~= cat.y then
		drag.moved_at = tg.now()
	end
	drag.x = x
	cat.x, cat.y = x + drag.dx, y + drag.dy
	if cat.box then
		cat.box[1], cat.box[2] = x, y
	end
end

local function drag_drop(x, y)
	drag_move(x, y)
	cat.drag = nil
	cat.lean, cat.swing = 0, 0
	local where = home()
	if where == HOME_FLOOR and cat.y < floor_y() - 1 then
		start_fall()
		return
	end
	if where == HOME_SPOT then
		remember_spot(cat.x, cat.y)
	end
	begin("land", 900)
	cat.pose = "land"
	dust()
	say(pick(plugin.t("say.land1"), plugin.t("say.land2"), plugin.t("say.land3")), 1500, 0.6)
end

local function open_overlay()
	local x, y, w, h = layout()
	local interactive = setting("pettable", true) ~= false
	cat.box = { x, y, w, h }
	-- draggable and on_drag* are new: older clients skip them and only
	-- take the click.
	overlay = tg.ui.overlay{
		x = x,
		y = y,
		width = w,
		height = h,
		paint = paint,
		on_click = interactive and function()
			pet()
		end or nil,
		draggable = interactive or nil,
		on_drag_start = interactive and drag_start or nil,
		on_drag = interactive and drag_move or nil,
		on_drop = interactive and drag_drop or nil,
	}
	overlay_interactive = interactive
end

local function frame_loop()
	if not flag("enabled") then
		close_overlay()
		return
	end
	if overlay and overlay_interactive ~= (setting("pettable", true) ~= false) then
		close_overlay()
	end
	tick()
	if not tg.ui.window_size() then
		return
	end
	if not overlay then
		open_overlay()
		if not overlay then
			return
		end
	elseif not cat.drag then
		-- While carried, the client holds the overlay and skips moves.
		local x, y, w, h = layout()
		local box = cat.box
		if not box or box[1] ~= x or box[2] ~= y or box[3] ~= w or box[4] ~= h then
			cat.box = { x, y, w, h }
			overlay:move{ x = x, y = y, width = w, height = h }
		end
	end
	overlay:update()
end

-- 25 frames a second. Repeating timers are 100 ms at least, so the next
-- frame is planned by the current one; the next is planned first, so a
-- failed frame does not stop the cat.
local function loop()
	tg.timer.after(40, loop)
	frame_loop()
end
last_tick = tg.now()
cat.blink_at = last_tick + 2000
loop()

local function call_cat()
	if not flag("enabled") then
		plugin.settings.set("enabled", true)
		plugin.settings.refresh()
	end
	local ww, wh = tg.ui.window_size()
	if not ww or cat.mode == "carried" or cat.mode == "fall" then
		return
	end
	local sw, sh = sprite_size()
	cat.tx = math.floor((ww - sw) / 2)
	cat.ty = math.floor((wh - sh) / (home() == HOME_FLOOR and 1 or 2))
	if home() == HOME_SPOT then
		remember_spot(cat.tx, cat.ty) -- it lives here now
	end
	cat.ball = nil
	cat.fx = {}
	begin("run")
	cat.after = "hello"
	say(pick(plugin.t("say.coming1"), plugin.t("say.coming2")), 1400)
end

-------------------------------------------------------------- the page

-- The preview shows three poses; a click shows the next three.
local PREVIEW = {
	{ "sit1", "walk1", "sleep1" },
	{ "happy1", "lick1", "stretch" },
	{ "hang2", "crouch2", "yawn" },
	{ "run1", "wipe", "sleep2" },
}
local preview_set = 1
local PREVIEW_HEIGHT = 112

local function paint_preview(c)
	local w, h = c:size()
	local key = coat_key()
	local base = opacity()
	local s = (w >= 3 * W * 3 + 40) and 3 or 2
	local gap = 12
	local ox = (w - (3 * W * s + 2 * gap)) / 2
	local oy = math.floor(h - (H + 1) * s - 4)
	local name = tag_text()
	for i, pose in ipairs(PREVIEW[preview_set]) do
		local x = math.floor(ox + (i - 1) * (W * s + gap))
		c:opacity(base)
		if flag("shadow") and not pose:match("^hang") then
			draw_shadow(c, frame(pose), x, oy, s, 1, base)
		end
		draw_frame(c, pose, key, x, oy, s, 1)
		if name and i == 2 then
			local f = frame(pose)
			local tw = math.min(c:measure(name, TAG_FONT), W * s + gap * 2 - 12)
			local tx = x + (f.head[1] + 0.5) * s - (tw + 12) / 2
			local ty = math.max(0, oy + f.head[2] * s - 18)
			c:opacity(base * 0.9)
			c:rect(tx, ty, tw + 12, 15, "windowBg", 7)
			c:opacity(base)
			c:stroke(tx, ty, tw + 12, 15, "windowSubTextFg", 1, 7)
			c:text(tx + 6, ty + 1, name, {
				size = TAG_FONT.size,
				bold = true,
				color = "windowFg",
				width = tw,
				height = 13,
				align = "center",
			})
		end
	end
	c:opacity(1)
end

local function refresh()
	plugin.settings.refresh()
end

local function hours()
	local list = {}
	for hour = 0, 23 do
		list[#list + 1] = string.format("%d:00", hour)
	end
	return list
end

local function settings_page()
	local rows = {
		{ type = "header", text = plugin.t("settings.cat") },
		{
			type = "switch",
			key = "enabled",
			text = plugin.t("settings.enabled"),
			icon = "fave",
			default = true,
		},
		{
			type = "input",
			key = "name",
			text = plugin.t("settings.name"),
			placeholder = plugin.t("settings.name.placeholder"),
			icon = "edit",
			on_change = refresh,
		},
		{
			type = "switch",
			key = "pettable",
			text = plugin.t("settings.interact"),
			subtext = plugin.t("settings.interact.about"),
			icon = "like",
			default = true,
			on_change = close_overlay,
		},
		{
			type = "text",
			text = plugin.t("call"),
			icon = "add_user",
			accent = true,
			on_click = call_cat,
		},

		{ type = "header", text = plugin.t("settings.appearance") },
		{
			type = "selector",
			key = "coat",
			text = plugin.t("settings.coat"),
			items = {
				plugin.t("coat.ginger"),
				plugin.t("coat.grey"),
				plugin.t("coat.black"),
				plugin.t("coat.white"),
				plugin.t("coat.siamese"),
				plugin.t("coat.tabby"),
				plugin.t("coat.tuxedo"),
				plugin.t("coat.calico"),
				plugin.t("coat.custom"),
			},
			default = 1,
			icon = "palette",
			on_change = refresh,
		},
	}
	local function add(row)
		rows[#rows + 1] = row
	end
	if choice("coat", 1, CUSTOM) == CUSTOM then
		add{
			type = "selector",
			key = "fur",
			text = plugin.t("settings.fur"),
			items = {
				plugin.t("fur.black"),
				plugin.t("fur.smoky"),
				plugin.t("fur.grey"),
				plugin.t("fur.blue"),
				plugin.t("fur.lilac"),
				plugin.t("fur.white"),
				plugin.t("fur.cream"),
				plugin.t("fur.fawn"),
				plugin.t("fur.golden"),
				plugin.t("fur.ginger"),
				plugin.t("fur.brown"),
				plugin.t("fur.chocolate"),
			},
			default = 10,
			icon = "draw",
			on_change = refresh,
		}
		add{
			type = "selector",
			key = "pattern",
			text = plugin.t("settings.pattern"),
			items = {
				plugin.t("pattern.none"),
				plugin.t("pattern.stripes"),
				plugin.t("pattern.patches"),
				plugin.t("pattern.tuxedo"),
				plugin.t("pattern.points"),
			},
			default = PATTERN_STRIPES,
			icon = "customize",
			on_change = refresh,
		}
		add{
			type = "selector",
			key = "eyes",
			text = plugin.t("settings.eyes"),
			items = {
				plugin.t("eyes.dark"),
				plugin.t("eyes.green"),
				plugin.t("eyes.hazel"),
				plugin.t("eyes.amber"),
				plugin.t("eyes.copper"),
				plugin.t("eyes.blue"),
			},
			default = 2,
			icon = "eye",
			on_change = refresh,
		}
	end
	add{
		type = "slider",
		key = "size",
		text = plugin.t("settings.size"),
		min = 1,
		max = 6,
		step = 1,
		default = 3,
	}
	add{
		type = "slider",
		key = "opacity",
		text = plugin.t("settings.opacity"),
		min = 40,
		max = 100,
		step = 10,
		default = 100,
		on_change = refresh,
	}
	add{
		type = "switch",
		key = "shadow",
		text = plugin.t("settings.shadow"),
		default = true,
		on_change = refresh,
	}
	add{
		type = "switch",
		key = "name_tag",
		text = plugin.t("settings.name_tag"),
		subtext = plugin.t("settings.name_tag.about"),
		default = false,
		on_change = refresh,
	}
	add{
		type = "custom",
		height = PREVIEW_HEIGHT,
		paint = paint_preview,
		on_click = function()
			preview_set = preview_set % #PREVIEW + 1
			refresh()
		end,
	}
	add{ type = "divider", text = plugin.t("settings.preview.about") }

	add{ type = "header", text = plugin.t("settings.behaviour") }
	add{
		type = "slider",
		key = "speed",
		text = plugin.t("settings.speed"),
		min = 1,
		max = 5,
		step = 1,
		default = 2,
	}
	add{
		type = "selector",
		key = "activity",
		text = plugin.t("settings.activity"),
		items = {
			plugin.t("activity.lazy"),
			plugin.t("activity.calm"),
			plugin.t("activity.normal"),
			plugin.t("activity.playful"),
			plugin.t("activity.restless"),
		},
		default = 3,
		icon = "timer",
	}
	add{
		type = "selector",
		key = "talk",
		text = plugin.t("settings.talk"),
		items = {
			plugin.t("talk.silent"),
			plugin.t("talk.quiet"),
			plugin.t("talk.normal"),
			plugin.t("talk.chatty"),
		},
		default = 3,
		icon = "chat",
	}
	add{
		type = "switch",
		key = "yarn",
		text = plugin.t("settings.yarn"),
		icon = "star",
		default = true,
	}
	add{
		type = "switch",
		key = "effects",
		text = plugin.t("settings.effects"),
		subtext = plugin.t("settings.effects.about"),
		icon = "like",
		default = true,
	}
	add{
		type = "switch",
		key = "night",
		text = plugin.t("settings.night"),
		subtext = plugin.t("settings.night.about"),
		icon = "night",
		default = true,
		on_change = refresh,
	}
	if flag("night") then
		add{
			type = "selector",
			key = "night_from",
			text = plugin.t("settings.night_from"),
			items = hours(),
			default = 24,
			icon = "schedule",
		}
		add{
			type = "selector",
			key = "night_to",
			text = plugin.t("settings.night_to"),
			items = hours(),
			default = 8,
			icon = "schedule",
		}
	end

	add{ type = "header", text = plugin.t("settings.home") }
	add{
		type = "selector",
		key = "home",
		text = plugin.t("settings.home.where"),
		items = {
			plugin.t("home.anywhere"),
			plugin.t("home.floor"),
			plugin.t("home.spot"),
		},
		default = HOME_ANYWHERE,
		icon = "location",
	}
	add{ type = "divider", text = plugin.t("settings.home.about") }
	return rows
end

plugin.settings.page(settings_page)

plugin.menu{
	place = "main",
	text = plugin.t("call"),
	icon = "fave",
	on_click = call_cat,
}
