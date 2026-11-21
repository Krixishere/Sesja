-- Atrapa API REAPERa do testów end-to-end skryptu ReaperMultiplayer.lua.
-- Uruchamiana przez tests/run_e2e.py:  lua5.4 tests/mock_reaper.lua <rola> <katalog> <serwer>
-- Projekt trzymany jest jako chunki – dokładnie tak, jak widzi go skrypt w REAPERze.

local ROLE, DIR, SERVER = arg[1], arg[2], arg[3]
package.path = "./?.lua;" .. package.path
local M = dofile("reaper/ReaperMultiplayer.lua") -- tryb testowy (bez globalnego reaper)
local json = M.json

local function uptime()
  local f = io.open("/proc/uptime")
  local v = f:read("n")
  f:close()
  return v
end
local T0 = uptime()
local function clock() return uptime() - T0 end

local function log(...) io.stderr:write("[" .. ROLE .. string.format(" %5.1f] ", clock()), table.concat({ ... }, " "), "\n") end

-------------------------------------------------------------------------------
local P = { tracks = {}, cc = 0, markers = {}, tempos = {}, ext = {}, projext = {}, bpm = 120, cursor = 0, undo = {} }
local function bump() P.cc = P.cc + 1 end

local function split_track(chunk)
  local header, items = {}, {}
  local depth, cur, idepth = 0, nil, 0
  for line in (chunk:gsub("\r", "") .. "\n"):gmatch("(.-)\n") do
    local l = line:gsub("^%s+", "")
    if l ~= "" then
      if cur then
        cur[#cur + 1] = l
        if l:sub(1, 1) == "<" then idepth = idepth + 1 elseif l == ">" then idepth = idepth - 1 end
        if idepth == 0 then items[#items + 1] = table.concat(cur, "\n"); cur = nil end
      elseif depth == 1 and l:sub(1, 5) == "<ITEM" then
        cur, idepth = { l }, 1
      else
        header[#header + 1] = l
        if l:sub(1, 1) == "<" then depth = depth + 1 elseif l == ">" then depth = depth - 1 end
      end
    end
  end
  return header, items
end

local guidN = 0
local function newguid()
  guidN = guidN + 1
  return string.format("{%s%07d-0000-0000-0000-000000000000}", ROLE, guidN)
end

local function item_guid(it) return it.chunk:match("IGUID%s+(%S+)") end
local function set_line(chunk, key, value) -- linia na głębokości 1
  local lines, done, depth = {}, false, 0
  for l in (chunk .. "\n"):gmatch("(.-)\n") do
    if depth == 1 and not done and l:match("^" .. key .. "%s") then
      l = key .. " " .. value
      done = true
    end
    lines[#lines + 1] = l
    if l:sub(1, 1) == "<" then depth = depth + 1 elseif l == ">" then depth = depth - 1 end
  end
  if not done then table.insert(lines, 2, key .. " " .. value) end
  return table.concat(lines, "\n")
end
local function get_line(chunk, key)
  return M.chunk_field(chunk, key)
end

local function new_item(chunk, tr)
  local it = { chunk = chunk, track = tr, valid = true }
  if not item_guid(it) then it.chunk = set_line(it.chunk, "IGUID", newguid()) end
  return it
end

local function track_chunk(tr)
  local out = {}
  for i = 1, #tr.header - 1 do out[#out + 1] = tr.header[i] end
  for _, it in ipairs(tr.items) do out[#out + 1] = it.chunk end
  out[#out + 1] = ">"
  return table.concat(out, "\n") .. "\n"
end

local function set_track_chunk(tr, chunk)
  local h, items = split_track(chunk)
  for _, it in ipairs(tr.items) do it.valid = false end
  tr.header = h
  tr.items = {}
  for _, ic in ipairs(items) do tr.items[#tr.items + 1] = new_item(ic, tr) end
  local g = M.chunk_field(table.concat(h, "\n"), "TRACKID")
  if g then tr.guid = g end
  bump()
end

local function make_track(name)
  local g = newguid()
  local tr = { items = {}, valid = true, sel = false }
  set_track_chunk(tr, table.concat({
    "<TRACK", 'NAME "' .. name .. '"', "PEAKCOL 16576", "VOLPAN 1 0 -1 -1 1", "MUTESOLO 0 0 0",
    "SEL 0", "REC 0 0 1 0 0 0 0 0", "TRACKHEIGHT 0 0 0 0 0 0", "TRACKID " .. g, "MAINSEND 1 0", ">",
  }, "\n"))
  return tr
end

local function audio_item_chunk(path, pos, len)
  return table.concat({
    "<ITEM", "POSITION " .. pos, "LENGTH " .. len, "SEL 0", "IGUID " .. newguid(), "IID 1",
    "NAME " .. (path:match("([^/]+)$")), "VOLPAN 1 0 1 -1", "GUID " .. newguid(),
    "<SOURCE WAVE", 'FILE "' .. path .. '"', ">", ">",
  }, "\n")
end

-------------------------------------------------------------------------------
reaper = {}
local r = reaper
local deferred, atexitfn

function r.GetOS() return "Linux" end
function r.GetExtState(s, k) return P.ext[s .. k] or "" end
function r.SetExtState(s, k, v) P.ext[s .. k] = v end
function r.GetResourcePath() return DIR .. "/resource" end
function r.RecursiveCreateDirectory(p) os.execute('mkdir -p "' .. p .. '"') return 1 end
function r.EnumerateFiles(p, i)
  local h = io.popen('ls -1 "' .. p .. '" 2>/dev/null')
  local n = 0
  for l in h:lines() do
    if n == i then h:close() return l end
    n = n + 1
  end
  h:close()
  return nil
end
function r.EnumProjects() return 0, DIR .. "/project/projekt.rpp" end
function r.GetProjectPath() return DIR .. "/project" end
function r.CountTracks() return #P.tracks end
function r.GetTrack(_, i) return P.tracks[i + 1] end
function r.GetTrackGUID(tr) return tr.guid end
function r.GetTrackName(tr)
  for _, l in ipairs(tr.header) do local n = l:match('^%s*NAME "?([^"]*)"?') if n then return true, n end end
  return true, ""
end
function r.GetTrackStateChunk(tr) return true, track_chunk(tr) end
function r.SetTrackStateChunk(tr, c) set_track_chunk(tr, c) return true end
function r.GetSetMediaTrackInfo_String(tr, k, v, set)
  if k == "GUID" then
    if set then
      tr.guid = v
      tr.header = split_track(set_line(table.concat(tr.header, "\n"), "TRACKID", v))
    end
    return true, tr.guid
  elseif k == "P_NAME" then
    if set then
      tr.header = split_track(set_line(table.concat(tr.header, "\n"), "NAME", '"' .. v .. '"'))
      bump()
    end
    return true, M.unquote(get_line(table.concat(tr.header, "\n"), "NAME") or "")
  end
  return false, ""
end
local function track_idx(tr) for i, t in ipairs(P.tracks) do if t == tr then return i end end end
function r.GetMediaTrackInfo_Value(tr, k)
  if k == "IP_TRACKNUMBER" then return track_idx(tr) end
  return 0
end
function r.SetMediaTrackInfo_Value(tr, k, v)
  local h = table.concat(tr.header, "\n")
  local vp = M.tokens(get_line(h, "VOLPAN") and ("VOLPAN " .. get_line(h, "VOLPAN")) or "VOLPAN 1 0 -1 -1 1")
  if k == "D_VOL" then vp[2] = tostring(v) elseif k == "D_PAN" then vp[3] = tostring(v) end
  table.remove(vp, 1)
  tr.header = split_track(set_line(h, "VOLPAN", table.concat(vp, " ")))
  bump()
  return true
end
local function all_items()
  local t = {}
  for _, tr in ipairs(P.tracks) do for _, it in ipairs(tr.items) do t[#t + 1] = it end end
  return t
end
function r.CountMediaItems() return #all_items() end
function r.GetMediaItem(_, i) return all_items()[i + 1] end
function r.GetSetMediaItemInfo_String(it, k, v, set)
  if k == "GUID" then
    if set then it.chunk = set_line(it.chunk, "IGUID", v) end
    return true, item_guid(it)
  end
  return false, ""
end
function r.GetItemStateChunk(it) return true, it.chunk end
function r.SetItemStateChunk(it, c)
  it.chunk = c:gsub("\n$", "")
  bump()
  return true
end
function r.GetMediaItemInfo_Value(it, k)
  if k == "I_CUSTOMCOLOR" then return tonumber((get_line(it.chunk, "COLOR") or "0"):match("%d+")) or 0 end
  return 0
end
function r.SetMediaItemInfo_Value(it, k, v)
  if k == "I_CUSTOMCOLOR" then it.chunk = set_line(it.chunk, "COLOR", string.format("%d B", v)) end
  bump()
  return true
end
function r.AddMediaItemToTrack(tr)
  local it = new_item("<ITEM\nPOSITION 0\nLENGTH 1\n>", tr)
  tr.items[#tr.items + 1] = it
  bump()
  return it
end
function r.MoveMediaItemToTrack(it, tr)
  for i, x in ipairs(it.track.items) do if x == it then table.remove(it.track.items, i) break end end
  tr.items[#tr.items + 1] = it
  it.track = tr
  bump()
  return true
end
function r.DeleteTrackMediaItem(tr, it)
  for i, x in ipairs(tr.items) do if x == it then table.remove(tr.items, i) break end end
  it.valid = false
  bump()
  return true
end
function r.GetMediaItem_Track(it) return it.track end
function r.ValidatePtr2(_, p) return p and p.valid end
function r.InsertTrackAtIndex(i)
  local tr = make_track("")
  table.insert(P.tracks, i + 1, tr)
  bump()
end
function r.DeleteTrack(tr)
  local i = track_idx(tr)
  if i then table.remove(P.tracks, i) end
  tr.valid = false
  for _, it in ipairs(tr.items) do it.valid = false end
  bump()
end
function r.CountSelectedTracks() local n = 0 for _, t in ipairs(P.tracks) do if t.sel then n = n + 1 end end return n end
function r.GetSelectedTrack(_, i)
  local n = 0
  for _, t in ipairs(P.tracks) do
    if t.sel then
      if n == i then return t end
      n = n + 1
    end
  end
end
function r.SetOnlyTrackSelected(tr) for _, t in ipairs(P.tracks) do t.sel = (t == tr) end end
function r.SetTrackSelected(tr, s) tr.sel = s end
function r.ReorderSelectedTracks(before)
  local sel, rest = {}, {}
  local b = before
  for i, t in ipairs(P.tracks) do
    if t.sel then
      sel[#sel + 1] = t
      if i - 1 < before then b = b - 1 end
    else
      rest[#rest + 1] = t
    end
  end
  for k, t in ipairs(sel) do table.insert(rest, b + k, t) end
  P.tracks = rest
  bump()
  return true
end
function r.CountTempoTimeSigMarkers() return #P.tempos end
function r.GetTempoTimeSigMarker(_, i)
  local t = P.tempos[i + 1]
  return true, t.pos, 0, 0, t.bpm, t.num, t.den, t.lin
end
function r.SetTempoTimeSigMarker(_, _, pos, _, _, bpm, num, den, lin)
  P.tempos[#P.tempos + 1] = { pos = pos, bpm = bpm, num = num, den = den, lin = lin } bump() return true
end
function r.DeleteTempoTimeSigMarker(_, i) table.remove(P.tempos, i + 1) bump() return true end
function r.GetMasterTrack() return P.master end
function r.SetCurrentBPM(_, bpm) P.bpm = bpm bump() end
function r.GetProjectTimeSignature2() return P.bpm, 4 end
function r.PreventUIRefresh() end
function r.Undo_BeginBlock2() end
function r.Undo_EndBlock2(_, name) P.undo[#P.undo + 1] = name end
function r.TrackList_AdjustWindows() end
function r.UpdateArrange() end
function r.UpdateTimeline() end
function r.CountProjectMarkers() return #P.markers, #P.markers, 0 end
function r.EnumProjectMarkers(i)
  local m = P.markers[i + 1]
  if not m then return 0 end
  return i + 1, m.rgn, m.pos, m.rend, m.name, m.idx
end
function r.EnumProjectMarkers3(_, i)
  local m = P.markers[i + 1]
  if not m then return 0 end
  return i + 1, m.rgn, m.pos, m.rend, m.name, m.idx, m.color
end
function r.DeleteProjectMarkerByIndex(_, i) table.remove(P.markers, i + 1) bump() return true end
function r.AddProjectMarker2(_, rgn, pos, rend, name, idx, color)
  if not idx or idx < 0 then idx = #P.markers + 1 end
  P.markers[#P.markers + 1] = { rgn = rgn or false, pos = pos, rend = rend or 0, name = name, idx = idx, color = color or 0 }
  bump()
  return idx
end
function r.SetProjExtState(_, s, k, v) P.projext[s .. k] = v end
function r.GetProjExtState(_, s, k) return 1, P.projext[s .. k] or "" end
function r.ColorToNative(rr, gg, bb) return rr + gg * 256 + bb * 65536 end
function r.GetPlayState() return 0 end
function r.GetPlayPosition() return 0 end
function r.GetCursorPosition() return P.cursor end
function r.SetEditCurPos(p) P.cursor = p end
function r.GetProjectStateChangeCount() return P.cc end
function r.ShowMessageBox() return 6 end
function r.GetUserInputs() return false, "" end
function r.ExecProcess(cmd) os.execute(cmd .. " >/dev/null 2>&1 &") return "" end
function r.time_precise() return clock() end
function r.defer(fn) deferred = fn end
function r.atexit(fn) atexitfn = fn end
function r.GetSelectedMediaItem() return nil end
function r.GetActiveTake() return nil end
function r.GetTakeName() return "" end

-- gfx -------------------------------------------------------------------------
local keyq = {}
-- gfx: zapisujemy polecenia rysowania ostatniej klatki (RMP_RECORD=1 -> ui_frame.json),
-- żeby dało się obejrzeć wygląd okna moda bez REAPERa (tests/render_mod_ui.js)
local FONTS, curFont, frame, lastFrame = {}, 1, {}, {}
local function rec(op) frame[#frame + 1] = op end
gfx = { w = 600, h = 700, mouse_cap = 0, mouse_x = -1, mouse_y = -1, mouse_wheel = 0, x = 0, y = 0, clear = 0 }
function gfx.init() end
function gfx.setfont(i, face, size, flags)
  if face then FONTS[i] = { face = face, size = size, bold = flags ~= nil } end
  curFont = i
end
function gfx.set(r, g, b, a) rec({ "set", r, g, b, a or 1 }) end
function gfx.rect(x, y, w, h, f) rec({ "rect", x, y, w, h, f == nil and 1 or f }) end
function gfx.circle(x, y, r, f) rec({ "circle", x, y, r, f or 0 }) end
function gfx.roundrect(x, y, w, h, r) rec({ "roundrect", x, y, w, h, r }) end
function gfx.triangle(...) rec({ "triangle", ... }) end
function gfx.line(x1, y1, x2, y2) rec({ "line", x1, y1, x2, y2 }) end
function gfx.measurestr(s)
  local f = FONTS[curFont] or { size = 14 }
  local n = utf8.len(s) or #s
  return n * f.size * (f.bold and 0.56 or 0.52), f.size * 1.2
end
function gfx.drawstr(s)
  local f = FONTS[curFont] or { size = 14 }
  rec({ "text", gfx.x, gfx.y, s, f.size, f.bold and 1 or 0 })
  gfx.x = gfx.x + gfx.measurestr(s)
end
function gfx.update() lastFrame = frame; frame = {} end
function gfx.showmenu() return 0 end
function gfx.dock() return 0, 0, 0, 0, 0 end
local closed = false
function gfx.getchar()
  if closed then return -1 end
  return table.remove(keyq, 1) or 0
end
local function type_text(s)
  for _, c in utf8.codes(s) do
    keyq[#keyq + 1] = c < 128 and c or (0x75000000 + c)
  end
  keyq[#keyq + 1] = 13
end

-------------------------------------------------------------------------------
-- Konfiguracja i scenariusze
-------------------------------------------------------------------------------
local S = "ReaperMultiplayer"
P.ext[S .. "server"] = SERVER
P.ext[S .. "room"] = os.getenv("RMP_ROOM") or "test"
P.ext[S .. "user"] = ROLE == "A" and "Ania" or "Bartek"
P.ext[S .. "interval"] = "0.3"
-- RMP_ASK=1: mod pyta o nowe ścieżki (bez odpowiedzi nowe ścieżki zostają lokalne)
P.ext[S .. "ask_tracks"] = os.getenv("RMP_ASK") or "0"
P.ext[S .. "password"] = os.getenv("RMP_PASSWORD") or ""
-- RMP_ADMIN: klucz gospodarza – dostaje go tylko Ania (A); Bartek jest edytorem
if ROLE == "A" then P.ext[S .. "admin_key"] = os.getenv("RMP_ADMIN") or "" end
P.ext[S .. "lang"] = ROLE == "A" and "pl" or "en" -- Ania po polsku, Bartek po angielsku
os.execute('mkdir -p "' .. DIR .. '/project"')

-- prawdziwy plik WAV (mono, 16 bit, 44.1 kHz) z sinusem o losowej wysokości
local function write_wav(path, bytes)
  local n = bytes // 2
  local freq = 180 + math.random(0, 300)
  local data = {}
  for i = 0, n - 1 do
    local env = math.min(1, i / 2000) * (0.55 + 0.45 * math.sin(i / 9000))
    data[#data + 1] = string.pack("<i2", math.floor(math.sin(2 * math.pi * freq * i / 44100) * 12000 * env))
  end
  local pcm = table.concat(data)
  local f = io.open(path, "wb")
  f:write("RIFF", string.pack("<I4", 36 + #pcm), "WAVEfmt ", string.pack("<I4I2I2I4I4I2I2", 16, 1, 1, 44100, 88200, 2, 16),
    "data", string.pack("<I4", #pcm), pcm)
  f:close()
end

local steps = {}
local function at(t, fn) steps[#steps + 1] = { t = t, fn = fn } end

local function find_track(name)
  for _, tr in ipairs(P.tracks) do
    local _, n = r.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    if n == name then return tr end
  end
end

P.master = make_track("MASTER")

if ROLE == "A" then
  at(5, function()
    -- Ania: region refrenu, marker, mapa tempa i limiter na masterze
    r.AddProjectMarker2(0, true, 10, 20, "Refren", 1, 0)
    r.AddProjectMarker2(0, false, 30, 0, "Drop", 2, 0)
    r.SetTempoTimeSigMarker(0, -1, 0, -1, -1, 140, 4, 4, false)
    local h = P.master.header
    table.insert(h, #h, "<FXCHAIN")
    table.insert(h, #h, "<JS limiter \"\"")
    table.insert(h, #h, ">")
    table.insert(h, #h, ">")
    bump()
  end)
  -- Ania ma już projekt: ścieżka "Wokal" z nagraniem
  local wav = DIR .. "/project/vocal take.wav"
  write_wav(wav, 300000)
  local tr = make_track("Wokal")
  P.tracks[1] = tr
  tr.items[1] = new_item(audio_item_chunk(wav, 2, 4), tr)
  bump()
  at(4, function() type_text("Cześć Bartek, wrzuć gitarę!") end)
  at(7, function()
    P.cursor = 12.5
    -- komentarz: wpisujemy tekst bez Entera i... komentarze idą przyciskiem, więc symulujemy czatem
    type_text("Refren od 0:12 jest za cichy")
  end)
  at(9, function()
    -- Ania zmienia głośność ścieżki Wokal
    r.SetMediaTrackInfo_Value(find_track("Wokal"), "D_VOL", 0.5)
  end)
else
  at(3.5, function()
    -- Bartek nagrał gitarę na nowej ścieżce
    local wav = DIR .. "/project/gitara.wav"
    write_wav(wav, tonumber(os.getenv("RMP_BIG") or "") or 200000)
    local tr = make_track("Gitara")
    P.tracks[#P.tracks + 1] = tr
    tr.items[1] = new_item(audio_item_chunk(wav, 0, 8), tr)
    bump()
  end)
  at(6, function()
    -- Bartek przesuwa klip Ani
    local w = find_track("Wokal")
    if w and w.items[1] then
      w.items[1].chunk = set_line(w.items[1].chunk, "POSITION", "3")
      bump()
    end
  end)
  at(8, function()
    -- Bartek zmienia nazwę swojej ścieżki
    r.GetSetMediaTrackInfo_String(find_track("Gitara"), "P_NAME", "Gitara akustyczna", true)
  end)
  at(9, function()
    -- Bartek: szyna z pogłosem i wysyłka z gitary
    local bus = make_track("Pogłos")
    P.tracks[#P.tracks + 1] = bus
    local src = 0
    for i, tr in ipairs(P.tracks) do if tr == find_track("Gitara akustyczna") then src = i - 1 end end
    table.insert(bus.header, #bus.header, "AUXRECV " .. src .. " 0 0.5 0 0 0 0 0 0 -1:U 0 -1 ''")
    bump()
  end)
end

-------------------------------------------------------------------------------
-- Uruchomienie skryptu jak w REAPERze
-------------------------------------------------------------------------------
local startDelay = ROLE == "A" and 0 or 2
while clock() < startDelay do os.execute("sleep 0.05") end

local src = io.open("reaper/ReaperMultiplayer.lua"):read("a")
local chunkfn = assert(load(src, "@ReaperMultiplayer.lua"))
chunkfn()

local END = tonumber(os.getenv("RMP_END") or "") or 14
while clock() < END do
  for i = #steps, 1, -1 do
    if clock() >= steps[i].t then
      local s = table.remove(steps, i)
      s.fn()
    end
  end
  local fn = deferred
  deferred = nil
  if fn then fn() end
  os.execute("sleep 0.03")
end
closed = true
if deferred then deferred() end
if atexitfn then atexitfn() end

-- zrzut stanu projektu
local out = { tracks = {}, markers = P.markers, tempos = P.tempos, bpm = P.bpm, undo = P.undo,
  master = table.concat(P.master.header, "\n") }
for _, tr in ipairs(P.tracks) do
  local h = table.concat(tr.header, "\n")
  local t = {
    guid = tr.guid, name = M.unquote(get_line(h, "NAME") or ""), volpan = get_line(h, "VOLPAN"),
    rec = get_line(h, "REC"), items = {}, auxrecv = get_line(h, "AUXRECV"),
  }
  for _, it in ipairs(tr.items) do
    local file = it.chunk:match('FILE "([^"]+)"')
    local f = file and io.open(file, "rb")
    local size = f and f:seek("end")
    if f then f:close() end
    t.items[#t.items + 1] = {
      guid = item_guid(it), pos = tonumber(get_line(it.chunk, "POSITION")), file = file,
      size = size, color = get_line(it.chunk, "COLOR"),
    }
  end
  out.tracks[#out.tracks + 1] = t
end
if os.getenv("RMP_RECORD") then
  local fr = io.open(DIR .. "/ui_frame.json", "w")
  fr:write(json.encode({ w = gfx.w, h = gfx.h, ops = lastFrame }))
  fr:close()
end
local f = io.open(DIR .. "/result.json", "w")
f:write(json.encode(out))
f:close()
log("koniec, ścieżek:", #P.tracks)
