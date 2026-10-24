import{t as e}from"./shaderStore-D-XQlhUT.js";import{r as t,t as n}from"./gaussianSplattingFragmentDeclaration-DR-sWMnd.js";import{r,t as i}from"./clipPlaneFragmentDeclaration-t7I2_ZlS.js";import{n as a,t as o}from"./fogFragment-CAOKyGQD.js";import{t as s}from"./logDepthDeclaration-DWk2NRvi.js";import{t as c}from"./logDepthFragment-CxtJswLx.js";var l=`gaussianSplattingPixelShader`,u=`#include<clipPlaneFragmentDeclaration>
#include<logDepthDeclaration>
#include<fogFragmentDeclaration>
#ifdef GPUPICKER_PACK_DEPTH
#include<packingFunctions>
#endif
varying vColor: vec4f;varying vPosition: vec2f;
#define CUSTOM_FRAGMENT_DEFINITIONS
#include<gaussianSplattingFragmentDeclaration>
@fragment
fn main(input: FragmentInputs)->FragmentOutputs {
#define CUSTOM_FRAGMENT_MAIN_BEGIN
#include<clipPlaneFragment>
var finalColor: vec4f=gaussianColor(input.vColor,input.vPosition);
#define CUSTOM_FRAGMENT_BEFORE_FRAGCOLOR
#ifdef GPUPICKER_DEPTH
fragmentOutputs.fragData0=finalColor;
#ifdef GPUPICKER_PACK_DEPTH
fragmentOutputs.fragData1=pack(fragmentInputs.position.z);
#else
fragmentOutputs.fragData1=vec4f(fragmentInputs.position.z,0.0,0.0,1.0);
#endif
#else
fragmentOutputs.color=finalColor;
#endif
#define CUSTOM_FRAGMENT_MAIN_END
}
`;e.ShadersStoreWGSL[l]||(e.ShadersStoreWGSL[l]=u);var d=[i,s,a,t,c,o,n,r];for(let t of d)e.IncludesShadersStoreWGSL[t.name]||(e.IncludesShadersStoreWGSL[t.name]=t.shader);var f={name:l,shader:u};export{f as gaussianSplattingPixelShaderWGSL};