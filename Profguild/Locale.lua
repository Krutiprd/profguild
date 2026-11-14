-- Profguild: Locale
-- English is the default. Slovak is chosen with /pg lang sk (WoW has no Slovak client,
-- so the language does not follow the client locale).

local _, ns = ...
ns = ns or {}

local strings = {}

strings.en = {
	ADDON_LOADED = "version %s loaded. Type /pg to search your guild's crafters.",
	NO_GUILD = "You are not in a guild, so there is nothing to share yet.",
	OPEN_PROFESSION = "Open each of these professions once so Profguild can share your recipes: %s.",
	SCANNED = "%s: recipes saved and shared with the guild (%d).",
	LEARNED = "New recipe shared with the guild: %s",
	SYNC_STARTED = "Asking the guild for updates.",
	SYNC_TOO_SOON = "A sync just ran. Try again in a few seconds.",
	SYNC_BLOCKED = "Sending is blocked right now (%s). Messages will go out automatically later.",
	RESET_DONE = "Received guild data cleared. Downloading it again.",
	RESET_CONFIRM = "This clears the data received from guildmates (your own stays). Type /pg reset confirm to proceed.",
	LANG_SET = "Language set to English.",
	LANG_USAGE = "Usage: /pg lang en | sk",
	NEWER_VERSION = "A guildmate runs a newer Profguild. Please update to keep syncing.",
	HELP = "Commands: /pg (window), /pg sync, /pg status, /pg debug, /pg lang en|sk, /pg reset",
	DEBUG_SAVED = "Debug info printed and saved to SavedVariables (ProfguildDB.debug).",

	REASON_NO_GUILD = "not in a guild",
	REASON_COMBAT = "in combat",
	REASON_INSTANCE = "in an instance",
	REASON_TRIAL = "trial or veteran account",
	REASON_LOCKDOWN = "the game blocks addon messages here",

	STATUS_HEADER = "Profguild %s status",
	STATUS_GUILD = "Guild: %s",
	STATUS_RECORDS = "Characters in the database: %d (%d hidden as inactive)",
	STATUS_PEERS = "Guildmates seen with Profguild in the last 20 min: %d",
	STATUS_OWN = "This character: version %d, professions: %s",
	STATUS_SEND = "Sending: %s",
	STATUS_SEND_OK = "allowed",
	STATUS_QUEUE = "Waiting messages: %d",
	STATUS_TRAFFIC = "Sent H/R/D: %d/%d/%d, received H/R/D: %d/%d/%d, applied: %d",
	STATUS_LAST_HELLO = "Last sync request: %s",
	NEVER = "never",
	SECONDS_AGO = "%d s ago",
	NOT_SCANNED = "not scanned",

	WINDOW_TITLE = "Profguild",
	SEARCH_HINT = "Search recipes, items, professions or members",
	TAB_RECIPES = "Recipes",
	TAB_MEMBERS = "Members",
	ONLINE_ONLY = "Online only",
	NO_RESULTS = "Nothing found.",
	EMPTY_DB = "No data yet. Open your professions and wait for guildmates with Profguild.",
	MORE_RESULTS = "Showing the first %d results. Refine the search.",
	CRAFTERS = "Crafters",
	CRAFTED_BY = "Crafted by",
	MORE_CRAFTERS = "(+%d)",
	CLICK_WHISPER = "Click: whisper %s. Shift-click: link the item.",
	NO_ONE_ONLINE = "No crafter is online. Click to whisper %s anyway.",
	MEMBER_RECIPES = "%d recipes",
	MEMBER_ALTS = "Alts: %s",
	MEMBER_UPDATED = "Updated %s",
	MEMBER_CLICK = "Click: show this member's recipes.",
	FILTER_MEMBER = "Showing recipes of %s",
	CLEAR_FILTER = "Clear",
	STATUSBAR = "%d characters, %d recipes, %d guildmates online with Profguild",
	NOT_SCANNED_HINT = "recipes not shared yet",
	DAYS_AGO = "%d days ago",
	TODAY = "today",
}

strings.sk = {
	ADDON_LOADED = "verzia %s načítaná. Napíš /pg a hľadaj crafterov v guilde.",
	NO_GUILD = "Nie si v guilde, zatiaľ nie je s kým zdieľať.",
	OPEN_PROFESSION = "Otvor raz každú z týchto profesií, aby Profguild mohol zdieľať tvoje recepty: %s.",
	SCANNED = "%s: recepty uložené a zdieľané s guildou (%d).",
	LEARNED = "Nový recept zdieľaný s guildou: %s",
	SYNC_STARTED = "Pýtam si od guildy novinky.",
	SYNC_TOO_SOON = "Synchronizácia práve prebehla. Skús to o pár sekúnd.",
	SYNC_BLOCKED = "Posielanie je teraz blokované (%s). Správy sa odošlú automaticky neskôr.",
	RESET_DONE = "Dáta od spoluhráčov zmazané. Sťahujem ich znova.",
	RESET_CONFIRM = "Toto zmaže dáta prijaté od spoluhráčov (tvoje ostanú). Pokračuj príkazom /pg reset confirm.",
	LANG_SET = "Jazyk nastavený na slovenčinu.",
	LANG_USAGE = "Použitie: /pg lang en | sk",
	NEWER_VERSION = "Niekto v guilde má novší Profguild. Aktualizuj ho, aby synchronizácia fungovala.",
	HELP = "Príkazy: /pg (okno), /pg sync, /pg status, /pg debug, /pg lang en|sk, /pg reset",
	DEBUG_SAVED = "Diagnostika vypísaná a uložená do SavedVariables (ProfguildDB.debug).",

	REASON_NO_GUILD = "nie si v guilde",
	REASON_COMBAT = "si v boji",
	REASON_INSTANCE = "si v inštancii",
	REASON_TRIAL = "trial alebo veteran účet",
	REASON_LOCKDOWN = "hra tu blokuje správy addonov",

	STATUS_HEADER = "Profguild %s – stav",
	STATUS_GUILD = "Guilda: %s",
	STATUS_RECORDS = "Postáv v databáze: %d (%d skrytých ako neaktívne)",
	STATUS_PEERS = "Spoluhráči s Profguildom za posledných 20 min: %d",
	STATUS_OWN = "Táto postava: verzia %d, profesie: %s",
	STATUS_SEND = "Posielanie: %s",
	STATUS_SEND_OK = "povolené",
	STATUS_QUEUE = "Čakajúce správy: %d",
	STATUS_TRAFFIC = "Odoslané H/R/D: %d/%d/%d, prijaté H/R/D: %d/%d/%d, uložené: %d",
	STATUS_LAST_HELLO = "Posledná žiadosť o sync: %s",
	NEVER = "nikdy",
	SECONDS_AGO = "pred %d s",
	NOT_SCANNED = "nenaskenované",

	WINDOW_TITLE = "Profguild",
	SEARCH_HINT = "Hľadaj recept, item, profesiu alebo člena",
	TAB_RECIPES = "Recepty",
	TAB_MEMBERS = "Členovia",
	ONLINE_ONLY = "Len online",
	NO_RESULTS = "Nič sa nenašlo.",
	EMPTY_DB = "Zatiaľ žiadne dáta. Otvor svoje profesie a počkaj na spoluhráčov s Profguildom.",
	MORE_RESULTS = "Zobrazených prvých %d výsledkov. Spresni hľadanie.",
	CRAFTERS = "Crafteri",
	CRAFTED_BY = "Vyrobí",
	MORE_CRAFTERS = "(+%d)",
	CLICK_WHISPER = "Klik: whisper %s. Shift+klik: link itemu.",
	NO_ONE_ONLINE = "Nikto z crafterov nie je online. Klikni a pošli whisper %s.",
	MEMBER_RECIPES = "receptov: %d",
	MEMBER_ALTS = "Alti: %s",
	MEMBER_UPDATED = "Aktualizované %s",
	MEMBER_CLICK = "Klik: zobraz recepty tohto člena.",
	FILTER_MEMBER = "Recepty hráča %s",
	CLEAR_FILTER = "Zrušiť",
	STATUSBAR = "Postavy: %d, recepty: %d, spoluhráči online s Profguildom: %d",
	NOT_SCANNED_HINT = "recepty zatiaľ nezdieľané",
	DAYS_AGO = "pred %d dňami",
	TODAY = "dnes",
}

ns.Locales = strings
ns.lang = "en"

-- ns.T("KEY", ...) returns the formatted string in the current language, falling back to English.
function ns.T(key, ...)
	local s = (strings[ns.lang] and strings[ns.lang][key]) or strings.en[key] or key
	if select("#", ...) > 0 then
		local ok, out = pcall(string.format, s, ...)
		if ok then return out end
	end
	return s
end

function ns.SetLanguage(lang)
	if strings[lang] then
		ns.lang = lang
		return true
	end
	return false
end
