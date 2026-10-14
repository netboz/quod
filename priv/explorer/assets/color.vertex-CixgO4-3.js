import{w as e}from"./sceneLoaderFlags-CW-1rcYh.js";import{r as t,t as n}from"./bonesVertex--mBXsIlF.js";import{r,t as i}from"./clipPlaneVertexDeclaration-C2MGY7z4.js";import{i as a,n as o,r as s,t as c}from"./bakedVertexAnimation-CleGGzY7.js";import{t as l}from"./fogVertexDeclaration-B_q_JFjK.js";import{t as u}from"./fogVertex-DtJsO2Qo.js";import{t as d}from"./vertexColorMixing-Bj3KYT5d.js";var f=`colorVertexShader`,p=`attribute position: vec3f;
#ifdef VERTEXCOLOR
attribute color: vec4f;
#endif
#include<bonesDeclaration>
#include<bakedVertexAnimationDeclaration>
#include<clipPlaneVertexDeclaration>
#include<fogVertexDeclaration>
#ifdef FOG
uniform view: mat4x4f;
#endif
#include<instancesDeclaration>
uniform viewProjection: mat4x4f;
#if defined(VERTEXCOLOR) || defined(INSTANCESCOLOR) && defined(INSTANCES)
varying vColor: vec4f;
#endif
#define CUSTOM_VERTEX_DEFINITIONS
@vertex
fn main(input : VertexInputs)->FragmentInputs {
#define CUSTOM_VERTEX_MAIN_BEGIN
#ifdef VERTEXCOLOR
var colorUpdated: vec4f=vertexInputs.color;
#endif
#include<instancesVertex>
#include<bonesVertex>
#include<bakedVertexAnimation>
var worldPos: vec4f=finalWorld* vec4f(vertexInputs.position,1.0);vertexOutputs.position=uniforms.viewProjection*worldPos;
#include<clipPlaneVertex>
#include<fogVertex>
#include<vertexColorMixing>
#define CUSTOM_VERTEX_MAIN_END
}`;e.ShadersStoreWGSL[f]||(e.ShadersStoreWGSL[f]=p);var m=[t,a,i,l,s,o,n,c,r,u,d];for(let t of m)e.IncludesShadersStoreWGSL[t.name]||(e.IncludesShadersStoreWGSL[t.name]=t.shader);var h={name:f,shader:p};export{h as colorVertexShaderWGSL};