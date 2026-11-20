-- @description REAPER Multiplayer – wspólna praca nad jednym projektem przez serwer
-- @version 1.4.0
-- @author RMP
-- @about
--   Łączy REAPERa z serwerem RMP (server/rmp_server.py). Wszystkie zmiany ścieżek,
--   klipów (audio i MIDI), FX, głośności itp. są automatycznie wysyłane do pozostałych
--   osób w tym samym pokoju. Nagrane pliki audio wysyłane są w tle – nikt nie musi
--   niczego ręcznie przesyłać. Okno skryptu pokazuje, kto jest online, kto co dodał,
--   czat i komentarze przypięte do miejsca na osi czasu.
--
--   Wymagania: REAPER 6.0+, program curl (wbudowany w Windows 10/11 i macOS).

local VERSION = "1.4.0"
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

--- Tekst UTF-8 -> UTF-16LE z BOM (plik czytany przez skrypt VBS na Windows).
function M.utf16le(s)
  local out = { "\255\254" }
  local ok = pcall(function()
    for _, cp in utf8.codes(s) do
      if cp >= 0x10000 then
        cp = cp - 0x10000
        out[#out + 1] = string.pack("<I2I2", 0xD800 + (cp >> 10), 0xDC00 + (cp & 0x3FF))
      else
        out[#out + 1] = string.pack("<I2", cp)
      end
    end
  end)
  if not ok then -- niepoprawny UTF-8: bajt po bajcie
    out = { "\255\254" }
    for i = 1, #s do out[#out + 1] = string.pack("<I2", s:byte(i)) end
  end
  return table.concat(out)
end

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
  lang = get_ext("lang", "pl"), -- ustawia aplikacja Sesja; pl albo en (inne -> en)
  hidden = get_ext("hidden", "1") == "1", -- Windows: curl bez migającego okna konsoli
}

-------------------------------------------------------------------------------
-- Tłumaczenia (pl, en). T("klucz", ...) działa jak string.format.
-------------------------------------------------------------------------------
local L = {
  pl = {
    track_add = "dodaje ścieżkę „%s”", track_edit = "zmienia ścieżkę „%s”", track_del = "usuwa ścieżkę „%s”",
    item_add = "dodaje klip „%s” na ścieżce „%s” @ %s", item_edit = "edytuje klip „%s” (%s)", item_del = "usuwa klip „%s”",
    order = "zmienia kolejność ścieżek", tempo = "ustawia tempo na %.2f BPM", comment_del = "usuwa komentarz",
    no_name = "bez nazwy", clip = "klip",
    upload_failed = "Nie udało się wysłać pliku %s", conn_error = "Błąd połączenia", server_error = "Błąd serwera",
    no_curl = "Nie można uruchomić curl (%s)", no_answer = "Brak odpowiedzi serwera (%s)",
    state_error = "Błąd pobierania stanu", cant_connect = "Nie można połączyć",
    srv_bad_password = "Złe hasło serwera", srv_bad_room = "Niepoprawna nazwa pokoju",
    undo_remote = "Multiplayer: zmiany od %s", undo_audio = "Multiplayer: pobrane audio",
    undo_clear = "Multiplayer: wyczyszczenie projektu przed wczytaniem", undo_load = "Multiplayer: wczytanie projektu z serwera",
    full_sync = "pełna synchronizacja z serwerem", disconnected_msg = "rozłączono",
    loaded = "wczytano projekt z serwera: %d ścieżek, %d klipów", host_msg = "jesteś gospodarzem – wysyłam Twój projekt na serwer",
    join_q = "Pokój „%s” ma już projekt na serwerze.\n\nTAK – wczytaj projekt z serwera (Twoje obecne ścieżki zostaną usunięte, można cofnąć Ctrl+Z)\nNIE – połącz: wczytaj projekt z serwera i dodaj do niego Twoje nowe ścieżki\nANULUJ – nie łącz",
    settings_title = "REAPER Multiplayer – połączenie",
    settings_fields = "Adres serwera (http://IP:port),Pokój (litery/cyfry),Twój nick,Hasło serwera (opcjonalne),Program curl,extrawidth=240",
    settings_missing = "Podaj adres serwera, nazwę pokoju i swój nick.",
    tab_all = "Wszystko", tab_chat = "Czat", tab_comments = "Komentarze", tab_activity = "Aktywność",
    comment_item = "[komentarz do „%s” @ %s] %s", comment_pos = "[komentarz @ %s] %s",
    go_to = "Przejdź do %s", delete_comment = "Usuń komentarz",
    added_by = "%s – dodane przez %s", at_time = " o %s", edited_by = ", ostatnio zmienione przez %s",
    clip_label = "Klip „%s”", track_label = "Ścieżka „%s”",
    clip_unsynced = "Klip „%s” – jeszcze nie zsynchronizowany", track_unsynced = "Ścieżka „%s” – jeszcze nie zsynchronizowana",
    select_hint = "Zaznacz klip lub ścieżkę, żeby zobaczyć, kto je dodał.",
    menu_settings = "Ustawienia połączenia…", menu_colorize = "Koloruj moje nowe klipy moim kolorem",
    menu_resync = "Wymuś pełną synchronizację", menu_clear = "Wyczyść czat lokalnie",
    st_on = "Połączono", st_connecting = "Łączenie…", st_error = "Problem z połączeniem", st_off = "Rozłączono",
    pending = "   ↑%d  ↓%d  oczekuje: %d", recording_wait = "   nagrywanie – zmiany innych czekają",
    connect = "Połącz", disconnect = "Rozłącz", menu = "Menu",
    header = "Pokój: %s   •   Ty: %s   •   %s", online = "Online:", only_you = "tylko Ty",
    in_app = "%s  (aplikacja Sesja)", input_ph = "Napisz wiadomość (Enter = wyślij na czat)…", send = "Wyślij",
    comment_on = "Komentarz do „%s”", comment_at = "Komentarz @ %s",
    in_session = "W sesji", app_only = "tylko w aplikacji", new_comment = "komentarz: %s",
    nobody = "Nikogo jeszcze nie ma", subtitle = "REAPER Multiplayer · pokój %s",
  },
  en = {
    track_add = "added track “%s”", track_edit = "changed track “%s”", track_del = "deleted track “%s”",
    item_add = "added clip “%s” on track “%s” @ %s", item_edit = "edited clip “%s” (%s)", item_del = "deleted clip “%s”",
    order = "reordered the tracks", tempo = "set the tempo to %.2f BPM", comment_del = "deleted a comment",
    no_name = "unnamed", clip = "clip",
    upload_failed = "Could not upload file %s", conn_error = "Connection error", server_error = "Server error",
    no_curl = "Cannot start curl (%s)", no_answer = "No answer from the server (%s)",
    state_error = "Could not load the project state", cant_connect = "Cannot connect",
    srv_bad_password = "Wrong server password", srv_bad_room = "Invalid room name",
    undo_remote = "Multiplayer: changes from %s", undo_audio = "Multiplayer: downloaded audio",
    undo_clear = "Multiplayer: clear project before loading", undo_load = "Multiplayer: load project from server",
    full_sync = "full sync with the server", disconnected_msg = "disconnected",
    loaded = "loaded project from the server: %d tracks, %d clips", host_msg = "you are the host – sending your project to the server",
    join_q = "Room “%s” already has a project on the server.\n\nYES – load the project from the server (your current tracks will be removed, Ctrl+Z undoes it)\nNO – merge: load the server project and add your new tracks to it\nCANCEL – don’t connect",
    settings_title = "REAPER Multiplayer – connection",
    settings_fields = "Server address (http://IP:port),Room (letters/digits),Your nickname,Server password (optional),curl program,extrawidth=240",
    settings_missing = "Enter the server address, room name and your nickname.",
    tab_all = "All", tab_chat = "Chat", tab_comments = "Comments", tab_activity = "Activity",
    comment_item = "[comment on “%s” @ %s] %s", comment_pos = "[comment @ %s] %s",
    go_to = "Go to %s", delete_comment = "Delete comment",
    added_by = "%s – added by %s", at_time = " at %s", edited_by = ", last changed by %s",
    clip_label = "Clip “%s”", track_label = "Track “%s”",
    clip_unsynced = "Clip “%s” – not synced yet", track_unsynced = "Track “%s” – not synced yet",
    select_hint = "Select a clip or track to see who added it.",
    menu_settings = "Connection settings…", menu_colorize = "Colour my new clips with my colour",
    menu_resync = "Force full sync", menu_clear = "Clear chat locally",
    st_on = "Connected", st_connecting = "Connecting…", st_error = "Connection problem", st_off = "Disconnected",
    pending = "   ↑%d  ↓%d  waiting: %d", recording_wait = "   recording – others’ changes are waiting",
    connect = "Connect", disconnect = "Disconnect", menu = "Menu",
    header = "Room: %s   •   You: %s   •   %s", online = "Online:", only_you = "just you",
    in_app = "%s  (Sesja app)", input_ph = "Write a message (Enter = send to chat)…", send = "Send",
    comment_on = "Comment on “%s”", comment_at = "Comment @ %s",
    in_session = "In the session", app_only = "app only", new_comment = "comment: %s",
    nobody = "Nobody here yet", subtitle = "REAPER Multiplayer · room %s",
  },
}
local function T(key, ...)
  local d = L[CFG.lang] or L.en
  local s = d[key] or L.en[key] or key
  if select("#", ...) > 0 then return string.format(s, ...) end
  return s
end
local function server_msg(resp)
  if resp and resp.code and (L.en["srv_" .. resp.code]) then return T("srv_" .. resp.code) end
  return (resp and resp.error) or T("server_error")
end

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
-- Poziom „aktywności” napędza wskaźnik VU w nagłówku; toast to krótkie powiadomienie w oknie.
local ACTIVITY = { level = 0, toast = nil }

local function feed_add(e)
  e.ts = e.ts or os.time()
  e.t0 = e.t0 or now() -- moment pojawienia się – do animacji wejścia
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

-- Na Windows curl.exe to program konsolowy: uruchomiony wprost przez ExecProcess
-- na ułamek sekundy pokazuje czarne okno (co sekundę!). Dlatego uruchamiamy go przez
-- wscript.exe (program bez konsoli) i mały skrypt VBS, który startuje curl z ukrytym oknem.
-- Polecenie trafia do pliku w UTF-16, żeby ścieżki z polskimi znakami działały.
local HIDDEN_VBS = nil
local WSCRIPT = (os.getenv("WINDIR") or "C:\\Windows") .. "\\System32\\wscript.exe"

local function hidden_runner()
  if HIDDEN_VBS and file_exists(HIDDEN_VBS) then return HIDDEN_VBS end
  HIDDEN_VBS = TMP .. SEP .. "sesja_hidden.vbs"
  write_file(HIDDEN_VBS, table.concat({
    "' Sesja: uruchamia polecenie z pliku bez okna konsoli",
    "Dim fso, f, cmd",
    "Set fso = CreateObject(\"Scripting.FileSystemObject\")",
    "Set f = fso.OpenTextFile(WScript.Arguments(0), 1, False, -1)",
    "cmd = f.ReadAll",
    "f.Close",
    "fso.DeleteFile WScript.Arguments(0)",
    "CreateObject(\"WScript.Shell\").Run cmd, 0, False",
  }, "\r\n") .. "\r\n")
  return HIDDEN_VBS
end

local function run(cmd)
  -- nie czekamy na zakończenie; wynik odczytujemy z pliku, a błędy wykrywamy przez timeout
  if IS_WIN and CFG.hidden and file_exists(WSCRIPT) then
    local cmdfile = new_tmp("cmd")
    write_file(cmdfile, M.utf16le(cmd))
    r.ExecProcess(q(WSCRIPT) .. " //B //Nologo " .. q(hidden_runner()) .. " " .. q(cmdfile), -1)
  else
    r.ExecProcess(cmd, -1)
  end
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
    j.cb(nil, T("no_curl", CFG.curl))
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
        j.cb(nil, T("no_answer", CFG.server))
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
  if n == "" then n = (guid and S.names[guid]) or T("no_name") end
  return n
end

local function item_name(chunk)
  local n = unquote(M.chunk_field(chunk or "", "NAME") or "")
  if n == "" then n = T("clip") end
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
    if not c.item then r.AddProjectMarker2(0, false, c.pos or 0, 0, MARK .. c.user .. ": " .. c.text, -1, col) end
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
  r.Undo_EndBlock2(0, undoName or T("undo_remote", table.concat(names, ", ")), -1)
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
  if #ready > 0 then apply_remote_ops(ready, T("undo_audio")) end
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
  if op.cid ~= S.cid then ACTIVITY.level = math.min(1, ACTIVITY.level + 0.35) end
  local ts = os.time()
  if t == "track" then
    local isNew = not S.meta[g]
    local name = track_name(op.chunk, g)
    S.names[g] = name
    S.meta[g] = {
      kind = "track", author = isNew and user or S.meta[g].author,
      created = isNew and ts or S.meta[g].created, editor = user, ts = ts,
    }
    feed_activity(op, T(isNew and "track_add" or "track_edit", name),
      isNew and ("new" .. g) or op_key(op))
  elseif t == "track_del" then
    feed_activity(op, T("track_del", S.names[g] or "?"), op_key(op))
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
      feed_activity(op, T("item_add", name, tn, M.fmt_pos(pos)),
        "new" .. g)
    else
      feed_activity(op, T("item_edit", name, tn), op_key(op))
    end
  elseif t == "item_del" then
    feed_activity(op, T("item_del", S.names[g] or "?"), op_key(op))
    S.meta[g] = nil
  elseif t == "order" then
    feed_activity(op, T("order"), "order")
  elseif t == "tempo" then
    feed_activity(op, T("tempo", tonumber(op.bpm) or 0), "tempo")
  elseif t == "chat" then
    feed_add({ kind = "chat", user = user, text = op.text or "" })
    if op.cid ~= S.cid then ACTIVITY.toast = { user = user, text = op.text or "", t0 = now() } end
  elseif t == "comment" and op.id then
    S.comments[op.id] = {
      id = op.id, pos = tonumber(op.pos) or 0, text = op.text or "", user = user,
      color = user_color_hex(user), item = op.item, itemName = op.itemName,
    }
    feed_add({ kind = "comment", user = user, text = op.text or "", pos = tonumber(op.pos) or 0, id = op.id,
      item = op.item, itemName = op.itemName })
    if op.cid ~= S.cid then ACTIVITY.toast = { user = user, text = T("new_comment", op.text or ""), t0 = now() } end
    rebuild_markers()
  elseif t == "comment_del" and op.id then
    S.comments[op.id] = nil
    for _, e in ipairs(FEED) do if e.kind == "comment" and e.id == op.id then e.deleted = true end end
    feed_add({ kind = "act", user = user, text = T("comment_del") })
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
            status_err(T("upload_failed", id))
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
  http_json("POST", "/api/sync?room=" .. CFG.room, body, function(resp, err)
    if S.cid ~= sessionCid then return end -- odpowiedź z poprzedniej sesji
    S.inflight = false
    S.nextSync = now() + CFG.interval
    if not resp then
      S.retryOps = (#sentOps > 0) and sentOps or nil
      S.state = "error"
      status_err(err or T("conn_error"))
      S.nextSync = now() + 3
      return
    end
    if not resp.ok then
      S.retryOps = (#sentOps > 0) and sentOps or nil
      S.state = "error"
      status_err(server_msg(resp))
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
    S.comments[c.id] = {
      id = c.id, pos = tonumber(c.pos) or 0, text = c.text or "", user = c.user or "?",
      item = c.item, itemName = c.itemName,
    }
  end
end

local function apply_state(st, mode, synced)
  local tracks, items = st.tracks or {}, st.items or {}
  if mode == "replace" then
    r.PreventUIRefresh(1)
    r.Undo_BeginBlock2(0)
    for i = r.CountTracks(0) - 1, 0, -1 do r.DeleteTrack(r.GetTrack(0, i)) end
    r.Undo_EndBlock2(0, T("undo_clear"), -1)
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

  apply_remote_ops(ops, T("undo_load"))

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
      status_err(st and server_msg(st) or err or T("state_error"))
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
    feed_add({ kind = "act", user = "system", text = T("full_sync") })
  end, 60)
end

local function disconnect(silent)
  if S.state ~= "off" then
    save_synced()
    if not silent then feed_add({ kind = "act", user = "system", text = T("disconnected_msg") }) end
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
      status_err(st and server_msg(st) or err or T("cant_connect"))
      return
    end
    local serverHas = next(st.tracks or {}) ~= nil
    local localHas = r.CountTracks(0) > 0
    local mode = "host"
    if serverHas then
      if localHas then
        local ans = r.ShowMessageBox(T("join_q", CFG.room), "REAPER Multiplayer", 3)
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
        text = T("loaded", nt, ni) })
    else
      S.baseTempo = (r.GetProjectTimeSignature2(0))
      rebuild_markers()
      feed_add({ kind = "act", user = "system", text = T("host_msg") })
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
  local ok, res = r.GetUserInputs(T("settings_title"), 5, T("settings_fields"),
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
    r.ShowMessageBox(T("settings_missing"), "REAPER Multiplayer", 0)
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
local remove_item_comment_marker
local UI = { input = "", tab = 1, scroll = 0, hits = {}, a = {}, lastT = nil, dt = 1 / 30, needle = nil, needleV = 0 }
local mouse = { l = false, r = false, x = 0, y = 0, clicked = false, rclicked = false, wheel = 0 }
local TABS = { "tab_all", "tab_chat", "tab_comments", "tab_activity" }

-- Paleta jak w aplikacji Sesja: granat studyjny, bursztyn wskaźnika VU, krem taśmy.
local C = {
  ink = { 14, 20, 36 }, ink2 = { 11, 16, 32 }, panel = { 22, 30, 51 }, panel2 = { 28, 37, 64 },
  raise = { 36, 46, 78 }, line = { 44, 53, 82 }, paper = { 234, 227, 210 }, paper2 = { 201, 195, 180 },
  muted = { 142, 149, 171 }, dim = { 93, 100, 122 }, amber = { 243, 167, 59 }, amberHi = { 247, 183, 88 },
  amberInk = { 42, 26, 4 }, rec = { 240, 82, 79 }, signal = { 95, 201, 181 },
}

local function col(c, a) gfx.set(c[1] / 255, c[2] / 255, c[3] / 255, a or 1) end
local function mix(c1, c2, t) return { c1[1] + (c2[1] - c1[1]) * t, c1[2] + (c2[2] - c1[2]) * t, c1[3] + (c2[3] - c1[3]) * t } end
local function set_rgb(rr, gg, bb, a) gfx.set(rr / 255, gg / 255, bb / 255, a or 1) end
local function set_hex(hex, a)
  local rr, gg, bb = hex_to_rgb(hex)
  set_rgb(rr, gg, bb, a)
end
local function hex_c(hex) local rr, gg, bb = hex_to_rgb(hex) return { rr, gg, bb } end

local function color_of(user)
  if user == "system" then return "#8e95ab" end
  return user_color_hex(user) or "#c9c3b4"
end

local function inside(x, y, w, h) return mouse.x >= x and mouse.x < x + w and mouse.y >= y and mouse.y < y + h end

-- Płynne przejście wartości (hover, położenie zakładki itp.); niezależne od liczby klatek.
local function anim(key, target, speed)
  local cur = UI.a[key]
  if cur == nil then
    UI.a[key] = target
    return target
  end
  cur = cur + (target - cur) * math.min(1, UI.dt * (speed or 14))
  if math.abs(target - cur) < 0.002 then cur = target end
  UI.a[key] = cur
  return cur
end

-- Wypełniony prostokąt z zaokrąglonymi rogami (gfx ma tylko obrys roundrect).
local function rrect(x, y, w, h, rad)
  x, y, w, h = math.floor(x), math.floor(y), math.floor(w), math.floor(h)
  rad = math.floor(math.max(0, math.min(rad, h / 2, w / 2)))
  if rad < 1 then gfx.rect(x, y, w, h, 1) return end
  gfx.rect(x + rad, y, w - 2 * rad, h, 1)
  gfx.rect(x, y + rad, rad, h - 2 * rad, 1)
  gfx.rect(x + w - rad, y + rad, rad, h - 2 * rad, 1)
  gfx.circle(x + rad, y + rad, rad, 1, 1)
  gfx.circle(x + w - rad - 1, y + rad, rad, 1, 1)
  gfx.circle(x + rad, y + h - rad - 1, rad, 1, 1)
  gfx.circle(x + w - rad - 1, y + h - rad - 1, rad, 1, 1)
end

-- Łuk o zadanej grubości (z odcinków – niezależny od konwencji kątów gfx.arc).
local function arc(cx, cy, rad, a0, a1, thick)
  local steps = math.max(8, math.floor(math.abs(a1 - a0) * rad / 2.5))
  local k = -thick / 2
  while k <= thick / 2 do
    local rr, px, py = rad + k, nil, nil
    for i = 0, steps do
      local ang = a0 + (a1 - a0) * i / steps
      local x, y = cx + math.cos(ang) * rr, cy + math.sin(ang) * rr
      if px then gfx.line(px, py, x, y, 1) end
      px, py = x, y
    end
    k = k + 0.6
  end
end

local function text_at(x, y, str, font, c, a)
  gfx.setfont(font)
  col(c, a)
  gfx.x, gfx.y = x, y
  gfx.drawstr(str)
end

local function ellipsize(str, maxw)
  if gfx.measurestr(str) <= maxw then return str end
  while #str > 1 and gfx.measurestr(str .. "…") > maxw do
    str = str:sub(1, (utf8.offset(str, -1) or #str) - 1)
  end
  return str .. "…"
end

-- Przycisk-pigułka. kind: primary | ghost | soft
local function button(x, y, w, h, label, kind, key)
  key = key or label
  local hover = inside(x, y, w, h)
  local hv = anim("b:" .. key, hover and 1 or 0, 18)
  local press = hover and mouse.l and 1 or 0
  local inset = press
  if kind == "primary" then
    col(mix(C.amber, C.amberHi, hv))
  elseif kind == "ghost" then
    col(mix(C.ink, C.panel2, hv))
  else
    col(mix(C.panel2, C.raise, hv))
  end
  rrect(x + inset, y + inset, w - 2 * inset, h - 2 * inset, h / 2)
  if kind == "ghost" then
    col(mix(C.line, C.amber, hv * 0.6))
    gfx.roundrect(x + inset, y + inset, w - 2 * inset - 1, h - 2 * inset - 1, (h - 2 * inset) / 2, 1)
  end
  gfx.setfont(kind == "primary" and 5 or 2)
  col(kind == "primary" and C.amberInk or C.paper)
  local tw, th = gfx.measurestr(label)
  gfx.x, gfx.y = math.floor(x + (w - tw) / 2), math.floor(y + (h - th) / 2)
  gfx.drawstr(label)
  return hover and mouse.clicked
end

local function avatar(cx, cy, rad, name, color)
  col(hex_c(color))
  gfx.circle(cx, cy, rad, 1, 1)
  gfx.setfont(rad >= 12 and 6 or 7)
  col(C.ink)
  local ini = (name or "?"):match("^[%z\1-\127\194-\244][\128-\191]*") or "?"
  ini = ini:upper()
  local tw, th = gfx.measurestr(ini)
  gfx.x, gfx.y = math.floor(cx - tw / 2 + 0.5), math.floor(cy - th / 2 + 0.5)
  gfx.drawstr(ini)
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
  if e.kind == "comment" then
    if e.itemName then return T("comment_item", e.itemName, M.fmt_pos(e.pos), e.text) end
    return T("comment_pos", M.fmt_pos(e.pos), e.text)
  end
  if e.kind == "act" and (e.n or 1) > 1 then return e.text .. " (×" .. e.n .. ")" end
  return e.text
end

local LH = 18

local function layout_entry(e, W)
  local text = entry_text(e)
  if e._w == W and e._t == text then return e._lines end
  gfx.setfont(1)
  e._lines = wrap(text, W, W)
  e._w, e._t = W, text
  return e._lines
end

local function entry_height(e, W) return LH + #layout_entry(e, W) * LH + 10 end

local function draw_feed(x, y, w, h)
  col(C.panel)
  rrect(x, y, w, h, 12)
  local list = {}
  for _, e in ipairs(FEED) do if entry_visible(e) then list[#list + 1] = e end end
  local textX = x + 40
  local innerW = w - 40 - 14
  local total = 0
  for _, e in ipairs(list) do total = total + entry_height(e, innerW) end
  local viewH = h - 12
  local maxScroll = math.max(0, total - viewH)
  UI.scroll = math.max(0, math.min(UI.scroll, maxScroll))
  local scroll = anim("scroll", UI.scroll, 16)
  local by = y + h - 6 + scroll
  local t = now()
  UI.hits = {}
  if #list == 0 then
    text_at(x + 16, y + 16, T("select_hint"), 2, C.dim)
  end
  for i = #list, 1, -1 do
    local e = list[i]
    local lines = layout_entry(e, innerW)
    local eh = LH + #lines * LH + 10
    local ey = by - eh
    if ey + eh < y then break end
    -- wejście: łagodne pojawienie się i wysunięcie o kilka pikseli
    local k = math.min(1, math.max(0, (t - (e.t0 or 0)) / 0.35))
    local ease = 1 - (1 - k) * (1 - k) * (1 - k)
    local dy = math.floor((1 - ease) * 8)
    local alpha = ease
    if ey >= y - 2 and ey + eh <= y + h + 2 then
      local hover = e.kind == "comment" and inside(x, ey, w, eh)
      local hv = anim("h:" .. tostring(e), hover and 1 or 0, 16)
      if hv > 0.01 then
        col(mix(C.panel, C.panel2, hv))
        rrect(x + 6, ey + 2, w - 12, eh - 4, 8)
      end
      if e.kind == "comment" then
        col(C.amber, alpha)
        rrect(x + 8, ey + 6 + dy, 3, eh - 12, 1)
      end
      avatar(x + 26, ey + 14 + dy, 10, e.user == "system" and "•" or e.user, color_of(e.user))
      gfx.setfont(3)
      local name = e.user == "system" and "Sesja" or (e.user or "?")
      text_at(textX, ey + 5 + dy, name, 3, hex_c(color_of(e.user)), alpha)
      local nw = gfx.measurestr(name)
      local tstr = os.date("%H:%M", e.ts)
      text_at(textX + nw + 8, ey + 6 + dy, tstr, 2, C.dim, alpha)
      for li, line in ipairs(lines) do
        local tc = e.kind == "act" and C.muted or e.kind == "comment" and C.amber or C.paper
        text_at(textX, ey + 5 + LH * li + dy, line, 1, tc, alpha)
      end
      UI.hits[#UI.hits + 1] = { e = e, y = ey, h = eh }
    end
    by = ey
  end
  -- delikatne wygaszenie u góry listy, gdy coś jest przewinięte
  if maxScroll - scroll > 2 then
    for i = 0, 10 do
      col(C.panel, 1 - i / 11)
      gfx.rect(x + 6, y + 6 + i, w - 12, 1, 1)
    end
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
          local choice = gfx.showmenu(T("go_to", M.fmt_pos(hit.e.pos)) .. "|" .. T("delete_comment"))
          if choice == 1 then
            r.SetEditCurPos(hit.e.pos, true, false)
          elseif choice == 2 and S.state == "on" then
            remove_item_comment_marker(S.comments[hit.e.id])
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
    local s = T("added_by", label, m.author or "?")
    if m.created then s = s .. T("at_time", os.date("%H:%M", math.floor(m.created))) end
    if m.editor and m.editor ~= m.author then
      s = s .. T("edited_by", m.editor)
      if m.ts then s = s .. T("at_time", os.date("%H:%M", math.floor(m.ts))) end
    end
    return s
  end
  if it then
    local g = item_guid(it)
    local m = S.meta[g]
    local take = r.GetActiveTake(it)
    local name = take and r.GetTakeName(take) or T("clip")
    if m then return fmt(m, T("clip_label", name)) end
    return T("clip_unsynced", name)
  end
  local tr = r.GetSelectedTrack(0, 0)
  if tr then
    local m = S.meta[r.GetTrackGUID(tr)]
    local _, name = r.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    if name == "" then name = T("no_name") end
    if m then return fmt(m, T("track_label", name)) end
    return T("track_unsynced", name)
  end
  return T("select_hint")
end

-- Komentarz do zaznaczonego klipu: znacznik na samym klipie (take marker),
-- który synchronizuje się razem z klipem, + wpis na liście komentarzy.
local TAKE_MARK_PREFIX = "\u{1F4AC} "
local function add_item_comment(item, txt, id)
  local take = r.GetActiveTake(item)
  local ipos = r.GetMediaItemInfo_Value(item, "D_POSITION")
  local ilen = r.GetMediaItemInfo_Value(item, "D_LENGTH")
  local cur = r.GetCursorPosition()
  if cur < ipos or cur > ipos + ilen then cur = ipos end
  if take and r.SetTakeMarker then
    local rate = r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
    local offs = r.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
    local col = S.myColor and native_color(S.myColor) or 0
    r.SetTakeMarker(take, -1, TAKE_MARK_PREFIX .. CFG.user .. ": " .. txt, (cur - ipos) * rate + offs, col)
    r.UpdateArrange()
  end
  local name = take and r.GetTakeName(take) or T("clip")
  return { t = "comment", id = id, pos = cur, text = txt, item = item_guid(item), itemName = name }
end

function remove_item_comment_marker(c)
  if not c or not c.item then return end
  for i = 0, r.CountMediaItems(0) - 1 do
    local it = r.GetMediaItem(0, i)
    if item_guid(it) == c.item then
      local take = r.GetActiveTake(it)
      if take and r.GetNumTakeMarkers then
        for k = r.GetNumTakeMarkers(take) - 1, 0, -1 do
          local _, name = r.GetTakeMarker(take, k)
          if name == TAKE_MARK_PREFIX .. c.user .. ": " .. c.text then r.DeleteTakeMarker(take, k) end
        end
        r.UpdateArrange()
      end
    end
  end
end

local function send_input(asComment)
  local txt = UI.input:gsub("^%s+", ""):gsub("%s+$", "")
  if txt == "" or S.state ~= "on" then return end
  if asComment then
    local id = S.cid .. "-" .. math.floor(now() * 1000)
    local item = r.GetSelectedMediaItem(0, 0)
    if item then
      S.outbox[#S.outbox + 1] = add_item_comment(item, txt, id)
    else
      S.outbox[#S.outbox + 1] = { t = "comment", id = id, pos = r.GetCursorPosition(), text = txt }
    end
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
    T("menu_settings"),
    (CFG.colorize and "!" or "") .. T("menu_colorize"),
    (S.state == "on" and "" or "#") .. T("menu_resync"),
    T("menu_clear"),
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

local function merged_users()
  -- ta sama osoba może być naraz w REAPERze i w aplikacji – pokazujemy ją raz, z dwiema plakietkami
  local list, by = {}, {}
  for _, u in ipairs(S.users) do
    local e = by[u.name]
    if not e then
      e = { name = u.name, color = u.color, reaper = false, app = false, pos = 0 }
      by[u.name] = e
      list[#list + 1] = e
    end
    if u.app then
      e.app = true
    else
      e.reaper, e.pos, e.play, e.rec, e.sel = true, u.pos or 0, u.play, u.rec, u.sel
    end
  end
  return list
end

local function draw_vu(cx, cy, rad)
  local a0, a1 = math.pi * 1.12, math.pi * 1.88
  local lvl = 0.1 + ACTIVITY.level * 0.85
  if S.state == "on" then lvl = lvl + 0.04 * math.sin(now() * 2.3) end
  if S.state == "connecting" then lvl = 0.35 + 0.3 * math.sin(now() * 6) end
  local target = a0 + (a1 - a0) * math.max(0, math.min(1, lvl))
  if not UI.needle then UI.needle = a0 end
  -- wskazówka na sprężynie (tłumienie ~0.75), jak prawdziwy miernik
  local k = 170
  local c = 2 * 0.75 * math.sqrt(k)
  local acc = -k * (UI.needle - target) - c * UI.needleV
  UI.needleV = UI.needleV + acc * UI.dt
  UI.needle = UI.needle + UI.needleV * UI.dt
  col(C.line)
  arc(cx, cy, rad, a0, a1, 2.4)
  col(C.rec)
  arc(cx, cy, rad, a0 + (a1 - a0) * 0.8, a1, 2.4)
  col(C.amber)
  arc(cx, cy, rad, a0, math.max(a0, math.min(a1, UI.needle)), 2.4)
  local nx, ny = cx + math.cos(UI.needle) * rad * 0.92, cy + math.sin(UI.needle) * rad * 0.92
  for o = -0.6, 0.6, 0.6 do gfx.line(cx + o, cy, nx + o, ny, 1) end
  gfx.circle(cx, cy, 3, 1, 1)
end

local function status_pill(x, y, st)
  local label, c
  if st == "on" then
    label, c = T("st_on"), C.signal
  elseif st == "connecting" then
    label, c = T("st_connecting"), C.amber
  elseif st == "error" then
    label, c = T("st_error"), C.rec
  else
    label, c = T("st_off"), C.muted
  end
  gfx.setfont(2)
  local tw = gfx.measurestr(label)
  local w = tw + 30
  col(C.panel2)
  rrect(x - w, y, w, 22, 11)
  -- „oddychająca” kropka: puls przy łączeniu i błędzie, delikatna poświata przy połączeniu
  local pulse = (st == "connecting" or st == "error") and (0.5 + 0.5 * math.sin(now() * 5)) or 1
  if st == "on" then
    col(c, 0.22 + 0.1 * math.sin(now() * 2))
    gfx.circle(x - w + 13, y + 11, 6, 1, 1)
  end
  col(c, 0.4 + 0.6 * pulse)
  gfx.circle(x - w + 13, y + 11, 3.5, 1, 1)
  text_at(x - w + 22, y + 4, label, 2, C.paper2)
  return w
end

local function person_card(x, y, u, maxw)
  local state, sc
  if u.reaper then
    if u.rec then
      state, sc = "REC " .. M.fmt_pos(u.pos), C.rec
    elseif u.play then
      state, sc = M.fmt_pos(u.pos), C.paper2
    else
      state, sc = "@ " .. M.fmt_pos(u.pos), C.muted
    end
  else
    state, sc = T("app_only"), C.muted
  end
  gfx.setfont(3)
  local nw = gfx.measurestr(u.name)
  gfx.setfont(7)
  local b1 = u.reaper and gfx.measurestr("REAPER") + 12 or 0
  local b2 = u.app and gfx.measurestr("Sesja") + 12 or 0
  gfx.setfont(2)
  local sw = gfx.measurestr(state) + (u.play and not u.rec and 12 or 0)
  local w = math.min(maxw, 52 + math.max(nw + 6 + b1 + b2 + (b1 > 0 and b2 > 0 and 4 or 0), sw) + 14)
  local h = 46
  local hover = inside(x, y, w, h)
  local hv = anim("p:" .. u.name, hover and 1 or 0, 16)
  col(mix(C.panel2, C.raise, hv))
  rrect(x, y, w, h, 12)
  local ax, ay = x + 24, y + 23
  if u.rec then
    -- pulsujący pierścień nagrywania
    local p = (now() * 1.4) % 1
    col(C.rec, (1 - p) * 0.8)
    gfx.circle(ax, ay, 15 + p * 7, 0, 1)
    col(C.rec)
    gfx.circle(ax, ay, 16, 0, 1)
  end
  avatar(ax, ay, 14, u.name, u.color)
  text_at(x + 46, y + 6, ellipsize(u.name, w - 60 - b1 - b2), 3, C.paper)
  gfx.setfont(3)
  local bx = x + 46 + math.min(gfx.measurestr(u.name), w - 60 - b1 - b2) + 6
  local function badge(label, c)
    gfx.setfont(7)
    local bw = gfx.measurestr(label) + 12
    col(mix(C.panel2, c, 0.25))
    rrect(bx, y + 8, bw, 15, 7)
    text_at(bx + 6, y + 9, label, 7, c)
    bx = bx + bw + 4
  end
  if u.reaper then badge("REAPER", C.amber) end
  if u.app then badge("Sesja", C.signal) end
  local sx = x + 46
  if u.play and not u.rec and u.reaper then
    col(C.paper2)
    gfx.triangle(sx, y + 28, sx, y + 36, sx + 7, y + 32)
    sx = sx + 12
  end
  text_at(sx, y + 25, ellipsize(state .. ((u.sel and u.sel ~= "") and ("  ·  " .. u.sel) or ""), x + w - sx - 10), 2, sc)
  return w, h
end

local function draw_toast(x, y, w)
  local ts = ACTIVITY.toast
  if not ts then return end
  local age = now() - ts.t0
  if age > 4.6 then
    ACTIVITY.toast = nil
    return
  end
  local a = math.min(1, age / 0.2) * math.min(1, (4.6 - age) / 0.4)
  local dy = math.floor((1 - math.min(1, age / 0.25)) * -10)
  col(C.raise, 0.96 * a)
  rrect(x, y + dy, w, 40, 10)
  col(C.amber, a)
  rrect(x + 8, y + 10 + dy, 3, 20, 1)
  avatar(x + 28, y + 20 + dy, 10, ts.user, color_of(ts.user))
  gfx.setfont(3)
  local nw = gfx.measurestr(ts.user)
  text_at(x + 44, y + 11 + dy, ts.user, 3, hex_c(color_of(ts.user)), a)
  gfx.setfont(1)
  text_at(x + 52 + nw, y + 11 + dy, ellipsize(ts.text, w - 64 - nw), 1, C.paper, a)
end

local function draw()
  local W, H = gfx.w, gfx.h
  local t = now()
  UI.dt = UI.lastT and math.max(0.001, math.min(0.1, t - UI.lastT)) or 1 / 30
  UI.lastT = t
  ACTIVITY.level = math.max(0, ACTIVITY.level - UI.dt * 0.5)

  col(C.ink)
  gfx.rect(0, 0, W, H, 1)
  -- delikatna bursztynowa poświata za wskaźnikiem
  for i = 0, 8 do
    col(C.amber, 0.004 * (8 - i) * (0.6 + ACTIVITY.level))
    gfx.circle(30, 40, 8 + i * 3, 1, 1)
  end
  local pad = 14
  local st = S.state

  -- nagłówek: żywy wskaźnik VU, nazwa, pokój, status i przyciski
  draw_vu(30, 40, 16)
  text_at(56, 12, "Sesja", 4, C.paper)
  gfx.setfont(2)
  local sub = T("subtitle", CFG.room)
  local nup, ndown, npend = 0, 0, 0
  for _ in pairs(S.uploads) do nup = nup + 1 end
  for _ in pairs(S.downloads) do ndown = ndown + 1 end
  for _ in pairs(S.pending) do npend = npend + 1 end
  text_at(56, 36, ellipsize(sub, W - 56 - 250), 2, C.muted)

  local bw = gfx.measurestr(st == "off" and T("connect") or T("disconnect")) + 28
  if button(W - pad - bw, 12, bw, 26, (st == "off") and T("connect") or T("disconnect"), st == "off" and "primary" or "soft", "conn") then
    if st == "off" then
      if (CFG.user ~= "" or open_settings()) then connect() end
    else
      disconnect()
    end
  end
  local mw = gfx.measurestr(T("menu")) + 26
  if button(W - pad - bw - 6 - mw, 12, mw, 26, T("menu"), "ghost", "menu") then show_menu() end
  status_pill(W - pad, 44, st)
  local y = 72

  -- pasek stanu: transfery audio, nagrywanie, błędy
  if nup + ndown + npend > 0 or #S.deferred > 0 then
    gfx.setfont(2)
    local msg = #S.deferred > 0 and T("recording_wait"):gsub("^%s+", "") or T("pending", nup, ndown, npend):gsub("^%s+", "")
    local c = #S.deferred > 0 and C.rec or C.signal
    local mw2 = gfx.measurestr(msg) + 34
    col(mix(C.ink, c, 0.14))
    rrect(pad, y, mw2, 22, 11)
    -- kręciołek transferu
    local ang = t * 6
    col(c)
    arc(pad + 13, y + 11, 5, ang, ang + 4.2, 1.5)
    text_at(pad + 24, y + 4, msg, 2, c)
    y = y + 30
  end
  if S.err then
    gfx.setfont(2)
    col(mix(C.ink, C.rec, 0.16))
    rrect(pad, y, W - 2 * pad, 24, 8)
    text_at(pad + 10, y + 5, ellipsize(S.err, W - 2 * pad - 20), 2, C.rec)
    y = y + 32
  end

  -- osoby w sesji
  local people = merged_users()
  text_at(pad, y, T("in_session"), 3, C.paper2)
  gfx.setfont(3)
  if #people > 0 then text_at(pad + gfx.measurestr(T("in_session")) + 8, y + 1, tostring(#people), 2, C.dim) end
  y = y + 24
  if #people == 0 then
    col(C.panel)
    rrect(pad, y, W - 2 * pad, 46, 12)
    text_at(pad + 16, y + 15, st == "on" and T("only_you") or T("nobody"), 2, C.dim)
    y = y + 56
  else
    local cx = pad
    local rowH = 0
    for _, u in ipairs(people) do
      gfx.setfont(3)
      local estW = math.min(W - 2 * pad, 52 + gfx.measurestr(u.name) + 120)
      if cx > pad and cx + estW > W - pad then
        cx = pad
        y = y + rowH + 8
      end
      local w, h = person_card(cx, y, u, W - pad - cx)
      cx = cx + w + 8
      rowH = h
    end
    y = y + rowH + 12
  end

  -- inspektor: kto dodał zaznaczony klip / ścieżkę
  col(C.panel)
  rrect(pad, y, W - 2 * pad, 30, 10)
  col(C.amber)
  gfx.circle(pad + 15, y + 15, 7, 0, 1)
  text_at(pad + 13, y + 8, "i", 7, C.amber)
  gfx.setfont(2)
  text_at(pad + 30, y + 8, ellipsize(inspector_text(), W - 2 * pad - 42), 2, C.paper2)
  y = y + 40

  -- zakładki z przesuwającym się podświetleniem
  local tabsW = W - 2 * pad
  col(C.panel)
  rrect(pad, y, tabsW, 30, 15)
  gfx.setfont(2)
  local tabW = {}
  local sumW = 0
  for i, key in ipairs(TABS) do
    tabW[i] = gfx.measurestr(T(key)) + 26
    sumW = sumW + tabW[i]
  end
  local tx = pad + 3
  local selX, selW = tx, tabW[1]
  for i, key in ipairs(TABS) do
    if i == UI.tab then selX, selW = tx, tabW[i] end
    tx = tx + tabW[i]
  end
  local ix, iw = anim("tabx", selX, 16), anim("tabw", selW, 16)
  col(C.raise)
  rrect(ix, y + 3, iw, 24, 12)
  col(C.amber)
  rrect(ix + iw / 2 - 8, y + 25, 16, 2, 1)
  tx = pad + 3
  for i, key in ipairs(TABS) do
    local hover = inside(tx, y, tabW[i], 30)
    local on = UI.tab == i
    text_at(tx + 13, y + 7, T(key), 2, on and C.paper or (hover and C.paper2 or C.muted))
    if hover and mouse.clicked then
      UI.tab = i
      UI.scroll = 0
    end
    tx = tx + tabW[i]
  end
  y = y + 38

  -- lista + powiadomienie
  local bottomH = 86
  local feedH = H - y - bottomH
  draw_feed(pad, y, W - 2 * pad, feedH)
  draw_toast(pad + 8, y + 8, W - 2 * pad - 16)

  -- pole wiadomości
  local iy = H - bottomH + 10
  local focus = anim("focus", UI.input ~= "" and 1 or 0, 12)
  col(C.ink2)
  rrect(pad, iy, W - 2 * pad, 32, 10)
  col(mix(C.line, C.amber, focus))
  gfx.roundrect(pad, iy, W - 2 * pad - 1, 31, 10, 1)
  gfx.setfont(1)
  local shown = UI.input
  while #shown > 0 and gfx.measurestr(shown) > W - 2 * pad - 28 do
    shown = shown:sub((utf8.offset(shown, 2) or (#shown + 1)))
  end
  if UI.input == "" then
    text_at(pad + 12, iy + 8, T("input_ph"), 1, C.dim)
  else
    text_at(pad + 12, iy + 8, shown, 1, C.paper)
  end
  local blink = 0.5 + 0.5 * math.cos(t * 5)
  col(C.amber, blink)
  local cxp = pad + 12 + (UI.input == "" and 0 or gfx.measurestr(shown))
  gfx.rect(cxp + 1, iy + 8, 2, 16, 1)

  -- przyciski
  local by = iy + 40
  gfx.setfont(5)
  local sw = gfx.measurestr(T("send")) + 32
  if button(pad, by, sw, 28, T("send"), "primary", "send") then send_input(false) end
  local selItem = r.GetSelectedMediaItem(0, 0)
  local cl
  if selItem then
    local tk = r.GetActiveTake(selItem)
    local nm = tk and r.GetTakeName(tk) or T("clip")
    if #nm > 24 then nm = nm:sub(1, (utf8.offset(nm, 22) or 23) - 1) .. "…" end
    cl = T("comment_on", nm)
  else
    cl = T("comment_at", M.fmt_pos(r.GetCursorPosition()))
  end
  gfx.setfont(2)
  local cw = math.min(gfx.measurestr(cl) + 32, W - 2 * pad - sw - 8)
  if button(pad + sw + 8, by, cw, 28, ellipsize(cl, cw - 24), "ghost", "comment") then send_input(true) end
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
  gfx.clear = 0x24140E -- tło okna (granat) zanim pierwsza klatka się narysuje
  gfx.init("Sesja – REAPER Multiplayer", tonumber(w) or 600, tonumber(h) or 700,
    tonumber(get_ext("dock", "0")) or 0, tonumber(x) or 120, tonumber(y) or 120)
  local font = IS_WIN and "Segoe UI" or "Arial"
  gfx.setfont(1, font, 15)
  gfx.setfont(2, font, 13)
  gfx.setfont(3, font, 15, string.byte("b"))
  gfx.setfont(4, font, 22, string.byte("b")) -- tytuł
  gfx.setfont(5, font, 13, string.byte("b")) -- przycisk główny
  gfx.setfont(6, font, 14, string.byte("b")) -- inicjał w dużym awatarze
  gfx.setfont(7, font, 11, string.byte("b")) -- plakietki, mały awatar
  r.atexit(on_exit)
  if CFG.user == "" then
    if open_settings() then connect() end
  else
    connect()
  end
  main_loop()
end

init()
