import{t as e}from"./shaderStore-D-XQlhUT.js";var t=`meshUboDeclaration`,n=`#ifdef WEBGL2
uniform mat4 world;uniform float visibility;
#else
layout(std140,column_major) uniform;uniform Mesh
{mat4 world;float visibility;};
#endif
#define WORLD_UBO
`;e.IncludesShadersStore[t]||(e.IncludesShadersStore[t]=n);var r={name:t,shader:n},i=`mainUVVaryingDeclaration`,a=`#ifdef MAINUV{X}
varying vec2 vMainUV{X};
#endif
`;e.IncludesShadersStore[i]||(e.IncludesShadersStore[i]=a);var o={name:i,shader:a},s=`logDepthDeclaration`,c=`#ifdef LOGARITHMICDEPTH
uniform float logarithmicDepthConstant;varying float vFragmentDepth;
#endif
`;e.IncludesShadersStore[s]||(e.IncludesShadersStore[s]=c);var l={name:s,shader:c};export{o as n,r,l as t};