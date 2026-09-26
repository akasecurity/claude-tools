// Installer helper: is ai-tc installed and enabled for this profile? Prints "present" | "absent".
// Thin wrapper around the vendored guard-core's detectAitc, so the installer's ai-tc
// detection (statusline skip, offer suppression) and the hooks' run-time deferral
// (command-guard, leak-guard, rtk-safe) share the exact same rule. Usage errors exit 1; a false/undetected
// result is a normal "absent" print with exit 0 (aitc_present in install.sh treats a
// non-"present" output, including a thrown/failed import, as absent — the safe
// default: the kit installs its statusline and shows the offer).
export {}; // make this a module so top-level `await import(...)` below is allowed under tsc
const [corePath, configDir] = process.argv.slice(2);
if (!corePath || !configDir) {
  console.error('usage: aitc-status.ts <guard-core.js> <config_dir>');
  process.exit(1);
}
const { detectAitc } = await import(corePath);
const home = process.env.HOME ?? '';
console.log(detectAitc('claude', { home, roots: [configDir] }).present ? 'present' : 'absent');
