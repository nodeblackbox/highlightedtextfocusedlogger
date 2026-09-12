/**
 * Talks to the persistent SelectionHelper.exe over stdin/stdout.
 *
 * Why a persistent child process instead of spawning fresh per hotkey press:
 * the v2/v4/v5 PowerShell scripts cache "which UIA element actually had the
 * selection" per foreground window so a repeat read in the same app is
 * instant. That cache lives in Program.cs's static Dictionary, so it only
 * helps if the process stays alive between hotkey presses.
 */
import { ChildProcessWithoutNullStreams, spawn } from "child_process";
import * as readline from "readline";

export interface SelectionResult {
  ok: boolean;
  text?: string;
  app?: string;
  reason?: string;
}

export class SelectionClient {
  private proc: ChildProcessWithoutNullStreams | null = null;
  private rl: readline.Interface | null = null;
  private pending: ((line: string) => void) | null = null;
  private readonly exePath: string;
  private readonly log: (msg: string) => void;

  constructor(exePath: string, log: (msg: string) => void = console.log) {
    this.exePath = exePath;
    this.log = log;
  }

  start(): void {
    if (this.proc) return;
    this.log(`selection-helper: starting ${this.exePath}`);
    this.proc = spawn(this.exePath, [], { windowsHide: true });
    this.rl = readline.createInterface({ input: this.proc.stdout });
    this.rl.on("line", (line) => {
      const cb = this.pending;
      this.pending = null;
      if (cb) cb(line);
    });
    this.proc.stderr.on("data", (d) => this.log(`selection-helper stderr: ${d}`));
    this.proc.on("exit", (code, signal) => {
      this.log(`selection-helper exited (code=${code}, signal=${signal})`);
      this.proc = null;
      this.rl = null;
      // If something was waiting on a response that will never arrive, unblock it.
      const cb = this.pending;
      this.pending = null;
      if (cb) cb(JSON.stringify({ ok: false, reason: "helper-crashed" }));
    });
  }

  stop(): void {
    this.rl?.close();
    this.proc?.kill();
    this.proc = null;
    this.rl = null;
  }

  /** One request in flight at a time -- matches the helper's simple line protocol. */
  private send(command: string, timeoutMs = 3000): Promise<string> {
    if (!this.proc || !this.proc.stdin.writable) {
      this.start();
    }
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        if (this.pending === onLine) {
          this.pending = null;
          resolve(JSON.stringify({ ok: false, reason: "timeout" }));
        }
      }, timeoutMs);
      const onLine = (line: string) => {
        clearTimeout(timer);
        resolve(line);
      };
      this.pending = onLine;
      this.proc!.stdin.write(command + "\n");
    });
  }

  async getSelection(): Promise<SelectionResult> {
    const line = await this.send("get");
    try {
      return JSON.parse(line) as SelectionResult;
    } catch {
      return { ok: false, reason: "bad-response" };
    }
  }

  async ping(): Promise<boolean> {
    try {
      const line = await this.send("ping", 1500);
      return JSON.parse(line)?.pong === true;
    } catch {
      return false;
    }
  }
}
