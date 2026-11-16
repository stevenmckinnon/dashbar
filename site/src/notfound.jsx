import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import "@fontsource-variable/instrument-sans";
import "./styles.css";
import NotFoundPage from "./NotFoundPage.jsx";

createRoot(document.getElementById("root")).render(
  <StrictMode>
    <NotFoundPage />
  </StrictMode>,
);
