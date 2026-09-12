/// <reference path="./global.d.ts" />

const pill = document.getElementById("pill") as HTMLDivElement;
const stateText = document.getElementById("stateText") as HTMLSpanElement;
const logEl = document.getElementById("log") as HTMLDivElement;
const voiceSelect = document.getElementById("voice") as HTMLSelectElement;
const volumeInput = document.getElementById("volume") as HTMLInputElement;
const volumeLabel = document.getElementById("volumeLabel") as HTMLSpanElement;
const player = document.getElementById("player") as HTMLAudioElement;

window.highlightReader.onLog((line) => {
  logEl.textContent += line + "\n";
  logEl.scrollTop = logEl.scrollHeight;
});

window.highlightReader.onState((state) => {
  pill.className = "pill " + state;
  stateText.textContent = state.replace("-", " ");
});

window.highlightReader.onAudioPlay((buf, volume) => {
  const blob = new Blob([buf], { type: "audio/mpeg" });
  player.src = URL.createObjectURL(blob);
  player.volume = volume;
  player.play().catch((err) => console.error("playback failed:", err));
});

window.highlightReader.onAudioStop(() => {
  player.pause();
  player.currentTime = 0;
});

player.addEventListener("ended", () => {
  window.highlightReader.audioEnded();
});

volumeInput.addEventListener("input", () => {
  const pct = Number(volumeInput.value);
  volumeLabel.textContent = `${pct}%`;
  player.volume = pct / 100; // live-update if something is already playing
  window.highlightReader.setSettings({ volume: pct });
});

const elevateCard = document.getElementById("elevateCard") as HTMLDivElement;
const elevateBtn = document.getElementById("elevateBtn") as HTMLButtonElement;
elevateBtn.addEventListener("click", () => window.highlightReader.relaunchElevated());

async function init() {
  const elevated = await window.highlightReader.getElevationStatus();
  elevateCard.hidden = elevated;

  const settings = (await window.highlightReader.getSettings()) as { voice: string; volume: number };
  volumeInput.value = String(settings.volume);
  volumeLabel.textContent = `${settings.volume}%`;

  const voices = await window.highlightReader.listVoices();
  voiceSelect.innerHTML = "";
  for (const v of voices) {
    const opt = document.createElement("option");
    opt.value = v.name;
    opt.textContent = `${v.name} (${v.gender}, ${v.locale})`;
    voiceSelect.appendChild(opt);
  }
  voiceSelect.value = settings.voice;
  if (voiceSelect.value !== settings.voice) {
    // saved/default voice wasn't in the list for some reason -- fall back visibly
    const opt = document.createElement("option");
    opt.value = settings.voice;
    opt.textContent = settings.voice;
    voiceSelect.insertBefore(opt, voiceSelect.firstChild);
    voiceSelect.value = settings.voice;
  }
}

voiceSelect.addEventListener("change", () => {
  window.highlightReader.setSettings({ voice: voiceSelect.value });
});

init();
