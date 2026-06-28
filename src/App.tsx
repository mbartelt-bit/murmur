import { useState } from "react";
import { Onboarding } from "./components/Onboarding";
import { HistoryList } from "./components/HistoryList";

export default function App() {
  const [ready, setReady] = useState(false);
  if (!ready) return <Onboarding onReady={() => setReady(true)} />;
  return <HistoryList />;
}
