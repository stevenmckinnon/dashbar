// Dashbar's launch film ("Signal"). storyboard.json is the plan; each scene is in scenes/.
// Every picture of the app is a real render with invented demo data (scripts/shots.sh).
import { useEffect, useState, type ReactElement } from "react";
import { AbsoluteFill, Sequence, continueRender, delayRender } from "remotion";
import { FONT, FPS, MONO, TIMELINE } from "./constants";
import { Grain, Ground } from "./components/Kit";
import { Hook } from "./scenes/Hook";
import { Notch } from "./scenes/Notch";
import { Sessions } from "./scenes/Sessions";
import { Limits } from "./scenes/Limits";
import { ServersCleanup } from "./scenes/ServersCleanup";
import { Window } from "./scenes/Window";
import { Close } from "./scenes/Close";

const SCENES: [keyof typeof TIMELINE, () => ReactElement][] = [
  ["hook", Hook], ["notch", Notch], ["sessions", Sessions], ["limits", Limits],
  ["serversCleanup", ServersCleanup], ["window", Window], ["close", Close],
];

const useFonts = () => {
  const [handle] = useState(() => delayRender("fonts"));
  useEffect(() => {
    Promise.all([
      document.fonts.load(`600 80px ${FONT}`), document.fonts.load(`400 34px ${FONT}`), document.fonts.load(`500 30px ${MONO}`),
    ]).finally(() => continueRender(handle));
  }, [handle]);
};

export const Launch = () => {
  useFonts();
  return (
    <AbsoluteFill>
      <Ground />
      {SCENES.map(([key, Scene]) => {
        const { start, duration } = TIMELINE[key];
        return (
          <Sequence key={key} from={Math.round(start * FPS)} durationInFrames={Math.round(duration * FPS)} premountFor={FPS}>
            <Scene />
          </Sequence>
        );
      })}
      <Grain />
    </AbsoluteFill>
  );
};
