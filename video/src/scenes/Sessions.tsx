import { AbsoluteFill, Img, useCurrentFrame } from "remotion";
import { C, shot } from "../constants";
import { Glow, Sub, Words } from "../components/Kit";
import { EASE, SPRINGS, blurCss, pop, ramp } from "../utils/animations";

const S = 0.9;               // overview.png is 840 × 1532 (2x)
const X = 1040, Y = 110, W = 840 * S;
const OUT = 4.4;

export const Sessions = () => {
  const f = useCurrentFrame();
  const rise = pop(f, 0, SPRINGS.heavy);
  const q = ramp(f, OUT, 0.4, 0, 1, EASE.exit);
  const scroll = -180 * ramp(f, 0.6, 4.2, 0, 1, EASE.drift);
  const rotY = -16 + 5 * ramp(f, 0, 4.4, 0, 1, EASE.drift) - 19 * q;
  const rotX = 30 - 24 * rise;
  return (
    <AbsoluteFill>
      <Glow x={X + 600} y={Y + 230} w={560} color={C.green} opacity={0.42 * rise * (1 - q)} hz={0.9} />
      <div style={{ position: "absolute", left: 0, top: 0, width: 1920, height: 1080, perspective: 1800, perspectiveOrigin: "70% 40%" }}>
        <div style={{ position: "absolute", left: X, top: Y, width: W, height: 1100, borderRadius: 22, overflow: "hidden",
          background: "rgb(46,46,46)", boxShadow: `0 0 0 1px ${C.hairline}, 0 40px 90px rgba(0,0,0,0.55)`,
          transform: `translate(${-260 * q}px, ${320 * (1 - rise)}px) rotateY(${rotY}deg) rotateX(${rotX}deg)`,
          transformOrigin: "50% 30%", opacity: Math.min(1, rise * 1.6) * (1 - q), filter: blurCss((1 - rise) * 16 + q * 12) }}>
          <div style={{ height: 1430 * S, overflow: "hidden", transform: `translateY(${scroll}px)` }}>
            <Img src={shot("overview")} style={{ width: W, height: 1532 * S, display: "block" }} />
          </div>
        </div>
      </div>
      <div style={{ position: "absolute", left: 150, top: 390, width: 940, transform: `translateX(${-80 * q}px)`, opacity: 1 - q, filter: blurCss(q * 12) }}>
        <Words text="Every session, by project." delay={0.3} size={76} />
        <Sub delay={0.7} style={{ marginTop: 28 }}>Working, idle or waiting for you, and how full each context window is.</Sub>
      </div>
    </AbsoluteFill>
  );
};
