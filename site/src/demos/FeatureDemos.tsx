import { Asterisk, Code, Folder, Gauge, Layers, Server, Trash2 } from 'lucide-react'
import { Badge, Bar, Chart, Check, Count, Stage, type Act } from '../stageshow/kit'
import { CardHead, Limit, Servers, WorkspaceRow } from './DashbarDemo'
import './dashbar-demo.css'
import './feature-demos.css'

// Five small demos for the "What it shows" list. Each is a cropped piece of
// the panel and one event: a context meter fills, a limit bar fills and its
// pace mark lands, servers arrive and two are marked, the system charts draw,
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

/* ---------- 1. Working agents ---------- */

type A = { ctx: boolean; rows: number }

async function agentsScript(a: Act<A>) {
  await a.wait(700)
  await a.set({ ctx: true })
  await a.wait(1200)
  await a.stagger([1, 2], (n) => a.set({ rows: n }), 160)
}

export function AgentsDemo({ dark = false }: Props) {
  return (
    <Frame height={315} compactHeight={349} initial={{ ctx: false, rows: 0 } as A} poster={{ ctx: true, rows: 2 } as A} script={agentsScript} theme={dark ? 'dark' : 'light'}>
      {(s: A) => (
        <>
          <div className="dd-card fd-fill">
            <div className="dd-now-top">
              <span className="dd-mono dd-mono--blue dd-mono--lg">S<i className="dd-dot" /></span>
              <div className="dd-grow"><b>storefront-web</b><small>node :3000 · 412 MB</small></div>
              <Badge tone="success" dot>Working 4m</Badge>
            </div>
            <div className="dd-session">
              <span className="dd-claude"><Asterisk size={14} strokeWidth={2} /></span>
              <div className="dd-grow"><b>Add Stripe checkout</b><small>Claude Code · CLI</small></div>
              <div className="dd-context">
                <span className="dd-meter"><i style={{ width: s.ctx ? '34%' : 0 }} /></span>
                <b className="fd-pct" data-show={s.ctx || undefined}>34%</b>
                <small>context</small>
              </div>
            </div>
          </div>
          <div className="dd-card fd-fill">
            <CardHead icon={<Layers size={14} strokeWidth={1.75} />} tone="violet" title="Other workspaces" count="4" />
            <div className="fd-in" data-show={s.rows > 0 || undefined}><WorkspaceRow tone="green" letter="B" name="billing-api" sub="Claude idle for 38m" port=":4000" /></div>
            <div className="fd-in" data-show={s.rows > 1 || undefined}><WorkspaceRow tone="red" letter="D" name="docs-site" sub="Claude idle for 1h 35m" port=":5173" /></div>
          </div>
        </>
      )}
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
    <Frame height={323} compactHeight={332} initial={{ limits: false, marks: false } as L} poster={{ limits: true, marks: true } as L} script={limitsScript} theme={dark ? 'dark' : 'light'}>
      {(s: L) => (
        <div className="dd-card">
          <CardHead icon={<Gauge size={14} strokeWidth={1.75} />} tone="green" title="Plan limits" />
          <div className="dd-who"><Asterisk size={14} strokeWidth={2} className="dd-claude-ink" /><b>Claude · Max 5x</b><Badge>Experimental</Badge></div>
          <Limit s={s} tone="claude" label="5-hour" resets="resets in 2 hours" used={55} mark={56} verdict="On pace to last until it resets" />
          <Limit s={s} tone="claude" label="Weekly" resets="resets in 4 days" used={71} mark={50} verdict="At this rate, you run out in 1d 18h" />
          <div className="dd-who"><Code size={14} strokeWidth={2} className="dd-codex-ink" /><b>Codex</b></div>
          <Limit s={s} tone="codex" label="5h window" resets="resets in 3 hours" used={21} mark={40} verdict="Well under pace" />
        </div>
      )}
    </Frame>
  )
}

/* ---------- 3. Idle servers ---------- */

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

/* ---------- 4. System ---------- */

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

/* ---------- 5. Clean-up ---------- */

type C = { checked: number }

const FOLDERS = [
  { name: 'DerivedData', where: 'Xcode', mb: 3210 },
  { name: 'node_modules', where: 'storefront-web', mb: 1840 },
  { name: '.next', where: 'storefront-web', mb: 640 },
  { name: '.build', where: 'notes-ios', mb: 410 },
  { name: '.turbo', where: 'billing-api', mb: 220 },
]

const gb = (mb: number) => `${(mb / 1000).toFixed(1)} GB`
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
            <div className="fd-folder" key={f.name}>
              <Check on={s.checked > i} size={18} />
              <div className="dd-grow"><b>{f.name}</b><small>{f.where}</small></div>
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
