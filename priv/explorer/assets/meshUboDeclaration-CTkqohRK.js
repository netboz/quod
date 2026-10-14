import{w as e}from"./sceneLoaderFlags-CW-1rcYh.js";var t=`meshUboDeclaration`,n=`struct Mesh {world : mat4x4<f32>,
visibility : f32,};var<uniform> mesh : Mesh;
#define WORLD_UBO
`;e.IncludesShadersStoreWGSL[t]||(e.IncludesShadersStoreWGSL[t]=n);var r={name:t,shader:n};export{r as t};