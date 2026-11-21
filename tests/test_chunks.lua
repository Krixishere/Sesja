-- Testy czystych funkcji skryptu (uruchom: lua5.4 tests/test_chunks.lua z katalogu repo)
package.path = "./?.lua;" .. package.path
local M = dofile("reaper/ReaperMultiplayer.lua")
local json = M.json

local fails = 0
local function check(cond, msg)
  if cond then
    print("ok   " .. msg)
  else
    print("FAIL " .. msg)
    fails = fails + 1
  end
end

-- JSON ---------------------------------------------------------------
local src = { a = 1, b = "zażółć \"gęślą\"\njaźń\\", c = { 1, 2.5, true, false }, d = json.array({}), e = {} }
local enc = json.encode(src)
local dec = json.decode(enc)
check(dec.a == 1 and dec.b == src.b, "json: string z polskimi znakami, cudzysłowami i \\n")
check(dec.c[2] == 2.5 and dec.c[3] == true and dec.c[4] == false, "json: tablica")
check(enc:find('"d":%[%]') ~= nil, "json: pusta tablica jako []")
check(json.decode('{"x":"\\u0105\\ud83d\\udcac","y":null,"z":-1.5e3}').x == "ą💬", "json: \\u i pary surogatów")
check(json.decode('{"x":-1.5e3}').x == -1500, "json: liczby z wykładnikiem")
check(json.decode('{"x":') == nil, "json: niekompletny JSON -> nil")

-- Chunki --------------------------------------------------------------
local TRACK = [[
<TRACK
  NAME "Wokal główny"
  PEAKCOL 16576
  VOLPAN 1 0 -1 -1 1
  MUTESOLO 0 0 0
  SEL 1
  REC 1 0 1 0 0 0 0 0
  TRACKHEIGHT 0 0 0 0 0 0
  TRACKID {AAAAAAAA-0000-0000-0000-000000000001}
  MAINSEND 1 0
  <FXCHAIN
    WNDRECT 24 52 655 408
    SHOW 0
    LASTSEL 0
    DOCKED 0
    BYPASS 0 0 0
    <VST "VST: ReaEQ (Cockos)" reaeq.dll 0 "" 1919247729<56535472656571726561657100000000> ""
      cWVlcu5e7f4CAAAAAQAAAAAAAAACAAAAAAAAAAIAAAABAAAAAAAAAAIAAAAAAAAAAQ
      AAEAAAA=
    >
    FLOATPOS 0 0 0 0
    FXID {11111111-2222-3333-4444-555555555555}
    WAK 0 0
  >
  <ITEM
    POSITION 2
    LENGTH 4
    SEL 1
    IGUID {BBBBBBBB-0000-0000-0000-000000000001}
    IID 1
    NAME vocal.wav
    GUID {CCCCCCCC-0000-0000-0000-000000000001}
    <SOURCE WAVE
      FILE "/tmp/x/vocal take.wav" 1
    >
  >
  <ITEM
    POSITION 8
    LENGTH 2
    IGUID {BBBBBBBB-0000-0000-0000-000000000002}
    NAME midi
    <SOURCE MIDI
      HASDATA 1 960 QN
      E 0 90 3c 60
      E 480 80 3c 00
    >
  >
>
]]

local header, locals, items = M.normalize_track(TRACK)
check(#items == 2, "track: wyciągnięto 2 klipy")
check(not header:find("SEL 1") and not header:find("TRACKHEIGHT") and not header:find("\nREC "),
  "track: linie lokalne usunięte z nagłówka")
check(#locals == 3, "track: 3 linie lokalne (SEL, REC, TRACKHEIGHT)")
check(not header:find("WNDRECT") and not header:find("FLOATPOS") and header:find("WAK 0 0"),
  "track: stan okien FX pominięty, reszta FX zostaje")
check(not header:find("<ITEM"), "track: nagłówek bez klipów")
check(M.unquote(M.chunk_field(header, "NAME")) == "Wokal główny", "chunk_field NAME")

local rebuilt = M.build_track_chunk(header, locals, items)
local h2, l2, i2 = M.normalize_track(rebuilt)
check(h2 == header and #l2 == #locals and #i2 == 2, "track: build -> normalize daje to samo")

local seen = {}
local norm, refs, guid = M.normalize_item(items[1], function(p)
  seen[#seen + 1] = p
  return "vocal_take~123~deadbeef.wav", p
end)
check(guid == "{BBBBBBBB-0000-0000-0000-000000000001}", "item: IGUID")
check(seen[1] == "/tmp/x/vocal take.wav", "item: ścieżka pliku ze spacją")
check(norm:find('FILE "rmp:vocal_take~123~deadbeef.wav" 1', 1, true) ~= nil, "item: FILE -> rmp:")
check(not norm:find("\nSEL ") and not norm:find("IID"), "item: SEL/IID usunięte")
check(refs["vocal_take~123~deadbeef.wav"] == "/tmp/x/vocal take.wav", "item: refs")

local den, missing = M.denormalize_item(norm, function(id) return nil end)
check(#missing == 1 and missing[1] == "vocal_take~123~deadbeef.wav", "item: brakujący plik wykryty")
den, missing = M.denormalize_item(norm, function(id) return "C:\\media\\" .. id end)
check(#missing == 0 and den:find('FILE "C:\\media\\vocal_take~123~deadbeef.wav" 1', 1, true), "item: rmp: -> lokalna ścieżka")

local nmidi = M.normalize_item(items[2], function() return nil end)
check(nmidi:find("E 0 90 3c 60", 1, true) ~= nil, "item MIDI: dane MIDI zachowane")

local tk = M.tokens('NAME "Wokal główny" 1 `x y`')
check(tk[1] == "NAME" and tk[2] == "Wokal główny" and tk[3] == "1" and tk[4] == "x y", "tokens")
check(M.id_size("vocal~123456~0badf00d.wav") == 123456, "id_size")
check(M.fmt_pos(3725) == "1:02:05" and M.fmt_pos(65) == "1:05", "fmt_pos")

-- UTF-16LE dla ukrytego uruchamiania curl na Windows
local u = M.utf16le("aą💬")
check(u == "\255\254" .. "a\0" .. "\5\1" .. "\61\216\172\220", "utf16le: BOM, ą i para surogatów dla emoji")
check(M.utf16le("C:\\Użytkownicy\\x") :sub(1, 2) == "\255\254", "utf16le: ścieżka z polskimi znakami")

-- file_id
local tmp = os.tmpname()
local f = io.open(tmp, "wb"); f:write(string.rep("abc", 50000)); f:close()
local id1, size = M.file_id(tmp)
check(size == 150000 and id1:match("~150000~%x%x%x%x%x%x%x%x"), "file_id: " .. tostring(id1))
os.remove(tmp)

-- szkielet ścieżki: bez stanu wtyczek i SESJA_FXP, z automatyką parametrów
local h1 = table.concat({
  "<TRACK", "NAME Wokal", "VOLPAN 1 0 -1 -1 1", "<FXCHAIN", "BYPASS 0 0 0",
  "<VST \"VST: ReaComp\" reacomp.dll 0 \"\" 1",  "QUFBQQ==", "QkJCQg==", ">",
  "<PARMENV 1:0", "PT 0 0.5 0", ">", "FXID {1}", ">", "SESJA_FXP 0 0.1000,0.2000", ">",
}, "\n")
local h2 = h1:gsub("QUFBQQ==", "Q0NDQw=="):gsub("0.1000,0.2000", "0.3000,0.2000")
local h3 = h1:gsub("PT 0 0.5 0", "PT 0 0.9 0")
check(M.fx_skeleton(h1) == M.fx_skeleton(h2), "fx_skeleton: zmiana stanu wtyczki i gałek nie zmienia szkieletu")
check(M.fx_skeleton(h1) ~= M.fx_skeleton(h3), "fx_skeleton: zmiana automatyki parametru zmienia szkielet")
check(not M.fx_skeleton(h1):find("QUFBQQ", 1, true) and M.fx_skeleton(h1):find("<VST", 1, true), "fx_skeleton: bez danych binarnych, z nagłówkiem wtyczki")
check(M.fxp_lines(h1) ~= M.fxp_lines(h2), "fxp_lines: wykrywa zmianę gałki")
check(not M.build_track_chunk(h1, {}, {}):find("SESJA_FXP", 1, true), "build_track_chunk: SESJA_FXP nie trafia do REAPERa")

print(fails == 0 and "\nWSZYSTKIE TESTY OK" or ("\nBŁĘDY: " .. fails))
os.exit(fails == 0 and 0 or 1)
