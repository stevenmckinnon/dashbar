import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import "@fontsource-variable/instrument-sans";
import "./stageshow/kit/stageshow.css";
import "./styles.css";
import App from "./App.jsx";

createRoot(document.getElementById("root")).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
