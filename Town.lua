local _, ns = ...
local L = ns.L

-- Wanderer's town card (API 13), its mailbox line in place of Wanderer's own: new mail, and a letter of this
-- character with gold or items about to leave its mailbox (as seen last time it was open: ns.OwnLeaving).

local W = Wanderer
local U = W and W.Util

-- (Init only, once Wanderer's check has passed)
function ns.InitTown()
	if not (W.TownLine and U) then return end
	W.TownLine(function()
		local newMail = U.Clean(U.Safe(HasNewMail)) and true or false
		local leaves = ns.OwnLeaving()
		if leaves then
			local left = U.Ago(leaves - time())
			return { text = newMail and L.TOWN_LINE_NEW_LEAVING:format(left) or L.TOWN_LINE_LEAVING:format(left) }
		end
		-- (Wanderer's own words for it)
		if newMail then return { text = L.TOWN_MAIL } end
	end, "mail")
end
