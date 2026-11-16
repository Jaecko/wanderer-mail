local _, ns = ...
local L = ns.L

-- Wanderer's mailbox, the letter chosen, read in place: who wrote it and when it leaves, its subject, its words
-- (they scroll), the auction house's account laid out, what it holds as squares (a click takes one, Shift links
-- it, Ctrl tries it on), and what can be done with it: take it (to pay on delivery: asked first, the amount said),
-- answer it, send it back, delete it, report it (in the game's window, where its button is), keep a copy.
-- Nothing taken, paid, sent back or deleted without a click.

local W = Wanderer
local U = W and W.Util
local Skin = W and W.Skin
local Safe, Clean = U and U.Safe, U and U.Clean

-- (a modified click on an item, the game's way: Wanderer's from its API 22, else the agreed fallback)
local ItemClick = rawget(U, "ItemClick") or function(link)
	if link and IsModifiedClick() and HandleModifiedItemClick then
		HandleModifiedItemClick(link)
		return true
	end
end

local SQUARE, SQUARE_GAP, PER_ROW = 36, 6, 8
local HEAD = 78 -- the heading's height: who, when, the subject
local LINES = 6 -- the auction house's account, its lines at most
local LINE = 22 -- (a summary line and its gap)
local DAYS_KEPT, DAYS_KEPT_COD = 30, 3 -- how long a letter stays: how long ago it came is told from it

local pane
local chosen -- the letter read: { index, sender, subject, body, invoice, takeable }
local paying -- a letter paid on delivery: the rest taken once the game has said so ({ index, sender, subject, at })

local function Me() return Clean(Safe(UnitName, "player")) end

-- The letter chosen ----------------------------------------------------------------------------------------------

-- The auction house's account of a letter: { kind, item, who, bid, deposit, cut, count, eta } (nil: none).
local function Invoice(index)
	local kind, item, who, bid, _, deposit, cut, _, etaHour, etaMin, count = Safe(rawget(_G, "GetInboxInvoiceInfo"), index)
	kind = Clean(kind)
	if not kind then return nil end
	return { kind = kind, item = Clean(item), who = Clean(who), bid = tonumber(Clean(bid)) or 0, deposit = tonumber(Clean(deposit)) or 0,
		cut = tonumber(Clean(cut)) or 0, count = tonumber(Clean(count)), etaHour = tonumber(Clean(etaHour)), etaMin = tonumber(Clean(etaMin)) }
end

-- A letter read: its words asked for (the game marks it read then), kept while it is chosen.
function ns.ChooseLetter(index)
	local _, _, sender, subject = Safe(GetInboxHeaderInfo, index)
	local body, _, _, takeable, isInvoice = Safe(rawget(_G, "GetInboxText"), index)
	body = Clean(body)
	chosen = { index = index, sender = Clean(sender), subject = Clean(subject), takeable = Clean(takeable) and true or false,
		body = type(body) == "string" and body:gsub("%$[Bb]", "\n") or "" }
	if Clean(isInvoice) then chosen.invoice = Invoice(index) end
	if pane then
		pane.offset = 0
		pane.note:SetText("")
	end
	ns.DrawSoon()
end

-- The letter chosen still there: found again when the letters before it went (its sender and subject), else let go.
function ns.ResolveChosen()
	if not chosen then return end
	if ns.SameLetter(chosen.index, chosen.sender, chosen.subject) then return end
	for index = 1, (ns.Letters()) do
		if ns.SameLetter(index, chosen.sender, chosen.subject) then
			chosen.index = index
			return
		end
	end
	chosen = nil
end

function ns.ChosenIndex() return chosen and chosen.index or nil end

-- A new visit: nothing chosen yet (nothing read without a click); the visit over: nothing left waiting.
function ns.LetterOpened() chosen, paying = nil, nil end
function ns.LetterClosed() chosen, paying = nil, nil end

-- Actions ------------------------------------------------------------------------------------------------------------

local function Note(text, role)
	if not pane then return end
	pane.note:SetText(text and Skin.Colorize(text, role or "warn") or "")
	ns.DrawSoon()
end

-- To pay on delivery: asked first, the amount said; paid by taking its first item (the game's way), the rest then
-- taken once the game has said so. slot: the item clicked (else the first).
local function AskPay(letter, slot)
	if ns.Running() then return end
	if letter.cod > (Clean(Safe(GetMoney)) or 0) then return Note(L.COD_SHORT:format(U.Coins(letter.cod)), "bad") end
	local first = slot or (letter.items[1] and letter.items[1].slot)
	if not first then return end
	local index, sender, subject = letter.index, letter.sender, letter.subject
	Skin.Ask(L.ASK_PAY:format(U.Coins(letter.cod), sender or "?"), function()
		if not ns.WindowInUse() or ns.Running() or not ns.SameLetter(index, sender, subject) then return end
		paying = { index = index, sender = sender, subject = subject, at = GetTime() }
		Safe(TakeInboxItem, index, first)
	end)
end
ns.AskPay = AskPay -- (tests)

-- Deleted for good: only when the game allows it (never a player's letter: that one goes back); asked first while
-- it still holds gold or items.
local function Delete(letter)
	if ns.Running() or not letter.canDelete then return end
	local index, sender, subject = letter.index, letter.sender, letter.subject
	local function Now()
		-- (a take started meanwhile moves the letters under the index: nothing deleted then)
		if ns.Running() or not ns.SameLetter(index, sender, subject) or not Clean(Safe(InboxItemCanDelete, index)) then return end
		Safe(rawget(_G, "DeleteInboxItem"), index)
		chosen = nil
		ns.DrawSoon()
	end
	if letter.money > 0 or letter.items[1] then
		return Skin.Ask(L.ASK_DELETE_FULL:format(letter.title), function() if ns.WindowInUse() then Now() end end)
	end
	Now()
end

-- Reported where the game has its button: its own window, this letter's place said.
local function Report(letter)
	local per = rawget(_G, "INBOXITEMS_TO_DISPLAY") or 7
	W.Print(L.REPORT_HOW:format(letter.sender or "?", math.floor((letter.index - 1) / per) + 1))
	ns.UseGame()
end

local function Primary()
	local letter = pane and pane.letter
	if not letter then return end
	local running = ns.Running()
	if running == "letter" then return ns.TakeLetter(letter.index) end
	if running then return end
	if letter.cod > 0 then return AskPay(letter) end
	ns.TakeLetter(letter.index)
end

-- The pane --------------------------------------------------------------------------------------------------------

-- A square of what the letter holds: an item (or its gold), its tooltip; a click takes it.
local function Square(parent)
	local square = CreateFrame("Button", nil, parent)
	square:SetSize(SQUARE, SQUARE)
	square:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	square.icon = Skin.Icon(square, SQUARE)
	square.icon:SetAllPoints()
	-- (on the icon: the kit's icon is a frame of its own, above what the square draws)
	square.count = Skin.Text(square.icon, "GameTooltipTextSmall", "text")
	square.count:SetPoint("BOTTOMRIGHT", square, "BOTTOMRIGHT", -3, 3)
	local hover = square.icon:CreateTexture(nil, "OVERLAY")
	hover:SetAllPoints()
	hover:SetColorTexture(1, 1, 1, Skin.HOVER)
	hover:Hide()
	square.hover = hover
	square:SetScript("OnEnter", function(self)
		self.hover:Show()
		local letter = pane.letter
		if not letter then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		if self.money then
			GameTooltip:AddLine(L.TIP_GOLD:format(U.Coins(self.money)), Skin.RGB("good"))
		elseif self.item then
			-- (the game's own tooltip of a letter's item, its count with it; else its link)
			if GameTooltip.SetInboxItem then
				Safe(GameTooltip.SetInboxItem, GameTooltip, letter.index, self.item.slot)
			elseif self.item.link then
				GameTooltip:SetHyperlink(self.item.link)
			end
			if letter.cod > 0 then GameTooltip:AddLine(L.TIP_COD:format(U.Coins(letter.cod)), Skin.RGB("bad")) end
		end
		GameTooltip:AddLine(letter.cod > 0 and L.SQUARE_PAY or L.SQUARE_TAKE, Skin.RGB("muted"))
		GameTooltip:Show()
	end)
	square:SetScript("OnLeave", function(self)
		self.hover:Hide()
		GameTooltip:Hide()
	end)
	square:SetScript("OnClick", function(self)
		local letter = pane.letter
		if not letter then return end
		if self.item and ItemClick(self.item.link) then return end
		if ns.Running() then return end
		Skin.Play("click")
		if self.money then return Safe(TakeInboxMoney, letter.index) end
		if not self.item then return end
		if letter.cod > 0 then return AskPay(letter, self.item.slot) end
		Safe(TakeInboxItem, letter.index, self.item.slot)
	end)
	return square
end

function ns.BuildLetter(frame)
	pane = frame
	pane.squares = {}
	-- Nothing chosen: a calm line (and the way to write, when the box is empty).
	pane.invite = Skin.Text(pane, "GameTooltipText", "muted")
	pane.invite:SetPoint("CENTER", pane, "CENTER", 0, 20)
	pane.invite:SetJustifyH("CENTER")
	pane.write = Skin.SmallButton(pane, Skin.GlyphText("pencil", "label") .. " " .. L.WRITE_ONE, function() ns.ShowTab("write") end,
		L.WRITE_ONE_DESC, 24)
	pane.write:SetPoint("TOP", pane.invite, "BOTTOM", 0, -14)
	-- Who, when, what about.
	pane.icon = Skin.Icon(pane, 40)
	pane.icon:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, 0)
	pane.sender = Skin.Text(pane, "GameTooltipHeaderText", "gold")
	pane.sender:SetPoint("TOPLEFT", pane.icon, "TOPRIGHT", 10, -2)
	pane.sender:SetPoint("RIGHT", pane, "RIGHT", 0, 0)
	pane.sender:SetJustifyH("LEFT")
	pane.meta = Skin.Text(pane, "GameTooltipTextSmall", "muted")
	pane.meta:SetPoint("TOPLEFT", pane.sender, "BOTTOMLEFT", 0, -4)
	pane.meta:SetPoint("RIGHT", pane, "RIGHT", 0, 0)
	pane.meta:SetJustifyH("LEFT")
	pane.subject = Skin.Text(pane, "GameTooltipText", "text")
	pane.subject:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, -50)
	pane.subject:SetPoint("RIGHT", pane, "RIGHT", 0, 0)
	pane.subject:SetJustifyH("LEFT")
	if pane.subject.SetWordWrap then pane.subject:SetWordWrap(false) end
	pane.rule = Skin.Rule(pane)
	pane.rule:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, -(HEAD - 6))
	pane.rule:SetPoint("RIGHT", pane, "RIGHT", 0, 0)
	-- Its words, and the auction house's account above them: they scroll.
	pane.scroll = CreateFrame("ScrollFrame", nil, pane)
	pane.scroll:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, -HEAD)
	pane.scroll:EnableMouseWheel(true)
	pane.child = CreateFrame("Frame", nil, pane.scroll)
	pane.child:SetSize(10, 10)
	pane.scroll:SetScrollChild(pane.child)
	pane.lines = {}
	local anchor
	for index = 1, LINES do
		local line = Skin.SummaryLine(pane.child, anchor, "", false)
		if not anchor then
			line:ClearAllPoints()
			line:SetPoint("TOPLEFT", pane.child, "TOPLEFT", 0, 0)
			line:SetPoint("RIGHT", pane.child, "RIGHT", -8, 0)
		end
		line.label:SetTextColor(Skin.RGB("label"))
		pane.lines[index] = line
		anchor = line
	end
	pane.body = Skin.Text(pane.child, "GameTooltipText", "soft")
	pane.body:SetJustifyH("LEFT")
	if pane.body.SetSpacing then pane.body:SetSpacing(3) end
	pane.offset = 0
	local function Scroll(offset)
		local most = math.max(0, (pane.childHeight or 0) - (pane.viewHeight or 0))
		pane.offset = math.max(0, math.min(most, math.floor(offset + 0.5)))
		pane.scroll:SetVerticalScroll(pane.offset)
		pane.bar:Set(pane.childHeight or 0, pane.viewHeight or 0, pane.offset)
	end
	pane.bar = Skin.ScrollBar(pane, Scroll)
	pane.bar:SetPoint("TOPRIGHT", pane.scroll, "TOPRIGHT", 0, 0)
	pane.bar:SetPoint("BOTTOMRIGHT", pane.scroll, "BOTTOMRIGHT", 0, 0)
	pane.scroll:SetScript("OnMouseWheel", function(_, delta) Scroll(pane.offset - delta * 40) end)
	-- (a controller reaches it: its right stick scrolls it then)
	pane.scroll:EnableMouse(true)
	pane.scroll.padTip = true
	-- What it holds.
	pane.holds = Skin.Caps(pane, L.IN_LETTER, "kicker")
	for index = 1, 1 + (ATTACHMENTS_MAX_RECEIVE or 16) do pane.squares[index] = Square(pane) end
	-- What can be done: take it (gold, the main one), the others quiet beside it.
	pane.take = Skin.Button(pane, "", Primary, "main", 140)
	pane.take:SetPoint("BOTTOMLEFT", pane, "BOTTOMLEFT", 0, 0)
	Skin.Tooltip(pane.take, function()
		local letter = pane.letter
		if not letter then return nil end
		return letter.cod > 0 and L.PAY_DESC or L.TAKE_LETTER_DESC
	end, "ANCHOR_TOP")
	local function Act(fn) return function() if pane.letter then fn(pane.letter) end end end
	pane.actions = {
		{ key = "reply", button = Skin.SmallButton(pane, Skin.GlyphText("pencil", "label") .. " " .. L.REPLY,
			Act(function(letter) ns.Reply(letter.sender, letter.subject) end), L.REPLY_DESC, 26) },
		{ key = "back", button = Skin.SmallButton(pane, Skin.GlyphText("undo", "label") .. " " .. L.LETTER_RETURN,
			Act(function(letter) if not ns.Running() then ns.AskReturn(letter.index) end end), L.RETURN_DESC, 26) },
		{ key = "delete", button = Skin.SmallButton(pane, Skin.GlyphText("close", "label") .. " " .. L.DELETE, Act(Delete), L.DELETE_DESC, 26) },
		{ key = "copy", button = Skin.SmallButton(pane, Skin.GlyphText("plus", "label") .. " " .. L.COPY,
			Act(function(letter) Safe(rawget(_G, "TakeInboxTextItem"), letter.index) end), L.COPY_DESC, 26) },
		{ key = "report", button = Skin.SmallButton(pane, Skin.GlyphText("bell", "label") .. " " .. L.REPORT, Act(Report), L.REPORT_DESC, 26) },
	}
	pane.note = Skin.Text(pane, "GameTooltipTextSmall", "warn")
	pane.note:SetJustifyH("LEFT")
	function pane:Fit() ns.DrawLetter() end
end

-- What the auction house's account says, line by line: { label, value }.
local function InvoiceLines(invoice)
	local item = invoice.item or "?"
	if invoice.count and invoice.count > 1 then item = item .. " x" .. invoice.count end
	local who = invoice.who or L.INV_MANY
	if invoice.kind == "buyer" then
		return { { L.INV_BOUGHT, item }, { L.INV_SELLER, who }, { L.INV_PAID, U.Coins(invoice.bid) } }
	end
	local get = invoice.bid + invoice.deposit - invoice.cut
	if invoice.kind == "seller_temp_invoice" then
		local lines = { { L.INV_SOLD, item }, { L.INV_BUYER, who }, { L.INV_PENDING, Skin.Colorize(U.Coins(get), "good") } }
		if invoice.etaHour then
			local at = rawget(_G, "GameTime_GetFormattedTime")
			local time = at and Clean(Safe(at, invoice.etaHour, invoice.etaMin or 0, true)) or ("%02d:%02d"):format(invoice.etaHour, invoice.etaMin or 0)
			lines[#lines + 1] = { L.INV_ARRIVES, time }
		end
		return lines
	end
	return { { L.INV_SOLD, item }, { L.INV_BUYER, who }, { L.INV_PRICE, U.Coins(invoice.bid) },
		{ L.INV_DEPOSIT, U.Coins(invoice.deposit) }, { L.INV_CUT, Skin.Colorize(U.Coins(-invoice.cut), "bad") },
		{ L.INV_RECEIVE, Skin.Colorize(U.Coins(get), "good") } }
end

-- Who, when: how long ago it came (about: told from the days it has left), when it leaves and what becomes of it.
local function Meta(letter)
	local parts = {}
	if letter.days then
		local kept = letter.cod > 0 and DAYS_KEPT_COD or DAYS_KEPT
		local ago = kept - letter.days
		if ago >= 0 and letter.days <= kept then
			parts[#parts + 1] = ago < 1 / 24 and L.ARRIVED_NOW or L.ARRIVED:format(U.Ago(math.floor(ago * 86400)))
		end
		local fate = ns.LetterFate(letter.index)
		if fate then
			local words = L.LEAVES:format(U.Ago(math.floor(letter.days * 86400)), fate)
			parts[#parts + 1] = letter.days <= ns.SOON_DAYS and Skin.Colorize(words, "warn") or words
		end
	end
	if letter.returned then parts[#parts + 1] = L.RETURNED end
	return table.concat(parts, U.SEPARATOR)
end

function ns.DrawLetter()
	if not pane then return end
	local width, height = pane:GetWidth() or 0, pane:GetHeight() or 0
	local index = chosen and chosen.index
	local letter = index and ns.ReadLetter(index)
	pane.letter = letter
	local reading = letter ~= nil
	for _, piece in ipairs({ pane.icon, pane.sender, pane.meta, pane.subject, pane.rule, pane.scroll, pane.bar, pane.holds, pane.take, pane.note }) do
		piece:SetShown(reading)
	end
	for _, action in ipairs(pane.actions) do action.button:SetShown(false) end
	for _, square in ipairs(pane.squares) do square:Hide() end
	local empty = (ns.Letters()) == 0
	pane.invite:SetShown(not reading)
	pane.write:SetShown(not reading and empty)
	if not reading then
		pane.invite:SetText(empty and L.LETTER_NONE or L.LETTER_CHOOSE)
		pane.invite:SetWidth(math.max(100, width - 40))
		return
	end
	-- Who, when, what about.
	pane.icon:Set(letter.icon, letter.quality)
	pane.sender:SetText(letter.title)
	pane.meta:SetText(Meta(letter))
	pane.subject:SetText(letter.subject)
	-- What can be done, from the bottom: the main button and the quiet ones (on a row above it when they do not fit).
	local running = ns.Running()
	local holds = letter.money > 0 or letter.items[1] ~= nil
	pane.take:SetShown(holds or running == "letter")
	if running == "letter" then
		pane.take:SetText(L.MAIL_STOP_COUNT:format(ns.Progress()))
	elseif letter.cod > 0 then
		pane.take:SetText(L.PAY_AND_TAKE:format(U.Coins(letter.cod)))
	elseif letter.money > 0 and not letter.items[1] then
		pane.take:SetText(L.TAKE_MONEY:format(U.Coins(letter.money)))
	else
		pane.take:SetText(L.MAIL_TAKE_ALL)
	end
	pane.take:Fit()
	pane.take:SetEnabled(not running or running == "letter")
	local me = Me()
	local shown = {
		reply = letter.canReply and letter.sender ~= nil and letter.sender ~= me,
		back = ns.CanReturn(letter.index) and true or false,
		delete = letter.canDelete,
		copy = rawget(_G, "TakeInboxTextItem") ~= nil and chosen.takeable and not letter.textCreated,
		report = rawget(_G, "CanComplainInboxItem") ~= nil and Clean(Safe(rawget(_G, "CanComplainInboxItem"), letter.index)) and true or false,
	}
	local actionsWidth, visible = 0, {}
	for _, action in ipairs(pane.actions) do
		if shown[action.key] then
			visible[#visible + 1] = action.button
			action.button:SetEnabled(not running)
			actionsWidth = actionsWidth + action.button:GetWidth() + 6
		end
	end
	local takeWidth = pane.take:IsShown() and pane.take:GetWidth() + 12 or 0
	local raised = takeWidth + actionsWidth > width
	local y = raised and 42 or 5
	local previous
	for count = #visible, 1, -1 do
		local button = visible[count]
		button:ClearAllPoints()
		if previous then button:SetPoint("RIGHT", previous, "LEFT", -6, 0) else button:SetPoint("BOTTOMRIGHT", pane, "BOTTOMRIGHT", 0, y) end
		button:Show()
		previous = button
	end
	local bottom = (raised and 42 + 26 or 36) + 8
	-- A word on what was asked (not enough gold to pay): over the buttons.
	pane.note:ClearAllPoints()
	pane.note:SetPoint("BOTTOMLEFT", pane, "BOTTOMLEFT", 0, bottom)
	pane.note:SetPoint("RIGHT", pane, "RIGHT", 0, 0)
	if (pane.note:GetText() or "") ~= "" then bottom = bottom + 18 end
	-- What it holds: its gold, then its items, eight to a row.
	local squares = {}
	if letter.money > 0 then squares[#squares + 1] = { money = letter.money } end
	for _, item in ipairs(letter.items) do squares[#squares + 1] = { item = item } end
	pane.holds:SetShown(squares[1] ~= nil)
	if squares[1] then
		local rows = math.ceil(#squares / PER_ROW)
		for number, what in ipairs(squares) do
			local square = pane.squares[number]
			square.money, square.item = what.money, what.item
			if what.money then
				square.icon:Set("Interface\\Icons\\INV_Misc_Coin_01")
				square.count:SetText("")
			else
				square.icon:Set(what.item.icon, what.item.quality)
				square.count:SetText(what.item.count > 1 and tostring(what.item.count) or "")
			end
			local column, row = (number - 1) % PER_ROW, math.floor((number - 1) / PER_ROW)
			square:ClearAllPoints()
			square:SetPoint("BOTTOMLEFT", pane, "BOTTOMLEFT", column * (SQUARE + SQUARE_GAP), bottom + (rows - 1 - row) * (SQUARE + SQUARE_GAP))
			square:SetEnabled(not running)
			square:Show()
		end
		bottom = bottom + rows * (SQUARE + SQUARE_GAP)
		pane.holds:ClearAllPoints()
		pane.holds:SetPoint("BOTTOMLEFT", pane, "BOTTOMLEFT", 0, bottom + 2)
		bottom = bottom + 22
	end
	-- Its words, and the auction house's account above them, in what is left.
	local viewHeight = math.max(40, height - HEAD - bottom - 6)
	pane.scroll:SetSize(width - 14, viewHeight)
	pane.child:SetWidth(width - 14)
	local lines = chosen.invoice and InvoiceLines(chosen.invoice) or {}
	for number, line in ipairs(pane.lines) do
		local words = lines[number]
		line:SetShown(words ~= nil)
		if words then
			line.label:SetText(words[1])
			line.value:SetText(words[2])
		end
	end
	local top = #lines > 0 and (#lines * LINE + 12) or 0
	pane.body:ClearAllPoints()
	pane.body:SetPoint("TOPLEFT", pane.child, "TOPLEFT", 0, -top)
	pane.body:SetWidth(width - 24)
	pane.body:SetText(chosen.body ~= "" and chosen.body or (#lines == 0 and Skin.Colorize(L.NO_WORDS, "muted") or ""))
	local textHeight = U.Measure(pane.body, "GetStringHeight", 14)
	pane.childHeight = top + textHeight + 8
	pane.viewHeight = viewHeight
	pane.child:SetHeight(pane.childHeight)
	local most = math.max(0, pane.childHeight - viewHeight)
	pane.offset = math.min(pane.offset or 0, most)
	pane.scroll:SetVerticalScroll(pane.offset)
	pane.bar:Set(pane.childHeight, viewHeight, pane.offset)
end

-- The game's answers: a letter paid on delivery, the rest of it taken (a click already said yes to it).
function ns.OnLetterEvent(event)
	if event ~= "MAIL_INBOX_UPDATE" or not paying then return end
	local wait = paying
	if GetTime() - wait.at > 10 or not ns.SameLetter(wait.index, wait.sender, wait.subject) then
		paying = nil
		return
	end
	local _, _, _, _, money, cod = Safe(GetInboxHeaderInfo, wait.index)
	if (Clean(cod) or 0) > 0 then return end
	paying = nil
	-- (what is left in it, if anything)
	local rest = (Clean(money) or 0) > 0
	for slot = 1, ATTACHMENTS_MAX_RECEIVE or 16 do rest = rest or Clean(Safe(GetInboxItem, wait.index, slot)) ~= nil end
	if rest and not ns.Running() then ns.TakeLetter(wait.index) end
end
