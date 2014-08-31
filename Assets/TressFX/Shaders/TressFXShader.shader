﻿Shader "TressFX/TFXShader"
{
	Properties
	{
	}
	SubShader
	{
        Pass
        {
        	Tags { "LightMode" = "ForwardAdd" }
        	// ColorMask 0
        	ZWrite Off
        	ZTest LEqual
			Stencil
			{
				Ref 1
				CompFront Always
				PassFront IncrSat
				FailFront Keep
				ZFailFront Keep
				CompBack Always
				PassBack IncrSat
				FailBack keep
				ZFailBack keep
			}
			
            CGPROGRAM
            #pragma target 5.0
 
            #pragma vertex vert
            #pragma fragment frag
            
            #include "UnityCG.cginc"
            
            // Shader structs
            struct PS_INPUT_HAIR_AA
            {
				    float4 Position	: SV_POSITION;
				    float4 Tangent	: Tangent;
				    float4 p0p1		: TEXCOORD0;
			};
			
			//--------------------------------------------------------------------------------------
			// Per-Pixel Linked List (PPLL) structure
			//--------------------------------------------------------------------------------------
			struct PPLL_STRUCT
			{
			    uint	TangentAndCoverage;	
			    uint	depth;
			    uint    uNext;
			};
            
            // UAV's
            RWTexture2D<uint> LinkedListHeadUAV : register(u1);
			RWStructuredBuffer<struct PPLL_STRUCT>	LinkedListUAV : register(u2);
            
            // All needed buffers
            StructuredBuffer<float3> g_HairVertexTangents;
			StructuredBuffer<float3> g_HairVertexPositions;
			StructuredBuffer<int> g_TriangleIndicesBuffer;
			StructuredBuffer<float> g_HairThicknessCoeffs;
			
			uniform float4 _HairColor;
			uniform float3 g_vEye;
			uniform float4 g_WinSize;
			uniform float g_FiberRadius;
			uniform float g_bExpandPixels;
			uniform float g_bThinTip;
			uniform matrix g_mInvViewProj;
			uniform matrix g_mInvViewProjViewport;
			uniform float g_FiberAlpha;
			uniform float g_alphaThreshold;
			uniform float4 g_MatKValue;
			uniform float g_fHairEx2;
			uniform float g_fHairKs2;
			
			// HELPER FUNCTIONS
			uint PackFloat4IntoUint(float4 vValue)
			{
			    return ( (uint(vValue.x*255)& 0xFFUL) << 24 ) | ( (uint(vValue.y*255)& 0xFFUL) << 16 ) | ( (uint(vValue.z*255)& 0xFFUL) << 8) | (uint(vValue.w * 255)& 0xFFUL);
			}

			float4 UnpackUintIntoFloat4(uint uValue)
			{
			    return float4( ( (uValue & 0xFF000000)>>24 ) / 255.0, ( (uValue & 0x00FF0000)>>16 ) / 255.0, ( (uValue & 0x0000FF00)>>8 ) / 255.0, ( (uValue & 0x000000FF) ) / 255.0);
			}

			uint PackTangentAndCoverage(float3 tangent, float coverage)
			{
			    return PackFloat4IntoUint( float4(tangent.xyz*0.5 + 0.5, coverage) );
			}

			float3 GetTangent(uint packedTangent)
			{
			    return 2.0 * UnpackUintIntoFloat4(packedTangent).xyz - 1.0;
			}

			float GetCoverage(uint packedCoverage)
			{
			    return UnpackUintIntoFloat4(packedCoverage).w;
			}
			
			float ComputeCoverage(float2 p0, float2 p1, float2 pixelLoc)
			{
				// p0, p1, pixelLoc are in d3d clip space (-1 to 1)x(-1 to 1)

				// Scale positions so 1.f = half pixel width
				p0 *= g_WinSize.xy;
				p1 *= g_WinSize.xy;
				pixelLoc *= g_WinSize.xy;

				float p0dist = length(p0 - pixelLoc);
				float p1dist = length(p1 - pixelLoc);
				float hairWidth = length(p0 - p1);
			    
				// will be 1.f if pixel outside hair, 0.f if pixel inside hair
				float outside = any( float2(step(hairWidth, p0dist), step(hairWidth, p1dist)) );
				
				// if outside, set sign to -1, else set sign to 1
				float sign = outside > 0.f ? -1.f : 1.f;
				
				// signed distance (positive if inside hair, negative if outside hair)
				float relDist = sign * saturate( min(p0dist, p1dist) );
				
				// returns coverage based on the relative distance
				// 0, if completely outside hair edge
				// 1, if completely inside hair edge
				return (relDist + 1.f) * 0.5f;
			}
			
			void StoreFragments_Hair(uint2 address, float3 tangent, float coverage, float depth)
			{
			return;
			    // Retrieve current pixel count and increase counter
			    uint uPixelCount = LinkedListUAV.IncrementCounter();
			    uint uOldStartOffset;
			    
			    // uint address_i = ListIndex(address);
			    // Exchange indices in LinkedListHead texture corresponding to pixel location 
			    InterlockedExchange(LinkedListHeadUAV[address], uPixelCount, uOldStartOffset);  // link head texture

			    // Append new element at the end of the Fragment and Link Buffer
			    PPLL_STRUCT Element;
				Element.TangentAndCoverage = PackTangentAndCoverage(tangent, coverage);
				Element.depth = asuint(depth);
			    Element.uNext = uOldStartOffset;
			    LinkedListUAV[uPixelCount] = Element; // buffer that stores the fragments
			}
              
            //Our vertex function simply fetches a point from the buffer corresponding to the vertex index
            //which we transform with the view-projection matrix before passing to the pixel program.
            PS_INPUT_HAIR_AA vert (uint id : SV_VertexID)
            {
            	uint vertexId = g_TriangleIndicesBuffer[id];
			    
			    // Access the current line segment
			    uint index = vertexId / 2;  // vertexId is actually the indexed vertex id when indexed triangles are used

			    // Get updated positions and tangents from simulation result
			    float3 t = g_HairVertexTangents[index].xyz;
			    float3 v = g_HairVertexPositions[index].xyz;

			    // Get hair strand thickness
			    float ratio = 1.0f; // ( g_bThinTip > 0 ) ? g_HairThicknessCoeffs[index] : 1.0f;

			    // Calculate right and projected right vectors
			    float3 right      = normalize( cross( t, normalize(v - g_vEye) ) );
			    float2 proj_right = normalize( mul( UNITY_MATRIX_VP, float4(right, 0) ).xy );

			    // g_bExpandPixels should be set to 0 at minimum from the CPU side; this would avoid the below test
			    float expandPixels = (g_bExpandPixels < 0 ) ? 0.0 : 0.71;

				// Calculate the negative and positive offset screenspace positions
				float4 hairEdgePositions[2]; // 0 is negative, 1 is positive
				hairEdgePositions[0] = float4(v +  -1.0 * right * ratio * g_FiberRadius, 1.0);
				hairEdgePositions[1] = float4(v +   1.0 * right * ratio * g_FiberRadius, 1.0);
				hairEdgePositions[0] = mul(UNITY_MATRIX_VP, hairEdgePositions[0]);
				hairEdgePositions[1] = mul(UNITY_MATRIX_VP, hairEdgePositions[1]);
				hairEdgePositions[0] = hairEdgePositions[0]/hairEdgePositions[0].w;
				hairEdgePositions[1] = hairEdgePositions[1]/hairEdgePositions[1].w;

			    // Write output data
			    PS_INPUT_HAIR_AA Output = (PS_INPUT_HAIR_AA)0;
			    float fDirIndex = (vertexId & 0x01) ? -1.0 : 1.0;
			    Output.Position = (fDirIndex==-1.0 ? hairEdgePositions[0] : hairEdgePositions[1]) + fDirIndex * float4(proj_right * expandPixels / g_WinSize.y, 0.0f, 0.0f);
			    Output.Tangent  = float4(t, ratio);
			    Output.p0p1     = float4( hairEdgePositions[0].xy, hairEdgePositions[1].xy );
			    
			    return Output;
            }
			
			// A-Buffer pass
            [earlydepthstencil]
            float4 frag( PS_INPUT_HAIR_AA In) : SV_Target
			{	
				In.Position.y -= 36;
				//In.Position = ComputeScreenPos(In.Position);
				// In.Position.x -= 10;
				//In.Position.y -= 6;
				// return In.Position;
				
			     // Render AA Line, calculate pixel coverage
			    float4 proj_pos = float4(   2*In.Position.x*g_WinSize.z - 1.0,  // g_WinSize.z = 1.0/g_WinSize.x
			                                1.0 - 2*In.Position.y*g_WinSize.w,    // g_WinSize.w = 1.0/g_WinSize.y 
			                                1, 
			                                1);
				
				float coverage = ComputeCoverage(In.p0p1.xy, In.p0p1.zw, proj_pos.xy);

				// coverage *= g_FiberAlpha;

			    // only store fragments with non-zero alpha value
			    if (coverage > g_alphaThreshold) // ensure alpha is at least as much as the minimum alpha value
			    {
			        StoreFragments_Hair(In.Position.xy, In.Tangent.xyz, coverage, In.Position.z);
			    }
			    
			    // output a mask RT for final pass    
			    return float4(coverage, 0, 0, 1);
			}
            
            ENDCG
        }
	} 
	FallBack "Diffuse"
}