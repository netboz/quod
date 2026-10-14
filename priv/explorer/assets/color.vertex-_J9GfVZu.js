import{w as e}from"./sceneLoaderFlags-CW-1rcYh.js";import{r as t,t as n}from"./bonesVertex-CclNM9u_.js";import{r,t as i}from"./clipPlaneVertexDeclaration-CD4_yJCA.js";import{i as a,n as o,r as s,t as c}from"./bakedVertexAnimation-BXtf8t44.js";import{t as l}from"./fogVertexDeclaration-CHNM7H2P.js";import{t as u}from"./fogVertex-CPQ217e_.js";import{t as d}from"./vertexColorMixing-WrCFRBTB.js";var f=`colorVertexShader`,p=`attribute vec3 position;
#ifdef VERTEXCOLOR
attribute vec4 color;
#endif
#include<bonesDeclaration>
#include<bakedVertexAnimationDeclaration>
#include<clipPlaneVertexDeclaration>
#include<fogVertexDeclaration>
#ifdef FOG
uniform mat4 view;
#endif
#include<instancesDeclaration>
uniform mat4 viewProjection;
#ifdef MULTIVIEW
uniform mat4 viewProjectionR;
#endif
#if defined(VERTEXCOLOR) || defined(INSTANCESCOLOR) && defined(INSTANCES)
varying vec4 vColor;
#endif
#define CUSTOM_VERTEX_DEFINITIONS
void main(void) {
#define CUSTOM_VERTEX_MAIN_BEGIN
#ifdef VERTEXCOLOR
vec4 colorUpdated=color;
#endif
#include<instancesVertex>
#include<bonesVertex>
#include<bakedVertexAnimation>
vec4 worldPos=finalWorld*vec4(position,1.0);
#ifdef MULTIVIEW
if (gl_ViewID_OVR==0u) {gl_Position=viewProjection*worldPos;} else {gl_Position=viewProjectionR*worldPos;}
#else
gl_Position=viewProjection*worldPos;
#endif
#include<clipPlaneVertex>
#include<fogVertex>
#include<vertexColorMixing>
#define CUSTOM_VERTEX_MAIN_END
}`;e.ShadersStore[f]||(e.ShadersStore[f]=p);var m=[t,a,i,l,s,o,n,c,r,u,d];for(let t of m)e.IncludesShadersStore[t.name]||(e.IncludesShadersStore[t.name]=t.shader);var h={name:f,shader:p};export{h as colorVertexShader};