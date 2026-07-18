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

startServer(config);
