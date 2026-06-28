import { useState } from "react";
import { Onboarding } from "./components/Onboarding";

export default function App() {
  const [ready, setReady] = useState(false);
  if (!ready) return <Onboarding onReady={() => setReady(true)} />;
  return <div className="p-8">Settings (coming next)</div>;
}
