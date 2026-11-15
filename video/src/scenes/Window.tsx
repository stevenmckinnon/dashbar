import { AbsoluteFill, Img, useCurrentFrame } from "remotion";
import { C, FONT, shot } from "../constants";
import { Glow, Sweep, Words } from "../components/Kit";
import { EASE, SPRINGS, blurCss, pop, ramp } from "../utils/animations";

const W = 1500, H = (1520 / 2200) * W; // history.png, an on-screen capture of the window at 2x
const X = (1920 - W) / 2, Y = 190;

export const Window = () => {
  const f = useCurrentFrame();
  const fly = pop(f, 0.15, { damping: 200, stiffness: 90, mass: 1.6 });
  const push = 1 + 0.05 * ramp(f, 0.4, 3.4, 0, 1, EASE.drift);
  const out = ramp(f, 3.6, 0.45, 0, 1, EASE.dramatic);
  const key = pop(f, 0.8, SPRINGS.gentle);
  const textOut = ramp(f, 3.4, 0.3, 0, 1, EASE.exit);
  return (
    <AbsoluteFill>
      <Glow x={960} y={760} w={1500} h={620} color={C.accent} opacity={0.32 * fly * (1 - out)} hz={0.4} />
      <div style={{ position: "absolute", inset: 0, perspective: 2200, perspectiveOrigin: "50% 20%" }}>
        <div style={{ position: "absolute", left: X, top: Y, width: W, height: H, borderRadius: 26, overflow: "hidden",
          boxShadow: `0 0 0 1px ${C.hairline}, 0 50px 120px rgba(0,0,0,0.6)`,
          opacity: Math.min(1, fly * 1.5) * (1 - out),
          transform: `translateY(${260 * (1 - fly) - 200 * out}px) rotateX(${34 * (1 - fly)}deg) scale(${(0.72 + 0.28 * fly) * push * (1 - 0.9 * out)})`,
          transformOrigin: "50% 30%", filter: blurCss((1 - fly) * 20 + out * 16) }}>
          <Img src={shot("history")} style={{ width: W, height: H, display: "block" }} />
          <Sweep delay={1.6} dur={0.9} opacity={0.1} />
        </div>
      </div>
      <div style={{ position: "absolute", left: 150, top: 62, display: "flex", alignItems: "center", gap: 28,
        opacity: 1 - textOut, filter: blurCss(textOut * 10) }}>
        <Words text="Or open the whole window." delay={0.4} size={72} stagger={0.06} />
        <div style={{ fontFamily: FONT, fontSize: 34, fontWeight: 600, color: C.primary, padding: "8px 18px", borderRadius: 12,
          boxShadow: `inset 0 0 0 1.5px rgba(255,255,255,0.25)`, opacity: Math.min(1, key * 2), transform: `scale(${0.6 + 0.4 * key})`,
          filter: blurCss((1 - Math.min(1, key)) * 6) }}>⌃⌥D</div>
      </div>
    </AbsoluteFill>
  );
};
