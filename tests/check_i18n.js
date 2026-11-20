// Sprawdza, że każdy klucz użyty w app.js istnieje w każdym języku i że parametry się zgadzają.
// Uruchom: node tests/check_i18n.js
const fs = require("fs");
const path = require("path");
const { DICT, LANGS } = require("../app/ui/i18n.js");
const app = fs.readFileSync(path.join(__dirname, "../app/ui/app.js"), "utf8");
const used = new Set([...app.matchAll(/\b(?:th?|tn)\(\s*"([a-z0-9_]+)"/g)].map((m) => m[1]));
for (const m of app.matchAll(/"((?:nav|donate|st|act|net|ob|startup|reaper|mod|autostart|join|start|save)_[a-z_]+)"/g)) used.add(m[1]);
["track_add", "track_edit", "track_del", "item_add", "item_edit", "item_del", "order", "tempo", "comment_del", "unknown"].forEach((a) => used.add("act_" + a));
["tailscale", "lan", "other", "local"].forEach((k) => used.add("net_" + k));
// przedrostki składane w kodzie ("act_" + akcja) i nazwy komend Rusta to nie klucze
for (const k of [...used]) if (k.endsWith("_") || k === "save_config") used.delete(k);
const params = (s) => [...String(typeof s === "string" ? s : JSON.stringify(s)).matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort().join(",");
let errors = 0;
const ref = DICT.en;
for (const { code } of LANGS) {
  const d = DICT[code];
  for (const k of used) if (!(k in d)) { console.log(`brak ${code}.${k}`); errors++; }
  for (const k of Object.keys(ref)) {
    if (!(k in d)) { console.log(`brak ${code}.${k} (jest w en)`); errors++; continue; }
    if (typeof ref[k] === "string" && params(d[k]) !== params(ref[k])) { console.log(`parametry ${code}.${k}: ${params(d[k])} vs ${params(ref[k])}`); errors++; }
  }
  for (const k of Object.keys(d)) if (!(k in ref)) { console.log(`nadmiarowy ${code}.${k}`); errors++; }
}
console.log(`klucze użyte: ${used.size}, języki: ${LANGS.length}`);
console.log(errors ? `BŁĘDY: ${errors}` : "TŁUMACZENIA OK");
process.exit(errors ? 1 : 0);
