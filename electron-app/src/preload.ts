import { contextBridge, ipcRenderer } from "electron";

contextBridge.exposeInMainWorld("highlightReader", {
  onLog: (cb: (line: string) => void) => ipcRenderer.on("log", (_e, line) => cb(line)),
  onState: (cb: (state: string) => void) => ipcRenderer.on("state", (_e, state) => cb(state)),
  onSettings: (cb: (s: unknown) => void) => ipcRenderer.on("settings", (_e, s) => cb(s)),
  onAudioPlay: (cb: (buf: ArrayBuffer, volume: number) => void) =>
    ipcRenderer.on("audio:play", (_e, buf, volume) => cb(buf, volume)),
  onAudioStop: (cb: () => void) => ipcRenderer.on("audio:stop", () => cb()),
  audioEnded: () => ipcRenderer.send("audio:ended"),
  setSettings: (partial: Record<string, unknown>) => ipcRenderer.send("settings:set", partial),
  getSettings: () => ipcRenderer.invoke("settings:get"),
  listVoices: () => ipcRenderer.invoke("voices:list"),
  getElevationStatus: () => ipcRenderer.invoke("elevation:status"),
  relaunchElevated: () => ipcRenderer.send("elevation:relaunch"),
});
