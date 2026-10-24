/**
 * TerrainGenerator — client-side deterministic terrain generation via SWI-Prolog WASM.
 *
 * Loads bbsvx_voxel.pl into the client's PrologEngine and generates terrain locally,
 * eliminating the need for HTTP prove round-trips and server-side block assertions.
 *
 * The terrain is 100% deterministic from (offsetX, offsetZ, seed), producing identical
 * results to the server-side Erlog computation.
 */

import type { PrologEngine } from '../prolog/PrologEngine';
import voxelTerrainSrc from '../../../ontologies/bbsvx_voxel.pl?raw';

export interface TerrainBlock {
  x: number;
  y: number;
  z: number;
  type: string;
}

export interface TerrainGenerator {
  readonly ready: boolean;
  generateColumn(
    offsetX: number,
    offsetZ: number,
    chunkSize: number,
    seed: number,
  ): TerrainBlock[];
}

/**
 * Patch bbsvx_voxel.pl for SWI-Prolog WASM compatibility.
 *
 * bbsvx_voxel.pl is written for Erlog (server). Two adjustments for SWI-Prolog:
 *
 * 1. between/3: Erlog lacks it, so bbsvx_voxel.pl defines its own. SWI-Prolog
 *    has it built-in. We prepend :- redefine_system_predicate(between/3) so the
 *    custom definition loads without permission_error. SWI's built-in is shadowed
 *    but the custom version is functionally identical.
 *
 * 2. Server-only predicates (isa/2, have_attribute/2, effect/4 for voxel_world):
 *    These reference ontology predicates that don't exist client-side. We strip
 *    them by filtering lines between known comment markers.
 */
export function patchForSwiProlog(source: string): string {
  // Allow between/3 redefinition (SWI-Prolog built-in)
  let patched = ':- redefine_system_predicate(between/3).\n' + source;

  // Strip voxel_world class declarations (server-side ontology metadata).
  // These are bounded by the "Voxel World Class" section header comment and
  // the "Utility: between/3" section header comment.
  const lines = patched.split('\n');
  const filtered: string[] = [];
  let inVoxelWorldSection = false;

  for (const line of lines) {
    if (line.includes('Voxel World Class')) {
      inVoxelWorldSection = true;
      filtered.push('% voxel_world class declarations stripped — server-side only');
      continue;
    }
    if (inVoxelWorldSection && line.includes('Utility: between/3')) {
      inVoxelWorldSection = false;
      // Keep this comment line — it's part of between/3 section
    }
    if (!inVoxelWorldSection) {
      filtered.push(line);
    }
  }

  return filtered.join('\n');
}

export class PrologTerrainGenerator implements TerrainGenerator {
  private engine: PrologEngine;
  private _ready = false;

  constructor(engine: PrologEngine) {
    this.engine = engine;
  }

  get ready(): boolean {
    return this._ready;
  }

  async init(): Promise<void> {
    if (this._ready) return;

    const patched = patchForSwiProlog(voxelTerrainSrc);

    // Primary path: write to Emscripten virtual FS and consult.
    // This avoids escaping issues with open_string (the .pl source may contain
    // backslashes, single quotes, percent signs, or other special characters
    // that would break when embedded in a Prolog string literal).
    let loaded = false;
    try {
      this.engine.writeFile('/bbsvx_voxel.pl', patched);
      loaded = this.engine.call("consult('/bbsvx_voxel.pl')");
    } catch (err) {
      console.warn('[TerrainGenerator] FS-based consult failed:', err);
    }

    // Fallback: open_string (handles case where FS write isn't available)
    if (!loaded) {
      try {
        const escaped = patched.replace(/\\/g, '\\\\').replace(/'/g, "''");
        loaded = this.engine.call(
          `setup_call_cleanup(open_string('${escaped}', S), load_files(user, [stream(S)]), close(S))`,
        );
      } catch (err) {
        console.warn('[TerrainGenerator] String-based load failed:', err);
      }
    }

    if (!loaded) {
      throw new Error('[TerrainGenerator] Failed to load terrain Prolog code');
    }

    // Verify terrain_height/4 is callable and returns a plausible integer.
    // A garbage return (e.g. unbound variable or out-of-range) would indicate
    // the voxel source loaded incorrectly (e.g. between/3 stripped too aggressively).
    const test = this.engine.queryOnce('terrain_height(0, 0, 42, H)');
    if (test === false) {
      throw new Error('[TerrainGenerator] terrain_height/4 not callable after load');
    }
    const h = test.H as number;
    if (!Number.isInteger(h) || h < -15 || h > 20) {
      throw new Error(`[TerrainGenerator] terrain_height returned unexpected value: ${h} (expected integer in [-15, 20])`);
    }

    this._ready = true;
    console.log('[TerrainGenerator] Terrain Prolog loaded, terrain_height(0,0,42) =', h);
  }

  generateColumn(
    offsetX: number,
    offsetZ: number,
    chunkSize: number,
    seed: number,
  ): TerrainBlock[] {
    if (!this._ready) {
      throw new Error('[TerrainGenerator] Not initialized — call init() first');
    }

    // Use surface_block/8 which returns flat bindings per block.
    // surface_block(CX, CZ, Size, Seed, X, Y, Z, Block) is defined in bbsvx_voxel.pl
    // and handles terrain_height + block_at + air filtering internally.
    const goal = `surface_block(${offsetX}, ${offsetZ}, ${chunkSize}, ${seed}, X, Y, Z, Type)`;
    const results = this.engine.queryAll(goal);

    if (results.length === 0) {
      console.warn(
        `[TerrainGenerator] 0 blocks for chunk (${offsetX},${offsetZ}) size=${chunkSize} seed=${seed}`,
      );
      // Verify engine is still functional
      const check = this.engine.queryOnce('terrain_height(0, 0, 42, H)');
      if (check === false) {
        console.error('[TerrainGenerator] Engine appears corrupted — terrain_height fails');
      } else {
        console.warn('[TerrainGenerator] Engine OK but surface_block returned empty');
      }
    }

    const blocks: TerrainBlock[] = new Array(results.length);
    for (let i = 0; i < results.length; i++) {
      const r = results[i];
      blocks[i] = {
        x: r.X as number,
        y: r.Y as number,
        z: r.Z as number,
        type: String(r.Type),
      };
    }

    return blocks;
  }
}
