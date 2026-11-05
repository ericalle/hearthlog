local ADDON_NAME, ns = ...

-- This file only reports that it loaded. The shims that used to live here are in Util.lua, so a
-- client that skips this file (seen once on Forever) loses nothing. /hl diag shows the result.
ns.LOADED = ns.LOADED or {}
ns.LOADED.Compat = true
