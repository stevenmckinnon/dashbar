import { Mark, Footer, Rich } from "./Chrome";
import { POLICY } from "./policy";

export default function PrivacyPage() {
  return (
    <>
      <div className="navbar">
        <nav className="nav wrap" aria-label="Primary">
          <a className="brand" href="/"><Mark /> Dashbar</a>
          <ul>
            <li><a className="btn small" href="/#install">Install</a></li>
          </ul>
        </nav>
      </div>
      <main className="wrap policy" id="top">
        <article>
          <h1>{POLICY.title}</h1>
          <p className="updated">Last updated: <time dateTime={POLICY.updated}>{POLICY.updatedText}</time></p>
          <p className="policy-lede"><Rich text={POLICY.lede} /></p>
          {POLICY.sections.map((s) => (
            <section key={s.id} id={s.id} aria-labelledby={`${s.id}-h`}>
              <h2 id={`${s.id}-h`}>{s.heading}</h2>
              {s.blocks.map((b, i) => b.list
                ? <ul key={i}>{b.list.map((item) => <li key={item}><Rich text={item} /></li>)}</ul>
                : <p key={i}><Rich text={b.text} /></p>)}
            </section>
          ))}
        </article>
      </main>
      <Footer home="/" />
    </>
  );
}
