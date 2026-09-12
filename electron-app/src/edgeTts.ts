/**
 * Edge TTS synthesis via the `edge-tts` Python package's CLI, invoked as a
 * child process. Text goes through a temp .txt file (--file) rather than a
 * command-line argument -- avoids Windows CLI quoting/length limits entirely
 * for arbitrary highlighted text (quotes, newlines, thousands of characters).
 *
 * Why shell out to Python instead of a pure-Node Edge TTS client: edge-tts
 * (Python) is the actively-maintained reference implementation of Microsoft's
 * undocumented Edge Read Aloud websocket protocol; it's already installed on
 * this machine (see PARAKEET.md-style research trail), and re-implementing
 * that websocket handshake in Node buys nothing for a single-user desktop tool.
 */
import { randomUUID } from "crypto";
import { spawn } from "child_process";
import * as fs from "fs/promises";
import * as os from "os";
import * as path from "path";

export interface SynthesisResult {
  mp3Path: string;
  cleanup: () => Promise<void>;
}

export class SynthesisCancelled extends Error {}

export async function synthesize(
  text: string,
  voice: string,
  opts: { rate?: string; volume?: string; pitch?: string; signal?: AbortSignal } = {}
): Promise<SynthesisResult> {
  const id = randomUUID();
  const txtPath = path.join(os.tmpdir(), `highlight-reader-${id}.txt`);
  const mp3Path = path.join(os.tmpdir(), `highlight-reader-${id}.mp3`);
  await fs.writeFile(txtPath, text, "utf-8");

  const args = [
    "-m", "edge_tts",
    "--file", txtPath,
    "--voice", voice,
    "--write-media", mp3Path,
  ];
  if (opts.rate) args.push("--rate", opts.rate);
  if (opts.volume) args.push("--volume", opts.volume);
  if (opts.pitch) args.push("--pitch", opts.pitch);

  await new Promise<void>((resolve, reject) => {
    const child = spawn("python", args, { windowsHide: true });
    let stderr = "";
    child.stderr.on("data", (d) => (stderr += d.toString()));

    const onAbort = () => {
      child.kill();
      reject(new SynthesisCancelled("synthesis cancelled"));
    };
    opts.signal?.addEventListener("abort", onAbort, { once: true });

    child.on("error", (err) => {
      opts.signal?.removeEventListener("abort", onAbort);
      reject(err);
    });
    child.on("exit", (code) => {
      opts.signal?.removeEventListener("abort", onAbort);
      if (opts.signal?.aborted) return; // already rejected via onAbort
      if (code === 0) resolve();
      else reject(new Error(`edge-tts exited with code ${code}: ${stderr.slice(-500)}`));
    });
  }).finally(() => fs.unlink(txtPath).catch(() => {}));

  return {
    mp3Path,
    cleanup: async () => {
      await fs.unlink(mp3Path).catch(() => {});
    },
  };
}

export interface EdgeVoice {
  name: string;
  gender: string;
  locale: string;
}

/** Parse `edge-tts --list-voices` table output into structured voices. */
export async function listVoices(): Promise<EdgeVoice[]> {
  return new Promise((resolve, reject) => {
    const child = spawn("python", ["-m", "edge_tts", "--list-voices"], { windowsHide: true });
    let out = "";
    child.stdout.on("data", (d) => (out += d.toString()));
    child.on("error", reject);
    child.on("exit", (code) => {
      if (code !== 0) return reject(new Error(`--list-voices exited ${code}`));
      const lines = out.split(/\r?\n/).filter((l) => l.trim());
      const voices: EdgeVoice[] = [];
      for (const line of lines.slice(1)) {
        // Fixed-width-ish columns: "Name  Gender  ContentCategories  VoicePersonalities"
        const m = line.match(/^(\S+)\s+(Male|Female)\s/);
        if (!m) continue;
        const name = m[1];
        const locale = name.split("-").slice(0, 2).join("-");
        voices.push({ name, gender: m[2], locale });
      }
      resolve(voices);
    });
  });
}
