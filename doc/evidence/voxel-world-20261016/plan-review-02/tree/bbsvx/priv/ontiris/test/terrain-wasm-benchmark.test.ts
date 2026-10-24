/**
 * Phase 0: WASM Terrain Benchmark & Cross-Engine Verification
 *
 * Verifies that bbsvx_voxel.pl terrain algorithms produce correct and consistent
 * results in SWI-Prolog WASM. This is critical because terrain must match between
 * Erlog (server) and SWI-Prolog WASM (client) for the client-side generation
 * architecture to work.
 *
 * Tests:
 * - bit_xor/3 edge cases
 * - squirrel3/3 hash consistency for 100 inputs
 * - terrain_height/4 grid verification
 * - surface_block/8 full chunk generation + timing
 */

import { describe, it, expect, beforeAll } from 'vitest';
import { PrologEngine } from '../src/prolog/PrologEngine';
import { PrologTerrainGenerator, patchForSwiProlog } from '../src/voxel/TerrainGenerator';
import voxelTerrainSrc from '../../ontologies/bbsvx_voxel.pl?raw';

describe('patchForSwiProlog', () => {
  it('should prepend redefine_system_predicate for between/3', () => {
    const patched = patchForSwiProlog(voxelTerrainSrc);
    expect(patched).toContain(':- redefine_system_predicate(between/3).');
  });

  it('should strip voxel_world class declarations', () => {
    const patched = patchForSwiProlog(voxelTerrainSrc);
    expect(patched).not.toContain('isa(voxel_world');
    expect(patched).not.toContain('have_attribute(voxel_world');
    expect(patched).not.toContain('effect(voxel_world');
  });

  it('should preserve terrain computation predicates', () => {
    const patched = patchForSwiProlog(voxelTerrainSrc);
    expect(patched).toContain('squirrel3(Pos, Seed, Result)');
    expect(patched).toContain('terrain_height(X, Z, Seed, Height)');
    expect(patched).toContain('surface_block(CX, CZ, Size, Seed');
    expect(patched).toContain('generate_terrain_data(Ox, Oz, Size, Seed');
    expect(patched).toContain('between(Low, High, Low)');
  });

  it('should preserve between/3 definition (redefine allows it)', () => {
    const patched = patchForSwiProlog(voxelTerrainSrc);
    // between/3 is kept in the source — redefine_system_predicate allows loading it
    expect(patched).toContain('between(Low, High, Low) :- Low =< High.');
  });
});

describe('Terrain WASM Benchmark', () => {
  let engine: PrologEngine;
  let generator: PrologTerrainGenerator;

  beforeAll(async () => {
    engine = new PrologEngine();
    await engine.init();
    generator = new PrologTerrainGenerator(engine);
    await generator.init();
  }, 30_000); // WASM init can be slow

  describe('bit_xor/3', () => {
    it('should compute XOR correctly for basic cases', () => {
      const cases: [number, number, number][] = [
        [0, 0, 0],
        [0xFFFFFFFF, 0, 0xFFFFFFFF],
        [0xFFFFFFFF, 0xFFFFFFFF, 0],
        [0xAAAAAAAA, 0x55555555, 0xFFFFFFFF],
        [123456789, 987654321, 123456789 ^ 987654321],
      ];

      for (const [a, b, expected] of cases) {
        const result = engine.queryOnce(`bit_xor(${a}, ${b}, R)`);
        expect(result).not.toBe(false);
        // Mask to 32 bits (bit_xor masks internally)
        expect((result as Record<string, unknown>).R).toBe(expected >>> 0);
      }
    });

    it('should mask result to 32 bits', () => {
      const result = engine.queryOnce('bit_xor(4294967295, 0, R)');
      expect(result).not.toBe(false);
      expect((result as Record<string, unknown>).R).toBe(4294967295);
    });
  });

  describe('squirrel3/3', () => {
    it('should produce consistent hashes for 100 inputs with seed 42', () => {
      const hashes: number[] = [];

      for (let i = 0; i < 100; i++) {
        const result = engine.queryOnce(`squirrel3(${i}, 42, R)`);
        expect(result).not.toBe(false);
        const r = (result as Record<string, unknown>).R as number;
        expect(r).toBeGreaterThanOrEqual(0);
        expect(r).toBeLessThanOrEqual(4294967295);
        hashes.push(r);
      }

      // Verify determinism: running again should produce identical results
      for (let i = 0; i < 100; i++) {
        const result = engine.queryOnce(`squirrel3(${i}, 42, R)`);
        expect((result as Record<string, unknown>).R).toBe(hashes[i]);
      }

      // Verify variety: not all the same value
      const unique = new Set(hashes);
      expect(unique.size).toBeGreaterThan(90);
    });

    it('should produce different hashes for different seeds', () => {
      const r1 = engine.queryOnce('squirrel3(0, 42, R)');
      const r2 = engine.queryOnce('squirrel3(0, 43, R)');
      expect(r1).not.toBe(false);
      expect(r2).not.toBe(false);
      expect((r1 as Record<string, unknown>).R).not.toBe(
        (r2 as Record<string, unknown>).R,
      );
    });

    it('should handle negative positions via masking', () => {
      // Negative positions get masked to 32 bits
      const result = engine.queryOnce('squirrel3(-1, 42, R)');
      expect(result).not.toBe(false);
      const r = (result as Record<string, unknown>).R as number;
      expect(r).toBeGreaterThanOrEqual(0);
      expect(r).toBeLessThanOrEqual(4294967295);
    });
  });

  describe('cross-engine verification (Erlog reference values)', () => {
    // These values were computed by running the same predicates in Erlog
    // (server-side Prolog). Any divergence means client terrain won't match server.
    it('squirrel3 must match Erlog outputs exactly', () => {
      const erlogRef: [number, number, number][] = [
        // [pos, seed, expected_result]
        [0, 42, 1414865756],
        [1, 42, 4081305030],
        [99, 42, 3393748367],
      ];
      for (const [pos, seed, expected] of erlogRef) {
        const result = engine.queryOnce(`squirrel3(${pos}, ${seed}, R)`);
        expect(result).not.toBe(false);
        expect((result as Record<string, unknown>).R).toBe(expected);
      }
    });

    it('terrain_height must match Erlog outputs exactly', () => {
      const erlogRef: [number, number, number, number][] = [
        // [x, z, seed, expected_height]
        [0, 0, 12345, 7],
        [5, 5, 12345, 4],
        [-3, 7, 12345, 3],
      ];
      for (const [x, z, seed, expected] of erlogRef) {
        const result = engine.queryOnce(`terrain_height(${x}, ${z}, ${seed}, H)`);
        expect(result).not.toBe(false);
        expect((result as Record<string, unknown>).H).toBe(expected);
      }
    });

    it('bit_xor must match Erlog outputs exactly', () => {
      // 0xAAAAAAAA xor 0x55555555 = 0xFFFFFFFF
      const result = engine.queryOnce('bit_xor(2863311530, 1431655765, R)');
      expect(result).not.toBe(false);
      expect((result as Record<string, unknown>).R).toBe(4294967295);
    });
  });

  describe('terrain_height/4', () => {
    it('should return integer heights for a grid of coordinates', () => {
      const seed = 12345;
      for (let x = -2; x <= 2; x++) {
        for (let z = -2; z <= 2; z++) {
          const result = engine.queryOnce(
            `terrain_height(${x}, ${z}, ${seed}, H)`,
          );
          expect(result).not.toBe(false);
          const h = (result as Record<string, unknown>).H as number;
          expect(Number.isInteger(h)).toBe(true);
          // Height should be in reasonable range (base=3, max variation +/-15)
          expect(h).toBeGreaterThanOrEqual(-15);
          expect(h).toBeLessThanOrEqual(20);
        }
      }
    });

    it('should be deterministic — same inputs produce same height', () => {
      const r1 = engine.queryOnce('terrain_height(10, 20, 42, H)');
      const r2 = engine.queryOnce('terrain_height(10, 20, 42, H)');
      expect(r1).not.toBe(false);
      expect((r1 as Record<string, unknown>).H).toBe(
        (r2 as Record<string, unknown>).H,
      );
    });

    it('should produce varying heights across coordinates', () => {
      const heights = new Set<number>();
      for (let x = 0; x < 16; x++) {
        const result = engine.queryOnce(`terrain_height(${x}, 0, 42, H)`);
        heights.add((result as Record<string, unknown>).H as number);
      }
      // Should have some variety (not all flat)
      expect(heights.size).toBeGreaterThan(1);
    });
  });

  describe('surface_block/8 (full chunk generation)', () => {
    it('should generate blocks for a 16x16 chunk', () => {
      const blocks = generator.generateColumn(0, 0, 16, 42);

      expect(blocks.length).toBeGreaterThan(0);
      expect(blocks.length).toBeLessThan(5000); // ~1024 expected for 16x16

      // Verify block structure
      for (const block of blocks) {
        expect(typeof block.x).toBe('number');
        expect(typeof block.y).toBe('number');
        expect(typeof block.z).toBe('number');
        expect(typeof block.type).toBe('string');
        expect(block.type).not.toBe('air');
      }

      // Blocks should be within the requested range
      for (const block of blocks) {
        expect(block.x).toBeGreaterThanOrEqual(0);
        expect(block.x).toBeLessThan(16);
        expect(block.z).toBeGreaterThanOrEqual(0);
        expect(block.z).toBeLessThan(16);
      }

      // Should have a variety of block types
      const types = new Set(blocks.map((b) => b.type));
      expect(types.size).toBeGreaterThan(1);
    });

    it('should generate deterministic results', () => {
      const blocks1 = generator.generateColumn(0, 0, 16, 42);
      const blocks2 = generator.generateColumn(0, 0, 16, 42);

      expect(blocks1.length).toBe(blocks2.length);
      for (let i = 0; i < blocks1.length; i++) {
        expect(blocks1[i]).toEqual(blocks2[i]);
      }
    });

    it('should handle negative offsets', () => {
      const blocks = generator.generateColumn(-16, -16, 16, 42);
      expect(blocks.length).toBeGreaterThan(0);

      for (const block of blocks) {
        expect(block.x).toBeGreaterThanOrEqual(-16);
        expect(block.x).toBeLessThan(0);
        expect(block.z).toBeGreaterThanOrEqual(-16);
        expect(block.z).toBeLessThan(0);
      }
    });

    it('should complete a 16x16 chunk in under 2 seconds', () => {
      const start = performance.now();
      const blocks = generator.generateColumn(32, 32, 16, 12345);
      const elapsed = performance.now() - start;

      console.log(
        `[Benchmark] 16x16 chunk: ${blocks.length} blocks in ${elapsed.toFixed(1)}ms`,
      );
      expect(elapsed).toBeLessThan(2000);
    });

    it('should complete a 32x32 chunk in under 5 seconds', () => {
      const start = performance.now();
      const blocks = generator.generateColumn(0, 0, 32, 12345);
      const elapsed = performance.now() - start;

      console.log(
        `[Benchmark] 32x32 chunk: ${blocks.length} blocks in ${elapsed.toFixed(1)}ms`,
      );
      expect(elapsed).toBeLessThan(5000);
    });
  });

  describe('biome system', () => {
    it('should produce valid biome-specific block types', () => {
      // Generate a large area to capture multiple biomes
      const blocks = generator.generateColumn(0, 0, 32, 42);
      const surfaceTypes = new Set(
        blocks.filter((b) => {
          // Surface blocks are at terrain height
          const r = engine.queryOnce(
            `terrain_height(${b.x}, ${b.z}, 42, H)`,
          ) as Record<string, unknown>;
          return b.y === (r.H as number);
        }).map((b) => b.type),
      );

      // Should see biome-dependent surface blocks
      const validSurface = ['grass', 'sand', 'snow_block'];
      for (const type of surfaceTypes) {
        expect(validSurface).toContain(type);
      }
    });
  });
});
