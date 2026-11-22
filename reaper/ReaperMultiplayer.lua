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

local VERSION = "1.8.0"
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
-- Parametry wtyczek dopisujemy do nagłówka ścieżki jako linie SESJA_FXP (tylko w Sesji,
-- nigdy do REAPERa). Dzięki nim odbiorca ustawia gałki na żywo, bez przeładowania wtyczki.
local PLUGIN_BLOCK = { VST = true, VST3 = true, AU = true, JS = true, DX = true, CLAP = true, LV2 = true, VIDEO_EFFECT = true }
function M.strip_fxp(header) return (header:gsub("\nSESJA_FXP [^\n]*", "")) end
function M.fxp_lines(header)
  local t = {}
  for l in (header .. "\n"):gmatch("(SESJA_FXP [^\n]*)\n") do t[#t + 1] = l end
  return table.concat(t, "\n")
end
--- Nagłówek bez wnętrza bloków wtyczek (stan binarny) i bez SESJA_FXP – „szkielet” do porównań.
function M.fx_skeleton(header)
  local out, depth, fxdepth, plug = {}, 0, nil, 0
  for _, line in ipairs(split_lines(header)) do
    if line:sub(1, 10) == "SESJA_FXP " then
      -- pomijamy
    elseif plug > 0 then
      if line:sub(1, 1) == "<" then plug = plug + 1 elseif line == ">" then plug = plug - 1 end
      if plug == 0 then out[#out + 1] = line; depth = depth - 1 end
    else
      out[#out + 1] = line
      if line:sub(1, 1) == "<" then
        depth = depth + 1
        local tok = line:match("^<(%S+)")
        if fxdepth and depth == fxdepth + 1 and PLUGIN_BLOCK[tok] then plug = 1 end
        if tok == "FXCHAIN" or tok == "FXCHAIN_REC" then fxdepth = depth end
      elseif line == ">" then
        if fxdepth and depth == fxdepth then fxdepth = nil end
        depth = depth - 1
      end
    end
  end
  return table.concat(out, "\n")
end

--- Lista wtyczek (linie otwierające bloki) – do sprawdzenia, czy łańcuch FX jest ten sam.
function M.fx_ids(header)
  local t = {}
  for _, line in ipairs(split_lines(header)) do
    local tok = line:match("^<(%S+)")
    if tok and PLUGIN_BLOCK[tok] then t[#t + 1] = line end
  end
  return table.concat(t, "\n")
end

function M.build_track_chunk(header, locals, items)
  local h = split_lines(M.strip_fxp(header))
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
-- akcje REAPERa: Track: Freeze to stereo (render pre-fader, save/remove items and online FX)
-- i Track: Unfreeze tracks (restore previously saved items and FX)
local FREEZE, UNFREEZE = 41223, 41644
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
  ask = get_ext("ask_tracks", "1") == "1", -- pytaj, zanim nowa ścieżka trafi do pokoju
  room_name = get_ext("room_name", ""),
  admin = get_ext("admin_key", ""), -- klucz gospodarza (tylko twórca sesji) -- nazwa sesji z aplikacji (pokój to wtedy kod z linku)
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
    file_gone = "Pliku %s nie ma już na dysku – dodaj go jeszcze raz (np. nie prosto z ZIP-a)", on_server = "wysyłany: %d%%",
    upload_failed = "Nie udało się wysłać pliku %s", rejected = "serwer odrzucił żądanie", server_said = "serwer: %s",
    conn_error = "Błąd połączenia", server_error = "Błąd serwera",
    no_curl = "Nie można uruchomić curl (%s)", no_answer = "Brak odpowiedzi serwera (%s)",
    state_error = "Błąd pobierania stanu", cant_connect = "Nie można połączyć",
    srv_bad_password = "Złe hasło", srv_bad_room = "Niepoprawna nazwa pokoju",
    srv_no_room = "Nie ma takiej sesji. Dołącz w aplikacji Sesja: Studio → Dołącz przez link",
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
    ask_track = "Nowa ścieżka „%s” – dodać do pokoju?", ask_more = "i jeszcze %d",
    role_admin = "Gospodarz", role_editor = "Edytor", host_badge = "GOSPODARZ",
    you = "Ty", comment_field = "Komentarz:", more_n = "i jeszcze %d…",
    btn_comment = "Komentarz", btn_comment_clip = "Komentarz do klipu",
    act_show = "Pokaż okno", act_comment = "Komentarz do zaznaczonego klipu",
    act_freeze = "Wyrenderuj zaznaczone ścieżki dla innych", act_unfreeze = "Odmroź zaznaczone ścieżki",
    act_share = "Dodaj zaznaczone ścieżki do pokoju", act_quit = "Rozłącz i zamknij",
    act_not_running = "Sesja nie jest teraz uruchomiona. Uruchom akcję „Sesja – Pokaż okno”.",
    proj_master = "zmienia efekty i ustawienia mastera", proj_markers = "zmienia markery i regiony",
    proj_tempomap = "zmienia mapę tempa i metrum",
    fx_missing = "Nie masz wtyczki „%s” (ścieżka „%s”) – nie usłyszysz jej efektu.", fx_ask = "Poproś o wersję audio",
    fx_hide = "Ukryj", fx_ask_chat = "Proszę o wersję audio ścieżki „%s” – nie mam wtyczki %s",
    fx_req = "%s nie ma wtyczki „%s” – wyrenderuj „%s” do audio dla innych?", fx_render = "Wyrenderuj dla innych",
    fx_later = "Nie teraz", menu_freeze = "Wyrenderuj zaznaczone ścieżki do audio dla innych (zamroź)",
    menu_unfreeze = "Przywróć zaznaczone ścieżki do edycji (odmroź)",
    req_q = "%s chce usunąć %s „%s”", req_yes = "Usuń", req_no = "Zostaw",
    draft_q = "Szkic: %s „%s” · dodał(a) %s", draft_ok = "Akceptuj", draft_no = "Odrzuć", draft_all = "Akceptuj wszystkie (%d)",
    k_track = "ścieżkę", k_item = "klip", k_track1 = "ścieżka", k_item1 = "klip",
    editor_wait = "Czeka na gospodarza: szkice %d · usunięcia %d",
    draft_label = "SZKIC – czeka na akceptację gospodarza · ",
    a_req_ok = "zgadza się na usunięcie „%s” (%s)", a_req_no = "zostawia „%s” – nie usunięto (%s)",
    a_draft_ok = "akceptuje szkic „%s” (%s)", a_draft_no = "odrzuca szkic „%s” (%s)",
    hide = "Ukryj", mini_open = "Rozwiń", menu_hide = "Ukryj okno – Sesja działa dalej w tle",
    menu_quit = "Rozłącz i zamknij", bg_hint = "Sesja działa w tle. Uruchom akcję „Sesja” ponownie, żeby pokazać okno.",
    online_n = "%d online",
    ask_add = "Dodaj do pokoju", ask_private = "Tylko u mnie", ask_always = "Zawsze dodawaj",
    ask_hint = "Dopóki nie zdecydujesz, inni jej nie widzą.",
    menu_ask = "Pytaj przed dodaniem nowej ścieżki do pokoju", menu_share_private = "Dodaj do pokoju ścieżki „tylko u mnie” (%d)",
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
    file_gone = "File %s is no longer on disk – add it again (e.g. not straight from a ZIP)", on_server = "uploading: %d%%",
    upload_failed = "Could not upload file %s", rejected = "the server rejected the request", server_said = "server: %s",
    conn_error = "Connection error", server_error = "Server error",
    no_curl = "Cannot start curl (%s)", no_answer = "No answer from the server (%s)",
    state_error = "Could not load the project state", cant_connect = "Cannot connect",
    srv_bad_password = "Wrong password", srv_bad_room = "Invalid room name",
    srv_no_room = "This session doesn’t exist. Join in the Sesja app: Studio → Join with a link",
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
    ask_track = "New track “%s” – add it to the room?", ask_more = "and %d more",
    role_admin = "Host", role_editor = "Editor", host_badge = "HOST",
    you = "you", comment_field = "Comment:", more_n = "and %d more…",
    btn_comment = "Comment", btn_comment_clip = "Comment on clip",
    act_show = "Show window", act_comment = "Comment on selected clip",
    act_freeze = "Render selected tracks for others", act_unfreeze = "Unfreeze selected tracks",
    act_share = "Add selected tracks to the room", act_quit = "Disconnect and close",
    act_not_running = "Sesja isn’t running right now. Run the action “Sesja – Show window”.",
    proj_master = "changed the master FX and settings", proj_markers = "changed markers and regions",
    proj_tempomap = "changed the tempo map and time signature",
    fx_missing = "You don’t have the plugin “%s” (track “%s”) – you won’t hear its effect.", fx_ask = "Ask for an audio version",
    fx_hide = "Hide", fx_ask_chat = "Please share an audio version of track “%s” – I don’t have the plugin %s",
    fx_req = "%s doesn’t have the plugin “%s” – render “%s” to audio for others?", fx_render = "Render for others",
    fx_later = "Not now", menu_freeze = "Render selected tracks to audio for others (freeze)",
    menu_unfreeze = "Restore selected tracks for editing (unfreeze)",
    req_q = "%s wants to delete %s “%s”", req_yes = "Delete", req_no = "Keep",
    draft_q = "Draft: %s “%s” · by %s", draft_ok = "Accept", draft_no = "Reject", draft_all = "Accept all (%d)",
    k_track = "track", k_item = "clip", k_track1 = "track", k_item1 = "clip",
    editor_wait = "Waiting for the host: drafts %d · deletions %d",
    draft_label = "DRAFT – waiting for the host · ",
    a_req_ok = "approved deleting “%s” (%s)", a_req_no = "kept “%s” – not deleted (%s)",
    a_draft_ok = "accepted the draft “%s” (%s)", a_draft_no = "rejected the draft “%s” (%s)",
    hide = "Hide", mini_open = "Expand", menu_hide = "Hide window – Sesja keeps running in the background",
    menu_quit = "Disconnect and close", bg_hint = "Sesja runs in the background. Run the “Sesja” action again to show the window.",
    online_n = "%d online",
    ask_add = "Add to room", ask_private = "Only for me", ask_always = "Always add",
    ask_hint = "Others won’t see it until you decide.",
    menu_ask = "Ask before adding a new track to the room", menu_share_private = "Add my “only for me” tracks to the room (%d)",
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
local RESUME = false -- po ponownym uruchomieniu: wróć do sesji bez pytania
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
    uploads = {}, downloads = {}, want = {}, uploadFails = {}, uploadRetry = {}, uploadProg = {},
    serverParts = nil, -- serwer przyjmuje pliki w częściach tej wielkości
    baseProj = {}, -- ostatnio wysłany/otrzymany master, markery, mapa tempa
    missingFx = {}, fxHidden = {}, fxRequests = {}, nextFxScan = 0,
    lastPending = 0, lastSyncedSave = 0, syncedDirty = false,
    serverInfo = "",
    role = "admin", roles = false, requests = {}, drafts = {}, draftSet = {},
    known = {}, -- ścieżki, które już są w pokoju albo zostały zatwierdzone
    held = {}, heldOrder = {}, -- nowe ścieżki czekające na decyzję: guid -> nazwa
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
  if CFG.admin ~= "" then c = c .. " -H " .. q("X-Sesja-Admin: " .. safe_key(CFG.admin)) end
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
  HIDDEN_VBS = TMP .. SEP .. "sesja_hidden2.vbs"
  write_file(HIDDEN_VBS, table.concat({
    "' Sesja: uruchamia polecenie z pliku bez okna konsoli i zapisuje kod wyjścia",
    "Dim fso, f, cmd, rc",
    "Set fso = CreateObject(\"Scripting.FileSystemObject\")",
    "Set f = fso.OpenTextFile(WScript.Arguments(0), 1, False, -1)",
    "cmd = f.ReadAll",
    "f.Close",
    "fso.DeleteFile WScript.Arguments(0)",
    "rc = CreateObject(\"WScript.Shell\").Run(cmd, 0, True)",
    "If WScript.Arguments.Count > 1 Then",
    "  Set f = fso.CreateTextFile(WScript.Arguments(1), True)",
    "  f.Write CStr(rc)",
    "  f.Close",
    "End If",
  }, "\r\n") .. "\r\n")
  return HIDDEN_VBS
end

-- Uruchamia curl w tle. done: plik, w który po zakończeniu trafia kod wyjścia – dzięki niemu
-- wiemy od razu, że curl skończył (np. serwer odrzucił plik), zamiast czekać do limitu czasu.
local function run(cmd, done)
  if IS_WIN and CFG.hidden and file_exists(WSCRIPT) then
    local cmdfile = new_tmp("cmd")
    write_file(cmdfile, M.utf16le(cmd))
    r.ExecProcess(q(WSCRIPT) .. " //B //Nologo " .. q(hidden_runner()) .. " " .. q(cmdfile)
      .. (done and (" " .. q(done)) or ""), -1)
  elseif done and not IS_WIN then
    local inner = cmd .. "; echo $? > " .. q(done)
    r.ExecProcess("/bin/sh -c '" .. inner:gsub("'", "'\\''") .. "'", -1)
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
    jobs[#jobs + 1] = { kind = "json", out = out, inp = inp, cb = cb, t0 = now(), timeout = timeout + 4, done = out .. ".rc" }
  else
    jobs[#jobs + 1] = { kind = "json", out = out, cb = cb, t0 = now(), timeout = timeout + 4, done = out .. ".rc" }
  end
  cmd = cmd .. " " .. q(url(path))
  if not run(cmd, out .. ".rc") then
    local j = table.remove(jobs)
    j.cb(nil, T("no_curl", CFG.curl))
  end
end

local function http_upload(id, localPath, cb, part, parts)
  local out = new_tmp("json")
  local path = "/api/file?room=" .. CFG.room .. "&id=" .. id
  if part then path = path .. "&part=" .. part .. "&parts=" .. parts end
  -- --speed-limit: przerwij, gdy przez 60 s idzie mniej niż 1 KB/s (zerwane łącze)
  local cmd = curl_base() .. " --max-time 1800 --speed-limit 1024 --speed-time 60 -H " .. q("Expect:") ..
    " -T " .. q(localPath) .. " -o " .. q(out) .. " " .. q(url(path))
  jobs[#jobs + 1] = { kind = "json", out = out, cb = cb, t0 = now(), timeout = 1810, done = out .. ".rc" }
  if not run(cmd, out .. ".rc") then
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
    t0 = now(), lastGrow = now(), lastSize = -1, timeout = 3610, done = tmp .. ".rc",
  }
  if not run(cmd, tmp .. ".rc") then
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
      -- curl skończył, a odpowiedzi JSON brak (np. serwer odrzucił plik stroną HTML)
      local finished = not done and j.done and file_exists(j.done) and (j.doneSeen or 0) > 0 and t - j.doneSeen > 0.5
      if not done and j.done and file_exists(j.done) and not j.doneSeen then j.doneSeen = t end
      if finished or (not done and t - j.t0 > j.timeout) then
        done = true
        local body = read_file(j.out) or ""
        os.remove(j.out)
        if j.inp then os.remove(j.inp) end
        local code = body:match("<title>(.-)</title>") or (finished and T("rejected")) or nil
        j.cb(nil, code and T("server_said", code) or T("no_answer", CFG.server))
      end
      if done and j.done then os.remove(j.done) end
    else -- plik
      local sz = file_size(j.out)
      if sz and sz ~= j.lastSize then j.lastSize, j.lastGrow = sz, t end
      if sz and j.size and sz == j.size then
        done = true
        os.remove(j.dest)
        local ok = os.rename(j.out, j.dest)
        j.cb(ok and true or false)
      elseif t - j.lastGrow > 45 or t - j.t0 > j.timeout
        or (j.done and file_exists(j.done) and t - (j.lastGrow or 0) > 1) then
        done = true
        os.remove(j.out)
        j.cb(false)
      end
      if done and j.done then os.remove(j.done) end
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

-- Ścieżki „tylko u mnie”: zapisane w projekcie, nigdy nie trafiają do pokoju.
local PRIVATE = {}
local function load_private()
  PRIVATE = {}
  local _, v = r.GetProjExtState(0, SEC, "private")
  for g in (v or ""):gmatch("[^,]+") do PRIVATE[g] = true end
end
local function save_private()
  local l = {}
  for g in pairs(PRIVATE) do l[#l + 1] = g end
  r.SetProjExtState(0, SEC, "private", table.concat(l, ","))
end
load_private()

-- czy ścieżka ma czekać na pytanie „dodać do pokoju?”
local function needs_ask(g)
  return CFG.ask and S.state == "on" and not S.known[g] and not S.meta[g] and not S.baseTracks[g]
end

-- Wysyłki (sendy) w REAPERze wskazują ścieżkę źródłową numerem – u każdego może być inny.
-- Na serwer idą z GUID ścieżki, a u odbiorcy zamieniamy je z powrotem na jego numer.
local function sends_to_guid(header)
  return (header:gsub("\nAUXRECV (%d+)([^\n]*)", function(idx, rest)
    local src = r.GetTrack(0, tonumber(idx))
    if not src then return "\nAUXRECV " .. idx .. rest end
    local g = r.GetTrackGUID(src)
    if PRIVATE[g] or S.held[g] then return "" end -- źródło jest tylko u mnie
    return "\nAUXRECV " .. g .. rest
  end))
end
local function sends_to_index(header, tmap)
  local unresolved = false
  local out = header:gsub("\nAUXRECV ({[%x%-]+})([^\n]*)", function(g, rest)
    local tr = tmap[g]
    if not tr then unresolved = true return "" end
    return "\nAUXRECV " .. math.floor(r.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER") - 1) .. rest
  end)
  return out, unresolved
end

-- wartości parametrów wtyczek ścieżki (lub mastera) jako linie SESJA_FXP
local MAX_FX_PARAMS = 512
local function fxp_for(tr)
  if not r.TrackFX_GetCount then return "" end
  local lines = {}
  for fx = 0, r.TrackFX_GetCount(tr) - 1 do
    local n = r.TrackFX_GetNumParams(tr, fx)
    if n <= MAX_FX_PARAMS then
      local v = {}
      for p = 0, n - 1 do v[p + 1] = string.format("%.4f", r.TrackFX_GetParamNormalized(tr, fx, p)) end
      lines[#lines + 1] = "SESJA_FXP " .. fx .. " " .. table.concat(v, ",")
    else
      lines[#lines + 1] = "SESJA_FXP " .. fx .. " -"
    end
  end
  return table.concat(lines, "\n")
end
local function with_fxp(header, tr)
  local f = fxp_for(tr)
  if f == "" or header:sub(-2) ~= "\n>" then return header end
  return header:sub(1, -2) .. f .. "\n>"
end
-- ustawia gałki wtyczek z linii SESJA_FXP; false = nie da się (inna liczba wtyczek / parametrów)
local function apply_fxp(tr, header)
  if not r.TrackFX_SetParamNormalized then return false end
  local cnt = r.TrackFX_GetCount(tr)
  for l in (header .. "\n"):gmatch("SESJA_FXP ([^\n]*)\n") do
    local fx, list = l:match("^(%d+) (.*)$")
    fx = tonumber(fx)
    if not fx or fx >= cnt or list == "-" then return false end
    local p = 0
    for v in list:gmatch("[^,]+") do
      local want = tonumber(v) or 0
      if math.abs(r.TrackFX_GetParamNormalized(tr, fx, p) - want) > 0.00015 then
        r.TrackFX_SetParamNormalized(tr, fx, p, want)
      end
      p = p + 1
    end
  end
  return true
end

local function snapshot()
  local snap = { tracks = {}, items = {}, order = {} }
  local held = {}
  for i = 0, r.CountTracks(0) - 1 do
    local tr = r.GetTrack(0, i)
    local g = r.GetTrackGUID(tr)
    if PRIVATE[g] then goto continue end
    if S.held[g] or needs_ask(g) then
      local _, nm = r.GetTrackName(tr)
      held[g] = nm
      goto continue
    end
    S.known[g] = true
    do
    local _, chunk = r.GetTrackStateChunk(tr, "", false)
    local header, _, items = M.normalize_track(chunk)
    header = with_fxp(sends_to_guid(header), tr)
    snap.tracks[g] = { header = header, idx = i }
    snap.order[#snap.order + 1] = g
    for _, ic in ipairs(items) do
      local norm, refs, ig = M.normalize_item(ic, path_to_ref)
      if ig then snap.items[ig] = { chunk = norm, track = g, refs = refs } end
    end
    end
    ::continue::
  end
  -- kolejka pytań: nowe na końcu, usunięte znikają
  local order = {}
  for _, g in ipairs(S.heldOrder) do if held[g] then order[#order + 1] = g end end
  for g in pairs(held) do if not S.held[g] then order[#order + 1] = g end end
  if #order > #S.heldOrder then ACTIVITY.level = math.min(1, ACTIVITY.level + 0.3) end
  S.held, S.heldOrder = held, order
  return snap
end

-- odpowiedzi na pytanie o nową ścieżkę
local function approve_track(g) S.held[g] = nil; S.known[g] = true; S.nextSync = 0 end
local function keep_private(g) S.held[g] = nil; PRIVATE[g] = true; save_private() end

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

-------------------------------------------------------------------------------
-- Projekt: master z efektami, markery i regiony, mapa tempa (ostatni zapis wygrywa)
-------------------------------------------------------------------------------
local PROJ_KEYS = { "master", "markers", "tempomap" }
local function fnum(x) return string.format("%.10g", x or 0) end

local function proj_read(key)
  if key == "master" then
    if not r.GetMasterTrack then return nil end
    local m = r.GetMasterTrack(0)
    local _, chunk = r.GetTrackStateChunk(m, "", false)
    return with_fxp((M.normalize_track(chunk or "")), m)
  elseif key == "markers" then
    if not r.EnumProjectMarkers3 then return nil end
    local out, i = {}, 0
    while true do
      local ok, rgn, pos, rend, name, idx, color = r.EnumProjectMarkers3(0, i)
      if ok == 0 then break end
      if not (name or ""):find(MARK, 1, true) then -- markery-komentarze synchronizują się osobno
        out[#out + 1] = table.concat({ rgn and "R" or "M", fnum(pos), fnum(rend), tostring(idx), tostring(color), name or "" }, "\t")
      end
      i = i + 1
    end
    return table.concat(out, "\n")
  elseif key == "tempomap" then
    if not r.GetTempoTimeSigMarker then return nil end
    local out = {}
    for i = 0, r.CountTempoTimeSigMarkers(0) - 1 do
      local _, tpos, _, _, bpm, num, den, lin = r.GetTempoTimeSigMarker(0, i)
      out[#out + 1] = table.concat({ fnum(tpos), fnum(bpm), tostring(num), tostring(den), lin and "1" or "0" }, "\t")
    end
    return table.concat(out, "\n")
  end
end

local function proj_apply(key, data)
  data = data or ""
  if key == "master" and r.GetMasterTrack then
    local m = r.GetMasterTrack(0)
    local _, cur = r.GetTrackStateChunk(m, "", false)
    local h, locals = M.normalize_track(cur or "")
    if data ~= "" then
      if M.fx_skeleton(h) == M.fx_skeleton(data) and apply_fxp(m, data) then
        -- tylko gałki na masterze
      elseif M.strip_fxp(h) ~= M.strip_fxp(data) then
        r.SetTrackStateChunk(m, M.build_track_chunk(data, locals, {}), false)
        apply_fxp(m, data)
      end
    end
  elseif key == "markers" and r.EnumProjectMarkers3 then
    local i, del = 0, {}
    while true do
      local ok, _, _, _, name = r.EnumProjectMarkers3(0, i)
      if ok == 0 then break end
      if not (name or ""):find(MARK, 1, true) then del[#del + 1] = i end
      i = i + 1
    end
    for k = #del, 1, -1 do r.DeleteProjectMarkerByIndex(0, del[k]) end
    for line in (data .. "\n"):gmatch("(.-)\n") do
      local k, pos, rend, idx, color, name = line:match("^([MR])\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")
      if k then
        r.AddProjectMarker2(0, k == "R", tonumber(pos) or 0, tonumber(rend) or 0, name, tonumber(idx) or -1, tonumber(color) or 0)
      end
    end
  elseif key == "tempomap" and r.SetTempoTimeSigMarker then
    for i = r.CountTempoTimeSigMarkers(0) - 1, 0, -1 do r.DeleteTempoTimeSigMarker(0, i) end
    for line in (data .. "\n"):gmatch("(.-)\n") do
      local tpos, bpm, num, den, lin = line:match("^([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)$")
      if tpos then
        r.SetTempoTimeSigMarker(0, -1, tonumber(tpos), -1, -1, tonumber(bpm), tonumber(num) or 0, tonumber(den) or 0, lin == "1")
      end
    end
    r.UpdateTimeline()
  end
  S.baseProj[key] = proj_read(key)
end

local function apply_remote_ops(ops, undoName)
  if #ops == 0 then return end
  local tmap, imap = track_map(), item_map()
  local aff = { tracks = {}, items = {}, order = false, tempo = false }
  local who = {}
  local later = {}
  r.PreventUIRefresh(1)
  r.Undo_BeginBlock2(0)
  for _, op in ipairs(ops) do
    local t = op.t
    if op.user then who[op.user] = true end
    if t == "track" and op.guid and op.chunk then
      local g = op.guid
      local tr = tmap[g]
      local hdr, unresolved = sends_to_index(op.chunk, tmap)
      if unresolved then later[#later + 1] = op end -- źródło wysyłki przyjdzie w tej samej paczce
      if not tr then
        local n = r.CountTracks(0)
        r.InsertTrackAtIndex(n, false)
        tr = r.GetTrack(0, n)
        r.SetTrackStateChunk(tr, M.build_track_chunk(hdr, {}, {}), false)
        pcall(r.GetSetMediaTrackInfo_String, tr, "GUID", g, true)
        tmap[g] = tr
        aff.order = true
      else
        local _, cur = r.GetTrackStateChunk(tr, "", false)
        local h, locals, items = M.normalize_track(cur)
        local mine = sends_to_guid(h)
        local plain = M.strip_fxp(op.chunk)
        -- zmiana samych gałek: ustawiamy tylko gałki – reszty (np. głośności zmienionej w tym
        -- samym czasie przez kogoś innego) nie ruszamy
        if op.po and M.fx_ids(mine) == M.fx_ids(op.chunk) and apply_fxp(tr, op.chunk) then
          -- same gałki: ustawione na żywo, wtyczka gra dalej
        elseif M.strip_fxp(mine) ~= plain and not fast_track(tr, h, M.strip_fxp(hdr)) then
          r.SetTrackStateChunk(tr, M.build_track_chunk(hdr, locals, items), false)
        elseif r.TrackFX_SetParamNormalized then
          apply_fxp(tr, op.chunk)
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
    elseif t == "proj" and op.key then
      proj_apply(op.key, op.data)
    elseif t == "tempo" and tonumber(op.bpm) then
      if r.CountTempoTimeSigMarkers(0) == 0 then r.SetCurrentBPM(0, tonumber(op.bpm), true) end
      aff.tempo = true
    end
  end
  -- druga runda: wysyłki, których ścieżka źródłowa doszła w tej samej paczce
  for _, op in ipairs(later) do
    local tr = tmap[op.guid]
    if tr then
      local hdr = sends_to_index(op.chunk, tmap)
      local _, cur = r.GetTrackStateChunk(tr, "", false)
      local _, locals, items = M.normalize_track(cur)
      r.SetTrackStateChunk(tr, M.build_track_chunk(hdr, locals, items), false)
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
    local base = S.baseTracks[g]
    if base ~= t.header then
      local op = { t = "track", guid = g, chunk = t.header, _idx = t.idx }
      -- zmieniły się tylko gałki wtyczek -> odbiorca ustawi je na żywo, bez przeładowania
      if base and M.fx_skeleton(base) == M.fx_skeleton(t.header) and M.fxp_lines(base) ~= M.fxp_lines(t.header) then
        op.po = true
      end
      trackOps[#trackOps + 1] = op
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

  for _, k in ipairs(PROJ_KEYS) do
    local v = proj_read(k)
    if v and v ~= S.baseProj[k] then
      if S.baseProj[k] ~= nil or v ~= "" then ops[#ops + 1] = { t = "proj", key = k, data = v } end
      S.baseProj[k] = v
    end
  end

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
  if t == "proj" then return "p:" .. tostring(op.key) end
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
  if t == "track" and g then S.known[g] = true end
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
  elseif t == "proj" and op.key then
    feed_activity(op, T("proj_" .. op.key), "proj:" .. op.key)
  elseif t == "tempo" then
    feed_activity(op, T("tempo", tonumber(op.bpm) or 0), "tempo")
  elseif t == "chat" then
    if op.fxreq and op.cid ~= S.cid then
      S.fxRequests[op.fxreq] = { user = user, fx = op.fxname or "?" }
    end
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
  elseif (t == "req_ok" or t == "req_no" or t == "draft_ok" or t == "draft_no") and op.name then
    local nm = op.name ~= "" and op.name or T("no_name")
    feed_add({ kind = "act", user = user, text = T("a_" .. t, nm, op.who or "?") })
    if op.cid ~= S.cid then ACTIVITY.toast = { user = user, text = T("a_" .. t, nm, op.who or "?"), t0 = now() } end
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

-- Koniec wysyłki pliku: sukces albo ponowienie za chwilę (rosnąca przerwa, bez poddawania się).
local function upload_finished(id, ok, err)
  S.uploads[id] = nil
  if ok then
    S.fileConfirmed[id] = true
    S.uploadFails[id], S.uploadRetry[id], S.uploadProg[id] = nil, nil, nil
    if S.err and S.err:find(T("upload_failed", ""), 1, true) then S.err = nil end
    return
  end
  local n = (S.uploadFails[id] or 0) + 1
  S.uploadFails[id] = n
  S.uploadRetry[id] = now() + math.min(300, 10 * 2 ^ (n - 1))
  local short = id:match("^(.-)~") or id
  status_err(T("upload_failed", short) .. (err and (": " .. err) or ""))
end

-- Wysyłka: małe pliki jednym żądaniem, duże w częściach (postęp, ponawianie części, brak
-- limitu rozmiaru żądania na serwerze).
local function start_upload(id, path)
  local size = file_size(path)
  -- plik zniknął albo zmienił się po dodaniu (np. jeszcze się kopiował): liczymy go od nowa,
  -- zamiast w kółko wysyłać nieaktualną wersję
  if not size or size ~= M.id_size(id) then
    S.uploads[id], S.fileLocal[id] = nil, nil
    idCache[path] = nil
    S.lastCC = -1
    if not size then status_err(T("file_gone", (path:match("([^/\\]+)$") or path))) end
    return
  end
  local P = S.serverParts
  if not P or size <= P then
    http_upload(id, path, function(resp, err) upload_finished(id, resp and resp.ok, err or (resp and server_msg(resp))) end)
    return
  end
  -- duży plik: do 3 części naraz (szybciej na łączach z dużym opóźnieniem)
  local parts = math.ceil(size / P)
  local prog = S.uploadProg[id]
  if not prog or prog.parts ~= parts then
    prog = { part = 0, parts = parts, done = {}, ndone = 0, next = 0, inflight = 0, fails = {}, dead = false }
    S.uploadProg[id] = prog
  end
  prog.next, prog.inflight, prog.dead = 0, 0, false
  local send_part
  local function launch()
    while not prog.dead and prog.inflight < 3 do
      while prog.next < parts and prog.done[prog.next] do prog.next = prog.next + 1 end
      if prog.next >= parts then return end
      local i = prog.next
      prog.next = prog.next + 1
      send_part(i)
    end
  end
  send_part = function(i)
    local fi = io.open(path, "rb")
    if not fi then prog.dead = true return upload_finished(id, false, T("file_gone", id)) end
    fi:seek("set", i * P)
    local data = fi:read(P) or ""
    fi:close()
    local tmp = new_tmp("part")
    write_file(tmp, data)
    data = nil
    prog.inflight = prog.inflight + 1
    http_upload(id, tmp, function(resp, err)
      os.remove(tmp)
      prog.inflight = prog.inflight - 1
      if prog.dead then return end
      if resp and resp.ok then
        if not prog.done[i] then prog.done[i] = true; prog.ndone = prog.ndone + 1 end
        prog.part = prog.ndone
        if resp.done then
          prog.dead = true
          return upload_finished(id, true)
        end
        launch()
        if prog.inflight == 0 and not prog.dead then
          -- wszystkie części wysłane, a serwer nie potwierdził całości – zaczniemy od nowa
          prog.dead, prog.done, prog.ndone = true, {}, 0
          upload_finished(id, false, T("rejected"))
        end
      else
        prog.fails[i] = (prog.fails[i] or 0) + 1
        if prog.fails[i] <= 4 then
          send_part(i) -- ta sama część jeszcze raz
        else
          prog.dead = true
          upload_finished(id, false, err or (resp and server_msg(resp)))
        end
      end
    end, i, parts)
  end
  launch()
end

local function pump_transfers()
  local up, down = 0, 0
  for _, st in pairs(S.uploads) do if st == "busy" then up = up + 1 end end
  for _, st in pairs(S.downloads) do if st == "busy" then down = down + 1 end end
  local t = now()
  for id, st in pairs(S.uploads) do
    if st == "queued" and up < 2 and t >= (S.uploadRetry[id] or 0) then
      local p = S.fileLocal[id]
      if not p or not file_exists(p) then
        S.uploads[id] = nil
      else
        S.uploads[id] = "busy"
        up = up + 1
        start_upload(id, p)
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

-- rola, prośby i szkice z odpowiedzi serwera (starsze serwery ich nie wysyłają)
local function read_review(resp)
  S.roles = resp.roles == true
  S.role = resp.role or "admin"
  S.requests = resp.requests or {}
  S.drafts = resp.drafts or {}
  S.draftSet = {}
  for _, d in ipairs(S.drafts) do S.draftSet[d.guid] = d end
end
local function decide(t, idOrGuid)
  local op = { t = t }
  if t == "req_ok" or t == "req_no" then op.id = idOrGuid else op.guid = idOrGuid end
  S.outbox[#S.outbox + 1] = op
  -- natychmiast chowamy kartę (serwer i tak przyśle nową listę)
  if op.id then
    for i, rq in ipairs(S.requests) do if rq.id == op.id then table.remove(S.requests, i) break end end
  else
    for i, d in ipairs(S.drafts) do if d.guid == op.guid then table.remove(S.drafts, i) break end end
    S.draftSet[op.guid] = nil
  end
  S.nextSync = 0
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
    -- kręcenie gałką wtyczki nie zawsze zmienia licznik projektu – pilnujemy ostatnio
    -- dotkniętego parametru i co kilka sekund i tak porównujemy projekt
    local touched = false
    if r.GetLastTouchedFX then
      local ok, tn, fxn, pn = r.GetLastTouchedFX()
      if ok then
        local tr = tn == 0 and r.GetMasterTrack(0) or r.GetTrack(0, tn - 1)
        local v = tr and (fxn >> 16) == 0 and r.TrackFX_GetParamNormalized(tr, fxn, pn) or 0
        local key = tn .. ":" .. fxn .. ":" .. pn .. ":" .. string.format("%.4f", v)
        if key ~= S.lastTouch then S.lastTouch, touched = key, true end
      end
    end
    if now() > (S.nextFullDiff or 0) then
      S.nextFullDiff, touched = now() + 3, true
      -- plik zmienił się na dysku po dodaniu (np. bit jeszcze się kopiował): nowy identyfikator,
      -- więc klip dostanie nową wersję pliku, a serwer – kompletny plik
      for id, path in pairs(S.fileLocal) do
        local sz = file_size(path)
        if sz and sz ~= M.id_size(id) then
          idCache[path] = nil
          S.fileLocal[id], S.uploads[id], S.uploadProg[id] = nil, nil, nil
        end
      end
    end
    if cc ~= S.lastCC or touched then
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
    S.serverParts = tonumber(resp.parts) or S.serverParts
    S.remoteProg = resp.progress or {}
    read_review(resp)
    handle_files(resp)
    if resp.resync then
      start_resync()
      return
    end
    local list = resp.ops or {}
    local last = {}
    for i, op in ipairs(list) do
      local k = op_key(op)
      if k and not op.po then last[k] = i end -- same gałki niczego nie nadpisują
    end
    local toApply = {}
    for i, op in ipairs(list) do
      note_op(op)
      local k = op_key(op)
      if k and op.cid ~= S.cid and (last[k] == i or (op.po and (last[k] or 0) < i)) then toApply[#toApply + 1] = op end
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
    for k, v in pairs(st.proj or {}) do proj_apply(k, v.data) end
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
      local resumed = RESUME and next(load_synced()) ~= nil
      RESUME = false
      if localHas and resumed then
        mode = "merge" -- powrót do tej samej sesji (okno pokazane ponownie / restart REAPERa)
      elseif localHas then
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
    read_review(st)
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
    for k, v in pairs(st.proj or {}) do
      if mode ~= "host" then proj_apply(k, v.data) else S.baseProj[k] = nil end
    end
    S.lastSeq = tonumber(st.seq) or 0
    -- ścieżki obecne przy dołączaniu idą do pokoju bez pytania (to jest projekt tej sesji)
    load_private()
    for i = 0, r.CountTracks(0) - 1 do S.known[r.GetTrackGUID(r.GetTrack(0, i))] = true end
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
  CFG.room_name = ""
  set_ext("room_name", "")
  CFG.admin = ""
  set_ext("admin_key", "")
  CFG.curl = curl ~= "" and curl or CFG.curl
  set_ext("server", CFG.server)
  set_ext("room", CFG.room)
  set_ext("user", CFG.user)
  set_ext("password", CFG.password)
  set_ext("curl", CFG.curl)
  return true
end

-------------------------------------------------------------------------------
-- Interfejs (gfx) – prosty panel w stylu REAPERa
--
-- Jedna kolumna, kolory z motywu REAPERa, bez animacji i zakładek:
--   nagłówek (sesja, status, menu) → osoby → „do zrobienia” → zdarzenia → pole czatu.
-- Funkcje są też zwykłymi akcjami REAPERa (Actions / pasek narzędzi / skróty).
-------------------------------------------------------------------------------
local remove_item_comment_marker
local UI = { input = "", scroll = 0, hits = {}, btn = {} }
local mouse = { l = false, r = false, x = 0, y = 0, clicked = false, rclicked = false, wheel = 0 }

-- kolory: z motywu REAPERa (jasny/ciemny), a gdy ich brak – spokojna ciemna paleta
local C = {}
local function theme(name, fallback)
  if r.GetThemeColor and r.ColorFromNative then
    local c = r.GetThemeColor(name, 0)
    if c and c >= 0 then
      local rr, gg, bb = r.ColorFromNative(c)
      return { rr, gg, bb }
    end
  end
  return fallback
end
local function lum(c) return (c[1] * 0.3 + c[2] * 0.59 + c[3] * 0.11) / 255 end
local function mix(c1, c2, t) return { c1[1] + (c2[1] - c1[1]) * t, c1[2] + (c2[2] - c1[2]) * t, c1[3] + (c2[3] - c1[3]) * t } end
local function load_theme()
  C.bg = theme("col_main_bg2", { 40, 40, 40 })
  C.text = theme("col_main_text2", { 220, 220, 220 })
  C.edit = theme("col_main_editbk", mix(C.bg, { 0, 0, 0 }, 0.35))
  local dark = lum(C.bg) < 0.5
  C.muted = mix(C.text, C.bg, 0.45)
  C.line = mix(C.bg, C.text, 0.14)
  C.hover = mix(C.bg, C.text, 0.08)
  C.on = dark and { 95, 201, 181 } or { 30, 140, 120 }
  C.warn = dark and { 243, 167, 59 } or { 190, 110, 0 }
  C.rec = { 230, 70, 66 }
  C.dark = dark
end

local function col(c, a) gfx.set(c[1] / 255, c[2] / 255, c[3] / 255, a or 1) end
local function hex_c(hex) local rr, gg, bb = hex_to_rgb(hex) return { rr, gg, bb } end
local function color_of(user)
  if user == "system" then return C.muted end
  local c = hex_c(user_color_hex(user) or "#c9c3b4")
  -- kolory osób czytelne także na jasnym motywie
  if not C.dark and lum(c) > 0.6 then c = mix(c, { 0, 0, 0 }, 0.45) end
  return c
end
local function inside(x, y, w, h) return mouse.x >= x and mouse.x < x + w and mouse.y >= y and mouse.y < y + h end
local function text_at(x, y, str, font, c)
  gfx.setfont(font)
  col(c)
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
local function wrap(text, w)
  local lines, cur = {}, ""
  for word in text:gmatch("%S+") do
    local cand = cur == "" and word or (cur .. " " .. word)
    if gfx.measurestr(cand) <= w or cur == "" then cur = cand else lines[#lines + 1] = cur; cur = word end
  end
  lines[#lines + 1] = cur
  return lines
end

-- przycisk w stylu REAPERa: płaski prostokąt z obwódką; zwraca true po kliknięciu
local function button(x, y, label, strong)
  gfx.setfont(strong and 3 or 2)
  local tw, th = gfx.measurestr(label)
  local w, h = tw + 14, th + 6
  local hover = inside(x, y, w, h)
  col(hover and C.hover or C.bg)
  gfx.rect(x, y, w, h, 1)
  col(strong and C.on or C.line)
  gfx.rect(x, y, w, h, 0)
  col(strong and C.on or C.text)
  gfx.x, gfx.y = x + 7, y + 3
  gfx.drawstr(label)
  return hover and mouse.clicked, w, h
end
local function dot(x, y, c, rad)
  col(c)
  gfx.circle(x, y, rad or 4, 1, 1)
end

-------------------------------------------------------------------------------
-- Informacja o zaznaczonym klipie / ścieżce, komentarze, wysyłanie
-------------------------------------------------------------------------------
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
    local pre = S.draftSet[g] and T("draft_label") or ""
    if m then return pre .. fmt(m, T("clip_label", name)) end
    return T("clip_unsynced", name)
  end
  local tr = r.GetSelectedTrack(0, 0)
  if tr then
    local m = S.meta[r.GetTrackGUID(tr)]
    local _, name = r.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    if name == "" then name = T("no_name") end
    if m then return (S.draftSet[r.GetTrackGUID(tr)] and T("draft_label") or "") .. fmt(m, T("track_label", name)) end
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

local function send_comment(txt)
  txt = (txt or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if txt == "" or S.state ~= "on" then return end
  local id = S.cid .. "-" .. math.floor(now() * 1000)
  local item = r.GetSelectedMediaItem(0, 0)
  if item then
    S.outbox[#S.outbox + 1] = add_item_comment(item, txt, id)
  else
    S.outbox[#S.outbox + 1] = { t = "comment", id = id, pos = r.GetCursorPosition(), text = txt }
  end
  S.nextSync = 0
end

local function send_input(asComment)
  local txt = UI.input:gsub("^%s+", ""):gsub("%s+$", "")
  if txt == "" or S.state ~= "on" then return end
  if asComment then
    send_comment(txt)
  else
    S.outbox[#S.outbox + 1] = { t = "chat", text = txt }
    S.nextSync = 0
  end
  UI.input = ""
  UI.scroll = 0
end

-- komentarz z akcji REAPERa: okienko z polem tekstowym
local function ask_comment()
  if S.state ~= "on" then return end
  local it = r.GetSelectedMediaItem(0, 0)
  local title = it and T("comment_on", (r.GetActiveTake(it) and r.GetTakeName(r.GetActiveTake(it))) or T("clip"))
    or T("comment_at", M.fmt_pos(r.GetCursorPosition()))
  local ok, txt = r.GetUserInputs(title, 1, T("comment_field") .. ",extrawidth=320", "")
  if ok then send_comment(txt) end
end

-------------------------------------------------------------------------------
-- Okno: pokaż / schowaj (sesja działa w tle)
-------------------------------------------------------------------------------
local WINDOW_TITLE = "Sesja"
local function save_window()
  if UI.hidden then return end
  set_ext("dock", gfx.dock(-1))
  local _, x, y, w, h = gfx.dock(-1, 0, 0, 0, 0)
  set_ext("wnd", string.format("%d %d %d %d", x, y, w, h))
end
local function open_window()
  local x, y, w, h = (get_ext("wnd", "")):match("(-?%d+) (-?%d+) (%d+) (%d+)")
  load_theme()
  gfx.clear = (C.bg[3] << 16) | (C.bg[2] << 8) | C.bg[1]
  -- domyślnie w dokerze, jak inne panele REAPERa (pierwsze uruchomienie: doker po prawej)
  local dockState = tonumber(get_ext("dock", "")) or 1
  gfx.init(WINDOW_TITLE, tonumber(w) or 340, tonumber(h) or 560, dockState, tonumber(x) or 120, tonumber(y) or 120)
  local font = IS_WIN and "Segoe UI" or (r.GetOS():match("OSX") and "Helvetica Neue" or "Arial")
  gfx.setfont(1, font, IS_WIN and 15 or 14)
  gfx.setfont(2, font, IS_WIN and 13 or 12)
  gfx.setfont(3, font, IS_WIN and 15 or 14, string.byte("b"))
  UI.hidden = false
end
local function hide_window()
  save_window()
  gfx.quit()
  UI.hidden = true
end

-------------------------------------------------------------------------------
-- Akcje REAPERa: małe skrypty, które wysyłają polecenie do działającej Sesji
-------------------------------------------------------------------------------
local MY_PATH = debug.getinfo(1, "S").source:match("^@(.*)$") or ""
local MY_DIR = MY_PATH:match("^(.*[\\/])") or ""
local ACTIONS = {
  { "show", "act_show" }, { "comment", "act_comment" }, { "freeze", "act_freeze" },
  { "unfreeze", "act_unfreeze" }, { "share", "act_share" }, { "quit", "act_quit" },
}
local ACTIONS_VERSION = "2"
local function install_actions()
  if MY_DIR == "" or not r.AddRemoveReaScript then return end
  local dir = MY_DIR .. "akcje"
  r.RecursiveCreateDirectory(dir, 0)
  local fresh = get_ext("actions_v", "") ~= ACTIONS_VERSION
  for _, a in ipairs(ACTIONS) do
    local path = dir .. SEP .. "Sesja - " .. T(a[2]) .. ".lua"
    if fresh or not file_exists(path) then
      write_file(path, table.concat({
        "-- Sesja: " .. T(a[2]) .. " (akcja dla działającego moda Sesja)",
        "local SEC, cmd = \"ReaperMultiplayer\", \"" .. a[1] .. "\"",
        "local alive = tonumber(reaper.GetExtState(SEC, \"alive\")) or 0",
        "if reaper.time_precise() - alive < 3 then",
        "  reaper.SetExtState(SEC, \"cmd\", cmd, false)",
        "elseif cmd == \"show\" then",
        "  dofile(" .. string.format("%q", MY_PATH) .. ")",
        "else",
        "  reaper.MB(\"" .. T("act_not_running") .. "\", \"Sesja\", 0)",
        "end",
      }, "\n") .. "\n")
      r.AddRemoveReaScript(true, 0, path, true)
    end
  end
  set_ext("actions_v", ACTIONS_VERSION)
end

local function selected_held()
  local n = 0
  for i = 0, r.CountSelectedTracks(0) - 1 do
    local g = r.GetTrackGUID(r.GetSelectedTrack(0, i))
    if S.held[g] or PRIVATE[g] then
      PRIVATE[g] = nil
      approve_track(g)
      n = n + 1
    end
  end
  if n > 0 then save_private() end
end

local function run_command(cmd)
  if cmd == "show" then
    if UI.hidden then open_window() else gfx.dock(gfx.dock(-1)) end
  elseif cmd == "comment" then ask_comment()
  elseif cmd == "freeze" then r.Main_OnCommand(FREEZE, 0); S.nextSync = 0
  elseif cmd == "unfreeze" then r.Main_OnCommand(UNFREEZE, 0); S.nextSync = 0
  elseif cmd == "share" then selected_held()
  elseif cmd == "quit" then UI.quit = true
  end
end
local function poll_commands(t)
  if t - (UI.lastAlive or 0) > 1 then
    UI.lastAlive = t
    r.SetExtState(SEC, "alive", tostring(t), false)
  end
  local cmd = r.GetExtState(SEC, "cmd")
  if cmd and cmd ~= "" then
    if r.DeleteExtState then r.DeleteExtState(SEC, "cmd", false) else r.SetExtState(SEC, "cmd", "", false) end
    run_command(cmd)
  end
end

-------------------------------------------------------------------------------
-- Menu (przycisk ☰ i prawy klik w oknie)
-------------------------------------------------------------------------------
local function show_menu()
  gfx.x, gfx.y = mouse.x, mouse.y
  local np = 0
  for _ in pairs(PRIVATE) do np = np + 1 end
  local st = S.state
  local items = {
    st == "off" and T("connect") or T("disconnect"),
    T("menu_settings"),
    "",
    ((st == "on" and r.GetSelectedMediaItem(0, 0)) and "" or "#") .. T("act_comment"),
    (r.CountSelectedTracks(0) > 0 and "" or "#") .. T("act_freeze"),
    (r.CountSelectedTracks(0) > 0 and "" or "#") .. T("act_unfreeze"),
    (np > 0 and "" or "#") .. T("menu_share_private", np),
    "",
    (CFG.ask and "!" or "") .. T("menu_ask"),
    (CFG.colorize and "!" or "") .. T("menu_colorize"),
    (st == "on" and "" or "#") .. T("menu_resync"),
    T("menu_clear"),
    "",
    (st ~= "off" and "" or "#") .. T("menu_hide"),
    T("menu_quit"),
    "#Sesja v" .. VERSION,
  }
  local c = gfx.showmenu(table.concat(items, "|"))
  -- puste pozycje to separatory i nie mają numerów
  local map = { "conn", "settings", "comment", "freeze", "unfreeze", "share", "ask", "colorize", "resync", "clear", "hide", "quit" }
  local what = map[c]
  if what == "conn" then
    if st == "off" then
      if CFG.user ~= "" or open_settings() then connect() end
    else
      disconnect()
    end
  elseif what == "settings" then
    if open_settings() then
      if S.state ~= "off" then disconnect(true) end
      connect()
    end
  elseif what == "comment" then ask_comment()
  elseif what == "freeze" or what == "unfreeze" then run_command(what)
  elseif what == "share" then
    for pg in pairs(PRIVATE) do PRIVATE[pg] = nil; S.known[pg] = true end
    save_private()
    S.nextSync = 0
  elseif what == "ask" then
    CFG.ask = not CFG.ask
    set_ext("ask_tracks", CFG.ask and "1" or "0")
  elseif what == "colorize" then
    CFG.colorize = not CFG.colorize
    set_ext("colorize", CFG.colorize and "1" or "0")
  elseif what == "resync" then
    if not S.inflight then start_resync() end
  elseif what == "clear" then
    for k in pairs(FEED) do FEED[k] = nil end
  elseif what == "hide" then hide_window()
  elseif what == "quit" then UI.quit = true
  end
end

local function handle_keys()
  while true do
    local c = gfx.getchar()
    if c == -1 then return false end
    if c == 0 then break end
    UI.typed = true
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
    if u.admin then e.admin = true end
    if u.app then
      e.app = true
    else
      e.reaper, e.pos, e.play, e.rec, e.sel = true, u.pos or 0, u.play, u.rec, u.sel
    end
  end
  return list
end

local function scan_missing_fx()
  if not r.TrackFX_GetOffline or now() < S.nextFxScan then return end
  S.nextFxScan = now() + 3
  local list = {}
  for i = 0, r.CountTracks(0) - 1 do
    local tr = r.GetTrack(0, i)
    local g = r.GetTrackGUID(tr)
    if S.meta[g] and S.meta[g].author ~= CFG.user then -- cudze ścieżki
      for fx = 0, r.TrackFX_GetCount(tr) - 1 do
        if r.TrackFX_GetOffline(tr, fx) then
          local _, fxn = r.TrackFX_GetFXName(tr, fx, "")
          local _, trn = r.GetTrackName(tr)
          fxn = (fxn or "?"):gsub("^%u+i?:%s*", ""):gsub("%s*%(.-%)%s*$", "")
          if not S.fxHidden[g .. fxn] then list[#list + 1] = { guid = g, fx = fxn, track = trn } end
        end
      end
    end
  end
  S.missingFx = list
end
local function render_for_others(g)
  local tr = track_map()[g]
  if not tr then return end
  for i = 0, r.CountTracks(0) - 1 do r.SetTrackSelected(r.GetTrack(0, i), false) end
  r.SetTrackSelected(tr, true)
  r.Main_OnCommand(FREEZE, 0)
  S.fxRequests[g] = nil
  S.nextSync = 0
end

-------------------------------------------------------------------------------
-- „Do zrobienia”: wszystko, co czeka na Twoją decyzję – jedna linia + krótkie przyciski
-------------------------------------------------------------------------------
local function todo_list()
  local list = {}
  local function add(text, accent, buttons) list[#list + 1] = { text = text, accent = accent, buttons = buttons } end
  -- nowa ścieżka czeka na zgodę, zanim trafi do pokoju
  local g = S.heldOrder[1]
  if g and S.held[g] then
    local q = T("ask_track", S.held[g] ~= "" and S.held[g] or T("no_name"))
    if #S.heldOrder > 1 then q = q .. " (" .. T("ask_more", #S.heldOrder - 1) .. ")" end
    add(q, C.warn, {
      { T("ask_add"), true, function() approve_track(g) end },
      { T("ask_private"), false, function() keep_private(g) end },
      { T("ask_always"), false, function()
        CFG.ask = false
        set_ext("ask_tracks", "0")
        for _, hg in ipairs(S.heldOrder) do approve_track(hg) end
      end },
    })
  end
  if S.roles and S.role == "admin" then
    local rq = S.requests[1]
    if rq then
      local kind = T(rq.t == "track_del" and "k_track" or "k_item")
      local q = T("req_q", rq.user or "?", kind, (rq.name ~= "" and rq.name) or T("no_name"))
      if #S.requests > 1 then q = q .. " (" .. T("ask_more", #S.requests - 1) .. ")" end
      add(q, C.rec, {
        { T("req_yes"), true, function() decide("req_ok", rq.id) end },
        { T("req_no"), false, function() decide("req_no", rq.id) end },
      })
    end
    local d = S.drafts[1]
    if d then
      local kind = T(d.kind == "track" and "k_track1" or "k_item1")
      local btns = {
        { T("draft_ok"), true, function() decide("draft_ok", d.guid) end },
        { T("draft_no"), false, function() decide("draft_no", d.guid) end },
      }
      if #S.drafts > 1 then
        btns[#btns + 1] = { T("draft_all", #S.drafts), false, function()
          local all = {}
          for _, x in ipairs(S.drafts) do all[#all + 1] = x.guid end
          for _, gg in ipairs(all) do decide("draft_ok", gg) end
        end }
      end
      add(T("draft_q", kind, (d.name ~= "" and d.name) or T("no_name"), d.user or "?"), C.on, btns)
    end
  elseif S.roles then
    local mine, reqs = 0, 0
    for _, d in ipairs(S.drafts) do if d.user == CFG.user then mine = mine + 1 end end
    for _, rq in ipairs(S.requests) do if rq.user == CFG.user then reqs = reqs + 1 end end
    if mine + reqs > 0 then add(T("editor_wait", mine, reqs), C.muted, {}) end
  end
  if S.state == "on" then
    scan_missing_fx()
    local m = S.missingFx[1]
    if m then
      add(T("fx_missing", m.fx, m.track), C.warn, {
        { T("fx_ask"), true, function()
          S.outbox[#S.outbox + 1] = { t = "chat", text = T("fx_ask_chat", m.track, m.fx), fxreq = m.guid, fxname = m.fx }
          S.fxHidden[m.guid .. m.fx] = true
          table.remove(S.missingFx, 1)
        end },
        { T("fx_hide"), false, function() S.fxHidden[m.guid .. m.fx] = true; table.remove(S.missingFx, 1) end },
      })
    end
    for fg, rq in pairs(S.fxRequests) do
      local tr = track_map()[fg]
      if not tr then S.fxRequests[fg] = nil break end
      local _, trn = r.GetTrackName(tr)
      add(T("fx_req", rq.user, rq.fx, trn), C.on, {
        { T("fx_render"), true, function() render_for_others(fg) end },
        { T("fx_later"), false, function() S.fxRequests[fg] = nil end },
      })
      break
    end
  end
  -- przesyłanie plików: postęp albo błąd
  local nup, ndown, npend = 0, 0, 0
  for _ in pairs(S.uploads) do nup = nup + 1 end
  for _ in pairs(S.downloads) do ndown = ndown + 1 end
  for _ in pairs(S.pending) do npend = npend + 1 end
  if #S.deferred > 0 then
    add(T("recording_wait"):gsub("^%s+", ""), C.rec, {})
  elseif nup + ndown + npend > 0 then
    local msg = T("pending", nup, ndown, npend):gsub("^%s+", "")
    for id, pr in pairs(S.uploadProg) do
      if S.uploads[id] then msg = msg .. " · ↑ " .. (id:match("^(.-)~") or id) .. " " .. math.floor(pr.part / pr.parts * 100) .. "%" break end
    end
    for id, pr in pairs(S.remoteProg or {}) do
      if S.want[id] and type(pr) == "table" and tonumber(pr[2]) then
        msg = msg .. " · ↓ " .. (id:match("^(.-)~") or id) .. " " .. T("on_server", math.floor((tonumber(pr[1]) or 0) / pr[2] * 100))
        break
      end
    end
    add(msg, C.muted, {})
  end
  return list
end

-------------------------------------------------------------------------------
-- Rysowanie
-------------------------------------------------------------------------------
local PAD, LH = 10, 18

local function entry_text(e)
  if e.kind == "comment" then
    if e.itemName then return T("comment_item", e.itemName, M.fmt_pos(e.pos), e.text) end
    return T("comment_pos", M.fmt_pos(e.pos), e.text)
  end
  if e.kind == "act" and (e.n or 1) > 1 then return e.text .. " (×" .. e.n .. ")" end
  return e.text
end

-- lista zdarzeń (czat, aktywność, komentarze) – od najnowszych na dole, kółko myszy przewija
local function draw_feed(x, y, w, h)
  local list = {}
  for _, e in ipairs(FEED) do if not e.deleted then list[#list + 1] = e end end
  UI.hits = {}
  if #list == 0 then
    text_at(x, y + 4, ellipsize(T("select_hint"), w), 2, C.muted)
    return
  end
  -- układ linii (z cache, liczony od nowa tylko po zmianie szerokości lub tekstu)
  local total = 0
  for _, e in ipairs(list) do
    local who = e.user == "system" and "Sesja" or (e.user or "?")
    local text = os.date("%H:%M", e.ts) .. "  " .. who .. ": " .. entry_text(e)
    if e._w ~= w or e._t ~= text then
      gfx.setfont(1)
      e._lines, e._w, e._t, e._who = wrap(text, w), w, text, who
    end
    total = total + #e._lines * LH + 4
  end
  local maxScroll = math.max(0, total - h)
  if mouse.wheel ~= 0 and inside(x, y, w, h) then UI.scroll = UI.scroll + mouse.wheel / 120 * LH * 3 end
  UI.scroll = math.max(0, math.min(UI.scroll, maxScroll))
  local by = y + h + UI.scroll
  for i = #list, 1, -1 do
    local e = list[i]
    local eh = #e._lines * LH + 4
    local ey = by - eh
    if ey + eh < y then break end
    if ey >= y - 1 and ey + eh <= y + h + 1 then
      local base = e.kind == "act" and C.muted or C.text
      for li, line in ipairs(e._lines) do
        local ly = ey + (li - 1) * LH
        if li == 1 then
          -- czas (przygaszony) i imię (kolor osoby), reszta zwykłym kolorem
          gfx.setfont(1)
          local tm = os.date("%H:%M", e.ts) .. "  "
          text_at(x, ly, tm, 1, C.muted)
          local nx = x + gfx.measurestr(tm)
          local who = e._who .. ":"
          text_at(nx, ly, who, 1, color_of(e.user))
          local rest = line:sub(#tm + #who + 1)
          gfx.setfont(1)
          text_at(nx + gfx.measurestr(who), ly, rest, 1, e.kind == "comment" and C.warn or base)
        else
          text_at(x, ly, line, 1, e.kind == "comment" and C.warn or base)
        end
      end
      UI.hits[#UI.hits + 1] = { e = e, y = ey, h = eh }
    end
    by = ey
  end
  -- kliknięcie w komentarz: skok do miejsca; prawy klik: menu
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
        UI.menuDone = true
      end
    end
  end
end

local function status_text(st)
  if st == "on" then return T("st_on"), C.on end
  if st == "connecting" then return T("st_connecting"), C.warn end
  if st == "error" then return T("st_error"), C.rec end
  return T("st_off"), C.muted
end

local function draw()
  local W, H = gfx.w, gfx.h
  col(C.bg)
  gfx.rect(0, 0, W, H, 1)
  local st = S.state
  local x, y, w = PAD, PAD, W - 2 * PAD

  -- nagłówek: ● nazwa sesji ........ [☰]
  local label, sc = status_text(st)
  dot(x + 5, y + 9, sc, 5)
  local mb, mw = button(W - PAD - 30, y, "☰")
  if mb then show_menu() end
  local name = CFG.room_name ~= "" and CFG.room_name or (CFG.room ~= "" and CFG.room or "Sesja")
  gfx.setfont(3)
  text_at(x + 16, y + 1, ellipsize(name, w - 16 - mw - 8), 3, C.text)
  y = y + 22
  local sub = label
  if S.roles and st == "on" then sub = sub .. " · " .. T(S.role == "admin" and "role_admin" or "role_editor") end
  if CFG.user ~= "" then sub = sub .. " · " .. CFG.user end
  text_at(x + 16, y, ellipsize(sub, w - 16), 2, C.muted)
  y = y + 18
  if S.err then
    gfx.setfont(2)
    for _, l in ipairs(wrap(S.err, w)) do text_at(x, y, l, 2, C.rec); y = y + 16 end
  end
  if st == "off" then
    y = y + 6
    if button(x, y, T("connect"), true) then
      if CFG.user ~= "" or open_settings() then connect() end
    end
    y = y + 28
  end

  -- osoby
  y = y + 6
  col(C.line)
  gfx.line(x, y, x + w, y)
  y = y + 8
  local people = merged_users()
  if #people == 0 then
    text_at(x, y, st == "on" and T("only_you") or T("nobody"), 2, C.muted)
    y = y + 18
  end
  for i, u in ipairs(people) do
    if UI.compact and i > 3 then
      text_at(x, y, T("online_n", #people), 2, C.muted)
      y = y + 18
      break
    end
    dot(x + 5, y + 8, color_of(u.name), 4)
    gfx.setfont(1)
    local nm = u.name .. (u.name == CFG.user and (" (" .. T("you") .. ")") or "")
    text_at(x + 16, y, ellipsize(nm, w * 0.55), 1, C.text)
    local nx = x + 16 + math.min(gfx.measurestr(nm), w * 0.55) + 6
    if u.admin then text_at(nx, y + 2, T("role_admin"), 2, C.muted); gfx.setfont(2); nx = nx + gfx.measurestr(T("role_admin")) + 6 end
    local state, stc
    if u.rec then state, stc = "● REC " .. M.fmt_pos(u.pos), C.rec
    elseif u.play then state, stc = "▶ " .. M.fmt_pos(u.pos), C.text
    elseif u.reaper then state, stc = M.fmt_pos(u.pos), C.muted
    else state, stc = T("app_only"), C.muted end
    gfx.setfont(2)
    local sw = gfx.measurestr(state)
    if x + w - sw > nx then text_at(x + w - sw, y + 2, state, 2, stc) end
    y = y + 20
  end

  -- do zrobienia
  local todo = todo_list()
  if #todo > 0 then
    y = y + 4
    col(C.line)
    gfx.line(x, y, x + w, y)
    y = y + 8
    for i, it in ipairs(todo) do
      if i > (UI.compact and 1 or 3) then
        text_at(x, y, T("more_n", #todo - i + 1), 2, C.muted)
        y = y + 18
        break
      end
      col(it.accent)
      gfx.rect(x, y + 2, 2, 14, 1)
      gfx.setfont(1)
      local lines = wrap(it.text, w - 10)
      for _, l in ipairs(lines) do text_at(x + 10, y, l, 1, C.text); y = y + LH end
      if #it.buttons > 0 then
        local bx = x + 10
        for _, b in ipairs(it.buttons) do
          gfx.setfont(b[2] and 3 or 2)
          local bw = gfx.measurestr(b[1]) + 14
          if bx + bw > x + w then break end
          local clicked = button(bx, y + 2, b[1], b[2])
          if clicked then b[3]() end
          bx = bx + bw + 6
        end
        y = y + 26
      end
      y = y + 6
    end
  end
  if UI.compact then return end

  -- zaznaczony klip / ścieżka: kto dodał
  y = y + 2
  col(C.line)
  gfx.line(x, y, x + w, y)
  y = y + 6
  text_at(x, y, ellipsize(inspector_text(), w), 2, C.muted)
  y = y + 20

  -- zdarzenia
  local inputH = 26
  local feedH = H - y - inputH - PAD - 8
  if feedH > LH then draw_feed(x, y, w, feedH) end

  -- pole czatu + przycisk komentarza
  local iy = H - PAD - inputH
  gfx.setfont(2)
  local cl = r.GetSelectedMediaItem(0, 0) and T("btn_comment_clip") or T("btn_comment")
  local cw = gfx.measurestr(cl) + 14
  local fw = w - cw - 6
  col(C.edit)
  gfx.rect(x, iy, fw, inputH, 1)
  col(UI.input ~= "" and C.on or C.line)
  gfx.rect(x, iy, fw, inputH, 0)
  gfx.setfont(1)
  local shown = UI.input
  while #shown > 0 and gfx.measurestr(shown) > fw - 16 do
    shown = shown:sub((utf8.offset(shown, 2) or (#shown + 1)))
  end
  if UI.input == "" then
    text_at(x + 6, iy + 5, ellipsize(T("input_ph"), fw - 12), 1, C.muted)
  else
    text_at(x + 6, iy + 5, shown, 1, C.text)
  end
  if math.floor(now() * 2) % 2 == 0 then
    col(C.text)
    gfx.rect(x + 6 + (UI.input == "" and 0 or gfx.measurestr(shown)) + 1, iy + 6, 1, 14, 1)
  end
  if button(x + fw + 6, iy + 2, cl) then
    if UI.input ~= "" then send_input(true) else ask_comment() end
  end

  -- prawy klik w wolnym miejscu okna: menu
  if mouse.rclicked and not UI.menuDone then show_menu() end
  UI.menuDone = false
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
-- Aplikacja Sesja zapisuje bieżącą sesję w session.txt obok skryptu – przełączamy się sami.
local HANDOFF = (debug.getinfo(1, "S").source:match("^@(.*[\\/])") or "") .. "session.txt"
local handoffSeen, handoffNext = nil, 0
local function check_handoff(t)
  if t < handoffNext then return end
  handoffNext = t + 2
  local f = io.open(HANDOFF, "rb")
  if not f then handoffSeen = handoffSeen or ""; return end
  local body = f:read("*a") or ""
  f:close()
  local first = handoffSeen == nil
  if body == handoffSeen then return end
  handoffSeen = body
  local v = {}
  for k, val in body:gmatch("([%w_]+)=([^\r\n]*)") do v[k] = val end
  if v.ask_tracks == "0" or v.ask_tracks == "1" then
    CFG.ask = v.ask_tracks == "1"
    set_ext("ask_tracks", v.ask_tracks)
    if not CFG.ask then for _, hg in ipairs(S.heldOrder) do approve_track(hg) end end
  end
  local room = (v.room or ""):gsub("[^%w%._%-]", "")
  if v.admin and (room == CFG.room or v.join ~= "0") then
    CFG.admin = safe_key(v.admin)
    set_ext("admin_key", CFG.admin)
  end
  if v.join == "0" or (v.server or "") == "" or room == "" then return end
  if v.server == CFG.server and room == CFG.room and (first or S.state == "on") then return end
  -- przy starcie: aplikacja wybrała inną sesję niż zapisana w REAPERze -> przechodzimy do niej
  CFG.server, CFG.room, CFG.password = v.server, room, safe_key(v.password)
  CFG.room_name = (v.name or ""):sub(1, 60)
  set_ext("room_name", CFG.room_name)
  if (v.user or "") ~= "" then CFG.user = v.user:sub(1, 40) end
  for _, k in ipairs({ "server", "room", "user", "password" }) do set_ext(k, CFG[k]) end
  if S.state ~= "off" then disconnect(true) end
  connect()
end

local function main_loop()
  poll_jobs()
  local t = now()
  check_handoff(t)
  poll_commands(t)
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

  if UI.quit then
    if S.state ~= "off" then disconnect(true) end
    return
  end
  if UI.hidden then
    -- w tle: bez okna, ale sesja dalej się synchronizuje
    if S.state == "off" then return end
    r.defer(main_loop)
    return
  end
  update_mouse()
  if not handle_keys() then -- okno zamknięte krzyżykiem
    if S.state ~= "off" then
      UI.hidden = true -- sesja trwa w tle; akcja „Sesja – pokaż okno” przywraca okno
      r.defer(main_loop)
    end
    return
  end
  UI.compact = gfx.h < 260
  -- rysujemy często tylko przy ruchu myszy / pisaniu; w spoczynku kilka razy na sekundę
  local moved = mouse.x ~= UI.mx or mouse.y ~= UI.my or mouse.l or mouse.r or mouse.wheel ~= 0 or gfx.w ~= UI.gw or gfx.h ~= UI.gh
  UI.mx, UI.my, UI.gw, UI.gh = mouse.x, mouse.y, gfx.w, gfx.h
  if moved or UI.typed then UI.busyUntil = t + 0.5; UI.typed = false end
  if t < (UI.busyUntil or 0) or t - (UI.lastDraw or 0) > 0.25 then
    UI.lastDraw = t
    draw()
    gfx.update()
  end
  r.defer(main_loop)
end

local function on_exit()
  local was = S and S.state ~= "off" and not UI.quit
  if S and S.state ~= "off" then save_synced() end
  -- „resume”: po ponownym uruchomieniu akcji (albo REAPERa) wracamy do sesji bez pytań
  set_ext("resume", was and "1" or "0")
  save_window()
  r.SetExtState(SEC, "alive", "0", false)
  if r.set_action_options then r.set_action_options(8) end
end

local function init()
  math.randomseed(math.floor(os.time() + (r.time_precise() * 1000) % 100000))
  reset_state()
  open_window()
  r.atexit(on_exit)
  -- ponowne uruchomienie głównej akcji: zamknij instancję w tle i otwórz okno od nowa (REAPER 7+)
  if r.set_action_options then r.set_action_options(1 | 2 | 4) end
  RESUME = get_ext("resume", "0") == "1"
  install_actions()
  if CFG.user == "" then
    if open_settings() then connect() end
  else
    connect()
  end
  main_loop()
end

init()
