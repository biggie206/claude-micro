// T055 (FR-020): pairing URI construction.
import { describe, expect, it } from "vitest";
import { buildPairingUri } from "../src/pairing.js";
import type { Config } from "../src/server.js";

const config = (over: Partial<Config> = {}): Config => ({
  tokens: [
    { id: "toms-iphone", token: "a".repeat(32) },
    { id: "spare", token: "b".repeat(32) },
  ],
  bind: "127.0.0.1",
  port: 8787,
  defaultDepth: 2,
  pairHost: "100.101.102.103",
  projects: [],
  skills: {
    up: { label: "U", prompt: "u" }, down: { label: "D", prompt: "d" },
    left: { label: "L", prompt: "l" }, right: { label: "R", prompt: "r" },
  },
  ...over,
});

describe("buildPairingUri (FR-020)", () => {
  it("defaults to the first token and the configured pairHost", () => {
    const { uri, tokenId, host } = buildPairingUri(config());
    expect(tokenId).toBe("toms-iphone");
    expect(host).toBe("100.101.102.103");
    const parsed = new URL(uri);
    expect(parsed.protocol).toBe("claudemicro:");
    expect(parsed.searchParams.get("url")).toBe("ws://100.101.102.103:8787/ws");
    expect(parsed.searchParams.get("token")).toBe("a".repeat(32));
    expect(parsed.searchParams.get("name")).toBe("toms-iphone");
  });

  it("selects a named token and rejects unknown ids", () => {
    expect(buildPairingUri(config(), "spare").tokenId).toBe("spare");
    expect(() => buildPairingUri(config(), "nope")).toThrow(/unknown token id/);
  });

  it("legacy single-token configs pair as \"shared\"", () => {
    const { tokenId } = buildPairingUri(config({ tokens: undefined, token: "c".repeat(32) }));
    expect(tokenId).toBe("shared");
  });
});
