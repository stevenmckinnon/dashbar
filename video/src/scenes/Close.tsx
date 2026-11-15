import { AbsoluteFill, Img, useCurrentFrame } from "remotion";
import { C, FONT, MONO, shot } from "../constants";
import { Glow, Ring, Sub, Words } from "../components/Kit";
import { SPRINGS, blurCss, enter, pop } from "../utils/animations";

const BREW = "brew install --cask stevenmckinnon/tap/dashbar";

export const Close = () => {
  const f = useCurrentFrame();
  const icon = pop(f, 0, SPRINGS.gentle);
  const typed = Math.floor(Math.max(0, (f / 30 - 1.15) * 45));
  return (
    <AbsoluteFill style={{ alignItems: "center", fontFamily: FONT }}>
      <Glow x={960} y={300} w={760} h={520} color={C.accent} opacity={0.3 * Math.min(1, icon)} hz={0.5} drift={10} />
      <Ring x={960} y={300} delay={0.05} from={60} to={340} color={C.accent} opacity={0.5} dur={1} />
      <Img src={shot("icon")} style={{ position: "absolute", top: 210, width: 180, height: 180,
        opacity: Math.min(1, icon * 2), transform: `scale(${0.25 + 0.75 * icon})`, filter: blurCss(Math.max(0, 1 - icon) * 10) }} />
      <div style={{ position: "absolute", top: 440, width: 1920, textAlign: "center" }}>
        <Words text="Your agents, in the menu bar" delay={0.3} size={96} align="center" stagger={0.06} />
        <Sub delay={0.7} style={{ textAlign: "center", marginTop: 20 }}>Free and open source. For macOS.</Sub>
      </div>
      <div style={{ position: "absolute", top: 700, padding: "20px 32px", borderRadius: 16, background: C.surface,
        boxShadow: `inset 0 0 0 1px ${C.hairline}`, fontFamily: MONO, fontSize: 30, fontWeight: 500, color: C.primary,
        ...enter(f, 0.95, { y: 20, blur: 8, scale: 0.98, dur: 0.45 }) }}>
        <span style={{ color: C.muted }}>$ </span>
        <span>{BREW.slice(0, typed)}</span>
        <span style={{ visibility: "hidden" }}>{BREW.slice(typed)}</span>
      </div>
      <div style={{ position: "absolute", top: 830, fontSize: 44, fontWeight: 600, color: C.accent, letterSpacing: "-0.01em",
        ...enter(f, 1.9, { y: 18, blur: 8, scale: 0.98, dur: 0.5 }) }}>usedashbar.com</div>
    </AbsoluteFill>
  );
};
