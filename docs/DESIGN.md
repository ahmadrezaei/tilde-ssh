# Tilde: SSH Client & Terminal. Design Spec v0.1

> Status: **draft for approval**. No app code has been written yet.
> Companion files: [`design/icon.svg`](../design/icon.svg) (app icon) and [`design/mockups.html`](../design/mockups.html) (visual mockups; open it in a browser).
> Toolchain assumed: Xcode 27.1, Swift 6.4. Date: 2026-11-25.

---

## 0. TL;DR

| | |
|---|---|
| **Brand** | **Tilde** (`~`: the shell's home directory, which is where every session starts) |
| **App Store name** | `Tilde – SSH Client & Terminal` (29/30) |
| **Subtitle** | `Remote Server Shell for DevOps` (30/30) |
| **Keywords** | `servers,secure,console,sysadmin,linux,unix,vps,homelab,cloud,host,root,keys,ed25519,bash,sre,admin` (98/100) |
| **Repo** | `github.com/<owner>/tilde-ssh` |
| **License** | Apache-2.0 (+ `TRADEMARKS.md` reserving the name/icon) |
| **Platforms** | iOS 26+, iPadOS 26+, macOS 26+ (one multiplatform SwiftUI target per OS family, shared Swift package) |
| **Stack** | SwiftUI · SwiftData + CloudKit (private DB) · iCloud Keychain · Citadel (swift-nio-ssh) · SwiftTerm · CryptoKit |
| **Look** | Terminal-first, dark by default, SF Mono everywhere data appears, one accent (mint `#2DD4BF`), red means **production** |

Design principles (used to settle trade-offs):

1. **Terminal first.** The terminal gets every pixel it can. Chrome is thin, translucent, and gets out of the way.
2. **Three taps to a prompt, max.** Open the app, tap a server, and you are typing. Quick Connect takes `user@host:port` from the search field.
3. **Make prod look dangerous.** Environment colors are part of the UI: a red `PROD` stripe on tabs, the title bar and the paste confirmation.
4. **Secrets never leave the Keychain.** CloudKit stores metadata only. Passwords and private keys are kept in iCloud Keychain, which is end-to-end encrypted.
5. **No account, no telemetry, no upsell.** The app is free and open source, and iCloud is the only backend.
6. **Keyboard-driven on every device.** ⌘-shortcuts on iPad and Mac, and a purpose-built key bar on touch devices.

---

## 1. Naming, App Store & SEO

### 1.1 Name

**Tilde** is short, has two syllables, and is instantly meaningful to anyone who has typed `cd ~`. It also gives a simple icon: a tilde ending in a block cursor. Rejected candidates: *Vigil* (good "3am on-call" story, but it is used by a well-known OSS status-page project), *Rook* (CNCF Rook/Ceph), *Keel* (keel.sh), *Bastion* (Azure Bastion), *Terminus* (renamed over a trademark dispute), *Hop* (crowded). None of the brands listed in the brief (Termius, Blink, Prompt, Secure ShellFish, WebSSH, La Terminal, Shelly) is close to Tilde, and a search for an existing "Tilde" SSH app on the App Store found none.

> **Pre-launch check (owner: WS6):** run a USPTO/EUIPO/WIPO search for "TILDE" in class 9 and class 42. Known adjacent marks are *Tilde SIA* (Latvian language technology) and *Tilda* (a website builder), both in different product spaces. The descriptive suffix in the App Store name ("SSH Client & Terminal") reduces confusion. Fallback brands if legal says no: **Vigil**, **Hostty**.

### 1.2 App Store metadata

| Field | Value | Count |
|---|---|---|
| Name | `Tilde – SSH Client & Terminal` | 29 / 30 |
| Subtitle | `Remote Server Shell for DevOps` | 30 / 30 |
| Keywords | `servers,secure,console,sysadmin,linux,unix,vps,homelab,cloud,host,root,keys,ed25519,bash,sre,admin` | 98 / 100 |
| Home-screen name (`CFBundleDisplayName`) | `Tilde` | |
| Primary / secondary category | **Developer Tools** / Utilities | |
| Price | Free. No IAP, no ads, no tracking | |
| Age rating | 4+ | |
| Privacy label | **Data Not Collected** | |

**SEO rationale**

- Apple indexes **name + subtitle + keywords** together, so no word is repeated across them. The name covers `ssh`, `client`, `terminal` and the brand `tilde`. The subtitle covers `remote`, `server`, `shell` and `devops`. The keyword field holds only words that appear in neither.
- The searches the brief cares about all hit indexed fields: "ssh", "ssh client", "terminal", "server" (subtitle), "servers" (keyword; Apple stems many plurals, but we spend 8 characters to be certain) and "secure shell" (`secure` + `shell`).
- The keyword field contains no trademarks (AWS, Ubuntu, Raspberry Pi, Kubernetes, PuTTY), because Apple rejects those. It also lists no features that are not shipped yet (`sftp`, `mosh`, `tunnel`); add those when they ship.
- Uses `,` with no spaces, singular forms, and no category name ("developer" is implied by the category).
- Localize later: en-GB/en-AU/en-CA get their own keyword fields for free, which is extra keyword space for synonyms such as `dedicated,ops,oncall,tty`.

**Promotional text (170 max, editable without review)**, 150 chars:
> Your servers, one tap away. Ed25519 keys, iCloud-synced hosts, and a keyboard built for Ctrl-C at 3am. Free and open source — no account, no tracking.

**Description** (the first three lines are what people see above "more"):
```
A fast, native SSH client and terminal for iPhone, iPad and Mac.
Connect with a password or SSH key. Your servers sync over iCloud; your secrets stay in iCloud Keychain.
Built for DevOps and SREs: dark, dense, keyboard-first. Free and open source.

• Server list with groups, tags, search and live reachability
• Quick Connect: type user@host:port and go
• Ed25519 key generation, import Ed25519 / ECDSA / RSA keys, share public keys
• Host key verification with loud warnings when a fingerprint changes
• A real SSH keyboard: Esc, Ctrl, Alt, Tab, arrows, | ~ / -, F-keys, snippets
• Sticky modifiers, swipe-for-arrows, flick for alternate symbols, fully customizable
• Tabs on iPad and Mac, hardware keyboard shortcuts, Option-as-Meta
• Auto-reconnect and one-switch tmux attach
• Jump host (ProxyJump) support
• Face ID / Touch ID app lock
• Production servers are color-coded so you never type into the wrong box
• Open source (Apache-2.0). No account. No analytics. Ever.
```

**Screenshots (6.9", 13" iPad, Mac)**: (1) Terminal running htop with the key bar, caption "A real SSH keyboard". (2) Server list with PROD/STG badges, caption "Every server, one tap". (3) iPad tabs, caption "Tabs. Shortcuts. Done." (4) Host key warning, caption "Paranoid by default". (5) Key manager, caption "Ed25519 in one tap". (6) Mac window, caption "Native on Mac too".

### 1.3 Repository & license

- **Repo:** `tilde-ssh` (the bare word "tilde" is overloaded on GitHub; `tilde-ssh` is searchable and self-describing). Topics: `ssh`, `ssh-client`, `terminal`, `swiftui`, `ios`, `macos`, `ipados`, `devops`, `citadel`, `swiftterm`.
- **License: Apache-2.0.**
  - All runtime dependencies are permissive and compatible: Citadel (MIT), swift-nio-ssh fork (Apache-2.0), swift-nio, swift-crypto, swift-log, swift-collections (Apache-2.0), BigInt (MIT), ColorizeSwift (MIT), SwiftTerm (MIT), JetBrains Mono / Nerd Font glyphs (OFL-1.1, bundled font files only).
  - It has no copyleft, so App Store distribution is clean. GPL software conflicts with App Store terms.
  - Over MIT, Apache-2.0 adds an **explicit patent grant**, which matters for a crypto-heavy app, and **§6 explicitly withholds trademark rights**, so forks can't ship to the App Store as "Tilde" with our icon. A `TRADEMARKS.md` file makes that explicit.
  - It matches the license of the Apple swift-nio ecosystem we build on.
  - Required files: `LICENSE`, `NOTICE` (third-party attributions, also rendered in Settings › About › Acknowledgements), `TRADEMARKS.md`, `SECURITY.md` (private vulnerability reporting via GitHub Security Advisories), `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`.

---

## 2. Brand

### 2.1 Icon (`design/icon.svg`)

- **Concept:** a heavy, rounded **tilde** (`~`, home) flowing into a **block cursor** (`▮`, ready for input), in phosphor mint on a deep ink squircle with a faint dot grid. Read together it is "home, ready": a prompt waiting for you.
- **Grid:** 1024×1024 canvas. The glyph sits inside Apple's central ~660 px keyline region and is optically centered (shifted +4 px down, because a cursor on a baseline looks high otherwise).
- **Small sizes:** at 29–60 px the dot grid disappears and the shape reads as `~▮`. The stroke is 110 px (after scaling), so nothing thinner than ~2 px survives at 29 pt @1x.
- **Variants (Icon Composer, iOS/macOS 26):** the SVG groups are layer-ready. `#background` becomes the background layer, `#grid` an optional texture, and `#glyph` the foreground layer.
  - Default (dark): as drawn.
  - Light-mode appearance: background `#E9EEF2 → #FFFFFF`, glyph `#0F9F8F`.
  - Tinted/Clear: the glyph is monochrome-friendly (a single shape plus a rectangle), so the system tint applies cleanly.
- **Export:** drop the preview clip-path (the OS applies its own mask) and export through Icon Composer to an `AppIcon.icon` bundle. A 1024 px PNG fallback goes in `Assets.xcassets`.

### 2.2 Color tokens

The UI and the terminal share a palette, and the app is **dark by default regardless of system setting**. Settings › Appearance offers `Dark (default) · Match System · Light`.

| Token | Dark | Light | Use |
|---|---|---|---|
| `bg` | `#0B0F14` | `#F6F8FA` | window / terminal background |
| `surface` | `#11161D` | `#FFFFFF` | sidebars, lists, key bar |
| `surface2` | `#171D25` | `#F0F3F6` | rows, cards, keys |
| `surface3` | `#1F2630` | `#E7EBEF` | inputs, pressed keys |
| `border` | `#262E39` | `#D5DBE1` | hairlines (0.5 pt) |
| `text` | `#E6EDF3` | `#1F2328` | primary text |
| `text2` | `#9AA6B2` | `#59636E` | secondary (user@host) |
| `text3` | `#5F6B78` | `#8C959F` | tertiary, placeholders |
| `accent` | `#2DD4BF` | `#0F9F8F` | brand mint, focus, armed modifiers, cursor |
| `accentStrong` | `#14B8A6` | `#0B7D71` | pressed accent, primary buttons |
| `accentSoft` | `#2DD4BF24` | `#0F9F8F1F` | selection, armed-key fill |
| `ok` | `#3FD68B` | `#1A7F4B` | connected, reachable < 150 ms |
| `warn` | `#F5B83D` | `#9A6700` | slow (≥ 150 ms), reconnecting, STAGING |
| `danger` | `#F7525F` | `#CF222E` | errors, host-key changed, **PRODUCTION** |
| `info` | `#58A6FF` | `#0969DA` | DEV environment, links |
| `lab` | `#C792EA` | `#8250DF` | LAB / homelab environment |

**Environment colors** (one per server) are `prod → danger`, `staging → warn`, `dev → info`, `lab → lab`, `none → text3`. They appear as a 2 pt stripe on the top edge of tabs and the terminal title bar, as a badge in lists, and in the paste-confirmation sheet.

### 2.3 Typography

- **Data and terminal:** **SF Mono** (`.monospaced` design / `monospacedSystemFont`) for hostnames, usernames, ports, fingerprints, key material, and the terminal.
- **Bundled alternative:** **JetBrains Mono Nerd Font Mono** (OFL), so Powerline/Starship/p10k prompt glyphs render. Users can pick SF Mono, JetBrains Mono NF, or Menlo.
- **Chrome:** SF Pro (system) for labels, buttons and section headers. Section headers are caps, 11 pt, +0.6 tracking, `text3`.
- **Sizes:** terminal default 12 pt on iPhone, 13 pt on iPad, 13 pt on Mac. Pinch, or ⌘+/⌘−, adjusts it per device, and the value is stored per device (not synced) because screens differ.
- **Dynamic Type:** chrome follows Dynamic Type. Terminal font size is independent but respects a minimum of 9 pt.

### 2.4 Default terminal theme: "Tilde Night"

| Slot | Normal | Bright |
|---|---|---|
| black | `#1C232B` | `#4B5663` |
| red | `#F7525F` | `#FF7B85` |
| green | `#3FD68B` | `#6EE7A8` |
| yellow | `#F5B83D` | `#FFD479` |
| blue | `#58A6FF` | `#82BFFF` |
| magenta | `#C792EA` | `#DDB6F2` |
| cyan | `#2DD4BF` | `#7CF5DD` |
| white | `#C9D1D9` | `#F5F8FA` |

Background `#0B0F14`, foreground `#D6DEE6`, cursor `#2DD4BF` (block, blinking off by default, which is calmer at 3am), selection `#2DD4BF33`, bold-as-bright off.

Built-in themes at MVP: **Tilde Night** (default), **Tilde Day**, **Midnight High Contrast** (WCAG AAA, for incident-room projectors). Importing iTerm2 `.itermcolors` comes later.

### 2.5 Voice

Short and literal. Use "Connect", not "Let's get connected!". Error copy names the cause and gives the fix: *"Permission denied (publickey). The server didn't accept key `macbook-ed25519`. Add the public key to `~/.ssh/authorized_keys` on db-primary."*

---

## 3. Information architecture & navigation

### 3.1 Shared concepts

- **Server**: a saved connection (host, port, user, auth, environment, group, tags).
- **Session**: a live SSH connection with a PTY, shown as a **tab**. One server can have several sessions.
- **Key**: an SSH identity. Private material lives in the Keychain, and only metadata syncs.
- **Snippet**: a saved command, inserted (or inserted and run) into the active session.
- **Known Host**: a pinned host key fingerprint (TOFU).
- **Quick Connect**: the search field doubles as an address bar (`user@host:port`).
- **Command Palette** (⌘P on iPad/Mac; long-press the tab button on iPhone): a fuzzy jump to a server, session, snippet or action.

### 3.2 iPhone (compact)

```
TabView (iOS 26, bottom tab bar)
├─ Servers        NavigationStack: ServerList → ServerDetail/Edit
├─ Keys           NavigationStack: KeyList → KeyDetail / Generate / Import
├─ Snippets       NavigationStack: SnippetList → SnippetEdit
└─ Settings       NavigationStack: Settings → sub-pages (Known Hosts lives here)
   tabViewBottomAccessory: "Live sessions" pill  (● 3 live · prod-api-01  ›)

SessionDeck (fullScreenCover, over everything)
└─ paged sessions (swipe with two fingers, or the tab-count button → grid switcher)
```

- Tapping a server opens the **SessionDeck** with a new session, or focuses that server's existing session (long-press offers "New session").
- Closing the deck (chevron top-left) **keeps the sessions alive**. The live pill on the tab bar brings it back, using iOS 26's `tabViewBottomAccessory`.
- Search/Quick Connect is pinned at the top of Servers (`.searchable`, always visible, never collapsed).

### 3.3 iPad (regular)

```
NavigationSplitView (2 columns)
├─ Sidebar (320 pt, collapsible ⌘⌃S)
│   ├─ Quick Connect field
│   ├─ LIVE (sessions, with status dots)
│   ├─ FAVORITES
│   ├─ GROUPS (collapsible, drag to reorder)
│   ├─ TAGS (filter chips)
│   └─ footer: Keys · Snippets · Known Hosts · Settings  (open as sheets)
└─ Detail: SessionContainer
    ├─ Tab strip (env stripe, status dot, title, ⌘1–9 badges on ⌘-hold, + button)
    └─ TerminalSurface (+ KeyBar when software keyboard is up)
```

- **Scenes:** multiple windows are supported (Stage Manager): "Open in New Window" on a tab or a server.
- **iPadOS 26 menu bar:** the same `.commands` as on Mac (see 3.5), so shortcuts are discoverable by swiping down or holding ⌘.
- **Hardware keyboard shortcuts:**

| Shortcut | Action |
|---|---|
| ⌘T | New tab (opens Quick Connect palette) |
| ⌘W | Close tab (confirm if a process is running) |
| ⌘⇧T | Reopen last closed session |
| ⌘1…⌘9 | Go to tab n (⌘9 = last) |
| ⌘⇧[ / ⌘⇧] | Previous / next tab |
| ⌘L | Focus Quick Connect (it acts like an address bar) |
| ⌘P | Command palette (servers, sessions, snippets, actions) |
| ⌘⇧S | Snippets palette |
| ⌘R | Reconnect current session |
| ⌘K | Clear screen and scrollback (Terminal.app/iTerm2 convention) |
| ⌘F | Find in scrollback |
| ⌘+ / ⌘− / ⌘0 | Font bigger / smaller / reset |
| ⌘N | New window |
| ⇧⌘N | New server |
| ⌘, | Settings |
| ⌘⌃S | Toggle sidebar |
| ⌘D / ⌘⇧D | Split right / down (**v1.1**) |
| ⌘. | Send Esc (Apple Magic Keyboard for iPad has no Esc key) |

### 3.4 Mac

```
WindowGroup "main" → NavigationSplitView (sidebar identical to iPad) + tab strip + terminal
WindowGroup(for: SessionID.self) "session" → a single detached session window
Window "Keys" (⌥⌘K)   Window "Snippets" (⌥⌘S)
Settings scene (⌘,)    MenuBarExtra (v1.1: quick connect from the menu bar)
```

- The unified toolbar holds a sidebar toggle, a centered **Quick Connect field** (⌘L), the session's latency pill, the snippets button, and `+`.
- Tabs live in an in-window tab strip (same component as iPad) rather than native NSWindow tabs, because native tabs duplicate the sidebar per tab. "Move Tab to New Window" opens the `session` WindowGroup.
- Terminal specifics: left Option = Meta (default on; right Option stays compose, for international users), copy-on-select (off by default), bracketed paste, a secure-keyboard-entry toggle in the Session menu, mouse reporting, ⌘-click to open URLs.

**Menus**

| Menu | Items |
|---|---|
| **Tilde** | About, Settings… ⌘, , Lock Now ⌃⌘L, Quit |
| **File** | New Tab ⌘T, New Window ⌘N, New Server… ⇧⌘N, Quick Connect ⌘L, Import from ~/.ssh/config…, Close Tab ⌘W, Close Window ⇧⌘W |
| **Edit** | Copy ⌘C, Paste ⌘V, Paste Snippet… ⇧⌘S, Select All ⌘A, Find… ⌘F, Find Next ⌘G |
| **View** | Show/Hide Sidebar ⌃⌘S, Bigger ⌘+, Smaller ⌘−, Actual Size ⌘0, Theme ▸, Enter Full Screen ⌃⌘F |
| **Session** | Reconnect ⌘R, Disconnect ⌥⌘W, Clear Scrollback ⌘K, Send Break, Secure Keyboard Entry, Edit Server…, Copy SSH Command ⌥⌘C |
| **Window** | Previous/Next Tab ⌘⇧[ ⌘⇧], Tab 1…9 ⌘1–9, Move Tab to New Window, Keys ⌥⌘K, Snippets ⌥⌘S |

---

## 4. Screen specs

> Density target: list rows are 44 pt on iOS and 28 pt on Mac. Monospace for every machine-readable value. No illustrations except in empty states.

### 4.1 Server list

**Row anatomy** (left to right):
1. **Status dot** (8 pt): `ok` reachable under 150 ms · `warn` slow · `danger` unreachable · `text3` not probed · pulsing `accent` = live session open.
2. **Name** (SF Mono 15 semibold, `text`), e.g. `prod-api-01`.
3. **Second line** (SF Mono 12, `text2`): `deploy@10.0.1.12:22` plus a key glyph (🔑 icon = key auth, ••• icon = password auth). Port is shown only if it is not 22.
4. **Trailing:** environment badge (`PROD` red, `STG` amber, `DEV` blue, `LAB` purple; caps 10 pt on a tinted capsule) and latency `23ms` (SF Mono 11, `text3`).

**Structure:**
- Pinned search/Quick Connect field: placeholder `Search or user@host:port`.
- `LIVE` section (only when sessions exist).
- `FAVORITES`.
- One section per **group** (collapsible, with a count), then `UNGROUPED`.
- A tag filter chip row under the search field (horizontal scroll): `All · k8s · db · edge · web …`. Multi-select uses AND logic.
- Sort is manual within a group (drag); a "Sort by name / last used" option in the `…` menu.

**Search behaviour:** fuzzy matches on name, host, user, tags and group.
- If the query parses as a connection target (`user@host`, `host:port`, `ssh -p 2 user@h`, `ssh://…`), the first row becomes **`↵ Connect to deploy@10.0.4.12:2222`** (accent) and Return connects. The tab action then offers "Save as server…".
- Typing `#tag` filters by tag, and `env:prod` filters by environment.

**Actions:**
- Tap: connect, or focus the existing session.
- Leading swipe: **Connect in new session** (accent).
- Trailing swipe: Edit, Delete (red, with confirm).
- Context menu: Connect, New Session, Edit, Duplicate, Copy SSH Command (`ssh -p 2222 -J bastion deploy@10.0.4.12`), Copy Host, Favorite, Move to Group ▸, Delete.

**Reachability probe:** a TCP connect to `host:port` via `NWConnection`. It runs on appear for visible rows, at most once every 60 s per host, with 3 concurrent probes and a 3 s timeout. It skips jump-host servers (it probes the bastion instead) and pauses on Low Data Mode and cellular unless Settings › Network › "Probe on cellular" is on. No SSH handshake is done, so there are no auth attempts and no log noise on servers.

**Toolbar:** iPhone has `+` (menu: New Server, Import from file, Generate Key), `…` (Sort, Select, Show/Hide offline). iPad/Mac use the same actions in the sidebar header.

### 4.2 Add / Edit server

A single scrolling `Form`, grouped, with dense rows. Required fields are marked by placeholder only. **Save** is enabled once Host is non-empty, and **Save & Connect** is the primary button on iPhone (bottom bar).

| Section | Fields |
|---|---|
| **Connection** | Name (placeholder auto-fills from host) · Host (hostname / IPv4 / IPv6; `.URL` keyboard, no autocorrect) · Port (numeric, default 22) · Username (default from Settings › Default user, e.g. `root`) |
| **Authentication** | Segmented: **Key** · **Password**. Key: picker of keys (shows type and fingerprint tail) plus "Generate new Ed25519…" inline. Password: secure field plus "Ask every time" toggle (then nothing is stored). |
| **Organize** | Environment (segmented: None / Dev / Staging / Prod / Lab, color dots) · Group (picker plus "New group…") · Tags (token field) · Favorite |
| **Advanced** (collapsed) | Jump host (picker of servers, single hop at MVP) · Startup command (e.g. `tmux new -A -s tilde`) · **Auto-attach tmux** toggle (fills the startup command) · Keep-alive interval (default 30 s) · TERM (`xterm-256color`) · Environment variables (`LANG=en_US.UTF-8`; sent via `env` requests, which servers may reject) · Notes (multiline, mono) |
| **Danger zone** (edit only) | Forget host key · Delete server |

- Paste helper: pasting `ssh -p 2222 -J bastion deploy@10.0.4.12` into Host splits it across the fields.
- **Test connection** button: does the handshake, host key and auth, then disconnects. It reports `✓ Authenticated as deploy (ed25519) in 182 ms`.

### 4.3 Key manager

**List:** one row per key. Row: key glyph, **name** (mono), type badge (`ED25519`, `ECDSA-P256`, `RSA-4096`), `SHA256:4f+Hq…Vw0` (mono, truncated middle), "used by 7 servers", sync glyph (☁ synced via iCloud Keychain / 📱 this device only).

**Generate:** a sheet with Name (default `<device>-ed25519`, e.g. `iphone-ed25519`), Type (**Ed25519** default · ECDSA P-256 · RSA 4096 marked "compatibility"), Comment (`tilde@iphone`), "Sync via iCloud Keychain" toggle (on), "Protect with passphrase" (v1.1). Generation takes under 50 ms (RSA is ~1 s, with a spinner).

**Import:**
- Sources: Files (`.pem`, `id_*`, `.key`), paste from clipboard, drag & drop (iPad/Mac), Mac `~/.ssh` folder picker.
- Formats: OpenSSH (`-----BEGIN OPENSSH PRIVATE KEY-----`) for Ed25519 / ECDSA / RSA. PEM PKCS#1 (`RSA PRIVATE KEY`), SEC1 (`EC PRIVATE KEY`) and PKCS#8 (`PRIVATE KEY`).
- Encrypted keys prompt for the passphrase (bcrypt-pbkdf, aes256-ctr/cbc). After import the key is stored **decrypted inside the Keychain**, which is the protection boundary. The passphrase is not stored.
- Rejected: PuTTY `.ppk` ("convert with `puttygen key.ppk -O private-openssh`"), DSA ("DSA is insecure and disabled in OpenSSH").

**Detail:** shows the public key in a mono block with tap-to-copy. Actions:
- **Copy public key**; **Share…** (share sheet: text or `.pub` file); **Copy `ssh-copy-id`-style one-liner**: `mkdir -p ~/.ssh && echo 'ssh-ed25519 AAAA… tilde@iphone' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys`.
- **Install on server…**: pick a server you can already reach by password, and Tilde appends the key over SSH with an exec channel, idempotently (`grep -qxF`).
- **Export private key** (behind Face ID plus a confirm, which warns you; it exports in OpenSSH format).
- Used-by list. Rename. **Delete**: blocked while servers reference the key, unless you reassign them.

### 4.4 Quick Connect

- The same field as search, plus ⌘L / ⌘T palettes on iPad/Mac.
- Parser accepts `host`, `user@host`, `user@host:port`, `[v6]:port`, `ssh://user@host:port`, `ssh [-p N] [-l user] [-i keyname] [-J jump] user@host`.
- Auth resolution order:
  1. A saved server matching host+port+user: use its settings.
  2. Otherwise the **default key** (Settings › Default key).
  3. Otherwise prompt for a password (sheet with "Save server" checkbox).
- The **recent** quick connects (last 10, synced) show as suggestions under the field.

### 4.5 Terminal session screen

**iPhone portrait**, top to bottom:
1. **Title bar (36 pt, translucent `surface` 85% + blur):** `‹` (close deck) · env stripe 2 pt across the top edge (PROD red) · title `prod-api-01` (mono semibold) with subtitle `● 23ms · 80×24` · trailing: **tab count button** `[3]` (tap = session grid, long-press = palette) · `…` menu (Snippets, Find, Reconnect, Font size, Copy SSH command, Edit server, Disconnect).
2. **Terminal surface** (SwiftTerm), full bleed, 4 pt inner padding.
3. **Modifier HUD**: when Ctrl/Alt is armed or locked, a small chip `CTRL` / `CTRL 🔒` appears in the bottom-right corner of the terminal, just above the key bar where your eyes already are.
4. **Key bar** (accessory, see §5) sits above the system keyboard.

**Gestures on the terminal (iOS/iPadOS)**

| Gesture | Effect |
|---|---|
| Tap | Show keyboard (if hidden) |
| Double-tap | Select word |
| Long-press | Start selection (magnifier), then the edit menu: Copy · Paste · Select All · Copy Output Line |
| 1-finger vertical pan | Scroll back. In an alt-screen app with mouse reporting (htop, vim), it sends wheel events |
| Swipe down past the top of the keyboard | Dismiss keyboard (interactive) |
| 2-finger horizontal swipe | Previous / next session (iPhone) |
| Pinch | Font size (shows `13 pt` HUD) |

**Paste safety:** pasting text that contains a newline shows a confirmation sheet, *"Paste 14 lines into **prod-api-01**?"*, with a preview of the first 5 lines. The default is on for PROD servers and off for others (Settings › Terminal › Confirm multi-line paste: Prod only / Always / Never). Bracketed paste is used when the remote shell enables it.

**Session states (overlay on the terminal, never a modal):**
- `connecting`: a centered mono line `Connecting to deploy@10.0.1.12:22 …` with a spinner.
- `reconnecting`: a top banner `⟳ Connection lost. Reconnecting in 3s (attempt 2)` with buttons `[Now]` `[Close]`. Backoff is 1, 2, 4, 8, 15, 30 s, then manual. The scrollback stays visible and dimmed to 60%.
- `disconnected`: a banner `Session ended (exit 0)` with `[Reconnect ⌘R]` `[Close tab]`.
- Backgrounding on iOS: the app asks for background time (`beginBackgroundTask`, ~30 s). On return, if the socket is dead, it reconnects automatically. If **Auto-attach tmux** is on, the user lands back in the same tmux session, which is the recommended setting and is offered in the first-run tip.

**iPad:** the same, inside the detail column with a tab strip. The key bar is wider (§5.4). On Mac there is no key bar, and a find bar (⌘F) appears at the top of the terminal.

### 4.6 Host key verification

**Unknown host (TOFU)**: a sheet (medium detent), which never auto-dismisses.
```
First connection to db-primary
10.0.2.5:22 presented an ED25519 key:
SHA256:p3Kc9yFQ2nL0e1x7XvR8bq0M4aZ+u5Jd2YH6sTgVwE0
[randomart, collapsible]
Compare with:  ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
[ Trust & Connect ]  (primary, accent)
[ Connect Once ]     (secondary)
[ Cancel ]
```
- The SSH handshake is held open while this sheet is shown (up to 120 s, then it times out).
- Trusting writes a `KnownHost` record that **syncs to every device**.
- Settings › Security › "Strict host checking" (off by default) refuses unknown hosts unless they were imported.

**Host key CHANGED**: a **full-screen danger takeover**. It cannot be swiped away, and it has a red background tint at 12%.
```
⚠  HOST KEY HAS CHANGED
prod-api-01  (10.0.1.12:22)

Someone could be intercepting this connection (man-in-the-middle),
or the server was reinstalled / its keys were rotated.
No credentials were sent.

Expected  ED25519  SHA256:4f+HqTn1dQ…Vw0   first trusted 2026-03-14 on MacBook-Pro
Received  ED25519  SHA256:Zk81Lr0aP2…mQ9

[ Disconnect ]                           (primary, full width)
[ Hold to trust new key ]                (destructive outline, 1.5 s press-and-hold)
Copy both fingerprints · How to verify
```
- The connection is **aborted at key exchange**, before any user auth, so no password or signature ever reaches the impostor.
- Trusting the new key replaces the pin, records `replacedAt` and the old fingerprint in `KnownHost.history`, and reconnects.

### 4.7 Settings

Grouped list. Each sub-page is a self-contained view owned by one workstream (§10).

| Section | Items |
|---|---|
| **Appearance** | Theme (Night/Day/HC) · App appearance (Dark default / System / Light) · Font (SF Mono / JetBrains Mono NF / Menlo) · Font size · Cursor (block/bar/underline, blink) · Bell (haptic / visual / off) |
| **Keyboard** | Key bar editor (§5.5) · Haptics · Option as Meta (Mac, HW keyboard) · ⌘. sends Esc · With hardware keyboard: Slim strip / Hide |
| **Terminal** | Scrollback lines (10 000 default, max 100 000) · Confirm multi-line paste (Prod only / Always / Never) · Copy on select (Mac) · TERM default · Keep-alive default |
| **Connections** | Default username · Default key · Connect timeout (15 s) · Auto-reconnect (on) · Probe reachability (on; cellular off) |
| **Security** | App Lock with Face ID / Touch ID / Optic ID (off; off/immediately/1 min/5 min/15 min) · Hide content in app switcher (on) · Strict host checking · Allow legacy ssh-rsa (SHA-1) signatures (off) · Clear clipboard after copying a secret (60 s) · Known Hosts › list |
| **Sync** | iCloud status (Account ✓ · Last sync 2 min ago · 42 servers, 5 keys) · Sync on/off · "Secrets waiting for iCloud Keychain: 0" · Reset local data |
| **Data** | Import ~/.ssh/config (Mac; iOS via Files) · Import known_hosts · Export servers (JSON, no secrets) |
| **About** | Version · GitHub · Report a bug · Acknowledgements (NOTICE) · Privacy ("Tilde collects nothing") |

### 4.8 Onboarding & empty states

- **First launch:** one screen, no carousel. The icon, then *"Tilde. SSH for people who get paged."*, then three buttons:
  1. **Add a server** (primary).
  2. **Import ~/.ssh/config** (Mac) / **Import from Files** (iOS).
  3. **Generate an SSH key**.
  Below them: *"Servers sync with iCloud. Secrets stay in iCloud Keychain."*
- If iCloud is unavailable, show an inline banner: *"iCloud is off. Servers will stay on this device."* with `[Settings]`.
- **Empty server list:** a mono illustration `~ $ _`, the line *"No servers yet."* and buttons [Add server] [Quick connect]. The Quick Connect field stays active.
- **Empty keys:** *"No keys. Ed25519 takes 50 ms to generate."* with [Generate].
- **Empty snippets:** seeded with 8 editable examples (deduplicated by fixed UUIDs) such as `sudo journalctl -u <unit> -f --since "10 min ago"`, `kubectl get pods -A -o wide`, `df -h && free -m`, `ss -tulpn`, `docker ps --format 'table {{.Names}}\t{{.Status}}'`, `tail -f /var/log/syslog`, `systemctl status <unit>`, `htop`.
- **Waiting for secrets:** a server synced but its password or key hasn't arrived from iCloud Keychain yet. The row shows a clock glyph, and Connect offers *"Waiting for iCloud Keychain. Enter password for this session"*.

### 4.9 Error states

All errors appear **inline in the session tab** (a banner over the dimmed terminal), with a short headline, a mono detail line, and 1–3 actions.

| Error | Headline / detail | Actions |
|---|---|---|
| DNS | `Can't resolve prod-api-01.internal` · *"Check VPN or DNS."* | Retry · Edit server |
| Refused | `Connection refused · 10.0.1.12:22` · *"sshd not running or wrong port."* | Retry · Edit |
| Timeout | `No response after 15s · 10.0.1.12:22` · *"Firewall / security group / VPN?"* | Retry · Edit |
| Auth failed (key) | `Permission denied (publickey)` · *"Key macbook-ed25519 was rejected. Server accepts: publickey."* | Copy public key · Install key… · Edit |
| Auth failed (password) | `Permission denied (password)` | Try again (re-prompt, with "update saved password") |
| Auth methods mismatch | `Server only allows keyboard-interactive` · *"2FA/PAM prompts arrive in v1.1."* | Learn more |
| Host key changed | full screen (§4.6) | |
| Algorithm mismatch | `No common algorithm (kex)` · *"Server offers: diffie-hellman-group1-sha1"* | Copy details |
| Secret missing | `Password not on this device yet` | Enter once · Open Settings › Sync |
| Network lost | reconnect banner (§4.5) | Now · Close |

---

## 5. The SSH key bar (iOS / iPadOS)

### 5.1 Why

On the iOS keyboard, `| ~ \ { } [ ] < > ^ _ \`` need two taps (123 → #+=) and Esc, Ctrl, Tab, arrows and F-keys don't exist at all. The key bar brings every one of these within **one tap or one flick**, keeps the modifiers in fixed positions for muscle memory, and stays one row high (46 pt) so it doesn't steal terminal lines.

### 5.2 iPhone layout (default "DevOps" profile)

```
┌──────┬──────┬──────┬──────────────────────────────────────────┬──────┐
│ esc  │ ctrl │ alt  │  tab   /    -    |    ~    ⚡            │  ✣   │
│      │      │      │  ⇤     \    _    &    `                  │      │  ← flick-up alternates (small, top-right of key)
└──────┴──────┴──────┴──────────────── • ○ ○ ○ ─────────────────┴──────┘
  pinned modifiers           paged area (6 keys/page)              pinned arrow joystick
```

| Page | Keys (primary / flick-up) |
|---|---|
| **1 Core** | `tab/⇤(shift-tab)` · `/ \` · `- _` · `\| &` · `~ \`` · `⚡ snippets` |
| **2 Brackets** | `{ }` · `[ ]` · `< >` · `( )` · `" '` · `= +` |
| **3 Shell** | `$ #` · `* ^` · `: ;` · `! ?` · `@ %` · `^C` (one-tap Ctrl-C) |
| **4 Nav** | `home` · `end` · `pgup` · `pgdn` · `del` · `⌫word` (Ctrl-W) |
| **5 F-keys** | `F1/F7` · `F2/F8` · `F3/F9` · `F4/F10` · `F5/F11` · `F6/F12` |

Geometry (iPhone 6.3", 402 pt width): 10 visible keys, each 36×38 pt, 3 pt gaps, 4 pt side insets. Keys are `surface2` with a 6 pt radius, labels in SF Mono 14 medium, and alternates in SF Mono 9 `text3` at the top right. The pinned keys are separated from the paged area by 6 pt gutters. Page dots (4 pt) sit under the paged area.

### 5.3 Behaviour

**Modifiers (Ctrl, Alt; Shift is available as an optional key)**
- **Tap → one-shot.** The key gets an accent outline plus an `accentSoft` fill, and the HUD chip `CTRL` appears. The next key from *any* source (system keyboard or key bar) is combined, then the modifier disarms.
- **Double-tap (< 300 ms) → lock.** Solid accent fill, a small lock glyph, and the HUD shows `CTRL 🔒`. Tap once to unlock.
- **Long-press Ctrl (400 ms) → combo popover:** `^C ^D ^Z ^R ^L ^A ^E ^W ^U ^K ^B` in a 4×3 grid. Slide to select and release to send, as with the iOS long-press accent picker.
- **Ctrl mapping:** letters become the control character (`a`→0x01). `@ [ \ ] ^ _ ?` follow xterm (`^[`=Esc, `^?`=DEL). Ctrl+digit follows xterm too (`^2`=NUL…). Ctrl+arrow sends `\e[1;5A`.
- **Alt/Meta:** sends an ESC prefix (`\e` + key), the convention for bash/zsh/emacs. Alt+arrow sends `\e[1;3A`.
- Modifiers combine (Ctrl+Alt). Arming both shows `CTRL+ALT`.

**Other keys**
- **Esc**: a single tap sends `\e`, with no delay or long-press ambiguity because vim users hammer it.
- **Flick up** on any key with a printed alternate sends the alternate, with a haptic tick. Long-press on a key with an alternate also shows both in a popover, for discoverability.
- **Arrow joystick ✣:**
  - *Drag* from the key in any direction. After 8 pt it sends that arrow, and holding repeats it. The repeat rate scales with distance: 8–28 pt gives 8 Hz, 28–60 pt gives 20 Hz, and more than 60 pt gives 40 Hz. Diagonal drags snap to the dominant axis. Every arrow sent gives a light haptic tick, and an arrow glyph appears in a bubble above the key.
  - *Tap* toggles **arrow page**: the paged area becomes `← ↓ ↑ → home end` until the next tap on ✣ or a swipe.
  - Arrows respect DECCKM (application cursor mode, `\eOA` vs `\e[A`). SwiftTerm exposes the mode.
- **⚡ Snippets** opens a compact palette above the bar: fuzzy search plus favorites. Tap inserts the snippet, and **⌥-variant (flick-up)** inserts and sends Return. Snippets with `<placeholders>` prompt for values first.
- **Repeat:** keys auto-repeat after 400 ms at 15 Hz. The exceptions are modifiers, ⚡ and page keys.
- **Paging:** swipe horizontally on the paged area. Pinned keys never move.
- **Haptics:** light impact on key-down. Settings can turn them off.
- **Accessibility:** every key has a VoiceOver label ("Control, one-shot"), and states are announced. Supports Larger Text, where the key bar grows to two rows instead of shrinking labels.

### 5.4 iPad layout

- **Software keyboard visible:** a **single wide row** (52 pt) with every page flattened in, plus an inline inverted-T arrow cluster. Left to right: `esc ctrl alt tab │ / - | ~ \ _ { } [ ] < > $ * : ' " │ ⚡ │ F1…F12 (scrolls) │ ← ↑ ↓ →`.
- **Hardware keyboard attached** (detected via `GCKeyboard.coalesced` and the keyboard frame height): the system keyboard is gone. The key bar becomes a **slim strip** (32 pt) of `esc · F1–F12 · ⚡ · ⌃lock · ⌄`, or hides completely, based on Settings › Keyboard › "With hardware keyboard". The strip also collapses into the iPadOS shortcuts bar (`inputAssistantItem`) when the user uses the floating keyboard.
- **Hardware keyboard handling:**
  - `pressesBegan` → SwiftTerm, with Ctrl and arrows native.
  - **Option as Meta** (default on).
  - **⌘. = Esc**, because the Magic Keyboard for iPad lacks Esc. A one-time tip suggests remapping Caps Lock → Escape in iPadOS Settings › Keyboards › Hardware Keyboard › Modifier Keys.
  - All app shortcuts use ⌘ only, so Ctrl-combos always reach the shell.

### 5.5 Customization

- Open Settings › Keyboard › **Key bar**, or long-press the page dots.
- The editor shows a live preview of the bar, then **Pages** (reorder, add, delete; 1–8 pages), each with 6 slots.
- Tap a slot to open the **key catalog**:
  - Every printable ASCII character.
  - Esc, Tab, Shift-Tab, Enter, Backspace, Del, Home/End/PgUp/PgDn/Ins, F1–F24, arrows.
  - Ctrl-combos (`^C` etc.).
  - Modifiers.
  - "Send text…" (a literal string, e.g. `| grep -i `).
  - Any **snippet**.
  - **tmux prefix** (sends the configured prefix, default `^B`).
  - Paste, Hide keyboard.
- Each slot has an optional flick-up alternate.
- The **pinned** zone can show or hide Alt (Esc and Ctrl are always pinned).
- **Presets:** DevOps (default), Vim, tmux, Emacs, Kubernetes (`kubectl`, `-n`, `-o wide`, `--all-namespaces`, `| grep`, `logs -f`), Minimal.
- Layouts are stored as versioned JSON `KeyBarLayout v1` in `NSUbiquitousKeyValueStore`, so they sync across devices (iPhone and iPad keep separate layouts because the widths differ). Export and import uses a `.tildekeys` JSON file. Per-server layouts come in v1.1.

---

## 6. Data model

### 6.1 SwiftData schema (`SchemaV1`, CloudKit-mirrored)

The CloudKit rules shape this schema:
- Every attribute is optional or has a default.
- There is **no `@Attribute(.unique)`**.
- Every relationship is optional and has an inverse.
- There are no ordered relationships, so a fractional `sortIndex: Double` is used instead.
- There is no `.deny` delete rule.
- Schema changes after the production CloudKit deploy must be **additive only** (new optional fields or entities). A `VersionedSchema` + `SchemaMigrationPlan` exists from day 1.

Every entity also carries `id: UUID = UUID()`, `createdAt: Date = .now` and `updatedAt: Date = .now`. These are not repeated in the tables below.

**`Server`**
| Field | Type | Default | Notes |
|---|---|---|---|
| name | String | "" | display name |
| host | String | "" | hostname / IP (stored trimmed, lowercased for matching) |
| port | Int | 22 | |
| username | String | "" | |
| authMethodRaw | String | "key" | `key` / `password` / `passwordPrompt` |
| key | SSHKeyRecord? | nil | relationship (nullify) |
| passwordSecretID | UUID? | nil | → Keychain `pw:<uuid>`; nil when prompting |
| environmentRaw | String | "none" | `none/dev/staging/prod/lab` |
| group | ServerGroup? | nil | relationship (nullify) |
| tags | [Tag]? | [] | many-to-many |
| jumpServer | Server? | nil | ProxyJump (one hop at MVP) |
| jumpedBy | [Server]? | [] | inverse of jumpServer |
| isFavorite | Bool | false | |
| sortIndex | Double | 0 | fractional ordering within group |
| startupCommand | String? | nil | |
| autoTmux | Bool | false | |
| tmuxSessionName | String | "tilde" | |
| keepAliveSeconds | Int | 30 | 0 = off |
| termType | String | "xterm-256color" | |
| envVarsJSON | String? | nil | `{"LANG":"en_US.UTF-8"}` |
| notes | String? | nil | |
| lastConnectedAt | Date? | nil | drives "recent" (syncs) |
| importedFrom | String? | nil | e.g. `ssh_config:Host prod-*` |

**`ServerGroup`**: name, symbol (SF Symbol name, default `folder`), sortIndex, isCollapsed (Bool, synced intentionally), servers ([Server]?).

**`Tag`**: name (case-insensitive deduplication), colorHex (String?), servers ([Server]?).

**`SSHKeyRecord`**: metadata only, **no private material**.
| Field | Type | Notes |
|---|---|---|
| name | String | `macbook-ed25519` |
| algorithmRaw | String | `ssh-ed25519`, `ecdsa-sha2-nistp256/384/521`, `ssh-rsa` |
| bits | Int? | RSA size |
| publicKeyOpenSSH | String | full `ssh-ed25519 AAAA… comment` line (public, safe to sync) |
| fingerprintSHA256 | String | `SHA256:…` |
| comment | String | |
| sourceRaw | String | `generated` / `imported` / `secureEnclave` (v1.1) |
| privateSecretID | UUID | → Keychain `key:<uuid>` |
| isSynchronizable | Bool | true = private key in iCloud Keychain; false = this-device-only |
| originDeviceName | String | for "this device only" keys, shown on other devices as "on MacBook Pro" |
| servers | [Server]? | inverse |

**`KnownHost`**
| Field | Type | Notes |
|---|---|---|
| endpoint | String | canonical `host` (port 22) or `[host]:port`, same as OpenSSH known_hosts |
| algorithm | String | `ssh-ed25519` … |
| publicKeyBase64 | String | raw key blob |
| fingerprintSHA256 | String | |
| firstSeenAt | Date | |
| lastSeenAt | Date | updated at most once a day to limit sync churn |
| trustedOnDevice | String | device name |
| statusRaw | String | `trusted` / `revoked` |
| historyJSON | String? | previous fingerprints + replacedAt |
| sourceRaw | String | `tofu` / `imported` / `manual` |

**`Snippet`**: name, command (String), folder (String?), isFavorite, sortIndex, runModeRaw (`insert` / `insertAndReturn`), scopeServer (Server?, nil = global), seedID (String?, used for deduplicating seeded examples).

**`RecentConnection`**: target string (`deploy@10.0.4.12:2222`), lastUsedAt, server (Server?). The list is capped at 10 per device, and pruning is done on read.

**Not in SwiftData:**
- *Preferences* (theme, font, key-bar layout) are in `NSUbiquitousKeyValueStore` (synced, 1 MB max), with `UserDefaults` for per-device values (font size, hardware-keyboard mode). The App Lock settings (lock on/off, timeout, hide content in the app switcher, strict host checking, clipboard clearing, legacy `ssh-rsa`) are **per-device `UserDefaults`**, not KVS: biometrics differ per device and nothing in them is sensitive.
- *Scrollback and session logs* are never persisted.

**Port forwards** (v1.1) will be added as an additive entity `PortForward` (server, kind L/R/D, bindHost, bindPort, targetHost, targetPort, autoStart).

### 6.2 Keychain scheme

| Attribute | Value |
|---|---|
| `kSecClass` | `kSecClassGenericPassword` |
| `kSecAttrService` | `app.tildessh.secret` |
| `kSecAttrAccount` | `<kind>:<uuid>`, where kind ∈ `pw` (server password), `key` (private key, OpenSSH format, unencrypted inside the Keychain), `kpp` (key passphrase, v1.1 "keep encrypted" mode) |
| `kSecAttrLabel` | human-readable: `Tilde: password for deploy@prod-api-01` (shown in the Passwords app) |
| `kSecAttrSynchronizable` | `true` (default) / `false` for "this device only" keys |
| `kSecAttrAccessible` | `kSecAttrAccessibleAfterFirstUnlock` (synced) / `…AfterFirstUnlockThisDeviceOnly` (local) |
| `kSecAttrAccessGroup` | `$(AppIdentifierPrefix)app.tildessh.shared` (shared by the iOS and macOS apps, and future extensions) |
| `kSecUseDataProtectionKeychain` | `true` on macOS (iOS-style keychain, required for sync) |
| `kSecValueData` | UTF-8 password / OpenSSH private key bytes |

Rules:
- Secrets are referenced **only by UUID** from SwiftData. No secret ever appears in a SwiftData field, a log, a crash report or the pasteboard (except an explicit "Copy password", which auto-clears after 60 s via `UIPasteboard` expiration / a Mac timer).
- The app deletes a Keychain item in the same user action that deletes its record. iCloud Keychain propagates the deletion. A manual **"Clean up orphaned secrets"** in Settings › Sync lists Keychain items with no referencing record that are older than 7 days. It never runs automatically, because sync ordering is not guaranteed.
- **Biometric-gated Keychain items cannot be synchronizable** (an Apple constraint). So biometric protection is an **app-level lock**, and "this device only + require Face ID per use" is a per-key option for high-value keys (v1.1, using `SecAccessControl .biometryCurrentSet`, together with Secure Enclave P-256 keys).

### 6.3 Sync behaviour & conflicts

- **Transport:**
  - SwiftData `ModelConfiguration(cloudKitDatabase: .private("iCloud.app.tildessh.Tilde"))`.
  - Silent push (remote notifications background mode) triggers imports.
  - Secrets sync independently through iCloud Keychain.
  - Display preferences sync through KVS. Per-device settings (App Lock, security) stay in `UserDefaults`.
- **Conflict policy:** the store merges with property-level "store trumps" locally and is effectively **last-writer-wins per record** across devices. Conflicts are minimized by design:
  - Records are small and independent. Tags and groups are separate records, so moving a server rarely conflicts with renaming one.
  - Ordering uses fractional `sortIndex`, so a reorder rewrites one record, not the whole list.
  - `lastSeenAt` and `lastConnectedAt` writes are throttled.
- **Deduplication** (because there are no unique constraints). A `Deduplicator` runs on `NSPersistentStoreRemoteChange` and on launch, debounced 2 s:
  - `Tag`: same lowercased name. Keep the oldest `createdAt`, merge the relationships, delete the rest.
  - `ServerGroup`: same name and **both empty or same members**. Otherwise keep both (they are legitimately different groups).
  - `KnownHost`: same `endpoint` + `algorithm` + `publicKeyBase64`. Keep the oldest.
    - Same endpoint and algorithm but a **different key** is a **conflict**. Both are marked `conflicted`, and the next connection to that host shows the host-key-changed screen listing both candidates. It never auto-resolves.
  - `Snippet` seeds: same `seedID`.
  - `Server`: **never auto-deduplicated** (two servers with identical host and user can be intentional, for example different keys). The UI flags exact duplicates with a "Duplicate?" hint.
- **Ordering lag:** a `Server` may arrive before its Keychain secret, or the other way round.
  - The UI handles a missing secret gracefully: it shows the "waiting for iCloud Keychain" state (§4.8).
  - Orphan secrets are harmless.
- **Offline-first:** everything works with no network or iCloud. With iCloud signed out, the store runs local-only, and data migrates to the cloud store when the user signs in (via `CKAccountChanged` → prompt).
- **CloudKit schema:** initialize the dev schema with `try container.initializeCloudKitSchema()` in a DEBUG-only path, then **deploy to Production in the CloudKit Console before every release that adds fields** (this goes on the WS6 release checklist).

### 6.4 Security model

| Threat | Mitigation |
|---|---|
| iCloud metadata exposure (hostnames, usernames) | CloudKit private DB, encrypted at rest by Apple, and end-to-end with Advanced Data Protection. The UI copy is honest: *"Server names and hosts sync with iCloud; passwords and keys sync end-to-end encrypted via iCloud Keychain."* A "Don't sync this server" flag is on the roadmap. |
| Secret theft from sync data | Secrets are never in CloudKit, only in iCloud Keychain (always E2E encrypted). |
| MITM | Strict TOFU. A mismatch aborts at kex before auth. Pins sync across devices, so the first trust on any device protects all of them. Imported `known_hosts` is supported. |
| Shoulder surfing / lost unlocked phone | Optional app lock (LocalAuthentication `.deviceOwnerAuthentication`; biometrics with passcode fallback). Lock timeout options. Privacy cover in the app switcher. Live sessions **stay connected** while locked, and the terminal is covered. |
| Pasting into prod by accident | Multi-line paste confirmation, plus red PROD stripes and badges. |
| Malicious escape sequences | SwiftTerm's OSC 52 clipboard write is **disabled by default** (opt-in per server). Title-change sequences are limited to 128 chars. Hyperlinks (OSC 8) show their URL before opening. |
| Logs | `os.Logger` with `privacy: .private` for hosts and users, and never logs secrets or key material. |
| Memory | Decrypted key bytes are kept only for the duration of auth, then zeroed where the type allows (`Data` → `withUnsafeMutableBytes` memset). |
| Supply chain | Every dependency is pinned (`Package.resolved` committed, exact revisions for forks). Renovate PRs are reviewed by a human, and CI checks `swift package show-dependencies` against an allowlist. |
| Crypto choices | Generated keys are Ed25519 by default, with RSA-4096 only on request. The DSA/ssh-dss algorithm is disabled. No SHA-1 signatures for RSA client auth (see Risks). |

---

## 7. Tech stack

### 7.1 Platforms & tooling

- **Deployment targets: iOS 26.0 / iPadOS 26.0 / macOS 26.0.** The current OS generation is 27, so this is N-1, which by late 2026 covers the overwhelming majority of active devices. The reasons for not choosing 18/15:
  - The Liquid Glass design language and APIs (`glassEffect`, `tabViewBottomAccessory`, new toolbar behaviours) are native, so no `#available` forks are needed in chrome code.
  - The iPadOS 26 windowing and menu bar mean iPad and Mac can share `.commands`.
  - SwiftData's 26-era improvements (model inheritance, CloudKit sync fixes) reduce sync bugs.
  - `Observation` and Swift 6 concurrency are mature on these OSes.
  - Dropping 18 costs very few users, and the team is small.
- **Swift 6.4, language mode 6, strict concurrency complete.** Citadel and NIO types are isolated behind an `actor` and imported with `@preconcurrency` where needed.
- **Project:** a **single Xcode project** with two app targets (`Tilde-iOS` for iPhone and iPad, and `Tilde-macOS` native, not Catalyst). All logic lives in **one local Swift package, `TildeKit`, with seven library targets**.
  - **No XcodeGen/Tuist.** Xcode 16+ folder-synchronized groups make `project.pbxproj` merge conflicts rare. Nearly all code lives in the package, where `Package.swift` is plain text. This also lets `swift test` run model, parsing and engine tests headless in CI. Revisit Tuist only if the number of targets grows past ~10.
- Two app targets (rather than one multi-destination target) because the macOS app needs a distinct sandbox entitlement set, menu bar extras later, and different Info.plist keys. They share 100% of the Swift code through TildeKit.

### 7.2 Dependencies

| Package | Version (pin) | License | Use |
|---|---|---|---|
| [Citadel](https://github.com/orlandos-nl/Citadel) | exact commit (≥ `ae8562f`, 2026-04) | MIT | SSH client: auth, PTY, exec, `jump(to:)`, DirectTCPIP, remote forward, SFTP (later) |
| swift-nio-ssh (Citadel's fork, currently `Wellz26/swift-nio-ssh 0.3.x`) | exact | Apache-2.0 | SSH transport, via Citadel |
| swift-nio, swift-crypto, swift-log, swift-collections | via Citadel | Apache-2.0 | |
| BigInt (attaswift), ColorizeSwift | via Citadel | MIT | RSA math; console colors (dead weight, harmless) |
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | 2.x exact | MIT | VT100/xterm emulator + UIKit/AppKit views |
| JetBrains Mono Nerd Font Mono (font files) | 3.x | OFL-1.1 | optional terminal font |
| Apple: SwiftUI, SwiftData, CloudKit, CryptoKit, Security, LocalAuthentication, Network, GameController, UniformTypeIdentifiers | OS | — | |

**Verified in Citadel's source (commit `ae8562f`):**
- `SSHAuthenticationMethod.passwordBased`, `.ed25519`, `.p256`, `.p384`, `.p521`, `.rsa`, `.custom(NIOSSHClientUserAuthenticationDelegate)`.
- `withPTY` with a `TTYStdinWriter.changeSize(cols:rows:pixelWidth:pixelHeight:)` (window-change).
- `SSHHostKeyValidator.custom(NIOSSHClientServerAuthenticationDelegate)` for TOFU.
- `SSHClient.jump(to:)` and `createDirectTCPIPChannel`.
- OpenSSH private-key parsing for **Ed25519 and RSA, including bcrypt-encrypted keys** (`init(sshEd25519:decryptionKey:)`, `init(sshRsa:decryptionKey:)`), plus key-type detection for ECDSA P-256/384/521.

**Gaps we fill ourselves** (WS3/WS2):
1. **ECDSA OpenSSH/PEM private-key parsing.** CryptoKit `P256/P384/P521.Signing.PrivateKey(pemRepresentation:)` covers SEC1/PKCS#8, and we write a ~150-line OpenSSH container parser that reuses Citadel's bcrypt.
2. **RSA client signatures use SHA-1 (`ssh-rsa`) in Citadel.** OpenSSH ≥ 8.8 rejects these by default. We implement `rsa-sha2-512/256` in a custom `NIOSSHClientUserAuthenticationDelegate` and upstream the patch. Until it lands, RSA keys are labelled "may fail on OpenSSH 8.8+ servers". This is a week-1 spike for WS2.
3. **keyboard-interactive auth** (PAM/2FA) is not available, so it goes to v1.1, which needs an upstream contribution to the NIO SSH fork.
4. **OpenSSH-format key serialization** for generated keys (writing `openssh-key-v1`).

### 7.3 Package & folder structure

```
tilde-ssh/
├─ Tilde.xcodeproj
├─ App/
│  ├─ Shared/            TildeApp.swift (App, Scenes, .commands), AppEnvironment.swift (DI)
│  ├─ iOS/               Info.plist, Tilde-iOS.entitlements, SceneDelegate glue
│  ├─ macOS/             Info.plist, Tilde-macOS.entitlements, AppDelegate.swift
│  └─ Resources/         AppIcon.icon, Assets.xcassets, Fonts/, PrivacyInfo.xcprivacy, Localizable.xcstrings
├─ Packages/TildeKit/
│  ├─ Package.swift
│  ├─ Sources/
│  │  ├─ TildeCore/          value types + protocols (the contracts, §10.2). No dependencies.
│  │  ├─ TildeStore/         SwiftData @Model schema, migrations, repositories, Deduplicator, KVS prefs, seeding
│  │  ├─ TildeSecurity/      KeychainSecretStore, KeyService (gen/parse/serialize), AppLock, Fingerprints
│  │  ├─ TildeSSH/           CitadelSessionEngine, HostKeyValidator, RSA-SHA2 auth, Reconnector, ReachabilityProbe, QuickConnectParser, SSHConfigParser
│  │  ├─ TildeTerminal/      TerminalSurface (UIKit/AppKit reps), KeyBar, KeyBarLayout, InputMapper, Themes, HardwareKeyboard
│  │  ├─ TildeDesign/        tokens, fonts, components (EnvBadge, StatusDot, MonoField, Banner, HoldToConfirmButton)
│  │  └─ TildeFeatures/
│  │     ├─ Servers/         ServerList, ServerRow, ServerEditor, QuickConnectField, CommandPalette
│  │     ├─ Sessions/        SessionCoordinator, SessionDeck(iPhone), SessionContainer+TabStrip(iPad/Mac), banners, HostKeyPrompt views
│  │     ├─ Keys/            KeyList, KeyDetail, GenerateKeySheet, ImportKeyFlow, InstallKeyFlow
│  │     ├─ Snippets/        SnippetList, SnippetEditor, SnippetPalette
│  │     ├─ Settings/        SettingsRoot + section views
│  │     ├─ Onboarding/
│  │     └─ Mac/             MacCommands, SSHConfigImportView, SessionWindow
│  └─ Tests/                 TildeCoreTests, TildeStoreTests, TildeSecurityTests, TildeSSHTests (+ Docker sshd integration), TildeTerminalTests, TildeFeaturesTests (snapshot)
├─ docs/                     DESIGN.md, ARCHITECTURE.md (later), RELEASE.md
├─ design/                   icon.svg, mockups.html, screenshots/
├─ fastlane/ (optional)      metadata/en-US/{name,subtitle,keywords,description,promotional_text}.txt
├─ .github/                  workflows/ci.yml, ISSUE_TEMPLATE/, dependabot.yml
├─ LICENSE  NOTICE  TRADEMARKS.md  SECURITY.md  CONTRIBUTING.md  CODE_OF_CONDUCT.md  README.md
```

Module dependency graph (an arrow means "depends on"):
```
TildeFeatures → TildeTerminal, TildeSSH, TildeSecurity, TildeStore, TildeDesign, TildeCore
TildeTerminal → TildeDesign, TildeCore, SwiftTerm
TildeSSH      → TildeCore, Citadel
TildeSecurity → TildeCore, TildeDesign, CTildeBcrypt, Citadel(Crypto/BCrypt only)
TildeStore    → TildeCore
TildeDesign   → (none)
TildeCore     → (none)
```

### 7.4 Identifiers, entitlements & capabilities

Bundle prefix: **`app.tildessh`** (recommended: register `tildessh.app`; all values below live in a single `Config/Shared.xcconfig` so a fork changes one file).

| Item | Value |
|---|---|
| Bundle IDs | `app.tildessh.Tilde` (iOS/iPadOS), `app.tildessh.Tilde.mac` (macOS). Or one ID with universal purchase, which is **recommended**: `app.tildessh.Tilde` for both, giving a single App Store listing and shared reviews |
| CloudKit container | `iCloud.app.tildessh.Tilde` |
| Keychain access group | `$(AppIdentifierPrefix)app.tildessh.shared` |
| KVS identifier | `$(TeamIdentifierPrefix)app.tildessh.Tilde` |

**Entitlements (both targets):** `com.apple.developer.icloud-services = [CloudKit]`, `com.apple.developer.icloud-container-identifiers = [iCloud.app.tildessh.Tilde]`, `com.apple.developer.ubiquity-kvstore-identifier`, `keychain-access-groups`, `aps-environment` (CloudKit silent push).
**iOS only:** Background Modes → *Remote notifications*. (No "audio"/"location" background abuse, which App Review rejects.)
**macOS only:** `com.apple.security.app-sandbox`, `com.apple.security.network.client` (**required for outbound SSH**), `com.apple.security.files.user-selected.read-only` (import keys, `~/.ssh/config`), `com.apple.security.files.bookmarks.app-scope` (v1.1 "watch ~/.ssh/config").
**Info.plist:** `NSFaceIDUsageDescription` ("Unlock Tilde and your saved servers."), `NSLocalNetworkUsageDescription` ("Tilde connects to servers on your local network over SSH."; **required on iOS and macOS 15+ for LAN/homelab hosts**), `CFBundleURLTypes` for the **`ssh://`** scheme (open `ssh://user@host:port` links) and `tilde://`, `UTImportedTypeDeclarations` for `.pub` / OpenSSH keys, `ITSAppUsesNonExemptEncryption = YES` plus the export-compliance answers (standard algorithms, open source; WS6 confirms the classification).
**Privacy manifest:** no tracking domains, no collected data. Required-reason APIs: `UserDefaults` (CA92.1) and file timestamps if used (C617.1).

---

## 8. MVP scope vs roadmap

### MVP (v1.0)
- Server CRUD, groups, tags, environments, favorites, search, fractional reordering
- Quick Connect (parser, recents, save-as-server), `ssh://` URL handler
- Auth: password (stored or prompt), Ed25519 / ECDSA keys, RSA keys (with the SHA-2 signing fix)
- Key manager: generate Ed25519 (and ECDSA/RSA), import OpenSSH/PEM incl. encrypted, copy/share public key, install key on server, export private key
- Terminal: SwiftTerm, xterm-256color, truecolor, resize, scrollback, select/copy/paste, find (iPad/Mac), pinch/⌘± font, 3 themes, bundled Nerd Font
- **Key bar** with sticky/locked modifiers, Ctrl combos, flick alternates, arrow joystick, pages, presets and editor. Hardware keyboard: Option-as-Meta, ⌘.=Esc, slim strip
- Multiple sessions: iPhone SessionDeck, iPad/Mac tab strip, ⌘ shortcuts, command palette, multi-window on iPad and Mac
- Host key TOFU, the changed-key takeover, a known hosts list, synced pins, `known_hosts` import
- iCloud sync (SwiftData + CloudKit), iCloud Keychain secrets, KVS prefs, deduplication
- App lock (Face ID / Touch ID / Optic ID), privacy cover, clipboard expiry
- Snippets: list, palette, placeholders, insert/run, seeded examples
- Reachability dot + latency, auto-reconnect with backoff, auto-tmux attach
- **Jump host (single hop)**: bastions are the norm in DevOps, and Citadel's `jump(to:)` makes it cheap
- Mac: sidebar, tab strip, full menu set, Settings scene, `~/.ssh/config` import (Host, HostName, User, Port, IdentityFile → key import prompt, ProxyJump single hop)
- Multi-line paste guard, PROD color system

### v1.1
Split panes (iPad/Mac) · local/remote/dynamic (SOCKS) port forwarding · keyboard-interactive / 2FA · agent forwarding · Secure Enclave P-256 keys + per-key Face ID · passphrase-kept-encrypted mode · SFTP file browser (Citadel SFTP) · iTerm2 theme import · per-server key-bar layouts · App Intents / Shortcuts ("Connect to…", "Run snippet on…") + Spotlight · MenuBarExtra quick connect (Mac) · "don't sync this server" · hashed known_hosts lookup.

### v1.2+
Mosh (needs a C/Swift Mosh client; licensing check: mosh is GPLv3, so a clean-room or separate-process approach would be needed, possibly a blocker) · multi-hop ProxyJump chains · OpenSSH certificates · FIDO2 `sk-ssh-ed25519` (YubiKey via NFC/USB-C) · team/shared vaults (CloudKit shared DB) · visionOS · session recording (asciinema, local only) · Live Activity for long-running commands · localization.

---

## 9. Testing strategy (brief)

- **Unit** (`swift test`, CI on macOS runner): QuickConnectParser, SSHConfigParser, KeyBar input mapping (byte-exact sequences per mode), OpenSSH key codec round-trips (fixtures generated by `ssh-keygen`), fingerprints, Deduplicator, migration plan.
- **Integration:** GitHub Actions service container `linuxserver/openssh-server` with password, ed25519, ecdsa and rsa users, and a second container as a bastion. Tests cover auth matrix × jump host × host key change (rotate keys between runs).
- **UI:** snapshot tests of design components and key screens in dark and light, at iPhone and iPad sizes. Manual 3am checklist: one-handed, low brightness, LTE, a hardware keyboard.
- **Sync:** two simulators on the same iCloud dev account, scripted edits, assert convergence and deduplication.

---

## 10. Work breakdown for parallel implementation

### 10.1 Phasing

- **Phase 0, the contract freeze (1 engineer, ~2 days, must merge before fan-out).** Create the Xcode project, the two app targets, the `TildeKit` package with **empty targets**, `TildeCore` contracts (§10.2) exactly as written, the `TildeStore` `@Model` schema v1 (§6.1), `TildeDesign` tokens, fixtures/mocks (`PreviewServers`, `EchoTerminalSession`, `InMemorySecretStore`, `FakeSessionEngine`), CI skeleton, and the entitlements.
- **Phase 1, parallel (6 workstreams, ~3–4 weeks).** Each workstream codes only against TildeCore protocols and uses the mocks for everything it doesn't own.
- **Phase 2, integration (~1 week).** WS5 wires real implementations in `AppEnvironment`. Then bug bash and TestFlight.

**Rules for avoiding collisions:**
1. Each workstream owns **directories**, not files scattered around.
2. Changing anything in `TildeCore/Contracts/` or `TildeStore/Schema/` needs a PR approved by WS1 and every consuming workstream.
3. Only WS5 edits `App/Shared/TildeApp.swift` and `AppEnvironment.swift`.
4. Only WS6 edits `*.entitlements`, `Info.plist`, `project.pbxproj` (after Phase 0) and `.github/`.
5. Each workstream adds its own test target folder.

### 10.2 Shared interface contracts (`TildeCore/Contracts/`, frozen in Phase 0)

```swift
// MARK: Value types (Sendable snapshots that cross actor/module boundaries; never @Model)
public enum ServerEnvironment: String, Codable, Sendable, CaseIterable { case none, dev, staging, prod, lab }
public enum AuthMethod: String, Codable, Sendable { case key, password, passwordPrompt }

public struct ConnectionTarget: Hashable, Sendable {           // from QuickConnect or a Server
    public var host: String; public var port: Int; public var username: String
}
public struct ServerSnapshot: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String, target: ConnectionTarget, auth: AuthMethod
    public var keyID: UUID?, passwordSecretID: UUID?
    public var environment: ServerEnvironment
    public var jump: JumpSnapshot?                             // one hop at MVP
    public var startupCommand: String?, autoTmux: Bool, tmuxSessionName: String
    public var keepAliveSeconds: Int, termType: String, envVars: [String: String]
}
public struct JumpSnapshot: Hashable, Sendable { public var target: ConnectionTarget; public var auth: AuthMethod; public var keyID: UUID?; public var passwordSecretID: UUID? }

// MARK: Secrets (implemented by WS3: KeychainSecretStore; mock: InMemorySecretStore)
public enum SecretKind: String, Sendable { case password = "pw", privateKey = "key", keyPassphrase = "kpp" }
public struct SecretRef: Hashable, Sendable { public let kind: SecretKind; public let id: UUID }
public protocol SecretStore: Sendable {
    func write(_ data: Data, for ref: SecretRef, label: String, synchronizable: Bool) throws
    func read(_ ref: SecretRef) throws -> Data?            // nil = not (yet) on this device
    func delete(_ ref: SecretRef) throws
    func allRefs() throws -> [SecretRef]
}

// MARK: Keys (WS3)
public enum SSHKeyAlgorithm: String, Codable, Sendable { case ed25519 = "ssh-ed25519", ecdsaP256 = "ecdsa-sha2-nistp256", ecdsaP384 = "ecdsa-sha2-nistp384", ecdsaP521 = "ecdsa-sha2-nistp521", rsa = "ssh-rsa" }
public struct PublicKeyInfo: Hashable, Sendable { public var algorithm: SSHKeyAlgorithm; public var bits: Int?; public var openSSH: String; public var fingerprintSHA256: String; public var comment: String }
public struct PrivateKeyMaterial: Sendable { public let algorithm: SSHKeyAlgorithm; public let openSSHBytes: Data } // unencrypted openssh-key-v1
public enum KeyParseError: Error, Sendable { case passphraseRequired, wrongPassphrase, unsupportedFormat(String), unsupportedAlgorithm(String) }
public protocol KeyService: Sendable {
    func generate(_ algorithm: SSHKeyAlgorithm, bits: Int?, comment: String) async throws -> (PublicKeyInfo, PrivateKeyMaterial)
    func parse(privateKey: Data, passphrase: String?) throws -> (PublicKeyInfo, PrivateKeyMaterial)
    func publicInfo(fromOpenSSHLine: String) throws -> PublicKeyInfo
    func fingerprintSHA256(publicKeyBlob: Data) -> String          // "SHA256:base64-no-pad"
}

// MARK: Host keys (store: WS1; validator: WS2; prompt UI: WS5)
public struct HostEndpoint: Hashable, Sendable { public var host: String; public var port: Int; public var canonical: String { port == 22 ? host.lowercased() : "[\(host.lowercased())]:\(port)" } }
public struct HostKey: Hashable, Sendable { public var algorithm: String; public var blobBase64: String; public var fingerprintSHA256: String }
public enum HostKeyLookup: Sendable { case trusted, unknown, mismatch(pinned: [PinnedHostKey]), conflicted(candidates: [PinnedHostKey]) }
public struct PinnedHostKey: Hashable, Sendable { public var key: HostKey; public var firstSeenAt: Date; public var trustedOnDevice: String }
public protocol KnownHostsStore: Sendable {
    func lookup(_ endpoint: HostEndpoint, presented: HostKey) async -> HostKeyLookup
    func trust(_ key: HostKey, for endpoint: HostEndpoint, replacing: Bool) async throws
    func touch(_ endpoint: HostEndpoint) async                       // throttled lastSeenAt
}
public struct HostKeyChallenge: Sendable, Identifiable { public let id: UUID; public let endpoint: HostEndpoint; public let serverName: String?; public let presented: HostKey; public let lookup: HostKeyLookup }
public enum HostKeyDecision: Sendable { case trustAndSave, connectOnce, reject }
@MainActor public protocol HostKeyPrompter: AnyObject {               // WS5 implements (sheet / takeover)
    func decide(_ challenge: HostKeyChallenge) async -> HostKeyDecision // mismatch: engine has already aborted; .trustAndSave → reconnect
}

// MARK: Credentials resolution (WS3 implements, WS2 consumes)
public enum ResolvedCredential: Sendable { case password(String), privateKey(PrivateKeyMaterial) }
@MainActor public protocol PasswordPrompter: AnyObject { func password(for target: ConnectionTarget, reason: PromptReason) async -> String? }
public enum PromptReason: Sendable { case notSaved, rejected, secretNotSynced }
public protocol CredentialResolver: Sendable {
    func resolve(auth: AuthMethod, keyID: UUID?, passwordSecretID: UUID?, target: ConnectionTarget) async throws -> ResolvedCredential
}

// MARK: Terminal I/O (WS2 implements via TerminalSession; WS4 consumes)
public protocol TerminalIO: AnyObject, Sendable {
    var output: AsyncStream<Data> { get }                // remote → screen bytes
    func send(_ bytes: Data)                             // keyboard → remote (non-blocking, ordered)
    func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int)
}

// MARK: Sessions (WS2 implements CitadelSessionEngine; mock FakeSessionEngine / EchoTerminalSession)
public struct PTYConfig: Sendable { public var term: String; public var cols: Int; public var rows: Int; public var env: [String: String] }
public struct SessionRequest: Sendable { public var server: ServerSnapshot; public var pty: PTYConfig; public var connectTimeout: Duration }
public struct ConnectionInfo: Equatable, Sendable { public var serverVersion: String; public var kex: String; public var cipher: String; public var authenticatedWith: String; public var latency: Duration? }
public enum SessionState: Equatable, Sendable {
    case idle, connecting(phase: ConnectPhase), connected(ConnectionInfo)
    case reconnecting(attempt: Int, retryAt: Date), disconnected(SessionEndReason)
}
public enum ConnectPhase: Equatable, Sendable { case resolving, tcp, jumpHost, handshake, hostKey, authenticating, openingShell }
public enum SessionEndReason: Equatable, Sendable { case exited(status: Int?), userClosed, error(SessionError) }
public enum SessionError: Error, Equatable, Sendable {
    case dnsFailure(host: String), refused, timeout(seconds: Int), networkLost
    case hostKeyMismatch(challengeID: UUID), hostKeyRejected
    case authFailed(method: String, serverAllows: [String]), secretUnavailable(SecretRef)
    case noCommonAlgorithm(kind: String, offered: [String]), channelFailed(String), underlying(String)
}
public protocol TerminalSession: TerminalIO {
    var id: UUID { get }
    var server: ServerSnapshot { get }
    var states: AsyncStream<SessionState> { get }        // replays current state on subscribe
    func connect() async
    func reconnect() async
    func disconnect() async
    func latency() async -> Duration?                    // keepalive round-trip
}
public protocol SessionEngine: Sendable {
    func makeSession(_ request: SessionRequest,
                     credentials: any CredentialResolver,
                     knownHosts: any KnownHostsStore,
                     hostKeyPrompter: any HostKeyPrompter,
                     passwordPrompter: any PasswordPrompter) -> any TerminalSession
    func test(_ request: SessionRequest, /* same deps */ credentials: any CredentialResolver, knownHosts: any KnownHostsStore, hostKeyPrompter: any HostKeyPrompter, passwordPrompter: any PasswordPrompter) async -> Result<ConnectionInfo, SessionError>
    func runCommand(_ command: String, on request: SessionRequest, credentials: any CredentialResolver, knownHosts: any KnownHostsStore) async throws -> (stdout: Data, exitStatus: Int)   // used by "Install key on server"
}

// MARK: Reachability (WS2)
public enum ProbeResult: Equatable, Sendable { case reachable(Duration), unreachable(reason: String), skipped }
public protocol ReachabilityProbe: Sendable { func probe(_ target: ConnectionTarget, timeout: Duration) async -> ProbeResult }

// MARK: Parsers (WS2)
public protocol QuickConnectParsing: Sendable { func parse(_ input: String) -> QuickConnectResult? }
public struct QuickConnectResult: Equatable, Sendable { public var target: ConnectionTarget; public var keyName: String?; public var jump: ConnectionTarget? }
public protocol SSHConfigParsing: Sendable { func parse(_ text: String) -> [SSHConfigHost] }
public struct SSHConfigHost: Equatable, Sendable { public var alias: String; public var hostName: String?; public var user: String?; public var port: Int?; public var identityFiles: [String]; public var proxyJump: String? }

// MARK: Key bar (WS4) ↔ snippets (WS1 data, WS5 palette)
public protocol SnippetProviding: Sendable { func snippets(matching query: String) async -> [SnippetSnapshot] }
public struct SnippetSnapshot: Identifiable, Hashable, Sendable { public let id: UUID; public var name: String; public var command: String; public var runOnInsert: Bool }

// MARK: App lock (WS3)
@MainActor public protocol AppLocking: AnyObject, Observable { var isLocked: Bool { get }; func unlock() async -> Bool; func lockNow() }
```

Public **SwiftUI entry points** that each workstream exports (composed by WS5):
- `TerminalSurface(io: any TerminalIO, theme: TerminalTheme, environment: ServerEnvironment, keyBar: KeyBarConfiguration, snippets: any SnippetProviding, onFontSizeChange:)` and `KeyBarEditorView()` (WS4).
- `KeyListView()`, `KeyPicker(selection: Binding<SSHKeyRecord?>)`, `GenerateKeySheet`, `SecuritySettingsSection()`, `AppLockGate<Content>` (WS3).
- `ServerList…`, `SessionContainer`, `SettingsRoot` (WS5).
- `MacCommands`, `SSHConfigImportView` (WS6).

### 10.3 Workstreams

| # | Workstream | Owns (directories/files) | Delivers | Depends on (via contracts) |
|---|---|---|---|---|
| **WS1** | **Core models & sync** | `TildeCore/**` (after Phase 0, as contract steward), `TildeStore/**`, `Tests/TildeCoreTests`, `Tests/TildeStoreTests` | `@Model` schema v1 + migration plan; `ModelContainer` factory (CloudKit + local fallback + in-memory for previews); `SwiftDataKnownHostsStore`; `Deduplicator`; `SnippetProviding` impl + seeds; `Preferences` (KVS + UserDefaults wrapper, `@Observable`); `ServerSnapshot(model:)` mappers; iCloud account status observer; JSON export of servers | none |
| **WS2** | **SSH session engine** | `TildeSSH/**`, `Tests/TildeSSHTests`, `ci/sshd/` (Docker fixtures) | `CitadelSessionEngine` + `CitadelTerminalSession` (actor; PTY, resize, keepalive, latency, exit status, env); TOFU `HostKeyValidator` (holds the handshake while prompting, aborts on mismatch); jump host; reconnect with backoff + tmux attach; **RSA-SHA2 auth delegate** (week-1 spike) + upstream PR; `NWConnection` `ReachabilityProbe`; `QuickConnectParser`; `SSHConfigParser`; `runCommand` | `CredentialResolver`, `KnownHostsStore`, prompters (mocks) |
| **WS3** | **Keys & security** | `TildeSecurity/**`, `TildeFeatures/Keys/**`, `TildeFeatures/Settings/SecuritySection*.swift`, `Tests/TildeSecurityTests` | `KeychainSecretStore`; `KeyService` (Ed25519/ECDSA via CryptoKit, RSA via `SecKey`; OpenSSH v1 + PEM/PKCS#8 parse/serialize, bcrypt-encrypted import; fingerprints + randomart); `DefaultCredentialResolver`; `AppLock` (LocalAuthentication, timeout, privacy cover); clipboard expiry; Key Manager UI (list/detail/generate/import/share/install/export) | `SessionEngine.runCommand` (mock) for "install key" |
| **WS4** | **Terminal & SSH keyboard** | `TildeTerminal/**`, `TildeFeatures/Settings/KeyboardSection*.swift`, `TildeFeatures/Settings/AppearanceSection*.swift`, `App/Resources/Fonts/`, `Tests/TildeTerminalTests` | `TerminalSurface` (SwiftTerm `TerminalView` wrappers for UIKit and AppKit; theming; font; selection/copy; find; pinch; OSC policy; multi-line paste guard hook; mouse reporting; DECCKM-aware arrows); **KeyBar** (UIKit `inputAccessoryView`, pages, sticky/lock modifiers, combo popover, flick alternates, joystick, haptics, VoiceOver); `InputMapper` (byte-exact sequences, unit tested); hardware keyboard handling (Option-as-Meta, ⌘.=Esc, slim strip, `GCKeyboard` detection); `KeyBarLayout` JSON + presets + editor; 3 themes | `TerminalIO` (use `EchoTerminalSession` / a local `LoopbackIO` running `vttest` captures), `SnippetProviding` |
| **WS5** | **App shell, servers & sessions UI** | `App/Shared/**`, `TildeFeatures/Servers/**`, `Sessions/**`, `Snippets/**`, `Onboarding/**`, `Settings/` (except sections owned by WS3/WS4), `TildeDesign/**`, `Tests/TildeFeaturesTests` | Per-platform navigation (iPhone TabView + SessionDeck + live accessory; iPad/Mac split view + tab strip); `SessionCoordinator` (`@Observable`, owns sessions/tabs, implements `HostKeyPrompter` & `PasswordPrompter`); server list/row/search/tags/groups/drag-reorder; Server editor + Test connection; Quick Connect + command palette; host-key sheet and **changed-key takeover**; session banners & error states; snippets UI; onboarding/empty states; Settings root; `AppEnvironment` DI wiring; design components | all contracts (mocks until Phase 2) |
| **WS6** | **Mac-specific, distribution & OSS** | `TildeFeatures/Mac/**`, `App/macOS/**`, `App/iOS/Info.plist`, `*.entitlements`, `PrivacyInfo.xcprivacy`, `App/Resources/AppIcon.icon`, `.github/**`, `fastlane/**`, `design/**`, root `*.md`, `LICENSE`, `NOTICE` | `MacCommands` (full menu set, wiring to `SessionCoordinator` via `FocusedValues`); session windows; `~/.ssh/config` + `known_hosts` import UI (NSOpenPanel, sandbox); `ssh://` URL handling glue; icon export (Icon Composer) + App Store screenshots; metadata files (§1.2); CI (build both platforms, `swift test`, Docker sshd integration job, SwiftLint/SwiftFormat); README/CONTRIBUTING/SECURITY/TRADEMARKS/NOTICE generation script; CloudKit production schema deploy checklist; export-compliance answers; trademark search | `SSHConfigParsing` (WS2), `KnownHostsStore` (WS1), `SessionCoordinator` focused values (WS5) |

**Critical path:** Phase 0 → WS2 RSA/ECDSA spike and WS4 KeyBar → WS5 integration. WS2 and WS4 are the riskiest and start immediately. WS1 can finish early and then help WS5 with the Settings/Sync screens.

### 10.4 Definition of done (each workstream)
- Builds for iOS and macOS with zero warnings in Swift 6 mode. Public API has doc comments.
- Unit tests green in CI, and a demo in the SwiftUI previews using mocks.
- No secrets in logs (a `grep` test runs in CI for `password`/`BEGIN OPENSSH` in log calls).
- Light and dark mode checked, Dynamic Type checked, VoiceOver labels on interactive controls.

---

## 11. Risks & assumptions

| # | Risk / assumption | Impact | Mitigation |
|---|---|---|---|
| R1 | **Citadel RSA auth signs with SHA-1 (`ssh-rsa`)**, which is rejected by default on OpenSSH ≥ 8.8 | RSA keys fail on modern servers | WS2 week-1: a custom auth delegate with `rsa-sha2-256/512` (RFC 8332), upstream PR; Ed25519 is the default anyway |
| R2 | Citadel depends on a **third-party fork of swift-nio-ssh** (`Wellz26/swift-nio-ssh`) | Supply-chain and maintenance risk | Pin exact revision; mirror the fork under our org; review diffs on bump |
| R3 | No **keyboard-interactive** auth (PAM/2FA/OTP) | Some corporate servers unusable at MVP | Clear error copy; v1.1 contribution |
| R4 | Algorithm coverage (no chacha20-poly1305; no legacy kex like group1-sha1) | Very old servers or network gear may fail | Clear "no common algorithm" error listing the server's offer; legacy kex deliberately unsupported |
| R5 | **iOS suspends sockets in background** | Sessions drop when the app is backgrounded for over ~30 s | Background task grace, instant auto-reconnect, auto-tmux attach; Mosh on the roadmap (GPL issue noted) |
| R6 | SwiftData + CloudKit limits (no unique constraints, additive-only schema, opaque sync errors) | Duplicates, migration pain | Deduplicator; versioned schema from day 1; Core Data `NSPersistentCloudKitContainer` fallback is possible on the same store |
| R7 | CloudKit and iCloud Keychain sync independently | A server can briefly lack its secret | "Waiting for iCloud Keychain" state + one-time password entry |
| R8 | Synced Keychain items can't be biometric-gated | Face ID is app-level only | Documented; device-only Secure Enclave keys in v1.1 |
| R9 | Swift 6 strict concurrency with NIO/Citadel types | Friction, `@unchecked Sendable` creep | Confine NIO to one actor per session; `@preconcurrency import`; review every `@unchecked` |
| R10 | SwiftTerm iOS ships its own accessory view and input handling | Our key bar must replace it cleanly | Assumption: `inputAccessoryView` is overridable and a send-bytes API exists (it does per the sample apps); WS4 spike day 1 |
| R11 | Name "Tilde" not legally cleared; "Tilda" (website builder) may share search results | Rename late is costly | WS6 trademark search before any public asset; fallbacks Vigil / Hostty |
| R12 | Export compliance (custom crypto via swift-crypto/Citadel) | Submission delay | Answer the App Store Connect questionnaire as standard algorithms + publicly available open source; confirm before the first TestFlight upload |
| R13 | Deployment target iOS/macOS 26 excludes 18/15 users | Smaller audience | Acceptable for a new app in late 2026; can be lowered to 18/15 with `#available` shims, at a cost of ~1 week |
| A1 | Assumes a paid Apple Developer account with iCloud/CloudKit enabled and the `tildessh.app` (or similar) domain for bundle IDs | | Changing it is a one-line xcconfig change |
| A2 | Universal purchase (single bundle ID across iOS and macOS) | One listing, shared ratings | |
