// FR-020: QR pairing — build the claudemicro://pair URI the iPhone app scans.
import { networkInterfaces } from "node:os";
import { namedTokens, type Config } from "./server.js";

/** First non-internal IPv4 (LAN/Tailscale) so the QR points at a phone-reachable host. */
export function lanHost(): string | null {
  const ifaces = networkInterfaces();
  // Prefer Tailscale (100.64.0.0/10) — encrypted link — then any private LAN address.
  const all = Object.values(ifaces).flat().filter((i) => i && !i.internal && i.family === "IPv4") as { address: string }[];
  const ts = all.find((i) => i.address.startsWith("100."));
  return (ts ?? all[0])?.address ?? null;
}

export function buildPairingUri(config: Config, tokenId?: string): { uri: string; tokenId: string; host: string } {
  const tokens = namedTokens(config);
  const chosen = tokenId ? tokens.find((t) => t.id === tokenId) : tokens[0];
  if (!chosen) throw new Error(`unknown token id "${tokenId}" (configured: ${tokens.map((t) => t.id).join(", ")})`);
  const host = config.pairHost ?? lanHost() ?? config.bind;
  const url = `ws://${host}:${config.port}/ws`;
  const uri = `claudemicro://pair?url=${encodeURIComponent(url)}&token=${encodeURIComponent(chosen.token)}&name=${encodeURIComponent(chosen.id)}`;
  return { uri, tokenId: chosen.id, host };
}
