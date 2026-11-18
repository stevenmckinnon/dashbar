import { Mark, Footer, Rich } from "./Chrome";
import { DOCS, docsToc } from "./docs";

function Block({ b }) {
  if (b.h3) return <h3>{b.h3}</h3>;
  if (b.code) return <pre><code>{b.code}</code></pre>;
  if (b.list) return <ul>{b.list.map((item) => <li key={item}><Rich text={item} /></li>)}</ul>;
  return <p><Rich text={b.text} /></p>;
}

export default function DocsPage() {
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
      <main className="wrap policy docs" id="top">
        <article>
          <h1>{DOCS.title}</h1>
          <p className="policy-lede"><Rich text={DOCS.lede} /></p>
          <nav className="docs-toc" aria-label="On this page">
            <ul>
              {docsToc().map(([id, heading]) => <li key={id}><a href={`#${id}`}>{heading}</a></li>)}
            </ul>
          </nav>
          {DOCS.sections.map((s) => (
            <section key={s.id} id={s.id} aria-labelledby={`${s.id}-h`}>
              <h2 id={`${s.id}-h`}>{s.heading}</h2>
              {s.blocks.map((b, i) => <Block key={i} b={b} />)}
            </section>
          ))}
        </article>
      </main>
      <Footer home="/" />
    </>
  );
}
