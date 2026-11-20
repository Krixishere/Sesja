-- @description REAPER Multiplayer – wspólna praca nad jednym projektem przez serwer
-- @version 1.0.0
-- @author RMP
-- @about
--   Łączy REAPERa z serwerem RMP (server/rmp_server.py). Wszystkie zmiany ścieżek,
--   klipów (audio i MIDI), FX, głośności itp. są automatycznie wysyłane do pozostałych
--   osób w tym samym pokoju. Nagrane pliki audio wysyłane są w tle – nikt nie musi
--   niczego ręcznie przesyłać. Okno skryptu pokazuje, kto jest online, kto co dodał,
--   czat i komentarze przypięte do miejsca na osi czasu.
--
--   Wymagania: REAPER 6.0+, program curl (wbudowany w Windows 10/11 i macOS).

local VERSION = "1.0.0"
local M = {}

-------------------------------------------------------------------------------
-- JSON (mały, samowystarczalny koder/dekoder)
-------------------------------------------------------------------------------
local json = {}
do
  local ARR = {}
  function json.array(t) return setmetatable(t or {}, ARR) end

  local escmap = {
    ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
    ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
  }
  local function enc_str(s)
    return '"' .. (s:gsub('[%c"\\]', function(c)
      return escmap[c] or string.format("\\u%04x", c:byte())
    end)) .. '"'
  end

  local function enc(v, out)
    local tv = type(v)
    if v == nil then
      out[#out + 1] = "null"
    elseif tv == "boolean" then
      out[#out + 1] = v and "true" or "false"
    elseif tv == "number" then
      if v ~= v or v == math.huge or v == -math.huge then
        out[#out + 1] = "0"
      elseif math.type(v) == "integer" then
        out[#out + 1] = string.format("%d", v)
      else
        out[#out + 1] = string.format("%.14g", v)
      end
    elseif tv == "string" then
      out[#out + 1] = enc_str(v)
    elseif tv == "table" then
      if getmetatable(v) == ARR or v[1] ~= nil then
        out[#out + 1] = "["
        for i = 1, #v do
          if i > 1 then out[#out + 1] = "," end
          enc(v[i], out)
        end
        out[#out + 1] = "]"
      else
        out[#out + 1] = "{"
        local first = true
        for k, val in pairs(v) do
          local tk = type(k)
          if tk == "string" or tk == "number" then
            if not first then out[#out + 1] = "," end
            first = false
            out[#out + 1] = enc_str(tostring(k))
            out[#out + 1] = ":"
            enc(val, out)
          end
        end
        out[#out + 1] = "}"
      end
    else
      out[#out + 1] = "null"
    end
  end

  function json.encode(v)
    local out = {}
    enc(v, out)
    return table.concat(out)
  end

  local function skip(s, i)
    local _, e = s:find("^[ \n\r\t]*", i)
    return e + 1
  end

  local simple = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

  local function parse_str(s, i)
    -- s:sub(i,i) == '"'
    local out = {}
    i = i + 1
    while true do
      local j = s:find('["\\]', i)
      if not j then error("niezakończony string") end
      out[#out + 1] = s:sub(i, j - 1)
      if s:sub(j, j) == '"' then return table.concat(out), j + 1 end
      local c = s:sub(j + 1, j + 1)
      if c == "u" then
        local cp = tonumber(s:sub(j + 2, j + 5), 16) or 63
        local nj = j + 6
        if cp >= 0xD800 and cp <= 0xDBFF and s:sub(nj, nj + 1) == "\\u" then
          local lo = tonumber(s:sub(nj + 2, nj + 5), 16)
          if lo and lo >= 0xDC00 and lo <= 0xDFFF then
            cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
            nj = nj + 6
          end
        end
        out[#out + 1] = utf8.char(cp)
        i = nj
      else
        out[#out + 1] = simple[c] or c
        i = j + 2
      end
    end
  end

  local parse
  parse = function(s, i)
    i = skip(s, i)
    local c = s:sub(i, i)
    if c == "{" then
      local t = {}
      i = skip(s, i + 1)
      if s:sub(i, i) == "}" then return t, i + 1 end
      while true do
        i = skip(s, i)
        if s:sub(i, i) ~= '"' then error("oczekiwano klucza") end
        local k
        k, i = parse_str(s, i)
        i = skip(s, i)
        if s:sub(i, i) ~= ":" then error("oczekiwano :") end
        local v
        v, i = parse(s, i + 1)
        t[k] = v
        i = skip(s, i)
        local d = s:sub(i, i)
        if d == "," then
          i = i + 1
        elseif d == "}" then
          return t, i + 1
        else
          error("oczekiwano , lub }")
        end
      end
    elseif c == "[" then
      local t = json.array({})
      local n = 0
      i = skip(s, i + 1)
      if s:sub(i, i) == "]" then return t, i + 1 end
      while true do
        local v
        v, i = parse(s, i)
        n = n + 1
        t[n] = v
        i = skip(s, i)
        local d = s:sub(i, i)
        if d == "," then
          i = i + 1
        elseif d == "]" then
          return t, i + 1
        else
          error("oczekiwano , lub ]")
        end
      end
    elseif c == '"' then
      return parse_str(s, i)
    elseif s:sub(i, i + 3) == "true" then
      return true, i + 4
    elseif s:sub(i, i + 4) == "false" then
      return false, i + 5
    elseif s:sub(i, i + 3) == "null" then
      return nil, i + 4
    else
      local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
      if not num or num == "" then error("nieoczekiwany znak przy " .. i) end
      return tonumber(num), i + #num
    end
  end

  function json.decode(s)
    if type(s) ~= "string" then return nil end
    local ok, v = pcall(parse, s, 1)
    if ok then return v end
    return nil
  end
end
M.json = json

-------------------------------------------------------------------------------
-- Przetwarzanie "chunków" REAPERa (czyste funkcje – testowalne poza REAPERem)
-------------------------------------------------------------------------------
local function trim_left(s) return (s:gsub("^%s+", "")) end
local function first_token(line) return line:match("^(%S+)") end

local function unquote(s)
  s = s or ""
  local q = s:sub(1, 1)
  if (q == '"' or q == "'" or q == "`") and #s >= 2 and s:sub(-1) == q then
    return s:sub(2, -2)
  end
  return s
end
M.unquote = unquote

local function split_lines(s)
  s = s:gsub("\r", "")
  if s:sub(-1) ~= "\n" then s = s .. "\n" end
  local t = {}
  for line in s:gmatch("(.-)\n") do t[#t + 1] = line end
  while #t > 0 and t[#t]:match("^%s*$") do t[#t] = nil end
  return t
end
M.split_lines = split_lines

-- Linie ścieżki, które są "lokalne" dla danego komputera (zaznaczenie, wysokość,
-- uzbrojenie do nagrywania, wyjścia sprzętowe) – nie są synchronizowane.
local TRACK_LOCAL = {
  SEL = true, TRACKHEIGHT = true, REC = true, HWOUT = true, MIDIHWOUT = true, BUSCOMP = true,
}
-- Stan okien FX (pozycja, czy otwarte) – też tylko lokalnie.
local FX_UI = {
  FLOATPOS = true, FLOAT = true, FLOATING = true, WNDRECT = true, SHOW = true,
  LASTSEL = true, DOCKED = true,
}
local ITEM_LOCAL = { SEL = true, IID = true }

local function is_open(line) return line:sub(1, 1) == "<" end
local function is_close(line) return line == ">" end

--- Rozbija chunk ścieżki na: znormalizowany nagłówek (bez klipów i bez linii lokalnych),
--- listę linii lokalnych oraz listę chunków klipów.
function M.normalize_track(chunk)
  local header, locals, items = {}, {}, {}
  local depth, cur, idepth = 0, nil, 0
  for _, raw in ipairs(split_lines(chunk)) do
    local line = trim_left(raw)
    if cur then
      cur[#cur + 1] = line
      if is_open(line) then
        idepth = idepth + 1
      elseif is_close(line) then
        idepth = idepth - 1
      end
      if idepth == 0 then
        items[#items + 1] = table.concat(cur, "\n")
        cur = nil
      end
    elseif depth == 1 and line:sub(1, 5) == "<ITEM" then
      cur, idepth = { line }, 1
    else
      local key = first_token(line) or ""
      if depth == 1 and TRACK_LOCAL[key] then
        locals[#locals + 1] = line
      elseif depth >= 2 and FX_UI[key] then
        -- pomijamy
      else
        header[#header + 1] = line
      end
      if is_open(line) then
        depth = depth + 1
      elseif is_close(line) then
        depth = depth - 1
      end
    end
  end
  return table.concat(header, "\n"), locals, items
end

--- Składa chunk ścieżki z nagłówka (np. otrzymanego z serwera), lokalnych linii i klipów.
function M.build_track_chunk(header, locals, items)
  local h = split_lines(header)
  local out = { h[1] or "<TRACK" }
  for _, l in ipairs(locals or {}) do out[#out + 1] = l end
  local last = #h
  if h[last] ~= ">" then last = last + 1 end -- uszkodzony nagłówek – dopisz zamknięcie
  for i = 2, last - 1 do out[#out + 1] = h[i] end
  for _, it in ipairs(items or {}) do out[#out + 1] = it end
  out[#out + 1] = ">"
  return table.concat(out, "\n") .. "\n"
end

--- Normalizuje chunk klipu: usuwa linie lokalne i zamienia ścieżki plików na
--- referencje "rmp:<id>" (path_to_ref(path) -> id, abs_path).
function M.normalize_item(chunk, path_to_ref)
  local out, refs = {}, {}
  local depth, guid = 0, nil
  for _, raw in ipairs(split_lines(chunk)) do
    local line = trim_left(raw)
    local key = first_token(line) or ""
    local skipit = false
    if depth == 1 and ITEM_LOCAL[key] then
      skipit = true
    elseif depth >= 2 and FX_UI[key] then
      skipit = true
    elseif depth == 1 and key == "IGUID" then
      guid = line:match("^IGUID%s+(%S+)")
    elseif key == "FILE" and path_to_ref then
      local p, rest = line:match('^FILE%s+"(.-)"(.*)$')
      if not p then p, rest = line:match("^FILE%s+(%S+)(.*)$") end
      if p and p:sub(1, 4) ~= "rmp:" then
        local id, abs = path_to_ref(p)
        if id then
          refs[id] = abs or p
          line = 'FILE "rmp:' .. id .. '"' .. (rest or "")
        end
      end
    end
    if not skipit then out[#out + 1] = line end
    if is_open(line) then
      depth = depth + 1
    elseif is_close(line) then
      depth = depth - 1
    end
  end
  return table.concat(out, "\n"), refs, guid
end

--- Zamienia referencje "rmp:<id>" z powrotem na lokalne ścieżki.
--- Zwraca chunk oraz listę brakujących plików.
function M.denormalize_item(chunk, ref_to_path)
  local missing = {}
  local out = chunk:gsub('FILE "rmp:([^"]+)"', function(id)
    local p = ref_to_path(id)
    if p then return 'FILE "' .. p .. '"' end
    missing[#missing + 1] = id
    return nil
  end)
  return out, missing
end

--- Zwraca wartość pierwszej linii z danym kluczem na głębokości 1.
function M.chunk_field(chunk, key)
  local depth = 0
  for line in (chunk .. "\n"):gmatch("(.-)\n") do
    line = trim_left(line)
    if depth == 1 then
      local k, rest = line:match("^(%S+)%s*(.*)$")
      if k == key then return rest end
    end
    if is_open(line) then
      depth = depth + 1
    elseif is_close(line) then
      depth = depth - 1
    end
  end
  return nil
end

--- Rozbija linię chunka na tokeny (z obsługą cudzysłowów).
function M.tokens(line)
  local t, i, n = {}, 1, #line
  while i <= n do
    local c = line:sub(i, i)
    if c:match("%s") then
      i = i + 1
    elseif c == '"' or c == "'" or c == "`" then
      local j = line:find(c, i + 1, true) or (n + 1)
      t[#t + 1] = line:sub(i + 1, j - 1)
      i = j + 1
    else
      local j = line:find("%s", i) or (n + 1)
      t[#t + 1] = line:sub(i, j - 1)
      i = j
    end
  end
  return t
end

--- Identyfikator pliku audio: nazwa~rozmiar~hash(początek+koniec).rozszerzenie
function M.file_id(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local size = f:seek("end")
  local h = 2166136261
  local function feed(data)
    for i = 1, #data do
      h = ((h ~ data:byte(i)) * 16777619) & 0xffffffff
    end
  end
  f:seek("set", 0)
  feed(f:read(65536) or "")
  if size > 65536 then
    f:seek("set", math.max(65536, size - 65536))
    feed(f:read(65536) or "")
  end
  f:close()
  local name = path:match("([^/\\]+)$") or "plik"
  local base, ext = name:match("^(.*)(%.[^.]+)$")
  if not base then base, ext = name, "" end
  base = base:gsub("[^A-Za-z0-9._%-]", "_"):sub(1, 60)
  ext = ext:gsub("[^A-Za-z0-9.]", "")
  return string.format("%s~%d~%08x%s", base, size, h, ext), size
end

function M.id_size(id) return tonumber(id:match("~(%d+)~%x+")) end

function M.fmt_pos(sec)
  sec = math.max(0, sec or 0)
  local h = math.floor(sec / 3600)
  local m = math.floor(sec / 60) % 60
  local s = math.floor(sec) % 60
  if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
  return string.format("%d:%02d", m, s)
end

-- Tryb testowy: poza REAPERem zwracamy tylko czyste funkcje.
if not reaper then return M end

-------------------------------------------------------------------------------
-- Od tego miejsca: kod działający w REAPERze
-------------------------------------------------------------------------------
local r = reaper
local SEC = "ReaperMultiplayer"
local MARK = "\u{1F4AC} " -- 💬 prefiks markerów-komentarzy
local IS_WIN = r.GetOS():match("Win") ~= nil
local SEP = IS_WIN and "\\" or "/"

local function now() return r.time_precise() end

local function get_ext(k, def)
  local v = r.GetExtState(SEC, k)
  if v == nil or v == "" then return def end
  return v
end
local function set_ext(k, v) r.SetExtState(SEC, k, tostring(v or ""), true) end

local CFG = {
  server = get_ext("server", "http://127.0.0.1:8765"),
  room = get_ext("room", "studio"),
  user = get_ext("user", ""),
  password = get_ext("password", ""),
  curl = get_ext("curl", IS_WIN and "curl.exe" or "curl"),
  interval = tonumber(get_ext("interval", "1.0")) or 1.0,
  colorize = get_ext("colorize", "1") == "1",
}

local S -- stan sesji (reset przy każdym połączeniu)
local function reset_state()
  S = {
    state = "off", -- off | connecting | on | error
    err = nil,
    cid = string.format("%08x%08x", math.random(0, 0x7fffffff), math.floor(os.time()) & 0x7fffffff),
    lastSeq = 0,
    baseTracks = {}, baseItems = {}, baseOrder = "", baseTempo = nil,
    meta = {}, names = {}, comments = {},
    users = {}, myColor = nil,
    outbox = {}, retryOps = nil,
    inflight = false, nextSync = 0,
    lastCC = -1,
    pending = {}, deferred = {},
    fileLocal = {}, fileConfirmed = {}, fileChecking = {},
    uploads = {}, downloads = {}, want = {}, uploadFails = {},
    lastPending = 0, lastSyncedSave = 0, syncedDirty = false,
    serverInfo = "",
  }
end
reset_state()
local FEED = {} -- czat / aktywność / komentarze (przeżywa rozłączenie)

local function feed_add(e)
  e.ts = e.ts or os.time()
  FEED[#FEED + 1] = e
  if #FEED > 600 then table.remove(FEED, 1) end
end

local function status_err(msg)
  S.err = msg
end

-------------------------------------------------------------------------------
-- Pliki tymczasowe, ścieżki
-------------------------------------------------------------------------------
local TMP = r.GetResourcePath() .. SEP .. "RMP_tmp"
r.RecursiveCreateDirectory(TMP, 0)
do -- sprzątanie po poprzednich uruchomieniach
  local i, names = 0, {}
  while true do
    local f = r.EnumerateFiles(TMP, i)
    if not f then break end
    names[#names + 1] = f
    i = i + 1
  end
  for _, f in ipairs(names) do os.remove(TMP .. SEP .. f) end
end

local function file_exists(p)
  local f = io.open(p, "rb")
  if f then f:close() return true end
  return false
end

local function file_size(p)
  local f = io.open(p, "rb")
  if not f then return nil end
  local s = f:seek("end")
  f:close()
  return s
end

local function read_file(p)
  local f = io.open(p, "rb")
  if not f then return nil end
  local d = f:read("a")
  f:close()
  return d
end

local function write_file(p, d)
  local f = io.open(p, "wb")
  if not f then return false end
  f:write(d)
  f:close()
  return true
end

local function is_abs(p)
  return p:sub(1, 1) == "/" or p:match("^%a:[\\/]") ~= nil or p:sub(1, 2) == "\\\\"
end

local function project_dir()
  local _, fn = r.EnumProjects(-1, "")
  if fn and fn ~= "" then
    return fn:match("^(.*)[/\\]") or r.GetProjectPath("")
  end
  return r.GetProjectPath("")
end

local function media_dir()
  local d = project_dir() .. SEP .. "RMP_media"
  r.RecursiveCreateDirectory(d, 0)
  return d
end

local idCache = {}
local function path_to_ref(p)
  local abs = p
  if not is_abs(p) then
    local c1 = project_dir() .. SEP .. p
    local c2 = r.GetProjectPath("") .. SEP .. p
    abs = file_exists(c1) and c1 or c2
  end
  local id = idCache[abs]
  if not id then
    if not file_exists(abs) then return nil end
    id = M.file_id(abs)
    if not id then return nil end
    idCache[abs] = id
  end
  return id, abs
end

local function ref_to_path(id)
  local lp = S.fileLocal[id]
  if lp and file_exists(lp) then return lp end
  local p = media_dir() .. SEP .. id
  local want = M.id_size(id)
  local sz = file_size(p)
  if sz and (not want or sz == want) then
    -- plik pobrany z serwera: zachowuje swój identyfikator i nie jest wysyłany ponownie
    idCache[p] = id
    S.fileConfirmed[id] = true
    return p
  end
  return nil
end

-------------------------------------------------------------------------------
-- Asynchroniczne HTTP przez curl (ExecProcess bez czekania + plik wynikowy)
-------------------------------------------------------------------------------
local jobs = {}
local jobCounter = 0

local function q(s) return '"' .. s .. '"' end

local function safe_key(s) return (s or ""):gsub("[^%w%._%-]", "") end

local function curl_base()
  local c = q(CFG.curl) .. " -s -S --connect-timeout 6"
  if CFG.password ~= "" then c = c .. " -H " .. q("X-RMP-Key: " .. safe_key(CFG.password)) end
  return c
end

local function url(path) return (CFG.server:gsub("/+$", "")) .. path end

local function new_tmp(ext)
  jobCounter = jobCounter + 1
  return TMP .. SEP .. S.cid .. "_" .. jobCounter .. "." .. ext
end

local function run(cmd)
  -- -1 = nie czekaj na zakończenie; wynik odczytujemy z pliku. Wartość zwracana
  -- przy -1 nie jest wiarygodna, więc błędy wykrywamy przez timeout.
  r.ExecProcess(cmd, -1)
  return true
end

-- Żądanie JSON. cb(resp|nil, err)
local function http_json(method, path, body, cb, timeout)
  timeout = timeout or 25
  local out = new_tmp("json")
  local cmd = curl_base() .. " --max-time " .. math.floor(timeout) .. " -o " .. q(out)
  if body then
    local inp = new_tmp("req")
    write_file(inp, json.encode(body))
    cmd = cmd .. " -X " .. method .. " -H " .. q("Content-Type: application/json") ..
      " --data-binary " .. q("@" .. inp)
    jobs[#jobs + 1] = { kind = "json", out = out, inp = inp, cb = cb, t0 = now(), timeout = timeout + 4 }
  else
    jobs[#jobs + 1] = { kind = "json", out = out, cb = cb, t0 = now(), timeout = timeout + 4 }
  end
  cmd = cmd .. " " .. q(url(path))
  if not run(cmd) then
    local j = table.remove(jobs)
    j.cb(nil, "Nie można uruchomić curl (" .. CFG.curl .. ")")
  end
end

local function http_upload(id, localPath, cb)
  local out = new_tmp("json")
  local cmd = curl_base() .. " --max-time 3600 -H " .. q("Expect:") .. " -T " .. q(localPath) ..
    " -o " .. q(out) .. " " .. q(url("/api/file?room=" .. CFG.room .. "&id=" .. id))
  jobs[#jobs + 1] = { kind = "json", out = out, cb = cb, t0 = now(), timeout = 3610 }
  if not run(cmd) then
    local j = table.remove(jobs)
    j.cb(nil, "curl")
  end
end

local function http_download(id, dest, size, cb)
  local tmp = dest .. ".part"
  os.remove(tmp)
  local cmd = curl_base() .. " -f --max-time 3600 -o " .. q(tmp) .. " " ..
    q(url("/api/file?room=" .. CFG.room .. "&id=" .. id))
  jobs[#jobs + 1] = {
    kind = "file", out = tmp, dest = dest, size = size, cb = cb,
    t0 = now(), lastGrow = now(), lastSize = -1, timeout = 3610,
  }
  if not run(cmd) then
    local j = table.remove(jobs)
    j.cb(false)
  end
end

local function poll_jobs()
  local t = now()
  local i = 1
  while i <= #jobs do
    local j = jobs[i]
    local done = false
    if j.kind == "json" then
      local d = read_file(j.out)
      if d and d:find('"_end"%s*:%s*true%s*}%s*$') then
        local obj = json.decode(d)
        if obj then
          done = true
          os.remove(j.out)
          if j.inp then os.remove(j.inp) end
          j.cb(obj)
        end
      end
      if not done and t - j.t0 > j.timeout then
        done = true
        os.remove(j.out)
        if j.inp then os.remove(j.inp) end
        j.cb(nil, "Brak odpowiedzi serwera (" .. CFG.server .. ")")
      end
    else -- plik
      local sz = file_size(j.out)
      if sz and sz ~= j.lastSize then j.lastSize, j.lastGrow = sz, t end
      if sz and j.size and sz == j.size then
        done = true
        os.remove(j.dest)
        local ok = os.rename(j.out, j.dest)
        j.cb(ok and true or false)
      elseif t - j.lastGrow > 45 or t - j.t0 > j.timeout then
        done = true
        os.remove(j.out)
        j.cb(false)
      end
    end
    if done then table.remove(jobs, i) else i = i + 1 end
  end
end

-------------------------------------------------------------------------------
-- Migawka projektu
-------------------------------------------------------------------------------
local function track_map()
  local m = {}
  for i = 0, r.CountTracks(0) - 1 do
    local tr = r.GetTrack(0, i)
    m[r.GetTrackGUID(tr)] = tr
  end
  return m
end

local function item_guid(it)
  local _, g = r.GetSetMediaItemInfo_String(it, "GUID", "", false)
  return g
end

local function item_map()
  local m = {}
  for i = 0, r.CountMediaItems(0) - 1 do
    local it = r.GetMediaItem(0, i)
    m[item_guid(it)] = it
  end
  return m
end

local function snapshot()
  local snap = { tracks = {}, items = {}, order = {} }
  for i = 0, r.CountTracks(0) - 1 do
    local tr = r.GetTrack(0, i)
    local g = r.GetTrackGUID(tr)
    local _, chunk = r.GetTrackStateChunk(tr, "", false)
    local header, _, items = M.normalize_track(chunk)
    snap.tracks[g] = { header = header, idx = i }
    snap.order[#snap.order + 1] = g
    for _, ic in ipairs(items) do
      local norm, refs, ig = M.normalize_item(ic, path_to_ref)
      if ig then snap.items[ig] = { chunk = norm, track = g, refs = refs } end
    end
  end
  return snap
end

local function track_name(header, guid)
  local n = M.chunk_field(header or "", "NAME")
  n = unquote(n or "")
  if n == "" then n = (guid and S.names[guid]) or "bez nazwy" end
  return n
end

local function item_name(chunk)
  local n = unquote(M.chunk_field(chunk or "", "NAME") or "")
  if n == "" then n = "klip" end
  return n
end

local function hex_to_rgb(hex)
  local rr, gg, bb = (hex or "#888888"):match("#?(%x%x)(%x%x)(%x%x)")
  return tonumber(rr, 16) or 136, tonumber(gg, 16) or 136, tonumber(bb, 16) or 136
end

local function native_color(hex)
  local rr, gg, bb = hex_to_rgb(hex)
  return r.ColorToNative(rr, gg, bb) | 0x1000000
end

-------------------------------------------------------------------------------
-- Komentarze jako markery
-------------------------------------------------------------------------------
local function user_color_hex(name)
  for _, u in ipairs(S.users) do if u.name == name then return u.color end end
  return nil
end

local function rebuild_markers()
  local _, nm, nr = r.CountProjectMarkers(0)
  for i = nm + nr - 1, 0, -1 do
    local _, _, _, _, name = r.EnumProjectMarkers(i)
    if name and name:sub(1, #MARK) == MARK then r.DeleteProjectMarkerByIndex(0, i) end
  end
  for _, c in pairs(S.comments) do
    local col = c.color and native_color(c.color) or 0
    r.AddProjectMarker2(0, false, c.pos or 0, 0, MARK .. c.user .. ": " .. c.text, -1, col)
  end
  r.UpdateTimeline()
end

-------------------------------------------------------------------------------
-- Zapamiętanie, które obiekty były już zsynchronizowane (dla ponownego dołączenia)
-------------------------------------------------------------------------------
local function save_synced()
  if not CFG.room or CFG.room == "" then return end
  local t = {}
  for g in pairs(S.baseTracks) do t[#t + 1] = g end
  for g in pairs(S.baseItems) do t[#t + 1] = g end
  for g in pairs(S.pending) do t[#t + 1] = g end
  r.SetProjExtState(0, SEC, "synced:" .. CFG.room, table.concat(t, " "))
  S.syncedDirty = false
end

local function load_synced()
  local _, v = r.GetProjExtState(0, SEC, "synced:" .. CFG.room)
  local set = {}
  for g in (v or ""):gmatch("%S+") do set[g] = true end
  return set
end

-------------------------------------------------------------------------------
-- Stosowanie zmian od innych osób
-------------------------------------------------------------------------------
local FAST = { VOLPAN = true, MUTESOLO = true, NAME = true, PEAKCOL = true }

-- Szybka ścieżka: jeśli zmieniła się tylko głośność/pan/mute/solo/nazwa/kolor,
-- ustawiamy to przez API zamiast podmieniać cały chunk (brak trzasków w odtwarzaniu).
local function fast_track(tr, localHeader, remoteHeader)
  local a, b = split_lines(localHeader), split_lines(remoteHeader)
  if #a ~= #b then return false end
  local changes = {}
  for i = 1, #a do
    if a[i] ~= b[i] then
      local ka, kb = first_token(a[i]), first_token(b[i])
      if ka ~= kb or not FAST[ka] then return false end
      changes[#changes + 1] = { M.tokens(a[i]), M.tokens(b[i]) }
    end
  end
  for _, ch in ipairs(changes) do
    local ta, tb = ch[1], ch[2]
    local k = tb[1]
    if k == "VOLPAN" or k == "MUTESOLO" then
      for x = 4, math.max(#ta, #tb) do if ta[x] ~= tb[x] then return false end end
    end
  end
  for _, ch in ipairs(changes) do
    local tb = ch[2]
    local k = tb[1]
    if k == "VOLPAN" then
      r.SetMediaTrackInfo_Value(tr, "D_VOL", tonumber(tb[2]) or 1)
      r.SetMediaTrackInfo_Value(tr, "D_PAN", tonumber(tb[3]) or 0)
    elseif k == "MUTESOLO" then
      r.SetMediaTrackInfo_Value(tr, "B_MUTE", tonumber(tb[2]) or 0)
      r.SetMediaTrackInfo_Value(tr, "I_SOLO", tonumber(tb[3]) or 0)
    elseif k == "NAME" then
      r.GetSetMediaTrackInfo_String(tr, "P_NAME", tb[2] or "", true)
    elseif k == "PEAKCOL" then
      r.SetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR", tonumber(tb[2]) or 0)
    end
  end
  return true
end

local function apply_order(list, tmap)
  local want = {}
  for _, g in ipairs(list or {}) do if tmap[g] then want[#want + 1] = g end end
  if #want < 2 then return end
  local function idx(g) return math.floor(r.GetMediaTrackInfo_Value(tmap[g], "IP_TRACKNUMBER")) - 1 end
  local slots, sorted = {}, true
  for i, g in ipairs(want) do
    slots[i] = idx(g)
    if i > 1 and slots[i] < slots[i - 1] then sorted = false end
  end
  if sorted then return end
  table.sort(slots)
  -- zapamiętaj zaznaczenie
  local sel = {}
  for i = 0, r.CountSelectedTracks(0) - 1 do sel[#sel + 1] = r.GetSelectedTrack(0, i) end
  for i, g in ipairs(want) do
    local c, s = idx(g), slots[i]
    if c ~= s then
      r.SetOnlyTrackSelected(tmap[g])
      r.ReorderSelectedTracks(c < s and s + 1 or s, 0)
    end
  end
  for i = 0, r.CountTracks(0) - 1 do r.SetTrackSelected(r.GetTrack(0, i), false) end
  for _, tr in ipairs(sel) do
    if r.ValidatePtr2(0, tr, "MediaTrack*") then r.SetTrackSelected(tr, true) end
  end
end

local function request_file(id)
  if not S.downloads[id] then S.want[id] = true end
end

local function rebaseline(aff)
  local snap = snapshot()
  for g in pairs(aff.tracks) do
    local t = snap.tracks[g]
    S.baseTracks[g] = t and t.header or nil
  end
  for g in pairs(aff.items) do
    local it = snap.items[g]
    S.baseItems[g] = it and { chunk = it.chunk, track = it.track } or nil
  end
  if aff.order then S.baseOrder = table.concat(snap.order, ",") end
  if aff.tempo then S.baseTempo = (r.GetProjectTimeSignature2(0)) end
  S.syncedDirty = true
end

local function apply_remote_ops(ops, undoName)
  if #ops == 0 then return end
  local tmap, imap = track_map(), item_map()
  local aff = { tracks = {}, items = {}, order = false, tempo = false }
  local who = {}
  r.PreventUIRefresh(1)
  r.Undo_BeginBlock2(0)
  for _, op in ipairs(ops) do
    local t = op.t
    if op.user then who[op.user] = true end
    if t == "track" and op.guid and op.chunk then
      local g = op.guid
      local tr = tmap[g]
      if not tr then
        local n = r.CountTracks(0)
        r.InsertTrackAtIndex(n, false)
        tr = r.GetTrack(0, n)
        r.SetTrackStateChunk(tr, M.build_track_chunk(op.chunk, {}, {}), false)
        pcall(r.GetSetMediaTrackInfo_String, tr, "GUID", g, true)
        tmap[g] = tr
        aff.order = true
      else
        local _, cur = r.GetTrackStateChunk(tr, "", false)
        local h, locals, items = M.normalize_track(cur)
        if h ~= op.chunk and not fast_track(tr, h, op.chunk) then
          r.SetTrackStateChunk(tr, M.build_track_chunk(op.chunk, locals, items), false)
        end
      end
      aff.tracks[g] = true
    elseif t == "track_del" and op.guid then
      local tr = tmap[op.guid]
      if tr then
        r.DeleteTrack(tr)
        tmap[op.guid] = nil
        imap = item_map()
      end
      for ig, p in pairs(S.pending) do if p.track == op.guid then S.pending[ig] = nil end end
      aff.tracks[op.guid] = true
      aff.order = true
    elseif t == "item" and op.guid and op.chunk then
      local tr = tmap[op.track or ""]
      if tr then
        local chunk, missing = M.denormalize_item(op.chunk, ref_to_path)
        if #missing > 0 then
          S.pending[op.guid] = op
          for _, id in ipairs(missing) do request_file(id) end
        else
          S.pending[op.guid] = nil
          local it = imap[op.guid]
          if it and not r.ValidatePtr2(0, it, "MediaItem*") then it = nil end
          local same = false
          if it and r.GetMediaItem_Track(it) == tr then
            local _, cur = r.GetItemStateChunk(it, "", false)
            same = (M.normalize_item(cur, path_to_ref)) == op.chunk
          end
          if not same then
            if not it then
              it = r.AddMediaItemToTrack(tr)
            elseif r.GetMediaItem_Track(it) ~= tr then
              r.MoveMediaItemToTrack(it, tr)
            end
            r.SetItemStateChunk(it, chunk, false)
            pcall(r.GetSetMediaItemInfo_String, it, "GUID", op.guid, true)
            imap[op.guid] = it
          end
        end
      end
      aff.items[op.guid] = true
    elseif t == "item_del" and op.guid then
      S.pending[op.guid] = nil
      local it = imap[op.guid]
      if it and r.ValidatePtr2(0, it, "MediaItem*") then
        r.DeleteTrackMediaItem(r.GetMediaItem_Track(it), it)
      end
      imap[op.guid] = nil
      aff.items[op.guid] = true
    elseif t == "order" then
      apply_order(op.list, tmap)
      aff.order = true
    elseif t == "tempo" and tonumber(op.bpm) then
      if r.CountTempoTimeSigMarkers(0) == 0 then r.SetCurrentBPM(0, tonumber(op.bpm), true) end
      aff.tempo = true
    end
  end
  local names = {}
  for n in pairs(who) do names[#names + 1] = n end
  r.Undo_EndBlock2(0, undoName or ("Multiplayer: zmiany od " .. table.concat(names, ", ")), -1)
  r.PreventUIRefresh(-1)
  r.TrackList_AdjustWindows(false)
  r.UpdateArrange()
  rebaseline(aff)
end

local function process_pending()
  local ready = {}
  for g, op in pairs(S.pending) do
    local _, missing = M.denormalize_item(op.chunk, ref_to_path)
    if #missing == 0 then
      ready[#ready + 1] = op
    else
      for _, id in ipairs(missing) do request_file(id) end
    end
  end
  if #ready > 0 then apply_remote_ops(ready, "Multiplayer: pobrane audio") end
end

-------------------------------------------------------------------------------
-- Wykrywanie lokalnych zmian
-------------------------------------------------------------------------------
local function register_local_file(id, path)
  if not S.fileLocal[id] then S.fileLocal[id] = path end
end

local function diff_local()
  local snap = snapshot()

  -- Kolorowanie moich nowych klipów (tylko takich bez własnego koloru)
  if CFG.colorize and S.myColor then
    local imap
    local col = native_color(S.myColor)
    for g, it in pairs(snap.items) do
      if not S.baseItems[g] and not S.pending[g] then
        imap = imap or item_map()
        local item = imap[g]
        if item and r.GetMediaItemInfo_Value(item, "I_CUSTOMCOLOR") == 0 then
          r.SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", col)
          local _, c = r.GetItemStateChunk(item, "", false)
          it.chunk = (M.normalize_item(c, path_to_ref))
        end
      end
    end
    if imap then r.UpdateArrange() end
  end

  local trackOps, itemOps, delOps = {}, {}, {}
  for g, t in pairs(snap.tracks) do
    if S.baseTracks[g] ~= t.header then
      trackOps[#trackOps + 1] = { t = "track", guid = g, chunk = t.header, _idx = t.idx }
    end
  end
  table.sort(trackOps, function(a, b) return a._idx < b._idx end)
  for _, op in ipairs(trackOps) do op._idx = nil end

  local orderStr = table.concat(snap.order, ",")
  if orderStr ~= S.baseOrder then
    trackOps[#trackOps + 1] = { t = "order", list = json.array(snap.order) }
  end

  for g, it in pairs(snap.items) do
    local b = S.baseItems[g]
    if not b or b.chunk ~= it.chunk or b.track ~= it.track then
      itemOps[#itemOps + 1] = { t = "item", guid = g, chunk = it.chunk, track = it.track }
      for id, p in pairs(it.refs) do register_local_file(id, p) end
    end
  end
  for g, b in pairs(S.baseItems) do
    if not snap.items[g] and snap.tracks[b.track] then
      delOps[#delOps + 1] = { t = "item_del", guid = g }
    end
  end
  for g in pairs(S.baseTracks) do
    if not snap.tracks[g] then delOps[#delOps + 1] = { t = "track_del", guid = g } end
  end

  local ops = {}
  for _, o in ipairs(trackOps) do ops[#ops + 1] = o end
  for _, o in ipairs(itemOps) do ops[#ops + 1] = o end
  for _, o in ipairs(delOps) do ops[#ops + 1] = o end

  if r.CountTempoTimeSigMarkers(0) == 0 then
    local bpm = r.GetProjectTimeSignature2(0)
    if S.baseTempo and math.abs(bpm - S.baseTempo) > 1e-6 then
      ops[#ops + 1] = { t = "tempo", bpm = bpm }
    end
    S.baseTempo = bpm
  end

  -- nowa linia bazowa = stan lokalny
  S.baseTracks, S.baseItems = {}, {}
  for g, t in pairs(snap.tracks) do S.baseTracks[g] = t.header end
  for g, it in pairs(snap.items) do S.baseItems[g] = { chunk = it.chunk, track = it.track } end
  S.baseOrder = orderStr
  if #ops > 0 then S.syncedDirty = true end
  return ops
end

-------------------------------------------------------------------------------
-- Opis operacji (feed "kto co zrobił") + metadane autorstwa
-------------------------------------------------------------------------------
local function op_key(op)
  local t = op.t
  if t == "track" or t == "track_del" then return "t:" .. tostring(op.guid) end
  if t == "item" or t == "item_del" then return "i:" .. tostring(op.guid) end
  if t == "order" or t == "tempo" then return t end
  return nil
end

local function feed_activity(op, text, key)
  local ck = (key or "") .. "|" .. (op.user or "")
  for i = #FEED, math.max(1, #FEED - 25), -1 do
    local e = FEED[i]
    if e.kind == "act" and e.ckey == ck and os.time() - (e.ts or 0) < 20 then
      e.n = (e.n or 1) + 1
      e.ts = os.time()
      return
    end
  end
  feed_add({ kind = "act", user = op.user, text = text, ckey = ck })
end

local function note_op(op)
  local t, g, user = op.t, op.guid, op.user or "?"
  local ts = os.time()
  if t == "track" then
    local isNew = not S.meta[g]
    local name = track_name(op.chunk, g)
    S.names[g] = name
    S.meta[g] = {
      kind = "track", author = isNew and user or S.meta[g].author,
      created = isNew and ts or S.meta[g].created, editor = user, ts = ts,
    }
    feed_activity(op, (isNew and "dodaje ścieżkę „" or "zmienia ścieżkę „") .. name .. "”",
      isNew and ("new" .. g) or op_key(op))
  elseif t == "track_del" then
    feed_activity(op, "usuwa ścieżkę „" .. (S.names[g] or "?") .. "”", op_key(op))
    S.meta[g] = nil
  elseif t == "item" then
    local isNew = not S.meta[g]
    local name = item_name(op.chunk)
    S.names[g] = name
    S.meta[g] = {
      kind = "item", author = isNew and user or S.meta[g].author,
      created = isNew and ts or S.meta[g].created, editor = user, ts = ts,
    }
    local pos = tonumber(M.chunk_field(op.chunk, "POSITION") or "") or 0
    local tn = S.names[op.track or ""] or "?"
    if isNew then
      feed_activity(op, "dodaje klip „" .. name .. "” na ścieżce „" .. tn .. "” @ " .. M.fmt_pos(pos),
        "new" .. g)
    else
      feed_activity(op, "edytuje klip „" .. name .. "” (" .. tn .. ")", op_key(op))
    end
  elseif t == "item_del" then
    feed_activity(op, "usuwa klip „" .. (S.names[g] or "?") .. "”", op_key(op))
    S.meta[g] = nil
  elseif t == "order" then
    feed_activity(op, "zmienia kolejność ścieżek", "order")
  elseif t == "tempo" then
    feed_activity(op, string.format("ustawia tempo na %.2f BPM", tonumber(op.bpm) or 0), "tempo")
  elseif t == "chat" then
    feed_add({ kind = "chat", user = user, text = op.text or "" })
  elseif t == "comment" and op.id then
    S.comments[op.id] = {
      id = op.id, pos = tonumber(op.pos) or 0, text = op.text or "", user = user,
      color = user_color_hex(user),
    }
    feed_add({ kind = "comment", user = user, text = op.text or "", pos = tonumber(op.pos) or 0, id = op.id })
    rebuild_markers()
  elseif t == "comment_del" and op.id then
    S.comments[op.id] = nil
    for _, e in ipairs(FEED) do if e.kind == "comment" and e.id == op.id then e.deleted = true end end
    feed_add({ kind = "act", user = user, text = "usuwa komentarz" })
    rebuild_markers()
  end
end

-------------------------------------------------------------------------------
-- Synchronizacja
-------------------------------------------------------------------------------
local start_resync

local function presence()
  local ps = r.GetPlayState()
  local play = (ps & 1) == 1
  local pos = play and r.GetPlayPosition() or r.GetCursorPosition()
  local sel = ""
  local tr = r.GetSelectedTrack(0, 0)
  if tr then
    local _, n = r.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    sel = n
  end
  return { pos = pos, play = play, rec = (ps & 4) == 4, sel = sel }
end

local function handle_files(resp)
  for _, id in ipairs(resp.missing or {}) do
    S.fileChecking[id] = nil
    if not S.uploads[id] and S.fileLocal[id] then S.uploads[id] = "queued" end
  end
  -- wszystko co sprawdzaliśmy, a czego nie ma na liście "missing" – już jest na serwerze
  local miss = {}
  for _, id in ipairs(resp.missing or {}) do miss[id] = true end
  for id in pairs(S.fileChecking) do
    if not miss[id] then S.fileConfirmed[id] = true end
  end
  S.fileChecking = {}
  for _, id in ipairs(resp.available or {}) do
    if S.want[id] and not S.downloads[id] then S.downloads[id] = "queued" end
  end
end

local function pump_transfers()
  local up, down = 0, 0
  for _, st in pairs(S.uploads) do if st == "busy" then up = up + 1 end end
  for _, st in pairs(S.downloads) do if st == "busy" then down = down + 1 end end
  for id, st in pairs(S.uploads) do
    if st == "queued" and up < 2 then
      local p = S.fileLocal[id]
      if not p or not file_exists(p) then
        S.uploads[id] = nil
      else
        S.uploads[id] = "busy"
        up = up + 1
        http_upload(id, p, function(resp)
          S.uploads[id] = nil
          if resp and resp.ok then
            S.fileConfirmed[id] = true
          else
            S.uploadFails[id] = (S.uploadFails[id] or 0) + 1
            if S.uploadFails[id] >= 3 then S.fileConfirmed[id] = true end -- poddajemy się
            status_err("Nie udało się wysłać pliku " .. id)
          end
        end)
      end
    end
  end
  for id, st in pairs(S.downloads) do
    if st == "queued" and down < 3 then
      S.downloads[id] = "busy"
      down = down + 1
      local dest = media_dir() .. SEP .. id
      http_download(id, dest, M.id_size(id), function(ok)
        S.downloads[id] = nil
        if ok then
          S.want[id] = nil
          S.lastPending = 0
        end
      end)
    end
  end
end

local function do_sync()
  local ps = r.GetPlayState()
  local recording = (ps & 4) == 4
  local ops = {}
  if S.retryOps then
    for _, o in ipairs(S.retryOps) do ops[#ops + 1] = o end
    S.retryOps = nil
  end
  if not recording then
    if #S.deferred > 0 then
      local d = S.deferred
      S.deferred = {}
      apply_remote_ops(d)
    end
    local cc = r.GetProjectStateChangeCount(0)
    if cc ~= S.lastCC then
      for _, o in ipairs(diff_local()) do ops[#ops + 1] = o end
      S.lastCC = r.GetProjectStateChangeCount(0)
    end
  end
  for _, o in ipairs(S.outbox) do ops[#ops + 1] = o end
  S.outbox = {}

  local check, want = json.array({}), json.array({})
  for id in pairs(S.fileLocal) do
    if not S.fileConfirmed[id] and not S.uploads[id] then
      check[#check + 1] = id
      S.fileChecking[id] = true
    end
  end
  for id in pairs(S.want) do
    if not S.downloads[id] then want[#want + 1] = id end
  end

  local body = {
    room = CFG.room, user = CFG.user, cid = S.cid, since = S.lastSeq,
    ops = json.array(ops), presence = presence(), check = check, want = want,
  }
  S.inflight = true
  local sentOps = ops
  local sessionCid = S.cid
  http_json("POST", "/api/sync", body, function(resp, err)
    if S.cid ~= sessionCid then return end -- odpowiedź z poprzedniej sesji
    S.inflight = false
    S.nextSync = now() + CFG.interval
    if not resp then
      S.retryOps = (#sentOps > 0) and sentOps or nil
      S.state = "error"
      status_err(err or "Błąd połączenia")
      S.nextSync = now() + 3
      return
    end
    if not resp.ok then
      S.retryOps = (#sentOps > 0) and sentOps or nil
      S.state = "error"
      status_err(resp.error or "Błąd serwera")
      S.nextSync = now() + 5
      return
    end
    S.state, S.err = "on", nil
    S.myColor = resp.color or S.myColor
    S.users = resp.users or {}
    handle_files(resp)
    if resp.resync then
      start_resync()
      return
    end
    local list = resp.ops or {}
    local last = {}
    for i, op in ipairs(list) do
      local k = op_key(op)
      if k then last[k] = i end
    end
    local toApply = {}
    for i, op in ipairs(list) do
      note_op(op)
      local k = op_key(op)
      if k and op.cid ~= S.cid and last[k] == i then toApply[#toApply + 1] = op end
      S.lastSeq = math.max(S.lastSeq, tonumber(op.seq) or 0)
    end
    if not resp.more then S.lastSeq = math.max(S.lastSeq, tonumber(resp.seq) or 0) end
    if #toApply > 0 then
      if (r.GetPlayState() & 4) == 4 then
        for _, op in ipairs(toApply) do S.deferred[#S.deferred + 1] = op end
      else
        apply_remote_ops(toApply)
      end
    end
    if resp.more then S.nextSync = 0 end
  end)
end

-------------------------------------------------------------------------------
-- Dołączanie / pełna synchronizacja
-------------------------------------------------------------------------------
local function load_meta_from_state(st)
  for g, t in pairs(st.tracks or {}) do
    S.names[g] = track_name(t.chunk, g)
    S.meta[g] = { kind = "track", author = t.author, created = t.created, editor = t.editor, ts = t.ts }
  end
  for g, it in pairs(st.items or {}) do
    S.names[g] = item_name(it.chunk)
    S.meta[g] = { kind = "item", author = it.author, created = it.created, editor = it.editor, ts = it.ts }
  end
  S.comments = {}
  for _, c in ipairs(st.comments or {}) do
    S.comments[c.id] = { id = c.id, pos = tonumber(c.pos) or 0, text = c.text or "", user = c.user or "?" }
  end
end

local function apply_state(st, mode, synced)
  local tracks, items = st.tracks or {}, st.items or {}
  if mode == "replace" then
    r.PreventUIRefresh(1)
    r.Undo_BeginBlock2(0)
    for i = r.CountTracks(0) - 1, 0, -1 do r.DeleteTrack(r.GetTrack(0, i)) end
    r.Undo_EndBlock2(0, "Multiplayer: wyczyszczenie projektu przed wczytaniem", -1)
    r.PreventUIRefresh(-1)
  end
  local order, seen = {}, {}
  for _, g in ipairs(st.order or {}) do
    if tracks[g] and not seen[g] then order[#order + 1] = g; seen[g] = true end
  end
  for g in pairs(tracks) do if not seen[g] then order[#order + 1] = g; seen[g] = true end end

  local snap = snapshot()
  local ops = {}
  if mode == "merge" and synced then
    for g in pairs(snap.tracks) do
      if synced[g] and not tracks[g] then ops[#ops + 1] = { t = "track_del", guid = g } end
    end
    for g, it in pairs(snap.items) do
      if synced[g] and not items[g] then
        ops[#ops + 1] = { t = "item_del", guid = g }
      end
    end
  end
  for _, g in ipairs(order) do
    local cur = snap.tracks[g]
    if not cur or cur.header ~= tracks[g].chunk then
      ops[#ops + 1] = { t = "track", guid = g, chunk = tracks[g].chunk }
    end
  end
  ops[#ops + 1] = { t = "order", list = order }
  for g, it in pairs(items) do
    local cur = snap.items[g]
    if not cur or cur.chunk ~= it.chunk or cur.track ~= it.track then
      ops[#ops + 1] = { t = "item", guid = g, chunk = it.chunk, track = it.track }
    end
  end
  if st.tempo and tonumber(st.tempo.bpm) then ops[#ops + 1] = { t = "tempo", bpm = st.tempo.bpm } end

  apply_remote_ops(ops, "Multiplayer: wczytanie projektu z serwera")

  -- linia bazowa: tylko obiekty, które są na serwerze
  local s2 = snapshot()
  S.baseTracks, S.baseItems = {}, {}
  local allKnown = true
  for g, t in pairs(s2.tracks) do
    if tracks[g] then S.baseTracks[g] = t.header else allKnown = false end
  end
  for g, it in pairs(s2.items) do
    if items[g] then S.baseItems[g] = { chunk = it.chunk, track = it.track } end
  end
  S.baseOrder = allKnown and table.concat(s2.order, ",") or ""
  S.baseTempo = (r.GetProjectTimeSignature2(0))
  S.lastCC = -1
  S.syncedDirty = true
  rebuild_markers()
end

function start_resync()
  S.inflight = true
  local sessionCid = S.cid
  http_json("GET", "/api/state?room=" .. CFG.room, nil, function(st, err)
    if S.cid ~= sessionCid then return end
    S.inflight = false
    if not st or not st.ok then
      status_err((st and st.error) or err or "Błąd pobierania stanu")
      S.nextSync = now() + 3
      return
    end
    local synced = {}
    for g in pairs(S.baseTracks) do synced[g] = true end
    for g in pairs(S.baseItems) do synced[g] = true end
    load_meta_from_state(st)
    apply_state(st, "merge", synced)
    S.lastSeq = tonumber(st.seq) or 0
    S.nextSync = 0
    feed_add({ kind = "act", user = "system", text = "pełna synchronizacja z serwerem" })
  end, 60)
end

local function disconnect(silent)
  if S.state ~= "off" then
    save_synced()
    if not silent then feed_add({ kind = "act", user = "system", text = "rozłączono" }) end
  end
  reset_state()
end

local function connect()
  if CFG.user == "" or CFG.room == "" or CFG.server == "" then return false end
  reset_state()
  S.state = "connecting"
  local sessionCid = S.cid
  http_json("GET", "/api/state?room=" .. CFG.room, nil, function(st, err)
    if S.cid ~= sessionCid then return end
    if not st or not st.ok then
      S.state = "error"
      status_err((st and st.error) or err or "Nie można połączyć")
      return
    end
    local serverHas = next(st.tracks or {}) ~= nil
    local localHas = r.CountTracks(0) > 0
    local mode = "host"
    if serverHas then
      if localHas then
        local ans = r.ShowMessageBox(
          "Pokój „" .. CFG.room .. "” ma już projekt na serwerze.\n\n" ..
          "TAK – wczytaj projekt z serwera (Twoje obecne ścieżki zostaną usunięte, można cofnąć Ctrl+Z)\n" ..
          "NIE – połącz: wczytaj projekt z serwera i dodaj do niego Twoje nowe ścieżki\n" ..
          "ANULUJ – nie łącz",
          "REAPER Multiplayer", 3)
        if ans == 6 then
          mode = "replace"
        elseif ans == 7 then
          mode = "merge"
        else
          S.state = "off"
          return
        end
      else
        mode = "replace"
      end
    end
    load_meta_from_state(st)
    for _, c in ipairs(st.chat or {}) do
      feed_add({ kind = "chat", user = c.user, text = c.text, ts = math.floor(tonumber(c.ts) or os.time()) })
    end
    if mode ~= "host" then
      apply_state(st, mode, mode == "merge" and load_synced() or nil)
      local nt, ni = 0, 0
      for _ in pairs(st.tracks or {}) do nt = nt + 1 end
      for _ in pairs(st.items or {}) do ni = ni + 1 end
      feed_add({ kind = "act", user = "system",
        text = string.format("wczytano projekt z serwera: %d ścieżek, %d klipów", nt, ni) })
    else
      S.baseTempo = (r.GetProjectTimeSignature2(0))
      rebuild_markers()
      feed_add({ kind = "act", user = "system", text = "jesteś gospodarzem – wysyłam Twój projekt na serwer" })
    end
    S.lastSeq = tonumber(st.seq) or 0
    S.state = "on"
    S.nextSync = 0
  end, 60)
  return true
end

-------------------------------------------------------------------------------
-- Ustawienia
-------------------------------------------------------------------------------
local function open_settings()
  local defs = table.concat({ CFG.server, CFG.room, CFG.user, CFG.password, CFG.curl }, ",")
  local ok, res = r.GetUserInputs("REAPER Multiplayer – połączenie", 5,
    "Adres serwera (http://IP:port),Pokój (litery/cyfry),Twój nick,Hasło serwera (opcjonalne),Program curl,extrawidth=240",
    defs)
  if not ok then return false end
  local vals = {}
  for v in (res .. ","):gmatch("(.-),") do vals[#vals + 1] = v end
  local server = (vals[1] or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if server ~= "" and not server:match("^https?://") then server = "http://" .. server end
  local room = (vals[2] or ""):gsub("[^%w%._%-]", "")
  local user = (vals[3] or ""):gsub("^%s+", ""):gsub("%s+$", ""):sub(1, 40)
  local pass = safe_key(vals[4] or "")
  local curl = (vals[5] or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if server == "" or room == "" or user == "" then
    r.ShowMessageBox("Podaj adres serwera, nazwę pokoju i swój nick.", "REAPER Multiplayer", 0)
    return false
  end
  CFG.server, CFG.room, CFG.user, CFG.password = server, room, user, pass
  CFG.curl = curl ~= "" and curl or CFG.curl
  set_ext("server", CFG.server)
  set_ext("room", CFG.room)
  set_ext("user", CFG.user)
  set_ext("password", CFG.password)
  set_ext("curl", CFG.curl)
  return true
end

-------------------------------------------------------------------------------
-- Interfejs (gfx)
-------------------------------------------------------------------------------
local UI = { input = "", tab = 1, scroll = 0, caret = 0, hits = {} }
local mouse = { l = false, r = false, x = 0, y = 0, clicked = false, rclicked = false }
local TABS = { "Wszystko", "Czat", "Komentarze", "Aktywność" }

local function set_rgb(rr, gg, bb, a) gfx.set(rr / 255, gg / 255, bb / 255, a or 1) end
local function set_hex(hex, a)
  local rr, gg, bb = hex_to_rgb(hex)
  set_rgb(rr, gg, bb, a)
end

local function color_of(user)
  if user == "system" then return "#9aa0a6" end
  return user_color_hex(user) or "#c8c8c8"
end

local function inside(x, y, w, h) return mouse.x >= x and mouse.x < x + w and mouse.y >= y and mouse.y < y + h end

local function button(x, y, w, h, label, active)
  local hover = inside(x, y, w, h)
  if active then
    set_rgb(70, 110, 170)
  elseif hover then
    set_rgb(72, 72, 78)
  else
    set_rgb(52, 52, 58)
  end
  gfx.rect(x, y, w, h, 1)
  set_rgb(225, 225, 230)
  gfx.setfont(2)
  local tw, th = gfx.measurestr(label)
  gfx.x, gfx.y = x + (w - tw) / 2, y + (h - th) / 2
  gfx.drawstr(label)
  return hover and mouse.clicked
end

local function wrap(text, firstW, restW)
  local lines, cur, w = {}, "", firstW
  for word in text:gmatch("%S+") do
    local cand = cur == "" and word or (cur .. " " .. word)
    if gfx.measurestr(cand) <= w or cur == "" then
      cur = cand
    else
      lines[#lines + 1] = cur
      cur, w = word, restW
    end
  end
  lines[#lines + 1] = cur
  return lines
end

local function entry_visible(e)
  if e.deleted then return false end
  local tab = UI.tab
  if tab == 1 then return true end
  if tab == 2 then return e.kind == "chat" end
  if tab == 3 then return e.kind == "comment" end
  return e.kind == "act"
end

local function entry_text(e)
  if e.kind == "comment" then return "[komentarz @ " .. M.fmt_pos(e.pos) .. "] " .. e.text end
  if e.kind == "act" and (e.n or 1) > 1 then return e.text .. " (×" .. e.n .. ")" end
  return e.text
end

local LH = 18

local function layout_entry(e, W)
  local text = entry_text(e)
  if e._w == W and e._t == text then return e._lines end
  gfx.setfont(2)
  local tw = gfx.measurestr("00:00  ")
  gfx.setfont(3)
  local nw = gfx.measurestr((e.user or "?") .. "  ")
  gfx.setfont(1)
  e._lines = wrap(text, W - tw - nw, W - tw)
  e._w, e._t, e._tw, e._nw = W, text, tw, nw
  return e._lines
end

local function draw_feed(x, y, w, h)
  set_rgb(24, 24, 27)
  gfx.rect(x, y, w, h, 1)
  local list = {}
  for _, e in ipairs(FEED) do if entry_visible(e) then list[#list + 1] = e end end
  local innerW = w - 16
  local total = 0
  for _, e in ipairs(list) do total = total + #layout_entry(e, innerW) * LH + 4 end
  local maxScroll = math.max(0, total - (h - 8))
  UI.scroll = math.max(0, math.min(UI.scroll, maxScroll))
  local by = y + h - 4 + UI.scroll
  UI.hits = {}
  for i = #list, 1, -1 do
    local e = list[i]
    local lines = layout_entry(e, innerW)
    local eh = #lines * LH + 4
    local ey = by - eh
    if ey + eh < y then break end
    if ey < y + h then
      if e.kind == "comment" and inside(x, math.max(y, ey), w, eh) then
        set_rgb(40, 44, 54)
        gfx.rect(x + 2, math.max(y, ey), w - 4, math.min(eh, y + h - ey), 1)
      end
      for li, line in ipairs(lines) do
        local ly = ey + 2 + (li - 1) * LH
        if ly >= y and ly + LH <= y + h then
          gfx.x, gfx.y = x + 8, ly
          if li == 1 then
            gfx.setfont(2)
            set_rgb(120, 120, 128)
            gfx.drawstr(os.date("%H:%M", e.ts))
            gfx.x = x + 8 + e._tw
            gfx.setfont(3)
            set_hex(color_of(e.user))
            gfx.drawstr(e.user or "?")
            gfx.x = x + 8 + e._tw + e._nw
          else
            gfx.x = x + 8 + e._tw
          end
          gfx.setfont(1)
          if e.kind == "act" then
            set_rgb(165, 168, 175)
          elseif e.kind == "comment" then
            set_rgb(250, 215, 120)
          else
            set_rgb(232, 232, 236)
          end
          gfx.drawstr(line)
        end
      end
      UI.hits[#UI.hits + 1] = { e = e, y = ey, h = eh }
    end
    by = ey
  end
  if mouse.wheel ~= 0 and inside(x, y, w, h) then
    UI.scroll = UI.scroll + mouse.wheel / 120 * LH * 3
  end
  -- kliknięcia w komentarze
  if inside(x, y, w, h) and (mouse.clicked or mouse.rclicked) then
    for _, hit in ipairs(UI.hits) do
      if mouse.y >= hit.y and mouse.y < hit.y + hit.h and hit.e.kind == "comment" then
        if mouse.clicked then
          r.SetEditCurPos(hit.e.pos, true, false)
        else
          gfx.x, gfx.y = mouse.x, mouse.y
          local choice = gfx.showmenu("Przejdź do " .. M.fmt_pos(hit.e.pos) .. "|Usuń komentarz")
          if choice == 1 then
            r.SetEditCurPos(hit.e.pos, true, false)
          elseif choice == 2 and S.state == "on" then
            S.outbox[#S.outbox + 1] = { t = "comment_del", id = hit.e.id }
            S.nextSync = 0
          end
        end
      end
    end
  end
end

local function inspector_text()
  local it = r.GetSelectedMediaItem(0, 0)
  local function fmt(m, label)
    local s = label .. " – dodane przez " .. (m.author or "?")
    if m.created then s = s .. " o " .. os.date("%H:%M", math.floor(m.created)) end
    if m.editor and m.editor ~= m.author then
      s = s .. ", ostatnio zmienione przez " .. m.editor
      if m.ts then s = s .. " o " .. os.date("%H:%M", math.floor(m.ts)) end
    end
    return s
  end
  if it then
    local g = item_guid(it)
    local m = S.meta[g]
    local take = r.GetActiveTake(it)
    local name = take and r.GetTakeName(take) or "klip"
    if m then return fmt(m, "Klip „" .. name .. "”") end
    return "Klip „" .. name .. "” – jeszcze nie zsynchronizowany"
  end
  local tr = r.GetSelectedTrack(0, 0)
  if tr then
    local m = S.meta[r.GetTrackGUID(tr)]
    local _, name = r.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    if name == "" then name = "bez nazwy" end
    if m then return fmt(m, "Ścieżka „" .. name .. "”") end
    return "Ścieżka „" .. name .. "” – jeszcze nie zsynchronizowana"
  end
  return "Zaznacz klip lub ścieżkę, żeby zobaczyć, kto je dodał."
end

local function send_input(asComment)
  local txt = UI.input:gsub("^%s+", ""):gsub("%s+$", "")
  if txt == "" or S.state ~= "on" then return end
  if asComment then
    S.outbox[#S.outbox + 1] = {
      t = "comment", id = S.cid .. "-" .. math.floor(now() * 1000), pos = r.GetCursorPosition(), text = txt,
    }
  else
    S.outbox[#S.outbox + 1] = { t = "chat", text = txt }
  end
  UI.input = ""
  S.nextSync = 0
  UI.scroll = 0
end

local function show_menu()
  gfx.x, gfx.y = mouse.x, mouse.y
  local items = {
    "Ustawienia połączenia…",
    (CFG.colorize and "!" or "") .. "Koloruj moje nowe klipy moim kolorem",
    (S.state == "on" and "" or "#") .. "Wymuś pełną synchronizację",
    "Wyczyść czat lokalnie",
    "#REAPER Multiplayer v" .. VERSION,
  }
  local c = gfx.showmenu(table.concat(items, "|"))
  if c == 1 then
    if open_settings() then
      if S.state ~= "off" then disconnect(true) end
      connect()
    end
  elseif c == 2 then
    CFG.colorize = not CFG.colorize
    set_ext("colorize", CFG.colorize and "1" or "0")
  elseif c == 3 then
    if not S.inflight then start_resync() end
  elseif c == 4 then
    for k in pairs(FEED) do FEED[k] = nil end
  end
end

local function handle_keys()
  while true do
    local c = gfx.getchar()
    if c == -1 then return false end
    if c == 0 then break end
    if c == 13 then
      send_input(false)
    elseif c == 8 then
      UI.input = UI.input:gsub("[%z\1-\127\194-\244][\128-\191]*$", "")
    elseif c == 27 then
      UI.input = ""
    elseif c == 22 and r.CF_GetClipboard then -- Ctrl+V (wymaga SWS)
      UI.input = UI.input .. (r.CF_GetClipboard(""):gsub("[\r\n]", " "))
    elseif c >= 32 and c < 127 then
      UI.input = UI.input .. string.char(c)
    elseif c >= 160 and c <= 255 then
      UI.input = UI.input .. utf8.char(c)
    elseif c >= 0x75000000 and c < 0x76000000 then -- 'u' << 24 | codepoint
      local cp = c - 0x75000000
      if cp >= 32 then UI.input = UI.input .. utf8.char(cp) end
    end
  end
  return true
end

local function draw()
  local W, H = gfx.w, gfx.h
  set_rgb(32, 32, 36)
  gfx.rect(0, 0, W, H, 1)
  local pad = 10
  local y = 10

  -- nagłówek
  local st = S.state
  local dot, label
  if st == "on" then
    dot, label = { 80, 200, 120 }, "Połączono"
  elseif st == "connecting" then
    dot, label = { 230, 190, 70 }, "Łączenie…"
  elseif st == "error" then
    dot, label = { 230, 80, 80 }, "Problem z połączeniem"
  else
    dot, label = { 120, 120, 120 }, "Rozłączono"
  end
  set_rgb(dot[1], dot[2], dot[3])
  gfx.circle(pad + 6, y + 9, 5, 1)
  gfx.setfont(3)
  set_rgb(235, 235, 240)
  gfx.x, gfx.y = pad + 18, y + 1
  gfx.drawstr(label)
  local nup, ndown = 0, 0
  for _ in pairs(S.uploads) do nup = nup + 1 end
  for _ in pairs(S.downloads) do ndown = ndown + 1 end
  local npend = 0
  for _ in pairs(S.pending) do npend = npend + 1 end
  if nup + ndown + npend > 0 then
    gfx.setfont(2)
    set_rgb(150, 190, 240)
    gfx.drawstr(string.format("   ↑%d  ↓%d  oczekuje: %d", nup, ndown, npend))
  end
  if #S.deferred > 0 then
    gfx.setfont(2)
    set_rgb(240, 120, 120)
    gfx.drawstr("   nagrywanie – zmiany innych czekają")
  end

  local bw = 84
  if button(W - pad - bw, y - 1, bw, 22, (st == "off") and "Połącz" or "Rozłącz") then
    if st == "off" then
      if (CFG.user ~= "" or open_settings()) then connect() end
    else
      disconnect()
    end
  end
  if button(W - pad - bw - 6 - 60, y - 1, 60, 22, "Menu") then show_menu() end
  y = y + 26

  gfx.setfont(2)
  set_rgb(150, 150, 158)
  gfx.x, gfx.y = pad, y
  gfx.drawstr("Pokój: " .. CFG.room .. "   •   Ty: " .. (CFG.user ~= "" and CFG.user or "?") ..
    "   •   " .. CFG.server)
  y = y + 18
  if S.err then
    set_rgb(240, 120, 120)
    gfx.x, gfx.y = pad, y
    gfx.drawstr(S.err)
    y = y + 18
  end

  -- osoby online
  y = y + 4
  gfx.setfont(3)
  set_rgb(200, 200, 205)
  gfx.x, gfx.y = pad, y
  gfx.drawstr("Online:")
  local cx = pad + gfx.measurestr("Online:") + 10
  gfx.setfont(2)
  if #S.users == 0 then
    set_rgb(120, 120, 128)
    gfx.x, gfx.y = cx, y + 1
    gfx.drawstr(st == "on" and "tylko Ty" or "–")
  end
  for _, u in ipairs(S.users) do
    local txt = u.name
    if u.rec then
      txt = txt .. "  ● REC " .. M.fmt_pos(u.pos)
    elseif u.play then
      txt = txt .. "  ▶ " .. M.fmt_pos(u.pos)
    else
      txt = txt .. "  @ " .. M.fmt_pos(u.pos)
    end
    if u.sel and u.sel ~= "" then txt = txt .. " · " .. u.sel end
    local tw = gfx.measurestr(txt) + 24
    if cx + tw > W - pad then
      cx = pad
      y = y + 22
    end
    set_rgb(48, 48, 54)
    gfx.rect(cx, y - 2, tw, 20, 1)
    set_hex(u.color)
    gfx.circle(cx + 9, y + 8, 4, 1)
    set_rgb(u.rec and 255 or 225, u.rec and 140 or 225, u.rec and 140 or 230)
    gfx.x, gfx.y = cx + 18, y + 1
    gfx.drawstr(txt)
    cx = cx + tw + 6
  end
  y = y + 26

  -- inspektor
  set_rgb(40, 40, 46)
  gfx.rect(pad, y, W - 2 * pad, 24, 1)
  gfx.setfont(2)
  set_rgb(210, 210, 215)
  gfx.x, gfx.y = pad + 8, y + 5
  local it = inspector_text()
  if gfx.measurestr(it) > W - 2 * pad - 16 then
    while #it > 4 and gfx.measurestr(it .. "…") > W - 2 * pad - 16 do
      it = it:sub(1, (utf8.offset(it, -1) or #it) - 1)
    end
    it = it .. "…"
  end
  gfx.drawstr(it)
  y = y + 32

  -- zakładki
  local tx = pad
  for i, name in ipairs(TABS) do
    gfx.setfont(2)
    local tw = gfx.measurestr(name) + 20
    if button(tx, y, tw, 22, name, UI.tab == i) then
      UI.tab = i
      UI.scroll = 0
    end
    tx = tx + tw + 4
  end
  y = y + 28

  -- lista
  local bottomH = 70
  draw_feed(pad, y, W - 2 * pad, H - y - bottomH)

  -- pole tekstowe
  local iy = H - bottomH + 10
  set_rgb(20, 20, 23)
  gfx.rect(pad, iy, W - 2 * pad, 26, 1)
  set_rgb(80, 80, 90)
  gfx.rect(pad, iy, W - 2 * pad, 26, 0)
  gfx.setfont(1)
  local shown = UI.input
  while #shown > 0 and gfx.measurestr(shown) > W - 2 * pad - 20 do
    shown = shown:sub((utf8.offset(shown, 2) or (#shown + 1)))
  end
  gfx.x, gfx.y = pad + 8, iy + 5
  if UI.input == "" then
    set_rgb(110, 110, 118)
    gfx.drawstr("Napisz wiadomość (Enter = wyślij na czat)…")
  else
    set_rgb(235, 235, 240)
    gfx.drawstr(shown)
  end
  if math.floor(now() * 2) % 2 == 0 then
    set_rgb(200, 200, 210)
    local cxp = pad + 8 + (UI.input == "" and 0 or gfx.measurestr(shown))
    gfx.line(cxp + 1, iy + 5, cxp + 1, iy + 21)
  end

  local by = iy + 32
  if button(pad, by, 90, 22, "Wyślij") then send_input(false) end
  local cl = "Komentarz @ " .. M.fmt_pos(r.GetCursorPosition())
  gfx.setfont(2)
  local cw = gfx.measurestr(cl) + 24
  if button(pad + 96, by, cw, 22, cl) then send_input(true) end
end

local function update_mouse()
  local cap = gfx.mouse_cap
  local l, rr = (cap & 1) == 1, (cap & 2) == 2
  mouse.clicked = l and not mouse.l
  mouse.rclicked = rr and not mouse.r
  mouse.l, mouse.r = l, rr
  mouse.x, mouse.y = gfx.mouse_x, gfx.mouse_y
  mouse.wheel = gfx.mouse_wheel
  gfx.mouse_wheel = 0
end

-------------------------------------------------------------------------------
-- Pętla główna
-------------------------------------------------------------------------------
local function main_loop()
  poll_jobs()
  local t = now()
  if S.state == "on" or S.state == "error" then
    if not S.inflight and t >= S.nextSync then do_sync() end
    pump_transfers()
    if t - S.lastPending > 1.0 and next(S.pending) and (r.GetPlayState() & 4) == 0 then
      S.lastPending = t
      process_pending()
    end
    if S.syncedDirty and t - S.lastSyncedSave > 30 then
      S.lastSyncedSave = t
      save_synced()
    end
  end

  update_mouse()
  if not handle_keys() then return end -- okno zamknięte
  draw()
  gfx.update()
  r.defer(main_loop)
end

local function on_exit()
  if S and S.state ~= "off" then save_synced() end
  set_ext("dock", gfx.dock(-1))
  local _, x, y, w, h = gfx.dock(-1, 0, 0, 0, 0)
  set_ext("wnd", string.format("%d %d %d %d", x, y, w, h))
end

local function init()
  math.randomseed(math.floor(os.time() + (r.time_precise() * 1000) % 100000))
  reset_state()
  local x, y, w, h = (get_ext("wnd", "")):match("(-?%d+) (-?%d+) (%d+) (%d+)")
  gfx.init("REAPER Multiplayer", tonumber(w) or 560, tonumber(h) or 640,
    tonumber(get_ext("dock", "0")) or 0, tonumber(x) or 120, tonumber(y) or 120)
  local font = IS_WIN and "Segoe UI" or "Arial"
  gfx.setfont(1, font, 15)
  gfx.setfont(2, font, 13)
  gfx.setfont(3, font, 15, string.byte("b"))
  r.atexit(on_exit)
  if CFG.user == "" then
    if open_settings() then connect() end
  else
    connect()
  end
  main_loop()
end

init()
