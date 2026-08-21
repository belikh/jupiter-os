# ZEUS — the jupiterOS design language

Status: DRAFT v0.9 for owner review · 2026-08-22
Namespace: `--ze-*` CSS custom properties · Applies to: Pegasus/QML kiosk themes,
Go `html/template` + plain-CSS web (arcade-webapp, suno-web), charm/bubbletea TUIs,
NixOS console tooling. **No React, no Svelte, no component frameworks — ever.**

---

## 1. Identity

Zeus is an **abstract instrument at full power** — a storm-console that is always
alive. It carries no narrative skin: no fictional corporation, no larp lore stamped
on chrome. The machine itself is the brand.

Its roots are three things the fleet already loves, fused into one ownable language:

- the **phosphor CRT soul** of our Fallout-terminal wallpanels (scanlines, bloom,
  flicker, mono-forward type),
- **charm-grade gloss** (springy motion, gradient accents, playful copy),
- and **Jupiter itself** — the loudest, stormiest thing in the sky. The mascot is a
  living lightning arc; the wordmark resolves out of static; the day theme is what
  the instrument writes down on paper.

Originality rule: Zeus is anchored in Jupiter and nothing else. If a screenshot of
any jupiterOS surface could be mistaken for Catppuccin, Fallout/RobCo, or any other
named theme, it has failed and must be reworked.

## 2. Principles

1. **Maximum distinctive.** Distinctiveness outranks comfort. A blind judge shown
   our surface next to any competitor must pick ours or we iterate. Safe-and-familiar
   is the one unrecoverable failure.
2. **Always alive.** Surfaces breathe even untouched: flicker, drift, churn, glow
   pulses. A static Zeus screen is a bug. Motion respects `prefers-reduced-motion`
   and power budgets (§9, §12).
3. **Machine outside, pizzazz inside.** Geometry is machined — 4px edges, hairlines,
   corner ticks. Voice and motion are charm-flavored — springy, glowing, witty.
   Corporate-clean beige minimalism is banned.
4. **Every phosphor earns its seat.** Multiple phosphors share each surface, but
   each hue performs exactly one semantic job. Decorative-only color is noise.
5. **Thumbs and d-pads are first-class.** Every interactive element is designed for
   a 15" touchscreen and a gamepad before a mouse. Hover is never load-bearing.
6. **Twin themes, equal citizens.** Night glass and day log are both fully
   maintained. Neither is a degraded inversion of the other.
7. **Tokens or it didn't happen.** Every visual decision ships as a `--ze-*` custom
   property (functional names). Hard-coded hexes in components are defects.

## 3. Palette — night glass (dark)

Base is a glossy blue-black void; five phosphors do semantic work inside it.

| Role | Token | Hex | Job |
|---|---|---|---|
| Canvas | `--ze-bg` | `#08090D` | page ground |
| Panel | `--ze-panel` | `#10131B` | cards, wells |
| Raised | `--ze-raised` | `#151926` | hover, focused, stacked layers |
| Line | `--ze-line` | `#222839` | hairline borders (default edge) |
| Line strong | `--ze-line-strong` | `#34405C` | emphasized edges, dividers |
| Foreground | `--ze-fg` | `#E2E8F4` | primary text |
| Secondary | `--ze-fg2` | `#AAB4CC` | body/supporting text |
| Muted | `--ze-muted` | `#697492` | labels, meta (≥12px only) |
| Phosphor green | `--ze-pos` | `#9CFF57` | healthy data, verified, success counts |
| Phosphor amber | `--ze-warn` | `#FFB642` | attention: stale, drift, caution |
| Phosphor blue | `--ze-info` | `#42B6FF` | information, links, cold readouts |
| Phosphor violet | `--ze-media` | `#C77DFF` | media, highlights, brand gradient |
| OK status | `--ze-ok` | `#57E389` | boolean-good states, locks |
| Alert | `--ze-alert` | `#FF5C47` | errors, now-problems |
| Storm rust | `--ze-storm` | `#C8502E` | brand accent, covers, vortex art |
| Storm deep | `--ze-storm-deep` | `#7E2C11` | gradient partner, pressed |

Wordmark/primary-action gradient (the only sanctioned multi-hue fill):
`linear-gradient(94deg, var(--ze-media), var(--ze-info) 42%, var(--ze-pos))`.

Glow is color's voice: any element tinted with a phosphor may add
`text-shadow: 0 0 14px <tone @ 50%>` or `box-shadow: 0 0 18px <tone @ 15–30%>`.
No glow without the matching tone already present in the element.

Contrast floors: body text ≥ 7:1, secondary ≥ 4.5:1, muted used only ≥ 12px and
never for actionable labels.

## 4. Palette — day log (light)

Day mode is the observatory's paper record: cream stock, ruled baselines, ink and
stamps — never a flat inverted dark theme.

| Role | Token | Hex | Job |
|---|---|---|---|
| Paper hi | `--ze-paper-hi` | `#EFE6CF` | page ground |
| Paper | `--ze-paper` | `#E9DFC4` | cards, wells |
| Rule | `--ze-rule` | `rgba(80,60,25,.16)` | ruled baselines, hairlines |
| Ink | `--ze-ink` | `#241C0E` | primary text |
| Ink secondary | `--ze-ink2` | `#57472C` | body/supporting text |
| Ink muted | `--ze-ink-mut` | `#8A6D34` | labels, meta |
| Rust ink | `--ze-rust` | `#7C3018` | anything that matters: alerts, key figures |
| Ochre stamp | `--ze-ochre` | `#A3762C` | verification stamps, meta chips |
| Pos on paper | `--ze-pos-d` | `#256B2A` | healthy data |
| Warn on paper | `--ze-warn-d` | `#8C5E00` | attention |
| Info on paper | `--ze-info-d` | `#1D5FA0` | information, links |
| Media on paper | `--ze-media-d` | `#7A3FB8` | media, highlights |
| Alert on paper | `--ze-alert-d` | `#B32318` | errors |

Light-theme texture swaps scanlines for ruled paper baselines
(`repeating-linear-gradient(180deg, transparent 0 27px, var(--ze-rule) 27px 28px)`).
Stamps replace glow: dashed 2px ochre/rust borders, slight rotation (-2°), uppercase
mono. No drop shadows heavier than `0 10px 26px rgba(60,42,16,.16)`.

## 5. Typography

Two families, strict lanes. TUIs inherit whatever the terminal provides and skip
this section entirely.

| Lane | Family | Usage |
|---|---|---|
| Display | **Space Grotesk** 500–800 | headings, wordmark, big UI labels |
| Data/body/UI | **JetBrains Mono** 400/700 | everything else: readouts, labels, body, buttons |

Rules:

- Display: tight tracking `-0.02em`, sentence case or ALL-CAPS for kickers only.
- Mono labels are UPPERCASE with `.22em–.32em` letter-spacing — this tracked-caps
  mono kicker is a Zeus fingerprint; use it on every section header.
- Numerals in telemetry are mono, large, bold, glowing their tone (34px+ for hero
  stats).
- Scale: `10 · 12 · 13 · 15 · 17 · 22 · 34 · 46 · 58`. Line-height 1.02–1.1 display,
  1.65 body, 1.75 TUI/terminal blocks.
- Fonts ship self-hosted woff2 from our own static dirs. No CDN fetches; kiosk
  surfaces must render correctly with zero network.

## 6. Spacing, radius, elevation

- **Space scale:** `4 · 8 · 12 · 16 · 24 · 32 · 44 · 64`. Section rhythm 44.
- **Radius: 4px everywhere.** Boxy is the verdict — cards, buttons, chips, inputs,
  modals all sit at `--ze-radius: 4px`. Pills exist only as meter tracks/progress.
- **Corner ticks** are the machined signature: 10×10px 1px strokes at two opposing
  corners of emphasized panels (top-left + bottom-right), tone-colored at ~70%
  opacity. Use on: focused/selected panels, modals, hero telemetry. Don't sprinkle
  on everything.
- **Depth comes from edges first, shadow second, glow third:**
  - e0: hairline border only (`--ze-line`)
  - e1: `0 8px 24px rgba(0,0,0,.35)`
  - e2: `0 22px 50px rgba(0,0,0,.5)`
  - e3: `0 30px 70px rgba(0,0,0,.55)`
  - glow-e: e1..e3 plus `0 0 24–34px <tone @ 20–28%>` for phosphor-tinted floats
    (active cards, modals, the focused item in a gamepad ring walk)

## 7. Texture & atmosphere (night glass)

Layered fixed overlays, cheapest first, all `pointer-events:none`:

1. **Scanlines** — `repeating-linear-gradient(0deg, rgba(255,255,255,.03) 0 1px, transparent 1px 3px)` over everything.
2. **Grain** — tiled SVG `feTurbulence` noise (~5% opacity, 140px tile).
3. **Vignette** — radial from transparent 58% to `rgba(0,0,0,.5)` at edges.
4. **Flicker** — opacity dips to ~0.93–0.96 for single frames a few times a minute.
   Never more often; never below 0.9; disabled entirely under reduced motion.
5. **Bloom** — text/box glows per §3, reserved for phosphor-tinted content.

Intensity tiers: **kiosk = full stack**, **web = scanlines + grain + vignette**
(flicker optional), **TUI = none** (a real terminal already has its own glass).

## 8. Motion

Always-alive ambient budget per visible view: ≤3 concurrent loops, compositor-safe
properties only (`transform`, `opacity`). Ambient loops pause when the view loses
focus and freeze completely under `prefers-reduced-motion: reduce`.

Signature moves:

- **Signal-resolve scramble** — glyphs (`▚▞░▒▓╱╲│─┼…`) resolve left-to-right into
  final text. Boot/wordmark ~900ms; view transitions 300–400ms (Tier B numbers).
  Must hard-lock against overlapping runs (double-tap nav is the dominant input);
  re-snapshotting mid-scramble corrupts text permanently — cancel-in-progress, then
  restart.
- **Spring** — interactions use `cubic-bezier(.34,1.56,.64,1)`: hover lift −5/−6px,
  press `scale(.97)`.
- **Durations:** fast 150ms · med 250ms · slow 400ms.
- **Ambient repertoire:** spark-bar breathing in telemetry cells, sprite idle pulse
  (§10), slow eye-drift on covers, occasional flicker. Nothing bounces endlessly;
  nothing blinks faster than 2Hz except the sprite's working strobe.

Forbidden: layout-thrashing animation (width/left/top), parallax, spinners that
block input during scramble, motion that conveys state the palette doesn't also
convey.

## 9. Touch & controller contract

Touchscreen (15" TCxWave-class panels):

- Primary controls ≥ **56×56px**, absolute floor 48×48 for dense secondary rows;
  gaps ≥ 12px.
- Tap feedback: ripple or brightness pop within 100ms. **Hover-dependent
  affordances are defects** — anything reachable on hover needs a tap/tap-hold path.
- Swipe/back gesture and persistent bottom nav on kiosk layouts; hit-slop extends
  to panel edges for edge-anchored controls.

Gamepad/d-pad:

- Focus is **always visible** even before first input: 3px ring in the active
  phosphor + glow-e shadow, offset 3px. Ring width scales up for pad input
  (RomM-style `data-input` switching is the precedent).
- Traversal order follows reading order; rows are focus islands; wrap-around at
  list edges. `(A)` select · `(B)` back · hold-to-repeat on steppers.
- Pressed state animates with the spring curve; focus never jumps scroll position
  unexpectedly.

## 10. The Sprite (mascot)

One mascot: **the Sprite** — a living lightning arc (Jovian lightning; "sprites" are
the real scientific name for upper-atmospheric discharges). It is energy, not a
character: no face, no limbs, no costume. Cute through motion, never chibi.

States (all surfaces implement all four):

| State | Behavior |
|---|---|
| Idle | slow breathing glow, gentle drift (3s ease loop) |
| Working | strobing flicker (~3Hz steps), brighter core |
| Alert | arc recolors to alert red + hard flash |
| Sleep | dim ember, near-static |

Renderings: inline SVG stroke arc (web/kiosk), braille/glyph frame cycle in TUIs
(`⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏` family, recolored by state), single `⚡`-adjacent glyph fallback on
consoles. The Sprite marks long operations, boot sequences, and system health in
headers. It never appears twice in one viewport.

## 11. Components — do / don't

**Buttons**
- DO: 4px rectangle, gradient fill + glow for primary; ghost (transparent +
  `--ze-line-strong`) for secondary; min-height 56px on touch surfaces
  (48px absolute floor for dense secondary rows — §9).
- DON'T: pill shapes (pre-boxy relic — kill these on sight), gradient on more than
  one primary per view, disabled-by-opacity-only (add `⃠` glyph or hatch pattern).

**Cards / library tiles**
- DO: panel base, hairline border, cover art with scanline overlay, chip row under
  title; hover lifts −6px with glow-e in the tile's dominant tone; selected/focused
  gets corner ticks.
- DON'T: rounded-16 gloss (that was candidate E; boxy won), shadows without
  hairlines, more than one glow color per tile.

**Chips**
- DO: 4px, mono 10px caps, tone border + tone text at low-alpha tint background.
- DON'T: emoji inside chips, tone-less grey chips for semantic facts.

**Telemetry cells**
- DO: top accent bar in the cell's tone, huge mono numeral, spark bars, tracked-caps
  label. Five tones may share one view (multi-phosphor mix) when each does its job.
- DON'T: same tone twice with different meanings in one view; numerals smaller than
  21px (they are the point).

**Lists / tables**
- DO: hairline row separators, focus-island rows, tone dot for state.
- DON'T: zebra striping (texture layer already owns rhythm).

**Empty / error states (voice showcase)**
- DO: Sprite + one witty line + one concrete action. Pizzazz lives here: "Nothing on
  this band yet — tune something in."
- DON'T: deadpan "Error 500" alone, blame-the-user phrasing, more than two sentences.

**Modals / dialogs**
- DO: e3 + glow, corner ticks, scrim `rgba(0,0,0,.6)`, scramble the title on open.
- DON'T: nested modals; if you need one, you need a view.

## 12. Per-surface adaptation

**Web — Go `html/template` + plain CSS** (arcade-webapp, suno-web)
- One `zeus-tokens.css` served static; components consume `var(--ze-*)` only.
  No build step, no preprocessor, no framework JS; htmx-style partial swaps may
  trigger signal-resolve on swap.
- Texture tier: scanlines + grain + vignette; flicker off by default.
- Type tier: full Space Grotesk + JetBrains Mono.
- Print/export styles fall back to day-log palette.

**Kiosk — Pegasus/QML themes**
- Full drama tier: all texture layers (ShaderEffect or layered Rectangle
  equivalents), flicker on, ambient always-alive.
- Touch + gamepad contract (§9) is mandatory, not optional polish.
- Power discipline: ambient loops pause after 60s idle input AND dim toward
  amber-only ≤10 lux-equivalent at night (melanopic rule inherited from the
  wallpanel playbook); wake on any input.
- QML maps tokens 1:1 to a singleton `QtObject` with `property color zePos:
  "#9CFF57"` etc. Same names, same values.

**TUI — charm/bubbletea/lipgloss**
- Terminal font wins; skip web typography. Box-drawing borders stay square:
  lipgloss `NormalBorder`/`ThickBorder`, **never** `RoundedBorder` (geometry is
  boxy everywhere).
- Phosphors map to truecolor ANSI; degrade gracefully via colorprofile down-shift.
- Texture: none (the terminal is the glass). Motion: redraw-driven only — state
  changes animate one frame, no tick-loop theater.
- The Glyph Familiar idea from the mascot zoo survives here as the Sprite's TUI
  rendering (§10); braille frames are native citizens.

**Console / CLI output** (scripts, systemd units, `gum` calls)
- Mono only, phosphor accents for pass/warn/fail, tracked-caps headers where width
  allows. No ASCII logos wider than 40 columns.

**Existing Fallout wallpanels (ha-strategy)**
- Out of scope for enforcement, but the phosphor hexes were deliberately adopted
  verbatim (`#9CFF57 / #FFB642 / #42B6FF / #C77DFF`), so a future migration of those
  dashboards onto Zeus tokens is a rename, not a redesign.

## 13. Voice

Charm-style playful pizzazz, allowed everywhere, required in empty/error/loading
states. Short, dry, confident winks — never cutesy baby-talk, never more than one
joke per screen. Machine labels stay machine-labeled (`DRIFT > 30D`), the prose
around them does the winking. Mascot speech is pizzazz-maximal; telemetry stays
deadpan. That's the split that keeps cute from tipping into chibi.

## 14. Anti-goals & anti-patterns

Hard anti-goals (owner-locked):

- **Not corporate clean.** No Notion/Linear beige minimalism, no sterile SaaS
  dashboard sameness.
- **No chibi mascots.** Cute motion yes; characters with faces/costumes no.
- **Not renamed anything.** Catppuccin-pastels, Fallout/RobCo larp branding,
  any competitor's skin — automatic reject.
- **Not neon-RGB cyberpunk.** Glow is earned by semantics; no glitch-everything,
  no rainbow soup.

Recurring anti-patterns (review checklist):

- Pill-shaped anything (except meter tracks).
- Rounded-soft panels — E lost to F for a reason.
- Decorative phosphor: a fifth instance of a hue with no semantic job.
- Hover-gated functionality on touch surfaces.
- Static screens: no ambient loop = bug (unless reduced-motion or power-save).
- Hard-coded hex outside the token file.
- Scanlines heavy enough to hurt legibility (>4% overlay alpha).
- More than one joke per screen; jokes in telemetry labels.
- Animating layout properties; blocking input during scramble; unguarded
  overlapping scrambles.
- Light theme built by inverting dark instead of using the paper-log palette.

## 15. Change process

Palette/type/motion/token changes edit this file first, ship tokens second,
components last. Previews for proposed changes live as throwaway single-file HTML
during deliberation (see `/tmp/opencode/gauntlet/style-previews/` for the six
candidates that produced this spec — A Red Spot, B Belts&Zones, C Galilean Court,
D Juno Station, E Decametric, F Full Drama); only the winning language graduates
into this document. Anything merging without a rendered preview behind it is
speculation, and speculation is rejected on sight.
