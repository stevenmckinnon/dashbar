#!/usr/bin/env python3
"""Saves Dashbar's public download counts (and, with a token that can read it, repo traffic) to CSV files.

GitHub only reports running totals for release downloads and keeps traffic for 14 days, so this is run
daily by .github/workflows/stats.yml and the results kept on the `stats` branch.

    GH_TOKEN=... python3 scripts/stats.py <folder>

Environment:
    GH_TOKEN           any token that can read the repo's releases (the workflow's GITHUB_TOKEN is enough)
    TRAFFIC_TOKEN      optional: a token with push access, needed for views and clones
    GITHUB_REPOSITORY  owner/name, default stevenmckinnon/dashbar
    GITHUB_STEP_SUMMARY  if set, a short table is written there for the Actions run page

Nothing here touches the app. It reads numbers GitHub already keeps.
"""
import csv
import datetime as dt
import json
import os
import sys
import urllib.error
import urllib.request

REPO = os.environ.get("GITHUB_REPOSITORY", "stevenmckinnon/dashbar")
API = "https://api.github.com"


def get(path, token):
    req = urllib.request.Request(API + path, headers={
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "dashbar-stats",
        **({"Authorization": f"Bearer {token}"} if token else {}),
    })
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def release_downloads(token):
    """{tag: DMG downloads so far} for every published release."""
    counts, page = {}, 1
    while True:
        releases = get(f"/repos/{REPO}/releases?per_page=100&page={page}", token)
        for rel in releases:
            if rel.get("draft"):
                continue
            counts[rel["tag_name"]] = sum(a["download_count"] for a in rel["assets"] if a["name"].endswith(".dmg"))
        if len(releases) < 100:
            return counts
        page += 1


def read_csv(path):
    if not os.path.exists(path):
        return []
    with open(path, newline="") as f:
        return list(csv.DictReader(f))


def write_csv(path, fields, rows):
    with open(path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def version_key(tag):
    parts = tag.lstrip("v").split(".")
    return tuple(int(p) if p.isdigit() else 0 for p in parts)


def save_downloads(folder, today, counts):
    """One row per release per day. Rerunning on the same day replaces that day's rows."""
    path = os.path.join(folder, "downloads.csv")
    rows = [r for r in read_csv(path) if r["date"] != today]
    previous = {}
    for r in rows:   # latest earlier snapshot per release, for the summary
        previous[r["release"]] = int(r["downloads"])
    for tag in sorted(counts, key=version_key, reverse=True):
        rows.append({"date": today, "release": tag, "downloads": counts[tag]})
    rows.sort(key=lambda r: (r["date"], version_key(r["release"])))
    write_csv(path, ["date", "release", "downloads"], rows)
    return previous


def save_traffic(folder, token):
    """Daily views and clones. GitHub returns the last 14 days; days already saved are updated."""
    views = get(f"/repos/{REPO}/traffic/views?per=day", token)["views"]
    clones = get(f"/repos/{REPO}/traffic/clones?per=day", token)["clones"]
    path = os.path.join(folder, "traffic.csv")
    by_day = {r["date"]: r for r in read_csv(path)}
    blank = {"views": 0, "unique_views": 0, "clones": 0, "unique_clones": 0}
    for v in views:
        day = v["timestamp"][:10]
        by_day[day] = {**blank, **by_day.get(day, {}), "date": day, "views": v["count"], "unique_views": v["uniques"]}
    for c in clones:
        day = c["timestamp"][:10]
        by_day[day] = {**blank, **by_day.get(day, {}), "date": day, "clones": c["count"], "unique_clones": c["uniques"]}
    rows = [by_day[d] for d in sorted(by_day)]
    write_csv(path, ["date", "views", "unique_views", "clones", "unique_clones"], rows)
    return rows


README = """# Dashbar stats

Written daily by `.github/workflows/stats.yml` on `main` (the script is `scripts/stats.py`).

- `downloads.csv`: DMG downloads per release so far, as GitHub reports them, one snapshot per day.
  The site's Download button, Homebrew and Sparkle updates all fetch these files, so they are all counted,
  including your own test installs and updates. Downloads, not people.
- `traffic.csv`: repo views and clones per day (only when the `TRAFFIC_TOKEN` secret is set).

The app sends nothing; these are numbers GitHub already keeps.
"""


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: stats.py <folder>")
    folder = sys.argv[1]
    os.makedirs(folder, exist_ok=True)
    today = dt.datetime.now(dt.timezone.utc).date().isoformat()

    counts = release_downloads(os.environ.get("GH_TOKEN"))
    previous = save_downloads(folder, today, counts)

    traffic_note = "Traffic skipped: add a `TRAFFIC_TOKEN` secret to save views and clones."
    traffic_token = os.environ.get("TRAFFIC_TOKEN")
    if traffic_token:
        try:
            rows = save_traffic(folder, traffic_token)
            last14 = rows[-14:]
            traffic_note = (f"Last 14 days: {sum(int(r['views']) for r in last14)} views, "
                            f"{sum(int(r['clones']) for r in last14)} clones.")
        except urllib.error.HTTPError as e:
            traffic_note = f"Traffic skipped: GitHub said {e.code} (the token needs push access to the repo)."

    readme = os.path.join(folder, "README.md")
    if not os.path.exists(readme):
        with open(readme, "w") as f:
            f.write(README)

    total, before = sum(counts.values()), sum(previous.values())
    lines = [f"## Dashbar downloads, {today}", "",
             f"**{total}** DMG downloads in all" + (f" (+{total - before} since the last snapshot)" if previous else ""), "",
             "| Release | Downloads | New |", "|---|---:|---:|"]
    for tag in sorted(counts, key=version_key, reverse=True):
        new = counts[tag] - previous.get(tag, 0) if previous else 0
        lines.append(f"| {tag} | {counts[tag]} | {'+' + str(new) if new else ''} |")
    lines += ["", traffic_note, ""]
    summary = "\n".join(lines)
    print(summary)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
            f.write(summary)


if __name__ == "__main__":
    main()
