import { useState } from "react";
import { Onboarding } from "./components/Onboarding";
import { HistoryList } from "./components/HistoryList";
import { HotkeySetting } from "./components/HotkeySetting";
import { EngineSettings } from "./components/EngineSettings";

export default function App() {
  const [ready, setReady] = useState(false);
  if (!ready) return <Onboarding onReady={() => setReady(true)} />;
  return (
    <div>
      <EngineSettings />
      <HotkeySetting />
      <HistoryList />
    </div>
  );
}
