import { AbsoluteFill, useCurrentFrame } from "remotion";
import { C, SYSTEM, shot } from "../constants";
import { Crop, Glow, Ring, Words } from "../components/Kit";
import { EASE, SPRINGS, blurCss, pop, ramp } from "../utils/animations";

// The menu bar, blown up 4x: 128 px tall, on the upper third line.
const BAR_Y = 300, BAR_H = 128, K = BAR_H / 144; // menubar.png rows are 144 px
const ITEM_X = 1100, ITEM_CX = ITEM_X + 65 * K, ITEM_CY = BAR_Y + BAR_H / 2;
const FLIP = 1.5;

export const Hook = () => {
  const f = useCurrentFrame();
  const sprite = { src: shot("menubar"), sw: 1800, sh: 1440, h: 144, scale: K };
  const strip = ramp(f, 0, 0.6, 0, 1);
  const out = ramp(f, 2.9, 0.3, 0, 1, EASE.exit);
  const push = 1 + 0.04 * ramp(f, 0, 3.2, 0, 1, EASE.drift) + 0.21 * out;
  const working = ramp(f, FLIP, 0.2, 0, 1);
  const hand = pop(f, FLIP, SPRINGS.gentle);
  return (
    <AbsoluteFill style={{ transform: `scale(${push})`, transformOrigin: `${ITEM_CX}px ${ITEM_CY}px`, opacity: 1 - out, filter: blurCss(out * 14) }}>
      <Glow x={ITEM_CX} y={ITEM_CY} w={760} h={560} color={C.amber} opacity={0.55 * ramp(f, FLIP, 0.5, 0, 1)} hz={1.2} drift={8} />
      <div style={{ position: "absolute", left: 0, top: BAR_Y, width: 1920, height: BAR_H, background: C.menubar,
        opacity: strip, transform: `scale(${1.12 - 0.12 * strip})`, filter: blurCss((1 - strip) * 14),
        boxShadow: `0 1px 0 ${C.hairline}`, fontFamily: SYSTEM, color: "rgba(255,255,255,0.92)" }}>
        <div style={{ position: "absolute", left: ITEM_X, top: 0 }}>
          <Crop {...sprite} x={60} y={432} w={400} style={{ position: "absolute", mixBlendMode: "lighten", clipPath: "inset(4px 0)", opacity: 1 - working,
            transform: `scale(${1 - 0.3 * working})`, filter: blurCss(working * 8), transformOrigin: `${65 * K}px ${BAR_H / 2}px` }} />
          <Crop {...sprite} x={60} y={720} w={300} style={{ position: "absolute", mixBlendMode: "lighten", clipPath: "inset(4px 0)", opacity: Math.min(1, hand * 2),
            transform: `scale(${0.4 + 0.6 * hand})`, transformOrigin: `${65 * K}px ${BAR_H / 2}px` }} />
        </div>
        <div style={{ position: "absolute", right: 90, top: 0, height: BAR_H, display: "flex", alignItems: "center", gap: 64, fontSize: 52, fontWeight: 500 }}>
          <svg width="66" height="48" viewBox="0 0 18 13" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round">
            <path d="M1.5 4.5a11 11 0 0 1 15 0M4.2 7.4a7 7 0 0 1 9.6 0M6.9 10.2a3 3 0 0 1 4.2 0" />
          </svg>
          <span>9:41</span>
        </div>
      </div>
      <Ring x={ITEM_CX} y={ITEM_CY} delay={FLIP} color={C.amber} />
      <div style={{ position: "absolute", left: 160, top: 520 }}>
        <Words text="Your agents are busy." delay={0.25} size={104} />
        <Words text="One needs you." delay={1.75} size={104} color={C.amber} slam stagger={0.06} />
      </div>
    </AbsoluteFill>
  );
};
