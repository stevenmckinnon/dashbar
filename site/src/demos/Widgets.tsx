import './widgets.css'

// The two desktop widgets, built by hand to mirror the app's own views (Sources/DashbarWidgetUI/WidgetViews.swift):
// LimitsWidgetView (small, 164 × 164 pt) and OverviewWidgetView (medium, 344 × 164 pt), with the demo numbers the
// app renders with `--snapshot --demo --widget` (docs/images/widget-*.png). They are still pictures: the real widgets
// don't move, so there is no timeline and no Replay pill. Every length is in widget points (widgets.css), so each
// one scales as a whole with the width it is given. When the widget views change, change these to match and re-run
// the side-by-side comparison with the app's render.

type Provider = 'claude' | 'codex' | 'google'
type Limit = { title: string; reset: string; used: number }
type Row = { name: string; provider: Provider; limits: [Limit, Limit] }

const ROWS: Row[] = [
  { name: 'Claude', provider: 'claude', limits: [{ title: '5h', reset: '15:46', used: 55 }, { title: 'wk', reset: 'Fri 01:34', used: 38 }] },
  { name: 'Codex', provider: 'codex', limits: [{ title: '5h', reset: '16:58', used: 21 }, { title: 'wk', reset: 'Fri 15:58', used: 34 }] },
  { name: 'Antigravity', provider: 'google', limits: [{ title: '5h', reset: '16:28', used: 42 }, { title: 'wk', reset: 'Thu 03:58', used: 61 }] },
]
const CLAUDE = [
  { title: '5-hour', reset: 'Resets 15:46', used: 55 },
  { title: 'Weekly', reset: 'Resets Fri 01:34', used: 38 },
]

/** LimitMeter: a 6 pt capsule, the fill at least 3 pt wide once anything is used. */
function Meter({ used }: { used: number }) {
  return <span className="wg-meter"><i style={{ width: used > 0 ? `max(calc(3 * var(--pt)), ${used}%)` : 0 }} /></span>
}

export function SmallWidget({ label }: { label: string }) {
  return (
    <figure className="wg wg-small" role="img" aria-label={label}>
      <div className="wg-body" aria-hidden="true">
        <div className="wg-head">
          <span className="wg-dot" data-p="claude" />
          <b className="wg-title">Claude</b>
          <span className="wg-plan">Max 5x</span>
        </div>
        {CLAUDE.map((l) => (
          <div className="wg-block" key={l.title}>
            <div className="wg-line"><span className="wg-window">{l.title}</span><b className="wg-figure">{l.used}%</b></div>
            <Meter used={l.used} />
            <span className="wg-reset">{l.reset}</span>
          </div>
        ))}
      </div>
    </figure>
  )
}

export function MediumWidget({ label }: { label: string }) {
  return (
    <figure className="wg wg-medium" role="img" aria-label={label}>
      <div className="wg-body" aria-hidden="true">
        <div className="wg-head">
          <b className="wg-title">Dashbar</b>
          <span className="wg-count"><span className="wg-dot" data-p="working" />2 working</span>
        </div>
        <div className="wg-rows">
          {ROWS.map((r) => (
            <div className="wg-row" key={r.name} data-p={r.provider}>
              <span className="wg-name"><span className="wg-dot" data-p={r.provider} />{r.name}</span>
              {r.limits.map((l) => (
                <div className="wg-compact" key={l.title}>
                  <div className="wg-line">
                    <span className="wg-short">{l.title}</span><span className="wg-when">{l.reset}</span>
                    <b className="wg-pct">{l.used}%</b>
                  </div>
                  <Meter used={l.used} />
                </div>
              ))}
            </div>
          ))}
        </div>
      </div>
    </figure>
  )
}
