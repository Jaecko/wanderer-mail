local _, ns = ...
local L = ns.L

-- Wanderer's mailbox: one window in place of the game's while you stand at a mailbox. A heading that says what
-- waits (the letters, the gold, what is to pay on delivery, the next letter leaving, your free slots), two tabs
-- (the letters received, the letter you write), the game's own window kept open out of sight: a link brings it
-- back for this visit (every feature of the game's mailbox stays there), a link beside it comes back here.
-- Escape, or the cross, ends the visit as the game's window does. Postal or TradeSkillMaster's mailing loaded:
-- the game's window is the one used until you choose otherwise (the settings' row "Wanderer's mailbox").

local W = Wanderer
local U = W and W.Util
local Skin = W and W.Skin
local Safe, Clean = U and U.Safe, U and U.Clean

local WIDTH, HEIGHT = 960, 640 -- at first; then as you leave it
local MIN_WIDTH, MIN_HEIGHT, MAX_WIDTH, MAX_HEIGHT = 880, 580, 1500, 1100
ns.SOON_DAYS = 3 -- a letter leaving within this many days is said in the warning colour

local window, reopen, placeGame
local atMailbox = false -- a mailbox open
local mode = "wanderer" -- this visit: "wanderer" (the game's window out of sight) or "game"
local switching = false -- Wanderer's window hidden to show the game's (the mailbox stays open)
local current = "inbox" -- the tab shown: "inbox" or "write"
local pages = {}

local function Settings() return W.Settings("mail") end
local function On()
	local settings = Settings()
	return settings and settings.enabled and true or false
end

-- Wanderer's mailbox wanted. Postal or TradeSkillMaster's mailing loaded (they work in the game's window): off,
-- until you choose; your choice then kept whatever is loaded.
local function Yielded() return W.Yields and W.Yields("mailButtons") ~= nil or false end
function ns.WindowWanted()
	local settings = Settings()
	if type(settings) ~= "table" then return false end
	if not settings.windowChosen then settings.window = not Yielded() end
	return settings.window ~= false
end

-- The link back to Wanderer's mailbox, above the game's window: not when you turned Wanderer's mailbox off (the
-- game's window then, as before).
local function LinkWanted()
	local settings = Settings()
	return On() and not (settings.windowChosen and settings.window == false)
end

-- Wanderer's mailbox is the one used at this mailbox now.
function ns.WindowInUse() return atMailbox and mode == "wanderer" end
function ns.Window() return window end
function ns.CurrentTab() return current end

-- The letters shown, the letter read, the letter written: drawn again (once, a moment after many changes).
local function Draw()
	if not (window and window:IsShown()) then return end
	ns.DrawHeading()
	if current == "inbox" and ns.DrawInbox then ns.DrawInbox() end
	if current == "write" and ns.DrawSend then ns.DrawSend() end
end
ns.DrawWindow = Draw
local drawSoon -- (made at Init: Util.Debounce)
function ns.DrawSoon() if drawSoon then drawSoon() else Draw() end end
-- (a take moving on: its buttons and words at once)
ns.TakeChanged = Draw

-- The game's window --------------------------------------------------------------------------------------------

local function PlaceGameWindow() if placeGame then placeGame() end end

local function HookGameWindow()
	if placeGame or not MailFrame then return end
	placeGame = Skin.AsideGameWindow(MailFrame, function() return atMailbox and mode == "wanderer" end)
	-- (the game puts its window away when the mailbox is out of reach, you walking off: the visit ends with it)
	MailFrame:HookScript("OnHide", function() if ns.VisitEnded then ns.VisitEnded() end end)
end

-- The game's own tab behind ours: its letter to write shown while ours is (an item right-clicked in the bags
-- goes into the letter, the game's way), its inbox otherwise. Never with a controller: the game's tabs then move
-- its own controller's focus.
local function GameTab(tab)
	if not ns.WindowInUse() then return end
	if not (U.UsingPad and U.UsingPad()) and rawget(_G, "MailFrameTab_OnClick") then Safe(_G.MailFrameTab_OnClick, nil, tab) end
	Safe(rawget(_G, "SetSendMailShowing"), tab == 2)
	-- (the game's own fields, out of sight, never keep the keys: they would swallow what you type here)
	for _, name in ipairs({ "SendMailNameEditBox", "SendMailSubjectEditBox", "SendMailBodyEditBox" }) do
		local box = rawget(_G, name)
		if box and box.HasFocus and box:HasFocus() then box:ClearFocus() end
	end
end

-- The game's tab behind not the one ours shows (changed in the game's window, then back here): set again.
local function GameTabWrong(name)
	local send = rawget(_G, "SendMailFrame")
	return not (send and send.IsShown) or (send:IsShown() and true or false) ~= (name == "write")
end

-- The game's window, Wanderer's out of sight (the mailbox stays open). What you were writing goes with it.
function ns.UseGame()
	if ns.HandDraft then ns.HandDraft(true) end
	mode = "game"
	if window and window:IsShown() then
		switching = true
		window:Hide()
		switching = false
	end
	PlaceGameWindow()
	if reopen then reopen:SetShown(atMailbox and LinkWanted()) end
	ns.Refresh()
end

-- Wanderer's window, the game's out of sight (on a tab, else the last one). What was written in the game's
-- window comes back with it.
function ns.UseWanderer(tab)
	mode = "wanderer"
	if reopen then reopen:Hide() end
	PlaceGameWindow()
	if ns.HandDraft then ns.HandDraft(false) end
	ns.Refresh()
	ns.OpenWindow(tab)
end

-- The window ----------------------------------------------------------------------------------------------------

-- A small chip of the heading: its words, a tone, a sentence under the mouse (a controller reaches it too).
local function Chip(tip)
	local chip = Skin.Chip(window)
	chip:EnableMouse(true)
	chip.padTip = true
	Skin.Tooltip(chip, tip, "ANCHOR_BOTTOM")
	return chip
end

function ns.ShowTab(name)
	if not pages[name] then name = "inbox" end
	local changed = name ~= current
	current = name
	if not window then return end
	for key, page in pairs(pages) do page:SetShown(key == name) end
	window.tabs:Select(name)
	if changed or GameTabWrong(name) then GameTab(name == "write" and 2 or 1) end
	Draw()
end

local function Create()
	window = Skin.CreateWindow("WandererMailWindow", "MEDIUM")
	Skin.Dress(window, { "TOPLEFT", UIParent, "TOPLEFT", 24, -110 }, "mailPos")
	-- (the game's own sounds of the mailbox; quiet when the visit itself opens or ends: the game's window plays them)
	Skin.Sounds(window, "IG_CHARACTER_INFO_OPEN", "IG_CHARACTER_INFO_CLOSE")
	-- (opened silently at the mailbox, yet by the player: the controller comes to it, Wanderer's Pad.lua)
	window.padTakes = true
	local saved = Settings() and Settings().size
	window:SetSize(Skin.Within(saved and saved[1] or WIDTH, MIN_WIDTH, MAX_WIDTH), Skin.Within(saved and saved[2] or HEIGHT, MIN_HEIGHT, MAX_HEIGHT))
	local _, title, margin = Skin.Header(window, L.KICKER, "", { margin = 10, settings = "ext:mail" }, "GameFontNormalLarge")
	window.title, window.margin = title, margin
	-- The game's own window, and your money, on the right (the cog and the cross after them).
	window.game = Skin.SmallButton(window, Skin.GlyphText("move", "label") .. " " .. L.GAME_WINDOW, function() ns.UseGame() end,
		L.GAME_WINDOW_DESC)
	-- (the game look: the title in the game's bar; the button level with the cog, the chips on a line of their own
	-- under it, the tabs under them: all higher by the title's room)
	local gameLook = Skin.GameWindows and Skin.GameWindows()
	window.gameLook = gameLook
	if gameLook and window.cog then window.game:SetPoint("RIGHT", window.cog, "LEFT", -6, 0)
	else window.game:SetPoint("TOPRIGHT", window, "TOPRIGHT", -(margin + 54), -margin + 2) end
	window.money = Skin.Text(window, "GameTooltipText", "soft")
	window.money:SetPoint("RIGHT", window.game, "LEFT", -18, 0)
	-- What waits, in a row of chips under the title.
	window.chips = {
		gold = Chip(L.CHIP_GOLD_TIP), items = Chip(L.CHIP_ITEMS_TIP), cod = Chip(L.CHIP_COD_TIP),
		leaving = Chip(function() return window.chips.leaving.tip end), free = Chip(L.CHIP_FREE_TIP),
	}
	-- The tabs, over a thin rule.
	local rule = Skin.Rule(window)
	rule:SetPoint("TOPLEFT", window, "TOPLEFT", margin, -(margin + (gameLook and 67 or 100)))
	rule:SetPoint("RIGHT", window, "RIGHT", -margin, 0)
	window.tabs = Skin.Tabs(window, { { "inbox", L.TAB_RECEIVED }, { "write", L.TAB_WRITE } }, function(name) ns.ShowTab(name) end)
	window.tabs:SetPoint("BOTTOMLEFT", rule, "TOPLEFT", 0, 0)
	for _, name in ipairs({ "inbox", "write" }) do
		local page = CreateFrame("Frame", nil, window)
		page:SetPoint("TOPLEFT", rule, "BOTTOMLEFT", 0, -12)
		page:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -margin, margin)
		page:Hide()
		pages[name] = page
	end
	ns.BuildInbox(pages.inbox)
	ns.BuildSend(pages.write)
	-- Its corner: dragged, the window grows or shrinks, its pages with it; its size kept.
	local function Fit()
		for _, page in pairs(pages) do
			if page.Fit then page:Fit() end
		end
	end
	Skin.Resizable(window, {
		minWidth = MIN_WIDTH, minHeight = MIN_HEIGHT, maxWidth = MAX_WIDTH, maxHeight = MAX_HEIGHT,
		onResized = function(width, height)
			W.ChangeEverywhere(function() if Settings() then Settings().size = { width, height } end end)
		end,
	})
	window:HookScript("OnSizeChanged", function()
		local skin = Skin.Get(window)
		if skin then skin:Layout() end
		Fit()
		Draw()
	end)
	window:HookScript("OnShow", function(self)
		Fit()
		self:SetScale(Skin.FitScale(self))
		ns.ShowTab(current)
	end)
	-- Closed by hand (its cross, Escape): the visit ends with it, as the game's window does (not when the whole
	-- interface is hidden, Alt+Z: it is still shown then).
	window:HookScript("OnHide", function(self)
		if switching or self:IsShown() or not atMailbox or mode ~= "wanderer" then return end
		Skin.CancelAsk()
		Safe(rawget(_G, "CloseMail"))
	end)
	Fit()
	Skin.Get(window):Layout()
end

function ns.OpenWindow(tab)
	if tab then current = tab end
	if not window then Create() end
	if window:IsShown() then ns.ShowTab(current) else window:Show() end
end

-- The heading: what waits, said in the title and its chips; your money.
function ns.DrawHeading()
	if not window then return end
	local held = ns.Holdings()
	local _, total = ns.Letters()
	if total == 0 then
		window.title:SetText(L.TITLE_EMPTY)
	else
		window.title:SetText(U.Plural(total, L.TITLE_ONE, L.TITLE_MANY))
	end
	window.money:SetText(U.Coins(Clean(Safe(GetMoney)) or 0))
	local chips = window.chips
	chips.gold:Set(held.gold > 0 and L.CHIP_GOLD:format(U.Coins(held.gold)) or nil, "gold")
	chips.items:Set(held.items > 0 and U.Plural(held.items, L.MSG_ITEM_ONE, L.MSG_ITEMS) or nil, "grey")
	chips.cod:Set(held.cod > 0 and L.CHIP_COD:format(U.Coins(held.cod)) or nil, "red")
	local leaving = held.leaving
	if leaving then
		chips.leaving:Set(L.CHIP_LEAVING:format(U.Ago(math.floor(leaving.days * 86400)), leaving.fate), "gold")
		-- (the warning colour: a letter about to go)
		chips.leaving.text:SetTextColor(Skin.RGB("warn"))
		chips.leaving.ground:SetColorTexture(Skin.RGB("warn", 0.14))
		chips.leaving.tip = L.CHIP_LEAVING_TIP:format(leaving.who or "?")
	else
		chips.leaving:Set(nil)
	end
	local free = ns.FreeSlots()
	chips.free:Set(free and U.Plural(free, L.CHIP_FREE_ONE, L.CHIP_FREE_MANY) or nil, free == 0 and "red" or "grey")
	-- (side by side, those shown)
	local previous
	for _, key in ipairs({ "gold", "items", "cod", "leaving", "free" }) do
		local chip = chips[key]
		chip:ClearAllPoints()
		if chip:IsShown() then
			if previous then chip:SetPoint("LEFT", previous, "RIGHT", 6, 0)
			-- (the game look: under the line of the cog and the buttons, 22 high from 3 under the top)
			elseif window.gameLook then chip:SetPoint("TOPLEFT", window, "TOPLEFT", window.margin, -31)
			else chip:SetPoint("TOPLEFT", window.title, "BOTTOMLEFT", 0, -10) end
			previous = chip
		end
	end
	window.tabs:SetBadge("inbox", total > 0 and total or nil, "gold")
end

-- Init ----------------------------------------------------------------------------------------------------------

-- The link above the game's window, back to Wanderer's.
local function Reopen()
	if reopen or not MailFrame then return end
	reopen = Skin.SmallButton(UIParent, Skin.GlyphText("chevron", "label") .. " " .. L.WINDOW_LINK, function() ns.UseWanderer() end,
		L.WINDOW_LINK_DESC)
	reopen:SetFrameStrata("HIGH")
	reopen:SetPoint("BOTTOMRIGHT", MailFrame, "TOPRIGHT", 0, 4)
	reopen:Hide()
end

-- The visit over (the mailbox closed): everything put away.
local function Close()
	atMailbox = false
	Skin.CancelAsk()
	if window and window:IsShown() then
		-- (the game's window plays its own sound as it closes)
		window.quiet = true
		window:Hide()
	end
	PlaceGameWindow()
	if reopen then reopen:Hide() end
	if ns.LetterClosed then ns.LetterClosed() end
	if ns.SendClosed then ns.SendClosed() end
end

local AT_MAILBOX = { "MAIL_INBOX_UPDATE", "MAIL_SEND_INFO_UPDATE", "MAIL_SEND_SUCCESS", "MAIL_FAILED", "PLAYER_MONEY",
	"BAG_UPDATE_DELAYED", "UI_ERROR_MESSAGE", "CLOSE_INBOX_ITEM" }

-- (Init only, once Wanderer's check has passed; an older core keeps the card alone)
function ns.InitWindow()
	if (W.API or 1) < 21 or not (Skin.Tabs and Skin.Table and Skin.AsideGameWindow and Skin.Sounds) then
		ns.WindowWanted, ns.WindowInUse = nil, nil
		return
	end
	drawSoon = U.Debounce(0.1, Draw)
	-- Wanderer Mail's own refresh (a setting changed, Wanderer switched off): the window follows it; switched off at
	-- a mailbox, the game's window comes back.
	local refresh = ns.Refresh
	function ns.Refresh()
		refresh()
		if atMailbox and mode == "wanderer" and not On() then return ns.UseGame() end
		if reopen and mode == "game" then reopen:SetShown(atMailbox and LinkWanted()) end
		ns.DrawSoon()
	end
	local events = CreateFrame("Frame")
	local function Hear(on)
		for _, event in ipairs(AT_MAILBOX) do pcall(on and events.RegisterEvent or events.UnregisterEvent, events, event) end
	end
	-- The visit over, however the game says it (its event, its window put away, its interaction ended): once.
	local function Ended()
		if not atMailbox then return end
		Hear(false)
		Close()
	end
	function ns.VisitEnded()
		C_Timer.After(0, function()
			if atMailbox and not (MailFrame and MailFrame:IsShown()) then Ended() end
		end)
	end
	events:SetScript("OnEvent", function(_, event, ...)
		if event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" then
			local mailbox = Enum and Enum.PlayerInteractionType and Enum.PlayerInteractionType.MailInfo
			if mailbox and ... == mailbox then Ended() end
			return
		end
		if event == "MAIL_SHOW" then
			if not On() then return end
			atMailbox = true
			Hear(true)
			mode = ns.WindowWanted() and "wanderer" or "game"
			-- The game's window comes with this same event: placed now if it is there, else a moment later.
			local function Place()
				HookGameWindow()
				Reopen()
				PlaceGameWindow()
				if reopen then reopen:SetShown(atMailbox and mode == "game" and LinkWanted()) end
			end
			Place()
			C_Timer.After(0, function() if atMailbox then Place() end end)
			if mode == "wanderer" then
				current = "inbox"
				if ns.LetterOpened then ns.LetterOpened() end
				if not window then Create() end
				-- (the game's window plays its own sound as the visit begins)
				window.quiet = not window:IsShown()
				ns.OpenWindow("inbox")
				window.quiet = nil
			end
			ns.Refresh()
			return
		elseif event == "MAIL_CLOSED" then
			return Ended()
		end
		if ns.OnSendEvent and ns.OnSendEvent(event, ...) then return end
		if ns.OnLetterEvent then ns.OnLetterEvent(event, ...) end
		if event == "UI_ERROR_MESSAGE" then return end
		ns.DrawSoon()
	end)
	pcall(events.RegisterEvent, events, "MAIL_SHOW")
	pcall(events.RegisterEvent, events, "MAIL_CLOSED")
	pcall(events.RegisterEvent, events, "PLAYER_INTERACTION_MANAGER_FRAME_HIDE")
end

-- The settings' row changed while at a mailbox: the window chosen now is the one shown.
function ns.WindowSettingChanged()
	if not atMailbox then return end
	if ns.WindowWanted() then
		if mode ~= "wanderer" then ns.UseWanderer() end
	elseif mode == "wanderer" then
		ns.UseGame()
	end
end
