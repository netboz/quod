import type { Scene } from '@babylonjs/core/scene.js'
import type { Texture } from '@babylonjs/core/Materials/Textures/texture.js'
import type { AssetContainer } from '@babylonjs/core/assetContainer.js'
import type { PBRMaterial } from '@babylonjs/core/Materials/PBR/pbrMaterial.js'

export type SurfaceDefinition = { colour: string; metallic: number; roughness: number; emission: number;
  textures: { digest: string; slot: string; repeat: number[] }[] }

export type ResourceLease<T> = { ready: Promise<T | null>; release(): void }
export type RenderResources = {
  acquire(binding: { digest: string; slot: string; repeat: number[] }): ResourceLease<Texture>
  acquireModel(binding: { digest: string; profile: string; allowed: number[]; bounds: number[];
    payload?: Uint8Array; palette?: Map<number, SurfaceDefinition>;
    originMm?: (string | bigint)[] }): ResourceLease<AssetContainer>
  acquireImage(digest: string): ResourceLease<string>
  dispose(): void
}
export function createRenderResources(scene: Scene | null, options?: {
  fetchAsset?: typeof fetch
  decode?: (bytes: Uint8Array, identity: string) => { texture: Texture; ready: Promise<unknown> }
  decodeModel?: (bytes: Uint8Array) => Promise<AssetContainer>
  decodeTerrain?: (data: { positions: Float32Array; normals: Float32Array;
    uvs: Float32Array; indices: Uint32Array }) => { container: AssetContainer; ready: Promise<unknown> }
}): RenderResources
export function createSurface(scene: Scene, name: string, definition: SurfaceDefinition,
  resources?: RenderResources, sky?: boolean): { material: PBRMaterial; ready: Promise<PBRMaterial | null> }
