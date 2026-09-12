/**
 * Speech text cleanup -- a direct TypeScript port of CleanForSpeech() from
 * HighlightLogger v3/v4/v5 (regex-only, no LLM, fast enough to run inline
 * on every hotkey press).
 */
export function cleanForSpeech(raw: string): string {
  if (!raw) return raw;
  let s = raw;

  s = s.replace(/ \/ /g, ". "); // undo any " / " line-join artifacts

  // Markdown emphasis / inline code / links.
  s = s.replace(/\*\*([^*]+)\*\*/g, "$1");
  s = s.replace(/\*([^*]+)\*/g, "$1");
  s = s.replace(/__([^_]+)__/g, "$1");
  s = s.replace(/~~([^~]+)~~/g, "$1");
  s = s.replace(/`([^`]+)`/g, "$1");
  s = s.replace(/\[([^\]]+)\]\([^)]+\)/g, "$1");

  s = s.replace(/<[^>]+>/g, " "); // HTML tags
  s = s.replace(/https?:\/\/\S+/g, "link"); // URLs read as "link"

  // Decorative bullets/arrows -> sentence break.
  s = s.replace(/[•·▪▫►▶▸▹→⇒➔]/g, ".");

  s = s.replace(/\r\n/g, ". ").replace(/\n/g, ". ").replace(/\r/g, ". ");

  s = s.replace(/\?+/g, "?");
  s = s.replace(/!+/g, "!");
  s = s.replace(/\.{2,}/g, ".");
  // Orphan question marks/periods left by empty UIA placeholders ("? . ? .").
  s = s.replace(/(?:\s*[?.]\s*){2,}/g, ". ");
  s = s.replace(/\s+/g, " ");

  s = s.trim().replace(/[.\s\t]+$/, "");

  // If after all that it's mostly punctuation, treat as garbage.
  let meaningful = 0;
  for (const ch of s) {
    if (/[\p{L}\p{N}]/u.test(ch)) meaningful++;
    if (meaningful >= 3) break;
  }
  return meaningful < 3 ? "" : s;
}
