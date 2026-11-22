import { useEffect, useState } from "react";
import { ChevronLeft, ChevronRight } from "lucide-react";
import { Mark, Footer, Rich } from "./Chrome";
import { DOCS, DOCS_PAGES, docsPage, docsPath, pageSections, pageOfSection } from "./docs";

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

/** "/docs/integrations/" → "integrations"; "/docs" → null. */
const slugFromPath = (path) => {
  const m = path.match(/^\/docs\/([^/]+)\/?$/);
  return m && docsPage(m[1]) ? m[1] : null;
};

/** The section being read: the last one whose heading has passed the top of the window. */
function useCurrentSection(ids) {
  const [current, setCurrent] = useState(ids[0]);
  useEffect(() => {
    if (!ids.length) return undefined;
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

/** Beside the page on wide screens: every docs page, and the sections of the one being read. */
function Contents({ page, current }) {
  return (
    <nav className="docs-side" aria-label="Docs">
      <ul>
        <li><a href="/docs" aria-current={!page ? "page" : undefined}>Overview</a></li>
        {DOCS_PAGES.map((p) => (
          <li key={p.slug}>
            <a href={docsPath(p.slug)} aria-current={page?.slug === p.slug ? "page" : undefined}>{p.title}</a>
            {page?.slug === p.slug && (
              <ul>
                {pageSections(p).filter((s) => s.heading !== p.title).map((s) => (
                  <li key={s.id}><a href={`#${s.id}`} aria-current={current === s.id ? "location" : undefined}>{s.heading}</a></li>
                ))}
              </ul>
            )}
          </li>
        ))}
      </ul>
    </nav>
  );
}

function Overview() {
  return (
    <>
      <h1>{DOCS.title}</h1>
      <p className="policy-lede"><Rich text={DOCS.lede} /></p>
      <ul className="docs-cards">
        {DOCS_PAGES.map((p) => (
          <li key={p.slug}>
            <a href={docsPath(p.slug)}>
              <strong>{p.title}</strong>
              <span>{p.summary}</span>
              <ChevronRight className="docs-card-arrow" size={20} strokeWidth={1.75} aria-hidden="true" />
            </a>
          </li>
        ))}
      </ul>
    </>
  );
}

function Page({ page }) {
  const i = DOCS_PAGES.indexOf(page);
  const prev = DOCS_PAGES[i - 1];
  const next = DOCS_PAGES[i + 1];
  // On a phone the contents column is hidden: the page's own sections as pills instead.
  const subs = pageSections(page).filter((s) => s.heading !== page.title);
  return (
    <>
      <p className="docs-crumb"><a href="/docs"><ChevronLeft size={16} strokeWidth={2} aria-hidden="true" />All docs</a></p>
      <h1>{page.title}</h1>
      {subs.length > 1 && (
        <nav className="docs-toc" aria-label="On this page">
          <ul>{subs.map((s) => <li key={s.id}><a href={`#${s.id}`}>{s.heading}</a></li>)}</ul>
        </nav>
      )}
      {pageSections(page).map((s) => (
        <section key={s.id} id={s.id} aria-labelledby={s.heading === page.title ? undefined : `${s.id}-h`}
                 className={s.parent ? "docs-sub" : undefined}>
          {s.heading !== page.title && <h2 id={`${s.id}-h`}>{s.heading}</h2>}
          {s.blocks.map((b, j) => <Block key={j} b={b} />)}
        </section>
      ))}
      <nav className="docs-pager" aria-label="More docs">
        {prev ? <a href={docsPath(prev.slug)} rel="prev"><span>Previous</span>{prev.title}</a> : <a href="/docs" rel="prev"><span>Previous</span>Overview</a>}
        {next && <a href={docsPath(next.slug)} rel="next"><span>Next</span>{next.title}</a>}
      </nav>
    </>
  );
}

export default function DocsPage() {
  const slug = slugFromPath(window.location.pathname);
  const page = slug ? docsPage(slug) : null;

  // Links made before the docs were split (/docs#claude-limits) go to the page that section is on now.
  useEffect(() => {
    const id = window.location.hash.slice(1);
    if (!page && id) {
      const target = pageOfSection(id);
      if (target) window.location.replace(docsPath(target.slug) + "#" + id);
    }
  }, [page]);

  const ids = page ? pageSections(page).map((s) => s.id) : [];
  const [sectionIds] = useState(ids);
  const current = useCurrentSection(sectionIds);

  return (
    <>
      <div className="navbar">
        <nav className="nav wrap" aria-label="Primary">
          <a className="brand" href="/"><Mark /> Dashbar</a>
          <ul>
            <li><a href="/docs">Docs</a></li>
            <li><a className="btn small" href="/#install">Install</a></li>
          </ul>
        </nav>
      </div>
      <main className="wrap policy docs" id="top">
        <div className="docs-layout">
          <article>{page ? <Page page={page} /> : <Overview />}</article>
          <Contents page={page} current={current} />
        </div>
      </main>
      <Footer home="/" />
    </>
  );
}
