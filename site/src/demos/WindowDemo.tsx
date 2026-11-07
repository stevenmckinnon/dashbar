import { Asterisk, Code, Compass, Cpu, Folder, LayoutGrid, Package, Pause, Pin, RotateCw, Search, Server, Settings, Sparkles, Terminal } from 'lucide-react'
import { Badge, Count, Stage, type Act } from '../stageshow/kit'
import { CardHead, Mark } from './DashbarDemo'
import './dashbar-demo.css'
import './window-demo.css'

// The Dashbar window: the panel's pages and every running workspace in a
// sidebar. It opens on Overview, clicks the working workspace's card, and its
// page fills in: the figures roll, their histories rise, the processes behind
// them arrive. That last frame is also the poster.

type S = {
  /** 0 Overview, 1 storefront-web */
  page: number
  /** The tiles' figures and histories */
  tiles: boolean
  /** How many process rows have arrived */
  rows: number
}

const initial: S = { page: 0, tiles: false, rows: 0 }
const POSTER: S = { page: 1, tiles: true, rows: 4 }
const REST = { wide: { x: 1000, y: 600 }, compact: { x: 300, y: 600 } }

async function script(a: Act<S>) {
  await a.wait(1100)
  await a.move('card-0')
  await a.wait(200)
  await a.click()
  await a.set({ page: 1 })
  await a.wait(450)
  await a.set({ tiles: true })
  await a.wait(1100)
  await a.stagger([1, 2, 3, 4], (n) => a.set({ rows: n }), 150)
  await a.move('rest')
}

export function WindowDemo({ dark = false }: { dark?: boolean }) {
  return (
    <Stage
      width={1160}   // the page's widest content width, so the demo fills it and lines up with both edges
      height={640}
      compact={{ below: 560, width: 358, height: 640 }}
      initial={initial}
      poster={POSTER}
      script={script}
      play="once"
      cursor={{ at: REST, style: 'real' }}
      theme={dark ? 'dark' : 'light'}
      greys="cool"
      className="dd wd"
    >
      {(s, _rect, layout) => (
        <>
          <div className="wd-window" data-layout={layout}>
            <Sidebar page={s.page} />
            <div className="wd-main">
              <Head s={s} />
              <div className="wd-body">
                <div className="wd-pane" data-on={s.page === 0}><Overview /></div>
                <div className="wd-pane" data-on={s.page === 1}><Workspace s={s} /></div>
              </div>
            </div>
          </div>
          <span data-target="rest" style={{ position: 'absolute', left: REST[layout].x, top: REST[layout].y }} />
        </>
      )}
    </Stage>
  )
}

/* ---------- Sidebar ---------- */

const PAGES = [
  { name: 'Overview', Icon: LayoutGrid },
  { name: 'Agents', Icon: Sparkles, badge: '4' },
  { name: 'Servers', Icon: Server, badge: '4' },
  { name: 'System', Icon: Cpu, badge: '34%' },
  { name: 'Clean-up', Icon: Package, badge: '7 GB' },
]

const WORKSPACES = [
  { letter: 'S', name: 'storefront-web', working: true },
  { letter: 'B', name: 'billing-api', port: ':4000' },
  { letter: 'D', name: 'docs-site', port: ':5173' },
  { letter: 'N', name: 'notes-ios' },
  { letter: 'M', name: 'ml-notebooks', port: ':8888' },
]

function Sidebar({ page }: { page: number }) {
  return (
    <aside className="wd-side">
      <div className="wd-lights"><i /><i /><i /></div>
      <div className="wd-search"><Search size={14} strokeWidth={1.75} /><span>Filter</span><kbd>⌘K</kbd></div>
      {PAGES.map(({ name, Icon, badge }, i) => (
        <div key={name} className="wd-nav" data-on={(page === 0 && i === 0) || undefined}>
          <Icon size={15} strokeWidth={1.75} className="wd-nav-icon" />
          <span>{name}</span>
          {badge && <em>{badge}</em>}
        </div>
      ))}
      <div className="wd-label">Workspaces</div>
      {WORKSPACES.map((w, i) => (
        <div key={w.name} className="wd-nav" data-on={(page === 1 && i === 0) || undefined}>
          <span className="wd-side-tile">{w.letter}</span>
          <span>{w.name}</span>
          {w.working ? <i className="wd-live" /> : w.port && <em className="wd-port">{w.port}</em>}
        </div>
      ))}
      <div className="wd-foot"><Mark size={16} /><b>Dashbar</b><Settings size={15} strokeWidth={1.75} className="wd-nav-icon" /></div>
    </aside>
  )
}

/* ---------- Header ---------- */

function Head({ s }: { s: S }) {
  return (
    <div className="wd-head">
      <div className="wd-title" data-on={s.page === 0 || undefined}><h4>Overview</h4></div>
      <div className="wd-title wd-identity" data-on={s.page === 1 || undefined}>
        <span className="dd-mono dd-mono--blue dd-mono--lg">S<i className="dd-dot" /></span>
        <div className="dd-grow">
          <div className="wd-name"><h4>storefront-web</h4><Badge tone="success" dot>Working 4m</Badge></div>
          <small>~/Development/storefront-web · checkout-flow</small>
        </div>
      </div>
      <div className="wd-controls">
        <Badge tone="success" dot>1 working</Badge>
        <span className="wd-glass">
          <Pause size={14} strokeWidth={1.75} className="dd-icon" />
          <RotateCw size={14} strokeWidth={1.75} className="dd-icon" />
          <Pin size={14} strokeWidth={1.75} className="dd-icon" />
        </span>
      </div>
    </div>
  )
}

/* ---------- Overview ---------- */

const CARDS = [
  { letter: 'S', name: 'storefront-web', status: 'Claude is working · 4m', working: true, cpu: '12%', mem: '1.1 GB', energy: '3.1 W', port: ':3000' },
  { letter: 'B', name: 'billing-api', status: 'Claude idle for 38m', cpu: '0.3%', mem: '512 MB', energy: '0.20 W', port: ':4000' },
  { letter: 'D', name: 'docs-site', status: 'Claude idle for 1h 35m', cpu: '2%', mem: '610 MB', energy: '0.60 W', port: ':5173' },
  { letter: 'N', name: 'notes-ios', status: 'Claude idle for 2h 50m', cpu: '0.1%', mem: '296 MB', energy: '0.05 W' },
]

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
      <div className="wd-section">Workspaces <span>5</span></div>
      <div className="wd-cards">
        {CARDS.map((c, i) => (
          <div key={c.name} className="dd-card wd-card" data-target={`card-${i}`}>
            <div className="dd-now-top">
              <span className="dd-mono">{c.letter}{c.working && <i className="dd-dot" />}</span>
              <div className="dd-grow"><b>{c.name}</b><small data-working={c.working || undefined}>{c.status}</small></div>
            </div>
            <div className="wd-figures">
              <Figure label="CPU" value={c.cpu} />
              <Figure label="Memory" value={c.mem} />
              <Figure label="Energy" value={c.energy} />
              {c.port && <span className="dd-port">{c.port}</span>}
            </div>
          </div>
        ))}
      </div>
    </>
  )
}

function Figure({ label, value }: { label: string; value: string }) {
  return <span className="wd-figure"><small>{label}</small><b>{value}</b></span>
}

/* ---------- A workspace's page ---------- */

const CPU = [5, 6, 7, 6, 9, 13, 8, 7, 6, 5, 11, 6, 5, 6, 7, 12]
const ENERGY = [8, 9, 11, 12, 13, 13, 12, 11, 10, 9, 9, 10, 11, 12, 13, 15]
const PROCESSES = [
  { name: 'node', count: 3, cpu: '7%', mem: '498 MB' },
  { name: 'claude', count: 1, cpu: '3%', mem: '344 MB' },
  { name: 'esbuild', count: 1, cpu: '1%', mem: '86 MB' },
  { name: 'next-server', count: 1, cpu: '0.4%', mem: '182 MB' },
]

function Workspace({ s }: { s: S }) {
  return (
    <>
      <div className="wd-actions">
        <span><Code size={14} strokeWidth={1.75} />Open in VS Code</span>
        <span><Terminal size={14} strokeWidth={1.75} />Ghostty</span>
        <span><Folder size={14} strokeWidth={1.75} />Finder</span>
        <span className="wd-wide-only"><Compass size={14} strokeWidth={1.75} />localhost:3000</span>
      </div>
      <div className="wd-tiles">
        <Tile label="Uptime" caption="Since 10:14" on={s.tiles}><strong>52m</strong></Tile>
        <Tile label="CPU" caption="Peak 24% · 2m" on={s.tiles} bars={CPU}>
          <strong><Count value={s.tiles ? 12 : 0} format={(n) => String(n)} /><small>%</small></strong>
        </Tile>
        <Tile label="Memory" caption="9 processes" on={s.tiles} line>
          <strong><Count value={s.tiles ? 119 : 0} format={(n) => (n / 100).toFixed(2)} /><small>GB</small></strong>
        </Tile>
        <Tile label="Energy" caption="Moderate · avg 2.5 W" on={s.tiles} bars={ENERGY}>
          <strong><Count value={s.tiles ? 31 : 0} format={(n) => (n / 10).toFixed(1)} /><small>W</small></strong>
        </Tile>
      </div>
      <div className="wd-pair">
        <div className="dd-card">
          <CardHead icon={<Server size={14} strokeWidth={1.75} />} tone="blue" title="Dev servers" count="1" />
          <div className="dd-srv" data-show>
            <span className="dd-port">:3000</span>
            <div className="dd-grow"><b className="wd-mono">node next dev</b><small>Started by Claude · up 52m</small></div>
            <span className="dd-faint">412 MB</span>
          </div>
        </div>
        <div className="dd-card">
          <CardHead icon={<Sparkles size={14} strokeWidth={1.75} />} tone="violet" title="Agents" count="1" />
          <div className="dd-session wd-agent">
            <span className="dd-claude"><Asterisk size={14} strokeWidth={2} /></span>
            <div className="dd-grow"><b>Add Stripe checkout and webhooks</b><small>Working 4m · CLI · runs :3000</small></div>
            <div className="dd-context"><span className="dd-meter"><i style={{ width: '34%' }} /></span><b>34%</b><small>context</small></div>
          </div>
        </div>
      </div>
      <div className="dd-card wd-procs">
        <CardHead icon={<Package size={14} strokeWidth={1.75} />} tone="violet" title="Processes" count="9" />
        <div className="wd-proc wd-proc-head"><span /><span>CPU</span><span>Memory</span></div>
        {PROCESSES.map((p, i) => (
          <div key={p.name} className="wd-proc wd-in" data-show={s.rows > i || undefined}>
            <span><b className="wd-mono">{p.name}</b>{p.count > 1 && <small> ×{p.count}</small>}</span>
            <span>{p.cpu}</span>
            <span className="dd-faint">{p.mem}</span>
          </div>
        ))}
      </div>
    </>
  )
}

function Tile({ label, caption, on, bars, line, children }: { label: string; caption: string; on: boolean; bars?: number[]; line?: boolean; children: React.ReactNode }) {
  const peak = bars ? Math.max(...bars) : 1
  return (
    <div className="dd-card wd-tile">
      <span className="wd-tile-label">{label}</span>
      <div className="wd-tile-value">{children}</div>
      <div className="wd-spark" data-on={on || undefined} data-empty={(!bars && !line) || undefined}>
        {bars?.map((v, i) => <i key={i} style={{ height: on ? `${Math.max(12, (v / peak) * 100)}%` : 0 }} />)}
        {line && <svg viewBox="0 0 100 20" preserveAspectRatio="none"><path d="M0 16 L100 4" /></svg>}
      </div>
      <small>{caption}</small>
    </div>
  )
}
