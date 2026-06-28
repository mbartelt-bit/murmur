import ReactDOM from "react-dom/client";
import { Hud } from "./components/Hud";
import { startDictationPersistence } from "./lib/persist";

ReactDOM.createRoot(document.getElementById("hud")!).render(<Hud />);
startDictationPersistence();
