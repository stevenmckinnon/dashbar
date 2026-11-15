import type { CSSProperties, ReactNode } from "react";
import { AbsoluteFill, Img, useCurrentFrame } from "remotion";
import { C, FONT } from "../constants";
import { EASE, blurCss, pop, ramp, wave, SPRINGS } from "../utils/animations";

/** A crop of a snapshot. x, y, w, h are in the source image's pixels. */
export const Crop = ({ src, sw, sh, x, y, w, h, scale, style }: {
  src: string; sw: number; sh: number; x: number; y: number; w: number; h: number; scale: number; style?: CSSProperties;
}) => {
  // Snapped to whole pixels from the image's origin, so crops cut from one image (rows of a card) meet without seams.
  const left = Math.round(x * scale), top = Math.round(y * scale);
  return (
    <div style={{ width: Math.round((x + w) * scale) - left, height: Math.round((y + h) * scale) - top, overflow: "hidden", position: "relative", ...style }}>
      <Img src={src} style={{ position: "absolute", left: -left, top: -top, width: sw * scale, height: sh * scale, maxWidth: "none" }} />
    </div>
  );
};

/** Stretches one region of a snapshot over a box. Used to lay a card's own colour over part of it. */
export const Patch = ({ src, sw, sh, x, y, w, h, style }: {
  src: string; sw: number; sh: number; x: number; y: number; w: number; h: number; style?: CSSProperties;
}) => (
  <div style={{ position: "absolute", inset: 0, overflow: "hidden", ...style }}>
    <Img src={src} style={{ position: "absolute", left: `${(-x / w) * 100}%`, top: `${(-y / h) * 100}%`,
      width: `${(sw / w) * 100}%`, height: `${(sh / h) * 100}%`, maxWidth: "none" }} />
  </div>
);

/** A soft light in a scene's meaning colour. Drifts and breathes. */
export const Glow = ({ x, y, w, h = w, color, opacity, hz = 0.5, drift = 24, seed = 0 }: {
  x: number; y: number; w: number; h?: number; color: string; opacity: number; hz?: number; drift?: number; seed?: number;
}) => {
  const f = useCurrentFrame();
  const dx = wave(f, 0.11, seed) * drift, dy = wave(f, 0.09, seed + 1.7) * drift;
  const breathe = 1 + wave(f, hz, seed) * 0.08;
  return (
    <div style={{ position: "absolute", left: x - w / 2 + dx, top: y - h / 2 + dy, width: w, height: h, borderRadius: "50%",
      background: `radial-gradient(closest-side, ${color}, transparent)`, opacity: opacity * breathe, filter: "blur(40px)",
      pointerEvents: "none" }} />
  );
};

/** The ground every scene sits on: ink with a faint vignette that drifts. */
export const Ground = () => {
  const f = useCurrentFrame();
  const cx = 50 + wave(f, 0.05) * 6;
  return <AbsoluteFill style={{ background: `radial-gradient(120% 90% at ${cx}% 40%, #0E1A1E 0%, ${C.bg} 60%, #050B0D 100%)` }} />;
};

/** Film grain, topmost. */
export const Grain = () => (
  <AbsoluteFill style={{ mixBlendMode: "overlay", opacity: 0.07, pointerEvents: "none" }}>
    <svg width="100%" height="100%">
      <filter id="grain"><feTurbulence type="fractalNoise" baseFrequency="0.9" numOctaves="2" stitchTiles="stitch" /></filter>
      <rect width="100%" height="100%" filter="url(#grain)" />
    </svg>
  </AbsoluteFill>
);

/** Kinetic headline: each word rises out of a blur, staggered. `slam` gives a stiff scale spring instead. */
export const Words = ({ text, delay, size, color = C.primary, stagger = 0.07, weight = 600, slam = false, out, align = "left", style }: {
  text: string; delay: number; size: number; color?: string; stagger?: number; weight?: number; slam?: boolean;
  out?: number; align?: CSSProperties["textAlign"]; style?: CSSProperties;
}) => {
  const f = useCurrentFrame();
  const words = text.split(" ");
  const q = out === undefined ? 0 : ramp(f, out, 0.3, 0, 1, EASE.exit);
  return (
    <div style={{ fontFamily: FONT, fontSize: size, fontWeight: weight, letterSpacing: "-0.03em", lineHeight: 1.04, color,
      textAlign: align, opacity: 1 - q, filter: q ? `blur(${q * 10}px)` : undefined, transform: `translateY(${q * -24}px)`, ...style }}>
      {words.map((w, i) => {
        const d = delay + i * stagger;
        const p = slam ? pop(f, d, SPRINGS.slam) : ramp(f, d, 0.55, 0, 1);
        const o = ramp(f, d, slam ? 0.12 : 0.3, 0, 1);
        const t = slam ? `scale(${1.35 - 0.35 * p})` : `translateY(${(1 - p) * 0.45 * size}px)`;
        return (
          <span key={i} style={{ display: "inline-block", whiteSpace: "pre", opacity: o, transform: t, filter: blurCss((1 - Math.min(1, p)) * 10),
            transformOrigin: "50% 70%" }}>
            {w}{i < words.length - 1 ? " " : ""}
          </span>
        );
      })}
    </div>
  );
};

/** Supporting line: rises and sharpens. */
export const Sub = ({ children, delay, size = 34, out, style }: { children: ReactNode; delay: number; size?: number; out?: number; style?: CSSProperties }) => {
  const f = useCurrentFrame();
  const p = ramp(f, delay, 0.55, 0, 1);
  const q = out === undefined ? 0 : ramp(f, out, 0.3, 0, 1, EASE.exit);
  return (
    <div style={{ fontFamily: FONT, fontSize: size, lineHeight: 1.35, color: C.muted, textWrap: "pretty",
      opacity: Math.min(p, 1 - q), transform: `translateY(${(1 - p) * 20 - q * 20}px)`, filter: blurCss((1 - p) * 8 + q * 10), ...style }}>
      {children}
    </div>
  );
};

/** An expanding ring, for impact moments. */
export const Ring = ({ x, y, delay, from = 20, to = 260, color, width = 3, dur = 0.9, opacity = 0.7 }: {
  x: number; y: number; delay: number; from?: number; to?: number; color: string; width?: number; dur?: number; opacity?: number;
}) => {
  const f = useCurrentFrame();
  const p = ramp(f, delay, dur, 0, 1);
  if (p <= 0 || p >= 1) return null;
  const r = from + (to - from) * p;
  return <div style={{ position: "absolute", left: x - r, top: y - r, width: r * 2, height: r * 2, borderRadius: "50%",
    border: `${width}px solid ${color}`, opacity: opacity * (1 - p) }} />;
};

/** A diagonal light sweep across a box. */
export const Sweep = ({ delay, dur = 0.8, opacity = 0.08 }: { delay: number; dur?: number; opacity?: number }) => {
  const f = useCurrentFrame();
  const p = ramp(f, delay, dur, 0, 1, EASE.glide);
  if (p <= 0 || p >= 1) return null;
  return (
    <AbsoluteFill style={{ overflow: "hidden", pointerEvents: "none" }}>
      <div style={{ position: "absolute", top: "-20%", bottom: "-20%", width: 320, left: `${-25 + p * 150}%`, transform: "skewX(-18deg)",
        background: `linear-gradient(90deg, transparent, rgba(255,255,255,${opacity}), transparent)` }} />
    </AbsoluteFill>
  );
};
