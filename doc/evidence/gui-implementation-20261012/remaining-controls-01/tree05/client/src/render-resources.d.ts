import type { Scene } from '@babylonjs/core/scene.js'
import type { Texture } from '@babylonjs/core/Materials/Textures/texture.js'
import type { AssetContainer } from '@babylonjs/core/assetContainer.js'

export type ResourceLease<T> = { ready: Promise<T | null>; release(): void }
export type RenderResources = {
  acquire(binding: { digest: string; slot: string; repeat: number[] }): ResourceLease<Texture>
  acquireModel(binding: { digest: string; profile: string; allowed: number[]; bounds: number[] }): ResourceLease<AssetContainer>
  acquireImage(digest: string): ResourceLease<string>
  dispose(): void
}
export function createRenderResources(scene: Scene | null, options?: {
  fetchAsset?: typeof fetch
  decode?: (bytes: Uint8Array, identity: string) => { texture: Texture; ready: Promise<unknown> }
  decodeModel?: (bytes: Uint8Array) => Promise<AssetContainer>
}): RenderResources
