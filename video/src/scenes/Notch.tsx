import { AbsoluteFill, interpolate, spring, useCurrentFrame } from "remotion";
import { C, FPS, shot } from "../constants";
import { Crop, Glow, Ring, Sub, Words } from "../components/Kit";
import { blurCss, ramp } from "../utils/animations";

// island-perm.png, in 2x layout units (it is rendered at 4x): the island spans x 594–1326 and y 0–496, its content from (612, 66).
const S = 1.3;
const FULL_W = 732 * S, FULL_H = 496 * S;
const CONTENT_X = 960 - FULL_W / 2 + 18 * S, CONTENT_Y = 66 * S;
const ALLOW = { x: CONTENT_X + (725 - 612) * S, y: CONTENT_Y + (424 - 66) * S };
const PRESS = 2.5, CLOSE = 3.2;

export const Notch = () => {
  const f = useCurrentFrame();
  const open = spring({ frame: f, fps: FPS, config: { damping: 20, stiffness: 120, mass: 1 } });
  const close = f < CLOSE * FPS ? 0 : spring({ frame: f - CLOSE * FPS, fps: FPS, config: { damping: 22, stiffness: 170 } });
  const p = Math.max(0, open - close);
  const w = interpolate(p, [0, 1], [220, FULL_W]);
  const h = interpolate(p, [0, 1], [40, FULL_H]);
  const r = interpolate(p, [0, 1], [18, 44]);
  const content = Math.min(ramp(f, 0.35, 0.45, 0, 1), interpolate(p, [0.55, 0.9], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp" }));
  const pressed = f >= PRESS * FPS && f < (PRESS + 0.2) * FPS;
  const glow = 0.35 * ramp(f, 0.3, 0.5, 0, 1) * ramp(f, PRESS, 0.4, 1, 0);
  const drift = 12 * ramp(f, 0, 4.6, 0, 1);
  return (
    <AbsoluteFill style={{ transform: `translateY(${drift}px)` }}>
      <Glow x={960} y={FULL_H - 40} w={1100} h={320} color={C.amber} opacity={glow} hz={0.8} drift={10} />
      <div style={{ position: "absolute", left: 960 - w / 2, top: -drift, width: w, height: h + drift, background: "#000",
        borderBottomLeftRadius: r, borderBottomRightRadius: r, overflow: "hidden", boxShadow: `0 0 0 1px rgba(255,255,255,${0.06 * p})` }} />
      <div style={{ position: "absolute", left: CONTENT_X, top: CONTENT_Y, opacity: content,
        filter: blurCss((1 - content) * 10), transform: `translateY(${(1 - content) * -20}px)` }}>
        <Crop src={shot("island-perm")} sw={1920} sh={640} x={612} y={66} w={696} h={412} scale={S} />
        <div style={{ position: "absolute", left: (646 - 612) * S, top: (400 - 66) * S, width: 159 * S, height: 48 * S,
          borderRadius: 24 * S, background: "#000", opacity: pressed ? 0.3 : 0 }} />
      </div>
      <Ring x={ALLOW.x} y={ALLOW.y} delay={PRESS} from={10} to={130} color="#fff" dur={0.6} opacity={0.6} />
      <div style={{ position: "absolute", left: 0, width: 1920, top: 730 }}>
        <Words text="Answer it from the notch." delay={0.6} size={76} align="center" stagger={0.06} out={4.2} />
        <Sub delay={0.9} out={4.2} style={{ textAlign: "center", marginTop: 22 }}>Allow once or deny. Dashbar never answers by itself.</Sub>
      </div>
    </AbsoluteFill>
  );
};
