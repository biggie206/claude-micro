// CLI bootstrap: load config and start the Claude Micro companion server.
// Run on the Mac that has Claude Code authenticated. See specs/001-claude-micro/quickstart.md
import { readFileSync } from "node:fs";
import { dirname, isAbsolute, resolve } from "node:path";
import { startServer, validateConfig, type Config } from "./server.js";

const configPath = process.env.CLAUDE_MICRO_CONFIG ?? new URL("../claude-micro.config.json", import.meta.url).pathname;
const config: Config = JSON.parse(readFileSync(configPath, "utf8"));
if (typeof config.auditLog === "string" && !isAbsolute(config.auditLog)) {
  config.auditLog = resolve(dirname(configPath), config.auditLog); // relative to the config file
}

const configError = validateConfig(config);
if (configError) {
  console.error(`Refusing to start: ${configError}`);
  process.exit(1);
}

const pairFlag = process.argv.indexOf("--pair");
if (pairFlag !== -1) {
  // FR-020: print a pairing QR and exit (never runs alongside the server so the
  // token isn't left on screen during normal operation).
  const requestedId = process.argv[pairFlag + 1]?.startsWith("-") ? undefined : process.argv[pairFlag + 1];
  const { default: qrcode } = await import("qrcode-terminal");
  const { buildPairingUri } = await import("./pairing.js");
  const { uri, tokenId, host } = buildPairingUri(config, requestedId);
  console.log(`Pairing QR for token "${tokenId}" → ws://${host}:${config.port}/ws`);
  console.log("Scan from Claude Micro on iPhone: Settings → Scan pairing QR\n");
  qrcode.generate(uri, { small: true });
  process.exit(0);
}

const server = startServer(config);

// FR-021: interrupt running turns and notify clients before dying.
let stopping = false;
for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, () => {
    if (stopping) process.exit(1); // second signal: force
    stopping = true;
    console.log(`\n${signal} — shutting down gracefully…`);
    void server.shutdown().then(() => process.exit(0));
  });
}
