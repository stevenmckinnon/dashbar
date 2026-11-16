// The logo and the footer, shared by the homepage and the privacy policy.
import { REPO, FOOTER } from "./content";

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
