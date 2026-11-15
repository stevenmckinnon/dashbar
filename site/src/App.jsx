import { useEffect, useState } from "react";
import { ArrowDownToLine, Check, Copy, RotateCw, Star } from "lucide-react";
import { FAQ } from "./faq";
import { RELEASE_NOTES, LATEST_VERSION, inline } from "./releases";
import { DashbarDemo } from "./demos/DashbarDemo";
import { AgentsDemo, LimitsDemo, UsageDemo, ServersDemo, SystemDemo, CleanupDemo } from "./demos/FeatureDemos";
import { WindowDemo } from "./demos/WindowDemo";
import { REPO, BREW, HERO, FEATURES_INTRO, FEATURES, WINDOW, PACE, PRIVACY, INSTALL, FOOTER } from "./content";

// The DMG itself, so the button downloads straight away. The version comes from the update feed at build time;
// if the feed can't be read it falls back to the releases page.
const DOWNLOAD = LATEST_VERSION
  ? `${REPO}/releases/download/v${LATEST_VERSION}/Dashbar-${LATEST_VERSION}.dmg`
  : `${REPO}/releases/latest`;

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

/** Copies the Homebrew command, and says so for a moment. */
function useCopy(text) {
  const [copied, setCopied] = useState(false);
  const copy = async () => {
    try { await navigator.clipboard.writeText(text); setCopied(true); setTimeout(() => setCopied(false), 1800); } catch { /* clipboard blocked */ }
  };
  return [copied, copy];
}

function BrewCommand({ className = "" }) {
  const [copied, copy] = useCopy(BREW);
  return (
    <div className={`brew-cmd ${className}`}>
      <code><span className="prompt" aria-hidden="true">$ </span>{BREW}</code>
      <button type="button" className="copy" onClick={copy} aria-label={copied ? "Copied" : "Copy the Homebrew command"}>
        {copied ? <Check size={16} strokeWidth={2} aria-hidden="true" /> : <Copy size={16} strokeWidth={1.75} aria-hidden="true" />}
      </button>
      <span className="sr" role="status">{copied ? "Command copied" : ""}</span>
    </div>
  );
}

function DownloadButton({ className = "" }) {
  return (
    <a className={`btn ${className}`} href={DOWNLOAD}>
      <ArrowDownToLine size={19} strokeWidth={2} aria-hidden="true" />Download for macOS
    </a>
  );
}

function NavBar() {
  const [scrolled, setScrolled] = useState(false);
  useEffect(() => {
    const on = () => setScrolled(window.scrollY > 8);
    on();
    window.addEventListener("scroll", on, { passive: true });
    return () => window.removeEventListener("scroll", on);
  }, []);
  return (
    <div className="navbar" data-scrolled={scrolled || undefined}>
      <nav className="nav wrap" aria-label="Primary">
        <a className="brand" href="#top"><Mark /> Dashbar</a>
        <ul>
          <li><a href="#features">Features</a></li>
          <li><a href="#window">Window</a></li>
          <li><a href="#pace">Pace</a></li>
          <li><a href="#privacy">Privacy</a></li>
          <li><a href="#faq">FAQ</a></li>
          <li className="nav-star">
            <a className="btn small ghost" href={REPO}>
              <Star size={16} strokeWidth={1.75} aria-hidden="true" /><span className="label">Star on GitHub</span>
            </a>
          </li>
          <li><a className="btn small" href="#install">Install</a></li>
        </ul>
      </nav>
    </div>
  );
}

function Hero() {
  const dark = useDark();
  const [run, setRun] = useState(0);
  return (
    <header className="wrap hero">
      <div className="hero-copy">
        <h1 id="top">{HERO.headline}</h1>
        <p className="lede"><Inline text={HERO.lede} /></p>
        <div className="actions">
          <DownloadButton />
          <BrewCommand />
        </div>
        <p className="note">{LATEST_VERSION ? <>Version {LATEST_VERSION}. </> : null}{HERO.note}</p>
      </div>
      <div className="demo" data-ss-fill="">
        <div role="img" aria-label="A short animation of Dashbar's panel, opened from the menu bar. Overview shows the workspace where Claude is working, the other workspaces, the tightest plan limits and 7 GB of rebuildable caches. Then the dev servers, two of them marked barely used, and the Usage tab, with a card for Claude Code and one for Codex, where the plan limits fill, today’s hours rise and Claude’s 5-hour limit lasts until it resets at this rate.">
          <div aria-hidden="true"><DashbarDemo key={run} dark={dark} /></div>
        </div>
        <div className="caption-row">
          <p className="caption">In your menu bar you see the icon and how many agents are working. Click it to open the panel.</p>
          <button className="replay-pill" type="button" onClick={() => setRun((n) => n + 1)}><RotateCw size={14} strokeWidth={2} aria-hidden="true" />Replay<span className="sr-only"> the demo</span></button>
        </div>
      </div>
    </header>
  );
}

/* ---------- What it shows ---------- */

// Each feature's words are in content.js; its demo is matched by name.
const DEMOS = {
  "Agents, and when they need you": AgentsDemo,
  "Plan limits, with pace": LimitsDemo,
  "Usage and estimated cost": UsageDemo,
  "Idle servers": ServersDemo,
  System: SystemDemo,
  "Clean-up": CleanupDemo,
};

const ITEMS = FEATURES.map(({ name, text }) => {
  if (!DEMOS[name]) throw new Error(`No demo for the feature "${name}"`);
  return { name, text, Demo: DEMOS[name] };
});

function Feature({ Demo, name, text }) {
  const dark = useDark();
  const [run, setRun] = useState(0);
  return (
    <article className="feature">
      <div className="feature-text">
        <h3>{name}</h3>
        <p><Inline text={text} /></p>
        <button className="replay-pill" type="button" onClick={() => setRun((n) => n + 1)}>
          <RotateCw size={14} strokeWidth={2} aria-hidden="true" />Replay<span className="sr-only"> the {name.toLowerCase()} demo</span>
        </button>
      </div>
      <div className="feature-art" data-ss-fill="">
        <div className="art" role="img" aria-label={`A short animation of the ${name.toLowerCase()} view.`}>
          <div aria-hidden="true"><Demo key={run} dark={dark} /></div>
        </div>
      </div>
    </article>
  );
}

function Features() {
  return (
    <section className="wrap features" id="features" aria-labelledby="features-h">
      <div className="section-head">
        <h2 id="features-h">What it shows</h2>
        <p>{FEATURES_INTRO}</p>
      </div>
      <div className="feature-list">
        {ITEMS.map((it) => <Feature key={it.name} {...it} />)}
      </div>
    </section>
  );
}

/* ---------- The Dashbar window ---------- */

function WindowSection() {
  const dark = useDark();
  const [run, setRun] = useState(0);
  return (
    <section className="wrap window" id="window" aria-labelledby="window-h">
      <div className="section-head window-head">
        <h2 id="window-h">{WINDOW.heading}</h2>
        <p>{`${WINDOW.before} `}<kbd>{WINDOW.shortcut}</kbd>{WINDOW.after}</p>
      </div>
      <div className="window-demo">
        <div role="img" aria-label="A short animation of the Dashbar window. It opens on Overview, with a card for each workspace. Clicking storefront-web opens its page: uptime 52 minutes, CPU 12%, memory 1.11 GB and energy 3.1 watts, its dev server on port 3000, its Claude Code session at 34% context, and the processes behind the numbers.">
          <div aria-hidden="true"><WindowDemo key={run} dark={dark} /></div>
        </div>
        <div className="caption-row">
          <p className="caption">{WINDOW.caption}</p>
          <button className="replay-pill" type="button" onClick={() => setRun((n) => n + 1)}><RotateCw size={14} strokeWidth={2} aria-hidden="true" />Replay<span className="sr-only"> the window demo</span></button>
        </div>
      </div>
    </section>
  );
}

/* ---------- Pace, worked out the way the app does it ---------- */

const WINDOW_HOURS = 5;
const ELAPSED_HOURS = 2;
const EVEN_PACE = (ELAPSED_HOURS / WINDOW_HOURS) * 100;

// The same rules and words as the app (RateLimit.pace and LimitBar.text). The bar is the agent's colour, amber
// while it is on course to run out, red from 90% used or once it is used up.
function paceResult(used) {
  if (used >= 100) return { text: "Out", unit: "until it resets", state: "Used up until it resets", fill: "problem" };
  const fill = used >= 90 ? "problem" : undefined;
  const steady = used < EVEN_PACE - 10 ? "At this rate, plenty left when it resets" : "At this rate, lasts until it resets";
  const perHour = used / ELAPSED_HOURS;
  if (perHour <= 0) return { text: "All", unit: "to spare", state: steady, fill };
  const hoursLeft = (100 - used) / perHour;
  if (hoursLeft >= WINDOW_HOURS - ELAPSED_HOURS) return { text: "Lasts", unit: "until it resets", state: steady, fill };
  const h = Math.floor(hoursLeft);
  const mins = Math.round((hoursLeft - h) * 60); // taste-skill-ignore: minutes, as on a clock
  const at = new Date(Date.now() + hoursLeft * 3600e3).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  return { text: h > 0 ? `${h}h ${String(mins).padStart(2, "0")}m` : `${mins}m`, unit: "to run out", state: `At this rate, runs out at ${at}`, fill: fill ?? "attention" };
}

function Pace() {
  const [used, setUsed] = useState(62);
  const r = paceResult(used);
  return (
    <section className="wrap pace" id="pace" aria-labelledby="pace-h">
      <div className="pace-text">
        <h2 id="pace-h">{PACE.heading}</h2>
        <p>{`${PACE.lead} Move the slider to try it: you are `}{ELAPSED_HOURS} hours into a {WINDOW_HOURS}-hour window.</p>
        <div className="control">
          <label htmlFor="used"><span>Used so far</span><output htmlFor="used">{used}%</output></label>
          <input id="used" type="range" min="0" max="100" step="1" value={used} onChange={(e) => setUsed(+e.target.value)} aria-valuetext={`${used} percent used`} />
        </div>
      </div>
      <div className="pace-result">
        <div className="figure" aria-live="polite" aria-atomic="true"><span>{r.text}</span><small>{r.unit}</small></div>
        <div className="limit" aria-hidden="true">
          <div className="limit-head"><b>5-hour</b><span>resets in {WINDOW_HOURS - ELAPSED_HOURS}h</span><span className="used">{used}% used</span></div>
          <div className="bar" data-fill={r.fill}><i style={{ width: `${used}%` }} /><u style={{ left: `calc(${EVEN_PACE}% - 1.5px)` }} /></div>
          <p data-fill={r.fill}>{r.state}</p>
        </div>
        <p className="pace-note">{PACE.note}</p>
      </div>
    </section>
  );
}

/* ---------- What's new ---------- */

function Inline({ text }) {
  return inline(text).map(({ key, tag: Tag, text: t }) => (Tag ? <Tag key={key}>{t}</Tag> : t));
}

function WhatsNew() {
  const shown = RELEASE_NOTES.slice(0, 3);
  if (!shown.length) return null;
  return (
    <section className="wrap news" id="whats-new" aria-labelledby="news-h">
      <h2 id="news-h">What’s new</h2>
      <div className="news-list">
        {shown.map(({ version, date, blocks }) => (
          <article key={version}>
            <h3>
              {version}
              <time dateTime={date.toISOString().slice(0, 10)}>
                {date.toLocaleDateString("en-GB", { day: "numeric", month: "long", year: "numeric", timeZone: "UTC" })}
              </time>
            </h3>
            {blocks.map((b, i) =>
              b.list ? (
                <ul key={i}>{b.items.map((item) => <li key={item}><Inline text={item} /></li>)}</ul>
              ) : (
                <p key={i}><Inline text={b.text} /></p>
              ),
            )}
          </article>
        ))}
        <a className="link" href={`${REPO}/releases`}>All releases on GitHub</a>
      </div>
    </section>
  );
}

/* ---------- Questions ---------- */

function Faq() {
  return (
    <section className="wrap faq" id="faq" aria-labelledby="faq-h">
      <h2 id="faq-h">Questions</h2>
      <div className="faq-list">
        {FAQ.map(({ q, a }) => (
          <details key={q}>
            <summary>{q}</summary>
            <p>{a}</p>
          </details>
        ))}
      </div>
    </section>
  );
}

/* ---------- What it reads, and what it sends ---------- */

function Privacy() {
  return (
    <section className="privacy" id="privacy" aria-labelledby="privacy-h">
      <div className="privacy-inner">
        <h2 id="privacy-h">{PRIVACY.heading}</h2>
        <div className="reads">
          <h3>Reads</h3>
          <ul>
            {PRIVACY.reads.map((item) => <li key={item}><Inline text={item} /></li>)}
          </ul>
        </div>
        <div className="sends">
          <h3>Sends</h3>
          <p>{PRIVACY.sendsIntro}</p>
          <ul>
            {PRIVACY.sends.map((item) => <li key={item}><Inline text={item} /></li>)}
          </ul>
          <p className="check">The code is <a href={REPO}>on GitHub</a> if you want to check.</p>
          <p className="site-note">{PRIVACY.siteNote}</p>
        </div>
      </div>
    </section>
  );
}

/* ---------- Install ---------- */

function Install() {
  return (
    <section className="wrap install" id="install" aria-labelledby="install-h">
      <div className="install-inner">
        <Mark size={56} />
        <h2 id="install-h">{INSTALL.heading}</h2>
        <p className="install-lede">{INSTALL.lede}</p>
        <div className="ways">
          <div className="how">
            <h3>Download</h3>
            <p>{INSTALL.download}</p>
            <DownloadButton />
          </div>
          <div className="how brew">
            <h3>Homebrew</h3>
            <p><Inline text={INSTALL.brew} /></p>
            <BrewCommand className="block" />
          </div>
        </div>
      </div>
    </section>
  );
}

/* ---------- Footer ---------- */

function Footer() {
  return (
    <footer className="footer">
      <div className="footer-inner wrap">
        <div className="who">
          <a className="brand" href="#top"><Mark /> Dashbar</a>
          <p>{`${FOOTER.about} Made by `}<a href="https://steve.mn">Steve McKinnon</a>.</p>
        </div>
        <ul className="links" aria-label="On this page">
          <li><a href="#features">Features</a></li>
          <li><a href="#window">Window</a></li>
          <li><a href="#pace">Pace</a></li>
          <li><a href="#privacy">Privacy</a></li>
          <li><a href="#whats-new">What’s new</a></li>
          <li><a href="#faq">FAQ</a></li>
          <li><a href="#install">Install</a></li>
        </ul>
        <ul className="links" aria-label="Project">
          <li><a href={REPO}>GitHub</a></li>
          <li><a href={`${REPO}/releases`}>Releases</a></li>
          <li><a href={`${REPO}/issues`}>Issues</a></li>
          <li><a href={`${REPO}/blob/main/LICENSE`}>Licence</a></li>
          <li><a href="mailto:hello@usedashbar.com">hello@usedashbar.com</a></li>
        </ul>
        <div className="last">
          <p>© 2026 Steve McKinnon. Free and open source under the MIT licence.</p>
          <p>{FOOTER.trademarks}</p>
        </div>
      </div>
    </footer>
  );
}

export default function App() {
  return (
    <>
      <NavBar />
      <Hero />
      <main>
        <Features />
        <WindowSection />
        <Pace />
        <Privacy />
        <WhatsNew />
        <Faq />
        <Install />
      </main>
      <Footer />
    </>
  );
}
