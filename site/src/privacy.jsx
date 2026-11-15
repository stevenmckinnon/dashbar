import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import "@fontsource-variable/instrument-sans";
import "./styles.css";
import PrivacyPage from "./PrivacyPage.jsx";

createRoot(document.getElementById("root")).render(
  <StrictMode>
    <PrivacyPage />
  </StrictMode>,
);
