import "@fontsource-variable/instrument-sans";
import "@fontsource-variable/jetbrains-mono";
import { Composition } from "remotion";
import { Launch } from "./Launch";
import { DURATION_SEC, FPS, HEIGHT, WIDTH } from "./constants";

export const Root = () => (
  <Composition id="Launch" component={Launch} durationInFrames={DURATION_SEC * FPS} fps={FPS} width={WIDTH} height={HEIGHT} />
);
