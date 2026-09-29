-- Goblin Gambling Co. : every sound in one place.
-- IDs use the SOUNDKIT name when the client has it, else the number.
-- /gg soundtest plays each one with its name so bad picks are easy to spot.
local ADDON, GG = ...

local K = SOUNDKIT or {}

GG.SOUNDS = {
  open     = K.IG_MAINMENU_OPEN or 850,
  close    = K.IG_MAINMENU_CLOSE or 851,
  tab      = K.IG_CHARACTER_INFO_TAB or 841,
  click    = K.IG_MAINMENU_OPTION_CHECKBOX_ON or 856,
  spin     = K.MONEY_FRAME_OPEN or 891,
  reelStop = K.U_CHAT_SCROLL_BUTTON or 1115,
  loss     = K.IG_QUEST_FAILED or 847,
  smallWin = K.LOOT_WINDOW_COIN_SOUND or 120,
  bigWin   = K.UI_EPICLOOT_TOAST or 31578,
  jackpot  = K.LEVELUP or 888,
  bailout  = K.MONEY_FRAME_CLOSE or 892,
}

-- Order for /gg soundtest.
local TEST_ORDER = { "open", "close", "tab", "click", "spin", "reelStop",
                     "loss", "smallWin", "bigWin", "jackpot", "bailout" }

-- Never let a bad sound ID throw an error.
local function Play(id)
  if id then pcall(PlaySound, id, "SFX") end
end

function GG:PlaySound(key)
  if not (self.db and self.db.settings.sound) then return end
  Play(GG.SOUNDS[key] or key)
end

function GG:SoundTest()
  GG.Say("Sound test: one sound every 1.5 seconds. Tell the goblin which ones are wrong.")
  for i, key in ipairs(TEST_ORDER) do
    C_Timer.After((i - 1) * 1.5, function()
      print(("   %d. %s (ID %s)"):format(i, key, tostring(GG.SOUNDS[key])))
      Play(GG.SOUNDS[key])
    end)
  end
end
