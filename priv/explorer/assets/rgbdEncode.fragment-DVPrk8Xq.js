import{w as e}from"./sceneLoaderFlags-CW-1rcYh.js";import{t}from"./helperFunctions-CZvzYFpf.js";var n=`rgbdEncodePixelShader`,r=`varying vUV: vec2f;var textureSamplerSampler: sampler;var textureSampler: texture_2d<f32>;
#include<helperFunctions>
#define CUSTOM_FRAGMENT_DEFINITIONS
@fragment
fn main(input: FragmentInputs)->FragmentOutputs {fragmentOutputs.color=toRGBD(textureSample(textureSampler,textureSamplerSampler,input.vUV).rgb);}`;e.ShadersStoreWGSL[n]||(e.ShadersStoreWGSL[n]=r);var i=[t];for(let t of i)e.IncludesShadersStoreWGSL[t.name]||(e.IncludesShadersStoreWGSL[t.name]=t.shader);var a={name:n,shader:r};export{a as rgbdEncodePixelShaderWGSL};