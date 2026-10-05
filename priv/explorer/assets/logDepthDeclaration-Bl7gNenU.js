import{t as e}from"./shaderStore-D-XQlhUT.js";var t=`meshUboDeclaration`,n=`struct Mesh {world : mat4x4<f32>,
visibility : f32,};var<uniform> mesh : Mesh;
#define WORLD_UBO
`;e.IncludesShadersStoreWGSL[t]||(e.IncludesShadersStoreWGSL[t]=n);var r={name:t,shader:n},i=`mainUVVaryingDeclaration`,a=`#ifdef MAINUV{X}
varying vMainUV{X}: vec2f;
#endif
`;e.IncludesShadersStoreWGSL[i]||(e.IncludesShadersStoreWGSL[i]=a);var o={name:i,shader:a},s=`logDepthDeclaration`,c=`#ifdef LOGARITHMICDEPTH
uniform logarithmicDepthConstant: f32;varying vFragmentDepth: f32;
#endif
`;e.IncludesShadersStoreWGSL[s]||(e.IncludesShadersStoreWGSL[s]=c);var l={name:s,shader:c};export{o as n,r,l as t};