-- IM Unlock Tool v4.6.221.54 Simulator
-- Xiaoim | MineOS / OpenComputers Edition
-- (Пародия: Xiaomi → Xiaoim, MI → IM)

local gpu = require("component").gpu
local event = require("event")
local computer = require("computer")
local unicode = require("unicode")
local fs = require("filesystem")

-- Simple key-value serializer (no external deps)
local function serializeUsers(t)
  local lines = {}
  for login, data in pairs(t) do
    -- escape pipe and semicolon in login/password just in case
    local pass = (data.password or ""):gsub("|","\\|"):gsub(";","\\;")
    local esc  = login:gsub("|","\\|"):gsub(";","\\;")
    local wd   = data.waitDone and "1" or "0"
    local wh   = tostring(data.waitHours or 0)
    local ws   = tostring(data.waitStartReal or 0)
    lines[#lines+1] = esc.."|"..pass.."|"..wd.."|"..wh.."|"..ws
  end
  return table.concat(lines, "\n")
end

local function deserializeUsers(str)
  local t = {}
  for line in (str.."\n"):gmatch("([^\n]*)\n") do
    if line ~= "" then
      local parts = {}
      for p in (line.."|"):gmatch("([^|]*)|") do parts[#parts+1] = p end
      if parts[1] and parts[1] ~= "" then
        t[parts[1]] = {
          password      = parts[2] or "",
          waitDone      = (parts[3] == "1"),
          waitHours     = tonumber(parts[4]) or 0,
          waitStartReal = tonumber(parts[5]) or 0,
        }
      end
    end
  end
  return t
end

-- ============================================================
--  COLOUR PALETTE  (Xiaoim: white bg, orange accent, dark text)
-- ============================================================
local C = {
  bg          = 0xFFFFFF,
  panel       = 0xF5F5F5,
  panelBorder = 0xE0E0E0,
  accent      = 0xFF6900,   -- Xiaoim orange
  accentHover = 0xE05A00,
  accentDark  = 0xBF4500,
  text        = 0x212121,
  textSub     = 0x757575,
  textLight   = 0xBDBDBD,
  textOnAcc   = 0xFFFFFF,
  inputBg     = 0xFFFFFF,
  inputBorder = 0xCCCCCC,
  inputFocus  = 0xFF6900,
  success     = 0x4CAF50,
  warning     = 0xFF9800,
  danger      = 0xF44336,
  progressBg  = 0xE0E0E0,
  progressFg  = 0xFF6900,
  linkColor   = 0xFF6900,
  overlayBg   = 0x000000,
}

local W, H = gpu.getResolution()

-- ============================================================
--  STATE
-- ============================================================
local SAVE_FILE = "/etc/imunlock_users.dat"

local state = {
  screen    = "login",   -- login | register | waiting | main | warning1 | warning2 | checking | unlocking | done | error
  user      = nil,
  password  = nil,
  device    = nil,
  waitHours = 0,
  waitStart = 0,
  unlockPct = 0,
  checkPct  = 0,   -- green 0-35% server-check progress before the outcome is decided
  outcome   = nil, -- "instant" | "wait" decided once checkPct hits target
  errorMsg  = "",
  focus     = 1,
  inputs    = { "", "" },   -- [1]=login/username, [2]=password
  showPass  = false,
  regMode   = false,
  tick      = 0,
  dots      = 0,
  anim      = 0,
}

-- Fake device database
local DEVICES = {
  { model="Redmi Note 12 Pro", imei="358041089876543", android="13",   imui="IMUI 14.0.6", sn="6C3F0K00B1" },
  { model="Xiaoim 13",         imei="869104036543210", android="13",   imui="IMUI 14.0.8", sn="2A7X9M00C3" },
  { model="Poco X5 Pro 5G",    imei="352753118765432", android="12",   imui="IMUI 13.0.7", sn="9D1P3N00A7" },
  { model="Redmi 10C",         imei="863741052345678", android="11",   imui="IMUI 13.0.3", sn="4B8Q2L00F5" },
  { model="Xiaoim 12T Pro",    imei="867530049876541", android="12",   imui="IMUI 14.0.4", sn="7E5R1H00G2" },
}

-- Possible outcomes once you press Unlock:
--   moментально (instant unlock) or a wait timer of 72h / 360h
local WAIT_RULES = {0, 72, 360}

-- ============================================================
--  PERSISTENCE
-- ============================================================
-- Safe file open wrapper (io may be nil in some OC environments)
local function safeOpen(path, mode)
  if io and io.open then
    local ok, f = pcall(io.open, path, mode)
    if ok and f then return f end
  end
  -- Fallback: use filesystem component directly
  local ok, f = pcall(fs.open, path, mode)
  if ok and f then return f end
  return nil
end

local function loadUsers()
  if not fs.exists(SAVE_FILE) then return {} end
  local f = safeOpen(SAVE_FILE, "r")
  if not f then return {} end
  local data
  -- handle both io-style and fs-style file handles
  if f.read then
    data = f:read("*a")
  elseif f.readAll then
    data = f:readAll()
  else
    data = ""
  end
  f:close()
  return deserializeUsers(data or "")
end

local function saveUsers(users)
  local dir = fs.path(SAVE_FILE)
  if dir and dir ~= "" and not fs.exists(dir) then
    pcall(fs.makeDirectory, dir)
  end
  local f = safeOpen(SAVE_FILE, "w")
  if f then
    local payload = serializeUsers(users)
    if f.write then f:write(payload) else f:writeLine(payload) end
    f:close()
  end
end

-- ============================================================
--  DRAW HELPERS
-- ============================================================
local function set(fg, bg) gpu.setForeground(fg); gpu.setBackground(bg) end
local function fill(x,y,w,h,ch) gpu.fill(x,y,w,h,ch or " ") end

local function rect(x,y,w,h,bg,fg,char)
  set(fg or C.text, bg or C.bg)
  fill(x,y,w,h,char or " ")
end

local function text(x,y,str,fg,bg)
  set(fg or C.text, bg or C.bg)
  gpu.set(x,y,str)
end

local function center(y,str,fg,bg,bgW,bgX)
  local bx = bgX or 1; local bw = bgW or W
  set(fg or C.text, bg or C.bg)
  fill(bx,y,bw,1," ")
  local cx = bx + math.floor((bw - unicode.len(str))/2)
  gpu.set(cx,y,str)
end

local function button(x,y,w,label,active,danger)
  local bg = active and (danger and C.danger or C.accent) or C.panelBorder
  local fg = active and C.textOnAcc or C.textSub
  set(fg,bg); fill(x,y,w,1," ")
  local lx = x + math.floor((w - unicode.len(label))/2)
  gpu.set(lx,y,label)
  return {x=x,y=y,w=w,h=1}
end

local function inputBox(x,y,w,label,value,focused,secret)
  -- label
  set(C.textSub, C.bg); gpu.set(x,y, label)
  y = y+1
  -- box
  local bord = focused and C.inputFocus or C.inputBorder
  set(bord, C.inputBg); fill(x,y,w,1," ")
  -- left/right border chars
  gpu.set(x,y,"["); gpu.set(x+w-1,y,"]")
  -- content
  local disp = secret and string.rep("*", unicode.len(value)) or value
  local maxW = w-2
  if unicode.len(disp) > maxW then
    disp = unicode.sub(disp, unicode.len(disp)-maxW+1)
  end
  set(C.text, C.inputBg); gpu.set(x+1,y,disp)
  if focused then
    local cx = x+1+unicode.len(disp)
    if cx < x+w-1 then set(C.accent,C.inputBg); gpu.set(cx,y,"_") end
  end
  return y
end

local function progress(x,y,w,pct,label)
  local fill_w = math.floor(w * pct / 100)
  set(C.textOnAcc, C.progressFg); fill(x,y,fill_w,1," ")
  set(C.textSub,   C.progressBg); fill(x+fill_w,y,w-fill_w,1," ")
  local lbl = label or (pct.."%")
  local lx = x + math.floor((w - #lbl)/2)
  if lx < x+fill_w then set(C.textOnAcc, C.progressFg) else set(C.textSub, C.progressBg) end
  gpu.set(lx,y,lbl)
end

-- Thin horizontal line
local function hline(y, fg, bg)
  set(fg or C.panelBorder, bg or C.bg)
  fill(1,y,W,1,"─")
end

-- Panel (rounded simulation with spaces)
local function panel(x,y,w,h)
  rect(x,y,w,h,C.panel)
  set(C.panelBorder, C.bg)
  -- top/bottom borders
  gpu.set(x,y,  "┌"..string.rep("─",w-2).."┐")
  gpu.set(x,y+h-1,"└"..string.rep("─",w-2).."┘")
  for i=1,h-2 do
    set(C.panelBorder, C.panel)
    gpu.set(x,   y+i,"│")
    gpu.set(x+w-1,y+i,"│")
  end
end

-- Spinner frames
local SPIN = {"◐","◓","◑","◒"}

-- ============================================================
--  HEADER
-- ============================================================
local function drawHeader()
  rect(1,1,W,3,C.accent)
  -- Logo
  set(C.textOnAcc, C.accent)
  local logo = " 小米  IM Unlock  [Xiaoim]"
  gpu.set(2,2, logo)
  -- Version tag
  local ver = "v4.6.221.54 "
  set(0xFFCC99, C.accent)
  gpu.set(W - #ver, 2, ver)
  -- thin accent line
  set(C.accentDark, C.accentDark); fill(1,3,W,1," ")
end

local function drawFooter()
  set(C.textLight, C.bg)
  fill(1,H,W,1," ")
  local msg = "© 2024 Xiaoim Inc. | IM Unlock Tool | Simulator"
  gpu.set(math.floor((W-#msg)/2)+1, H, msg)
end

-- ============================================================
--  SCREEN: LOGIN / REGISTER
-- ============================================================
local loginBtns = {}

local function drawLogin()
  rect(1,1,W,H,C.bg)
  drawHeader()
  drawFooter()

  local pw = 36
  local px = math.floor((W-pw)/2)+1
  local py = 5

  panel(px,py,pw,H-py-1)

  -- Title
  local title = state.regMode and "Создать IM аккаунт" or "Войти в IM аккаунт"
  set(C.accent, C.panel)
  local tx = px + math.floor((pw - unicode.len(title))/2)
  gpu.set(tx, py+2, title)

  -- Xiaoim symbol
  set(C.accent, C.panel)
  gpu.set(px+math.floor((pw-2)/2), py+4, "IM")

  -- Input fields
  local iy = py+6
  local iw = pw-4
  local ix = px+2

  inputBox(ix, iy,   iw, "IM аккаунт (email/номер):", state.inputs[1], state.focus==1, false)
  iy = iy+3
  inputBox(ix, iy,   iw, "Пароль:", state.inputs[2], state.focus==2, not state.showPass)

  iy = iy+2
  -- show password toggle
  set(C.linkColor, C.panel)
  local sp = state.showPass and "[x] Скрыть пароль" or "[ ] Показать пароль"
  gpu.set(ix, iy, sp)
  loginBtns.showpass = {x=ix, y=iy, w=#sp, h=1}

  iy = iy+2

  if state.errorMsg ~= "" then
    set(C.danger, C.panel)
    local ex = px + math.floor((pw - unicode.len(state.errorMsg))/2)
    gpu.set(ex, iy, state.errorMsg)
    iy = iy+2
  end

  -- Main button
  local bw = pw-4
  local btnLabel = state.regMode and "  Зарегистрироваться  " or "  Войти  "
  loginBtns.main = button(ix, iy, bw, btnLabel, true, false)
  iy = iy+2

  -- Switch mode link
  set(C.linkColor, C.panel)
  local sw = state.regMode and "Уже есть аккаунт? Войти" or "Нет аккаунта? Зарегистрироваться"
  local swx = px + math.floor((pw - unicode.len(sw))/2)
  gpu.set(swx, iy, sw)
  loginBtns.switch = {x=swx, y=iy, w=unicode.len(sw), h=1}

  if not state.regMode then
    iy = iy+1
    set(C.textSub, C.panel)
    local fp = "Забыли пароль?"
    local fpx = px + math.floor((pw - unicode.len(fp))/2)
    gpu.set(fpx, iy, fp)
  end

  -- Device hint
  iy = py+H-py-3
  set(C.textLight, C.panel)
  local hint = "Подключите устройство по USB перед входом"
  local hx = px + math.floor((pw - unicode.len(hint))/2)
  gpu.set(hx, iy, hint)
end

-- ============================================================
--  SCREEN: WAITING (timer countdown)
-- ============================================================
local function drawWaiting()
  rect(1,1,W,H,C.bg)
  drawHeader()
  drawFooter()

  local pw = 50
  local px = math.floor((W-pw)/2)+1
  local py = 5
  panel(px,py,pw,H-py-1)

  -- Icon
  set(C.warning, C.panel)
  local clock = "⏱"
  gpu.set(px+math.floor((pw-2)/2), py+2, clock)

  center(py+3, "Ожидание разблокировки", C.accent, C.panel, pw, px)

  set(C.panelBorder, C.panel); fill(px+1,py+4,pw-2,1,"─")

  local elapsed = computer.uptime() - state.waitStart  -- 1 real second = 1 sim hour
  local totalSec = state.waitHours * 60 * 60
  local remaining = math.floor(math.max(0, math.min(totalSec, totalSec - elapsed*3600)))  -- compressed time
  local rh = math.floor(remaining/3600)
  local rm = math.floor((remaining%3600)/60)
  local rs = remaining%60

  local timerStr = string.format("%02d:%02d:%02d", rh, rm, rs)
  set(C.accent, C.panel)
  local tx = px + math.floor((pw-#timerStr)/2)
  gpu.set(tx, py+6, timerStr)

  center(py+7, "осталось до разблокировки", C.textSub, C.panel, pw, px)

  -- Progress bar
  local totalHours = state.waitHours
  local pct
  if totalHours == 0 or totalSec == 0 then
    pct = 100
  else
    local passedSec = totalSec - remaining
    pct = math.floor(passedSec / totalSec * 100)
    pct = math.max(0, math.min(100, pct))
  end

  progress(px+2, py+9, pw-4, pct, pct.."%  прошло")

  set(C.panelBorder, C.panel); fill(px+1,py+11,pw-2,1,"─")

  -- Device info
  local dev = state.device
  set(C.textSub, C.panel); gpu.set(px+2, py+12, "Устройство:")
  set(C.text,    C.panel); gpu.set(px+14, py+12, dev.model)

  set(C.textSub, C.panel); gpu.set(px+2, py+13, "Android:")
  set(C.text,    C.panel); gpu.set(px+14, py+13, dev.android)

  set(C.textSub, C.panel); gpu.set(px+2, py+14, "IMEI:")
  set(C.text,    C.panel); gpu.set(px+14, py+14, dev.imei)

  set(C.textSub, C.panel); gpu.set(px+2, py+15, "IMUI:")
  set(C.text,    C.panel); gpu.set(px+14, py+15, dev.imui)

  set(C.panelBorder, C.panel); fill(px+1,py+16,pw-2,1,"─")

  -- Spin anim
  local sp = SPIN[(state.anim%4)+1]
  set(C.accent, C.panel)
  gpu.set(px+2, py+17, sp.." Проверка статуса связи с серверами Xiaoim...")

  -- Info
  center(py+19, "IM аккаунт: "..state.user, C.textSub, C.panel, pw, px)

  -- Check if done
  if remaining == 0 or totalHours == 0 then
    local users = loadUsers()
    if users[state.user] then
      users[state.user].waitDone = true
      users[state.user].waitHours = 0
      users[state.user].waitStartReal = 0
      saveUsers(users)
    end
    state.screen = "main"
  end
end

-- ============================================================
--  SCREEN: MAIN (device connected, ready)
-- ============================================================
local mainBtns = {}

local function drawPhoneArt(x, y, accentColor, panelBg)
  -- A small ASCII/box phone silhouette, like the device illustration in Mi Unlock
  set(C.textSub, panelBg)
  local frame = {
    "┌──────────┐",
    "│  ┌────┐  │",
    "│  │    │  │",
    "│  │    │  │",
    "│  │    │  │",
    "│  │    │  │",
    "│  └────┘  │",
    "│    ●     │",
    "└──────────┘",
  }
  for i, row in ipairs(frame) do
    gpu.set(x, y+i-1, row)
  end
  -- "screen" glow in accent colour to suggest it's powered/connected
  set(accentColor, panelBg)
  gpu.set(x+3, y+2, "▓▓▓▓")
  gpu.set(x+3, y+3, "▓▓▓▓")
  gpu.set(x+3, y+4, "▓▓▓▓")
  gpu.set(x+3, y+5, "▓▓▓▓")
end

local function drawMain()
  rect(1,1,W,H,C.bg)
  drawHeader()
  drawFooter()

  local pw = 56
  local px = math.floor((W-pw)/2)+1
  local py = 5
  panel(px,py,pw,H-py-1)

  center(py+1, "IM Unlock Tool", C.accent, C.panel, pw, px)
  set(C.panelBorder,C.panel); fill(px+1,py+2,pw-2,1,"─")

  -- Phone illustration on the left half of the panel
  local artX = px+4
  local artY = py+4
  drawPhoneArt(artX, artY, C.accent, C.panel)

  -- Device info to the right of the phone art
  local ix = artX + 15
  local iy = artY
  local dev = state.device

  set(C.success, C.panel)
  gpu.set(ix, iy, "● Device connected")
  iy = iy+2

  set(C.textSub, C.panel); gpu.set(ix, iy,   "Model:")
  set(C.text,    C.panel); gpu.set(ix+9, iy, dev.model)
  iy = iy+1
  set(C.textSub, C.panel); gpu.set(ix, iy,   "Android:")
  set(C.text,    C.panel); gpu.set(ix+9, iy, dev.android)
  iy = iy+1
  set(C.textSub, C.panel); gpu.set(ix, iy,   "IMUI:")
  set(C.text,    C.panel); gpu.set(ix+9, iy, dev.imui)
  iy = iy+1
  set(C.textSub, C.panel); gpu.set(ix, iy,   "Bootloader:")
  set(C.danger,  C.panel); gpu.set(ix+12, iy, "LOCKED")

  local belowY = artY + 9
  set(C.panelBorder,C.panel); fill(px+1, belowY, pw-2, 1, "─")

  -- IMEI / account line
  belowY = belowY + 1
  set(C.textSub, C.panel); gpu.set(px+2, belowY, "IMEI:")
  set(C.text,    C.panel); gpu.set(px+10, belowY, dev.imei)
  set(C.textSub, C.panel); gpu.set(px+34, belowY, "IM account:")
  set(C.accent,  C.panel); gpu.set(px+47, belowY, state.user)

  belowY = belowY + 2
  set(C.panelBorder,C.panel); fill(px+1, belowY, pw-2, 1, "─")

  -- Unlock button (single, centered, like real Mi Unlock)
  local bw = pw-4
  local bx = px+2
  local by = belowY + 2
  mainBtns.unlock = button(bx, by, bw, "  Unlock  ", true, false)

  by = by+2
  mainBtns.logout = button(bx, by, bw, "Sign out", false, false)
end

-- ============================================================
--  SCREEN: WARNING #1 (data loss warning, like real Mi Unlock)
-- ============================================================
local warn1Btns = {}

local function drawWarning1()
  rect(1,1,W,H,C.bg)
  drawHeader()
  drawFooter()

  -- Dim the background main screen feel with an overlay panel
  rect(1,4,W,H-4,C.overlayBg)

  local pw = 50
  local px = math.floor((W-pw)/2)+1
  local py = 9
  panel(px,py,pw,11)

  set(C.warning, C.panel)
  gpu.set(px+math.floor((pw-2)/2), py+1, "⚠")
  center(py+2, "Warning", C.warning, C.panel, pw, px)

  set(C.panelBorder,C.panel); fill(px+1,py+3,pw-2,1,"─")

  set(C.text, C.panel)
  gpu.set(px+2, py+4, "Unlocking the bootloader will:")
  set(C.textSub, C.panel)
  gpu.set(px+2, py+5, "  • Erase all data on the device")
  gpu.set(px+2, py+6, "  • Void parts of the warranty")
  gpu.set(px+2, py+7, "  • Lower the device's security level")

  local bw = math.floor((pw-6)/2)
  warn1Btns.cancel = button(px+2,        py+9, bw, "Cancel", false, false)
  warn1Btns.next   = button(px+4+bw,     py+9, bw, "I understand", true, false)
end

-- ============================================================
--  SCREEN: WARNING #2 (final confirmation, like real Mi Unlock)
-- ============================================================
local warn2Btns = {}

local function drawWarning2()
  rect(1,1,W,H,C.bg)
  drawHeader()
  drawFooter()

  rect(1,4,W,H-4,C.overlayBg)

  local pw = 50
  local px = math.floor((W-pw)/2)+1
  local py = 9
  panel(px,py,pw,11)

  set(C.danger, C.panel)
  gpu.set(px+math.floor((pw-2)/2), py+1, "⚠")
  center(py+2, "Final Confirmation", C.danger, C.panel, pw, px)

  set(C.panelBorder,C.panel); fill(px+1,py+3,pw-2,1,"─")

  set(C.text, C.panel)
  gpu.set(px+2, py+4, "This action cannot be undone.")
  set(C.textSub, C.panel)
  gpu.set(px+2, py+5, "Make sure you have backed up your")
  gpu.set(px+2, py+6, "personal data before continuing.")
  set(C.text, C.panel)
  gpu.set(px+2, py+7, "Continue unlocking this device?")

  local bw = math.floor((pw-6)/2)
  warn2Btns.cancel = button(px+2,        py+9, bw, "Cancel", false, false)
  warn2Btns.unlock = button(px+4+bw,     py+9, bw, "Unlock", true, true)
end

-- ============================================================
--  SCREEN: CHECKING (green % progress while talking to server)
-- ============================================================
local function drawChecking()
  rect(1,1,W,H,C.bg)
  drawHeader()
  drawFooter()

  local pw = 52
  local px = math.floor((W-pw)/2)+1
  local py = 9
  panel(px,py,pw,9)

  local sp = SPIN[(state.anim%4)+1]
  set(C.accent, C.panel)
  gpu.set(px+math.floor((pw-2)/2), py+1, sp)

  center(py+2, "Connecting to Xiaoim servers...", C.accent, C.panel, pw, px)
  set(C.panelBorder,C.panel); fill(px+1,py+3,pw-2,1,"─")

  -- Green progress bar, 0/5/10/.../35%
  set(C.textOnAcc, C.success)
  local pct = state.checkPct
  local w = pw-4
  local fill_w = math.floor(w * pct / 100)
  fill(px+2, py+5, fill_w, 1, " ")
  set(C.textSub, C.progressBg)
  fill(px+2+fill_w, py+5, w-fill_w, 1, " ")
  local lbl = pct.."%"
  local lx = px+2 + math.floor((w-#lbl)/2)
  if lx < px+2+fill_w then set(C.textOnAcc, C.success) else set(C.textSub, C.progressBg) end
  gpu.set(lx, py+5, lbl)

  set(C.textSub, C.panel)
  gpu.set(px+2, py+7, "Please keep the device connected...")
end

local function drawUnlocking()
  rect(1,1,W,H,C.bg)
  drawHeader()
  drawFooter()

  local pw = 52
  local px = math.floor((W-pw)/2)+1
  local py = 5
  panel(px,py,pw,H-py-1)

  -- Spinner
  local sp = SPIN[(state.anim%4)+1]
  set(C.accent, C.panel)
  local sx = px + math.floor((pw-2)/2)
  gpu.set(sx, py+2, sp)

  center(py+3, "Разблокировка загрузчика...", C.accent, C.panel, pw, px)
  set(C.panelBorder,C.panel); fill(px+1,py+4,pw-2,1,"─")

  -- Steps with live updates
  local pct = state.unlockPct
  local stages = {
    {at=0,  label="Проверка IM аккаунта..."},
    {at=12, label="Проверка привязки устройства..."},
    {at=22, label="Отправка команды на серверы Xiaoim..."},
    {at=35, label="Получение токена разблокировки..."},
    {at=48, label="Применение токена..."},
    {at=62, label="Запись в fastboot..."},
    {at=75, label="Разблокировка bootloader..."},
    {at=88, label="Форматирование userdata..."},
    {at=95, label="Перезагрузка устройства..."},
    {at=100,label="Готово!"},
  }

  local currentStage = "Инициализация..."
  for _,s in ipairs(stages) do
    if pct >= s.at then currentStage = s.label end
  end

  local sy = py+5
  for i,s in ipairs(stages) do
    if pct >= s.at then
      if pct > s.at or i==#stages then
        set(C.success, C.panel)
        gpu.set(px+2, sy+i-1, "✓ "..s.label)
      else
        set(C.accent, C.panel)
        gpu.set(px+2, sy+i-1, sp.." "..s.label)
      end
    else
      set(C.textLight, C.panel)
      gpu.set(px+2, sy+i-1, "  "..s.label)
    end
  end

  set(C.panelBorder,C.panel); fill(px+1,sy+#stages,pw-2,1,"─")

  -- Progress bar
  local pby = sy+#stages+1
  progress(px+2, pby, pw-4, pct, pct.."%")

  -- Log line
  local t = math.floor(computer.uptime())
  local ss = t % 60; local mm = math.floor(t/60)%60; local hh = math.floor(t/3600)%24
  local ts = string.format("%02d:%02d:%02d", hh, mm, ss)
  set(C.textSub, C.panel)
  local dots = string.rep(".", state.dots%4)
  gpu.set(px+2, pby+2, "["..ts.."] "..currentStage..dots)

  if pct >= 100 then
    state.screen = "done"
  end
end

-- ============================================================
--  SCREEN: DONE
-- ============================================================
local doneBtns = {}

local function drawDone()
  rect(1,1,W,H,C.bg)
  drawHeader()
  drawFooter()

  local pw = 44
  local px = math.floor((W-pw)/2)+1
  local py = 6
  panel(px,py,pw,H-py-1)

  -- Big check
  set(C.success, C.panel)
  local ck = "✓"
  gpu.set(px+math.floor((pw-2)/2), py+2, ck)

  center(py+3, "Device unlocked successfully", C.success, C.panel, pw, px)
  center(py+4, "Bootloader разблокирован", C.textSub, C.panel, pw, px)

  set(C.panelBorder,C.panel); fill(px+1,py+5,pw-2,1,"─")

  local dev = state.device
  local info = {
    {"Устройство",  dev.model},
    {"Bootloader",  "UNLOCKED ✓"},
    {"Серийный",    dev.sn},
    {"Аккаунт",     state.user},
  }
  for i,r in ipairs(info) do
    set(C.textSub, C.panel); gpu.set(px+2, py+5+i, r[1]..":")
    local c = (r[1]=="Bootloader") and C.success or C.text
    set(c, C.panel); gpu.set(px+16, py+5+i, r[2])
  end

  set(C.panelBorder,C.panel); fill(px+1,py+5+#info+1,pw-2,1,"─")

  set(C.warning, C.panel)
  gpu.set(px+2, py+5+#info+2, "⚠  Устройство перезагружается...")
  set(C.textSub,C.panel)
  gpu.set(px+2, py+5+#info+3, "   Данные удалены. Настройте заново.")

  local bw = pw-4
  local bx = px+2
  doneBtns.ok = button(bx, py+5+#info+6, bw, "  Готово — Закрыть  ", true, false)
end

-- ============================================================
--  SCREEN: ERROR
-- ============================================================
local errBtns = {}

local function drawError()
  rect(1,1,W,H,C.bg)
  drawHeader()
  drawFooter()

  local pw = 44
  local px = math.floor((W-pw)/2)+1
  local py = 7
  panel(px,py,pw,12)

  set(C.danger, C.panel)
  gpu.set(px+math.floor((pw-2)/2), py+1, "✗")
  center(py+2, "Ошибка!", C.danger, C.panel, pw, px)
  center(py+3, state.errorMsg, C.textSub, C.panel, pw, px)

  set(C.panelBorder,C.panel); fill(px+1,py+5,pw-2,1,"─")
  errBtns.back = button(px+2, py+7, pw-4, "  Назад  ", true, false)
end

-- ============================================================
--  INPUT HANDLING
-- ============================================================
local function handleChar(char)
  if state.screen == "login" then
    state.inputs[state.focus] = state.inputs[state.focus] .. char
  end
end

local function handleKey(code)
  if state.screen == "login" then
    if code == 15 then  -- Tab
      state.focus = state.focus == 1 and 2 or 1
    elseif code == 14 then  -- Backspace
      local s = state.inputs[state.focus]
      if #s > 0 then state.inputs[state.focus] = unicode.sub(s,1,-2) end
    elseif code == 28 then  -- Enter
      -- submit
      local login = state.inputs[1]
      local pass  = state.inputs[2]
      if login=="" or pass=="" then
        state.errorMsg = "Заполните все поля!"
        return
      end
      local users = loadUsers()
      if state.regMode then
        if users[login] then
          state.errorMsg = "Аккаунт уже существует!"
          return
        end
        users[login] = {password=pass, waitDone=false, waitHours=0}
        saveUsers(users)
        state.regMode = false
        state.errorMsg = ""
        state.inputs = {login,""}
        state.focus = 2
      else
        local u = users[login]
        if not u or u.password ~= pass then
          state.errorMsg = "Неверный логин или пароль!"
          return
        end
        state.user = login
        state.errorMsg = ""
        -- pick random device
        state.device = DEVICES[math.random(1,#DEVICES)]
        if u.waitDone then
          -- a previous wait timer already finished; device is ready, go straight to main
          state.screen = "main"
        elseif (u.waitHours or 0) > 0 then
          -- a wait timer is currently running from a previous unlock attempt
          state.waitHours = u.waitHours
          state.waitStart = u.waitStartReal or computer.uptime()
          state.screen = "waiting"
        else
          state.screen = "main"
        end
      end
    end
  end
end

local function handleClick(x,y,btn)
  if state.screen == "login" then
    -- Focus inputs
    -- input 1 is at row: depends on panel
    local pw=36; local px=math.floor((W-pw)/2)+1; local py=5
    local iy=py+7; local ix=px+2
    if y==iy and x>=ix and x<ix+pw-4 then state.focus=1 end
    if y==iy+3 and x>=ix and x<ix+pw-4 then state.focus=2 end

    -- Buttons
    if loginBtns.showpass and y==loginBtns.showpass.y and x>=loginBtns.showpass.x and x<loginBtns.showpass.x+loginBtns.showpass.w then
      state.showPass = not state.showPass
    end
    if loginBtns.main and y==loginBtns.main.y and x>=loginBtns.main.x and x<loginBtns.main.x+loginBtns.main.w then
      handleKey(28)  -- simulate Enter
    end
    if loginBtns.switch and y==loginBtns.switch.y and x>=loginBtns.switch.x and x<loginBtns.switch.x+loginBtns.switch.w then
      state.regMode = not state.regMode
      state.errorMsg = ""
      state.inputs = {"",""}
      state.focus = 1
    end

  elseif state.screen == "main" then
    if mainBtns.unlock and y==mainBtns.unlock.y and x>=mainBtns.unlock.x and x<mainBtns.unlock.x+mainBtns.unlock.w then
      state.screen = "warning1"
    end
    if mainBtns.logout and y==mainBtns.logout.y and x>=mainBtns.logout.x and x<mainBtns.logout.x+mainBtns.logout.w then
      state.screen = "login"
      state.user = nil
      state.inputs = {"",""}
      state.errorMsg = ""
      state.focus = 1
    end

  elseif state.screen == "warning1" then
    if warn1Btns.cancel and y==warn1Btns.cancel.y and x>=warn1Btns.cancel.x and x<warn1Btns.cancel.x+warn1Btns.cancel.w then
      state.screen = "main"
    end
    if warn1Btns.next and y==warn1Btns.next.y and x>=warn1Btns.next.x and x<warn1Btns.next.x+warn1Btns.next.w then
      state.screen = "warning2"
    end

  elseif state.screen == "warning2" then
    if warn2Btns.cancel and y==warn2Btns.cancel.y and x>=warn2Btns.cancel.x and x<warn2Btns.cancel.x+warn2Btns.cancel.w then
      state.screen = "main"
    end
    if warn2Btns.unlock and y==warn2Btns.unlock.y and x>=warn2Btns.unlock.x and x<warn2Btns.unlock.x+warn2Btns.unlock.w then
      state.screen = "checking"
      state.checkPct = 0
      state.outcome = nil
    end

  elseif state.screen == "done" then
    if doneBtns.ok and y==doneBtns.ok.y and x>=doneBtns.ok.x and x<doneBtns.ok.x+doneBtns.ok.w then
      -- Reset & back to login
      state.screen = "login"
      state.user = nil
      state.inputs = {"",""}
      state.errorMsg = ""
      state.focus = 1
    end

  elseif state.screen == "error" then
    if errBtns.back and y==errBtns.back.y and x>=errBtns.back.x and x<errBtns.back.x+errBtns.back.w then
      state.screen = "login"
      state.errorMsg = ""
    end
  end
end

-- ============================================================
--  DRAW DISPATCH
-- ============================================================
local function draw()
  local s = state.screen
  if s=="login" or s=="register" then drawLogin()
  elseif s=="waiting"   then drawWaiting()
  elseif s=="main"      then drawMain()
  elseif s=="warning1"  then drawWarning1()
  elseif s=="warning2"  then drawWarning2()
  elseif s=="checking"  then drawChecking()
  elseif s=="unlocking" then drawUnlocking()
  elseif s=="done"      then drawDone()
  elseif s=="error"     then drawError()
  end
end

-- ============================================================
--  MAIN LOOP
-- ============================================================
local function main()
  gpu.setResolution(W,H)
  draw()

  local lastDraw = computer.uptime()

  while true do
    local ev = {event.pull(0.1)}
    local evType = ev[1]

    if evType == "key_down" then
      local char = ev[3]; local code = ev[4]
      if code == 211 then break end  -- Delete = exit
      if char >= 32 and char <= 126 then handleChar(string.char(char)) end
      handleKey(code)
      draw()

    elseif evType == "touch" then
      handleClick(ev[3],ev[4],ev[5])
      draw()
    end

    -- Tick update
    local now = computer.uptime()
    if now - lastDraw >= 0.5 then
      lastDraw = now
      state.anim = state.anim + 1
      state.dots = state.dots + 1

      -- Advance the green server-check progress (0,5,10,...,35%)
      if state.screen == "checking" then
        if state.checkPct < 35 then
          state.checkPct = math.min(35, state.checkPct + 5)
        else
          -- Decide the outcome now that the "check" has finished
          local hours = WAIT_RULES[math.random(1,#WAIT_RULES)]
          local users = loadUsers()
          if hours == 0 then
            state.outcome = "instant"
            state.screen = "unlocking"
            state.unlockPct = 0
            if users[state.user] then
              users[state.user].waitDone = false
              users[state.user].waitHours = 0
              users[state.user].waitStartReal = 0
              saveUsers(users)
            end
          else
            state.outcome = "wait"
            state.waitHours = hours
            state.waitStart = computer.uptime()
            if users[state.user] then
              users[state.user].waitDone = false
              users[state.user].waitHours = hours
              users[state.user].waitStartReal = computer.uptime()
              saveUsers(users)
            end
            state.screen = "waiting"
          end
        end
      end

      -- Advance unlock progress
      if state.screen == "unlocking" then
        state.unlockPct = math.min(100, state.unlockPct + math.random(1,4))
      end

      draw()
    end
  end

  -- Cleanup
  set(0xFFFFFF,0x000000)
  gpu.fill(1,1,W,H," ")
end

main()
