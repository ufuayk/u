# u

A minimal, colorful and sleek terminal file manager for macOS.

```
 u — keybindings

╭──────────────────────────────────────────────────────╮
│  NAVIGATION              SELECTION                   │
│  j / ↓   move down       space   toggle mark         │
│  k / ↑   move up         x       cut selection       │
│  h / ←   parent dir      y       copy selection      │
│  l / →   open             p       paste here         │
╰──────────────────────────────────────────────────────╯
```

## Features

- **Vim-like navigation** — `j`/`k`/`h`/`l`, arrow keys, `g`/`G` to jump top/bottom
- **Split-pane preview** — see the contents of text files, source code, and directories without opening them
- **Archive peeking** — look inside `.zip` and `.tar.gz`/`.tgz` files without extracting
- **Cut / copy / paste** — move or duplicate files and folders, with smart name-collision handling
- **Multi-select** — mark several files at once for bulk delete/cut/copy
- **Git-aware** — folders containing a `.git` directory are highlighted in purple
- **Language-aware colors** — `.py`, `.js`, `.rb`, `.c`/`.cpp`, `.rs` files get distinct colors at a glance
- **In-app help** — press `u` or `?` anytime for a full keybinding reference

## Requirements

- macOS (Ruby ships preinstalled)
- A terminal emulator that supports ANSI escape codes (Terminal.app, iTerm2, etc...)

Ruby is *not* preinstalled by default on most Linux distributions — if you're on Linux, install it first (e.g. `sudo apt install ruby` / `sudo dnf install ruby`). I didn't develop u to be compatible with Linux.

## Installation
 
**Quick install (recommended):**
 
```bash
curl -fsSL https://raw.githubusercontent.com/ufuayk/u/macos/install.sh | bash
```
 
This downloads `u.rb` and installs it on your `PATH` as `u` (falls back to `~/.local/bin` if you don't have write access to `/usr/local/bin` or `sudo`).
 
**Manual install (not recommended):**
 
```bash
chmod +x u.rb
sudo mv u.rb /usr/local/bin/u
```
 
Either way, run `u` from anywhere once it's installed.

## Usage

```bash
u                          # opens in your home directory (default)
u /path/to/somewhere       # opens in a specific directory
u --start /path/to/dir     # same as above, explicit flag form
u --width 100 --height 30  # override the forced terminal size (default 120x40)
u --no-resize              # don't force-resize the terminal at all
u --help                   # print CLI usage and exit
```

By default, `u` asks your terminal to resize itself to 120×40 on launch — that's the size it's tuned for. Most modern terminal emulators honor this automatically; if yours doesn't, the layout still adapts gracefully to whatever size you have.

## Keybindings

| Key | Action |
|---|---|
| `j` / `↓` | Move down |
| `k` / `↑` | Move up |
| `h` / `←` | Go to parent directory |
| `l` / `→` / `Enter` | Open directory, open file, or peek inside an archive |
| `g` | Jump to top |
| `G` | Jump to bottom |
| `space` | Toggle mark on the current entry |
| `x` | Cut (marked entries, or current) |
| `y` | Copy / yank (marked entries, or current) |
| `p` | Paste into the current directory |
| `d` | Delete (marked entries, or current) — asks to confirm |
| `r` | Rename current entry |
| `n` | Create a new file |
| `N` | Create a new directory |
| `.` | Toggle hidden files |
| `/` | Filter entries by text |
| `R` | Refresh the listing |
| `v` | Toggle the preview pane |
| `u` / `?` | Toggle the in-app help screen |
| `q` / `Ctrl-C` | Quit |

Press `u` or `?` inside the app anytime — the full reference above is always one keypress away.

## Preview pane

Toggle it with `v`. It shows, on the right half of the screen:

- **Text & source files** (`.txt`, `.md`, `.py`, `.js`, `.rb`, `.sh`, `.c`, and more) — the actual file contents, read-only. Nothing is ever executed.
- **Directories** — a quick listing of what's inside.
- **`.zip` / `.tar.gz` / `.tgz` archives** — the list of files inside the archive, with sizes, without extracting anything to disk.

## Cut, copy, paste

- `y` copies the current (or marked) entries to an in-memory clipboard. It persists — paste it into as many places as you like.
- `x` cuts them instead. Cut is one-shot: it clears itself after a single paste (a move).
- `p` pastes into whatever directory you're currently browsing.
- Pasting into a directory that already has a file with the same name won't overwrite it — `u` automatically names the copy `file copy.ext`, `file copy 2.ext`, and so on, the same way Finder does.

## Design notes

- Everything is implemented with Ruby's standard library only — `io/console`, `fileutils`, `zlib`. No `rubyzip`, no third-party gems, no network calls.
- The `.zip` reader parses the ZIP central directory by hand; the `.tar.gz` reader parses USTAR headers over a `Zlib::GzipReader` stream. Both only *list* archive contents — extraction isn't implemented (yet).
- The whole file manager lives in a single executable script, so installing it is just copying one file onto your `PATH`.

## License

MIT. Not the university. xd
