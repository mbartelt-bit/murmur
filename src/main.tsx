import React from "react";
import ReactDOM from "react-dom/client";
import App from "./App";
import "./index.css";

if (
  import.meta.env.DEV &&
  new URLSearchParams(location.search).has("preview")
) {
  const { installPreview } = await import("./preview");
  installPreview();
  const banner = document.createElement("div");
  banner.textContent = "UI preview · example data · recording disabled";
  banner.style.cssText =
    "background:#fff3cf;color:#534314;text-align:center;padding:6px;font-size:12px";
  document.body.prepend(banner);
}

ReactDOM.createRoot(document.getElementById("root") as HTMLElement).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
);
