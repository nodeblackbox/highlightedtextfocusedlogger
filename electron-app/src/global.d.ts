export {};

declare global {
  interface Window {
    highlightReader: {
      onLog(cb: (line: string) => void): void;
      onState(cb: (state: string) => void): void;
      onSettings(cb: (s: unknown) => void): void;
      onAudioPlay(cb: (buf: ArrayBuffer, volume: number) => void): void;
      onAudioStop(cb: () => void): void;
      audioEnded(): void;
      setSettings(partial: Record<string, unknown>): void;
      getSettings(): Promise<unknown>;
      listVoices(): Promise<{ name: string; gender: string; locale: string }[]>;
      getElevationStatus(): Promise<boolean>;
      relaunchElevated(): void;
    };
  }
}
