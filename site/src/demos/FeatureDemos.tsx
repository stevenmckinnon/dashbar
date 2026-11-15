import { Archive, Asterisk, ChevronRight, Flame, Hammer, Hand, Layers, Package, Split, Trash2, X } from 'lucide-react'
import { Badge, Bar, Chart, Collapse, Count, Stage, type Act } from '../stageshow/kit'
import { CardHead, CLAUDE_LIMITS, CODEX_LIMITS, FillerRow, HourBars, NowSession, NowTitle, QuickActions, Servers, SplitLine, ToolCard, UsageTop, WorkspaceRow } from './DashbarDemo'
import './dashbar-demo.css'
import './feature-demos.css'

// Six small demos for the "What it shows" list. Each is a cropped piece of
// the panel and one event: a permission prompt arrives and is answered, a
// limit bar fills and its pace mark lands, the hours rise and the cost
// estimate rolls, servers arrive and two are marked, the system charts draw,
// a cache folder goes to the Trash and the total rolls. All play once; none
// runs over 5 s.

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

const AGENTS_REST = { wide: { x: 470, y: 410 }, compact: { x: 300, y: 400 } }

export function AgentsDemo({ dark = false }: Props) {
  return (
    <Frame height={452} compactHeight={430} initial={{ ask: false, done: false } as A} poster={{ ask: true, done: false } as A} script={agentsScript} cursor={{ at: 'rest', style: 'real' }} theme={dark ? 'dark' : 'light'}>
      {(s: A, _r: any, layout: 'wide' | 'compact') => {
        const asking = s.ask && !s.done
        return (
          <>
            <div className="dd-card fd-fill">
              <NowTitle letter="B" name="billing-api" sub="node :4000 · 186 MB" attention={asking}>
                {asking ? <Badge tone="warning" dot>Needs permission 34s</Badge> : <Badge tone="success" dot>Working 1s</Badge>}
              </NowTitle>
              <NowSession title="Fix flaky invoice export test" sub="Terminal" context={12} />
              <div className="fd-ask" data-open={asking || undefined}>
                <div className="fd-ask-in">
                  <div className="fd-ask-box">
                    <div className="fd-ask-head"><Hand size={15} strokeWidth={1.75} /><b>Run a command</b><span className="dd-faint">0:26 left</span></div>
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
              <QuickActions port=":4000" />
            </div>
            <div className="dd-card fd-fill">
              <CardHead icon={<Layers size={14} strokeWidth={1.75} />} tone="violet" title="Other workspaces" count="4" />
              <WorkspaceRow tone="blue" letter="S" name="storefront-web" sub="Claude working · 4m · 3 subagents" port=":3000" note="server 412 MB" working />
              <WorkspaceRow tone="red" letter="D" name="docs-site" sub="Claude idle · 1h 35m" port=":5173" note="server 144 MB" />
              <WorkspaceRow tone="magenta" letter="N" name="notes-ios" sub="Claude idle · 2h 50m" note="1 agent" />
              <FillerRow />
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
    <Frame height={374} compactHeight={390} initial={{ limits: false, marks: false } as L} poster={{ limits: true, marks: true } as L} script={limitsScript} theme={dark ? 'dark' : 'light'}>
      {(s: L) => (
        <>
          {/* Claude first: its weekly limit is the one on course to run out */}
          <ToolCard tone="claude" title="Claude Code" s={s}
            limits={[CLAUDE_LIMITS[0], { ...CLAUDE_LIMITS[1], used: 71, verdict: 'At this rate, runs out Mon 19:40', attention: true }]} />
          <ToolCard tone="codex" title="Codex" s={s} limits={CODEX_LIMITS} />
        </>
      )}
    </Frame>
  )
}

/* ---------- 3. Usage, and what it would cost ---------- */

// Claude Code's card as the Dashbar window shows it, under the period
// picker: the hours rise, the estimate rolls up and the workspaces and
// models fill in with their share of it.
type U = { on: boolean; lists: boolean }

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
    <Frame height={392} compactHeight={416} initial={{ on: false, lists: false } as U} poster={{ on: true, lists: true } as U} script={usageScript} theme={dark ? 'dark' : 'light'}>
      {(s: U, _r: any, layout: string) => (
        <>
          <UsageTop pace={false} />
          <ToolCard tone="claude" title="Claude Code" limits={[]} s={{ limits: true, marks: true }}>
            <div className="dd-headline">
              <strong>153M</strong><small>tokens today</small>
              <span className="dd-cost"><b>≈ <Count value={s.on ? 5649 : 0} format={(n) => `$${(n / 100).toFixed(2)}`} /></b><small>at API prices</small></span>
            </div>
            <small className="dd-caption">By hour, last 24 hours · 6 sessions</small>
            <HourBars on={s.on} />
            <SplitLine text="In 1.2M · Out 640K · Cache read 148M · Cache write 2.9M" />
            <small className="dd-split dd-sub"><Split size={13} strokeWidth={2} />Of which subagents 41M · ≈ $13.56 · 27%</small>
            <div className="fd-ranks">
              <Rank title="Workspaces" items={PROJECTS} on={s.lists} />
              {layout !== 'compact' && <Rank title="Models" items={MODELS} on={s.lists} />}
            </div>
          </ToolCard>
        </>
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
// Each app's share of all CPU, as the app's "Busiest right now" card gives it
const APPS = [
  { name: 'Xcode', pct: 9.2 },
  { name: 'Google Chrome', pct: 6.1 },
  { name: 'Visual Studio Code', pct: 4.4 },
]

async function systemScript(a: Act<Y>) {
  await a.wait(600)
  await a.set({ on: true })
  await a.wait(900)
  await a.stagger([1, 2, 3], (n) => a.set({ apps: n }), 180)
}

function Tile({ label, value, unit, format = (n) => String(n).padStart(2, '0'), children }: { label: string; value: number; unit: string; format?: (n: number) => string; children: React.ReactNode }) {
  return (
    <div className="dd-card fd-tile">
      <div className="fd-tile-top"><span>{label}</span></div>
      <strong data-show={value > 0 || undefined}><Count value={value} format={format} /><small>{unit}</small></strong>
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
              <Tile label="CPU" value={s.on ? 34 : 0} unit="%">
                <Chart data={CPU} kind="bars" width={cw} height={44} show={s.on} />
              </Tile>
              <Tile label="Network" value={s.on ? 24 : 0} format={(n) => (n / 10).toFixed(1)} unit="MB/s">
                <Chart data={NET} kind="bars" width={cw} height={44} show={s.on} />
              </Tile>
            </div>
            <div className="dd-card fd-fill">
              <CardHead icon={<Flame size={14} strokeWidth={1.75} />} tone="blue" title="Busiest right now"><span className="fd-head-end">share of all CPU</span></CardHead>
              {APPS.map((p, i) => (
                <div className="fd-app fd-in" key={p.name} data-show={s.apps > i || undefined}>
                  <b>{p.name}</b>
                  <span className="fd-track"><i style={{ width: s.apps > i ? `${(p.pct / 12) * 100}%` : 0 }} /></span>
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

// The Clean-up tab: rebuildable folders, largest first. The cursor rests on
// one, its Trash button appears, it asks once, and the folder goes to the
// Trash: the row closes and the total rolls down. The poster is the list after.
type C = { hover: boolean; confirm: boolean; gone: boolean }

const FOLDERS = [
  { name: 'Xcode', kind: 'DerivedData', mb: 2300, Icon: Hammer },
  { name: 'storefront-web', kind: 'node_modules', mb: 1480, Icon: Package },
  { name: 'notes-ios', kind: '.build', mb: 1150, Icon: Hammer },
  { name: 'billing-api', kind: 'node_modules', mb: 920, Icon: Package },
  { name: 'storefront-web', kind: '.next', mb: 610, Icon: Archive },
  { name: 'docs-site', kind: 'node_modules', mb: 540, Icon: Package },
]
const GONE = 1

// Decimal units, three figures at most, as the app writes them (Finder's units)
const gb = (mb: number) => (mb < 1000 ? `${Math.round(mb)} MB` : `${Number((mb / 1000).toPrecision(3))} GB`)
const TOTAL = FOLDERS.reduce((t, f) => t + f.mb, 0)

async function cleanupScript(a: Act<C>) {
  await a.wait(700)
  await a.move('row')
  await a.set({ hover: true })
  await a.wait(350)
  await a.move('trash')
  await a.wait(150)
  await a.click()
  await a.set({ confirm: true })
  await a.wait(500)
  await a.move('confirm')
  await a.wait(150)
  await a.click()
  await a.set({ gone: true, hover: false })
  await a.wait(300)
  await a.move('rest')
}

const CLEANUP_REST = { wide: { x: 470, y: 306 }, compact: { x: 280, y: 314 } }

export function CleanupDemo({ dark = false }: Props) {
  return (
    <Frame height={330} compactHeight={338} initial={{ hover: false, confirm: false, gone: false } as C} poster={{ hover: false, confirm: false, gone: true } as C} script={cleanupScript} cursor={{ at: 'rest', style: 'real' }} theme={dark ? 'dark' : 'light'}>
      {(s: C, _r: any, layout: 'wide' | 'compact') => (
        <>
          <div className="dd-card fd-fill">
            <CardHead icon={<Package size={14} strokeWidth={1.75} />} tone="violet" title="Clean-up">
              <span className="fd-head-end"><Count value={s.gone ? TOTAL - FOLDERS[GONE].mb : TOTAL} format={gb} /></span>
            </CardHead>
            {FOLDERS.map((f, i) => {
              const row = (
                <div className="fd-folder" data-hover={(i === GONE && s.hover) || undefined} data-target={i === GONE ? 'row' : undefined}>
                  <f.Icon size={14} strokeWidth={1.75} className="fd-folder-icon" />
                  <div className="dd-grow"><b>{f.name}</b><small><code className="dd-code">{f.kind}</code></small></div>
                  {i === GONE && s.confirm ? (
                    <>
                      <span className="fd-confirm" data-target="confirm">Move to Trash</span>
                      <X size={14} strokeWidth={1.75} className="fd-folder-icon" />
                    </>
                  ) : (
                    <>
                      <span className="dd-faint">{gb(f.mb)}</span>
                      <span className="fd-trash" data-show={(i === GONE && s.hover) || undefined} data-target={i === GONE ? 'trash' : undefined}><Trash2 size={14} strokeWidth={1.75} /></span>
                    </>
                  )}
                </div>
              )
              return i === GONE ? <Collapse key={f.name + f.kind} open={!s.gone}>{row}</Collapse> : <div key={f.name + f.kind}>{row}</div>
            })}
            <small className="fd-note">Moves to the Trash. Reinstall packages or rebuild to get them back.</small>
          </div>
          <span data-target="rest" style={{ position: 'absolute', left: CLEANUP_REST[layout].x, top: CLEANUP_REST[layout].y }} />
        </>
      )}
    </Frame>
  )
}

export { Bar }
