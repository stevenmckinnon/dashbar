import { Asterisk, ChevronRight, Code, Folder, Gauge, Hand, Layers, Server, Trash2 } from 'lucide-react'
import { Badge, Bar, Chart, Check, Count, Stage, type Act } from '../stageshow/kit'
import { CardHead, Limit, Servers, WorkspaceRow } from './DashbarDemo'
import './dashbar-demo.css'
import './feature-demos.css'

// Six small demos for the "What it shows" list. Each is a cropped piece of
// the panel and one event: a permission prompt arrives and is answered, a
// limit bar fills and its pace mark lands, the hours rise and the cost
// estimate rolls, servers arrive and two are marked, the system charts draw,
// folders are ticked and the total rolls. All play once; none runs over 5 s.

type Props = { dark?: boolean }
const wide = { width: 592 }

function Frame({ height, compactHeight, children, ...rest }: { height: number; compactHeight: number } & Omit<React.ComponentProps<typeof Stage<any>>, 'width' | 'height' | 'compact' | 'play' | 'greys' | 'className' | 'theme' | 'children'> & { children: any; theme: 'light' | 'dark' }) {
  return (
    <Stage {...(rest as any)} width={wide.width} height={height} compact={{ below: 500, width: 358, height: compactHeight }} play="once" greys="cool" className="dd fd">
      {(s: any, r: any, layout: any) => <div className="fd-box" data-layout={layout}>{children(s, r, layout)}</div>}
    </Stage>
  )
}

/* ---------- 1. Agents, and when one needs you ---------- */

// Claude Code stops to ask before running a command. Dashbar shows the
// request under that session, the cursor answers Allow once, and the session
// carries on. The poster is the moment of the question.
type A = { ask: boolean; done: boolean }

async function agentsScript(a: Act<A>) {
  await a.wait(700)
  await a.set({ ask: true })
  await a.wait(1700)
  await a.move('allow')
  await a.wait(250)
  await a.click()
  await a.set({ done: true })
  await a.wait(300)
  await a.move('rest')
}

const AGENTS_REST = { wide: { x: 470, y: 430 }, compact: { x: 280, y: 480 } }

export function AgentsDemo({ dark = false }: Props) {
  return (
    <Frame height={476} compactHeight={516} initial={{ ask: false, done: false } as A} poster={{ ask: true, done: false } as A} script={agentsScript} cursor={{ at: 'rest', style: 'real' }} theme={dark ? 'dark' : 'light'}>
      {(s: A, _r: any, layout: 'wide' | 'compact') => {
        const asking = s.ask && !s.done
        return (
          <>
            <div className="dd-card fd-fill">
              <div className="dd-now-top">
                <span className="dd-mono dd-mono--lg">B<i className="dd-dot" data-attention={asking || undefined} /></span>
                <div className="dd-grow"><b>billing-api</b><small>node :4000 · 186 MB</small></div>
                {asking ? <Badge tone="warning" dot>Needs permission 34s</Badge> : <Badge tone="success" dot>Working 1m</Badge>}
              </div>
              <div className="dd-session">
                <span className="dd-claude"><Asterisk size={14} strokeWidth={2} /></span>
                <div className="dd-grow"><b>Fix flaky invoice export test</b><small>Terminal</small></div>
                <div className="dd-context"><span className="dd-meter"><i style={{ width: '12%' }} /></span><b>12%</b><small>context</small></div>
              </div>
              <div className="fd-ask" data-open={asking || undefined}>
                <div className="fd-ask-in">
                  <div className="fd-ask-box">
                    <div className="fd-ask-head"><Hand size={15} strokeWidth={1.75} /><b>Run a command</b><span className="dd-faint">0:26</span></div>
                    <div className="fd-ask-code"><code className="dd-code">npm test -- --runInBand src/invoices/export.test.ts</code></div>
                    <small className="fd-ask-why">Run the invoice export tests</small>
                    <div className="fd-ask-actions">
                      <span className="fd-ask-btn fd-ask-allow" data-target="allow">Allow once</span>
                      <span className="fd-ask-btn">Deny</span>
                      <span className="fd-ask-open">Open session</span>
                    </div>
                  </div>
                </div>
              </div>
            </div>
            <div className="dd-card fd-fill">
              <CardHead icon={<Layers size={14} strokeWidth={1.75} />} tone="violet" title="Other workspaces" count="3" />
              <WorkspaceRow tone="blue" letter="S" name="storefront-web" sub="Claude is working · 4m" port=":3000" note="server 412 MB" working />
              <WorkspaceRow tone="red" letter="D" name="docs-site" sub="Claude idle for 1h 35m" port=":5173" note="server 144 MB" />
            </div>
            <span data-target="rest" style={{ position: 'absolute', left: AGENTS_REST[layout].x, top: AGENTS_REST[layout].y }} />
          </>
        )
      }}
    </Frame>
  )
}

/* ---------- 2. Plan limits, with pace ---------- */

type L = { limits: boolean; marks: boolean }

async function limitsScript(a: Act<L>) {
  await a.wait(700)
  await a.set({ limits: true })
  await a.wait(1400)
  await a.set({ marks: true })
}

export function LimitsDemo({ dark = false }: Props) {
  return (
    <Frame height={380} compactHeight={390} initial={{ limits: false, marks: false } as L} poster={{ limits: true, marks: true } as L} script={limitsScript} theme={dark ? 'dark' : 'light'}>
      {(s: L) => (
        <div className="dd-card">
          <CardHead icon={<Gauge size={14} strokeWidth={1.75} />} tone="green" title="Plan limits" />
          <div className="dd-who"><Asterisk size={14} strokeWidth={2} className="dd-claude-ink" /><b>Claude</b></div>
          <Limit s={s} tone="claude" label="5-hour" resets="resets in 2 hours" used={55} mark={56} verdict="On pace to last until it resets" />
          <Limit s={s} tone="claude" label="Weekly" resets="resets in 4 days" used={71} mark={50} verdict="At this rate, runs out Sat 14:20" attention />
          <div className="dd-who"><Code size={14} strokeWidth={2} className="dd-codex-ink" /><b>Codex</b></div>
          <Limit s={s} tone="codex" label="5h window" resets="resets in 3 hours" used={21} mark={40} verdict="Well under pace" />
          <Limit s={s} tone="codex" label="7d window" resets="resets in 4 days" used={34} mark={42} verdict="On pace to last until it resets" />
        </div>
      )}
    </Frame>
  )
}

/* ---------- 3. Usage, and what it would cost ---------- */

// Today's Claude Code usage card: the hours rise, the estimate rolls up and
// the projects fill in with their share of it.
type U = { on: boolean; lists: boolean }

const HOURS = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 12, 45, 32, 80, 25, 42, 75]
const PROJECTS = [
  { name: 'storefront-web', value: '92M · $35.11', share: 100 },
  { name: 'billing-api', value: '38M · $14.50', share: 41 },
  { name: 'docs-site', value: '12M · $4.58', share: 13 },
]
const MODELS = [
  { name: 'Opus 5.5', value: '112M · $48.67', share: 100 },
  { name: 'Sonnet 5.5', value: '36M · $7.82', share: 32 },
]

async function usageScript(a: Act<U>) {
  await a.wait(600)
  await a.set({ on: true })
  await a.wait(1300)
  await a.set({ lists: true })
}

function Rank({ title, items, on }: { title: string; items: { name: string; value: string; share: number }[]; on: boolean }) {
  return (
    <div className="fd-rank">
      <small className="fd-rank-title">{title}</small>
      {items.map((it) => (
        <div className="fd-rank-row" key={it.name}>
          <div className="fd-rank-line"><b>{it.name}</b><span className="dd-faint">{it.value}</span></div>
          <span className="fd-rank-bar"><i style={{ width: on ? `${it.share}%` : 0 }} /></span>
        </div>
      ))}
    </div>
  )
}

export function UsageDemo({ dark = false }: Props) {
  return (
    <Frame height={360} compactHeight={408} initial={{ on: false, lists: false } as U} poster={{ on: true, lists: true } as U} script={usageScript} theme={dark ? 'dark' : 'light'}>
      {(s: U, _r: any, layout: string) => (
        <div className="dd-card fd-fill fd-usage">
          <div className="dd-head fd-usage-head">
            <span className="dd-chip dd-claude-ink"><Asterisk size={15} strokeWidth={2} /></span>
            <b>Claude Code</b>
            <span className="dd-faint">Today 153M</span>
          </div>
          <div className="fd-tokens">
            {[['In', '1.2M'], ['Out', '640K'], ['Cache read', '148M'], ['Cache write', '2.9M']].map(([k, v]) => (
              <div key={k}><small>{k}</small><b>{v}</b></div>
            ))}
          </div>
          <div className="fd-cost">
            <strong>≈ <Count value={s.on ? 5649 : 0} format={(n) => `$${(n / 100).toFixed(2)}`} /></strong>
            <span>at API prices</span>
          </div>
          <div className="fd-hours-head">
            <span>By hour, last 24 hours <i>· 6 sessions</i></span>
            <span className="fd-link">History<ChevronRight size={13} strokeWidth={2} /></span>
          </div>
          <div className="fd-hours" data-on={s.on || undefined}>
            {HOURS.map((v, i) => <i key={i} data-zero={v === 0 || undefined} style={{ height: v === 0 || !s.on ? 2 : `${v}%`, transitionDelay: `${Math.max(0, i - 16) * 60}ms` }} />)}
          </div>
          <div className="fd-ranks">
            <Rank title="Projects" items={PROJECTS} on={s.lists} />
            {layout !== 'compact' && <Rank title="Models" items={MODELS} on={s.lists} />}
          </div>
        </div>
      )}
    </Frame>
  )
}

/* ---------- 4. Idle servers ---------- */

type V = { rows: number; flags: boolean }

async function serversScript(a: Act<V>) {
  await a.wait(600)
  await a.stagger([1, 2, 3, 4], (n) => a.set({ rows: n }), 110)
  await a.wait(900)
  await a.set({ flags: true })
}

export function ServersDemo({ dark = false }: Props) {
  return (
    <Frame height={352} compactHeight={352} initial={{ rows: 0, flags: false } as V} poster={{ rows: 4, flags: true } as V} script={serversScript} theme={dark ? 'dark' : 'light'}>
      {(s: V) => (
        <div className="fd-clip">
          <Servers s={s} />
        </div>
      )}
    </Frame>
  )
}

/* ---------- 5. System ---------- */

type Y = { on: boolean; apps: number }

const CPU = [14, 22, 18, 30, 24, 38, 26, 34, 21, 29, 23]
const NET = [4, 9, 6, 14, 8, 20, 11, 16, 9, 12, 7]
const APPS = [
  { name: 'Xcode', pct: 62 },
  { name: 'Chrome', pct: 41 },
  { name: 'node', pct: 22 },
]

async function systemScript(a: Act<Y>) {
  await a.wait(600)
  await a.set({ on: true })
  await a.wait(900)
  await a.stagger([1, 2, 3], (n) => a.set({ apps: n }), 180)
}

function Tile({ label, value, unit, children }: { label: string; value: number; unit: string; children: React.ReactNode }) {
  return (
    <div className="dd-card fd-tile">
      <div className="fd-tile-top"><span>{label}</span></div>
      <strong data-show={value > 0 || undefined}><Count value={value} format={(n) => String(n).padStart(2, '0')} /><small>{unit}</small></strong>
      <div className="fd-tile-chart">{children}</div>
    </div>
  )
}

export function SystemDemo({ dark = false }: Props) {
  return (
    <Frame height={317} compactHeight={328} initial={{ on: false, apps: 0 } as Y} poster={{ on: true, apps: 3 } as Y} script={systemScript} theme={dark ? 'dark' : 'light'}>
      {(s: Y, _r: any, layout: string) => {
        const cw = layout === 'compact' ? 120 : 190
        return (
          <>
            <div className="fd-tiles">
              <Tile label="CPU" value={s.on ? 29 : 0} unit="%">
                <Chart data={CPU} width={cw} height={44} show={s.on} />
              </Tile>
              <Tile label="Network" value={s.on ? 12 : 0} unit="MB/s">
                <Chart data={NET} width={cw} height={44} show={s.on} />
              </Tile>
            </div>
            <div className="dd-card fd-fill">
              <CardHead icon={<Server size={14} strokeWidth={1.75} />} tone="blue" title="Busiest apps" />
              {APPS.map((p, i) => (
                <div className="fd-app fd-in" key={p.name} data-show={s.apps > i || undefined}>
                  <b>{p.name}</b>
                  <span className="fd-track"><i style={{ width: s.apps > i ? `${p.pct}%` : 0 }} /></span>
                  <span className="dd-faint">{p.pct}%</span>
                </div>
              ))}
            </div>
          </>
        )
      }}
    </Frame>
  )
}

/* ---------- 6. Clean-up ---------- */

type C = { checked: number }

const FOLDERS = [
  { name: 'Xcode', kind: 'DerivedData', mb: 2300 },
  { name: 'storefront-web', kind: 'node_modules', mb: 1480 },
  { name: 'notes-ios', kind: '.build', mb: 1150 },
  { name: 'billing-api', kind: 'node_modules', mb: 920 },
  { name: 'storefront-web', kind: '.next', mb: 610 },
]

// Decimal units, three figures at most, as the app writes them (Finder's units)
const gb = (mb: number) => (mb < 1000 ? `${Math.round(mb)} MB` : `${Number((mb / 1000).toPrecision(3))} GB`)
const total = (n: number) => FOLDERS.slice(0, n).reduce((t, f) => t + f.mb, 0)

async function cleanupScript(a: Act<C>) {
  await a.wait(900)
  await a.stagger([1, 2, 3], (n) => a.set({ checked: n }), 520)
}

export function CleanupDemo({ dark = false }: Props) {
  return (
    <Frame height={369} compactHeight={369} initial={{ checked: 0 } as C} poster={{ checked: 3 } as C} script={cleanupScript} theme={dark ? 'dark' : 'light'}>
      {(s: C) => (
        <div className="dd-card fd-fill">
          <CardHead icon={<Folder size={14} strokeWidth={1.75} />} tone="violet" title="Folders you can clear" />
          {FOLDERS.map((f, i) => (
            <div className="fd-folder" key={f.name + f.kind}>
              <Check on={s.checked > i} size={18} />
              <div className="dd-grow"><b>{f.name}</b><small><code className="dd-code">{f.kind}</code></small></div>
              <span className="dd-faint">{gb(f.mb)}</span>
            </div>
          ))}
          <div className="fd-action">
            <span className="fd-total"><Count value={total(s.checked)} format={gb} /><small> to get back</small></span>
            <span className="fd-btn" data-on={s.checked > 0 || undefined}><Trash2 size={14} strokeWidth={1.75} />Move to Trash</span>
          </div>
        </div>
      )}
    </Frame>
  )
}

export { Bar }
