local ADDON, ns = ...

local defaults = {
	scale = 1,
	tooltip = true,
	stack = true,
	vendor = true,
	passive = true,
	sort = "name",
	desc = false,
	deal = 30,
	realms = {},
	sell = {
		open = true,
		alt = true,
		log = true,
		rule = "copper",
		percent = 1,
		marketMult = 1,
		vendorMult = 3,
		margin = 5,
		threshold = 500000,
		duration = 2,
		bid = 100,
		prices = {},
	},
}

ACore.New(ADDON, ns, { db = "AAuctionDB", defaults = defaults, profile = true, shared = { "realms" } })

AAuction = {}

ns.realmKey = "Unknown"
ns.ahOpen = false

function ns.Now()
	if GetServerTime then
		local ok, t = pcall(GetServerTime)
		if ok and type(t) == "number" and not ns.IsSecret(t) then return t end
	end
	return time()
end

function ns.Age(t)
	if not t or t <= 0 then return "" end
	local d = ns.Now() - t
	if d < 90 then return "now" end
	if d < 3600 then return math.floor(d / 60) .. "m" end
	if d < 86400 then return math.floor(d / 3600) .. "h" end
	return math.floor(d / 86400) .. "d"
end

ns:Listen("LOGIN", function()
	local realm = GetRealmName and GetRealmName() or "Unknown"
	if type(realm) ~= "string" or realm == "" then realm = "Unknown" end
	ns.realmKey = realm .. "-" .. ns.playerFaction
end)

ns:On("AUCTION_HOUSE_SHOW", function()
	ns.ahOpen = true
	ns:Fire("AH_CHANGED")
end)

ns:On("AUCTION_HOUSE_CLOSED", function()
	ns.ahOpen = false
	ns:Fire("AH_CHANGED")
end)

ACore.Register({
	name = "AAuction",
	title = "AAuction",
	slash = "/aah",
	desc = "auction prices",
	toggle = function() ns.UI.Toggle() end,
	options = function() return ns.Options() end,
})

SLASH_AAUCTION1 = "/aauction"
SLASH_AAUCTION2 = "/aah"
SlashCmdList["AAUCTION"] = function(msg)
	msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
	local cmd = msg:lower()
	if cmd == "" then
		ns.UI.Toggle()
	elseif cmd == "sell" then
		ns.UI.Show("sell")
	elseif cmd == "scan" then
		ns.StartScan()
	elseif cmd == "deals" then
		ns.UI.Show("prices")
		ns.UI.SetDeals(true)
	elseif cmd == "stop" then
		ns.StopScan("stopped")
	elseif cmd == "reset" then
		ns.db.scale = 1
		ns.db.pos = nil
		ns:Fire("LAYOUT_RESET")
	elseif cmd:match("^purge") then
		local days = tonumber(cmd:match("(%d+)")) or 30
		ns.Print("removed " .. ns.Purge(days) .. " items not seen for " .. days .. " days")
	else
		ns.UI.Show()
		ns.UI.SetSearch(msg)
	end
end

BINDING_HEADER_AAUCTION = "AAuction"
BINDING_NAME_AAUCTION_TOGGLE = "Toggle AAuction"
function AAuction_ToggleBinding()
	ns.UI.Toggle()
end
