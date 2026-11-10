local ADDON, ns = ...
local L = ns.L

-- Wanderer at the mailbox: a card beside the game's window says what the inbox holds and takes what you choose
-- (the auction house's letters, the players', Forever's kept loot, the gold alone, all where the game has no such
-- button), how far while it takes, what it took after; on each letter, what becomes of it, and its shortcuts;
-- who to write to, under the letter you write, and a word when the name looks wrong; your letters leaving the
-- mailboxes of your other characters (a notice, and their line in Wanderer's characters' window).

local W = Wanderer
local U = W and W.Util
local Skin = W and W.Skin
local Safe, Clean = U and U.Safe, U and U.Clean
local Fold = U and U.Fold or string.lower -- names compared: small letters, no accents

local STEP = 0.35 -- seconds between two takes
local REFUSAL_WAIT = 1 -- seconds after asking for an item when the game's refusal is taken as its own
local MAX_ATTACHMENTS = ATTACHMENTS_MAX_RECEIVE or 16
local MAX_TRIES = 3
local MAX_CHIPS = 16 -- recipients offered at most
local RECENT_KEPT = 5 -- players written to lately, kept per character
local SOON = 1 -- days: a letter going back within this long is said
local CHIP_HEIGHT = 20 -- the arrow at the end of the name field
local KEEP_FREE = 1 -- free places a take leaves in your bags (an item joining a stack needs none)
local MAX_SEND = 12 -- attachments of a letter you write

-- The sender words of the letters bringing back the loot Forever keeps for you (lower case, part of the name):
-- they make their own block. Learned in game with /wmail dump; a sender not here: a player's letter, as before.
local LOST_SENDERS = { "lost and found" }
ns.LOST_SENDERS = LOST_SENDERS -- (tests)

local function Settings() return W and W.Settings and W.Settings("mail") or nil end
local function On()
	local settings = Settings()
	return settings and settings.enabled and true or false
end

local function DB()
	WandererMailDB = type(WandererMailDB) == "table" and WandererMailDB or {}
	local db = WandererMailDB
	db.recent = type(db.recent) == "table" and db.recent or {}
	return db
end

-- Letters about to leave the mailbox of your other characters ----------------------------------------------
-- Each character's soonest letter with something inside (gold or items: lost or sent back when its time is
-- up), seen when that character opens its mailbox, kept by character key for the whole account. At login, a
-- quiet notice when one of the others has a letter leaving within a few days, once a day for each of them.

local DAY = 86400
local SOON_OTHERS = 3 -- days: a letter of another character leaving within this long is told

local function Account()
	WandererMailAccountDB = type(WandererMailAccountDB) == "table" and WandererMailAccountDB or {}
	local account = WandererMailAccountDB
	account.letters = type(account.letters) == "table" and account.letters or {}
	return account
end

-- What this character's mailbox holds now, read while it is open: its soonest letter worth keeping.
local function RecordLetters()
	local key = W.CharacterKey and W.CharacterKey()
	if not key then return end
	local soonest, count = nil, 0
	for index = 1, Clean(Safe(GetInboxNumItems)) or 0 do
		local _, _, _, _, money, _, daysLeft, hasItem = Safe(GetInboxHeaderInfo, index)
		daysLeft = tonumber(Clean(daysLeft))
		-- (the items: a count, or true on older clients)
		local items = Clean(hasItem)
		items = items == true and 1 or tonumber(items) or 0
		if daysLeft and ((Clean(money) or 0) > 0 or items > 0) then
			count = count + 1
			if not soonest or daysLeft < soonest then soonest = daysLeft end
		end
	end
	local letters = Account().letters
	if not soonest then
		letters[key] = nil
		return
	end
	local told = type(letters[key]) == "table" and letters[key].told or nil
	letters[key] = { leaves = time() + math.floor(soonest * DAY), count = count, told = told }
end
ns.RecordLetters = RecordLetters

-- The others' letters leaving soon: { { name, leaves, count, key } }, the soonest first. Those gone already, or
-- of a character forgotten, let go.
function ns.LettersLeaving()
	local letters, now, found, known = Account().letters, time(), {}, {}
	for _, who in ipairs(W.Characters(true)) do known[who.key] = who end
	for key, entry in pairs(letters) do
		local who = known[key]
		local leaves = type(entry) == "table" and tonumber(entry.leaves)
		if not leaves or leaves <= now or not (who or key == W.CharacterKey()) then
			letters[key] = nil
		elseif who and leaves - now <= SOON_OTHERS * DAY then
			found[#found + 1] = { name = who.name, leaves = leaves, count = entry.count or 1, key = key }
		end
	end
	table.sort(found, function(a, b) return a.leaves < b.leaves end)
	return found
end

-- Told once a day at most for each character (whichever of yours logs in).
function ns.TellLettersLeaving()
	local settings = Settings()
	if not (On() and settings.leaving) then return end
	local today, letters = math.floor(time() / DAY), Account().letters
	local fresh = {}
	for _, leaving in ipairs(ns.LettersLeaving()) do
		local entry = letters[leaving.key]
		if entry.told ~= today then
			entry.told = today
			fresh[#fresh + 1] = leaving
		end
	end
	if not fresh[1] then return end
	local first = fresh[1]
	local text
	if fresh[2] then
		local names = {}
		for _, leaving in ipairs(fresh) do names[#names + 1] = leaving.name end
		text = L.LEAVING_MANY:format(table.concat(names, ", "), U.Ago(first.leaves - time()))
	else
		text = L.LEAVING_ONE:format(first.name, U.Ago(first.leaves - time()))
	end
	W.Toast(L.LEAVING_TITLE, text, { icon = "Interface\\Icons\\INV_Letter_15", kicker = L.ADDON })
end

-- This character's own letter leaving within SOON_OTHERS days (as seen last time its mailbox was open), when the
-- notice is wanted: its time, else nil. (The town card's mailbox line, Town.lua.)
function ns.OwnLeaving()
	local settings = Settings()
	if not (type(settings) == "table" and settings.enabled and settings.leaving and W.CharacterKey) then return nil end
	local entry = Account().letters[W.CharacterKey()]
	local leaves = type(entry) == "table" and tonumber(entry.leaves) or nil
	if not leaves or leaves <= time() or leaves - time() > SOON_OTHERS * DAY then return nil end
	return leaves
end

-- Your other characters' window (Wanderer's): this character's letters leaving soon, in its line.
local function LeavingLine(key)
	local settings = Settings()
	if not (settings and settings.enabled and settings.leaving) then return nil end
	local entry = Account().letters[key]
	local leaves = type(entry) == "table" and tonumber(entry.leaves)
	local now = time()
	if not (leaves and leaves > now and leaves - now <= SOON_OTHERS * DAY) then return nil end
	local count = tonumber(entry.count) or 1
	local words = (count == 1 and L.CHARACTER_LETTER_ONE or L.CHARACTER_LETTERS):format(U.Ago(leaves - now))
	local c = Skin.COLORS.warn
	-- (both ways of reading it: by name, and in order)
	return { text = words, r = c[1], g = c[2], b = c[3], words, c[1], c[2], c[3] }
end
ns.LeavingLine = LeavingLine -- (tests)

-- What a letter is ----------------------------------------------------------------------------------------
-- From the auction house: sold (its gold), won (your item), back to you (expired or canceled), outbid (your gold
-- back), or a sale still pending (nothing to take yet); the loot Forever kept for you (lost, by its sender);
-- else from a player; or to pay on delivery. Told by the game's invoice, else by the subject the game writes
-- for each.

local SUBJECTS = {
	{ "sold", "AUCTION_SOLD_MAIL_SUBJECT" }, { "won", "AUCTION_WON_MAIL_SUBJECT" },
	{ "back", "AUCTION_EXPIRED_MAIL_SUBJECT" }, { "back", "AUCTION_REMOVED_MAIL_SUBJECT" },
	{ "outbid", "AUCTION_OUTBID_MAIL_SUBJECT" },
}
local AUCTION = { sold = true, won = true, back = true, outbid = true, pending = true }
local patterns -- (the subjects as patterns, made once)
local function Patterns()
	if patterns then return patterns end
	patterns = {}
	for _, known in ipairs(SUBJECTS) do
		local pattern = U.FormatPattern(_G[known[2]])
		if pattern then patterns[#patterns + 1] = { known[1], pattern } end
	end
	return patterns
end

local function IsLost(sender)
	sender = Clean(sender)
	if type(sender) ~= "string" then return false end
	sender = sender:lower()
	for _, words in ipairs(LOST_SENDERS) do
		if sender:find(words, 1, true) then return true end
	end
	return false
end

local function Kind(index)
	local _, _, sender, subject, _, cod = Safe(GetInboxHeaderInfo, index)
	if (Clean(cod) or 0) > 0 then return "cod" end
	local invoice = Clean(Safe(rawget(_G, "GetInboxInvoiceInfo"), index))
	if invoice == "seller" then return "sold" end
	if invoice == "buyer" then return "won" end
	if invoice == "seller_temp_invoice" then return "pending" end
	subject = Clean(subject)
	if type(subject) == "string" then
		for _, known in ipairs(Patterns()) do
			if subject:match(known[2]) then return known[1] end
		end
	end
	if IsLost(sender) then return "lost" end
	return "player"
end
ns.LetterKind = Kind -- (tests)

-- Taking --------------------------------------------------------------------------------------------------

local card -- the card beside the mailbox (below)
-- "all", "gold", "auction" (the auction house's letters), "players", "lost" (Forever's kept loot), "letter"
-- (one letter, Shift+click), or false
local running = false
local taken = { items = 0, refused = 0, done = 0, total = 0 } -- and start: your gold when it began
local tries = {} -- TryKey -> times asked, during one run
local unique = {} -- "index:slot" -> true: an item the game would not give (unique, a limit), during one run
local only -- the letter a Shift+click takes: { index, sender, subject }
local goOn -- a take ended with letters kept on the server: { mode, shown } (the inbox as it ended), fresh once more came

local pending -- the attachment asked for last ({ index, slot, letters, waits }): counted once it is gone
local run = 0 -- one chain of steps at a time
local returnsReminded = false -- the reminder of a letter going back: once a session (done means seen)

local Letters, ShowProgress, Summarize, Said -- (below)

-- This letter still the one it was (its sender and subject at that place): the indexes move as letters go.
local function SameLetter(index, sender, subject)
	local _, _, nowSender, nowSubject = Safe(GetInboxHeaderInfo, index)
	return Clean(nowSender) == sender and Clean(nowSubject) == subject
end

-- The letters a take looks at: all of them, the auction house's, the players', the kept loot, one letter;
-- never one to pay on delivery.
local function Wanted(mode, kind, index)
	if kind == "cod" then return false end
	if mode == "auction" then return AUCTION[kind] or false end
	if mode == "players" then return kind == "player" end
	if mode == "lost" then return kind == "lost" end
	if mode == "letter" then return only ~= nil and index == only[1] and SameLetter(index, only[2], only[3]) end
	return true
end

-- How many things a take will ask for (each gold, each item; the gold only: the gold): its progress.
local function Pieces(mode)
	local count = 0
	for index = 1, Letters() do
		if Wanted(mode, Kind(index), index) then
			local _, _, _, _, money = Safe(GetInboxHeaderInfo, index)
			if (Clean(money) or 0) > 0 then count = count + 1 end
			if mode ~= "gold" then
				for slot = 1, MAX_ATTACHMENTS do
					if Clean(Safe(GetInboxItem, index, slot)) then count = count + 1 end
				end
			end
		end
	end
	return count
end

-- Room in your bags -------------------------------------------------------------------------------------------
-- Before each item: a free place beyond the one kept, or a stack of the same item with room enough; else the item
-- waits in its letter and the take goes on with the rest (the gold needs no room). The game saying the bags are
-- full: no new place asked for again in this take.

-- (the bags for anything: a quiver or a herb bag takes only its own kind; nil: this game does not say)
local function FreeSlots()
	local container = C_Container or {}
	if not container.GetContainerNumFreeSlots then return nil end
	local free = 0
	for _, bag in ipairs(U.BagIDs()) do
		local count, kind = Safe(container.GetContainerNumFreeSlots, bag)
		if (Clean(kind) or 0) == 0 then free = free + (tonumber(Clean(count)) or 0) end
	end
	return free
end
ns.FreeSlots = FreeSlots -- (tests)

-- How many more of this item your stacks can hold.
local function StackRoom(id)
	local most = tonumber(U.ItemMaxStack(id)) or 1
	local room = 0
	U.EachBagItem(function(_, _, info)
		if Clean(info.itemID) == id then
			room = room + math.max(0, most - (tonumber(Clean(info.stackCount)) or most))
		end
	end)
	return room
end

local function Fits(index, slot)
	if not taken.noRoom then
		local free = FreeSlots()
		if free == nil or free > KEEP_FREE then return true end
	end
	local _, id, _, count = Safe(GetInboxItem, index, slot)
	id = tonumber(Clean(id))
	return id ~= nil and StackRoom(id) >= (tonumber(Clean(count)) or 1)
end

-- The order letters are looked at: the last first (the indexes stay right); with the option, those leaving the
-- mailbox soonest first.
local function Order()
	local list = {}
	for index = Letters(), 1, -1 do list[#list + 1] = index end
	local settings = Settings()
	if type(settings) == "table" and settings.soonestFirst then
		local days = {}
		for _, index in ipairs(list) do
			days[index] = tonumber(Clean((select(7, Safe(GetInboxHeaderInfo, index))))) or math.huge
		end
		table.sort(list, function(a, b)
			if days[a] ~= days[b] then return days[a] < days[b] end
			return a > b
		end)
	end
	return list
end

-- The items a take leaves for lack of room, once it is over.
local function LeftForRoom(mode)
	if mode == "gold" then return 0 end
	local count = 0
	for index = 1, Letters() do
		if Wanted(mode, Kind(index), index) then
			for slot = 1, MAX_ATTACHMENTS do
				if Clean(Safe(GetInboxItem, index, slot)) and not unique[index .. ":" .. slot] and not Fits(index, slot) then
					count = count + 1
				end
			end
		end
	end
	return count
end

local function SetRunning(mode)
	running = mode
	ShowProgress()
end

-- The server brings the letters beyond 50 when it refreshes the inbox, once a minute at most (an earlier ask is
-- not answered): asked again now and then while the card waits for them, until they come, another take starts
-- or the mailbox closes. Reading only: nothing is taken before the click on "Go on".
local ASK_AGAIN, ASK_TIMES = 20, 4
local function AskServer(wait, times)
	if goOn ~= wait or wait.fresh or not (On() and MailFrame and MailFrame:IsShown()) then return end
	Safe(rawget(_G, "CheckInbox"))
	times = (times or 0) + 1
	if times < ASK_TIMES then C_Timer.After(ASK_AGAIN, function() AskServer(wait, times) end) end
end

-- The take over: stopped (a click, the mailbox closed) or done (natural: nothing more it can take).
local function Finish(natural)
	if not running then return end
	local mode = running
	SetRunning(false)
	-- The gold really received, whatever the game refused.
	local now = Clean(Safe(GetMoney))
	local money = (now and taken.start) and math.max(0, now - taken.start) or 0
	local parts = {}
	if money > 0 then parts[#parts + 1] = U.Coins(money) end
	if taken.items > 0 then parts[#parts + 1] = U.Plural(taken.items, L.MSG_ITEM_ONE, L.MSG_ITEMS) end
	local full = natural and LeftForRoom(mode) or 0
	local roomOut = full > 0 or (natural and taken.noRoom)
	-- One line in the chat, once; the rest on the card.
	if parts[2] then
		W.Print(L.MSG_MAIL_TAKEN:format(parts[1], parts[2]))
	elseif parts[1] then
		W.Print(L.MSG_MAIL_TAKEN_ONE:format(parts[1]))
	elseif roomOut then
		W.Print(L.MSG_MAIL_FULL)
	end
	local result = { parts[2] and L.RESULT_TAKEN_BOTH:format(parts[1], parts[2]) or parts[1] and L.RESULT_TAKEN:format(parts[1])
		or L.RESULT_NOTHING }
	if full > 0 then
		result[#result + 1] = Skin.Colorize(U.Plural(full, L.RESULT_FULL_ONE, L.RESULT_FULL_MANY), "bad")
	elseif roomOut then
		result[#result + 1] = Skin.Colorize(L.RESULT_FULL, "bad")
	end
	-- (items the game would not give, a unique one already carried: left in their letters)
	if taken.refused > 0 then result[#result + 1] = Skin.Colorize(U.Plural(taken.refused, L.RESULT_STAYED_ONE, L.RESULT_STAYED), "warn") end
	-- The inbox shows 50 letters at most: the others wait on the server. Once it brings them, the card offers to
	-- go on (a click); asked for now and again, the server answering when it allows.
	local shown, total = Letters()
	if total > shown then
		result[#result + 1] = U.Plural(total - shown, L.SUM_MORE_ONE, L.SUM_MORE)
		if natural and not roomOut and mode ~= "letter" then
			goOn = { mode = mode, shown = shown }
			AskServer(goOn)
		end
	end
	only = nil
	ns.lastResult = table.concat(result, U.SEPARATOR) -- (tests)
	Said(ns.lastResult)
end

-- The letters shown in the inbox, and how many there are in all (the server keeps those beyond 50).
function Letters()
	local shown, total = Safe(GetInboxNumItems)
	shown = Clean(shown) or 0
	return shown, math.max(shown, Clean(total) or 0)
end

-- What a try is counted under: its place and its letter (a letter gone, the next one takes its index: its own count).
local function TryKey(kind, index, value)
	local _, _, sender, subject = Safe(GetInboxHeaderInfo, index)
	return kind .. ":" .. index .. ":" .. value .. ":" .. tostring(Clean(sender)) .. ":" .. tostring(Clean(subject))
end

-- The next thing to take; an item without room in your bags waits.
local function NextTake()
	local function Again(kind, index, value)
		return (tries[TryKey(kind, index, value)] or 0) < MAX_TRIES
	end
	for _, index in ipairs(Order()) do
		if Wanted(running, Kind(index), index) then
			local _, _, _, _, money = Safe(GetInboxHeaderInfo, index)
			money = Clean(money) or 0
			if money > 0 and Again("money", index, 0) then return "money", index, 0 end
			-- The gold only: the items of the letter are left as they are.
			if running ~= "gold" then
				for slot = 1, MAX_ATTACHMENTS do
					if Clean(Safe(GetInboxItem, index, slot)) and Again("item", index, slot) and Fits(index, slot) then return "item", index, slot end
				end
			end
		end
	end
end

local function Step(mine)
	if not running or mine ~= run then return end
	-- The last attachment asked for: waited for a moment while the game answers; gone (or its letter gone with
	-- it, the last one taken): taken.
	if pending and pending.refused then
		pending = nil
	elseif pending then
		local there = Clean(Safe(GetInboxItem, pending[1], pending[2])) and Letters() >= pending.letters
		if there and pending.waits < MAX_TRIES then
			pending.waits = pending.waits + 1
			return C_Timer.After(STEP, function() Step(mine) end)
		end
		if not there then
			taken.items = taken.items + 1
			taken.done = taken.done + 1
		end
	end
	pending = nil
	ShowProgress()
	local kind, index, value = NextTake()
	if not kind then return Finish(true) end
	local key = TryKey(kind, index, value)
	tries[key] = (tries[key] or 0) + 1
	if kind == "money" then
		Safe(TakeInboxMoney, index)
		if tries[key] == 1 then taken.done = taken.done + 1 end
	else
		-- (known before asking: the game's refusal may come at once)
		pending = { index, value, key = key, letters = Letters(), waits = 0, at = GetTime() }
		Safe(TakeInboxItem, index, value)
	end
	C_Timer.After(STEP, function() Step(mine) end)
end

-- The game's refusals while taking: bags full, no new place asked for again (the rest goes on: gold, stacks);
-- an item it will not give (unique, a limit reached) is left in its letter and the rest goes on.
local REFUSALS = { "ERR_ITEM_MAX_COUNT", "ERR_ITEM_UNIQUE_EQUIPPABLE", "ERR_ITEM_MAX_LIMIT_CATEGORY_COUNT_EXCEEDED_IS",
	"ERR_ITEM_MAX_LIMIT_CATEGORY_EQUIPPED_EXCEEDED_IS", "ERR_ITEM_MAX_LIMIT_CATEGORY_SOCKETED_EXCEEDED_IS",
	"ERR_TOO_MANY_SPECIAL_BAGS", "ERR_ITEM_UNIQUE_EQUIPPABLE_SOCKETED", "ERR_MAIL_DATABASE_ERROR" }
local function IsRefusal(message)
	for _, name in ipairs(REFUSALS) do
		local text = _G[name]
		if type(text) == "string" and text ~= "" then
			if message == text then return true end
			local pattern = text:find("%", 1, true) and U.FormatPattern(text)
			if pattern and message:match(pattern) then return true end
		end
	end
	return false
end

function ns.Refused(message)
	if not (running and type(message) == "string") then return end
	if ERR_INV_FULL and message == ERR_INV_FULL then
		taken.noRoom = true
		-- (that item not asked again: only a stack could take it, and the game said no)
		if pending and not pending.refused then
			tries[pending.key] = MAX_TRIES
			pending.refused = true
		end
		return
	end
	-- (only right after the item was asked for: a refusal of something else is not this one's)
	if pending and not pending.refused and GetTime() - (pending.at or 0) <= REFUSAL_WAIT and IsRefusal(message) then
		-- (never asked again this run)
		tries[pending.key] = MAX_TRIES
		unique[pending[1] .. ":" .. pending[2]] = true
		pending.refused = true
		taken.refused = taken.refused + 1
		taken.done = taken.done + 1
	end
end

-- A take started (a click on one of the card's buttons); a click on it again stops it.
local function Start(mode)
	if running then return Finish() end
	goOn = nil
	taken.items, taken.refused, taken.done, taken.noRoom = 0, 0, 0, false
	wipe(unique)
	taken.total = Pieces(mode)
	taken.start = Clean(Safe(GetMoney))
	pending = nil
	wipe(tries)
	run = run + 1
	Said(nil)
	SetRunning(mode)
	Step(run)
end

ns.StartTaking = Start -- (tests)

-- Shortcuts on the inbox's letters -----------------------------------------------------------------------------
-- Shift+click takes the letter (its gold and items; never one to pay on delivery), where the game has no such
-- click of its own; Ctrl+click sends a player's letter back, after a question. Left to Postal or TSM when they
-- offer their own buttons.

-- (the game's own Shift+click, taking a letter, on the clients that have it)
local function GameTakesOnClick() return rawget(_G, "AutoLootMailItem") ~= nil or rawget(_G, "InboxFrame_OnModifiedClick") ~= nil end
ns.GameTakesOnClick = GameTakesOnClick -- (tests)

local function TakeLetter(index)
	local _, _, sender, subject, _, cod = Safe(GetInboxHeaderInfo, index)
	if (Clean(cod) or 0) > 0 then return end
	only = { index, Clean(sender), Clean(subject) }
	Start("letter")
end

-- A letter that can go back: a player's (not the game's, the auction house's, nor one already sent back).
local function CanReturn(index)
	if Clean(Safe(InboxItemCanDelete, index)) then return false end
	local kind = Kind(index)
	return kind == "player" or kind == "cod"
end

local function AskReturn(index)
	if not CanReturn(index) then return end
	local _, _, sender, subject = Safe(GetInboxHeaderInfo, index)
	sender, subject = Clean(sender), Clean(subject)
	local asked = run
	Skin.Ask(L.ASK_RETURN:format(sender or "?"), function()
		-- (still that letter, at that place, and no take started meanwhile: one moves the letters under the index)
		-- (nor Wanderer Mail switched off meanwhile)
		if not On() or running or run ~= asked or not SameLetter(index, sender, subject) then return end
		Safe(rawget(_G, "ReturnInboxItem"), index)
		local letter = _G.OpenMailFrame
		if letter and letter:IsShown() and InboxFrame and InboxFrame.openMailID == index then letter:Hide() end
	end)
end

local ButtonsOn -- (below)

-- A click on a letter of the inbox (after the game's own: the letter opens).
function ns.LetterClicked(index)
	index = tonumber(Clean(index))
	if not index or running or not ButtonsOn() then return end
	if Clean(Safe(IsShiftKeyDown)) then
		if not GameTakesOnClick() then TakeLetter(index) end
	elseif Clean(Safe(IsControlKeyDown)) then
		AskReturn(index)
	end
end

-- The game's own button, when this version of the game has one.
local function GameHasButton() return _G.OpenAllMail ~= nil end

-- Another addon's buttons at the mailbox (Postal, TSM's mail): ours step aside, never two of each.
function ns.OtherButtons() return W and W.Yields and W.Yields("mailButtons") or nil end

-- Our take buttons: asked for (an option, on) and no other addon's.
function ButtonsOn()
	local settings = Settings()
	return On() and settings.buttons ~= false and not ns.OtherButtons()
end

-- The card beside the mailbox ---------------------------------------------------------------------------------
-- A Wanderer card at the mailbox's right, as high as its content: what the inbox holds (the letters, the gold
-- inside, those to pay on delivery, your free slots, the first letter going back), then the auction house's
-- letters and the players', each with its own "Take these"; the gold alone; while taking, the button says how
-- far ("Stop 12 / 40") over a thin gold bar; once done, what was taken, on the card.

local CARD_WIDTH, LINE_HEIGHT, GAP = 240, 18, 8

-- A line of the card: a small icon (optional), its words on the left, its value on the right.
local function Line(parent, icon)
	local line = CreateFrame("Frame", nil, parent)
	line:SetHeight(LINE_HEIGHT)
	line:EnableMouse(false)
	local left = 0
	if icon then
		line.icon = line:CreateTexture(nil, "ARTWORK")
		line.icon:SetSize(14, 14)
		line.icon:SetPoint("LEFT")
		line.icon:SetTexture(icon)
		line.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
		left = 20
	end
	line.label = Skin.Text(line, "GameTooltipTextSmall", "soft")
	line.label:SetPoint("LEFT", line, "LEFT", left, 0)
	line.value = Skin.Text(line, "GameTooltipTextSmall", "text")
	line.value:SetPoint("RIGHT")
	return line
end

-- A block of letters: its title, its lines, its button.
local function Block(title, onTake, tip)
	local block = Skin.Panel(card)
	block.caps = Skin.Caps(block, title, "kicker")
	block.caps:SetPoint("TOPLEFT", block, "TOPLEFT", 12, -10)
	block.lines = {}
	block.take = Skin.Button(block, L.TAKE_THESE, onTake)
	block.take:SetHeight(26)
	block.take:SetPoint("BOTTOMLEFT", block, "BOTTOMLEFT", 12, 10)
	block.take:SetPoint("BOTTOMRIGHT", block, "BOTTOMRIGHT", -12, 10)
	Skin.Tooltip(block.take, tip, "ANCHOR_RIGHT")
	return block
end

-- A block's lines drawn ({ label, value }, those with something only), its height set; false when empty.
local function FillBlock(block, rows)
	for index, row in ipairs(rows) do
		local line = block.lines[index] or Line(block)
		block.lines[index] = line
		line:ClearAllPoints()
		line:SetPoint("TOPLEFT", block.caps, "BOTTOMLEFT", 0, -6 - (index - 1) * LINE_HEIGHT)
		line:SetPoint("RIGHT", block, "RIGHT", -12, 0)
		line.label:SetText(row[1])
		line.value:SetText(row[2])
		line:Show()
	end
	for index = #rows + 1, #block.lines do block.lines[index]:Hide() end
	block:SetHeight(10 + 12 + 6 + #rows * LINE_HEIGHT + 10 + 26 + 10)
	return rows[1] ~= nil
end

-- "12 · 31g 50s", "3 items".
local function CountGold(count, gold) return gold > 0 and (count .. U.SEPARATOR .. U.Coins(gold)) or tostring(count) end
local function Items(count) return U.Plural(count, L.MSG_ITEM_ONE, L.MSG_ITEMS) end

-- What the inbox holds, read now: { letters, gold, cod, soonest (days), kinds = { kind = { count, gold, items } } }.
local function Read()
	local count = Letters()
	local held = { letters = count, gold = 0, cod = 0, kinds = {} }
	for index = 1, count do
		local _, _, _, _, money, codAmount, daysLeft = Safe(GetInboxHeaderInfo, index)
		money = Clean(money) or 0
		held.gold = held.gold + money
		local kind = Kind(index)
		if kind == "cod" or (Clean(codAmount) or 0) > 0 then held.cod = held.cod + 1 end
		local items = 0
		for slot = 1, MAX_ATTACHMENTS do
			if Clean(Safe(GetInboxItem, index, slot)) then items = items + 1 end
		end
		local sum = held.kinds[kind] or { count = 0, gold = 0, items = 0 }
		sum.count, sum.gold, sum.items = sum.count + 1, sum.gold + money, sum.items + items
		held.kinds[kind] = sum
		daysLeft = tonumber(Clean(daysLeft))
		-- (a letter the game deletes when its time is up, an auction house's or an empty one, goes back to no one)
		if Clean(Safe(InboxItemCanDelete, index)) then daysLeft = nil end
		if daysLeft and (not held.soonest or daysLeft < held.soonest) then held.soonest = daysLeft end
	end
	return held
end

local function BuildCard()
	card = Skin.CreateWindow("WandererMailCard", "MEDIUM", MailFrame)
	if Skin.PadWindow then Skin.PadWindow(card, { side = true }) end
	card:SetWidth(CARD_WIDTH)
	card:EnableMouse(true)
	-- Beside the mailbox, or beside the letter you read (the game opens it at the mailbox's right): never over it.
	local function Place()
		local letter = _G.OpenMailFrame
		local beside = letter and letter:IsShown() and letter or MailFrame
		card:ClearAllPoints()
		card:SetPoint("TOPLEFT", beside, "TOPRIGHT", 6, 0)
	end
	Place()
	if _G.OpenMailFrame then
		_G.OpenMailFrame:HookScript("OnShow", Place)
		_G.OpenMailFrame:HookScript("OnHide", Place)
	end
	local _, _, margin = Skin.Header(card, "Wanderer", L.CARD_TITLE, { settings = "ext:mail" })
	card.margin = margin
	-- What the inbox holds.
	card.letters = Line(card, "Interface\\Icons\\INV_Letter_15")
	card.letters.label:SetText(L.LINE_LETTERS)
	card.gold = Line(card, "Interface\\Icons\\INV_Misc_Coin_01")
	card.gold.label:SetText(L.LINE_GOLD)
	card.cod = Line(card, "Interface\\Icons\\INV_Misc_Note_02")
	card.cod.label:SetText(L.LINE_COD)
	card.free = Line(card, "Interface\\Icons\\INV_Misc_Bag_08")
	card.free.label:SetText(L.LINE_FREE)
	card.returns = Skin.Text(card, "GameTooltipTextSmall", "warn")
	card.returns:SetJustifyH("LEFT")
	-- The auction house's letters, the players'.
	card.auction = Block(L.AH_BLOCK, function() Start("auction") end, L.TAKE_AUCTION_DESC)
	card.players = Block(L.PLAYERS_BLOCK, function() Start("players") end, function()
		-- (the shortcuts on the letters told here, Shift+click only where the game has none)
		local hints = { L.TAKE_PLAYERS_DESC }
		if not GameTakesOnClick() then hints[#hints + 1] = L.HINT_TAKE end
		hints[#hints + 1] = L.HINT_RETURN
		return table.concat(hints, "\n")
	end)
	-- The loot Forever kept for you, sent by mail.
	card.lost = Block(L.LOST_BLOCK, function() Start("lost") end, L.TAKE_LOST_DESC)
	-- The next letters the server brought, after a take that left some there.
	card.goOn = Skin.Button(card, L.GO_ON, function()
		local mode = goOn and goOn.mode
		if mode then Start(mode) end
	end, "main")
	Skin.Tooltip(card.goOn, L.GO_ON_DESC, "ANCHOR_RIGHT")
	-- The gold alone; everything where the game has no such button.
	card.goldButton = Skin.Button(card, L.MAIL_TAKE_GOLD, function() Start("gold") end, "main")
	Skin.Tooltip(card.goldButton, L.MAIL_TAKE_GOLD_DESC, "ANCHOR_RIGHT")
	card.allButton = Skin.Button(card, L.MAIL_TAKE_ALL, function() Start("all") end)
	Skin.Tooltip(card.allButton, L.MAIL_TAKE_ALL_DESC, "ANCHOR_RIGHT")
	-- How far, under the button taking; what was taken, once done.
	card.bar = Skin.ProgressLine(card, 3)
	card.result = Skin.Text(card, "GameTooltipTextSmall", "soft")
	card.result:SetJustifyH("LEFT")
	card:HookScript("OnShow", function(self) self:SetScale(Skin.Scale()) end)
end

-- Its pieces stacked from the top, those shown only; its height to fit them.
local function Stack(pieces)
	local m = card.margin
	local y = -(m + 40)
	for _, piece in ipairs(pieces) do
		local frame, gap = piece[1], piece[2] or 4
		frame:ClearAllPoints()
		frame:SetPoint("TOPLEFT", card, "TOPLEFT", m, y)
		frame:SetPoint("RIGHT", card, "RIGHT", -m, 0)
		frame:Show()
		-- (a text: its words' own height, laid out now)
		local height = frame.GetStringHeight and U.Measure(frame, "GetStringHeight", 14) or frame:GetHeight()
		y = y - height - gap
	end
	card:SetHeight(-y + m - 4)
	Skin.Get(card):Layout()
end

-- The buttons as the take goes: the one taking says "Stop 12 / 40", the others wait; the bar under it.
function ShowProgress()
	if not card then return end
	local buttons = { auction = card.auction.take, players = card.players.take, lost = card.lost.take, gold = card.goldButton,
		all = card.allButton }
	local words = { auction = L.TAKE_THESE, players = L.TAKE_THESE, lost = L.TAKE_THESE, gold = L.MAIL_TAKE_GOLD, all = L.MAIL_TAKE_ALL }
	for mode, button in pairs(buttons) do
		local mine = running == mode
		button:SetText(mine and L.MAIL_STOP_COUNT:format(math.min(taken.done, taken.total), taken.total) or words[mode])
		button:SetEnabled(not running or mine)
	end
	local under = running and buttons[running] or nil
	card.bar:SetShown(under ~= nil and under:IsShown())
	if under then
		card.bar:ClearAllPoints()
		card.bar:SetPoint("TOPLEFT", under, "BOTTOMLEFT", 0, -3)
		card.bar:SetPoint("TOPRIGHT", under, "BOTTOMRIGHT", 0, -3)
		card.bar:Set(taken.total > 0 and taken.done / taken.total or 0)
	end
end

-- What a take did, on the card for a while (nil: put away).
local saidAt
function Said(text)
	if not card then return end
	saidAt = text and GetTime() or nil
	card.result:SetText(text or "")
	if text then
		local at = saidAt
		C_Timer.After(10, function()
			if saidAt == at then Said(nil) end
		end)
	end
	Summarize()
end

function Summarize()
	if not card then return end
	local settings = Settings()
	local summary = On() and settings.summary
	local buttons = ButtonsOn()
	if not (MailFrame and MailFrame:IsShown() and (summary or buttons)) then
		if running and not buttons then Finish() end
		return card:Hide()
	end
	local held = Read()
	local pieces = {}
	if summary then
		local _, total = Letters()
		card.letters.value:SetText(total > held.letters and (held.letters .. "  " .. Skin.Colorize("+" .. (total - held.letters), "muted")) or tostring(held.letters))
		card.gold.value:SetText(held.gold > 0 and Skin.Colorize(U.Coins(held.gold), "good") or Skin.Colorize("0", "muted"))
		card.cod.value:SetText(Skin.Colorize(tostring(held.cod), "warn"))
		local free = FreeSlots() or 0
		card.free.value:SetText(Skin.Colorize(tostring(free), free == 0 and "bad" or "text"))
		-- (to pay on delivery: a line only when one waits, rare)
		card.cod:SetShown(held.cod > 0)
		pieces = { { card.letters }, { card.gold } }
		if held.cod > 0 then pieces[#pieces + 1] = { card.cod } end
		pieces[#pieces + 1] = { card.free, 6 }
		if held.soonest and held.soonest < SOON then
			card.returns:SetText(L.LINE_RETURNS:format(U.Ago(math.floor(held.soonest * 86400))))
			pieces[#pieces + 1] = { card.returns, 6 }
			-- (and in Wanderer's reminders, once)
			if not returnsReminded and not W.HasTodo("mail-returns") then
				returnsReminded = true
				W.AddTodo(L.TODO_RETURNS, { key = "mail-returns" })
			end
		else
			card.returns:Hide()
			-- (none going back within a day now: the reminder taken back, when Wanderer can)
			if W.HasTodo("mail-returns") then pcall(W.RemoveTodo, "mail-returns") end
			returnsReminded = false
		end
		pieces[#pieces][2] = GAP + 4
	else
		for _, line in ipairs({ card.letters, card.gold, card.cod, card.free, card.returns }) do line:Hide() end
	end
	-- The blocks, with their buttons (only where something waits in them, or while they take).
	local kinds = held.kinds
	local function Of(kind) return kinds[kind] or { count = 0, gold = 0, items = 0 } end
	local auctionRows = {}
	if Of("sold").count > 0 then auctionRows[#auctionRows + 1] = { L.AH_SOLD, CountGold(Of("sold").count, Of("sold").gold) } end
	if Of("back").items > 0 then auctionRows[#auctionRows + 1] = { L.AH_BACK, Items(Of("back").items) } end
	if Of("won").items > 0 then auctionRows[#auctionRows + 1] = { L.AH_WON, Items(Of("won").items) } end
	if Of("outbid").count > 0 then auctionRows[#auctionRows + 1] = { L.AH_OUTBID, CountGold(Of("outbid").count, Of("outbid").gold) } end
	-- ("3 letters · 2g · 4 items")
	local function KindRows(kind)
		local sum = Of(kind)
		if sum.count == 0 then return {} end
		local words = { U.Plural(sum.count, L.SUM_LETTER_ONE, L.SUM_LETTERS) }
		if sum.gold > 0 then words[#words + 1] = U.Coins(sum.gold) end
		if sum.items > 0 then words[#words + 1] = Items(sum.items) end
		return { { table.concat(words, U.SEPARATOR), "" } }
	end
	-- (the take buttons only on the inbox, not while you write a letter; a take under way keeps its button)
	local inbox = InboxFrame == nil or InboxFrame:IsVisible() or (running and true or false)
	buttons = buttons and inbox
	local auctionShown = buttons and (FillBlock(card.auction, auctionRows) or running == "auction")
	local lostShown = buttons and (FillBlock(card.lost, KindRows("lost")) or running == "lost")
	local playersShown = buttons and (FillBlock(card.players, KindRows("player")) or running == "players")
	card.auction:SetShown(auctionShown and true or false)
	card.lost:SetShown(lostShown and true or false)
	card.players:SetShown(playersShown and true or false)
	if auctionShown then pieces[#pieces + 1] = { card.auction, GAP } end
	if lostShown then pieces[#pieces + 1] = { card.lost, GAP } end
	if playersShown then pieces[#pieces + 1] = { card.players, GAP } end
	-- Going on past the 50 letters shown: offered once the server brought more, while some are left to take.
	-- (the fewest seen since it ended: the last letters taken leave a moment after)
	if goOn and not goOn.fresh then
		if held.letters > goOn.shown then goOn.fresh = true else goOn.shown = held.letters end
	end
	local offer = buttons and not running and goOn ~= nil and goOn.fresh and Pieces(goOn.mode) > 0
	card.goOn:SetShown(offer and true or false)
	if offer then pieces[#pieces + 1] = { card.goOn, 8 } end
	card.goldButton:SetShown(buttons)
	card.allButton:SetShown(buttons and not GameHasButton())
	if buttons then
		pieces[#pieces + 1] = { card.goldButton, 8 }
		if not GameHasButton() then pieces[#pieces + 1] = { card.allButton, 8 } end
	end
	card.result:SetShown((card.result:GetText() or "") ~= "")
	if card.result:IsShown() then pieces[#pieces + 1] = { card.result, 4 } end
	if not pieces[1] then return card:Hide() end
	Stack(pieces)
	card:Show()
	ShowProgress()
end

-- Who to write to ------------------------------------------------------------------------------------------

local chipRow

-- A player written to lately: remembered for this character (the last few).
local function Remember(name)
	name = Clean(name)
	if type(name) ~= "string" or name == "" then return end
	local recent = DB().recent
	for index = #recent, 1, -1 do
		if Fold(recent[index]) == Fold(name) then table.remove(recent, index) end
	end
	table.insert(recent, 1, name)
	while #recent > RECENT_KEPT do table.remove(recent) end
end

-- "Élise-Hyjal": "elise", the way names are compared (small letters, no accents: "elise" typed finds "Élise").
local function Short(name)
	name = type(name) == "string" and strtrim(name) or ""
	return Fold(name:match("^([^%-]+)") or name)
end

-- Your friends of the game: { { name, class } } (the class as the game words it: no colour).
local function Friends()
	local list = {}
	local friends = C_FriendList or {}
	for index = 1, Clean(Safe(friends.GetNumFriends)) or 0 do
		local info = Safe(friends.GetFriendInfoByIndex, index)
		local name = type(info) == "table" and Clean(info.name)
		if type(name) == "string" and name ~= "" then list[#list + 1] = { name = name, online = Clean(info.connected) and true or false } end
	end
	return list
end

-- Your guild's members, as the game last gave its roster: { { name, class, online } }.
local function Guild()
	local list = {}
	local getInfo = rawget(_G, "GetGuildRosterInfo")
	for index = 1, Clean(Safe(rawget(_G, "GetNumGuildMembers"))) or 0 do
		local name, _, _, _, _, _, _, _, online, _, class = Safe(getInfo, index)
		name = Clean(name)
		if type(name) == "string" and name ~= "" then
			list[#list + 1] = { name = name, class = Clean(class), online = Clean(online) and true or false }
		end
	end
	return list
end

-- Your other characters of this realm and side, the players written to lately, your friends, then your guild's
-- members online.
local function Recipients()
	local list, seen = {}, {}
	local realm = Clean(Safe(GetRealmName))
	local faction = Clean(Safe(UnitFactionGroup, "player"))
	local me = Short(Clean(Safe(UnitName, "player")))
	local function Add(entry)
		local short = Short(entry.name)
		if #list >= MAX_CHIPS or seen[short] or short == me or short == "" then return end
		seen[short] = true
		list[#list + 1] = entry
	end
	for _, who in ipairs(W.Characters(true)) do
		if who.realm == realm and (not faction or who.faction == faction) then
			Add({ name = who.name, tip = L.ALT_TIP:format(who.level or 0), class = who.class, mine = true })
		end
	end
	for _, name in ipairs(DB().recent) do
		Add({ name = name, label = name:match("^([^%-]+)") or name, tip = L.RECENT_TIP })
	end
	for _, friend in ipairs(Friends()) do
		Add({ name = friend.name, label = friend.name:match("^([^%-]+)"), tip = L.FRIEND_TIP })
	end
	for _, member in ipairs(Guild()) do
		if member.online then Add({ name = member.name, label = member.name:match("^([^%-]+)"), tip = L.GUILD_TIP, class = member.class }) end
	end
	return list
end
ns.Recipients = Recipients -- (tests)

-- The recipient guard -----------------------------------------------------------------------------------------
-- Inside the name's field, on its right: a quiet word when the letter carries gold or items to a name that is
-- none of yours, nor written to lately, a friend or of your guild (a typo, a name filled in by the game); or when
-- it asks one of your own characters to pay on delivery. Read only: the game's Send button stays the only one.

-- Every name you know: short name -> "mine", "recent", "friend" or "guild" (read again every few seconds at most:
-- a guild's roster is long).
local knownNames, knownAt
local function KnownNames()
	local now = GetTime()
	if knownNames and now - knownAt < 5 then return knownNames end
	local known = {}
	knownNames, knownAt = known, now
	for _, who in ipairs(W.Characters(true)) do
		if who.name then known[Short(who.name)] = "mine" end
	end
	known[Short(Clean(Safe(UnitName, "player")))] = "mine"
	for _, name in ipairs(DB().recent) do known[Short(name)] = known[Short(name)] or "recent" end
	for _, friend in ipairs(Friends()) do known[Short(friend.name)] = known[Short(friend.name)] or "friend" end
	for _, member in ipairs(Guild()) do known[Short(member.name)] = known[Short(member.name)] or "guild" end
	return known
end

-- What the letter you write carries: gold sent, an amount to pay on delivery, items.
local function Carried()
	local copper = tonumber(Clean(Safe(rawget(_G, "MoneyInputFrame_GetCopper"), _G.SendMailMoney))) or 0
	local codButton = _G.SendMailCODButton
	local cod = codButton and codButton.GetChecked and Clean(codButton:GetChecked()) and true or false
	local items = false
	for slot = 1, rawget(_G, "ATTACHMENTS_MAX_SEND") or MAX_SEND do
		if Clean(Safe(rawget(_G, "GetSendMailItem"), slot)) then
			items = true
			break
		end
	end
	return cod and 0 or copper, cod and copper or 0, items
end

-- The guard's word for the letter now, or nil.
function ns.GuardText()
	local settings = Settings()
	if not (On() and settings.guard ~= false) then return nil end
	local box = _G.SendMailNameEditBox
	local name = box and Short(Clean(box:GetText()))
	if not name or #name < 2 then return nil end
	local gold, cod, items = Carried()
	local known = KnownNames()[name]
	if cod > 0 and known == "mine" then return L.GUARD_COD_SELF end
	if (gold > 0 or items) and not known then return L.GUARD_UNKNOWN end
	return nil
end

local guard
local function ShowGuard()
	if not guard then return end
	local text = _G.SendMailFrame and _G.SendMailFrame:IsVisible() and ns.GuardText() or nil
	guard:SetText(text or "")
	guard:SetShown(text ~= nil)
end

local function Pick(name)
	local box = _G.SendMailNameEditBox
	if not box then return end
	box:SetText(name)
	local subject = _G.SendMailSubjectEditBox
	if subject and subject.SetFocus then Safe(subject.SetFocus, subject) end
end

local function ClassColor(class)
	local r, g, b = U.ClassColor(class)
	if r then return r, g, b end
	return 1, 0.82, 0
end

-- The list of who to write to, as Postal and ElvUI offer it: a small arrow at the end of the name's field opens a
-- clear list beside it (your characters in their class colour with their level, then the players written to
-- lately); a click writes the name, the field stays yours to type in.
local function OpenRecipients(owner)
	local rows = {}
	for _, who in ipairs(Recipients()) do
		local r, g, b = ClassColor(who.class)
		local text = who.class and (U.ColorCode(r, g, b) .. (who.label or who.name) .. "|r") or (who.label or who.name)
		rows[#rows + 1] = { text = text, hint = who.tip, glyph = who.mine and "chevron" or nil,
			onClick = function() Pick(who.name) end }
	end
	if not rows[1] then return end
	Skin.ActionCard(owner, { title = L.SEND_TO, rows = rows })
end
ns.OpenRecipients = OpenRecipients -- (tests)

local function LayoutChips()
	if not chipRow then return end
	local sending = _G.SendMailFrame and _G.SendMailFrame:IsVisible()
	local wanted = On() and Settings().recipients and sending and Recipients()[1] ~= nil
	chipRow:SetShown(wanted and true or false)
end

-- What becomes of each letter -----------------------------------------------------------------------------------
-- On each letter of the inbox, under the days the game shows: what happens once they are gone (back to its
-- sender, or destroyed), warm when it holds gold or items and leaves within a few days. Where the game shows no
-- days, the days too.

local marks = {} -- one small text per letter shown

-- A letter's words and colour: "back to its sender" or "destroyed" (with its days, when asked).
function ns.LetterFate(index, withDays)
	local _, _, _, _, money, _, daysLeft, hasItem = Safe(GetInboxHeaderInfo, index)
	daysLeft = tonumber(Clean(daysLeft))
	if not daysLeft then return nil end
	local words = Clean(Safe(InboxItemCanDelete, index)) and L.FATE_GONE or L.FATE_BACK
	if withDays then words = U.Ago(math.floor(daysLeft * DAY)) .. U.SEPARATOR .. words end
	local items = Clean(hasItem)
	local holds = (Clean(money) or 0) > 0 or (items ~= nil and items ~= false and items ~= 0)
	return words, (holds and daysLeft < SOON_OTHERS) and "warn" or "muted"
end

local function MarkLetters()
	local per = rawget(_G, "INBOXITEMS_TO_DISPLAY") or 7
	local page = InboxFrame and tonumber(InboxFrame.pageNum) or 1
	local count = Letters()
	for row = 1, per do
		local frame = _G["MailItem" .. row]
		if frame then
			local days = _G["MailItem" .. row .. "ExpireTime"]
			local mark = marks[row]
			if not mark then
				mark = Skin.Text(frame, "GameFontNormalSmall", "muted")
				mark:SetJustifyH("RIGHT")
				if days then mark:SetPoint("TOPRIGHT", days, "BOTTOMRIGHT", 0, -1) else mark:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4) end
				marks[row] = mark
			end
			local index = (page - 1) * per + row
			local words, role
			if On() and index <= count then words, role = ns.LetterFate(index, days == nil) end
			if words then
				mark:SetText(words)
				local c = Skin.COLORS[role] or Skin.COLORS.muted
				mark:SetTextColor(c[1], c[2], c[3])
			end
			mark:SetShown(words ~= nil)
		end
	end
end
ns.MarkLetters = MarkLetters -- (tests)

-- The window -----------------------------------------------------------------------------------------------

local built = false

local function Build()
	if built or not (MailFrame and InboxFrame) then return end
	built = true
	BuildCard()
	-- At the end of the name's field, when you write a letter: the list of who to write to.
	local box = _G.SendMailNameEditBox
	chipRow = CreateFrame("Button", "WandererMailRecipients", box or MailFrame)
	chipRow:SetSize(CHIP_HEIGHT, CHIP_HEIGHT)
	if box then chipRow:SetPoint("LEFT", box, "RIGHT", 2, 0) else chipRow:SetPoint("TOPLEFT", MailFrame, "TOPLEFT", 80, -40) end
	chipRow.glyph = Skin.Glyph(chipRow, "chevron", 10)
	chipRow.glyph:SetPoint("CENTER")
	if chipRow.glyph.SetRotation then chipRow.glyph:SetRotation(-math.pi / 2) end
	chipRow:SetScript("OnClick", function(self) OpenRecipients(self) end)
	Skin.Tooltip(chipRow, function() return L.SEND_TO_TIP end, "ANCHOR_TOP")
	chipRow:Hide()
	-- Inside the name's field, on its right: the guard's word.
	if box then
		guard = Skin.Text(box, "GameFontNormalSmall", "warn")
		guard:SetPoint("RIGHT", box, "RIGHT", -6, 0)
		guard:SetJustifyH("RIGHT")
		if guard.SetWordWrap then guard:SetWordWrap(false) end
		guard:Hide()
		box:HookScript("OnTextChanged", ShowGuard)
		-- (the gold and the items change without a word: looked at a few times a second while you write)
		local send, since = _G.SendMailFrame, 0
		if send then
			send:HookScript("OnUpdate", function(_, elapsed)
				since = since + (elapsed or 0)
				if since < 0.3 then return end
				since = 0
				ShowGuard()
			end)
		end
	end
	-- The inbox's letters: what becomes of each, and the shortcuts on them.
	if rawget(_G, "InboxFrame_Update") then hooksecurefunc("InboxFrame_Update", MarkLetters) end
	if rawget(_G, "InboxFrame_OnClick") then hooksecurefunc("InboxFrame_OnClick", function(_, index) ns.LetterClicked(index) end) end
	for _, frame in ipairs({ InboxFrame, _G.SendMailFrame }) do
		if frame then
			frame:HookScript("OnShow", function() ns.Refresh() end)
			frame:HookScript("OnHide", function() ns.Refresh() end)
		end
	end
end

function ns.Refresh()
	if not built then return end
	if running and not ButtonsOn() then Finish() end
	Summarize()
	LayoutChips()
	ShowGuard()
	if InboxFrame and InboxFrame:IsVisible() then MarkLetters() end
end
ns.Card = function() return card end -- (tests)

-- What each letter is, written down for this character (/wmail dump): its sender, subject and the game's flags,
-- to learn in game how Forever's own letters are told (the kept loot's sender, for one).
function ns.Dump()
	if not (MailFrame and MailFrame:IsShown()) then return W.Print(L.DUMP_CLOSED) end
	local letters = {}
	for index = 1, Letters() do
		local _, _, sender, subject, money, cod, daysLeft, hasItem, wasRead, wasReturned, textCreated, canReply, isGM =
			Safe(GetInboxHeaderInfo, index)
		local items = {}
		for slot = 1, MAX_ATTACHMENTS do
			local name, id, _, count = Safe(GetInboxItem, index, slot)
			name = Clean(name)
			if name then items[#items + 1] = ("%s x%s (%s)"):format(tostring(name), tostring(Clean(count) or 1), tostring(Clean(id))) end
		end
		letters[#letters + 1] = {
			sender = Clean(sender), subject = Clean(subject), money = Clean(money), cod = Clean(cod), days = Clean(daysLeft),
			hasItem = Clean(hasItem), read = Clean(wasRead), returned = Clean(wasReturned), textCreated = Clean(textCreated),
			canReply = Clean(canReply), gm = Clean(isGM), canDelete = Clean(Safe(InboxItemCanDelete, index)),
			invoice = Clean(Safe(rawget(_G, "GetInboxInvoiceInfo"), index)), kind = Kind(index), items = items,
		}
	end
	DB().dump = { at = time(), letters = letters }
	W.Print(L.DUMP_DONE:format(#letters))
end

-- Init -----------------------------------------------------------------------------------------------------

function ns.Init()
	if not (W and W.RegisterExtension) then return end
	-- (built on Wanderer's API 15: an older Wanderer is only asked to update, nothing of it is called)
	if (W.API or 1) < 15 then return W.Print(L.NEEDS_WANDERER) end
	W.RegisterExtension({
		key = "mail",
		addon = ADDON,
		slash = "/wmail",
		title = L.ADDON,
		news = L.NEWS_LINES,
		defaults = { enabled = true, buttons = true, summary = true, recipients = true, leaving = true, soonestFirst = false, guard = true },
		refresh = function() ns.Refresh() end,
		-- (the card first: what it says, then the buttons it holds)
		options = function(o)
			local enabled = o.Checkbox("mail", "enabled", L.ENABLE, L.ENABLE_DESC, ns.Refresh)
			local on = o.IsOn("mail", "enabled")
			o.Under(o.Checkbox("mail", "summary", L.SUMMARY, L.SUMMARY_DESC, ns.Refresh), enabled, on)
			local buttons = o.Under(o.Checkbox("mail", "buttons", L.BUTTONS, L.BUTTONS_DESC, ns.Refresh), enabled, on)
			o.Yield(buttons, "mailButtons")
			o.Under(o.Checkbox("mail", "soonestFirst", L.SOONEST, L.SOONEST_DESC), enabled, on)
			o.Under(o.Checkbox("mail", "recipients", L.RECIPIENTS, L.RECIPIENTS_DESC, ns.Refresh), enabled, on)
			o.Under(o.Checkbox("mail", "guard", L.GUARD, L.GUARD_DESC, ns.Refresh), enabled, on)
			o.Under(o.Checkbox("mail", "leaving", L.LEAVING, L.LEAVING_DESC), enabled, on)
		end,
	})
	-- Wanderer's characters' window (API 14): each character's letters leaving soon, in its line.
	W.CharacterLine(LeavingLine, "mail")
	-- A character let go there: its letters as last seen let go here too.
	W.OnCharacterForgotten(function(key) Account().letters[key] = nil end)
	SLASH_WANDERERMAIL1 = "/wmail"
	SlashCmdList.WANDERERMAIL = function(words)
		if type(words) == "string" and strtrim(words):lower() == "dump" then return ns.Dump() end
		W.Print(Clean(Safe(HasNewMail)) and L.SLASH_NEW or L.SLASH_NONE)
	end
	-- A recipient is remembered once the game has taken the letter (a name it refuses is not).
	local lastRecipient
	hooksecurefunc("SendMail", function(name) lastRecipient = Clean(name) end)
	-- (the bags, the inbox and the error lines heard only while the mailbox is open)
	local events = CreateFrame("Frame")
	local AT_MAILBOX = { "MAIL_INBOX_UPDATE", "BAG_UPDATE_DELAYED", "UI_ERROR_MESSAGE" }
	local function AtMailbox(on)
		for _, event in ipairs(AT_MAILBOX) do
			pcall(on and events.RegisterEvent or events.UnregisterEvent, events, event)
		end
	end
	for _, event in ipairs({ "MAIL_SHOW", "MAIL_CLOSED", "MAIL_SEND_SUCCESS" }) do
		pcall(events.RegisterEvent, events, event)
	end
	-- (the inbox and the bags speak many times at once: the card drawn again once, a moment after)
	local refreshSoon = U.Debounce(0.1, ns.Refresh)
	events:SetScript("OnEvent", function(_, event, _, message)
		if event == "MAIL_CLOSED" then
			AtMailbox(false)
			goOn = nil
			return Finish()
		end
		if event == "MAIL_SHOW" then
			AtMailbox(true)
			-- (the guild's roster asked for: the game gives none until something asks, and its members are known names)
			local guild = C_GuildInfo and C_GuildInfo.GuildRoster or rawget(_G, "GuildRoster")
			if On() and Clean(Safe(rawget(_G, "IsInGuild"))) and guild then pcall(guild) end
		end
		if event == "MAIL_SEND_SUCCESS" then
			-- (switched off: nobody remembered)
			if On() then Remember(lastRecipient) end
			lastRecipient = nil
		end
		if event == "UI_ERROR_MESSAGE" then
			if running then ns.Refused(Clean(message)) end
			return
		end
		if event == "MAIL_SHOW" then Build() end
		-- (what this character keeps in its mailbox, for the notice on the others)
		if event == "MAIL_INBOX_UPDATE" and On() and MailFrame and MailFrame:IsShown() then RecordLetters() end
		if event == "MAIL_INBOX_UPDATE" or event == "BAG_UPDATE_DELAYED" then return refreshSoon() end
		ns.Refresh()
	end)
	-- At login, a moment after arriving (once): the letters of the others leaving soon.
	local arrival = CreateFrame("Frame")
	arrival:RegisterEvent("PLAYER_ENTERING_WORLD")
	arrival:SetScript("OnEvent", function(self)
		self:UnregisterEvent("PLAYER_ENTERING_WORLD")
		C_Timer.After(8, ns.TellLettersLeaving)
	end)
end

if W and W.WhenLoaded then W.WhenLoaded(ADDON, ns.Init) elseif W and W.Print then W.Print(L.NEEDS_WANDERER) end
