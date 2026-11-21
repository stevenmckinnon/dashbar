// The logo, the footer and rich text, shared by the homepage, the docs and the privacy policy.
import { REPO, FOOTER } from "./content";
import { rich } from "./policy";

/** Text with **bold**, `code` and [links](url). */
export function Rich({ text }) {
  return rich(text).map(({ key, tag: Tag, text: t, href }) =>
    Tag === "a" ? <a key={key} href={href}>{t}</a> : Tag ? <Tag key={key}>{t}</Tag> : t);
}

export function Mark({ size = 28 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 48 48" aria-hidden="true">
      <path d="M8 26a16 16 0 0 1 32 0" fill="none" stroke="var(--arc)" strokeWidth="6" strokeLinecap="round" />
      <rect x="4" y="33" width="40" height="10" rx="5" fill="var(--track)" />
      <rect x="6" y="35" width="26" height="6" rx="3" fill="var(--signal)" />
    </svg>
  );
}

/** `home` is where the homepage's sections are: "" on the homepage itself, "/" on other pages. */
export function Footer({ home = "" }) {
  return (
    <footer className="footer">
      <div className="footer-inner wrap">
        <div className="who">
          <a className="brand" href={`${home}#top`}><Mark /> Dashbar</a>
          <p>{`${FOOTER.about} Made by `}<a href="https://steve.mn">Steve McKinnon</a>.</p>
          <div className="badges">
            {/* KittyLaunch's badge, copied here (docs/images/badges/) so the page asks nothing of another site. */}
            <a className="badge" href="https://kittylaunch.com/p/dashbar?utm_source=badge" target="_blank" rel="noopener">
              <picture>
                <source srcSet="/badges/kittylaunch-dark.svg" media="(prefers-color-scheme: dark)" />
                <img src="/badges/kittylaunch-light.svg" width="120" height="120" alt="Dashbar, Verified by KittyLaunch" data-kittylaunch-badge="1" />
              </picture>
            </a>
            {/* BuiltByIndies' badge, exactly as they supplied it: its image loads from their site (said on the privacy page). */}
            <a href="https://builtbyindies.com/products/dashbar?utm_source=badge&utm_medium=embed&utm_campaign=live" target="_blank"><img src="https://builtbyindies.com/badge/2ee31575-bd93-420c-9393-5e02ddab5098.svg?theme=dark&count=0" alt="BuiltByIndies" height="60" /></a>
          </div>
        </div>
        <ul className="links" aria-label={home ? "Homepage" : "On this page"}>
          <li><a href={`${home}#features`}>Features</a></li>
          <li><a href={`${home}#window`}>Window</a></li>
          <li><a href={`${home}#pace`}>Pace</a></li>
          <li><a href={`${home}#privacy`}>Privacy</a></li>
          <li><a href={`${home}#whats-new`}>What’s new</a></li>
          <li><a href={`${home}#faq`}>FAQ</a></li>
          <li><a href={`${home}#install`}>Install</a></li>
        </ul>
        <ul className="links" aria-label="Project">
          <li><a href="/docs">Docs</a></li>
          <li><a href={REPO}>GitHub</a></li>
          <li><a href={`${REPO}/releases`}>Releases</a></li>
          <li><a href={`${REPO}/issues`}>Issues</a></li>
          <li><a href={`${REPO}/blob/main/LICENSE`}>Licence</a></li>
          <li><a href="/privacy">Privacy policy</a></li>
          <li><a href="mailto:hello@usedashbar.com">hello@usedashbar.com</a></li>
        </ul>
        <div className="last">
          <p>© 2026 Steve McKinnon. Free and open source under the MIT licence.</p>
          <p>{FOOTER.independence}</p>
        </div>
      </div>
    </footer>
  );
}
