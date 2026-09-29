-- lua tests/test_format.lua   (run from the GoblinGambling/ folder)
local H = dofile("tests/helpers.lua")
local GG = H.load("UI/Widgets.lua")

H.eq(GG.FormatNumber(0), "0", "zero")
H.eq(GG.FormatNumber(7), "7", "one digit")
H.eq(GG.FormatNumber(999), "999", "three digits")
H.eq(GG.FormatNumber(1000), "1,000", "thousand")
H.eq(GG.FormatNumber(1234), "1,234", "1234")
H.eq(GG.FormatNumber(123456), "123,456", "six digits")
H.eq(GG.FormatNumber(1234567), "1,234,567", "million")
H.eq(GG.FormatNumber(-5000), "-5,000", "negative")
H.eq(GG.FormatNumber(-999), "-999", "negative small")
H.eq(GG.FormatNumber(1499.6), "1,500", "rounds")
H.eq(GG.FormatNumber(nil), "0", "nil is zero")
H.ok(GG.FormatGold(1234):find("1,234", 1, true), "gold format includes number")

-- Every addon file must at least compile under Lua 5.1.
local files = {
  "Core.lua", "Sound.lua", "Stats.lua", "UI/Widgets.lua", "UI/Window.lua",
  "Games/SlotsLogic.lua", "Games/PokerLogic.lua", "Games/SlotsUI.lua",
  "UI/StatsTab.lua",
}
for _, f in ipairs(files) do
  local chunk, err = loadfile(f)
  H.ok(chunk, "syntax error: " .. tostring(err))
end

-- TOC lists exactly those files, and each one exists.
local toc = assert(io.open("GoblinGambling.toc", "r"))
local listed = {}
for line in toc:lines() do
  line = line:gsub("\r", "")
  if line ~= "" and not line:match("^#") then
    local path = line:gsub("\\", "/")
    listed[#listed + 1] = path
    H.ok(io.open(path, "r"), "TOC lists missing file " .. path)
  end
end
toc:close()
local inToc = {}
for _, p in ipairs(listed) do inToc[p] = true end
for _, f in ipairs(files) do H.ok(inToc[f], f .. " is not in the TOC") end

print(string.format("test_format: %d checks passed", H.passed))
