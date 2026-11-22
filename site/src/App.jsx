import { useEffect, useRef, useState } from "react";
import { ArrowDownToLine, Check, Copy, Play, RotateCw, Send, Star } from "lucide-react";
import { FAQ } from "./faq";
import { RELEASE_NOTES, LATEST_VERSION, inline } from "./releases";
import { DashbarDemo } from "./demos/DashbarDemo";
import { AgentsDemo, LimitsDemo, UsageDemo, ServersDemo, SystemDemo, CleanupDemo } from "./demos/FeatureDemos";
import { WindowDemo } from "./demos/WindowDemo";
import { SmallWidget, MediumWidget } from "./demos/Widgets";
import { SITE, REPO, BREW, HERO, TOUR, FEATURES_INTRO, FEATURES, WINDOW, WIDGETS, PACE, PRIVACY, INSTALL, SEND_TO_MAC } from "./content";
import { Mark, Footer } from "./Chrome";

// The DMG itself, so the button downloads straight away. The version comes from the update feed at build time;
// if the feed can't be read it falls back to the releases page.
const DOWNLOAD = LATEST_VERSION
  ? `${REPO}/releases/download/v${LATEST_VERSION}/Dashbar-${LATEST_VERSION}.dmg`
  : `${REPO}/releases/latest`;

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

/** True while the media query matches, and follows it as the window changes. */
function useMedia(query) {
  const [on, setOn] = useState(() => typeof matchMedia !== "undefined" && matchMedia(query).matches);
  useEffect(() => {
    const mq = matchMedia(query);
    const change = () => setOn(mq.matches);
    change();
    mq.addEventListener("change", change);
    return () => mq.removeEventListener("change", change);
  }, [query]);
  return on;
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

// Phones and tablets can't run a Mac app, so there the button sends the link on instead. Touch with no hover
// catches iPads too, which call themselves Macs; a Mac never matches, trackpad or not.
const TOUCH_ONLY = "(hover: none) and (pointer: coarse)";

function DownloadButton({ className = "" }) {
  const touchOnly = useMedia(TOUCH_ONLY);
  if (touchOnly) return <SendToMac className={className} />;
  return (
    <a className={`btn ${className}`} href={DOWNLOAD}>
      <ArrowDownToLine size={19} strokeWidth={2} aria-hidden="true" />Download for macOS
    </a>
  );
}

const SEND_URL = `${SITE}#install`;
const MAILTO = `mailto:?subject=${encodeURIComponent(SEND_TO_MAC.subject)}&body=${encodeURIComponent(`${SEND_TO_MAC.body} ${SEND_URL}`)}`;

/** The share sheet (email, AirDrop, Notes, Messages) where there is one, else a new email to yourself. Sends nothing itself. */
function SendToMac({ className = "" }) {
  const send = async () => {
    if (navigator.share) {
      try { await navigator.share({ title: "Dashbar", text: SEND_TO_MAC.body, url: SEND_URL }); return; }
      catch (e) { if (e?.name === "AbortError") return; /* no share sheet after all: fall through to email */ }
    }
    window.location.href = MAILTO;
  };
  return (
    <div className="send-to-mac">
      <button type="button" className={`btn ${className}`} onClick={send}>
        <Send size={18} strokeWidth={2} aria-hidden="true" />{SEND_TO_MAC.button}
      </button>
      <p className="send-note">{SEND_TO_MAC.note}</p>
    </div>
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
          <li className="nav-pace"><a href="#pace">Pace</a></li>
          <li><a href="#privacy">Privacy</a></li>
          <li><a href="#faq">FAQ</a></li>
          <li className="nav-docs"><a href="/docs">Docs</a></li>
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

/** Opens the FAQ entry with this id, so following a link to it shows the answer, not just the question. */
function openFaq(id) {
  const item = document.getElementById(id);
  if (item instanceof HTMLDetailsElement) item.open = true;
}

/** "Works with Claude Code, Codex, … and OpenCode", each name a link to the FAQ answer that says what it gets. */
function WorksWith() {
  const { lead, tools, faq } = HERO.worksWith;
  return (
    <p className="note works-with">
      {lead}{" "}
      {tools.map((tool, i) => (
        <span key={tool}>
          <a href={`#${faq}`} onClick={() => openFaq(faq)}>{tool}</a>
          {i < tools.length - 2 ? ", " : i === tools.length - 2 ? " and " : null}
        </span>
      ))}
    </p>
  );
}

function Hero() {
  const dark = useDark();
  const touchOnly = useMedia(TOUCH_ONLY);
  const [run, setRun] = useState(0);
  return (
    <header className="wrap hero">
      <div className="hero-copy">
        <h1 id="top">{HERO.headline}</h1>
        <p className="lede"><Inline text={HERO.lede} /></p>
        <div className="actions">
          <DownloadButton />
          {/* A Terminal command is no use on a phone; the Install section still has it for later. */}
          {touchOnly ? null : <BrewCommand />}
        </div>
        <WorksWith />
        {/* What the Mac needs is for the Mac; on a phone the Install section still says it. */}
        {touchOnly ? null : <p className="note">{LATEST_VERSION ? <>Version {LATEST_VERSION}. </> : null}{HERO.note}</p>}
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

/* ---------- The launch film ---------- */

// Never autoplays and loads nothing until asked: the poster is all a visitor downloads unless they press play.
function Tour() {
  const video = useRef(null);
  const [started, setStarted] = useState(false);
  const play = () => {
    const v = video.current;
    if (!v) return;
    v.currentTime = 0;
    v.play();
    setStarted(true);
  };
  return (
    <section className="wrap tour" id="tour" aria-labelledby="tour-h">
      <div className="section-head">
        <h2 id="tour-h">{TOUR.heading}</h2>
        <p>{TOUR.lede}</p>
      </div>
      <div className="tour-film">
        <div className="film">
          <video ref={video} src="/launch.mp4" poster="/launch-poster.jpg" preload="none" playsInline muted
            controls={started} width="1920" height="1080"
            aria-label="Dashbar's 30-second launch film. The menu bar icon turns to a raised hand; the notch opens on a permission prompt and Allow once is pressed. Then the Overview panel with every session by project, the Claude and Codex plan limits filling with their pace marks, idle dev servers, 7 GB of caches you can rebuild, and the Dashbar window's History page." />
          {!started && (
            <button className="film-play" type="button" onClick={play}>
              <Play size={18} strokeWidth={2.25} aria-hidden="true" />Play<span className="sr-only"> the 30-second film</span>
            </button>
          )}
        </div>
        <div className="caption-row">
          <p className="caption">{TOUR.caption}</p>
          {started && (
            <button className="replay-pill" type="button" onClick={play}><RotateCw size={14} strokeWidth={2} aria-hidden="true" />Replay<span className="sr-only"> the film</span></button>
          )}
        </div>
      </div>
    </section>
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

const ITEMS = FEATURES.map(({ name, text, more }) => {
  if (!DEMOS[name]) throw new Error(`No demo for the feature "${name}"`);
  return { name, text, more, Demo: DEMOS[name] };
});

function Feature({ Demo, name, text, more }) {
  const dark = useDark();
  const [run, setRun] = useState(0);
  return (
    <article className="feature">
      <div className="feature-text">
        <h3>{name}</h3>
        <p><Inline text={text} /></p>
        {more && <p className="feature-more"><a href={more.href}>{more.label}</a></p>}
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

// On phones the first three features keep their demos and the rest are a short list of words, so six demos don't
// stack into six screens. Each demo that is shown still plays once and has its Replay pill.
const DEMOS_ON_PHONES = 3;

function Brief({ name, text, more }) {
  return (
    <article className="feature-brief">
      <h3>{name}</h3>
      <p><Inline text={text} /></p>
      {more && <p className="feature-more"><a href={more.href}>{more.label}</a></p>}
    </article>
  );
}

function Features() {
  const phone = useMedia("(max-width: 600px)");
  const shown = phone ? ITEMS.slice(0, DEMOS_ON_PHONES) : ITEMS;
  const brief = phone ? ITEMS.slice(DEMOS_ON_PHONES) : [];
  return (
    <section className="wrap features" id="features" aria-labelledby="features-h">
      <div className="section-head">
        <h2 id="features-h">What it shows</h2>
        <p>{FEATURES_INTRO}</p>
      </div>
      <div className="feature-list">
        {shown.map((it) => <Feature key={it.name} {...it} />)}
        {brief.length > 0 && <div className="feature-briefs">{brief.map((it) => <Brief key={it.name} {...it} />)}</div>}
      </div>
    </section>
  );
}

/* ---------- Beyond the menu bar: the Dashbar window, then the desktop widgets ---------- */

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
      <div className="widgets" id="widgets">
        <div className="widgets-text">
          <h3>{WIDGETS.heading}</h3>
          <p>{WIDGETS.text}</p>
        </div>
        {/* Built in HTML to mirror the app's widget views (demos/Widgets.tsx), with the app's invented demo data. */}
        <div className="widgets-row">
          <div className="widget-shot widget-small"><SmallWidget label={WIDGETS.altSmall} /></div>
          <div className="widget-shot widget-medium"><MediumWidget label={WIDGETS.altMedium} /></div>
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
  const shown = RELEASE_NOTES.slice(0, 1);
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
        <a className="link" href={`${REPO}/releases`}>All releases</a>
      </div>
    </section>
  );
}

/* ---------- Questions ---------- */

function Faq() {
  // A visit to /#faq-agents (or any entry's id) opens that entry.
  useEffect(() => {
    const open = () => { if (location.hash.startsWith("#faq-")) openFaq(location.hash.slice(1)); };
    open();
    addEventListener("hashchange", open);
    return () => removeEventListener("hashchange", open);
  }, []);
  return (
    <section className="wrap faq" id="faq" aria-labelledby="faq-h">
      <h2 id="faq-h">Questions</h2>
      <div className="faq-list">
        {FAQ.map(({ id, q, a, more }) => (
          <details key={id} id={id}>
            <summary>{q}</summary>
            <p>{a}</p>
            {more && <p className="faq-more"><a href={more.href}>{more.label}</a></p>}
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
            {PRIVACY.summary.map((item) => <li key={item}><Inline text={item} /></li>)}
          </ul>
          <p className="policy-link"><a href="/privacy#reads">{PRIVACY.fullReads}</a></p>
        </div>
        <div className="sends">
          <h3>Sends</h3>
          <p>{PRIVACY.sendsIntro}</p>
          <ul>
            {PRIVACY.sends.map((item) => <li key={item}><Inline text={item} /></li>)}
          </ul>
          <p className="check">The code is <a href={REPO}>on GitHub</a> if you want to check.</p>
          <p className="site-note">{PRIVACY.siteNote}</p>
          <p className="policy-link"><a href="/privacy">{PRIVACY.policyLink}</a></p>
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

export default function App() {
  return (
    <>
      <NavBar />
      <Hero />
      <main>
        <Tour />
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
