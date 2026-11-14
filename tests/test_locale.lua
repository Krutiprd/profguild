local H = ...
local ns = H.newNamespace({ "Locale.lua" })

H.test("locale: every English key exists in Slovak and formats the same", function()
	for key, en in pairs(ns.Locales.en) do
		local sk = ns.Locales.sk[key]
		H.ok(sk, "missing sk key " .. key)
		local _, enCount = en:gsub("%%[ds]", "")
		local _, skCount = sk:gsub("%%[ds]", "")
		H.eq(skCount, enCount, "placeholders in " .. key)
	end
	for key in pairs(ns.Locales.sk) do
		H.ok(ns.Locales.en[key], "extra sk key " .. key)
	end
end)

H.test("locale: switching language and fallback", function()
	H.eq(ns.T("TAB_RECIPES"), "Recipes")
	H.ok(ns.SetLanguage("sk"))
	H.eq(ns.T("TAB_RECIPES"), "Recepty")
	H.eq(ns.T("SCANNED", "Tailoring", 5), "Tailoring: recepty uložené a zdieľané s guildou (5).")
	H.ok(not ns.SetLanguage("de"))
	H.eq(ns.T("NO_SUCH_KEY"), "NO_SUCH_KEY")
	ns.SetLanguage("en")
end)
