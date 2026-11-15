import { AbsoluteFill, useCurrentFrame } from "remotion";
import { C, FONT } from "../constants";
import { Glow, Words } from "../components/Kit";
import { EASE, SPRINGS, enter, pop, ramp, sceneExit } from "../utils/animations";

// Values are the demo's (Demo.swift), as the Usage tab shows them.
const ROWS = [
  { tool: "Claude", window: "5-hour", reset: "resets in 2h 11m", used: 55, pace: 56, verdict: "At this rate, lasts until it resets", color: C.claude, y: 420, delay: 0.25, fill: 0.7, sheen: 3.0 },
  { tool: "Codex", window: "5-hour", reset: "resets in 3h 23m", used: 21, pace: 32, verdict: "At this rate, plenty left when it resets", color: C.codex, y: 690, delay: 0.4, fill: 1.0, sheen: 3.18 },
];
const X = 160, W = 1600, FILL_DUR = 1.1;

const Icon = ({ tool, color }: { tool: string; color: string }) => tool === "Claude"
  ? <svg width="40" height="40" viewBox="0 0 24 24" stroke={color} strokeWidth="2.6" strokeLinecap="round">
      {[0, 30, 60, 90, 120, 150].map((a) => <line key={a} x1="12" y1="2.5" x2="12" y2="21.5" transform={`rotate(${a} 12 12)`} />)}
    </svg>
  : <svg width="46" height="40" viewBox="0 0 28 24" fill="none" stroke={color} strokeWidth="2.6" strokeLinecap="round" strokeLinejoin="round">
      <path d="M8 6 2 12l6 6M20 6l6 6-6 6M16 3l-4 18" />
    </svg>;

const Row = ({ r }: { r: (typeof ROWS)[number] }) => {
  const f = useCurrentFrame();
  const g = ramp(f, r.fill, FILL_DUR, 0, 1, EASE.glide);
  const used = r.used * g;
  // The mark drops when the fill gets there, or when the fill stops short of it.
  const markAt = r.fill + FILL_DUR * Math.min(1, r.pace / r.used) * 0.75;
  const mark = pop(f, Math.min(markAt, r.fill + FILL_DUR), SPRINGS.gentle);
  const verdictAt = Math.min(markAt, r.fill + FILL_DUR) + 0.2;
  // A sheen that runs along this bar's fill only, once it has settled.
  const sheen = ramp(f, r.sheen, 0.75, 0, 1, EASE.glide);
  return (
    <div style={{ position: "absolute", left: X, top: r.y, width: W, ...enter(f, r.delay, { x: 140, y: 0, scale: 1, dur: 0.6 }) }}>
      <div style={{ display: "flex", alignItems: "center", gap: 18, fontFamily: FONT }}>
        <Icon tool={r.tool} color={r.color} />
        <span style={{ fontSize: 46, fontWeight: 600, color: C.primary, letterSpacing: "-0.02em" }}>{r.tool} · {r.window}</span>
        <span style={{ fontSize: 34, color: C.muted, marginLeft: 8 }}>{r.reset}</span>
        <span style={{ marginLeft: "auto", fontSize: 46, fontWeight: 600, color: C.primary, fontVariantNumeric: "tabular-nums" }}>
          {Math.round(used)}% used
        </span>
      </div>
      <div style={{ position: "relative", marginTop: 26, height: 22, borderRadius: 11, background: C.track }}>
        <div style={{ position: "absolute", left: 0, top: 0, bottom: 0, width: `${used}%`, borderRadius: 11, background: r.color,
          boxShadow: `0 0 28px ${r.color}55`, overflow: "hidden" }}>
          {sheen > 0 && sheen < 1 && (
            <div style={{ position: "absolute", top: 0, bottom: 0, width: 140, left: `calc(${sheen * 100}% + ${(sheen - 1) * 140}px)`,
              background: "linear-gradient(90deg, transparent, rgba(255,255,255,0.45), transparent)" }} />
          )}
        </div>
        <div style={{ position: "absolute", left: `calc(${r.pace}% - 3px)`, top: -11, width: 6, height: 44, borderRadius: 3, background: C.primary,
          opacity: Math.min(1, mark * 2), transform: `translateY(${(1 - mark) * -36}px)` }} />
      </div>
      <div style={{ marginTop: 22, fontFamily: FONT, fontSize: 32, color: C.muted, ...enter(f, verdictAt, { y: 14, blur: 8, scale: 1, dur: 0.45 }) }}>
        {r.verdict}
      </div>
    </div>
  );
};

export const Limits = () => {
  const f = useCurrentFrame();
  return (
    <AbsoluteFill style={sceneExit(f, 5.0, 0.4, 0.94)}>
      <Glow x={420} y={470} w={900} h={520} color={C.claude} opacity={0.22} seed={0.4} />
      <Glow x={1500} y={760} w={900} h={520} color={C.codex} opacity={0.2} seed={2.1} />
      <div style={{ position: "absolute", left: X, top: 150 }}>
        <Words text="See if you'll run out." delay={0} size={92} />
      </div>
      {ROWS.map((r) => <Row key={r.tool} r={r} />)}
    </AbsoluteFill>
  );
};
