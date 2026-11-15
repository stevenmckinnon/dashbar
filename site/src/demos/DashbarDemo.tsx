import { ArrowUpRight, Asterisk, Braces, ChevronDown, ChevronRight, CodeXml, Compass, Folder, Gauge, Layers, Moon, Package, Pause, RotateCw, Server, Split, SquareArrowOutUpRight, SquareTerminal } from 'lucide-react'
import { Badge, Bar, Count, Segmented, Stage, type Act } from '../stageshow/kit'
import './dashbar-demo.css'

// Dashbar's panel, hung from the menu bar. It opens on Overview (the working
// workspace, the others, the tightest plan limits and the caches), looks at
// the servers (two are barely used), then at the Usage tab, one card per
// tool, where the limits fill, the hours rise, the pace marks land and the
// story ends. That last frame is also the poster.

type S = {
  /** 0 Overview, 1 Usage, 2 Servers */
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

const REST = { wide: { x: 458, y: 610 }, compact: { x: 345, y: 470 } }

async function script(a: Act<S>) {
  // Time to read the Overview first
  await a.wait(1800)

  // Servers: four arrive, two are marked barely used
  await a.move('tab-2')
  await a.wait(200)
  await a.click()
  await a.set({ tab: 2 })
  await a.wait(100)
  await a.stagger([1, 2, 3, 4], (n) => a.set({ rows: n }), 110)
  await a.wait(700)
  await a.set({ flags: true })
  await a.wait(2200)

  // Usage: the limits fill and the pace mark says where an even pace would be
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

const TABS = ['Overview', 'Usage', 'Servers', 'System', 'Clean-up']
const TARGETS = TABS.map((_, i) => `tab-${i}`)

export function DashbarDemo({ dark = false }: { dark?: boolean }) {
  return (
    <Stage
      width={480}
      height={716}
      compact={{ below: 420, width: 358, height: 680 }}
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
              <div className="dd-pane" data-on={s.tab === 1}><Usage s={s} /></div>
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

/** The Now card's title: the workspace, then the arrow that opens it in the Dashbar window */
export function NowTitle({ letter, name, sub, attention, children }: { letter: string; name: string; sub: string; attention?: boolean; children: React.ReactNode }) {
  return (
    <div className="dd-now-top">
      <span className="dd-mono">{letter}<i className="dd-dot" data-attention={attention || undefined} /></span>
      <div className="dd-grow dd-now-name"><b>{name}</b><small>{sub}</small></div>
      <ArrowUpRight size={13} strokeWidth={2} className="dd-now-open" />
      {children}
    </div>
  )
}

/** The agent's session in the Now card, with how full its context is */
export function NowSession({ title, sub, context }: { title: string; sub: string; context: number }) {
  return (
    <div className="dd-session">
      <span className="dd-claude"><Asterisk size={14} strokeWidth={2} /></span>
      <div className="dd-grow"><b>{title}</b><small>{sub}</small></div>
      <div className="dd-context"><span className="dd-meter"><i style={{ width: `${context}%` }} /></span><b>{context}%</b><small>context used</small></div>
    </div>
  )
}

/** The Now card's four labelled actions */
export function QuickActions({ port }: { port: string }) {
  return (
    <div className="dd-actions">
      <span><Braces size={15} strokeWidth={1.75} />VS Code</span>
      <span><SquareTerminal size={15} strokeWidth={1.75} />Ghostty</span>
      <span><Folder size={15} strokeWidth={1.75} />Finder</span>
      <span className="dd-wide-only"><Compass size={15} strokeWidth={1.75} />localhost{port}</span>
    </div>
  )
}

function Overview() {
  return (
    <>
      <div className="dd-card dd-now">
        <NowTitle letter="S" name="storefront-web" sub="node :3000 · 412 MB">
          <Badge tone="success" dot>Working 4m</Badge>
        </NowTitle>
        <NowSession title="Add Stripe checkout and webhooks" sub="Terminal · runs :3000" context={34} />
        <div className="dd-subagents dd-wide-only"><Split size={13} strokeWidth={2} />3 subagents running · 1 done<ChevronRight size={13} strokeWidth={2} /></div>
        <QuickActions port=":3000" />
      </div>

      <div className="dd-card">
        <CardHead icon={<Layers size={14} strokeWidth={1.75} />} tone="violet" title="Other workspaces" count="3" />
        <WorkspaceRow tone="green" letter="B" name="billing-api" sub="Claude idle · 38m" port=":4000" note="server 186 MB" />
        <WorkspaceRow tone="red" letter="D" name="docs-site" sub="Claude idle · 1h 35m" port=":5173" note="server 144 MB" />
        <WorkspaceRow tone="magenta" letter="N" name="notes-ios" sub="Claude idle · 2h 50m" note="1 agent" />
      </div>

      <PlanStrip />

      <div className="dd-cleanup">
        <Package size={14} strokeWidth={1.75} />
        <span>7 GB of rebuildable caches</span>
        <ChevronRight size={14} strokeWidth={1.75} />
      </div>
    </>
  )
}

/** Overview's plan limits: the tightest windowed limit of each agent, one line each, and a link to Usage */
function PlanStrip() {
  return (
    <div className="dd-card dd-strip">
      <div className="dd-head">
        <span className="dd-chip"><Gauge size={14} strokeWidth={1.75} /></span>
        <b>Plan limits</b>
        <span className="dd-link">Usage<ChevronRight size={13} strokeWidth={2} /></span>
      </div>
      <div className="dd-strip-row" data-tone="claude">
        <Asterisk size={14} strokeWidth={2} className="dd-claude-ink" /><b>Claude</b><span>5-hour</span>
        <span className="dd-strip-bar"><i style={{ width: '55%' }} /></span>
        <strong>55% used</strong><span className="dd-strip-reset">resets in 2h 11m</span>
      </div>
      <div className="dd-strip-row" data-tone="codex">
        <CodeXml size={14} strokeWidth={2} className="dd-codex-ink" /><b>Codex</b><span>Weekly</span>
        <span className="dd-strip-bar"><i style={{ width: '34%' }} /></span>
        <strong>34% used</strong><span className="dd-strip-reset">resets Thu 11:46</span>
      </div>
    </div>
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

export function CardHead({ icon, tone, title, count, children }: { icon: React.ReactNode; tone: string; title: string; count?: string; children?: React.ReactNode }) {
  return (
    <div className="dd-head">
      <span className="dd-chip" data-tone={tone}>{icon}</span>
      <b>{title}</b>
      {count && <span className="dd-faint">{count}</span>}
      {children}
    </div>
  )
}

export function WorkspaceRow({ tone, letter, name, sub, port, note, working, attention, wideOnly }: { tone: string; letter: string; name: string; sub: string; port?: string; note?: string; working?: boolean; attention?: boolean; wideOnly?: boolean }) {
  return (
    <div className="dd-ws" data-wide-only={wideOnly || undefined}>
      <span className={`dd-mono dd-mono--${tone}`}>{letter}{(working || attention) && <i className="dd-dot" data-attention={attention || undefined} />}</span>
      <div className="dd-grow"><b>{name}</b><small data-working={working || undefined} data-attention={attention || undefined}>{sub}</small></div>
      {(port || note) && (
        <span className="dd-ws-end">
          {port && <span className="dd-port-text">{port}</span>}
          {note && <small data-port-note={port ? true : undefined}>{note}</small>}
        </span>
      )}
      <ChevronRight size={14} strokeWidth={1.75} className="dd-chevron" />
    </div>
  )
}

/* ---------- Usage: one card per tool ---------- */

/** The key to the tick on the limit bars, once at the top of the tab */
export function PaceKey() {
  return <span className="dd-pace-key"><i />even pace</span>
}

type Tone = 'claude' | 'codex'

/** One limit as the Usage tab draws it. The fill is the agent's colour, amber while it is on course to run out,
 *  red from 90% used; the track is neutral. */
export function Limit({ label, resets, used, mark, verdict, tone, attention, s }: { label: string; resets: string; used: number; mark: number; verdict: string; tone: Tone; attention?: boolean; s: { limits: boolean; marks: boolean } }) {
  const state = used >= 90 ? 'problem' : attention ? 'attention' : undefined
  return (
    <div className="dd-limit" data-tone={tone} data-state={state}>
      <div className="dd-limit-top">
        <b>{label}</b><span className="dd-faint">{resets}</span>
        <span className="dd-used" data-show={s.limits || undefined}>
          <Count value={s.limits ? used : 0} format={(n) => `${String(n).padStart(2, '0')}%`} />
          <span>used</span>
        </span>
      </div>
      <div className="dd-bar">
        <i style={{ width: s.limits ? `${used}%` : 0 }} />
        <u data-show={s.marks || undefined} style={{ left: `${mark}%` }} />
      </div>
      <small className="dd-verdict" data-show={s.marks || undefined} data-attention={attention || undefined}>{verdict}</small>
    </div>
  )
}

export type LimitSpec = { label: string; resets: string; used: number; mark: number; verdict: string; attention?: boolean }

export const CLAUDE_LIMITS: LimitSpec[] = [
  { label: '5-hour', resets: 'resets in 2h 11m', used: 55, mark: 56, verdict: 'At this rate, lasts until it resets' },
  { label: 'Weekly', resets: 'resets Wed 23:33', used: 38, mark: 50, verdict: 'At this rate, plenty left when it resets' },
]
export const CODEX_LIMITS: LimitSpec[] = [
  { label: '5-hour', resets: 'resets in 3h 23m', used: 21, mark: 32, verdict: 'At this rate, plenty left when it resets' },
  { label: 'Weekly', resets: 'resets Thu 13:57', used: 34, mark: 41, verdict: 'At this rate, lasts until it resets' },
]

/** The tab's top: one period for every card, the key to the pace tick (when a card shows a meter), and with two
 *  tools in use, their total */
export function UsageTop({ period = 0, pace = true, total }: { period?: number; pace?: boolean; total?: { tokens: string; span: string; cost: string } }) {
  return (
    <div className="dd-usage-top">
      <div className="dd-usage-controls">
        <span className="dd-period">{['Today', '7d', '14d'].map((p, i) => <span key={p} data-on={i === period || undefined}>{p}</span>)}</span>
        {pace && <PaceKey />}
      </div>
      {total && (
        <div className="dd-total">
          <b>{total.tokens}</b><span>tokens {total.span} across 2 tools</span>
          <span className="dd-total-cost"><b>≈ {total.cost}</b><span>at API prices</span></span>
        </div>
      )}
    </div>
  )
}

/** A tool's card: the header (it opens History), its plan limits, then what the period's tokens add up to */
export function ToolCard({ tone, title, limits, s, target, children }: { tone: Tone; title: string; limits: LimitSpec[]; s: { limits: boolean; marks: boolean }; target?: string; children?: React.ReactNode }) {
  return (
    <div className="dd-card dd-tool" data-target={target}>
      <div className="dd-head dd-tool-head">
        <span className={`dd-chip dd-${tone}-ink`}>{tone === 'claude' ? <Asterisk size={15} strokeWidth={2} /> : <CodeXml size={15} strokeWidth={2} />}</span>
        <b>{title}</b>
        <ChevronRight size={14} strokeWidth={2} className="dd-chevron" />
      </div>
      {limits.length > 0 && <div className="dd-tool-limits">{limits.map((l) => <Limit key={l.label} s={s} tone={tone} {...l} />)}</div>}
      {children && <div className="dd-tool-tokens" data-tone={tone}>{children}</div>}
    </div>
  )
}

/** Tokens by hour over the last 24 hours: the current hour in the tool's colour, earlier hours neutral */
export const HOURS = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 12, 45, 32, 80, 25, 42, 75]

export function HourBars({ on, values = HOURS }: { on: boolean; values?: number[] }) {
  return (
    <div className="dd-hours">
      <div className="dd-hours-bars">
        {values.map((v, i) => (
          <i key={i} data-zero={v === 0 || undefined} data-now={i === values.length - 1 || undefined}
            style={{ height: v === 0 || !on ? 2 : `${v}%`, transitionDelay: `${Math.max(0, i - 16) * 60}ms` }} />
        ))}
      </div>
      <div className="dd-hours-axis"><span>12</span><span>18</span><span>00</span><span>06</span></div>
    </div>
  )
}

/** The total's parts, each kept on one line when the line wraps: "In 1.2M · Out 640K · Cache read 148M · …" */
export function SplitLine({ text }: { text: string }) {
  return <small className="dd-split">{text.split(' · ').map((p) => p.replaceAll(' ', '\u00a0')).join(' · ')}</small>
}

/** "153M tokens today" with the estimate on the right, the chart, the total's parts and the subagents' share */
export function ToolTokens({ tokens, span = 'today', cost, sessions, on, split, sub }: { tokens: string; span?: string; cost: React.ReactNode; sessions: string; on: boolean; split: string; sub?: string }) {
  return (
    <>
      <div className="dd-headline">
        <strong>{tokens}</strong><small>tokens {span}</small>
        <span className="dd-cost"><b>≈ {cost}</b><small>at API prices</small></span>
      </div>
      <small className="dd-caption">By hour, last 24 hours · {sessions}</small>
      <HourBars on={on} />
      <SplitLine text={split} />
      {sub && <small className="dd-split dd-sub"><Split size={13} strokeWidth={2} />{sub}</small>}
    </>
  )
}

function Usage({ s }: { s: S }) {
  return (
    <>
      <UsageTop total={{ tokens: '162M', span: 'today', cost: '$59.09' }} />
      <ToolCard tone="claude" title="Claude Code" limits={CLAUDE_LIMITS} s={s} target="limits">
        <ToolTokens tokens="153M" cost="$56.49" sessions="6 sessions" on={s.limits}
          split="In 1.2M · Out 640K · Cache read 148M · Cache write 2.9M" sub="Of which subagents 41M · ≈ $13.56 · 27%" />
      </ToolCard>
      {/* Codex's card runs off the bottom of the panel */}
      <ToolCard tone="codex" title="Codex" limits={CODEX_LIMITS} s={s}>
        <ToolTokens tokens="9.5M" cost="$2.60" sessions="2 sessions" on={s.limits}
          split="In 410K · Out 96K · Cache read 9.0M · Cache write 0" />
      </ToolCard>
    </>
  )
}

/* ---------- Servers ---------- */

const SERVERS = [
  { port: ':3000', name: 'storefront-web', by: 'Started by Claude', up: 'up 52m', cmd: 'node next dev', mem: '412 MB', idle: false },
  { port: ':4000', name: 'billing-api', by: '', up: 'up 20h', cmd: 'node server.js', mem: '186 MB', idle: true },
  { port: ':5173', name: 'docs-site', by: 'Started by Claude', up: 'up 3h', cmd: 'node vite', mem: '144 MB', idle: false },
  { port: ':8888', name: 'ml-notebooks', by: '', up: 'up 1d 3h', cmd: 'python jupyter-lab', mem: '238 MB', idle: true },
]

const LISTENERS = [96, 70, 120, 84, 110, 76, 100, 88, 116, 80, 104]

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
              <span className="dd-cmd"> · <code>{v.cmd}</code></span>
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
