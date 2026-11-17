local _, ns = ...
local L = ns.L

-- Wanderer's mailbox, the letter you write: to whom (the game's names completed as you type, your other
-- characters, the players you wrote to lately, your friends and your guild online one click away, a word when the
-- name looks wrong), its subject, its words, twelve squares for what it carries (an item dropped on them, or
-- right-clicked in your bags: the game's own letter stays open behind, out of sight, and holds them), gold sent or
-- asked on delivery, the postage; "Send" asks first when gold goes or is asked. Enter in the words never sends.

local W = Wanderer
local U = W and W.Util
local Skin = W and W.Skin
local Safe, Clean = U and U.Safe, U and U.Clean

local ItemClick = rawget(U, "ItemClick") or function(link)
	if link and IsModifiedClick() and HandleModifiedItemClick then
		HandleModifiedItemClick(link)
		return true
	end
end

local MAX_SEND = rawget(_G, "ATTACHMENTS_MAX_SEND") or 12
local MAX_COD = (rawget(_G, "MAX_COD_AMOUNT") or 10000) * 10000 -- copper: the most asked on delivery
local SQUARE, SQUARE_GAP, PER_ROW = 40, 6, 6
local FORM_SHARE = 0.56 -- of the page's width, for the name, subject and words
local GAP = 24
local FOOT = 44
local QUICK = 8 -- names offered under the field at most (the rest: the list of all)
local SEND_WAIT = 15 -- seconds: the game's answer to a letter sent, waited for

local page, form
local cod = false -- asked on delivery (else gold sent)
local sending -- the letter given to the game: { name, at }
local lastError -- the game's last refusal: { text, at }
local previousItem = "" -- the subject the first item wrote (the game's way: changed with it while you leave it)

local function Settings() return W.Settings("mail") end
local function Pad() return U.UsingPad and U.UsingPad() or false end
local function Money() return Clean(Safe(GetMoney)) or 0 end
local function Postage() return tonumber(Clean(Safe(rawget(_G, "GetSendMailPrice")))) or 0 end

-- What the letter carries now, as the game holds it: { slot, name, id, icon, count, quality, link }.
local function Attached()
	local items = {}
	for slot = 1, MAX_SEND do
		local name, id, icon, count, quality = Safe(rawget(_G, "GetSendMailItem"), slot)
		name = Clean(name)
		if name then
			id = tonumber(Clean(id))
			items[#items + 1] = { slot = slot, name = name, id = id, icon = Clean(icon) or (id and U.ItemIcon(id)),
				count = tonumber(Clean(count)) or 1, quality = tonumber(Clean(quality)), link = Clean(Safe(rawget(_G, "GetSendMailItemLink"), slot)) }
		end
	end
	return items
end

local function Say(text, role)
	if form then form.status:SetText(text and Skin.Colorize(text, role or "muted") or "") end
end

-- The game's way: the subject is the first item's name (and its count) while you leave it so.
local function AutoSubject()
	if not form then return end
	local first = Attached()[1]
	local now = form.subject:GetText() or ""
	local title = first and (first.count > 1 and (first.name .. " (" .. first.count .. ")") or first.name) or ""
	if now == "" or now == previousItem then form.subject:SetText(title) end
	previousItem = title
	-- (nothing carried: nothing to ask on delivery)
	if not first and cod then
		cod = false
		form.choices:Select("send")
	end
end

-- An amount within what may be: never more than you have (the postage too) for gold sent, nor beyond the game's
-- limit on delivery.
local function Within(copper)
	copper = math.max(0, math.floor(tonumber(copper) or 0))
	if cod then return math.min(copper, MAX_COD) end
	return math.min(copper, math.max(0, Money() - Postage()))
end

local clamping = false
local function Clamp()
	if clamping or not form then return end
	local copper = form.money:Get()
	local within = Within(copper)
	if within ~= copper then
		clamping = true
		form.money:Set(within)
		clamping = false
	end
end

-- Recipients ------------------------------------------------------------------------------------------------------

-- Who to write to, read again every few seconds at most (a guild's roster is long; the field is drawn at each key).
local recipients, recipientsAt, recipientsMore
local function Recipients()
	if not recipients or GetTime() - recipientsAt > 3 then
		recipients, recipientsMore = ns.Recipients()
		recipientsAt = GetTime()
	end
	return recipients, recipientsMore
end

-- A name written in the field (the subject next, as the game does; a keyboard's only).
local function Pick(name)
	form.name:SetText(name)
	if not Pad() then form.subject:SetFocus() end
	ns.DrawSend()
end

-- A name begun: the game's completion (its friends, guild, those met), else one of yours, finished in place, the
-- rest highlighted (typing on replaces it), as in the game's own field.
local function Suggest(text)
	local lower = text:lower()
	local function Fits(name) return type(name) == "string" and #name > #text and name:sub(1, #text):lower() == lower end
	local auto = rawget(_G, "C_AutoComplete")
	local complete = auto and auto.GetAutoCompleteResults
	local lists = rawget(_G, "AUTOCOMPLETE_LIST")
	local mail = type(lists) == "table" and lists.MAIL
	if complete and mail then
		local results = Clean(Safe(complete, text, 5, #text, true, mail.include, mail.exclude))
		if type(results) == "table" then
			for _, result in ipairs(results) do
				local name = type(result) == "table" and Clean(result.name) or Clean(result)
				if Fits(name) then return name end
			end
		end
	end
	for _, who in ipairs((Recipients())) do
		if Fits(who.name) then return who.name end
	end
	return nil
end

local function Complete(box, typed)
	if not typed then return end
	local text = box:GetText() or ""
	if text == "" then return end
	local cursor = box.GetCursorPosition and box:GetCursorPosition()
	if cursor and cursor ~= #text then return end
	local name = Suggest(text)
	if not name then return end
	box:SetText(name)
	if box.HighlightText then box:HighlightText(#text, #name) end
	if box.SetCursorPosition then box:SetCursorPosition(#name) end
end
ns.CompleteName = Complete -- (tests)

-- Sending ------------------------------------------------------------------------------------------------------------

-- The letter given to the game (asked first when gold goes or is asked: the click on yes).
local function Give(name, subject, body, copper)
	local setMoney, setCod = rawget(_G, "SetSendMailMoney"), rawget(_G, "SetSendMailCOD")
	Safe(setCod, 0)
	Safe(setMoney, 0)
	if copper > 0 and cod then
		Safe(setCod, copper)
	elseif copper > 0 then
		if Clean(Safe(setMoney, copper)) == false then return Say(L.SEND_NO_GOLD, "bad") end
	end
	sending = { name = name, at = GetTime() }
	lastError = nil
	Say(L.SENDING, "muted")
	-- (the game's own SendMail, looked up now: Wanderer Mail remembers the name once the game has taken it)
	Safe(_G.SendMail, name, subject, body)
	ns.DrawSend()
end

function ns.SendLetter()
	if not form or (sending and not sending.stale) then return end
	local name = strtrim(form.name:GetText() or "")
	local subject = strtrim(form.subject:GetText() or "")
	local body = form.body:GetText() or ""
	local items = Attached()
	local copper = Within(form.money:Get())
	if name == "" then return Say(L.SEND_NEED_NAME, "bad") end
	if subject == "" then return Say(L.SEND_NEED_SUBJECT, "bad") end
	if cod and not items[1] then return Say(L.COD_NEEDS_ITEM, "bad") end
	if cod and copper == 0 then return Say(L.COD_NEEDS_AMOUNT, "bad") end
	if Postage() > Money() then return Say(L.SEND_NO_POSTAGE, "bad") end
	if copper == 0 then return Give(name, subject, body, 0) end
	local question = cod and L.ASK_SEND_COD:format(name, U.Coins(copper)) or L.ASK_SEND_GOLD:format(U.Coins(copper), name)
	Skin.Ask(question, function()
		if not ns.WindowInUse() or (sending and not sending.stale) then return end
		Give(name, subject, body, copper)
	end)
end

-- The letter written emptied: its name, subject, words and gold (what it carried stays with the game).
local function Empty()
	form.name:SetText("")
	form.subject:SetText("")
	form.body:SetText("")
	form.money:Set(0)
	cod, previousItem = false, ""
	form.choices:Select("send")
end

-- "Clear": emptied, what it carried back into your bags.
local function Clear()
	if not form then return end
	Empty()
	for _, item in ipairs(Attached()) do Safe(rawget(_G, "ClickSendMailItemButton"), item.slot, true) end
	Say(nil)
	ns.DrawSend()
end

-- An answer to a letter: to its sender, "RE: its subject".
function ns.Reply(sender, subject)
	if not form or not sender then return end
	ns.ShowTab("write")
	local prefix = (rawget(_G, "MAIL_REPLY_PREFIX") or "RE:") .. " "
	subject = subject or ""
	if subject:sub(1, #prefix) ~= prefix then subject = prefix .. subject end
	form.name:SetText(sender)
	form.subject:SetText(subject)
	Say(nil)
	if not Pad() then form.body:SetFocus() end
	ns.DrawSend()
end

-- The letter written handed to the game's window, or taken back from it (toGame false), as you switch.
function ns.HandDraft(toGame)
	if not form then return end
	local boxes = { { form.name, _G.SendMailNameEditBox }, { form.subject, _G.SendMailSubjectEditBox }, { form.body, _G.SendMailBodyEditBox } }
	for _, pair in ipairs(boxes) do
		local mine, game = pair[1], pair[2]
		if game and game.SetText then
			if toGame and (mine:GetText() or "") ~= "" then
				game:SetText(mine:GetText())
			elseif not toGame and (game:GetText() or "") ~= "" then
				mine:SetText(game:GetText())
			end
		end
	end
end

-- The game's answers about the letter sent (true: nothing else to do for that event).
function ns.OnSendEvent(event, ...)
	if event == "UI_ERROR_MESSAGE" then
		if sending then lastError = { text = Clean((select(2, ...))), at = GetTime() } end
		return false
	end
	if event == "MAIL_SEND_INFO_UPDATE" then
		AutoSubject()
		return false
	end
	if event == "MAIL_SEND_SUCCESS" and sending then
		local name = sending.name
		sending = nil
		Empty()
		Say(L.SENT:format(name), "good")
		-- (the game's own letter, out of sight, takes the keys as it empties itself: given back here)
		local gameBox = _G.SendMailNameEditBox
		if gameBox and gameBox.HasFocus and gameBox:HasFocus() then gameBox:ClearFocus() end
		if ns.CurrentTab() == "write" and not Pad() then form.name:SetFocus() end
		return false
	end
	if event == "MAIL_FAILED" and sending then
		sending = nil
		local said = lastError and GetTime() - lastError.at < 3 and lastError.text
		Say(type(said) == "string" and said ~= "" and said or L.SEND_FAILED, "bad")
		return false
	end
	if event == "PLAYER_MONEY" then Clamp() end
	return false
end

-- The visit over: nothing waits (the game empties its own letter as its window closes).
function ns.SendClosed()
	sending, lastError = nil, nil
	if not form then return end
	Empty()
	Say(nil)
end

-- The page -----------------------------------------------------------------------------------------------------------

-- With a controller: a field is written in a question of the kit (a keyboard's words), its button over it.
local function PadType(input, prompt, letters, after)
	local button = CreateFrame("Button", nil, page)
	button:SetAllPoints(input)
	button:SetFrameLevel((input:GetFrameLevel() or 1) + 5)
	button:SetScript("OnClick", function()
		Skin.AskText(prompt, input:GetText() or "", function(text)
			input:SetText(text or "")
			if after then after() end
			ns.DrawSend()
		end, letters, true)
	end)
	Skin.Tooltip(button, prompt, "ANCHOR_TOP")
	button:Hide()
	return button
end

local function Square(slot)
	local square = CreateFrame("Button", nil, page)
	square.slot = slot
	square:SetSize(SQUARE, SQUARE)
	square:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	square:RegisterForDrag("LeftButton")
	square.icon = Skin.Icon(square, SQUARE)
	square.icon:SetAllPoints()
	-- (on the icon: the kit's icon is a frame of its own, above what the square draws)
	local game = Skin.GameWindows()
	-- (the game look: the count in the game's number font, its square's light under the mouse, as its item buttons)
	square.count = game and square.icon:CreateFontString(nil, "OVERLAY", "NumberFontNormal") or Skin.Text(square.icon, "GameTooltipTextSmall", "text")
	square.count:SetPoint("BOTTOMRIGHT", square, "BOTTOMRIGHT", -3, 3)
	square.plus = Skin.Glyph(square.icon, "plus", 12)
	square.plus:SetPoint("CENTER")
	square.plus:SetAlpha(0.5)
	local hover = square.icon:CreateTexture(nil, "OVERLAY")
	hover:SetAllPoints()
	if game then
		hover:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
		hover:SetBlendMode("ADD")
	else
		hover:SetColorTexture(1, 1, 1, Skin.HOVER)
	end
	hover:Hide()
	square.hover = hover
	square:SetScript("OnClick", function(self, mouse)
		local item = self.item
		if item and mouse ~= "RightButton" and ItemClick(item.link) then return end
		local click = rawget(_G, "ClickSendMailItemButton")
		-- (an item held: into this square; one here: back to the hand, or the bags with the right button or a
		-- controller)
		if Clean(Safe(rawget(_G, "CursorHasItem"))) then return Safe(click, self.slot) end
		if item then
			Skin.Play("click")
			Safe(click, self.slot, mouse == "RightButton" or Pad())
		end
	end)
	square:SetScript("OnReceiveDrag", function(self) Safe(rawget(_G, "ClickSendMailItemButton"), self.slot) end)
	square:SetScript("OnDragStart", function(self) if self.item then Safe(rawget(_G, "ClickSendMailItemButton"), self.slot) end end)
	square:SetScript("OnEnter", function(self)
		self.hover:Show()
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		if self.item then
			if GameTooltip.SetSendMailItem then
				Safe(GameTooltip.SetSendMailItem, GameTooltip, self.slot)
			elseif self.item.link then
				GameTooltip:SetHyperlink(self.item.link)
			end
			GameTooltip:AddLine(L.ATTACHED_TIP, Skin.RGB("muted"))
		else
			local r, g, b = Skin.RGB("text")
			GameTooltip:AddLine(Pad() and L.ATTACH_HINT_PAD or L.ATTACH_HINT, r, g, b, true)
		end
		GameTooltip:Show()
	end)
	square:SetScript("OnLeave", function(self)
		self.hover:Hide()
		GameTooltip:Hide()
	end)
	return square
end

-- One step of gold up or down (a controller's cross): 1 silver under 1 gold, 10 silver under 10 gold, 1 gold above.
local function Step(now, direction)
	local measure = direction > 0 and now or now - 1
	local size = measure < 10000 and 100 or measure < 100000 and 1000 or 10000
	return math.max(0, now + direction * size)
end

local function Caption(text) return Skin.Caps(page, text, "kicker") end

function ns.BuildSend(frame)
	page = frame
	form = {}
	-- To.
	form.toCaps = Caption(L.TO)
	form.name = Skin.CreateInput(page, nil, 77, {
		hint = L.TO_HINT,
		onChange = function(self, typed)
			Complete(self, typed)
			ns.DrawSend()
		end,
		onEnter = function() form.subject:SetFocus() end,
	})
	form.name:SetHeight(28)
	form.name:SetScript("OnTabPressed", function() form.subject:SetFocus() end)
	form.pick = Skin.GlyphButton(page, "down", 10, L.SEND_TO_TIP, function(self) ns.OpenRecipients(self, Pick) end)
	form.pick:SetPoint("RIGHT", form.name, "RIGHT", -4, 0)
	form.pick:SetFrameLevel((form.name:GetFrameLevel() or 1) + 2)
	form.guard = Skin.Text(page, "GameTooltipTextSmall", "warn")
	form.guard:SetPoint("RIGHT", form.pick, "LEFT", -4, 0)
	form.guard:SetJustifyH("RIGHT")
	if form.guard.SetWordWrap then form.guard:SetWordWrap(false) end
	form.quick = {}
	for index = 1, QUICK do
		form.quick[index] = Skin.SmallButton(page, "", function(self) if self.who then Pick(self.who.name) end end,
			function(self) return self.who and self.who.tip or nil end, 20)
	end
	form.more = Skin.SmallButton(page, "", function(self) ns.OpenRecipients(self, Pick) end, L.SEND_TO_TIP, 20)
	-- Subject.
	form.subjectCaps = Caption(L.SUBJECT)
	form.subject = Skin.CreateInput(page, nil, 64, {
		hint = L.SUBJECT_HINT,
		onChange = function() ns.DrawSend() end,
		onEnter = function() form.body:SetFocus() end,
	})
	form.subject:SetHeight(28)
	form.subject:SetScript("OnTabPressed", function() form.body:SetFocus() end)
	-- Its words: a sheet that scrolls; a click anywhere on it writes there (an item held: put in the letter).
	form.bodyCaps = Caption(L.MESSAGE)
	form.paper = Skin.Panel(page)
	form.paper:EnableMouse(true)
	-- (a mouse's: a controller writes through the question over it, PadType)
	form.paper.padIgnored = true
	form.paper:SetScript("OnMouseUp", function()
		if Clean(Safe(rawget(_G, "CursorHasItem"))) then return Safe(rawget(_G, "ClickSendMailItemButton")) end
		if not Pad() then form.body:SetFocus() end
	end)
	form.scroll = CreateFrame("ScrollFrame", nil, form.paper)
	form.scroll:SetPoint("TOPLEFT", form.paper, "TOPLEFT", 1, -1)
	form.scroll:SetPoint("BOTTOMRIGHT", form.paper, "BOTTOMRIGHT", -Skin.SCROLL_WIDTH - 2, 1)
	form.body = CreateFrame("EditBox", nil, form.scroll)
	form.body:SetMultiLine(true)
	form.body:SetAutoFocus(false)
	form.body:SetMaxLetters(500)
	form.body:SetFontObject(Skin.FontFor("ChatFontNormal"))
	form.body:SetTextInsets(8, 8, 8, 8)
	form.body:SetWidth(300)
	form.scroll:SetScrollChild(form.body)
	form.bodyHint = Skin.Text(form.paper, "GameTooltipTextSmall", "muted")
	form.bodyHint:SetPoint("TOPLEFT", form.paper, "TOPLEFT", 9, -9)
	form.bodyHint:SetText(L.MESSAGE_HINT)
	local function Scroll(offset)
		-- (the words' own height: the game's scroll range over what is shown)
		local shown = form.scroll:GetHeight() or 0
		local range = tonumber(Clean(Safe(form.scroll.GetVerticalScrollRange, form.scroll))) or 0
		local total = shown + range
		form.offset = math.max(0, math.min(math.max(0, total - shown), offset))
		form.scroll:SetVerticalScroll(form.offset)
		form.bar:Set(total, shown, form.offset)
	end
	form.offset = 0
	form.bar = Skin.ScrollBar(form.paper, Scroll)
	form.bar:SetPoint("TOPRIGHT", form.paper, "TOPRIGHT", -1, -2)
	form.bar:SetPoint("BOTTOMRIGHT", form.paper, "BOTTOMRIGHT", -1, 2)
	form.scroll:EnableMouseWheel(true)
	form.scroll:SetScript("OnMouseWheel", function(_, delta) Scroll(form.offset - delta * 30) end)
	-- (Enter writes a new line, never sends; Escape lets go; Tab goes back to the name)
	form.body:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	form.body:SetScript("OnTabPressed", function() form.name:SetFocus() end)
	form.body:SetScript("OnTextChanged", function(self)
		form.bodyHint:SetShown((self:GetText() or "") == "" and not self:HasFocus())
		Scroll(form.offset)
	end)
	form.body:SetScript("OnEditFocusGained", function() form.bodyHint:Hide() end)
	form.body:SetScript("OnEditFocusLost", function(self) form.bodyHint:SetShown((self:GetText() or "") == "") end)
	-- (the line written stays in sight: followed a moment later, once the sheet has grown with it)
	form.body:SetScript("OnCursorChanged", function(_, _, y, _, height)
		form.cursor = { -(tonumber(y) or 0), tonumber(height) or 14 }
	end)
	form.body:SetScript("OnUpdate", function()
		local cursor = form.cursor
		if not cursor then return end
		form.cursor = nil
		local y, height, shown = cursor[1], cursor[2], form.scroll:GetHeight() or 0
		if y < form.offset then Scroll(y) elseif y + height > form.offset + shown then Scroll(y + height - shown + 8) else Scroll(form.offset) end
	end)
	-- What it carries: twelve squares (an item dropped anywhere on them, or right-clicked in your bags).
	form.attachCaps = Caption(L.ATTACHMENTS)
	form.attachCount = Skin.Text(page, "GameTooltipTextSmall", "muted")
	form.drop = CreateFrame("Frame", nil, page)
	form.drop:EnableMouse(true)
	form.drop.padIgnored = true
	form.drop:SetScript("OnReceiveDrag", function() Safe(rawget(_G, "ClickSendMailItemButton")) end)
	form.drop:SetScript("OnMouseUp", function()
		if Clean(Safe(rawget(_G, "CursorHasItem"))) then Safe(rawget(_G, "ClickSendMailItemButton")) end
	end)
	form.squares = {}
	for slot = 1, MAX_SEND do form.squares[slot] = Square(slot) end
	form.attachHint = Skin.Text(page, "GameTooltipTextSmall", "muted")
	form.attachHint:SetJustifyH("LEFT")
	-- Gold sent, or asked on delivery (only with an item: said when chosen without one).
	form.moneyCaps = Caption(L.MONEY)
	form.choices = Skin.Choices(page, { { "send", L.SEND_GOLD }, { "cod", L.COD } }, function(key)
		if key == "cod" and not Attached()[1] then
			form.choices:Select("send")
			return Say(L.COD_NEEDS_ITEM, "warn")
		end
		cod = key == "cod"
		Clamp()
		Say(nil)
		ns.DrawSend()
	end, 28)
	form.choices:Select("send")
	form.money = Skin.Money(page, function()
		Clamp()
		if form.postage then ns.DrawSend() end
	end)
	form.moneyNote = Skin.Text(page, "GameTooltipTextSmall", "muted")
	form.moneyNote:SetJustifyH("LEFT")
	-- (a controller: the cross's left and right step the amount, its button asks for it)
	form.padMoney = CreateFrame("Button", nil, page)
	form.padMoney:SetAllPoints(form.money)
	form.padMoney:SetFrameLevel((form.money:GetFrameLevel() or 1) + 5)
	form.padMoney.padAdjust = function(_, delta)
		form.money:Set(Within(Step(form.money:Get(), delta > 0 and 1 or -1)))
		ns.DrawSend()
	end
	form.padMoney:SetScript("OnClick", function()
		Skin.AskText(L.GOLD_ASK, tostring(math.floor(form.money:Get() / 10000)), function(text)
			form.money:Set(Within((tonumber(text) or 0) * 10000))
			ns.DrawSend()
		end, 7, true)
	end)
	Skin.Tooltip(form.padMoney, L.GOLD_PAD_TIP, "ANCHOR_TOP")
	form.padMoney:Hide()
	form.padName = PadType(form.name, L.TO_HINT, 77)
	form.padSubject = PadType(form.subject, L.SUBJECT_HINT, 64)
	form.padBody = PadType(form.paper, L.MESSAGE_HINT, 500)
	-- The foot: the postage, a word on what happened, "Clear", "Send".
	local foot = CreateFrame("Frame", nil, page)
	foot:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", 0, 0)
	foot:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
	foot:SetHeight(FOOT)
	local rule = Skin.Rule(foot)
	rule:SetPoint("TOPLEFT")
	rule:SetPoint("TOPRIGHT")
	form.send = Skin.Button(foot, Skin.GlyphText("chevron", "onGold") .. " " .. L.SEND, function() ns.SendLetter() end, "main", 130)
	form.send:SetPoint("BOTTOMRIGHT", foot, "BOTTOMRIGHT", 0, 4)
	Skin.Tooltip(form.send, L.SEND_DESC, "ANCHOR_TOP")
	form.clear = Skin.Button(foot, L.CLEAR, function() Clear() end, nil, 100)
	form.clear:SetHeight(36)
	form.clear:SetPoint("RIGHT", form.send, "LEFT", -8, 0)
	Skin.Tooltip(form.clear, L.CLEAR_DESC, "ANCHOR_TOP")
	form.postage = Skin.Text(foot, "GameTooltipText", "soft")
	form.postage:SetPoint("BOTTOMLEFT", foot, "BOTTOMLEFT", 0, 14)
	form.status = Skin.Text(foot, "GameTooltipTextSmall", "muted")
	form.status:SetJustifyH("LEFT")
	form.status:SetPoint("LEFT", form.postage, "RIGHT", 18, 0)
	form.status:SetPoint("RIGHT", form.clear, "LEFT", -12, 0)
	if form.status.SetWordWrap then form.status:SetWordWrap(false) end
	function page:Fit() ns.DrawSend() end
end

-- Placed from the page's size (the window's, our own numbers).
local function Layout(width, height)
	local formWidth = math.floor(width * FORM_SHARE)
	local right = formWidth + GAP
	local rightWidth = width - right
	local y = 0
	local function Put(frame, x, top, w, h)
		frame:ClearAllPoints()
		frame:SetPoint("TOPLEFT", page, "TOPLEFT", x, -top)
		if w then frame:SetWidth(w) end
		if h then frame:SetHeight(h) end
	end
	Put(form.toCaps, 0, y)
	Put(form.name, 0, y + 16, formWidth)
	y = y + 16 + 28 + 6
	form.quickTop = y
	y = y + 20 + 12
	Put(form.subjectCaps, 0, y)
	Put(form.subject, 0, y + 16, formWidth)
	y = y + 16 + 28 + 12
	Put(form.bodyCaps, 0, y)
	Put(form.paper, 0, y + 16, formWidth, math.max(80, height - FOOT - 12 - (y + 16)))
	form.body:SetWidth(formWidth - Skin.SCROLL_WIDTH - 6)
	-- (as tall as the sheet at least: a click anywhere on it writes; longer words make it grow)
	form.body:SetHeight(math.max(60, (form.paper:GetHeight() or 80) - 4))
	-- The right column: what it carries, the gold.
	Put(form.attachCaps, right, 0)
	form.attachCount:ClearAllPoints()
	form.attachCount:SetPoint("LEFT", form.attachCaps, "RIGHT", 8, 0)
	local rows = math.ceil(MAX_SEND / PER_ROW)
	Put(form.drop, right, 16, PER_ROW * (SQUARE + SQUARE_GAP), rows * (SQUARE + SQUARE_GAP))
	for slot, square in ipairs(form.squares) do
		local column, row = (slot - 1) % PER_ROW, math.floor((slot - 1) / PER_ROW)
		Put(square, right + column * (SQUARE + SQUARE_GAP), 16 + row * (SQUARE + SQUARE_GAP))
	end
	local below = 16 + rows * (SQUARE + SQUARE_GAP)
	Put(form.attachHint, right, below + 2, rightWidth)
	below = below + 40
	Put(form.moneyCaps, right, below)
	Put(form.choices, right, below + 16)
	Put(form.money, right, below + 16 + 28 + 10)
	Put(form.moneyNote, right, below + 16 + 28 + 10 + 28 + 8, rightWidth)
end

-- The quick names under the field, those that fit; the rest behind "+N" (the list of all, its own "more" line).
local function DrawQuick(width)
	local list, more = Recipients()
	local x, shown = 0, 0
	for index, button in ipairs(form.quick) do
		local who = list[index]
		button.who = who
		if who then
			local r, g, b = ns.ClassColor(who.class)
			local label = who.label or who.name
			button:SetLabel(who.class and (U.ColorCode(r, g, b) .. label .. "|r") or label)
		end
		local fits = who ~= nil and x + button:GetWidth() <= width - 60
		button:ClearAllPoints()
		if fits then
			button:SetPoint("TOPLEFT", page, "TOPLEFT", x, -form.quickTop)
			x = x + button:GetWidth() + 6
			shown = shown + 1
		end
		button:SetShown(fits)
	end
	local rest = #list - shown + (more or 0)
	form.more:SetShown(rest > 0)
	if rest > 0 then
		form.more:SetLabel("+" .. rest)
		form.more:ClearAllPoints()
		form.more:SetPoint("TOPLEFT", page, "TOPLEFT", x, -form.quickTop)
	end
end

function ns.DrawSend()
	if not (page and form) then return end
	local window = ns.Window()
	if not window then return end
	local margin = window.margin or 20
	local width = (window:GetWidth() or 0) - margin * 2
	local height = (window:GetHeight() or 0) - margin * 2 - 112
	Layout(width, height)
	local settings = Settings()
	if settings and settings.recipients ~= false then DrawQuick(math.floor(width * FORM_SHARE)) else
		for _, button in ipairs(form.quick) do button:Hide() end
		form.more:Hide()
	end
	-- (a letter given to the game and no answer for long, the game's own question about the gold still open
	-- perhaps: the button back to you, its answer still heard)
	if sending and not sending.stale and GetTime() - sending.at > SEND_WAIT then
		sending.stale = true
		Say(nil)
	end
	-- What it carries.
	local items = Attached()
	local bySlot = {}
	for _, item in ipairs(items) do bySlot[item.slot] = item end
	for slot, square in ipairs(form.squares) do
		local item = bySlot[slot]
		square.item = item
		square.icon:Set(item and item.icon or nil, item and item.quality or nil)
		square.count:SetText(item and item.count > 1 and tostring(item.count) or "")
		square.plus:SetShown(item == nil)
	end
	form.attachCount:SetText(("%d / %d"):format(#items, MAX_SEND))
	local pad = Pad()
	form.attachHint:SetText(pad and L.ATTACH_HINT_PAD or L.ATTACH_HINT)
	-- The gold: what you have, or what is asked on delivery.
	local copper = form.money:Get()
	form.moneyNote:SetText(cod and L.COD_NOTE or L.YOU_HAVE:format(U.Coins(Money())))
	-- The word on the name: gold or items to a name you do not know, your own character asked to pay.
	local name = form.name:GetText() or ""
	local guard = ns.GuardFor(name, cod and 0 or copper, cod and copper or 0, items[1] ~= nil)
	form.guard:SetText(guard or "")
	-- The postage, in red beyond what you have.
	local postage = Postage()
	form.postage:SetText(L.POSTAGE:format(Skin.Colorize(U.Coins(postage), postage > Money() and "bad" or "text")))
	form.send:SetEnabled(not sending or sending.stale == true)
	-- With a controller: the fields asked for in a question, the amount stepped.
	for _, button in ipairs({ form.padName, form.padSubject, form.padBody, form.padMoney }) do button:SetShown(pad) end
end
