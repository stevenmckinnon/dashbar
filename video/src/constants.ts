import { staticFile } from "remotion";

export const FPS = 30;
export const WIDTH = 1920;
export const HEIGHT = 1080;

// "Signal": the site's dark ink, and light only in the colour of what a scene is about.
export const C = {
  bg: "#081114",
  surface: "#121C20",
  primary: "#EEF3F5",
  muted: "#93A3A9",
  hairline: "rgba(255,255,255,0.10)",
  accent: "#4FD1E3",  // Dashbar's arc
  amber: "#F5B83D",   // needs you
  green: "#3DD16B",   // working
  claude: "#D97757",
  codex: "#22C3D6",
  track: "#2A3438",
  // Just lighter than the menu bar in menubar.png (38 as Chrome draws it): the item crops blend with "lighten",
  // so their background drops out and only the icon and text show.
  menubar: "rgb(41,41,42)",
};

export const FONT = '"Instrument Sans Variable", "Instrument Sans", sans-serif';
export const MONO = '"JetBrains Mono Variable", "JetBrains Mono", monospace';
export const SYSTEM = 'system-ui, -apple-system, sans-serif'; // only for the drawn macOS menu bar

// Panel and island shots are 4x renders, the menu bar 6x, the window a 2x on-screen capture. Crops are given in
// 2x layout units (the size each image would have at 2x), so the extra pixels only add detail.
export const shot = (name: string) => staticFile(`shots/${name}.png`);

// Seconds, from storyboard.json. Adjacent scenes overlap for their transitions.
export const TIMELINE = {
  hook: { start: 0, duration: 3.2 },
  notch: { start: 3.0, duration: 4.6 },
  sessions: { start: 7.4, duration: 4.8 },
  limits: { start: 12.0, duration: 5.4 },
  serversCleanup: { start: 17.2, duration: 5.4 },
  window: { start: 22.4, duration: 4.0 },
  close: { start: 26.2, duration: 3.8 },
};
export const DURATION_SEC = 30;
