# 雲拼 Yunpin

Yunpin (雲拼, "cloud pinyin") puts Google's cloud pinyin (the pinyin input on
Google Translate) inside
[Weasel](https://github.com/rime/weasel) (小狼毫), the Windows version of RIME.
While you're online, Google's candidates are ranked together with the local
[rime-ice](https://github.com/iDvel/rime-ice) (雾凇拼音) dictionary's. The
dictionary takes over when Google is slow or you're offline. Simplified and Traditional (Taiwan
character forms) are switchable.

This is a personal project, shared as is. It was built and tested on Windows 11
(build 26300) with Weasel 0.17.4, librime 1.13.1 and rime-ice 2026.06.30, and is
developed from WSL2. There are no prebuilt binaries: you build and install it
from WSL (see [Development](#development)).

## Using it

Switch to Weasel and type pinyin. Candidates marked ☁ come from Google.

| Key | Action |
|---|---|
| Space or a number key | Pick a candidate |
| Ctrl+Shift+4 | Toggle 简/繁 in the current window |
| Ctrl+Shift+3 | Toggle Chinese/English punctuation (中文標點/英文標點 in the F4 menu) |
| F4 | Schema menu: choose 简/繁 here to keep it for new windows, or switch to another schema |
| Left Shift | Toggle Chinese/English (letters typed so far are committed as-is) |

Weasel keeps the 简/繁 state per window. Only a choice made in the schema menu
is remembered for new windows.

What to expect (times measured on the development machine):

- **Online:** Google's and the dictionary's candidates are ranked together.
  One both suggest comes first: for `wlj`, 王老吉 (Google's 2nd, the
  dictionary's 3rd) beats 王立军 (Google's 1st). On a tie Google's wins, so
  its best guess for a whole sentence usually comes first. Each key waits for
  Google, typically 30–75 ms.
- **Google is slow:** after `timeout_ms` (200 ms) the key shows local
  candidates instead. Google's come back on a later key once it answers, so
  the order can briefly flicker.
- **Offline:** local candidates only, with no waiting (0–6 ms per key).
- **Partial picks:** pick 我们 out of 我们去公园 and Google converts the rest.
- **Learning:** whatever you pick is saved to your local user dictionary, so
  it comes up offline too. That includes a word neither Google nor the
  dictionary has, built from several picks (泥 then 好 for `nihao`). Words
  you've picked come first, online and offline, as RIME does offline. One
  picked by mistake goes with Ctrl+Delete, or falls back by itself after about
  500 other picks.
- **繁:** Taiwan character forms (裡, 為, 著急). Vocabulary isn't changed
  (软件 → 軟件); type `ruanti` for 軟體.
- **Mid-syllable:** Google's guess can look odd (`womenqugon` → 我们去个噢你)
  until you finish the syllable.
- **After a digit:** `,` `.` `:` are full-width like anywhere else (`3。`).
  rime-ice's digit separators, which hold them half-width for numbers like
  3.14, are off; switch to English punctuation (Ctrl+Shift+3) for those.

**Privacy:** while you compose, the pinyin you type is sent to
`inputtools.google.com`. The service is undocumented and could change or stop
working; the local dictionary keeps working either way.

## How it works

```
key ─► Weasel ─► WeaselServer ─► librime + rime-ice
                                  ├─ lua_translator@*cloud_pinyin
                                  │    └─ cloudhttp.dll ── HTTPS ──► inputtools.google.com
                                  ├─ script_translator             local dictionary
                                  └─ …                             rime-ice's dates, English, custom phrases
                                  filters: lua_filter@*cloud_pinyin*filter ► … ► simplifier@traditionalize (OpenCC s2tw) ► … ► lua_filter@*cloud_pinyin*apostrophes ► uniquifier
```

### `rime/lua/cloud_pinyin.lua`: the translator

- Runs for plain pinyin (lowercase letters and `'`). It skips rime-ice's
  special modes: symbols, radical lookup, Unicode, numbers, calculator and
  lunar dates.
- Asks Google for Simplified candidates (`itc=zh-t-i0-pinyin`). Latin-only
  candidates, such as the raw input, are dropped.
- Each candidate covers Google's `matched_length` of the input, so a partial
  pick leaves the rest of the input to be converted.
- RIME orders candidates first by how much input they cover, then by quality.
  Quality 100 puts Google's candidates ahead of the local dictionary's covering
  the same input. librime compares each translator only with the next one in
  the list, so the translator sits right before `script_translator`.
- The file's `filter` table (`lua_filter@*cloud_pinyin*filter`, first in the
  chain) keeps rime-ice's other candidates where rime-ice ranks them: the date
  for `rq`, English words such as `hello`, custom phrases. Each Google
  candidate waits for the next dictionary candidate.
- With `rank: blend`, the same filter then ranks Google's and the dictionary's
  candidates covering the same input together (reciprocal rank fusion). Each
  scores `cloud_weight / (blend_k + its place in Google's list)` plus
  `1 / (blend_k + its place in the dictionary's)`, so one both suggest scores
  twice. Ties go to Google. The dictionary's first 10 candidates for that input
  take part; the rest follow in rime-ice's order. Blending only reorders the
  places these candidates take, so other candidates stay where they are.
- With `used_first`, words you've picked come before that, in RIME's order:
  the user dictionary's, which holds picked Google candidates too. They're
  shown as RIME's candidates, not Google's, because Ctrl+Delete (RIME's
  `delete_candidate`) only removes the dictionary's.
- With `used_within`, only words picked recently enough come first, online
  and offline. RIME keeps a decaying count per word: each pick adds 1, and
  every word RIME saves after it shrinks it by e^(-1/200). Once a word's count
  is below a single pick's after `used_within` saves, it's ranked as if never
  picked: where the dictionary has it, or after the rest. The count comes from
  the candidate's weight, which also holds the typed spelling's credibility,
  so only words typed in full pinyin are judged; abbreviations and corrections
  keep coming first.
- 繁 conversion is rime-ice's own filter, so Google's and local candidates are
  converted the same way.
- The input box shows only letters you typed. A Google candidate's are split
  into syllables where Google's pinyin splits them, like the dictionary's:
  `wm` for 我们 shows `w'm`, not `wo'men`. If they don't line up, the input
  is shown as typed.
- The `apostrophes` filter puts `'` between syllables in the input box, as
  Microsoft and Google Pinyin do. rime-ice's own filters expect spaces there,
  so the speller still uses spaces and this filter runs near the end, just
  before `uniquifier`. A Lua filter after `uniquifier` would let duplicates
  through, because it reads ahead.
- On commit, picked Google candidates are written to `rime_ice.userdb`, with
  Google's pinyin as the code. RIME learns a word made of several dictionary
  picks by itself, but not one that includes a Google pick, so the script
  saves those. Dictionary picks get their pinyin from their syllables, not
  from what you typed, so abbreviations and corrected typos are saved
  correctly. A word with a pick that has no pinyin, such as an English word,
  isn't saved. Each commit that saves something uses a freshly loaded
  `Memory`: librime reads the user dictionary's tick (its clock for how
  recently words were picked) only on load and as RIME looks up, and saving
  writes that tick + 1, so an old `Memory` would set the clock back.

### `src/cloudhttp.c`: the HTTP module (`cloudhttp.dll`)

- `http.get(url, timeout_ms)` returns the response body, or `nil` and one of
  `"timeout"`, `"offline"`, `"failed"`, `"queued"` (when `timeout_ms <= 0`) or
  `"unavailable"` (WinHTTP or the background thread couldn't start).
  `http.stats()` returns counters for debugging.
- One background thread holds one WinHTTP session and keeps the TLS connection
  to Google open. A request on the open connection takes 27–79 ms; one that
  needs a new connection takes 90–130 ms. Windows proxy settings apply.
- A late reply isn't aborted, because that would drop the connection. It
  finishes in the background and goes into a 256-entry cache. Only the newest
  request waits in the queue.
- **Online/offline:** after a key times out or a request fails, callers stop
  waiting until a request succeeds again. That can be the late reply itself,
  so one slow reply only skips waiting for the keys typed before it lands. Each
  key still sends its request in the background, so recovery is automatic.
  Network timeouts are 2 s for DNS, 2 s for connecting and 3 s for transfers.
- It links against the Lua 5.4.7 API that Weasel's `rime.dll` exports. It
  stays loaded for the life of the process, because its thread outlives Lua
  states.

### `rime/rime_ice.custom.yaml`

Adds the translator and filters to rime-ice, holds the settings, and sets
`s2tw` for 繁.

## Configuration

Edit `rime/rime_ice.custom.yaml`, then run `scripts/deploy.sh`.

| Setting | Set to | Meaning |
|---|---|---|
| `cloud_pinyin/timeout_ms` | `200` | Longest a key waits for Google before showing local candidates |
| `cloud_pinyin/count` | `5` | Google candidates per request |
| `cloud_pinyin/comment` | `"☁"` | Marker on Google's candidates; `""` for none |
| `cloud_pinyin/learn` | `true` | Save picked Google candidates, and words that include one, to the user dictionary |
| `cloud_pinyin/rank` | `blend` | `blend`: rank Google's and the dictionary's candidates together. `cloud`: Google's first |
| `cloud_pinyin/blend_k` | `2` | With `blend`: lower favors each list's first candidates, higher favors ones both suggest |
| `cloud_pinyin/cloud_weight` | `1` | With `blend`: weight of Google's ranking against the dictionary's (1). Above 1 favors Google |
| `cloud_pinyin/used_first` | `true` | With `blend`: words you've picked come first, as RIME does offline |
| `cloud_pinyin/used_within` | `500` | With `used_first`: only words picked within about the last N picks (RIME counts each word it saves) |
| `cloud_pinyin/endpoint` | Google's | Request URL. The tests point it at a dead host to simulate being offline |
| `traditionalize/opencc_config` | `s2tw.json` | 繁 conversion: `s2tw` characters only, `s2twp` adds Taiwan vocabulary; `s2t` and `s2hk` also work |

The "Set to" column is what `rime/rime_ice.custom.yaml` sets. Without a line,
the script falls back to a 200 ms timeout, 5 candidates, no marker, no
learning and Google's candidates first (`blend_k` 2, `cloud_weight` 1 and no
`used_first` if `blend` is set without them; picked words never expire
without `used_within`), and 繁 uses rime-ice's own `s2t` (OpenCC
standard forms, not Taiwan's).

To stop using Google, remove the `engine/translators/@before 1` and
`engine/filters/@before 0` entries and deploy, or switch to another schema
with F4. For rime-ice's spaces between syllables instead of `'`, remove the
`engine/filters/@before last` entry.

### Window style

`rime/weasel.custom.yaml` styles the candidate window after the Windows 11
Traditional Chinese (Taiwan) IME: a vertical list in Microsoft JhengHei UI,
WinUI flyout colors, and the accent-colored bar on the highlighted row. It has
a dark scheme (`win11_dark`, used while Windows is in dark mode) and a light
one (`win11_light`). The sizes were measured from a screenshot of the
Microsoft IME at 150% scaling. The dark colors were measured too; the light
ones are WinUI's standard light values.

- The bar uses the author's Windows accent color (`#9D6820`): its Light2 shade
  in dark mode, Dark1 in light mode. To match your own accent color, update
  `hilited_mark_color` in both schemes.
- The composition is shown in the app, as the pinyin you typed with `'`
  between syllables (`preedit_type: composition`). To see the highlighted candidate there
  instead, like the Microsoft IME, set `style/preedit_type: preview`.
- Text size is `style/font_point` (10 matches the Microsoft IME).
- Weasel can't draw the Microsoft IME's bottom toolbar or scroll dots.

## Development

The scripts run in WSL and reach Windows through `/mnt/c` and `.exe` interop.

```
src/cloudhttp.c             HTTP module, deployed as lua\cloudhttp.dll
rime/lua/cloud_pinyin.lua   the translator
rime/rime_ice.custom.yaml   rime-ice patch and settings
rime/weasel.custom.yaml     candidate window style
test/http_test.lua          tests for cloudhttp.dll
test/luarun.c               runs a Lua script on rime.dll's Lua
test/rimetest.c             drives librime without a UI; commands are listed in the file
scripts/build.sh            cross-compiles with zig
scripts/test.sh             runs the tests in %LOCALAPPDATA%\ime-dev
scripts/deploy.sh           installs into Weasel
scripts/common.sh           paths shared by the scripts
backups/                    your RIME folder before the first install (not in git)
.tools/                     third-party pieces (see Setup; not in git)
build/                      build output (not in git)
```

### Setup

Weasel (x64) must be installed on Windows, and WSL needs `curl`, `objdump`
and `bsdtar`. `.tools/` holds zig, the Lua headers, the RIME API header and
rime-ice. To recreate it:

```sh
mkdir -p .tools && cd .tools

curl -fLo zig.tar.xz https://ziglang.org/download/0.17.0/zig-x86_64-linux-0.17.0.tar.xz
echo "1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026  zig.tar.xz" | sha256sum -c -
mkdir zig && tar -xJf zig.tar.xz -C zig --strip-components=1 && rm zig.tar.xz

# Lua headers must match the Lua inside Weasel's rime.dll (5.4.7 in Weasel 0.17.4)
curl -fLo lua.tar.gz https://www.lua.org/ftp/lua-5.4.7.tar.gz
echo "9fbf5e28ef86c69858f6d3d34eccc32e911c1a28b4120ff3e84aaa70cfbf1e30  lua.tar.gz" | sha256sum -c -
mkdir lua && tar -xzf lua.tar.gz -C lua && rm lua.tar.gz

mkdir librime && curl -fLo librime/rime_api.h \
  https://raw.githubusercontent.com/rime/librime/1.13.1/src/rime_api.h

mkdir -p rime-ice-dl/x && curl -fLo rime-ice-dl/full.zip \
  https://github.com/iDvel/rime-ice/releases/download/2026.06.30/full.zip
echo "675d23b070be00e1b800f9a6db033ef98f4493cd5b568ed8aa3b3541769c46ac  rime-ice-dl/full.zip" | sha256sum -c -
bsdtar -xf rime-ice-dl/full.zip -C rime-ice-dl/x
```

### Build, test, deploy

```sh
scripts/build.sh    # build/cloudhttp.dll, build/luarun.exe, build/rimetest.exe
scripts/test.sh     # all tests; or scripts/test.sh http, scripts/test.sh rime
scripts/deploy.sh   # install into Weasel and redeploy
```

- **`build.sh`** makes an import library from the installed Weasel's
  `rime.dll` exports, then compiles with `zig cc -target x86_64-windows-gnu`.
- **`test.sh`** never touches Weasel or your RIME folder. It copies the
  binaries and Weasel's `rime.dll` to `%LOCALAPPDATA%\ime-dev` and runs two
  suites. It needs network access, and the expected candidates are Google's
  answers as of October 2026.
  - `http` checks latency, the cache, the timeout and offline recovery.
  - `rime` runs the real engine with rime-ice in a test folder. It checks the
    ranking (both `blend` and `cloud`), 繁, partial picks, the input box,
    offline mode and learning. The first
    run compiles rime-ice, which takes about a minute.
- **`deploy.sh`** does the following:
  1. Stops WeaselServer.
  2. If Yunpin isn't installed yet, backs up your RIME folder to `backups/`
     and lists which of your settings files it's about to replace.
  3. Copies rime-ice and our files in, replacing files with the same names.
     That includes `default.yaml`, `rime_ice.custom.yaml` and
     `weasel.custom.yaml` (the window style). If you already use rime-ice,
     move your own patches into `rime/rime_ice.custom.yaml` here. It leaves
     out rime-ice's `weasel.yaml`, `squirrel.yaml` and the schemas Yunpin
     doesn't use (double pinyin, T9).
  4. Puts `rime_ice` first in the schema list in `default.custom.yaml`,
     keeping your other schemas and settings there.
  5. Runs `WeaselDeployer.exe /deploy` and restarts the server.

### Things to know

- Changes to the Lua script or the DLL need a WeaselServer restart:
  librime-lua caches modules, and the DLL is locked while loaded.
  `deploy.sh` does the restart.
- After upgrading Weasel, run build, test and deploy again, since the import
  library comes from its `rime.dll`. If Weasel moves off Lua 5.4, update the
  Lua headers too.
- To update rime-ice, replace `.tools/rime-ice-dl/x` with the new release,
  then test and deploy.
- Don't point `rimetest` at your live RIME folder. Weasel holds the lock on
  the user dictionary, and the test would write into your data.
- RIME notices changed files by timestamps with 1-second resolution, so
  `test.sh` waits a second before editing settings and forces a deploy after.

## Troubleshooting

- **No ☁ candidates:**
  - Check that the schema is 雾凇拼音 (F4).
  - Look for `cloud_pinyin` errors in the logs in `%TEMP%\rime.weasel\`.
  - Check that the module is loaded (it loads when you first type) with this
    PowerShell command:
    `(Get-Process WeaselServer).Modules | ? ModuleName -like 'cloudhttp*'`
  - Run `scripts/test.sh http` to check the network path.
- **☁ shows as a box:** your font lacks the symbol; change `comment`.
- **Typing feels slow:** lower `timeout_ms`.

## Undo

The quick way is to switch back to the schema you used before in the F4 menu.
Deploy keeps it in the list.

To restore the RIME folder as it was before the first install, run the
following from this directory. It deletes everything learned since then,
including `rime_ice.userdb`. It uses the oldest backup in `backups/`.

```sh
W=$(ls -d "/mnt/c/Program Files/Rime"/weasel-* | sort -V | tail -1)
# Your RIME folder: %APPDATA%\Rime unless you set another one in Weasel
R=$(wslpath "$(cd /mnt/c && cmd.exe /c 'echo %APPDATA%' | tr -d '\r')")/Rime
B=$(ls backups/Rime-*.tar.gz | head -1)   # the backup deploy.sh made
(cd "$W" && ./WeaselServer.exe /q)
rm -rf "${R:?}"/* && tar -xzf "${B:?}" -C "$R"
(cd "$W" && ./WeaselDeployer.exe /deploy)
```

Then start Weasel again, either from the Start menu or with
`start_service.bat` in Weasel's folder.

## License

[MIT](LICENSE). Yunpin doesn't include or redistribute any third-party code or
data. The setup steps download zig, Lua, the RIME API header and rime-ice,
each under its own license (rime-ice is GPL-3.0). Yunpin isn't affiliated with
Google or the RIME project.
