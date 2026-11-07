// The entry point Slang emits GLSL by: every exported function of the shared code, none called
import pathtracer;
[shader("fragment")] float4 main() : SV_Target { return float4(0.0f); }
