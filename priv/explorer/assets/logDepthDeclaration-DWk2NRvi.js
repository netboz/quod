import{n as e}from"./rolldown-runtime-QTnfLwEv.js";import{t}from"./shaderStore-D-XQlhUT.js";var n=e({logDepthDeclarationWGSL:()=>a}),r=`logDepthDeclaration`,i=`#ifdef LOGARITHMICDEPTH
uniform logarithmicDepthConstant: f32;varying vFragmentDepth: f32;
#endif
`;t.IncludesShadersStoreWGSL[r]||(t.IncludesShadersStoreWGSL[r]=i);var a={name:r,shader:i};export{n,a as t};