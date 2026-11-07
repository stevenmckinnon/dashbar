import { useEffect, useState } from "react";
import { RotateCw } from "lucide-react";
import { DashbarDemo } from "./demos/DashbarDemo";
import { AgentsDemo, LimitsDemo, ServersDemo, SystemDemo, CleanupDemo } from "./demos/FeatureDemos";

const REPO = "https://github.com/stevenmckinnon/dashbar";
const RELEASES = `${REPO}/releases/latest`;
const BREW = "brew install --cask stevenmckinnon/tap/dashbar";

/** A picture in the visitor's colour scheme: *-light.png by default, *-dark.png in dark mode. */
function Shot({ name, alt, width, height, className, lazy = true }) {
  return (
    <picture>
      <source media="(prefers-color-scheme: dark)" srcSet={`./${name}-dark.png`} />
      <img className={className} src={`./${name}-light.png`} width={width} height={height} alt={alt} loading={lazy ? "lazy" : undefined} />
    </picture>
  );
}

function Mark({ size = 28 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 48 48" aria-hidden="true">
      <path d="M8 26a16 16 0 0 1 32 0" fill="none" stroke="var(--arc)" strokeWidth="6" strokeLinecap="round" />
      <rect x="4" y="33" width="40" height="10" rx="5" fill="var(--track)" />
      <rect x="6" y="35" width="26" height="6" rx="3" fill="var(--signal)" />
    </svg>
  );
}

/* ---------- Hero: the panel, as a short demo ---------- */

function useDark() {
  const [dark, setDark] = useState(() => typeof matchMedia !== "undefined" && matchMedia("(prefers-color-scheme: dark)").matches);
  useEffect(() => {
    const mq = matchMedia("(prefers-color-scheme: dark)");
    const on = () => setDark(mq.matches);
    mq.addEventListener("change", on);
    return () => mq.removeEventListener("change", on);
  }, []);
  return dark;
}

function Hero() {
  const dark = useDark();
  const [run, setRun] = useState(0);
  return (
    <header className="wrap">
      <nav className="nav" aria-label="Primary">
        <a className="brand" href="#top"><Mark /> Dashbar</a>
        <ul>
          <li><a href="#features">Features</a></li>
          <li><a href="#pace">Pace</a></li>
          <li><a href="#privacy">Privacy</a></li>
          <li><a href={REPO}>GitHub</a></li>
          <li><a className="btn small" href="#install">Install</a></li>
        </ul>
      </nav>
      <div className="hero">
        <div>
          <h1 id="top">Your agents, in the menu bar</h1>
          <p className="lede">Dashbar shows which <b>Claude Code</b> and <b>Codex</b> sessions are working, how much of your plan is left, and which dev servers are idling. Free and open source.</p>
          <div className="actions">
            <a className="btn" href={RELEASES}>Download for macOS</a>
            <span className="note">Needs macOS 14 or later. Notarised by Apple.</span>
          </div>
        </div>
        <div className="demo">
          <div role="img" aria-label="A short animation of Dashbar's panel, opened from the menu bar. It shows the dev servers, two of them marked barely used, then the plan limits, where the 5-hour limit is on pace to last until it resets.">
            <div aria-hidden="true"><DashbarDemo key={run} dark={dark} /></div>
          </div>
          <div className="caption-row">
            <p className="caption">In your menu bar you see the icon and how many agents are working. Click it to open the panel.</p>
            <button className="replay-pill" type="button" onClick={() => setRun((n) => n + 1)}><RotateCw size={14} strokeWidth={2} aria-hidden="true" />Replay<span className="sr-only"> the demo</span></button>
          </div>
        </div>
      </div>
    </header>
  );
}

/* ---------- What it shows ---------- */

const ITEMS = [
  { name: "Working agents", Demo: AgentsDemo, w: 792, h: 276,
    body: <>Each Claude Code session by project: working or idle, for how long, and how full its context window is. It reads the session files and transcripts under <code>~/.claude</code>, and nothing else.</> },
  { name: "Plan limits, with pace", Demo: LimitsDemo, w: 792, h: 616,
    body: <>Your 5-hour and weekly limits, with a mark for where an even pace would be and a projection of when you would run out at the current rate. Codex’s limits come from its own logs. Claude’s are experimental and off by default: they read Claude Code’s sign-in from your Keychain, and macOS asks first.</> },
  { name: "Idle servers", Demo: ServersDemo, w: 792, h: 336,
    body: <>Dev servers grouped under the project that owns them. One that has been up for over an hour and is barely using the CPU is marked, and so is one an agent started.</> },
  { name: "System", Demo: SystemDemo, w: 792, h: 400,
    body: <>CPU, memory, GPU, network and battery, and the busiest apps right now. None of it is new; it is just in the same place as everything else.</> },
  { name: "Clean-up", Demo: CleanupDemo, w: 792, h: 580,
    body: <>Finds <code>node_modules</code>, <code>.next</code>, build folders and Xcode’s DerivedData, shows what you would get back, and moves them to the Trash only after you confirm.</> },
];

function FeatureArt({ Demo, name }) {
  const dark = useDark();
  const [run, setRun] = useState(0);
  return (
    <>
      <div className="art" role="img" aria-label={`A short animation of the ${name.toLowerCase()} view.`}>
        <div aria-hidden="true"><Demo key={run} dark={dark} /></div>
      </div>
      <div className="item-head">
        <h3>{name}</h3>
        <button className="replay-pill" type="button" onClick={() => setRun((n) => n + 1)}>
          <RotateCw size={14} strokeWidth={2} aria-hidden="true" />Replay<span className="sr-only"> the {name.toLowerCase()} demo</span>
        </button>
      </div>
    </>
  );
}

function Features() {
  return (
    <section className="wrap features" id="features" aria-labelledby="features-h">
      <div className="features-head">
        <h2 id="features-h">What it shows</h2>
        <p>Everything an agent-heavy day throws at your Mac, in one small panel.</p>
      </div>
      <div className="items">
        {ITEMS.map((it) => (
          <article className="item" key={it.name}>
            <FeatureArt Demo={it.Demo} name={it.name} />
            <p>{it.body}</p>
          </article>
        ))}
      </div>
    </section>
  );
}

/* ---------- Pace, worked out the way the app does it ---------- */

const WINDOW_HOURS = 5;
const ELAPSED_HOURS = 2;
const EVEN_PACE = (ELAPSED_HOURS / WINDOW_HOURS) * 100;

function paceResult(used) {
  if (used >= 100) return { text: "Out", unit: "until it resets", state: "Used up until it resets" };
  const perHour = used / ELAPSED_HOURS;
  if (perHour <= 0) return { text: "All", unit: "to spare", state: "On pace to last until it resets" };
  const hoursLeft = (100 - used) / perHour;
  if (hoursLeft >= WINDOW_HOURS - ELAPSED_HOURS) {
    return { text: "Lasts", unit: "until it resets", state: used < EVEN_PACE - 10 ? "Well under pace" : "On pace to last until it resets" };
  }
  const h = Math.floor(hoursLeft);
  const mins = Math.round((hoursLeft - h) * 60); // taste-skill-ignore: minutes, as on a clock
  return { text: h > 0 ? `${h}h ${String(mins).padStart(2, "0")}m` : `${mins}m`, unit: "to run out", state: "At this rate, you run out before it resets" };
}

function Pace() {
  const [used, setUsed] = useState(62);
  const r = paceResult(used);
  return (
    <section className="wrap pace" id="pace" aria-labelledby="pace-h">
      <div className="pace-text">
        <h2 id="pace-h">When would you run out?</h2>
        <p>Dashbar projects your current rate forward to 100%. Move the slider to try it: you are {ELAPSED_HOURS} hours into a {WINDOW_HOURS}-hour window.</p>
        <div className="control">
          <label htmlFor="used"><span>Used so far</span><output htmlFor="used">{used}%</output></label>
          <input id="used" type="range" min="0" max="100" step="1" value={used} onChange={(e) => setUsed(+e.target.value)} aria-valuetext={`${used} percent used`} />
        </div>
      </div>
      <div className="pace-result">
        <div className="figure" aria-live="polite" aria-atomic="true"><span>{r.text}</span><small>{r.unit}</small></div>
        <div className="limit" aria-hidden="true">
          <div className="limit-head"><b>5-hour</b><span>resets in {WINDOW_HOURS - ELAPSED_HOURS} hours</span><span className="used">{used}% used</span></div>
          <div className="bar"><i style={{ width: `${used}%` }} /><u style={{ left: `calc(${EVEN_PACE}% - 1.5px)` }} /></div>
          <p>{r.state}</p>
        </div>
        <p className="pace-note">The bar is a copy of the one in the app. The mark is where an even pace would be by now.</p>
      </div>
    </section>
  );
}

/* ---------- What it reads, and what it sends ---------- */

function Privacy() {
  return (
    <section className="privacy" id="privacy" aria-labelledby="privacy-h">
      <div className="privacy-inner">
        <h2 id="privacy-h">What it reads and sends</h2>
        <div className="reads">
          <h3>Reads</h3>
          <ul>
            <li>Claude Code’s session files and transcripts: <code>~/.claude/sessions</code> and <code>~/.claude/projects</code></li>
            <li>Codex’s session logs: <code>~/.codex/sessions</code></li>
            <li>The listening ports on your Mac and the processes behind them, through the system’s own process API</li>
            <li>The folders you choose, to size the caches in clean-up</li>
          </ul>
        </div>
        <div className="sends">
          <h3>Sends</h3>
          <p>Nothing, with two exceptions. There is no account and no analytics.</p>
          <ul>
            <li>If you turn on Claude plan limits: one request to <code>api.anthropic.com</code> with Claude Code’s own sign-in. Dashbar never refreshes or stores that sign-in.</li>
            <li>Update checks, from version 0.3.0: a small feed fetched from GitHub to see whether a newer version exists.</li>
          </ul>
          <p style={{ marginTop: 14 }}>The code is <a href={REPO}>on GitHub</a> if you want to check.</p>
        </div>
      </div>
    </section>
  );
}

/* ---------- Install ---------- */

function Install() {
  const [copied, setCopied] = useState(false);
  const copy = async () => {
    try { await navigator.clipboard.writeText(BREW); setCopied(true); setTimeout(() => setCopied(false), 1800); } catch { /* clipboard blocked */ }
  };
  return (
    <section className="wrap install" id="install" aria-labelledby="install-h">
      <h2 id="install-h">Install</h2>
      <div className="how">
        <h3>Download</h3>
        <p>Open the DMG and drag Dashbar to Applications. It is signed and notarised by Apple, and needs macOS 14 or later.</p>
        <a className="btn" href={RELEASES}>Download for macOS</a>
      </div>
      <div className="how brew">
        <h3>Homebrew</h3>
        <p>One command. <code>brew upgrade</code> keeps it current.</p>
        <div className="cmd">
          <code>{BREW}</code>
          <button className="btn small" type="button" onClick={copy}>{copied ? "Copied" : "Copy"}</button>
        </div>
        <span className="sr" role="status">{copied ? "Command copied" : ""}</span>
      </div>
    </section>
  );
}

/* ---------- Footer ---------- */

function Footer() {
  return (
    <footer className="footer">
      <div className="footer-inner">
        <div className="who">
          <a className="brand" href="#top"><Mark /> Dashbar</a>
          <p>Made by <a href="https://steve.mn">Steve McKinnon</a>. Free and open source under the MIT licence.</p>
          <p>Dashbar is not affiliated with Anthropic or OpenAI. Claude and Codex are their trademarks.</p>
        </div>
        <ul className="links">
          <li><a href="#features">Features</a></li>
          <li><a href={REPO}>GitHub</a></li>
          <li><a href="#pace">Pace</a></li>
          <li><a href={`${REPO}/releases`}>Releases</a></li>
          <li><a href="#privacy">Privacy</a></li>
          <li><a href={`${REPO}/issues`}>Issues</a></li>
          <li><a href="#install">Install</a></li>
          <li><a href={`${REPO}/blob/main/LICENSE`}>Licence</a></li>
        </ul>
        <p className="last">© 2026 Steve McKinnon.</p>
      </div>
    </footer>
  );
}

export default function App() {
  return (
    <>
      <Hero />
      <main>
        <Features />
        <Pace />
        <Privacy />
        <Install />
      </main>
      <Footer />
    </>
  );
}
