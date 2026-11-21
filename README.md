# ZZZ .zon Tool

A Windows desktop app for Remielle players: build characters, check and fix
`.zon` player files, and read character base stats straight from your own
`remielle.exe`. Everything runs locally; the app never goes online.

## The app window is the website

The app shows the real website (`site/index.html`) in its own window, using **CEF**
(Chromium Embedded Framework, Chrome's engine - not Edge, not WebView2). Every tab works
exactly like the site.

- **Nothing leaves your PC.** The page loads from local files; Chrome's background services,
  component updates and crash reports are off; all web traffic is pointed at a closed local
  port (`--proxy-server=http://127.0.0.1:9`), so nothing can go online even by accident.
- **Your saved builds** (the site's localStorage) live in `Public-zzz-tool-data/` next to the app.
- **Zoom** like a browser: Ctrl +, Ctrl -, Ctrl 0 or Ctrl + mouse wheel (starts at 110%, remembered).
- The window remembers its size and position (and whether it was maximized).
- Web links (the guides' links, YouTube, ...) open in your own browser; the app window itself
  never goes online.
- **App tools** (a link in the top bar, only inside the app): **Check file**, **Game save**
  and **Game data** (level-60 character and W-Engine stats read from your remielle.exe) -
  the app's own tools that read and write files on your PC. The page talks
  to them through `zzz://app/`, the app window's own address: it isn't a network address,
  no port is opened and no server runs.

The first `zig build` downloads CEF 156 (about 170 MB) from CEF's official build server with
Windows' built-in `curl` and `tar`, checks its SHA-1, unpacks it into `third_party/cef/` and
trims what the app never uses (other languages, sandbox launchers, WebGPU / software-3D
files) - about 335 MB kept, so later builds don't download again. Nothing is installed into Windows.

## Build and run

You only need **Zig 0.17.0** (the same one used to build Remielle).

```
git clone https://github.com/brandonyazz16/Public-zzz-tool
cd Public-zzz-tool
zig build run
```

`zig-out/bin/` is a complete app folder (`Public-zzz-tool.exe`, CEF's files, `site/`, `app_pages/`).
Update later with `git pull` and `zig build run` again.

### Ready-to-run zip

```
zig build release
```

makes `zig-out/Public-zzz-tool-windows.zip` (about 180 MB): unzip it anywhere and run
`Public-zzz-tool.exe` - no Zig needed on that PC.

## App tools

- **Check file**: open any player `.zon` and get every problem the server would reject, with
  the same messages and `line:column` as Remielle (it uses Zig's own `.zon` parser), plus
  character, W-Engine and disc names checked against the server's own lists, refine, Mindscape,
  skin_id (0 or one of that character's own skins, from remielle.exe), form (`"Eldreda"` etc.),
  rank/level, disc slots, main stats, substats and Potential. **Fix**, **Fix all** and
  **Save fixed copy** (your original is never overwritten).
  Names are checked against **your own remielle.exe** (picked in Game save): W-Engines, discs and
  places it has are accepted even if this app is older, names it no longer has are flagged (with a
  fix when Remielle renamed them), and a new character name your exe knows is only a notice.
  Until remielle.exe is picked, Check file and the site's .zon tabs are locked in the app.
- **Game save**: pick `remielle.exe`, pick a player, **Read** the save (runs
  `remielle print-player`), then **Pack** it back (runs `remielle pack-player`). Safety rules:
  - a file with any Check file error is never packed, and packing needs a second click;
  - the new save is packed to a separate file and read back with `print-player` before it's
    used - if Remielle refuses either step, nothing in the game folder changes;
  - the old save is copied to `Public-zzz-tool/backups/` first, then replaced atomically;
  - **Restore** puts any backup back (and backs up the save it replaces); backups are never deleted.
  After packing, log out and back in to the game to see the change (the server can stay open).
  Every pack reads the new save back and compares it, character by character, with what was
  sent. **Check the save** compares the save as it is now with the last pack - if the game or
  server wrote over it (e.g. when you logged out), it names the characters that changed.
- **Server**: **Start server** runs `remielle.exe` in its own command window (from the game
  folder, as if you ran it yourself); **Stop server** presses Ctrl+C in that window so it shuts
  down cleanly (if it's still running 10 s later it's ended).
- **Game (beta)**: pick remielle-bootstrap in your CNBetaWin client folder once, then
  **Start game**, or **Start server + game**. It needs admin rights, so Windows asks first.
- **Game save <-> .zon editor**: **Read into .zon editor** opens a player's save in the site's
  .zon editor (asks for a second click if the editor already has a loaded or edited file).
  Equip builds there as usual, then **Pack into game** (next to Download .zon, only in the app)
  checks the whole file first - any error and nothing is packed (the file opens in Check file
  to fix) - then packs it with the same safety rules as above.
- **Game data**: level-60 base stats for every character and W-Engine, decoded from your
  `remielle.exe` (Armorers show Automatic Sharpness Accumulation, Rupture characters
  Automatic Adrenaline Accumulation, in the Energy Regen slot - as on the site).
  A **Skins** column lists each character's skin ids (the .zon's `skin_id`; 0 = no skin), read
  from your remielle.exe (newer builds only).
  **Exe vs site** lists what your remielle.exe has that the site doesn't (with its stats) and
  every level-60 number that differs from the site's. It only lists - nothing is changed.

## Tests

```
zig build test
```

To run the tests that use your own files, copy them into `testdata/` (git-ignored):
`remielle.exe`, `template.zon` (a clean player file) and `broken-1.zon` (a file with a known error).
The test checks the decoded stats against numbers confirmed in game
(Banyue 8,497 HP / 784 ATK / 445 DEF / 95 Impact, Lucia, Seed, Dialyn, Astra Yao).

## Third-party code

- CEF 156 (Chromium Embedded Framework) - BSD, downloaded at build time - `third_party/cef` (the app window)
