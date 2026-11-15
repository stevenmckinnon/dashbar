import { AbsoluteFill, Sequence, useCurrentFrame } from "remotion";
import { FPS } from "../constants";
import { C, FONT, shot } from "../constants";
import { Crop, Glow, Ground, Patch, Sub, Words } from "../components/Kit";
import { EASE, blurCss, enter, ramp } from "../utils/animations";

// In 2x layout units (the shots are 4x). The cards are x 24–816 with a 40-unit corner radius, as the app draws them.
const CARD = { x: 24, w: 792, radius: 40 };
// Rows are cut from one image and overlap the next by 2 units, so a fractional scale never opens a seam.
// A plain stretch of card colour (right of the "Dev servers" title), laid over rows to dim them.
const PLAIN = { x: 420, y: 185, w: 360, h: 50 };
// servers.png 840 × 740: the card is y 172–595; header, then four rows (2 and 4 are "Barely used").
const SERVER_CUTS = [172, 252, 335, 416, 497, 595];
const IDLE = [2, 4];
// cleanup.png 840 × 888: six rows.
const CLEAN_CUTS = [252, 323, 393, 463, 533, 603, 676];
const WIPE = 2.6;

const ServersBeat = () => {
  const f = useCurrentFrame();
  const S = 1.25;
  const dim = ramp(f, 1.2, 0.4, 0, 1);
  const push = 1 + 0.03 * ramp(f, 0, 2.9, 0, 1, EASE.drift);
  const leave = ramp(f, WIPE, 0.4, 0, 1, EASE.exit);
  return (
    <AbsoluteFill style={{ transform: `translateY(${-40 * leave}px)`, filter: blurCss(leave * 8) }}>
      <Glow x={640} y={640} w={900} h={500} color="#9FC3CF" opacity={0.16 * dim} />
      <div style={{ position: "absolute", left: 140, top: 290, transform: `scale(${push})`, transformOrigin: "0 50%",
        borderRadius: CARD.radius * S, overflow: "hidden" }}>
        {SERVER_CUTS.slice(0, -1).map((y, i) => {
          const busy = i > 0 && !IDLE.includes(i);
          return (
            <div key={i} style={{ position: "relative", ...enter(f, 0.05 + i * 0.09, { y: 28, blur: 8, scale: 1, dur: 0.5 }) }}>
              <Crop src={shot("servers")} sw={840} sh={740} x={CARD.x} y={y} w={CARD.w} h={SERVER_CUTS[i + 1] - y + (i < SERVER_CUTS.length - 2 ? 2 : 0)} scale={S}
                style={{ marginBottom: i < SERVER_CUTS.length - 2 ? -Math.round(2 * S) : 0 }} />
              {busy && <Patch src={shot("servers")} sw={840} sh={740} {...PLAIN} style={{ opacity: 0.72 * dim }} />}
            </div>
          );
        })}
      </div>
      <div style={{ position: "absolute", left: 1200, top: 400, width: 620 }}>
        <Words text="Idle servers, spotted." delay={0.2} size={76} stagger={0.06} />
        <Sub delay={0.55} size={32} style={{ marginTop: 24 }}>Up for hours, barely used. Marked under the project that owns it.</Sub>
      </div>
    </AbsoluteFill>
  );
};

const CleanupBeat = () => {
  const f = useCurrentFrame();
  const S = 1.05;
  const n = ramp(f, 0.1, 0.9, 0, 7);
  const num = ramp(f, 0.1, 0.7, 0, 1);
  return (
    <AbsoluteFill>
      <Glow x={430} y={540} w={800} h={560} color="#9FC3CF" opacity={0.18} seed={1.3} />
      <div style={{ position: "absolute", left: 150, top: 300, fontFamily: FONT }}>
        <div style={{ fontSize: 240, fontWeight: 600, letterSpacing: "-0.05em", lineHeight: 0.9, color: C.primary, fontVariantNumeric: "tabular-nums",
          opacity: num, transform: `scale(${0.9 + 0.1 * num})`, filter: blurCss((1 - num) * 12), transformOrigin: "0 80%" }}>
          {n.toFixed(n < 7 ? 1 : 0)} GB
        </div>
        <Sub delay={0.4} size={40} style={{ marginTop: 18 }}>of caches you can rebuild</Sub>
      </div>
      <div style={{ position: "absolute", left: 960, top: 270, borderRadius: CARD.radius * S, overflow: "hidden" }}>
        {CLEAN_CUTS.slice(0, -1).map((y, i) => (
          <div key={i} style={{ ...enter(f, 0.15 + i * 0.08, { x: 60, y: 0, blur: 8, scale: 1, dur: 0.5 }) }}>
            <Crop src={shot("cleanup")} sw={840} sh={888} x={CARD.x} y={y} w={CARD.w} h={CLEAN_CUTS[i + 1] - y + (i < CLEAN_CUTS.length - 2 ? 2 : 0)} scale={S}
              style={{ marginBottom: i < CLEAN_CUTS.length - 2 ? -Math.round(2 * S) : 0 }} />
          </div>
        ))}
      </div>
      <Sub delay={1.3} size={30} style={{ position: "absolute", left: 960, top: 790 }}>Moved to the Trash, only after you confirm.</Sub>
    </AbsoluteFill>
  );
};

export const ServersCleanup = () => {
  const f = useCurrentFrame();
  const wipe = ramp(f, WIPE, 0.35, 0, 1, EASE.dramatic);
  const out = ramp(f, 5.1, 0.3, 0, 1, EASE.exit);
  return (
    <AbsoluteFill style={{ opacity: 1 - out, filter: blurCss(out * 12), transform: `scale(${1 - 0.03 * out})` }}>
      {wipe < 1 && <ServersBeat />}
      {wipe > 0 && (
        <AbsoluteFill style={{ clipPath: `inset(${(1 - wipe) * 100}% 0 0 0)` }}>
          <Ground />
          <Sequence from={Math.round(WIPE * FPS)} layout="none"><CleanupBeat /></Sequence>
        </AbsoluteFill>
      )}
    </AbsoluteFill>
  );
};

