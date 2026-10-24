import{t as e}from"./shaderStore-D-XQlhUT.js";import{r as t,t as n}from"./gaussianSplattingFragmentDeclaration-DdhsiUSn.js";import{r,t as i}from"./clipPlaneFragmentDeclaration-qaQmcAD3.js";import{n as a,t as o}from"./fogFragment-Bi6O_OvH.js";import{t as s}from"./logDepthDeclaration-BJAWQrwd.js";import{t as c}from"./logDepthFragment-C5lxT4l1.js";var l=`gaussianSplattingPixelShader`,u=`#include<clipPlaneFragmentDeclaration>
#include<logDepthDeclaration>
#include<fogFragmentDeclaration>
#ifdef GPUPICKER_DEPTH
layout(location=0) out highp vec4 glFragData[2];
#endif
#ifdef GPUPICKER_PACK_DEPTH
#include<packingFunctions>
#endif
varying vec4 vColor;varying vec2 vPosition;
#define CUSTOM_FRAGMENT_DEFINITIONS
#include<gaussianSplattingFragmentDeclaration>
void main () {
#define CUSTOM_FRAGMENT_MAIN_BEGIN
#include<clipPlaneFragment>
vec4 finalColor=gaussianColor(vColor);
#define CUSTOM_FRAGMENT_BEFORE_FRAGCOLOR
#ifdef GPUPICKER_DEPTH
glFragData[0]=finalColor;
#ifdef GPUPICKER_PACK_DEPTH
glFragData[1]=pack(gl_FragCoord.z);
#else
glFragData[1]=vec4(gl_FragCoord.z,0.0,0.0,1.0);
#endif
#else
gl_FragColor=finalColor;
#endif
#define CUSTOM_FRAGMENT_MAIN_END
}
`;e.ShadersStore[l]||(e.ShadersStore[l]=u);var d=[i,s,a,t,c,o,n,r];for(let t of d)e.IncludesShadersStore[t.name]||(e.IncludesShadersStore[t.name]=t.shader);var f={name:l,shader:u};export{f as gaussianSplattingPixelShader};