# Dashbar stats

Written daily by `.github/workflows/stats.yml` on `main` (the script is `scripts/stats.py`).

- `downloads.csv`: DMG downloads per release so far, as GitHub reports them, one snapshot per day.
  The site's Download button, Homebrew and Sparkle updates all fetch these files, so they are all counted,
  including your own test installs and updates. Downloads, not people.
- `traffic.csv`: repo views and clones per day (only when the `TRAFFIC_TOKEN` secret is set).

The app sends nothing; these are numbers GitHub already keeps.
