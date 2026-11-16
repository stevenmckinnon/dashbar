import { Mark, Footer } from "./Chrome";

// Served by Cloudflare (wrangler.jsonc not_found_handling: "404-page") for any path that isn't a file, with a 404 status.
export default function NotFoundPage() {
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
      <main className="wrap policy not-found" id="top">
        <article>
          <h1>Page not found</h1>
          <p className="policy-lede">There’s nothing at this address. It may have moved, or the link has a typo.</p>
          <p className="not-found-actions">
            <a className="btn" href="/">Go to the homepage</a>
          </p>
        </article>
      </main>
      <Footer home="/" />
    </>
  );
}
