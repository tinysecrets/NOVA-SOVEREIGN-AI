import axios from "axios";

const BACKEND_URL = import.meta.env.VITE_BACKEND_URL || "http://127.0.0.1:8000";
export const API = `${BACKEND_URL}/api`;

const http = axios.create({ baseURL: API, timeout: 120000 });

export const api = {
  getSettings: () => http.get("/settings").then((r) => r.data),
  saveSettings: (body) => http.post("/settings", body).then((r) => r.data),
  getModels: () => http.get("/models").then((r) => r.data),
  chat: (body) => http.post("/chat", body).then((r) => r.data),
  getSessions: () => http.get("/sessions").then((r) => r.data),
  getHistory: (id) => http.get(`/history/${id}`).then((r) => r.data),
  plan: (body) => http.post("/agents/plan", body).then((r) => r.data),
  dispatch: (body) => http.post("/agents/dispatch", body).then((r) => r.data),
  critic: (body) => http.post("/agents/critic", body).then((r) => r.data),
  react: (body) => http.post("/agents/react", body).then((r) => r.data),
  runs: () => http.get("/agents/runs").then((r) => r.data),
  systemHealth: () => http.get("/system/health").then((r) => r.data),
  prove: () => http.post("/system/prove").then((r) => r.data),
};

/** Consume an SSE POST body; calls onEvent for each parsed JSON payload. */
export async function streamPost(path, body, onEvent, { signal } = {}) {
  const resp = await fetch(`${API}${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
    signal,
  });
  if (!resp.ok || !resp.body) {
    const text = await resp.text().catch(() => "");
    throw new Error(text || `HTTP ${resp.status}`);
  }
  const reader = resp.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    const chunks = buffer.split("\n\n");
    buffer = chunks.pop() || "";
    for (const chunk of chunks) {
      const line = chunk.replace(/^data:\s?/, "").trim();
      if (!line || line === "[DONE]") continue;
      let evt;
      try {
        evt = JSON.parse(line);
      } catch {
        continue;
      }
      onEvent(evt);
    }
  }
}

export function errText(e) {
  return e?.response?.data?.detail || e?.message || "Something went wrong";
}
