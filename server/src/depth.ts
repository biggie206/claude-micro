// DepthLevel (rotary dial / Digital Crown detents) → Agent SDK thinking configuration.
// See specs/001-claude-micro/research.md R4.
import type { DepthLevel } from "./protocol.js";

export type ThinkingConfig =
  | { type: "disabled" }
  | { type: "adaptive" }
  | { type: "enabled"; budget_tokens: number };

export const DEPTH_LABELS: Record<DepthLevel, string> = {
  0: "Off",
  1: "Light",
  2: "Standard",
  3: "Deep",
  4: "Max",
};

export function thinkingForDepth(level: DepthLevel): ThinkingConfig {
  switch (level) {
    case 0: return { type: "disabled" };
    case 1: return { type: "enabled", budget_tokens: 4_000 };
    case 2: return { type: "adaptive" };
    case 3: return { type: "enabled", budget_tokens: 24_000 };
    case 4: return { type: "enabled", budget_tokens: 60_000 };
    default: return { type: "adaptive" };
  }
}
