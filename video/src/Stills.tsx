import type { ReactNode } from "react";
import { AbsoluteFill, Img } from "remotion";
import { C, FONT, SYSTEM, shot } from "./constants";
import { Crop, Glow, Grain, Ground } from "./components/Kit";

// Gallery images for launch sites: 1920x1080 layouts, rendered with --scale=1.5 (2880x1620) so no picture is upscaled.

const Head = ({ title, sub, align = "left", width = 760 }: { title: ReactNode; sub: string; align?: "left" | "center"; width?: number }) => (
  <div style={{ fontFamily: FONT, width, textAlign: align }}>
    <div style={{ fontSize: 88, fontWeight: 600, letterSpacing: "-0.03em", lineHeight: 1.04, color: C.primary }}>{title}</div>
    <div style={{ marginTop: 28, fontSize: 34, lineHeight: 1.35, color: C.muted, textWrap: "pretty" }}>{sub}</div>
  </div>
);

const Frame = ({ children }: { children: ReactNode }) => (
  <AbsoluteFill>
    <Ground />
    {children}
    <Grain />
  </AbsoluteFill>
);

// The menu bar item, working, with the panel open under it.
const BAR_H = 64, K = BAR_H / 144; // menubar.png rows are 144 px at 6x
const ITEM_X = 1250, ITEM_CX = ITEM_X + 65 * K;
const PS = 940 / 2860; // overview.png at 4x, cropped above its bottom bar
const PW = 1680 * PS;

export const StillMenuBar = () => (
  <Frame>
    <Glow x={ITEM_CX} y={560} w={1100} h={900} color={C.accent} opacity={0.16} />
    <div style={{ position: "absolute", left: 0, top: 0, width: 1920, height: BAR_H, background: C.menubar,
      boxShadow: `0 1px 0 ${C.hairline}`, fontFamily: SYSTEM, color: "rgba(255,255,255,0.92)" }}>
      <div style={{ position: "absolute", left: ITEM_X, top: 0 }}>
        <Crop src={shot("menubar")} sw={1800} sh={1440} x={60} y={432} w={400} h={144} scale={K}
          style={{ mixBlendMode: "lighten", clipPath: "inset(2px 0)" }} />
      </div>
      <div style={{ position: "absolute", right: 48, top: 0, height: BAR_H, display: "flex", alignItems: "center", gap: 34, fontSize: 26, fontWeight: 500 }}>
        <svg width="33" height="24" viewBox="0 0 18 13" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round">
          <path d="M1.5 4.5a11 11 0 0 1 15 0M4.2 7.4a7 7 0 0 1 9.6 0M6.9 10.2a3 3 0 0 1 4.2 0" />
        </svg>
        <span>Sat 14 Nov  9:41</span>
      </div>
    </div>
    <div style={{ position: "absolute", left: ITEM_CX - PW / 2, top: BAR_H + 14, borderRadius: 20, overflow: "hidden",
      boxShadow: `0 0 0 1px ${C.hairline}, 0 40px 100px rgba(0,0,0,0.55)` }}>
      <Crop src={shot("overview")} sw={1680} sh={3064} x={0} y={0} w={1680} h={2860} scale={PS} />
    </div>
    <div style={{ position: "absolute", left: 140, top: 330 }}>
      <Head title="Your agents, in the menu bar" sub="Which Claude Code and Codex sessions are working, which one needs you, and how much of your plan is left." />
    </div>
  </Frame>
);

// A permission prompt at the notch.
export const StillNotch = () => (
  <Frame>
    <Glow x={960} y={330} w={1300} h={600} color={C.amber} opacity={0.14} />
    <div style={{ position: "absolute", left: 0, top: 0, width: 1920, height: 640,
      WebkitMaskImage: "linear-gradient(180deg, #000 72%, transparent)", maskImage: "linear-gradient(180deg, #000 72%, transparent)" }}>
      <Img src={shot("island-perm")} style={{ width: 1920, height: 640, display: "block" }} />
    </div>
    <div style={{ position: "absolute", left: 0, right: 0, top: 690, display: "flex", justifyContent: "center" }}>
      <Head align="center" width={1300} title="Answer from the notch"
        sub="When an agent stops to ask, the prompt shows up at the notch. Allow it once or deny it without finding the terminal." />
    </div>
  </Frame>
);

// The Dashbar window on a workspace's page.
const WW = 1500, WH = (1520 / 2200) * WW; // workspace.png, an on-screen capture at 2x

export const StillWindow = () => (
  <Frame>
    <Glow x={960} y={820} w={1600} h={640} color={C.accent} opacity={0.2} />
    <div style={{ position: "absolute", left: 150, top: 70, display: "flex", alignItems: "baseline", gap: 32 }}>
      <div style={{ fontFamily: FONT, fontSize: 72, fontWeight: 600, letterSpacing: "-0.03em", color: C.primary }}>Every workspace, in one window</div>
      <div style={{ fontFamily: FONT, fontSize: 34, fontWeight: 600, color: C.primary, padding: "8px 18px", borderRadius: 12,
        boxShadow: "inset 0 0 0 1.5px rgba(255,255,255,0.25)" }}>⌃⌥D</div>
    </div>
    <div style={{ position: "absolute", left: (1920 - WW) / 2, top: 210, width: WW, height: WH, borderRadius: 26, overflow: "hidden",
      boxShadow: `0 0 0 1px ${C.hairline}, 0 50px 120px rgba(0,0,0,0.6)` }}>
      <Img src={shot("workspace")} style={{ width: WW, height: WH, display: "block" }} />
    </div>
  </Frame>
);
