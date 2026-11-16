local _, ns = ...
local L = ns.L

-- Wanderer's mailbox, the letters received: on the left, every letter in one list (no pages), grouped (the
-- auction house's, the players', the others: the game's own), each group with its count and its own "Take all";
-- on the right, the letter chosen, read in place (Letter.lua); at the foot, the shortcuts said, "Take the gold"
-- and "Take all" (how far while they take, what was taken after), and going on past the 50 letters shown.

local W = Wanderer
local U = W and W.Util
local Skin = W and W.Skin
local Safe, Clean = U and U.Safe, U and U.Clean

local MAX_ATTACHMENTS = ATTACHMENTS_MAX_RECEIVE or 16
local LIST_SHARE = 0.46 -- of the page's width, for the list
local GAP = 20 -- between the list and the letter
local FOOT = 44 -- the foot's height
local RIGHT_WIDTH = 168 -- a letter's right column: what it holds, its days
local ROWS_MADE = 30

local page, list

-- What the inbox holds ---------------------------------------------------------------------------------------

local COD_ICON = "Interface\\Icons\\INV_Misc_Note_02"
local COIN_ICON = "Interface\\Icons\\INV_Misc_Coin_01"
local LETTER_ICON = "Interface\\Icons\\INV_Letter_15"

-- One letter as the window reads it (its words, what it holds, what it is), without opening it.
function ns.ReadLetter(index)
	local packageIcon, stationery, sender, subject, money, cod, days, _, wasRead, wasReturned, textCreated, canReply, isGM =
		Safe(GetInboxHeaderInfo, index)
	local letter = {
		index = index, sender = Clean(sender), subject = Clean(subject) or "", money = Clean(money) or 0, cod = Clean(cod) or 0,
		days = tonumber(Clean(days)), read = Clean(wasRead) and true or false, returned = Clean(wasReturned) and true or false,
		textCreated = Clean(textCreated) and true or false, canReply = Clean(canReply) and true or false, gm = Clean(isGM) and true or false,
		items = {},
	}
	for slot = 1, MAX_ATTACHMENTS do
		local name, id, icon, count, quality = Safe(GetInboxItem, index, slot)
		name = Clean(name)
		if name then
			id = tonumber(Clean(id))
			letter.items[#letter.items + 1] = { slot = slot, name = name, id = id, icon = Clean(icon) or (id and U.ItemIcon(id)),
				count = tonumber(Clean(count)) or 1, quality = tonumber(Clean(quality)),
				link = Clean(Safe(rawget(_G, "GetInboxItemLink"), index, slot)) }
		end
	end
	letter.kind = ns.LetterKind(index)
	letter.group = ns.LetterGroup(index, letter.kind)
	letter.canDelete = Clean(Safe(InboxItemCanDelete, index)) and true or false
	-- Its icon: to pay on delivery (a receipt), its first item, its gold, a package, its paper.
	local first = letter.items[1]
	if letter.cod > 0 then
		letter.icon = COD_ICON
	elseif first then
		letter.icon, letter.quality = first.icon, first.quality
	elseif letter.money > 0 then
		letter.icon = COIN_ICON
	else
		letter.icon = Clean(packageIcon) or Clean(stationery) or LETTER_ICON
	end
	-- What it is called in the list: the sender, or for the auction house what happened ("Sold: Linen x20").
	letter.title = letter.sender or (UNKNOWN or "?")
	local words = ({ sold = L.ROW_SOLD, won = L.ROW_WON, back = L.ROW_BACK, outbid = L.ROW_OUTBID, pending = L.ROW_PENDING })[letter.kind]
	if words then
		local _, item, _, _, _, _, _, _, _, _, count = Safe(rawget(_G, "GetInboxInvoiceInfo"), index)
		item, count = Clean(item), tonumber(Clean(count))
		item = item or ns.SubjectItem(letter.subject) or (first and first.name)
		if item and count and count > 1 then item = item .. " x" .. count end
		if item then letter.title = words:format(item) end
	end
	return letter
end

-- Every letter shown in the inbox.
function ns.InboxLetters()
	local letters = {}
	for index = 1, (ns.Letters()) do letters[index] = ns.ReadLetter(index) end
	return letters
end

-- What the inbox holds, for the heading: gold, items, the amounts to pay on delivery, the next letter with
-- something inside about to leave ({ days, fate, who }, within a few days).
function ns.Holdings()
	local held = { gold = 0, items = 0, cod = 0 }
	for _, letter in ipairs(ns.InboxLetters()) do
		held.gold = held.gold + letter.money
		held.items = held.items + #letter.items
		held.cod = held.cod + letter.cod
		local holds = letter.money > 0 or letter.items[1] ~= nil
		if holds and letter.days and letter.days <= ns.SOON_DAYS and (not held.leaving or letter.days < held.leaving.days) then
			held.leaving = { days = letter.days, fate = (ns.LetterFate(letter.index)), who = letter.title }
		end
	end
	return held
end

-- The groups, in order: their title and the take that empties them.
local GROUPS = {
	{ key = "auction", mode = "auction", title = function() return L.GROUP_AUCTION end },
	{ key = "players", mode = "people", title = function() return L.GROUP_PLAYERS end },
	{ key = "others", mode = "others", title = function() return L.GROUP_OTHERS end },
}

-- The list's lines: each group's heading, then its letters (the game's order: the newest first).
local function Entries()
	local byGroup = { auction = {}, players = {}, others = {} }
	for _, letter in ipairs(ns.InboxLetters()) do
		local group = byGroup[letter.group] or byGroup.players
		group[#group + 1] = letter
	end
	local entries = {}
	for _, group in ipairs(GROUPS) do
		local letters = byGroup[group.key]
		if letters[1] then
			entries[#entries + 1] = { header = group.title() .. "  " .. #letters, group = group.key, mode = group.mode }
			for _, letter in ipairs(letters) do
				local c = Skin.COLORS[letter.read and "soft" or "text"]
				entries[#entries + 1] = { name = letter.title, icon = letter.icon, quality = letter.quality, color = c, letter = letter }
			end
		end
	end
	return entries
end
ns.InboxEntries = Entries -- (tests)

-- A letter's tooltip: who, what, what it holds, when it leaves.
local function LetterTip(letter)
	local lines = { letter.title }
	if letter.subject ~= "" then lines[#lines + 1] = { letter.subject, Skin.RGB("text") } end
	if letter.items[1] then
		lines[#lines + 1] = { L.TIP_ATTACHED, Skin.RGB("label") }
		for _, item in ipairs(letter.items) do
			local r, g, b = U.QualityColor(item.quality or 1)
			lines[#lines + 1] = { item.count > 1 and (item.name .. " x" .. item.count) or item.name, r, g, b }
		end
	end
	if letter.money > 0 then lines[#lines + 1] = { L.TIP_GOLD:format(U.Coins(letter.money)), Skin.RGB("good") } end
	if letter.cod > 0 then lines[#lines + 1] = { L.TIP_COD:format(U.Coins(letter.cod)), Skin.RGB("bad") } end
	local fate = ns.LetterFate(letter.index, true)
	if fate then lines[#lines + 1] = { fate, Skin.RGB("muted") } end
	return lines
end

-- What a letter holds, in its row's right column (to pay on delivery in the losing colour).
local function Holds(letter)
	if letter.cod > 0 then return Skin.Colorize(L.ROW_COD:format(U.Coins(letter.cod)), "bad") end
	local count = #letter.items
	local parts = {}
	if letter.money > 0 then parts[#parts + 1] = U.Coins(letter.money) end
	if count > 0 then parts[#parts + 1] = U.Plural(count, L.MSG_ITEM_ONE, L.MSG_ITEMS) end
	return table.concat(parts, U.SEPARATOR)
end

-- The list ------------------------------------------------------------------------------------------------------

local TAKE_WORDS = { all = L.MAIL_TAKE_ALL, gold = L.MAIL_TAKE_GOLD }

-- A take's button: "Stop 12 / 40" while it takes, its words otherwise; waiting while another one takes.
local function ShowTake(button, mode, words)
	local running = ns.Running()
	if running == mode then
		button:SetText(L.MAIL_STOP_COUNT:format(ns.Progress()))
	else
		button:SetText(words)
	end
	if button.Fit then button:Fit() end
	button:SetEnabled(not running or running == mode)
end

-- A row's own pieces beside the table's: the unread mark, the subject under the name, the right column, a
-- group's "Take all".
local function Dress(row)
	if row.subject then return end
	row.dot = Skin.Glyph(row, "dot", 10, "OVERLAY")
	row.dot:SetVertexColor(Skin.RGB("gold"))
	row.dot:SetPoint("TOPLEFT", row, "TOPLEFT", 2, -2)
	row.subject = Skin.Text(row, "GameTooltipTextSmall", "muted")
	row.subject:SetJustifyH("LEFT")
	if row.subject.SetWordWrap then row.subject:SetWordWrap(false) end
	row.holds = Skin.Text(row, "GameTooltipTextSmall", "soft")
	row.holds:SetJustifyH("RIGHT")
	row.holds:SetPoint("TOPRIGHT", row, "TOPRIGHT", -8, -4)
	row.holds:SetWidth(RIGHT_WIDTH)
	row.when = Skin.Text(row, "GameTooltipTextSmall", "muted")
	row.when:SetJustifyH("RIGHT")
	row.when:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -8, 4)
	row.when:SetWidth(RIGHT_WIDTH)
	for _, text in ipairs({ row.holds, row.when }) do
		if text.SetWordWrap then text:SetWordWrap(false) end
	end
	row.take = Skin.SmallButton(row, "", function(self)
		if self.mode then ns.StartTaking(self.mode) end
	end, function(self)
		return ({ auction = L.TAKE_AUCTION_DESC, people = L.TAKE_PEOPLE_DESC, others = L.TAKE_OTHERS_DESC })[self.mode]
	end, 20)
	row.take:SetPoint("RIGHT", row, "RIGHT", -8, 0)
	-- Hovered: the letter's tooltip (who, what it holds, when it leaves).
	row:SetScript("OnEnter", function(self)
		local entry = self.entry
		if not entry or entry.header then return end
		self.hover:SetShown(not self.chosen:IsShown())
		Skin.ShowTip(self, LetterTip(entry.letter), "ANCHOR_RIGHT")
	end)
end

local function DrawRow(row, entry)
	Dress(row)
	local letter = entry and entry.letter
	row.dot:SetShown(letter ~= nil and not letter.read)
	row.subject:SetShown(letter ~= nil)
	row.holds:SetShown(letter ~= nil)
	row.when:SetShown(letter ~= nil)
	-- A group's heading: its own "Take all", while something there can be taken (or while it takes).
	local mode = entry and entry.header and entry.mode
	row.take.mode = mode or nil
	local running = ns.Running()
	local takes = mode and (running == mode or ns.Pieces(mode) > 0)
	row.take:SetShown(takes and true or false)
	if takes then ShowTake(row.take, mode, L.TAKE_GROUP) end
	if not letter then return end
	-- (the name over the subject; both stop before the right column)
	row.name:ClearAllPoints()
	row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 8, 1)
	row.name:SetPoint("RIGHT", row, "RIGHT", -(RIGHT_WIDTH + 16), 0)
	row.subject:ClearAllPoints()
	row.subject:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 8, -1)
	row.subject:SetPoint("RIGHT", row, "RIGHT", -(RIGHT_WIDTH + 16), 0)
	-- (the auction house's: who sent it under what happened; else the subject)
	local under = letter.group == "auction" and (letter.sender or letter.subject) or letter.subject
	row.subject:SetText(under or "")
	row.holds:SetText(Holds(letter))
	if letter.days then
		local words = ns.LetterFate(letter.index, true) or ""
		local soon = letter.days <= ns.SOON_DAYS
		row.when:SetText(Skin.Colorize(words, soon and "warn" or "muted"))
	else
		row.when:SetText("")
	end
end

local entries = {}
local function DrawList()
	if not list then return end
	local offset = list:Clamp(#entries)
	local chosen = ns.ChosenIndex and ns.ChosenIndex()
	for index, row in ipairs(list.rows) do
		local entry = entries[offset + index]
		row:Fill(entry, entry ~= nil and entry.letter ~= nil and entry.letter.index == chosen)
		if entry and index <= list.count then DrawRow(row, entry) end
	end
	list.empty:SetShown(entries[1] == nil)
end

-- A click on a letter: Shift takes it, Ctrl sends a player's back (asked first), else it is read on the right.
local function Clicked(entry)
	local letter = entry and entry.letter
	if not letter then return end
	if Clean(Safe(IsShiftKeyDown)) then
		if not ns.Running() then ns.TakeLetter(letter.index) end
		return
	end
	if Clean(Safe(IsControlKeyDown)) then
		if not ns.Running() then ns.AskReturn(letter.index) end
		return
	end
	ns.ChooseLetter(letter.index)
end

-- The foot ------------------------------------------------------------------------------------------------------

local function DrawFoot()
	local foot = page.foot
	ShowTake(foot.all, "all", TAKE_WORDS.all)
	ShowTake(foot.gold, "gold", TAKE_WORDS.gold)
	local offer = ns.GoOnOffered()
	foot.goOn:SetShown(offer)
	-- (the words on the left, up to the buttons shown)
	foot.hint:ClearAllPoints()
	foot.hint:SetPoint("LEFT", foot, "LEFT", 0, -2)
	foot.hint:SetPoint("RIGHT", offer and foot.goOn or foot.gold, "LEFT", -12, 0)
	-- (what a take did, for a while; else the shortcuts on the letters)
	local said = ns.saidText
	if said then
		foot.hint:SetText(said)
		foot.hint:SetTextColor(Skin.RGB("soft"))
	else
		local pad = U.UsingPad and U.UsingPad()
		foot.hint:SetText(pad and L.HINT_INBOX_PAD or L.HINT_INBOX)
		foot.hint:SetTextColor(Skin.RGB("muted"))
	end
	-- How far, under the button taking.
	local running = ns.Running()
	local under = running == "all" and foot.all or running == "gold" and foot.gold or nil
	foot.bar:SetShown(under ~= nil)
	if under then
		local done, total = ns.Progress()
		foot.bar:ClearAllPoints()
		foot.bar:SetPoint("TOPLEFT", under, "BOTTOMLEFT", 0, -3)
		foot.bar:SetPoint("TOPRIGHT", under, "BOTTOMRIGHT", 0, -3)
		foot.bar:Set(total > 0 and done / total or 0)
	end
	-- (nothing to take: the buttons wait)
	if not running and ns.Pieces("all") == 0 then foot.all:SetEnabled(false) end
	if not running and ns.Pieces("gold") == 0 then foot.gold:SetEnabled(false) end
end

function ns.BuildInbox(frame)
	page = frame
	list = Skin.Table(page, {
		width = 420, rows = ROWS_MADE, rowHeight = Skin.ROW.normal, titles = false, columns = {},
		onClick = function(entry) Clicked(entry) end,
		onDraw = DrawList,
	})
	list:SetPoint("TOPLEFT", page, "TOPLEFT", 0, 0)
	list.empty:SetText(L.INBOX_EMPTY)
	for _, row in ipairs(list.rows) do Dress(row) end
	-- The letter read, on the right.
	page.letter = CreateFrame("Frame", nil, page)
	ns.BuildLetter(page.letter)
	-- The foot: the shortcuts said, the gold alone, everything.
	local foot = CreateFrame("Frame", nil, page)
	foot:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", 0, 0)
	foot:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
	foot:SetHeight(FOOT)
	page.foot = foot
	local rule = Skin.Rule(foot)
	rule:SetPoint("TOPLEFT")
	rule:SetPoint("TOPRIGHT")
	foot.all = Skin.Button(foot, L.MAIL_TAKE_ALL, function() ns.StartTaking("all") end, "main", 130)
	foot.all:SetPoint("BOTTOMRIGHT", foot, "BOTTOMRIGHT", 0, 4)
	Skin.Tooltip(foot.all, L.MAIL_TAKE_ALL_DESC, "ANCHOR_TOP")
	foot.gold = Skin.Button(foot, L.MAIL_TAKE_GOLD, function() ns.StartTaking("gold") end, nil, 120)
	foot.gold:SetHeight(36)
	foot.gold:SetPoint("RIGHT", foot.all, "LEFT", -8, 0)
	Skin.Tooltip(foot.gold, L.MAIL_TAKE_GOLD_DESC, "ANCHOR_TOP")
	foot.goOn = Skin.Button(foot, L.GO_ON, function() ns.GoOn() end, "main")
	foot.goOn:SetPoint("RIGHT", foot.gold, "LEFT", -8, 0)
	Skin.Tooltip(foot.goOn, L.GO_ON_DESC, "ANCHOR_TOP")
	foot.goOn:Hide()
	foot.bar = Skin.ProgressLine(foot, 3)
	foot.bar:Hide()
	foot.hint = Skin.Text(foot, "GameTooltipTextSmall", "muted")
	foot.hint:SetJustifyH("LEFT")
	-- Its size: the list as tall as the page above the foot, the letter beside it.
	function page:Fit()
		local window = ns.Window()
		local margin = window.margin or 20
		local width = (window:GetWidth() or 0) - margin * 2
		local height = (window:GetHeight() or 0) - margin * 2 - 112
		local listWidth = math.floor(width * LIST_SHARE)
		list:SetWidth(listWidth)
		list.empty:SetWidth(listWidth - 40)
		list:Fit(height - FOOT - 8)
		page.letter:ClearAllPoints()
		page.letter:SetPoint("TOPLEFT", page, "TOPLEFT", listWidth + GAP, 0)
		page.letter:SetSize(width - listWidth - GAP, height - FOOT - 8)
		if page.letter.Fit then page.letter:Fit() end
	end
end

function ns.DrawInbox()
	if not page then return end
	if ns.ResolveChosen then ns.ResolveChosen() end
	entries = Entries()
	DrawList()
	DrawFoot()
	if ns.DrawLetter then ns.DrawLetter() end
end
