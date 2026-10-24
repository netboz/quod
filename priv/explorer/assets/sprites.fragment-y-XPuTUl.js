import{t as e}from"./shaderStore-D-XQlhUT.js";import{n as t,t as n}from"./fogFragment-Bi6O_OvH.js";import{t as r}from"./logDepthDeclaration-BJAWQrwd.js";import{t as i}from"./logDepthFragment-C5lxT4l1.js";var a=`imageProcessingCompatibility`,o=`#ifdef IMAGEPROCESSINGPOSTPROCESS
gl_FragColor.rgb=pow(gl_FragColor.rgb,vec3(2.2));
#endif
`;e.IncludesShadersStore[a]||(e.IncludesShadersStore[a]=o);var s={name:a,shader:o},c=`spritesPixelShader`,l=`#ifdef LOGARITHMICDEPTH
#extension GL_EXT_frag_depth : enable
#endif
uniform bool alphaTest;varying vec4 vColor;varying vec2 vUV;uniform sampler2D diffuseSampler;
#include<fogFragmentDeclaration>
#include<logDepthDeclaration>
#define CUSTOM_FRAGMENT_DEFINITIONS
#ifdef PIXEL_PERFECT
vec2 uvPixelPerfect(vec2 uv) {vec2 res=vec2(textureSize(diffuseSampler,0));uv=uv*res;vec2 seam=floor(uv+0.5);uv=seam+clamp((uv-seam)/fwidth(uv),-0.5,0.5);return uv/res;}
#endif
void main(void) {
#define CUSTOM_FRAGMENT_MAIN_BEGIN
#ifdef PIXEL_PERFECT
vec2 uv=uvPixelPerfect(vUV);
#else
vec2 uv=vUV;
#endif
vec4 color=texture2D(diffuseSampler,uv);float fAlphaTest=float(alphaTest);if (fAlphaTest != 0.)
{if (color.a<0.95)
discard;}
color*=vColor;
#include<logDepthFragment>
#include<fogFragment>
gl_FragColor=color;
#include<imageProcessingCompatibility>
#define CUSTOM_FRAGMENT_MAIN_END
}`;e.ShadersStore[c]||(e.ShadersStore[c]=l);var u=[t,r,i,n,s];for(let t of u)e.IncludesShadersStore[t.name]||(e.IncludesShadersStore[t.name]=t.shader);var d={name:c,shader:l};export{d as spritesPixelShader};