# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & test

- Server (`server/`): `npm run build` (tsc) · `npm test` (vitest) · `npm run dev` (tsx, live)
- Apple (`apple/`): `xcodegen` to generate ClaudeMicro.xcodeproj, then `xcodebuild` (targets: ClaudeMicro for iOS, ClaudeMicroWatch for watchOS)

## Rules

- Spec-driven: update `specs/001-claude-micro/` before changing behavior.
- `specs/001-claude-micro/contracts/websocket-protocol.md` is normative together with `server/src/protocol.ts` — keep them in sync (and `apple/Shared/Models.swift` mirrors them).
