import type { CSSProperties } from "react";
import { Easing, interpolate, spring } from "remotion";
import { FPS } from "../constants";

export const EASE = {
  snappy: Easing.bezier(0.16, 1, 0.3, 1),
  glide: Easing.bezier(0.25, 0.1, 0.25, 1),
  dramatic: Easing.bezier(0.7, 0, 0.3, 1),
  drift: Easing.bezier(0.4, 0, 0.6, 1),
  exit: Easing.bezier(0.55, 0, 0.75, 0.3),
};

/** A blur filter, or none at zero (a leftover blur(0) makes Chrome rasterise before transforming, which softens text). */
export const blurCss = (px: number) => (px > 0.05 ? `blur(${px}px)` : undefined);

const clamp = { extrapolateLeft: "clamp", extrapolateRight: "clamp" } as const;

/** from → to between two times in seconds. */
export const ramp = (f: number, startSec: number, durSec: number, from: number, to: number, easing = EASE.snappy) =>
  interpolate(f, [startSec * FPS, (startSec + durSec) * FPS], [from, to], { ...clamp, easing });

export const SPRINGS = {
  precise: { damping: 200, stiffness: 300, mass: 1 },
  heavy: { damping: 200, stiffness: 80, mass: 2 },
  gentle: { damping: 12, stiffness: 220, mass: 0.6 },
  slam: { damping: 15, stiffness: 300, mass: 0.8 },
};

/** 0 → 1 spring that starts at delaySec. */
export const pop = (f: number, delaySec: number, config: Partial<typeof SPRINGS.precise> = SPRINGS.precise) =>
  f < delaySec * FPS ? 0 : spring({ frame: f - delaySec * FPS, fps: FPS, config });

/** Ambient sine, for drift and pulse. */
export const wave = (f: number, hz: number, phase = 0) => Math.sin((f / FPS) * hz * Math.PI * 2 + phase);

/** An entrance (opacity + translate + blur + scale) and an optional compound exit, as one style. */
export const enter = (
  f: number, delaySec: number,
  { y = 30, x = 0, blur = 10, scale = 0.97, dur = 0.55, out, outDur = 0.35, outY = 0, outX = 0 }:
  { y?: number; x?: number; blur?: number; scale?: number; dur?: number; out?: number; outDur?: number; outY?: number; outX?: number } = {},
): CSSProperties => {
  const p = ramp(f, delaySec, dur, 0, 1);
  const q = out === undefined ? 0 : ramp(f, out, outDur, 0, 1, EASE.exit);
  return {
    opacity: Math.min(ramp(f, delaySec, dur * 0.6, 0, 1), 1 - q),
    transform: `translate(${(1 - p) * x + q * outX}px, ${(1 - p) * y + q * outY}px) scale(${scale + (1 - scale) * p - q * 0.03})`,
    filter: blurCss((1 - p) * blur + q * 10),
  };
};

/** A whole scene's compound exit: opacity + scale + blur. */
export const sceneExit = (f: number, startSec: number, durSec = 0.35, toScale = 0.96, blur = 12): CSSProperties => {
  const q = ramp(f, startSec, durSec, 0, 1, EASE.exit);
  if (q <= 0) return {};
  return { opacity: 1 - q, transform: `scale(${1 + (toScale - 1) * q})`, filter: blurCss(q * blur) };
};
