import { useEffect, useState } from "react";
import { Mark, Footer, Rich } from "./Chrome";
import { DOCS, docsToc } from "./docs";

function Block({ b }) {
  if (b.h3) return <h3>{b.h3}</h3>;
  if (b.code) return <pre><code>{b.code}</code></pre>;
  if (b.list) return <ul>{b.list.map((item) => <li key={item}><Rich text={item} /></li>)}</ul>;
  if (b.facts) return (
    <dl className="docs-facts">
      {b.facts.map(([k, v]) => [<dt key={`${k}-t`}>{k}</dt>, <dd key={`${k}-d`}><Rich text={v} /></dd>])}
    </dl>
  );
  if (b.table) return (
    <div className="docs-table">
      <table>
        <thead><tr>{b.table.head.map((h) => <th key={h} scope="col">{h}</th>)}</tr></thead>
        <tbody>{b.table.rows.map((r) => <tr key={r[0]}>{r.map((c, i) => <td key={i}><Rich text={c} /></td>)}</tr>)}</tbody>
      </table>
    </div>
  );
  return <p><Rich text={b.text} /></p>;
}

/** The section being read: the last one whose heading has passed the top of the window. */
function useCurrentSection(ids) {
  const [current, setCurrent] = useState(ids[0]);
  useEffect(() => {
    const update = () => {
      let id = ids[0];
      for (const s of ids) {
        const el = document.getElementById(s);
        if (el && el.getBoundingClientRect().top <= 120) id = s;
      }
      setCurrent(id);
    };
    update();
    window.addEventListener("scroll", update, { passive: true });
    return () => window.removeEventListener("scroll", update);
  }, [ids]);
  return current;
}

const toc = docsToc();
const ids = toc.map(([id]) => id);

/** The contents beside the page on wide screens: integrations nested under Integrations. */
function Contents({ current }) {
  const top = toc.filter(([, , parent]) => !parent);
  const link = (id, heading) => (
    <a href={`#${id}`} aria-current={current === id ? "location" : undefined}>{heading}</a>
  );
  return (
    <nav className="docs-side" aria-label="Contents">
      <ul>
        {top.map(([id, heading]) => {
          const children = toc.filter(([, , parent]) => parent === id);
          return (
            <li key={id}>
              {link(id, heading)}
              {children.length > 0 && <ul>{children.map(([cid, ch]) => <li key={cid}>{link(cid, ch)}</li>)}</ul>}
            </li>
          );
        })}
      </ul>
    </nav>
  );
}

export default function DocsPage() {
  const current = useCurrentSection(ids);
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
        <div className="docs-layout">
          <article>
            <h1>{DOCS.title}</h1>
            <p className="policy-lede"><Rich text={DOCS.lede} /></p>
            <nav className="docs-toc" aria-label="On this page">
              <ul>
                {toc.filter(([, , parent]) => !parent).map(([id, heading]) => <li key={id}><a href={`#${id}`}>{heading}</a></li>)}
              </ul>
            </nav>
            {DOCS.sections.map((s) => (
              <section key={s.id} id={s.id} aria-labelledby={`${s.id}-h`} className={s.parent ? "docs-sub" : undefined}>
                <h2 id={`${s.id}-h`}>{s.heading}</h2>
                {s.blocks.map((b, i) => <Block key={i} b={b} />)}
              </section>
            ))}
          </article>
          <Contents current={current} />
        </div>
      </main>
      <Footer home="/" />
    </>
  );
}
