import { Asterisk, ChevronDown, ChevronRight, Code, Compass, Folder, Gauge, Layers, Moon, Pause, RotateCw, Server, SquareArrowOutUpRight, Terminal } from 'lucide-react'
import { Badge, Bar, Count, Segmented, Stage, type Act } from '../stageshow/kit'
import './dashbar-demo.css'

// Dashbar's panel, hung from the menu bar. It opens on Overview, looks at the
// servers (two are barely used), then at the plan limits, where the pace
// mark lands and the story ends. That last frame is also the poster.

type S = {
  /** 0 Overview, 1 Agents, 2 Servers */
  tab: number
  /** How many server rows have arrived */
  rows: number
  flags: boolean
  /** The limit bars fill, then the pace marks and their verdicts arrive */
  limits: boolean
  marks: boolean
}

const initial: S = { tab: 0, rows: 0, flags: false, limits: false, marks: false }
const POSTER: S = { tab: 1, rows: 4, flags: true, limits: true, marks: true }

const REST = { wide: { x: 396, y: 612 }, compact: { x: 300, y: 500 } }

async function script(a: Act<S>) {
  await a.wait(1000)

  // Servers: four arrive, two are marked barely used
  await a.move('tab-2')
  await a.wait(200)
  await a.click()
  await a.set({ tab: 2 })
  await a.wait(100)
  await a.stagger([1, 2, 3, 4], (n) => a.set({ rows: n }), 110)
  await a.wait(700)
  await a.set({ flags: true })
  await a.wait(2400)

  // Agents: the limits fill and the pace mark says where an even pace would be
  await a.move('tab-1')
  await a.wait(200)
  await a.click()
  await a.set({ tab: 1 })
  await a.wait(500)
  await a.set({ limits: true })
  await a.wait(1300)
  await a.set({ marks: true })
  await a.move('rest')
}

const TABS = ['Overview', 'Agents', 'Servers', 'System', 'Clean-up']
const TARGETS = TABS.map((_, i) => `tab-${i}`)

export function DashbarDemo({ dark = false }: { dark?: boolean }) {
  return (
    <Stage
      width={480}
      height={660}
      compact={{ below: 420, width: 358, height: 560 }}
      initial={initial}
      poster={POSTER}
      script={script}
      play="once"
      cursor={{ at: REST, style: 'real' }}
      theme={dark ? 'dark' : 'light'}
      greys="cool"
      className="dd"
    >
      {(s, _rect, layout) => (
        <>
          <MenuBar />
          <div className="dd-panel" data-layout={layout}>
            <Header />
            <Segmented className="dd-rail" items={TABS} value={s.tab} targets={TARGETS} />
            <div className="dd-body">
              <div className="dd-pane" data-on={s.tab === 0}><Overview /></div>
              <div className="dd-pane" data-on={s.tab === 1}><Agents s={s} /></div>
              <div className="dd-pane" data-on={s.tab === 2}><Servers s={s} /></div>
            </div>
          </div>
          <span data-target="rest" style={{ position: 'absolute', left: REST[layout].x, top: REST[layout].y }} />
        </>
      )}
    </Stage>
  )
}

/* ---------- The menu bar ---------- */

function MenuBar() {
  return (
    <div className="dd-menubar">
      <div className="dd-menus">
        {[34, 24, 28, 32].map((w, i) => <Bar key={i} w={w} h={6} style={{ background: 'var(--dd-bar-ink)' }} />)}
      </div>
      <div className="dd-status">
        {[14, 14, 18].map((w, i) => <Bar key={i} w={w} h={6} style={{ background: 'var(--dd-bar-ink)' }} />)}
        <span className="dd-item" data-open>
          <svg width="16" height="16" viewBox="0 0 48 48" aria-hidden="true"><path d="M8 26a16 16 0 0 1 32 0" fill="none" stroke="currentColor" strokeWidth="7" strokeLinecap="round" /><rect x="4" y="33" width="40" height="10" rx="5" fill="currentColor" /></svg>
          <span>1</span>
        </span>
      </div>
    </div>
  )
}

export function Mark({ size = 22 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 48 48" aria-hidden="true">
      <path d="M8 26a16 16 0 0 1 32 0" fill="none" stroke="var(--dd-arc)" strokeWidth="6" strokeLinecap="round" />
      <rect x="4" y="33" width="40" height="10" rx="5" fill="var(--dd-track)" />
      <rect x="6" y="35" width="26" height="6" rx="3" fill="var(--dd-signal)" />
    </svg>
  )
}

function Header() {
  return (
    <div className="dd-header">
      <div className="dd-brand"><Mark /><span>Dashbar</span></div>
      <div className="dd-header-end">
        <Badge tone="success" dot>1 working</Badge>
        <Pause size={15} strokeWidth={1.75} className="dd-icon" />
        <RotateCw size={15} strokeWidth={1.75} className="dd-icon" />
        <SquareArrowOutUpRight size={15} strokeWidth={1.75} className="dd-icon" />
      </div>
    </div>
  )
}

/* ---------- Overview ---------- */

function Overview() {
  return (
    <>
      <div className="dd-stats">
        <div className="dd-stat">
          <div className="dd-stat-top"><span>Agents</span><b className="dd-ok">1 working</b></div>
          <div className="dd-stat-bottom"><strong>4</strong><span className="dd-spark">{[5, 9, 6, 12, 8, 14].map((h, i) => <i key={i} style={{ height: h }} />)}</span></div>
        </div>
        <div className="dd-stat">
          <div className="dd-stat-top"><span>Servers</span><b className="dd-ok">Live</b></div>
          <div className="dd-stat-bottom"><strong>4</strong><span className="dd-faint">980 MB</span></div>
        </div>
        <div className="dd-stat">
          <div className="dd-stat-top"><span>Clean-up</span></div>
          <div className="dd-stat-bottom"><strong>7<small>GB</small></strong><span className="dd-kinds"><i /><i /><i /></span></div>
        </div>
      </div>

      <div className="dd-card dd-now">
        <div className="dd-now-top">
          <span className="dd-mono dd-mono--blue dd-mono--lg">S<i className="dd-dot" /></span>
          <div className="dd-grow"><b>storefront-web</b><small>node :3000 · 412 MB</small></div>
          <Badge tone="success" dot>Working 4m</Badge>
        </div>
        <div className="dd-session">
          <span className="dd-claude"><Asterisk size={14} strokeWidth={2} /></span>
          <div className="dd-grow"><b>Add Stripe checkout and webhooks</b><small>Claude Code · CLI · runs :3000</small></div>
          <div className="dd-context"><span className="dd-meter"><i style={{ width: '34%' }} /></span><b>34%</b><small>context</small></div>
        </div>
        <div className="dd-actions">
          {[Code, Terminal, Folder, Compass].map((Glyph, i) => <span key={i}><Glyph size={15} strokeWidth={1.75} /></span>)}
        </div>
      </div>

      <div className="dd-card">
        <CardHead icon={<Layers size={14} strokeWidth={1.75} />} tone="violet" title="Other workspaces" count="4" />
        <WorkspaceRow tone="green" letter="B" name="billing-api" sub="Claude idle for 38m" port=":4000" />
        <WorkspaceRow tone="red" letter="D" name="docs-site" sub="Claude idle for 1h 35m" port=":5173" />
        <WorkspaceRow tone="magenta" letter="N" name="notes-ios" sub="Claude idle for 2h 50m" wideOnly />
        <FillerRow />
        <FillerRow />
      </div>
    </>
  )
}

/** Filler: the rows that run off the bottom of the panel */
export function FillerRow() {
  return (
    <div className="dd-ws">
      <Bar w={32} h={32} r={9} tone={3} />
      <div className="dd-grow dd-filler"><Bar w={96} h={7} tone={3} /><Bar w={128} h={6} tone={2} /></div>
    </div>
  )
}

export function CardHead({ icon, tone, title, count }: { icon: React.ReactNode; tone: string; title: string; count?: string }) {
  return (
    <div className="dd-head">
      <span className="dd-chip" data-tone={tone}>{icon}</span>
      <b>{title}</b>
      {count && <span className="dd-faint">{count}</span>}
    </div>
  )
}

export function WorkspaceRow({ tone, letter, name, sub, port, working, wideOnly }: { tone: string; letter: string; name: string; sub: string; port?: string; working?: boolean; wideOnly?: boolean }) {
  return (
    <div className="dd-ws" data-wide-only={wideOnly || undefined}>
      <span className={`dd-mono dd-mono--${tone}`}>{letter}{working && <i className="dd-dot" />}</span>
      <div className="dd-grow"><b>{name}</b><small data-working={working || undefined}>{sub}</small></div>
      {port && <span className="dd-port-text">{port}</span>}
      <ChevronRight size={14} strokeWidth={1.75} className="dd-chevron" />
    </div>
  )
}

/* ---------- Agents: the plan limits ---------- */

export function Limit({ label, resets, used, mark, verdict, tone, s }: { label: string; resets: string; used: number; mark: number; verdict: string; tone: 'claude' | 'codex'; s: { limits: boolean; marks: boolean } }) {
  return (
    <div className="dd-limit" data-tone={tone}>
      <div className="dd-limit-top">
        <b>{label}</b><span className="dd-faint">{resets}</span>
        <span className="dd-used" data-show={s.limits || undefined}>
          <Count value={s.limits ? used : 0} format={(n) => `${String(n).padStart(2, '0')}%`} />
          <span>used</span>
        </span>
      </div>
      <small className="dd-verdict" data-show={s.marks || undefined}>{verdict}</small>
      <div className="dd-bar">
        <i style={{ width: s.limits ? `${used}%` : 0 }} />
        <u data-show={s.marks || undefined} style={{ left: `${mark}%` }} />
      </div>
    </div>
  )
}

function Agents({ s }: { s: S }) {
  return (
    <>
      <div className="dd-card" data-target="limits">
        <CardHead icon={<Gauge size={14} strokeWidth={1.75} />} tone="green" title="Plan limits" />
        <div className="dd-who"><Asterisk size={14} strokeWidth={2} className="dd-claude-ink" /><b>Claude · Max 5x</b><Badge>Experimental</Badge></div>
        <Limit s={s} tone="claude" label="5-hour" resets="resets in 2 hours" used={55} mark={56} verdict="On pace to last until it resets" />
        <Limit s={s} tone="claude" label="Weekly" resets="resets in 4 days" used={38} mark={50} verdict="Well under pace" />
        <div className="dd-who"><Code size={14} strokeWidth={2} className="dd-codex-ink" /><b>Codex</b></div>
        <Limit s={s} tone="codex" label="5h window" resets="resets in 3 hours" used={21} mark={40} verdict="Well under pace" />
      </div>
      <div className="dd-card">
        <CardHead icon={<Layers size={14} strokeWidth={1.75} />} tone="violet" title="Workspaces" count="5" />
        <WorkspaceRow tone="blue" letter="S" name="storefront-web" sub="Claude is working · 4m" port=":3000" working />
        <WorkspaceRow tone="green" letter="B" name="billing-api" sub="Claude idle for 38m" port=":4000" />
        <WorkspaceRow tone="magenta" letter="N" name="notes-ios" sub="Claude idle for 2h 50m" />
        <FillerRow />
      </div>
    </>
  )
}

/* ---------- Servers ---------- */

const SERVERS = [
  { port: ':3000', name: 'storefront-web', by: 'Started by Claude', up: 'up 52m', mem: '412 MB', idle: false },
  { port: ':4000', name: 'billing-api', by: '', up: 'up 20h', mem: '186 MB', idle: true },
  { port: ':5173', name: 'docs-site', by: 'Started by Claude', up: 'up 3h', mem: '144 MB', idle: false },
  { port: ':8888', name: 'ml-notebooks', by: '', up: 'up 1d', mem: '238 MB', idle: true },
]

const LISTENERS = [96, 70, 120, 84, 110, 76, 100, 88]

export function Servers({ s }: { s: { rows: number; flags: boolean } }) {
  return (
    <div className="dd-card">
      <CardHead icon={<Server size={14} strokeWidth={1.75} />} tone="blue" title="Dev servers" count="4" />
      {SERVERS.map((v, i) => (
        <div key={v.name} className="dd-srv" data-show={s.rows > i || undefined}>
          <span className="dd-port">{v.port}</span>
          <div className="dd-grow">
            <b>{v.name}</b>
            <small>
              {v.idle ? (
                <>
                  <span className="dd-flag" data-show={s.flags || undefined}>
                    <span className="dd-flag-in"><Moon size={12} strokeWidth={1.75} />Barely used<i> · </i></span>
                  </span>
                  {v.up}
                </>
              ) : (
                <>{v.by} · {v.up}</>
              )}
            </small>
          </div>
          <span className="dd-faint">{v.mem}</span>
        </div>
      ))}
      <div className="dd-more" data-show={s.rows > 3 || undefined}>
        <ChevronDown size={14} strokeWidth={1.75} className="dd-chevron" />
        <span>Other apps listening (35)</span>
      </div>
      {LISTENERS.map((w, i) => (
        <div key={i} className="dd-listener" data-show={s.rows > 3 || undefined}>
          <Bar w={44} h={18} r={9} tone={2} />
          <Bar w={w} h={7} tone={3} />
        </div>
      ))}
    </div>
  )
}
