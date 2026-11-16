import "@fontsource-variable/instrument-sans";
import "@fontsource-variable/jetbrains-mono";
import { Composition } from "remotion";
import { Launch } from "./Launch";
import { StillMenuBar, StillNotch, StillWindow } from "./Stills";
import { DURATION_SEC, FPS, HEIGHT, WIDTH } from "./constants";

export const Root = () => (
  <>
    <Composition id="Launch" component={Launch} durationInFrames={DURATION_SEC * FPS} fps={FPS} width={WIDTH} height={HEIGHT} />
    <Composition id="still-menubar" component={StillMenuBar} durationInFrames={1} fps={FPS} width={WIDTH} height={HEIGHT} />
    <Composition id="still-notch" component={StillNotch} durationInFrames={1} fps={FPS} width={WIDTH} height={HEIGHT} />
    <Composition id="still-window" component={StillWindow} durationInFrames={1} fps={FPS} width={WIDTH} height={HEIGHT} />
  </>
);
