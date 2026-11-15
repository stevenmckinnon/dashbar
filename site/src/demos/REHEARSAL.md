# Dashbar hero demo: rehearsal notes

`DashbarDemo.tsx` is the hero on the project site: Dashbar's panel hung from a mock menu bar, played once.

## Built from

- **Gold copied for structure:** `examples/hero-demo` (the `Stage`, `Act` script and named-target pattern), laid out as a bottom bleed: the panel is inset a gutter and runs off the bottom edge.
- **Story:** opens on a finished Overview, clicks Servers (rows arrive, two get "Barely used"), clicks Agents (limits fill, numbers roll, pace marks and verdicts arrive). Plays once, about 10 seconds, and holds on its payoff. The reduced-motion poster is that final frame.
- **Replay:** a real button below the demo remounts it, so nothing loops for more than five seconds.

## Changed from the gold

- Panel built by hand (a menu bar popover is not a kit `Window`), with kit `Segmented`, `Badge`, `Count` and `Bar`.
- Icons are Lucide at one size and stroke; the product's own SF Symbols are not available.
- Real words only on the agent and its session, the limits and their verdicts, and the servers. Filler bars carry the rows that run off the bottom.
- A second design (`compact`, 358 wide) drops the context readout, the memory column and one workspace row.
- The brand-artwork folder and `BrandMark` were removed from the kit copy (third-party logos the site does not use).

## Checks run

Filmed in the skill's playground (the site's bundle merges the kit and the demo into one stylesheet, which confuses its "kit override" check):

- Wide loop, `--gate`: **rehearsal passed.**
- Compact loop at 390, `--gate`: **rehearsal passed.**
- Reduced-motion poster: complete and self-explanatory.
- In the real page: axe-core ran on the demo at 390 wide in dark mode only. It found four faults (a prohibited `aria-label` on the kit's `Count`, and a `header` that became a second banner landmark); both were fixed, and the re-run shows zero violations. **Light mode and desktop width were not re-run with the demo.** No horizontal overflow at 390. Replay restarts the story.

## Lines left, and why

- `near aligned: Overview / Agents` compares a tab's box edge with a tile label's text edge. The tab labels are centred by design, so the lines are not meant to align.
- `near-empty frames` at about 2s for 450ms (1350ms in compact): the moment one tab crossfades into the sparse Servers list. It is short, but it is there.
- The film reports coverage as `inconclusive` (sampling gaps of up to about 58ms), so motion in those gaps was not judged frame by frame.

## Not checked

- Live frame rate on a real device; a real screen reader; touch.
- Safari and Firefox (only Chrome).
- The System and Clean-up tabs exist in the rail but are not built; the demo never opens them.
- The stat boxes were nudged under a layout heuristic's width threshold (side margin 12px to 14px); it changes nothing visible but it is a nudge, not a design reason.

## Feature demos (`FeatureDemos.tsx`)

Five cropped pieces of the panel, each one event, played once, under 5 s, with a Replay link under each.
Reuses the hero's cards, limits and server rows (exported from `DashbarDemo.tsx`). Full 16px gutter inside the stage; the art is pulled out by 16px so the cards line up with the copy.

- Gate (film.mjs `--gate`, playground, Chrome) at 592 and 390: agents, limits, servers and system pass. Cleanup passes except the kit `Count`'s own re-centring of its digit strip, reported as "settle snap" (the digits repeat, so nothing visible moves; checked on the contact sheet).
- The system charts' draw-in is a kit part; its "same-box content change" lines are manual-inspection prompts, looked at on the sheet.
- Not checked: axe on the page with the new demos, light mode contact sheets, Safari/Firefox, a real screen reader pass.

Updated for the app as of the permission prompts, cost and History work: the agents demo now shows a permission prompt answered with Allow once (cursor; the poster is the prompt itself, before the click), the limits demo shows the status line reading (no plan name or Experimental badge) and Codex's 7d window, and a sixth demo shows a usage card with its cost estimate. Checked in headless Chrome at 390, 905, 1000, 1180 and 1280, light and dark, reduced motion and played through; the film gate was not re-run.

## Updated for the restructured panel (Overview and Usage)

- **Hero:** Overview now shows what the app does: the Now card (title with the window arrow, session, context used,
  subagents line, four labelled actions), Other workspaces, the plan limits strip (tightest windowed limit per agent,
  "Usage ›") and the rebuildable caches line. The second tab is Usage: the limits card (with the even pace key, neutral
  tracks, captions under the bars in the app's words), the two Claude widgets and the usage card running off the bottom.
  The story is the same: Overview, Servers, then Usage, where the limits fill and the marks land (poster). Stage 480 × 716,
  compact 358 × 680 (compact drops the context readout, the subagents line, the fourth action, the servers' memory and the
  strip's reset column).
- **Feature demos:** agents (Now card with the prompt above the quick actions, "Claude working · 4m · 3 subagents"),
  limits (shared limits card; the weekly limit on course to run out is amber), usage (range, subagents line, Workspaces),
  system (neutral bar charts, "Busiest right now" with share of all CPU), clean-up (rebuilt to the app's hover Trash
  button and Move to Trash confirmation; the row closes and the total rolls from 7 GB to 5.52 GB).
- **Window:** the sidebar's second page is Usage with no badge; the session count sits on Overview. Neutral icons and
  sparkline. The workspace page's Agents card still shows one session without the subagent rows the app lists.
- Checked in headless Chrome at 390, 905, 1100 and 1280, light and dark: no horizontal overflow, no console errors, the
  hero plays to its poster and Replay restarts it, reduced motion shows the poster. The film gate was not re-run.
