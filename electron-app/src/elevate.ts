/**
 * Admin-elevation check + relaunch, the in-app equivalent of the old
 * Run-AsAdmin*.bat files. UIPI (User Interface Privilege Isolation) blocks a
 * normal-integrity process from reading text out of elevated apps (Task
 * Manager, Registry Editor, anything launched "As Administrator") -- running
 * elevated lifts that, same reason the PowerShell scripts needed it.
 */
import { spawn, spawnSync } from "child_process";
import { app } from "electron";

export function isElevated(): boolean {
  // `net session` only succeeds (exit 0) when run from an elevated process --
  // a standard, dependency-free way to check integrity level on Windows.
  const result = spawnSync("net", ["session"], { stdio: "ignore", windowsHide: true });
  return result.status === 0;
}

/** Relaunch this exact app elevated (UAC prompt), then quit the current instance. */
export function relaunchElevated(): void {
  const exe = process.execPath; // electron.exe in dev, the packaged app's exe once built
  const args = process.defaultApp ? [app.getAppPath()] : [];
  const argString = args.map((a) => `'${a.replace(/'/g, "''")}'`).join(",");
  const psCommand =
    `Start-Process -FilePath '${exe.replace(/'/g, "''")}'` +
    (argString ? ` -ArgumentList ${argString}` : "") +
    " -Verb RunAs";
  spawn("powershell", ["-NoProfile", "-Command", psCommand], { detached: true, stdio: "ignore" }).unref();
  app.quit();
}
