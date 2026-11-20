module pathtracer;

public static const float PI = 3.141592653589793;
public static const float MAX_SAFE_INTEGER_FOR_F32 = 8388607.0;
public static const uint UINT_MAX = 4294967295u;
public static const float BIAS = 0.0000152587890625;
public static const float INV_PI = 0.3183098861837907;
public static const float LEAST_NORMAL = 1.17549435e-38f;

public static const uint LOBE_DIFFUSE = 0u;
public static const uint LOBE_REFRACT = 1u;
public static const uint LOBE_REFLECT = 2u;
// 3 is the walk's LOBE_NONE of camera rays
public static const uint LOBE_SHEEN_VELVET = 4u;
public static const uint LOBE_TOON = 6u;

__target_intrinsic(wgsl, "Material")
__target_intrinsic(glsl, "Material")
__target_intrinsic(cuda, "BSDFMaterial")
__extern_cpp public struct Material {
    __extern_cpp public float3 albedo;
    __extern_cpp public float3 emissive;
    __extern_cpp public float roughness;
    __extern_cpp public float metallic;
    __extern_cpp public float transmission;
    __extern_cpp public float ior;
    __extern_cpp public float3 absorption;
    __extern_cpp public float3 specular_tint = float3(1.0f);
    __extern_cpp public float specular_level = 1.0f;
    __extern_cpp public float3 translucent = float3(0.0f);
    __extern_cpp public float3 sheen = float3(0.0f);
    __extern_cpp public float sheen_roughness = 0.5f;
    __extern_cpp public float anisotropy = 0.0f;
    __extern_cpp public float anisotropic_rotation = 0.0f;
    __extern_cpp public float3 tangent = float3(0.0f);
    // Velvet sheen lobe if 1
    __extern_cpp public float velvet = 0.0f;
#ifdef FK_TOON
    // (w, w * Size, w * Smooth) of a Toon BSDF taking weight |w|, glossy for w < 0
    __extern_cpp public float3 toon = float3(0.0f);
#endif
    // Scale over Abbe number of the spread of the IOR by wavelength, 0 for none
    __extern_cpp public float dispersion = 0.0f;
};

__extern_cpp public struct RandomSphere {
    __extern_cpp public uint state;
    __extern_cpp public float3 value;
};

__extern_cpp public struct SampleBSDF {
    __extern_cpp public float3 unit_direction;
    __extern_cpp public float3 throughput;
    __extern_cpp public uint random_state;
    __extern_cpp public bool refracted;
    __extern_cpp public uint lobe;
    // Solid angle PDF, 0 for delta lobes
    __extern_cpp public float pdf;
}

// Tangent and roughness along tangent and bitangent, 0 when isotropic
__extern_cpp public struct AnisotropicFrame {
    __extern_cpp public float3 tangent;
    __extern_cpp public float2 alphas;
}

// The sheen's values at a vertex: on, and its albedo by the view, exp(bilinear SHEEN_ALBEDO), bilinear VELVET_ALBEDO
// for velvet; zero without sheen
__extern_cpp public struct SheenProfile {
    __extern_cpp public bool on;
    __extern_cpp public float albedo;
}

#ifdef FK_TOON
// The toon's values at a vertex: glossy, a, s, b, K or W, P(theta_v) and the axis R or n
__extern_cpp public struct ToonProfile {
    __extern_cpp public bool glossy;
    __extern_cpp public float a;
    __extern_cpp public float s;
    __extern_cpp public float b;
    __extern_cpp public float norm;
    __extern_cpp public float view;
    __extern_cpp public float3 axis;
}
#endif

// SHEEN_ALBEDO nodes per side, least sheen_roughness
public static const uint SHEEN_NODES = 24u;
public static const float SHEEN_LEAST = 0.05f;
// albedo = integral f * n_dot_l dl over the hemisphere, f of the sheen lobe
// SHEEN_ALBEDO[i * SHEEN_NODES + j] = ln(albedo) at
// sqrt(n_dot_v) = i / (SHEEN_NODES - 1)
// sqrt(sheen_roughness) = sqrt(SHEEN_LEAST) + j / (SHEEN_NODES - 1) * (1 - sqrt(SHEEN_LEAST))
// exp(bilinear SHEEN_ALBEDO) >= albedo
public static const float SHEEN_ALBEDO[576] = {
    0.6209f, 0.4945f, 0.3808f, 0.2844f, 0.2001f, 0.1258f, 0.0599f, 0.0011f, -0.0516f, -0.0989f, -0.1416f, -0.1801f,
    -0.2151f, -0.2469f, -0.2759f, -0.3023f, -0.3265f, -0.3486f, -0.3689f, -0.3876f, -0.4048f, -0.4207f, -0.4344f, -0.4493f,
    0.5924f, 0.4705f, 0.3590f, 0.2644f, 0.1815f, 0.1083f, 0.0433f, -0.0147f, -0.0666f, -0.1134f, -0.1555f, -0.1937f,
    -0.2282f, -0.2597f, -0.2883f, -0.3145f, -0.3384f, -0.3604f, -0.3805f, -0.3990f, -0.4161f, -0.4318f, -0.4454f, -0.4607f,
    0.5228f, 0.4060f, 0.3026f, 0.2125f, 0.1333f, 0.0632f, 0.0007f, -0.0551f, -0.1052f, -0.1504f, -0.1912f, -0.2281f,
    -0.2617f, -0.2922f, -0.3200f, -0.3455f, -0.3687f, -0.3901f, -0.4097f, -0.4277f, -0.4444f, -0.4597f, -0.4739f, -0.4880f,
    0.4357f, 0.3277f, 0.2316f, 0.1473f, 0.0728f, 0.0066f, -0.0526f, -0.1056f, -0.1534f, -0.1965f, -0.2355f, -0.2709f,
    -0.3031f, -0.3324f, -0.3592f, -0.3836f, -0.4060f, -0.4266f, -0.4455f, -0.4629f, -0.4790f, -0.4938f, -0.5075f, -0.5209f,
    0.3313f, 0.2346f, 0.1474f, 0.0701f, 0.0014f, -0.0601f, -0.1152f, -0.1649f, -0.2097f, -0.2503f, -0.2872f, -0.3206f,
    -0.3511f, -0.3790f, -0.4044f, -0.4277f, -0.4490f, -0.4687f, -0.4867f, -0.5033f, -0.5187f, -0.5329f, -0.5460f, -0.5586f,
    0.2111f, 0.1279f, 0.0511f, -0.0177f, -0.0797f, -0.1355f, -0.1860f, -0.2316f, -0.2730f, -0.3107f, -0.3449f, -0.3762f,
    -0.4047f, -0.4307f, -0.4546f, -0.4765f, -0.4966f, -0.5151f, -0.5321f, -0.5478f, -0.5623f, -0.5758f, -0.5882f, -0.6001f,
    0.0755f, 0.0080f, -0.0565f, -0.1157f, -0.1698f, -0.2192f, -0.2642f, -0.3052f, -0.3427f, -0.3769f, -0.4082f, -0.4368f,
    -0.4630f, -0.4871f, -0.5091f, -0.5294f, -0.5481f, -0.5653f, -0.5811f, -0.5957f, -0.6093f, -0.6218f, -0.6334f, -0.6445f,
    -0.0757f, -0.1249f, -0.1757f, -0.2238f, -0.2689f, -0.3108f, -0.3496f, -0.3854f, -0.4184f, -0.4487f, -0.4766f, -0.5023f,
    -0.5259f, -0.5476f, -0.5676f, -0.5860f, -0.6030f, -0.6187f, -0.6333f, -0.6467f, -0.6591f, -0.6706f, -0.6813f, -0.6916f,
    -0.2432f, -0.2712f, -0.3064f, -0.3421f, -0.3770f, -0.4106f, -0.4423f, -0.4722f, -0.5001f, -0.5260f, -0.5501f, -0.5724f,
    -0.5931f, -0.6122f, -0.6299f, -0.6462f, -0.6614f, -0.6754f, -0.6884f, -0.7004f, -0.7116f, -0.7220f, -0.7316f, -0.7409f,
    -0.4281f, -0.4315f, -0.4492f, -0.4710f, -0.4946f, -0.5188f, -0.5427f, -0.5658f, -0.5880f, -0.6090f, -0.6287f, -0.6473f,
    -0.6647f, -0.6808f, -0.6959f, -0.7100f, -0.7230f, -0.7351f, -0.7464f, -0.7569f, -0.7667f, -0.7758f, -0.7843f, -0.7925f,
    -0.6323f, -0.6076f, -0.6052f, -0.6112f, -0.6221f, -0.6358f, -0.6509f, -0.6666f, -0.6824f, -0.6979f, -0.7129f, -0.7272f,
    -0.7409f, -0.7538f, -0.7659f, -0.7774f, -0.7881f, -0.7981f, -0.8075f, -0.8163f, -0.8245f, -0.8321f, -0.8393f, -0.8463f,
    -0.8579f, -0.8012f, -0.7760f, -0.7641f, -0.7606f, -0.7624f, -0.7677f, -0.7751f, -0.7838f, -0.7931f, -0.8028f, -0.8125f,
    -0.8220f, -0.8312f, -0.8401f, -0.8486f, -0.8567f, -0.8644f, -0.8717f, -0.8785f, -0.8850f, -0.8910f, -0.8967f, -0.9024f,
    -1.1077f, -1.0143f, -0.9633f, -0.9311f, -0.9114f, -0.8999f, -0.8941f, -0.8922f, -0.8929f, -0.8954f, -0.8991f, -0.9035f,
    -0.9085f, -0.9136f, -0.9189f, -0.9242f, -0.9294f, -0.9344f, -0.9393f, -0.9440f, -0.9485f, -0.9527f, -0.9568f, -0.9610f,
    -1.3850f, -1.2495f, -1.1692f, -1.1141f, -1.0760f, -1.0495f, -1.0313f, -1.0188f, -1.0106f, -1.0054f, -1.0024f, -1.0011f,
    -1.0009f, -1.0015f, -1.0028f, -1.0044f, -1.0064f, -1.0085f, -1.0107f, -1.0130f, -1.0153f, -1.0175f, -1.0198f, -1.0223f,
    -1.6942f, -1.5102f, -1.3965f, -1.3154f, -1.2565f, -1.2131f, -1.1808f, -1.1565f, -1.1382f, -1.1244f, -1.1139f, -1.1060f,
    -1.1001f, -1.0956f, -1.0923f, -1.0900f, -1.0883f, -1.0871f, -1.0864f, -1.0860f, -1.0858f, -1.0858f, -1.0860f, -1.0867f,
    -2.0409f, -1.8008f, -1.6487f, -1.5379f, -1.4554f, -1.3928f, -1.3446f, -1.3070f, -1.2773f, -1.2538f, -1.2349f, -1.2196f,
    -1.2072f, -1.1970f, -1.1886f, -1.1817f, -1.1759f, -1.1710f, -1.1669f, -1.1635f, -1.1606f, -1.1581f, -1.1560f, -1.1547f,
    -2.4327f, -2.1270f, -1.9306f, -1.7857f, -1.6761f, -1.5916f, -1.5253f, -1.4725f, -1.4300f, -1.3954f, -1.3669f, -1.3433f,
    -1.3235f, -1.3068f, -1.2927f, -1.2806f, -1.2701f, -1.2611f, -1.2533f, -1.2464f, -1.2404f, -1.2350f, -1.2303f, -1.2267f,
    -2.8799f, -2.4966f, -2.2486f, -2.0641f, -1.9233f, -1.8135f, -1.7264f, -1.6562f, -1.5990f, -1.5517f, -1.5123f, -1.4791f,
    -1.4510f, -1.4269f, -1.4061f, -1.3881f, -1.3724f, -1.3586f, -1.3464f, -1.3357f, -1.3261f, -1.3175f, -1.3098f, -1.3036f,
    -3.3975f, -2.9209f, -2.6120f, -2.3810f, -2.2036f, -2.0643f, -1.9529f, -1.8625f, -1.7882f, -1.7262f, -1.6741f, -1.6299f,
    -1.5920f, -1.5593f, -1.5309f, -1.5061f, -1.4843f, -1.4650f, -1.4479f, -1.4326f, -1.4189f, -1.4065f, -1.3954f, -1.3863f,
    -4.0081f, -3.4164f, -3.0342f, -2.7475f, -2.5265f, -2.3521f, -2.2121f, -2.0978f, -2.0031f, -1.9239f, -1.8568f, -1.7995f,
    -1.7502f, -1.7074f, -1.6700f, -1.6372f, -1.6082f, -1.5824f, -1.5595f, -1.5389f, -1.5204f, -1.5037f, -1.4886f, -1.4761f,
    -4.7491f, -4.0092f, -3.5364f, -3.1814f, -2.9070f, -2.6900f, -2.5150f, -2.3715f, -2.2523f, -2.1520f, -2.0668f, -1.9937f,
    -1.9306f, -1.8756f, -1.8274f, -1.7849f, -1.7473f, -1.7138f, -1.6839f, -1.6570f, -1.6328f, -1.6110f, -1.5911f, -1.5747f,
    -5.6876f, -4.7403f, -4.1526f, -3.7111f, -3.3695f, -3.0986f, -2.8796f, -2.6994f, -2.5492f, -2.4224f, -2.3144f, -2.2214f,
    -2.1409f, -2.0707f, -2.0090f, -1.9546f, -1.9063f, -1.8633f, -1.8248f, -1.7903f, -1.7592f, -1.7310f, -1.7055f, -1.6843f,
    -6.6894f, -5.3435f, -4.8626f, -4.3441f, -3.9339f, -3.6027f, -3.3310f, -3.1051f, -2.9151f, -2.7539f, -2.6159f, -2.4969f,
    -2.3936f, -2.3034f, -2.2242f, -2.1544f, -2.0924f, -2.0373f, -1.9880f, -1.9437f, -1.9039f, -1.8679f, -1.8348f, -1.8078f,
    -9.6955f, -7.6249f, -6.6107f, -5.7233f, -5.0483f, -4.5213f, -4.1012f, -3.7605f, -3.4801f, -3.2464f, -3.0496f, -2.8823f,
    -2.7388f, -2.6148f, -2.5070f, -2.4127f, -2.3296f, -2.2562f, -2.1909f, -2.1327f, -2.0805f, -2.0335f, -1.9905f, -1.9537f
};

// albedo = integral f * n_dot_l dl over the hemisphere, f of the velvet lobe
// VELVET_ALBEDO[i * SHEEN_NODES + j] = albedo at
// sqrt(n_dot_v) = i / (SHEEN_NODES - 1)
// sqrt(sheen_roughness) = sqrt(VELVET_LEAST) + j / (SHEEN_NODES - 1) * (1 - sqrt(VELVET_LEAST))
// bilinear VELVET_ALBEDO >= albedo
public static const float VELVET_LEAST = 0.01f;
public static const float VELVET_ALBEDO[576] = {
    1.03604f, 1.04969f, 1.0247f, 1.01461f, 1.00961f, 1.0068f, 1.00505f, 1.0039f, 1.00313f,
    1.00258f, 1.00213f, 1.00174f, 1.00139f, 1.00113f, 1.00097f, 1.00093f, 1.00098f, 1.00108f,
    1.00119f, 1.00128f, 1.00132f, 1.00134f, 1.00133f, 1.00131f, 0.907341f, 0.982758f, 0.983867f,
    0.987145f, 0.989889f, 0.991949f, 0.993481f, 0.99464f, 0.995514f, 0.996202f, 0.996783f, 0.997259f,
    0.997621f, 0.997881f, 0.998069f, 0.99823f, 0.998401f, 0.998602f, 0.998829f, 0.999051f, 0.999248f,
    0.999416f, 0.999554f, 0.999666f, 0.4705f, 0.720479f, 0.825413f, 0.880248f, 0.913171f, 0.934224f,
    0.948453f, 0.958545f, 0.965972f, 0.971619f, 0.975998f, 0.979463f, 0.982253f, 0.984537f, 0.986437f,
    0.988039f, 0.989404f, 0.990578f, 0.991595f, 0.992474f, 0.993232f, 0.993946f, 0.994618f, 0.995143f,
    0.103391f, 0.376527f, 0.589906f, 0.716831f, 0.793741f, 0.843842f, 0.877875f, 0.901892f, 0.919514f,
    0.932841f, 0.943174f, 0.951355f, 0.95795f, 0.963352f, 0.967837f, 0.971608f, 0.974813f, 0.97756f,
    0.97993f, 0.981985f, 0.983773f, 0.98533f, 0.986689f, 0.987881f, 0.00549575f, 0.121308f, 0.330383f,
    0.509574f, 0.635823f, 0.721304f, 0.780631f, 0.823377f, 0.855f, 0.878958f, 0.897554f, 0.912288f,
    0.92417f, 0.933904f, 0.94199f, 0.948788f, 0.954564f, 0.959515f, 0.963786f, 0.96749f, 0.970712f,
    0.973521f, 0.975974f, 0.978117f, 6.61684e-05f, 0.0197857f, 0.134809f, 0.304415f, 0.456845f, 0.574617f,
    0.661371f, 0.725478f, 0.773616f, 0.810615f, 0.839515f, 0.862483f, 0.881046f, 0.896275f, 0.908938f,
    0.919593f, 0.928652f, 0.936419f, 0.943122f, 0.948936f, 0.953994f, 0.958404f, 0.962256f, 0.965621f,
    6.08604e-08f, 0.00167625f, 0.0368659f, 0.144052f, 0.286438f, 0.418522f, 0.526809f, 0.611797f, 0.677611f,
    0.728972f, 0.769568f, 0.802119f, 0.828613f, 0.85042f, 0.868594f, 0.883912f, 0.896951f, 0.908142f,
    0.917807f, 0.926193f, 0.933494f, 0.939862f, 0.945423f, 0.950285f, 1.25723e-12f, 5.34419e-05f, 0.00689807f,
    0.0529875f, 0.151352f, 0.273795f, 0.389782f, 0.489247f, 0.570689f, 0.636345f, 0.689308f, 0.732306f,
    0.767559f, 0.796797f, 0.82128f, 0.841979f, 0.859637f, 0.874817f, 0.887945f, 0.899347f, 0.90928f,
    0.917949f, 0.925524f, 0.932147f, 1.3243e-19f, 4.34399e-07f, 0.000783197f, 0.0150598f, 0.0670014f, 0.156855f,
    0.264148f, 0.367524f, 0.458924f, 0.536339f, 0.600868f, 0.654321f, 0.698765f, 0.735947f, 0.767304f,
    0.793975f, 0.81681f, 0.836493f, 0.853549f, 0.868387f, 0.881328f, 0.892632f, 0.902517f, 0.911163f,
    1.21215e-29f, 5.61858e-10f, 4.58034e-05f, 0.00315008f, 0.0245591f, 0.0787702f, 0.161048f, 0.256356f, 0.349499f,
    0.43383f, 0.507297f, 0.570105f, 0.623414f, 0.668656f, 0.70719f, 0.740185f, 0.768629f, 0.793246f,
    0.814644f, 0.8333f, 0.849601f, 0.863861f, 0.876341f, 0.887267f, 1.18e-43f, 6.58941e-14f, 1.12095e-06f,
    0.000447875f, 0.00728175f, 0.0341812f, 0.0884685f, 0.164118f, 0.249804f, 0.334535f, 0.412717f, 0.482445f,
    0.543312f, 0.596086f, 0.641678f, 0.681142f, 0.715394f, 0.745232f, 0.771299f, 0.794104f, 0.81408f,
    0.831588f, 0.846935f, 0.860384f, 0.0f, 3.57222e-19f, 8.93677e-09f, 3.87386e-05f, 0.0016727f, 0.0126485f,
    0.0432065f, 0.0963084f, 0.166104f, 0.243926f, 0.321657f, 0.39457f, 0.46081f, 0.519763f, 0.571757f,
    0.617429f, 0.657506f, 0.692694f, 0.723625f, 0.750828f, 0.774739f, 0.795752f, 0.814208f, 0.830406f,
    0.0f, 3.95293e-26f, 1.71185e-11f, 1.77652e-06f, 0.000278371f, 0.00388712f, 0.0185851f, 0.051246f, 0.102469f,
    0.167095f, 0.23838f, 0.31022f, 0.378577f, 0.441685f, 0.498804f, 0.549939f, 0.595501f, 0.63594f,
    0.671776f, 0.703496f, 0.731528f, 0.756251f, 0.778023f, 0.797168f, 0.0f, 3.24832e-35f, 5.40527e-15f,
    3.64183e-08f, 3.07466e-05f, 0.000948591f, 0.00691073f, 0.0245214f, 0.0580932f, 0.107074f, 0.167111f, 0.232879f,
    0.299713f, 0.364121f, 0.424437f, 0.479848f, 0.530119f, 0.575395f, 0.615977f, 0.652184f, 0.684402f,
    0.712959f, 0.738198f, 0.760445f, 0.0f, 0.0f, 1.74471e-19f, 2.68698e-10f, 2.01521e-06f, 0.00017266f,
    0.00214895f, 0.0103928f, 0.0300239f, 0.06363f, 0.11019f, 0.166118f, 0.227146f, 0.289683f, 0.35066f,
    0.408507f, 0.462324f, 0.51169f, 0.556544f, 0.597014f, 0.633331f, 0.66572f, 0.694487f, 0.719913f,
    0.0f, 0.0f, 3.08186e-25f, 5.37352e-13f, 6.7686e-08f, 2.15671e-05f, 0.000531871f, 0.0037964f, 0.0139498f,
    0.034771f, 0.0677712f, 0.111826f, 0.164029f, 0.220927f, 0.279718f, 0.337675f, 0.393289f, 0.445565f,
    0.493927f, 0.538158f, 0.578278f, 0.614346f, 0.64653f, 0.675068f, 0.0f, 0.0f, 1.27566e-32f,
    1.98236e-16f, 9.54645e-10f, 1.65077e-06f, 9.77844e-05f, 0.00114505f, 0.00568278f, 0.0172268f, 0.0385165f, 0.0704336f,
    0.111939f, 0.16071f, 0.213977f, 0.269376f, 0.324579f, 0.378065f, 0.428723f, 0.475863f, 0.519157f,
    0.558469f, 0.593769f, 0.625195f, 0.0f, 0.0f, 3.71e-42f, 7.81385e-21f, 4.26179e-12f, 6.59225e-08f,
    1.21035e-05f, 0.000267655f, 0.00194808f, 0.00754345f, 0.019913f, 0.0410557f, 0.0715148f, 0.110424f, 0.155951f,
    0.205847f, 0.258068f, 0.310556f, 0.361781f, 0.410492f, 0.455929f, 0.497659f, 0.535512f, 0.569487f,
    0.0f, 0.0f, 0.0f, 1.45017e-26f, 3.94085e-15f, 1.07907e-09f, 8.70304e-07f, 4.40725e-05f, 0.000526944f,
    0.00279516f, 0.00910075f, 0.0217338f, 0.0421972f, 0.0708745f, 0.107093f, 0.149399f, 0.195912f, 0.244817f,
    0.294247f, 0.342617f, 0.388693f, 0.431747f, 0.471393f, 0.507518f, 0.0f, 0.0f, 0.0f,
    3.37723e-34f, 3.80886e-19f, 4.90657e-12f, 2.86603e-08f, 4.38328e-06f, 0.000101341f, 0.000814766f, 0.00349242f, 0.0100821f,
    0.0224322f, 0.0417282f, 0.0682778f, 0.101541f, 0.1403f, 0.18293f, 0.22785f, 0.27341f, 0.318203f,
    0.361181f, 0.401751f, 0.439621f, 0.0f, 0.0f, 0.0f, 1e-44f, 1.13511e-24f, 3.09601e-15f,
    2.829e-10f, 2.00208e-07f, 1.15122e-05f, 0.000164009f, 0.00102415f, 0.00382522f, 0.0102177f, 0.0217333f, 0.039361f,
    0.0633666f, 0.0933079f, 0.128186f, 0.166681f, 0.207392f, 0.249039f, 0.290635f, 0.331344f, 0.370641f,
    0.0f, 0.0f, 0.0f, 0.0f, 8.14998e-33f, 6.36955e-20f, 3.45818e-13f, 2.37366e-09f, 5.25425e-07f,
    1.73998e-05f, 0.000188743f, 0.00102674f, 0.00357492f, 0.00922096f, 0.019297f, 0.0347333f, 0.0558823f, 0.0825094f,
    0.11391f, 0.149101f, 0.187013f, 0.226641f, 0.267131f, 0.307802f, 0.0f, 0.0f, 0.0f,
    0.0f, 0.0f, 7.3833e-28f, 4.41417e-18f, 1.48474e-12f, 3.29402e-09f, 4.59631e-07f, 1.27394e-05f, 0.000130862f,
    0.000711395f, 0.00253174f, 0.00673074f, 0.0145471f, 0.0270257f, 0.0448186f, 0.0681154f, 0.09668f, 0.129946f,
    0.16713f, 0.207334f, 0.249632f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f,
    3.35173e-37f, 1.16604e-24f, 3.3994e-17f, 1.6423e-12f, 1.93988e-09f, 2.40242e-07f, 7.14224e-06f, 8.33758e-05f, 0.00051761f,
    0.00207299f, 0.00607771f, 0.0141988f, 0.0280109f, 0.0485893f, 0.0762827f, 0.110697f, 0.150843f, 0.195364f
};

#ifdef FK_HAIR
// HAIR_WIDTHS and HAIR_TILTS scale the R lobe's width w and the cuticle tilt alpha per lobe
static const float HAIR_WIDTHS[4] = {1.0f, 0.5f, 2.0f, 2.0f};
static const float HAIR_TILTS[4] = {-2.0f, 1.0f, 4.0f, 0.0f};
#endif

public float3 normalize(float3 a) {
    __target_switch {
    case cuda: __intrinsic_asm "(($0) * make_float3(rnorm3df(($0).x, ($0).y, ($0).z)))";
    case wgsl: __intrinsic_asm "normalize($0)";
    default: return a * (1.0f / sqrt(dot(a, a)));
    }
}
public float inverseSqrt(float x) {
    __target_switch {
    case cuda: __intrinsic_asm "rsqrtf($0)";
    case wgsl: __intrinsic_asm "inverseSqrt($0)";
    default: return 1.0f / sqrt(x);
    }
}
[ForceInline] public float select(float f, float t, bool cond) { return select(cond, t, f); }
[ForceInline] public float3 select(float3 f, float3 t, bool cond) { return select(cond, t, f); }
[ForceInline] public float3 select(float3 f, float3 t, bool3 cond) { return select(cond, t, f); }
[ForceInline] public bool sheenUsed() {
    __target_switch {
    case glsl: __intrinsic_asm "(SHEEN)";
    default: return true;
    }
}
[ForceInline] public bool velvetUsed() {
    __target_switch {
    case glsl: __intrinsic_asm "(VELVET)";
    default: return true;
    }
}
[ForceInline] public bool anisotropyUsed() {
    __target_switch {
    case glsl: __intrinsic_asm "(ANISOTROPY)";
    default: return true;
    }
}
[ForceInline] public bool translucencyUsed() {
    __target_switch {
    case glsl: __intrinsic_asm "(TRANSLUCENT)";
    default: return true;
    }
}
public float unshared(float x) {
    __target_switch {
    case wgsl: __intrinsic_asm "$0";
    default: return x;
    }
}
public float3 negate(float3 x) {
    __target_switch {
    case wgsl: __intrinsic_asm "(-$0)";
    default: return -x;
    }
}
public float3 mix(float3 e1, float3 e2, float e3) {
    __target_switch {
    case wgsl: __intrinsic_asm "mix($0, $1, $2)";
    default: return e1 * (1.0f - e3) + e2 * e3;
    }
}
public float sign(float e) {
    __target_switch {
    case wgsl: __intrinsic_asm "sign($0)";
    default: return e > 0.0f ? 1.0f : e < 0.0f ? -1.0f : 0.0f;
    }
}
public uint insertBits(uint e, uint newbits, uint offset, uint count) {
    __target_switch {
    case wgsl: __intrinsic_asm "insertBits($0, $1, $2, $3)";
    default: return (e & ~(((1u << count) - 1u) << offset)) | ((newbits & ((1u << count) - 1u)) << offset);
    }
}

__extern_cpp public struct Random {
    __extern_cpp public uint state;
    __extern_cpp public float value;
};

[CudaDeviceExport] public func rgb_to_greyscale(rgb: float3) -> float {
    return dot(rgb, float3(0.299, 0.587, 0.114));
}

[CudaDeviceExport] public Random pcg(uint state) {
    __target_switch {
    case wgsl:
    case glsl:
    // PCG random number generator
    // Reference: http://www.pcg-random.org/
    return Random(state * 747796405u + 2891336453u, float(hash(state)) / float(UINT_MAX));
    default:
        const float value = ((state = hash(state)) >> 8) * 0x1p-24f;
        return Random(state, value);
    }
}

[CudaDeviceExport] public func normal_distribution(state: uint) -> Random {
    let r1: Random = pcg(state);
    let r2: Random = pcg(r1.state);
    // Sample normal distribution
    let theta: float = 2.0f * PI * r1.value;
    let rho: float = sqrt(-2.0f * clamp(log(r2.value), - MAX_SAFE_INTEGER_FOR_F32, 0.0f));
    return Random(r2.state, rho * cos(theta));
}

[CudaDeviceExport] public func random_sphere(state: uint) -> RandomSphere {
    let x: Random = normal_distribution(state);
    let y: Random = normal_distribution(x.state);
    let z: Random = normal_distribution(y.state);
    return RandomSphere(z.state, normalize(float3(x.value, y.value, z.value)));
}

[CudaDeviceExport] public func trowbridgeReitz(alpha: float, n_dot_h: float) -> float {
    let numerator: float = alpha * alpha;
    // D = alpha^2 / (PI * (n_dot_h^2 * (alpha^2 - 1) + 1)^2)
    // n_dot_h^2 * (alpha^2 - 1) + 1 = (1 - n_dot_h) * (1 + n_dot_h) + alpha^2 * n_dot_h^2
    // => D = numerator / max(PI * denom^2, LEAST_NORMAL), finite as alpha -> 0
    let denom: float = (1.0f - n_dot_h) * (1.0f + n_dot_h) + numerator * n_dot_h * n_dot_h;
    return numerator / max(PI * denom * denom, LEAST_NORMAL);
}

// Smith masking of GGX
// G1 = 2 * n_dot_x / (n_dot_x + sqrt(alpha^2 + (1 - alpha^2) * n_dot_x^2))
// alpha = 0 => G1 = 1
[CudaDeviceExport] public func smithG1(alpha: float, n_dot_x: float) -> float {
    let alpha_sq: float = alpha * alpha;
    let g1: float = 2.0f * n_dot_x / (n_dot_x + sqrt(alpha_sq + (1.0f - alpha_sq) * n_dot_x * n_dot_x));
    return select(1.0f, g1, alpha > 0.0f);
}

[CudaDeviceExport] public func fresnel(cos_theta: float, eta_i: float, eta_o: float) -> float {
    // Compute sini using Snell's law
    let sin_theta = sqrt(max(0.0f, 1.0f - cos_theta * cos_theta));
    let sin_psi = (eta_i / eta_o) * sin_theta;
    // Total internal reflection
    var kr: float = 1.0f;
    if (sin_psi < 1.0f) {
        // Index-matched: no bend, so cos_psi is cos_theta exactly, lest rounding near grazing reflect
        let cos_psi = select(sqrt(max(0.0f, 1.0f - sin_psi * sin_psi)), cos_theta, eta_i == eta_o);
        // cos = abs(cosi);
        let Rs = ((eta_o * cos_theta) - (eta_i * cos_psi)) / ((eta_o * cos_theta) + (eta_i * cos_psi));
        let Rp = ((eta_i * cos_theta) - (eta_o * cos_psi)) / ((eta_i * cos_theta) + (eta_o * cos_psi));
        kr = (Rs * Rs + Rp * Rp) / 2.0f;
    }

    return kr;
}

// Sampling the GGX VNDF (Heitz 2018, Listing 1)
// Output Ne: normal sampled with PDF D_Ve(Ne) = G1(Ve) * max(0, dot(Ve, Ne)) * D(Ne) / Ve.z
[CudaDeviceExport] public func sampleGGXVNDF(Ve: float3, alpha: float, U1: float, U2: float) -> float3 {
    // The Ve argument is the view direction in tangent space, where the normal is (0, 0, 1).
    // Section 3.2: transforming the view direction to the hemisphere configuration.
    let Vh: float3 = normalize(float3(alpha * Ve.x, alpha * Ve.y, Ve.z));
    // Section 4.1: orthonormal basis (with special case if cross product is zero).
    let lensq: float = Vh.x * Vh.x + Vh.y * Vh.y;
    var T1: float3;
    __target_switch {
    case wgsl: T1 = select(float3(1.0, 0.0, 0.0), float3(-Vh.y, Vh.x, 0.0) * inverseSqrt(lensq), lensq > 0.0);
    default: T1 = lensq > 0.0f ? float3(-Vh.y, Vh.x, 0.0f) * inverseSqrt(lensq) : float3(1.0f, 0.0f, 0.0f);
    }
    let T2: float3 = cross(Vh, T1);
    // Section 4.2: parameterization of the projected area.
    let r: float = sqrt(U1);
    let phi: float = 2.0 * PI * U2;
    let t1: float = r * cos(phi);
    var t2: float = r * sin(phi);
    let s: float = 0.5 * (1.0 + Vh.z);
    t2 = (1.0 - s) * sqrt(max(0.0, 1.0 - t1 * t1)) + s * t2;
    // Section 4.3: reprojection onto hemisphere.
    let Nh: float3 = t1 * T1 + t2 * T2 + sqrt(max(0.0, 1.0 - unshared(t1) * unshared(t1) - t2 * t2)) * Vh;
    // Section 3.4: transforming the normal back to the ellipsoid configuration.
    return normalize(float3(alpha * Nh.x, alpha * Nh.y, max(0.0, Nh.z)));
}

// Corresponding PDF is: pdf = cos(theta) / PI
[CudaDeviceExport] public func sampleCosWeightedHemisphere(random_1: float, random_2: float) -> float3 {
    let r = sqrt(random_1);
    let theta: float = 2.0f * PI * random_2;
    let x = r * cos(theta);
    let z = r * sin(theta);
    let y = sqrt(max(0.0f, 1.0f - x * x - z * z));
    return float3(x, y, z);
}

[CudaDeviceExport] public func tangentToWorld(v: float3, n: float3) -> float3 {
    var a: float3 = float3(0.0, 1.0, 0.0);
    if (abs(dot(n, a)) > 1.0f - BIAS) {
        a = float3(1.0, 0.0, 0.0);
    }
    let tangent: float3 = normalize(cross(n, a));
    let bitangent: float3 = cross(n, tangent);
    return v.x * tangent + v.y * n + v.z * bitangent;
}

[CudaDeviceExport] public func worldToTangent(v: float3, n: float3) -> float3 {
    var a: float3 = float3(0.0, 1.0, 0.0);
    if (abs(dot(n, a)) > 1.0f - BIAS) {
        a = float3(1.0, 0.0, 0.0);
    }
    let tangent: float3 = normalize(cross(n, a));
    let bitangent: float3 = cross(n, tangent);
    return float3(dot(v, tangent), dot(v, n), dot(v, bitangent));
}

// t projected off n, any perpendicular where t lies along n
[ForceInline] func perpendicular(t: float3, n: float3) -> float3 {
    let projected: float3 = t - n * dot(n, t);
    return normalize(select(tangentToWorld(float3(1.0f, 0.0f, 0.0f), n), projected, dot(projected, projected) > 0.0f));
}

// Tangent frame of the normal map from the triangle's edges and UV deltas
[CudaDeviceExport] public func normalMapTBN(p0: float3, p1: float3, p2: float3, uv0: float2, uv1: float2, uv2: float2, n: float3) -> float3x3 {
    let e1: float3 = p1 - p0;
    let e2: float3 = p2 - p0;
    let duv1: float2 = uv1 - uv0;
    let duv2: float2 = uv2 - uv0;
    let det: float = duv1.x * duv2.y - duv1.y * duv2.x;
    let inv_det: float = 1.0f / det;
    var t: float3 = (e1 * duv2.y - e2 * duv1.y) * inv_det;
    let b_geom: float3 = (e2 * duv1.x - e1 * duv2.x) * inv_det;

    // Gram-Schmidt: make tangent perpendicular to interpolated normal.
    t = perpendicular(t, n);
    // Handedness: ensure TBN is right-handed; flip T if geometric b disagrees with cross(n,t).
    if (dot(cross(n, t), b_geom) > 0.0f) {
        // Refractive half-vector (eq. 16)
        t = negate(t);
    }
    let b: float3 = cross(n, t);

    return float3x3(t, b, n);
}

[CudaDeviceExport] public func tangentToWorldNormalMap(v: float3, tbn: float3x3) -> float3 {
    return mul(v, tbn);
}

// Offset along the smooth normal to prevent unnatural hard shadow / reflection borders due to the difference
// between the smooth normal and geometry
[CudaDeviceExport] public func geometryOffset(t0: float3, t1: float3, t2: float3, n0: float3, n1: float3, n2: float3, geometry_n: float3, uvw: float3, position: float3) -> float {
    let edge1: float3 = t1 - t0;
    let edge2: float3 = t2 - t0;
    let edge3: float3 = t2 - t1;
    let min_edge_length: float = min(length(edge1), min(length(edge2), length(edge3)));
    let diffs: float3 = float3(distance(position, t0), distance(position, t1), distance(position, t2));
    let angles: float3 = acos(abs(float3(dot(geometry_n, normalize(n0)), dot(geometry_n, normalize(n1)), dot(geometry_n, normalize(n2)))));
    // Limit angles to 45 degrees
    let angle_tan: float3 = clamp(tan(angles), float3(0.0f), float3(PI * 0.25f));
    // Keep geometry offset within reasonable range
    return clamp(dot(diffs * angle_tan, uvw), 0.0f, min_edge_length * 0.125f);
}

// Each lobe toward out_dir: its throughput and PDF_lobe in the diffuse, refraction, reflection, sheen and toon slots,
// PDF_lobe = 0 where it doesn't reach out_dir
// out_dir across the face (refracted): the refraction, and the diffuse where translucent through the shading normal
// otherwise: the diffuse, but where translucent through the shading normal, the reflection, the sheen and the toon
// as throughput = BSDF_lobe * n_dot_l / PDF_lobe
// => BSDF * n_dot_l = sum throughput * PDF_lobe
[CudaDeviceExport] public func BSDF(in_dir: float3, out_dir: float3, n: float3, material: Material, eta_i: float,
    eta_o: float, refracted: bool, random_state: uint, out throughputs: float3[5], out pdfs: float[5]) -> float3 {
    let v: float3 = negate(in_dir);
    let n_dot_v: float = dot(n, v);
    let n_i: float3 = n * sign(n_dot_v);
    let frame: AnisotropicFrame = anisotropicFrame(material, n_i);
    let n_i_dot_l: float = dot(n_i, out_dir);
    let alpha: float = material.roughness * material.roughness;
    let sheen_profile: SheenProfile = sheenProfile(v, n_i, material);
    let translucent: bool = translucencyUsed() && rgb_to_greyscale(material.translucent) > 0.0f;
    let through: bool = dot(n, out_dir) * n_dot_v < 0.0f;
#ifdef FK_TOON
    let lobes: uint = isToon(material) ? 5u : 4u;
#else
    let lobes: uint = 4u;
#endif
    for (var i: uint = 0u; i < 5u; i++) {
        throughputs[i] = float3(0.0f);
        pdfs[i] = 0.0f;
    }
    // The lobe's half vector and its terms, taken again only where they differ from the last lobe's
    var half_of: uint = UINT_MAX;
    var ggx_n: float3 = float3(0.0f);
    var lobe_terms: BSDFLobes = {};
    for (var i: uint = 0u; i < lobes; i++) {
        let lobe: uint = i == 3u ? LOBE_SHEEN_VELVET : i == 4u ? LOBE_TOON : i;
        if ((lobe == LOBE_DIFFUSE && translucent ? through : lobe == LOBE_REFRACT) != refracted) {
            continue;
        }
        // sampleBSDF's half vector for the diffuse and toon lobes, out_dir's reflective one for reflection and sheen
        let lobe_half: uint = lobe == LOBE_TOON ? LOBE_DIFFUSE : lobe == LOBE_SHEEN_VELVET ? LOBE_REFLECT : lobe;
        if (lobe_half != half_of) {
            if (lobe_half == LOBE_DIFFUSE) {
                ggx_n = sampledHalf(in_dir, n, material, random_state, frame);
            } else if (lobe_half == LOBE_REFRACT) {
                ggx_n = refractedHalf(in_dir, out_dir, n, eta_i, eta_o);
            } else {
                ggx_n = reflectedHalf(in_dir, out_dir);
            }
            lobe_terms = bsdfLobes(in_dir, negate(in_dir), n_i, ggx_n, material, eta_i, eta_o, frame, sheen_profile);
            lobe_terms.translucent_share = translucentShare(material);
            half_of = lobe_half;
        }
        switch (lobe) {
        case LOBE_DIFFUSE:
            pdfs[0] = diffusePDF(n_i_dot_l, 0.0f, abs(n_dot_v), alpha, lobe_terms, eta_i, eta_o);
            throughputs[0] = diffuseBSDF(out_dir, n_i, alpha, material, lobe_terms);
            break;
        case LOBE_REFRACT:
            pdfs[1] = refractPDF(n_i_dot_l, dot(out_dir, ggx_n), abs(n_dot_v), alpha, lobe_terms, eta_i, eta_o);
            throughputs[1] = refractBSDF(out_dir, n_i, alpha, material, lobe_terms);
            break;
        case LOBE_SHEEN_VELVET:
            pdfs[3] = sheenVelvetPDF(n_i_dot_l, 0.0f, abs(n_dot_v), alpha, lobe_terms, eta_i, eta_o);
            throughputs[3] = sheenVelvetBSDF(out_dir, n_i, alpha, material, lobe_terms);
            break;
#ifdef FK_TOON
        case LOBE_TOON: {
            let profile: ToonProfile = toonProfile(v, n_i, material);
            pdfs[4] = toonPDF(out_dir, n_i, profile, lobe_terms);
            throughputs[4] = toonBSDF(out_dir, n_i, profile, lobe_terms);
            break;
        }
#endif
        default:
            pdfs[2] = reflectPDF(n_i_dot_l, 0.0f, abs(n_dot_v), alpha, lobe_terms, eta_i, eta_o);
            throughputs[2] = reflectBSDF(out_dir, n_i, alpha, material, lobe_terms);
            break;
        }
    }
    // Directions a lobe can't sample carry no throughput
    var f: float3 = float3(0.0f);
    for (var i: uint = 0u; i < 5u; i++) {
        if (pdfs[i] > 0.0f) {
            f += throughputs[i] * pdfs[i];
        }
    }
    return f;
}

// Half vector terms of sampleBSDF, shared with the lobes' evaluation toward a given out_dir
__extern_cpp public struct BSDFLobes {
    __extern_cpp public float v_dot_h;
    __extern_cpp public float n_dot_h;
    __extern_cpp public float3 refracted;
    __extern_cpp public float3 F;
    __extern_cpp public float F_greyscale;
    __extern_cpp public float reflect_weight;
    __extern_cpp public float3 diffuse_weight;
    __extern_cpp public float3 refract_weight;
    __extern_cpp public float p_diffuse;
    __extern_cpp public float p_reflect;
    __extern_cpp public float p_refract;
    // Share of the diffuse lobe's samples sent through the surface
    __extern_cpp public float translucent_share;
    // Sheen lobe weight, probability and v, 0 without sheen
    __extern_cpp public float3 sheen;
    __extern_cpp public float p_sheen_velvet;
    __extern_cpp public float3 view;
    // Anisotropic frame and G1_v * D of its VNDF, 0 when isotropic
    __extern_cpp public float3 tangent;
    __extern_cpp public float2 alphas;
    __extern_cpp public float visible;
#ifdef FK_TOON
    // Toon lobe's probability
    __extern_cpp public float p_toon = 0.0f;
    // Toon lobe weight, 0 without toon
    __extern_cpp public float3 toon = float3(0.0f);
#endif
}

// Half vector from the VNDF, an anisotropic material's in its frame
[CudaDeviceExport] public func sampleHalfVector(v: float3, n_i: float3, alpha: float, frame: AnisotropicFrame, inout random_state: uint) -> float3 {
    // Generate random values for sampling
    let random_h_1: Random = pcg(random_state);
    let random_h_2: Random = pcg(random_h_1.state);
    random_state = random_h_2.state;
    if (frame.alphas.x > 0.0f) {
        // Stretch Ve to alpha = 1, sample the isotropic VNDF, unstretch
        let Ve: float3 = anisotropicLocal(v, frame.tangent, n_i);
        let Nh: float3 = sampleGGXVNDF(normalize(float3(frame.alphas.x * Ve.x, frame.alphas.y * Ve.y, Ve.z)), 1.0f,
            random_h_1.value, random_h_2.value);
        let h: float3 = normalize(float3(frame.alphas.x * Nh.x, frame.alphas.y * Nh.y, Nh.z));
        return h.x * frame.tangent + h.y * cross(n_i, frame.tangent) + h.z * n_i;
    }
    let v_tangent: float3 = worldToTangent(v, n_i);
    let ggx_n: float3 = sampleGGXVNDF(v_tangent.xzy, alpha, random_h_1.value, random_h_2.value).xzy;
    // Transform half vector back to world space
    return tangentToWorld(ggx_n, n_i);
}

#ifdef FK_TOON
// Toon of mark (w, w * Size, w * Smooth), glossy for w < 0
// a = Size * PI / 2, s = Smooth * PI / 2, b = min(a + s, PI / 2)
// K = 2 * PI * G(b), W = 2 * PI * H(b) glossy, R = 2 * n_dot_v * n - v
[CudaDeviceExport] public func toonProfile(v: float3, n_i: float3, material: Material) -> ToonProfile {
    let glossy: bool = material.toon.x < 0.0f;
    let a: float = clamp(material.toon.y / material.toon.x, 1e-5f, 1.0f) * PI / 2.0f;
    let s: float = clamp(material.toon.z / material.toon.x, 0.0f, 1.0f) * PI / 2.0f;
    let b: float = min(a + s, PI / 2.0f);
    // view = P(theta_v)
    let view: float = toonP(acos(min(dot(n_i, v), 1.0f)), a, s);
    let axis: float3 = glossy ? normalize(2.0f * dot(n_i, v) * n_i - v) : n_i;
    return ToonProfile(glossy, a, s, b, 2.0f * PI * toonIntegral(b, a, s, glossy), view, axis);
}
// A toon of mark w != 0
[ForceInline] public func isToon(material: Material) -> bool {
    return abs(material.toon.x) > 0.0f;
}
// P(t) = 1 below a, 1 - (t - a) / s up to a + s, 0 beyond
[CudaDeviceExport] public func toonP(t: float, a: float, s: float) -> float {
    return t < a ? 1.0f : max(1.0f - (t - a) / max(s, BIAS), 0.0f);
}
// G(t) = integral_0^t P cos sin = sin(min(t, a))^2 / 2 + (1 + a / s) * (cos(2a) - cos(2t)) / 4
//      - ((sin(2t) / 8 - t * cos(2t) / 4) - (sin(2a) / 8 - a * cos(2a) / 4)) / s beyond a
// H(t) = integral_0^t P sin = 1 - cos(min(t, a)) + (1 + a / s) * (cos(a) - cos(t))
//      - ((sin(t) - t * cos(t)) - (sin(a) - a * cos(a))) / s beyond a, glossy
[CudaDeviceExport] public func toonIntegral(t: float, a: float, s: float, glossy: bool) -> float {
    var integral: float = glossy ? 1.0f - cos(min(t, a)) : sin(min(t, a)) * sin(min(t, a)) / 2.0f;
    if (t > a && s > 0.0f) {
        integral += glossy ? (1.0f + a / s) * (cos(a) - cos(t)) - ((sin(t) - t * cos(t)) - (sin(a) - a * cos(a))) / s
            : (1.0f + a / s) * (cos(2.0f * a) - cos(2.0f * t)) / 4.0f
            - ((sin(2.0f * t) / 8.0f - t * cos(2.0f * t) / 4.0f) - (sin(2.0f * a) / 8.0f - a * cos(2.0f * a) / 4.0f))
            / s;
    }
    return integral;
}
#endif

[CudaDeviceExport] public func bsdfLobes(in_dir: float3, v: float3, n_i: float3, ggx_n: float3, material: Material,
    eta_i: float, eta_o: float, frame: AnisotropicFrame, sheen_profile: SheenProfile) -> BSDFLobes {
    // Calculate shared half vector dot products
    let v_dot_h: float = dot(ggx_n, v);
    let n_dot_h: float = dot(n_i, ggx_n);
    // Try refraction through the properly oriented half vector
    let eta: float = eta_i / eta_o;
    let refracted: float3 = normalize(refract(in_dir, ggx_n, eta));
    // F0 = r^2, r = sqrt(specular_level) * |eta_i - eta_o| / (eta_i + eta_o)
    // F0 = ((eta_level - 1) / (eta_level + 1))^2 => eta_level = (1 + r) / (1 - r)
    // F_dielectric = specular_tint * F0 + (1 - specular_tint * F0) * (F(eta_level) - F0) / (1 - F0), 1 past total
    // internal reflection
    let r: float = min(sqrt(material.specular_level) * abs(eta_i - eta_o) / (eta_i + eta_o), 1.0f - BIAS);
    let f0: float = r * r;
    let eta_level: float = (1.0f + r) / (1.0f - r);
    let F_level: float = fresnel(abs(v_dot_h), eta_i > eta_o ? eta_level : 1.0f, eta_i > eta_o ? 1.0f : eta_level);
    let total: bool = eta_i * eta_i * (1.0f - v_dot_h * v_dot_h) >= eta_o * eta_o;
    let F_dielectric: float3 = total ? float3(1.0f) : material.specular_tint * f0 + (1.0f - material.specular_tint * f0)
        * (F_level - f0) / (1.0f - f0);
    // albedo, sheen_profile's
    // BSDF = sheen * f
    // sheen = material.sheen / max(albedo, 1)
    // => integral BSDF * n_dot_l dl = material.sheen * min(albedo, 1)
    // scale = 1 - material.sheen * min(albedo, 1)
    // sheen_component = greyscale(material.sheen) * min(albedo, 1)
    var scale: float3 = float3(1.0f);
    var sheen_component: float = 0.0f;
    var sheen: float3 = float3(0.0f);
    var view: float3 = float3(0.0f);
    if (sheen_profile.on) {
        let albedo: float = sheen_profile.albedo;
        scale = 1.0f - material.sheen * min(albedo, 1.0f);
        sheen_component = rgb_to_greyscale(material.sheen) * min(albedo, 1.0f);
        sheen = material.sheen / max(albedo, 1.0f);
        view = v;
    }
    var toon_component: float = 0.0f;
    var toon: float3 = float3(0.0f);
#ifdef FK_TOON
    // Toon: base lobes scaled by 1 - |w|, the toon of weight toon = |w| * albedo chosen by |w| * greyscale(albedo)
    if (isToon(material)) {
        let mark: float = min(abs(material.toon.x), 1.0f);
        scale *= 1.0f - mark;
        toon_component = mark * rgb_to_greyscale(material.albedo);
        toon = mark * material.albedo;
    }
#endif
    // On-surface rebounces of the metallic lobe, summed as a series: a ray single scattering loses meets
    // the microsurface again and leaves with Ebar, else bounces on, each meeting weighted by F = albedo
    // albedo = F * E + F^2 * Ebar * (1 - E) / (1 - F * (1 - Ebar)), E(mu) taken as Ebar
    // => albedo = F * Ebar * m, m = 1 / (1 - F * (1 - Ebar))
    // Limited per view so that no view returns more than it receives: m <= 1 / E_up(mu, r) with E_up >= E
    // 1 - Ebar(alpha) = alpha^1.81585 * (2.15372 - 0.73285 alpha) / (1 + 1.28095 alpha), alpha = r^2: a fit of the white
    // GGX lobe's average single-bounce return, measured by sampleBSDF, off by at most 0.0005
    // E_up(mu, r) = 1.000645 - sum c_ij r^i mu^j (i >= 1, i + j <= 4): a fit of the single-bounce return from above,
    // at or above it at every measured (mu, r), at most 0.118 (low r, grazing) and on average 0.014 above it
    // r = roughness; anisotropic metal takes r of its smoother axis, whose single bounce returns the most, so its E_up stays above
    let smoother: float = select(material.roughness, sqrt(min(frame.alphas.x, frame.alphas.y)), frame.alphas.x > 0.0f);
    let alpha: float = smoother * smoother;
    let lost: float = select(0.0f, pow(alpha, 1.81585f) * (2.15372f - 0.73285f * alpha) / (1.0f + 1.28095f * alpha),
        alpha > 0.0f);
    let mu: float = clamp(dot(n_i, v), 0.0f, 1.0f);
    let return_up: float = min(1.000645f - smoother * (0.003755f + mu * (-0.041334f + mu * (-0.909385f + mu * 0.352754f)))
        - smoother * smoother * (0.276028f + mu * (1.270234f + mu * 0.0474f)) - smoother * smoother * smoother
        * (0.314529f - mu * 0.348307f)
        + smoother * smoother * smoother * smoother * 0.272297f, 1.0f);
    let rebounce: float3 = min(1.0f / (1.0f - material.albedo * lost), float3(1.0f / max(return_up, BIAS)));
    var F: float3 = mix(F_dielectric, material.albedo * rebounce, material.metallic) * scale;
    let F_greyscale: float = rgb_to_greyscale(F);
    // BSDF weights (these are artistic choices to balance the lobes)
    let reflect_weight: float = 1.0f;
    let diffuse_weight: float3 = (1.0f - material.transmission) * (1.0f - material.metallic) * (1.0f - F_dielectric)
        * scale;
    let refract_weight: float3 = material.transmission * (1.0f - material.metallic) * (1.0f - F_dielectric) * scale;
    // Add fresnel term for improved sampling performance
    let reflect_component: float = max(reflect_weight * F_greyscale, 0.0f);
    let diffuse_component: float = max(rgb_to_greyscale(diffuse_weight), 0.0f);
    let refract_component: float = max(rgb_to_greyscale(refract_weight) * sign(length(refracted)), 0.0f);
    // p_sheen_velvet = min(sheen_component, 1), 1 without base lobes
    // p_lobe = lobe_component / base_component * (1 - p_sheen_velvet)
#ifdef FK_TOON
    let base_component: float = reflect_component + diffuse_component + refract_component + toon_component;
#else
    let base_component: float = reflect_component + diffuse_component + refract_component;
#endif
    let p_sheen_velvet: float = select(min(sheen_component, 1.0f), 1.0f,
        sheen_component > 0.0f && !(base_component > 0.0f));
    let base_component_inv: float = (1.0f - p_sheen_velvet) / max(base_component, BIAS);
    let p_diffuse: float = diffuse_component * base_component_inv;
    let p_reflect: float = reflect_component * base_component_inv;
    let p_refract: float = refract_component * base_component_inv;
    // Anisotropic G1_v * D, the VNDF's numerator
    var visible: float = 0.0f;
    if (frame.alphas.x > 0.0f) {
        visible = anisotropicG1(anisotropicLocal(v, frame.tangent, n_i), frame.alphas) * anisotropicD(anisotropicLocal(ggx_n, frame.tangent, n_i), frame.alphas);
    }
#ifdef FK_TOON
    return BSDFLobes(v_dot_h, n_dot_h, refracted, F, F_greyscale, reflect_weight, diffuse_weight, refract_weight, p_diffuse,
        p_reflect, p_refract, 0.0f, sheen, p_sheen_velvet, view, frame.tangent, frame.alphas, visible,
        toon_component * base_component_inv, toon);
#else
    return BSDFLobes(v_dot_h, n_dot_h, refracted, F, F_greyscale, reflect_weight, diffuse_weight, refract_weight, p_diffuse, p_reflect, p_refract, 0.0f, sheen, p_sheen_velvet, view, frame.tangent, frame.alphas, visible);
#endif
}

// translucent_share = greyscale(translucent) / (greyscale(albedo) + greyscale(translucent))
[CudaDeviceExport] public func translucentShare(material: Material) -> float {
    let translucent: float = rgb_to_greyscale(material.translucent);
    return select(0.0f, translucent / (rgb_to_greyscale(material.albedo) + translucent), translucencyUsed() && translucent > 0.0f);
}

// Tangent projected onto the normal plane, rotated by 2 * PI * anisotropic_rotation
// aspect = sqrt(1 - 0.9 * |anisotropy|)
// alpha_t = alpha / aspect, alpha_b = alpha * aspect, swapped for anisotropy < 0
[CudaDeviceExport] public func anisotropicFrame(material: Material, n_i: float3) -> AnisotropicFrame {
    let alpha: float = material.roughness * material.roughness;
    if (!anisotropyUsed() || material.anisotropy == 0.0f || !(alpha > 0.0f)) {
        return AnisotropicFrame(float3(0.0f), float2(0.0f));
    }
    let t: float3 = perpendicular(material.tangent, n_i);
    let angle: float = 2.0f * PI * material.anisotropic_rotation;
    let aspect: float = sqrt(1.0f - 0.9f * abs(material.anisotropy));
    let ratio: float = select(aspect, 1.0f / aspect, material.anisotropy < 0.0f);
    return AnisotropicFrame(t * cos(angle) + cross(n_i, t) * sin(angle), float2(alpha / ratio, alpha * ratio));
}

// w in the frame (t, n x t, n)
[CudaDeviceExport] public func anisotropicLocal(w: float3, t: float3, n: float3) -> float3 {
    return float3(dot(w, t), dot(w, cross(n, t)), dot(w, n));
}

// D = 1 / (PI * alpha_x * alpha_y * ((h.x / alpha_x)^2 + (h.y / alpha_y)^2 + h.z^2)^2)
[CudaDeviceExport] public func anisotropicD(h: float3, alphas: float2) -> float {
    let x: float = h.x / alphas.x;
    let y: float = h.y / alphas.y;
    let denom: float = x * x + y * y + h.z * h.z;
    return 1.0f / max(PI * alphas.x * alphas.y * denom * denom, LEAST_NORMAL);
}

// G1 = 2 * n_dot_w / (n_dot_w + sqrt(alpha_x^2 * w.x^2 + alpha_y^2 * w.y^2 + n_dot_w^2))
[CudaDeviceExport] public func anisotropicG1(w: float3, alphas: float2) -> float {
    let n_dot_w: float = max(w.z, 0.0f);
    return 2.0f * n_dot_w / (n_dot_w + length(float3(alphas.x * w.x, alphas.y * w.y, n_dot_w)));
}

// Each lobe by three functions under each other: XBSDF, its throughput toward l, XSample, sampleBSDF's case drawing
// it, and XPDF, its solid angle PDF, 0 for delta lobes; all three on the half vector terms of one half vector

// PDF_VNDF of the half vector of lobes, the refraction's and the reflection's
[CudaDeviceExport] public func vndfPDF(n_i_dot_v: float, alpha: float, lobes: BSDFLobes) -> float {
    // PDF_VNDF = G1_v * v_dot_h * D / n_dot_v
    var pdf_h: float = select(0.0f, smithG1(alpha, n_i_dot_v) * lobes.v_dot_h * trowbridgeReitz(alpha, lobes.n_dot_h) / n_i_dot_v, alpha > 0.0f && lobes.v_dot_h > 0.0f && lobes.n_dot_h > 0.0f && n_i_dot_v > 0.0f);
    // visible = G1_v * D
    // => PDF_VNDF = visible * v_dot_h / n_dot_v
    if (lobes.alphas.x > 0.0f) {
        pdf_h = select(0.0f, lobes.visible * lobes.v_dot_h / n_i_dot_v, lobes.v_dot_h > 0.0f && lobes.n_dot_h > 0.0f && n_i_dot_v > 0.0f);
    }
    return pdf_h;
}

[CudaDeviceExport] public func diffuseBSDF(l: float3, n_i: float3, alpha: float, material: Material,
    lobes: BSDFLobes) -> float3 {
    // BSDF = diffuse_weight * albedo / PI
    // => BSDF * n_dot_l = diffuse_weight * albedo * n_dot_l / PI

    // throughput = BSDF * n_dot_l / PDF
    //            = diffuse_weight * albedo * n_dot_l / PI / cosine_hemisphere.y * PI
    //            = diffuse_weight * albedo * n_dot_l / cosine_hemisphere.y

    // Since cosine_hemisphere.y is n_dot_l over the unit hemisphere, we can simplify the throughput to:
    // => throughput = albedo * diffuse_weight
    //
    // Translucent: BSDF = diffuse_weight * translucent / PI behind, PDF = share * |cosine_hemisphere.y| / PI
    // => throughput = diffuse_weight * translucent / share behind, diffuse_weight * albedo / (1 - share) in front
    let share: float = lobes.translucent_share;
    let through: bool = dot(n_i, l) < 0.0f;
    let color: float3 = select(material.albedo, select(material.albedo, material.translucent, through)
        / select(1.0f - share, share, through), share > 0.0f);
    return lobes.diffuse_weight * color / lobes.p_diffuse;
}

// Diffuse case of sampleBSDF, u its draw over the base lobes
[CudaDeviceExport] public func diffuseSample(u: float, n_i: float3, n_i_dot_v: float, alpha: float, material: Material,
    lobes: BSDFLobes, eta_i: float, eta_o: float, random_state: uint) -> SampleBSDF {
    var sample: SampleBSDF = SampleBSDF(float3(1.0f), float3(1.0f), 0u, false, 0u, 0.0f);
    let random_d_1: Random = pcg(random_state);
    let random_d_2: Random = pcg(random_d_1.state);
    sample.random_state = random_d_2.state;
    // Sample cosine weighted hemisphere
    let cosine_hemisphere: float3 = sampleCosWeightedHemisphere(random_d_1.value, random_d_2.value);
    // Behind the surface with probability translucent_share: cosine sample mirrored across the tangent plane
    let through: bool = u < lobes.p_diffuse * lobes.translucent_share;
    let toward: float = select(cosine_hemisphere.y, - cosine_hemisphere.y, through);
    sample.unit_direction = tangentToWorld(float3(cosine_hemisphere.x, toward, cosine_hemisphere.z), n_i);
    sample.refracted = through;
    sample.lobe = LOBE_DIFFUSE;
    sample.throughput = diffuseBSDF(sample.unit_direction, n_i, alpha, material, lobes);
    sample.pdf = diffusePDF(toward, 0.0f, n_i_dot_v, alpha, lobes, eta_i, eta_o);
    return sample;
}

[CudaDeviceExport] public func diffusePDF(n_i_dot_l: float, l_dot_h: float, n_i_dot_v: float, alpha: float,
    lobes: BSDFLobes, eta_i: float, eta_o: float) -> float {
    // PDF_COSINE_HEMISPHERE = cosine_hemisphere.y / PI
    // => PDF = cosine_hemisphere.y / PI
    // Translucent: PDF = share * |cosine_hemisphere.y| / PI behind, (1 - share) * cosine_hemisphere.y / PI in front
    let share: float = lobes.translucent_share;
    return select(0.0f, select(lobes.p_diffuse * n_i_dot_l * INV_PI, lobes.p_diffuse * abs(n_i_dot_l) * INV_PI
        * select(1.0f - share, share, n_i_dot_l < 0.0f), share > 0.0f), n_i_dot_v > 0.0f);
}

// Velvet in place of the Charlie sheen
[ForceInline] public func isVelvet(material: Material) -> bool {
    return velvetUsed() && material.velvet > 0.0f;
}

[CudaDeviceExport] public func sheenProfile(v: float3, n_i: float3, material: Material) -> SheenProfile {
    var profile: SheenProfile = SheenProfile(false, 0.0f);
    if (sheenUsed() && rgb_to_greyscale(material.sheen) > 0.0f) {
        let x: float = clamp(sqrt(max(dot(n_i, v), 0.0f)), 0.0f, 1.0f) * float(SHEEN_NODES - 1u);
        let i: uint = min(uint(x), SHEEN_NODES - 2u);
        let least: float = select(sqrt(SHEEN_LEAST), sqrt(VELVET_LEAST), isVelvet(material));
        let y: float = (clamp(sqrt(max(material.sheen_roughness, 0.0f)), least, 1.0f) - least) / (1.0f - least)
            * float(SHEEN_NODES - 1u);
        let j: uint = min(uint(y), SHEEN_NODES - 2u);
        let k: uint = i * SHEEN_NODES + j;
        let u: float = x - float(i);
        let t: float = y - float(j);
        if (isVelvet(material)) {
            let a: float = VELVET_ALBEDO[k] + (VELVET_ALBEDO[k + SHEEN_NODES] - VELVET_ALBEDO[k]) * u;
            let b: float = VELVET_ALBEDO[k + 1u] + (VELVET_ALBEDO[k + SHEEN_NODES + 1u] - VELVET_ALBEDO[k + 1u]) * u;
            profile = SheenProfile(true, a + (b - a) * t);
        } else {
            let a: float = SHEEN_ALBEDO[k] + (SHEEN_ALBEDO[k + SHEEN_NODES] - SHEEN_ALBEDO[k]) * u;
            let b: float = SHEEN_ALBEDO[k + 1u] + (SHEEN_ALBEDO[k + SHEEN_NODES + 1u] - SHEEN_ALBEDO[k + 1u]) * u;
            profile = SheenProfile(true, exp(a + (b - a) * t));
        }
    }
    return profile;
}

[CudaDeviceExport] public func sheenVelvetBSDF(l: float3, n_i: float3, alpha: float, material: Material,
    lobes: BSDFLobes) -> float3 {
    // BSDF = sheen * D * V
    // => BSDF * n_dot_l = sheen * D * V * n_dot_l

    // throughput = BSDF * n_dot_l / PDF
    //            = sheen * D * V * n_dot_l / p_sheen_velvet * 2 * PI

    // r = max(sheen_roughness, SHEEN_LEAST)
    // D = (2 + 1 / r) * (1 - n_dot_h^2)^(0.5 / r) / (2 * PI)
    // V = 1 / (4 * (n_dot_l + n_dot_v - n_dot_l * n_dot_v))
    // f holds D * V
    // => throughput = sheen * f * n_dot_l * 2 * PI / p_sheen_velvet
    //
    // Velvet: s = max(sheen_roughness, 0.01), sin2 = 1 - n_dot_h^2
    // D = exp(-n_dot_h^2 / (sin2 * s^2)) / (PI * s^2 * sin2^2), V = G / (4 * n_dot_l * n_dot_v)
    // G = min(1, 2 * n_dot_h * n_dot_v / v_dot_h, 2 * n_dot_h * n_dot_l / v_dot_h)
    // => throughput = sheen * f * n_dot_l * 2 * PI / p_sheen_velvet, f holding D * V
    let h: float3 = normalize(l + lobes.view);
    let n_dot_h: float = dot(n_i, h);
    let n_dot_l: float = max(dot(n_i, l), 0.0f);
    let n_dot_v: float = max(dot(n_i, lobes.view), 0.0f);
    let inv_r: float = 1.0f / max(material.sheen_roughness, SHEEN_LEAST);
    var f: float = (2.0f + inv_r) * pow(max(1.0f - n_dot_h * n_dot_h, 0.0f), 0.5f * inv_r) * 0.5f * INV_PI
        / max(4.0f * (n_dot_l + n_dot_v - n_dot_l * n_dot_v), BIAS);
    if (isVelvet(material)) {
        let s2: float = max(material.sheen_roughness, 0.01f) * max(material.sheen_roughness, 0.01f);
        let sin2: float = max(1.0f - n_dot_h * n_dot_h, BIAS);
        f = exp(- n_dot_h * n_dot_h / (sin2 * s2)) / (PI * s2 * sin2 * sin2)
            * min(1.0f, 2.0f * n_dot_h * min(n_dot_l, n_dot_v) / max(abs(dot(h, lobes.view)), BIAS))
            / max(4.0f * n_dot_l * n_dot_v, BIAS);
    }
    return lobes.sheen * (f * n_dot_l * 2.0f * PI / lobes.p_sheen_velvet);
}

// Sheen case of sampleBSDF
[CudaDeviceExport] public func sheenVelvetSample(n_i: float3, n_i_dot_v: float, alpha: float, material: Material,
    lobes: BSDFLobes, eta_i: float, eta_o: float, random_state: uint) -> SampleBSDF {
    var sample: SampleBSDF = SampleBSDF(float3(1.0f), float3(1.0f), 0u, false, 0u, 0.0f);
    let random_s_1: Random = pcg(random_state);
    let random_s_2: Random = pcg(random_s_1.state);
    sample.random_state = random_s_2.state;
    // Sample uniform hemisphere
    let across: float = sqrt(max(0.0f, 1.0f - random_s_1.value * random_s_1.value));
    let phi: float = 2.0f * PI * random_s_2.value;
    sample.unit_direction = tangentToWorld(float3(across * cos(phi), random_s_1.value, across * sin(phi)), n_i);
    sample.lobe = LOBE_SHEEN_VELVET;
    sample.throughput = sheenVelvetBSDF(sample.unit_direction, n_i, alpha, material, lobes);
    sample.pdf = sheenVelvetPDF(random_s_1.value, 0.0f, n_i_dot_v, alpha, lobes, eta_i, eta_o);
    return sample;
}

[CudaDeviceExport] public func sheenVelvetPDF(n_i_dot_l: float, l_dot_h: float, n_i_dot_v: float, alpha: float,
    lobes: BSDFLobes, eta_i: float, eta_o: float) -> float {
    // PDF_UNIFORM_HEMISPHERE = 1 / (2 * PI)
    // => PDF = p_sheen_velvet / (2 * PI)
    return select(0.0f, lobes.p_sheen_velvet * 0.5f * INV_PI, n_i_dot_l > 0.0f && n_i_dot_v > 0.0f);
}

#ifdef FK_TOON
[CudaDeviceExport] public func toonBSDF(l: float3, n_i: float3, profile: ToonProfile, w: BSDFLobes) -> float3 {
    // BSDF = toon * P(theta_v) * P(theta_l) / K
    // => BSDF * n_dot_l = toon * P(theta_v) * P(theta_l) * n_dot_l / K

    // throughput = BSDF * n_dot_l / PDF
    //            = toon * P(theta_v) * P(theta_l) * n_dot_l / K / p_toon / P(theta_l) / n_dot_l * K
    //            = toon * P(theta_v) / p_toon

    // view holds P(theta_v)
    // => throughput = toon * view / p_toon
    //
    // Glossy: BSDF = toon * P(alpha) / W, PDF = p_toon * P(alpha) / W
    // => throughput = toon * n_dot_l / p_toon, 0 below the surface
    return w.toon * select(profile.view, max(dot(n_i, l), 0.0f), profile.glossy) / w.p_toon;
}

// Toon case of sampleBSDF
[CudaDeviceExport] public func toonSample(n_i: float3, profile: ToonProfile, w: BSDFLobes, random_state: uint)
    -> SampleBSDF {
    var sample: SampleBSDF = SampleBSDF(float3(1.0f), float3(1.0f), 0u, false, 0u, 0.0f);
    let random_t_1: Random = pcg(random_state);
    let random_t_2: Random = pcg(random_t_1.state);
    sample.random_state = random_t_2.state;
    // target = u_1 * K / (2 * PI), t = G^-1(target), H^-1 glossy, closed below a
    // t = t - (G(t) - target) / (P(t) * sin(t) * cos(t)), P(t) * sin(t) glossy, 8 steps from (a + b) / 2
    let a: float = profile.a;
    let target: float = random_t_1.value * profile.norm / (2.0f * PI);
    let core: float = profile.glossy ? acos(clamp(1.0f - target, -1.0f, 1.0f)) : asin(min(sqrt(2.0f * target), 1.0f));
    var t: float = core < a ? core : (a + profile.b) / 2.0f;
    for (var k: int = 0; k < 8; k++) {
        let slope: float = toonP(t, a, profile.s) * sin(t) * (profile.glossy ? 1.0f : cos(t));
        t = clamp(t - select(0.0f, (toonIntegral(t, a, profile.s, profile.glossy) - target) / slope, slope > 0.0f),
            0.0f, profile.b);
    }
    let phi: float = 2.0f * PI * random_t_2.value;
    sample.unit_direction = tangentToWorld(float3(sin(t) * cos(phi), cos(t), sin(t) * sin(phi)), profile.axis);
    sample.refracted = dot(n_i, sample.unit_direction) < 0.0f;
    sample.lobe = LOBE_TOON;
    sample.throughput = toonBSDF(sample.unit_direction, n_i, profile, w);
    sample.pdf = toonPDF(sample.unit_direction, n_i, profile, w);
    return sample;
}

[CudaDeviceExport] public func toonPDF(l: float3, n_i: float3, profile: ToonProfile, w: BSDFLobes) -> float {
    // PDF_TOON = P(theta_l) * n_dot_l / K
    // norm holds K, W glossy
    // => PDF = p_toon * P(theta_l) * n_dot_l / K
    // Glossy: PDF = p_toon * P(alpha) / W, cos(alpha) = l . axis
    let n_i_dot_l: float = dot(n_i, l);
    let t: float = acos(clamp(select(n_i_dot_l, dot(l, profile.axis), profile.glossy), -1.0f, 1.0f));
    return select(0.0f, w.p_toon * toonP(t, profile.a, profile.s) * select(n_i_dot_l, 1.0f, profile.glossy)
        / profile.norm, profile.glossy || n_i_dot_l > 0.0f);
}
#endif

[CudaDeviceExport] public func refractBSDF(l: float3, n_i: float3, alpha: float, material: Material,
    lobes: BSDFLobes) -> float3 {
    let m_n_i_dot_l: float = - dot(n_i, l);
    // Microfacet term
    var G1_l: float = smithG1(alpha, max(m_n_i_dot_l, 0.0f));
    // Anisotropic masking toward l in its frame
    if (lobes.alphas.x > 0.0f) {
        G1_l = anisotropicG1(anisotropicLocal(l, lobes.tangent, negate(n_i)), lobes.alphas);
    }
    // BSDF = refract_weight * v_dot_h / n_dot_v / n_dot_l * D * G * JACOBIAN * albedo, refract_weight holding (1 - F)
    // => BSDF * n_dot_l = refract_weight * v_dot_h / n_dot_v * D * G * JACOBIAN * albedo

    // throughput = BSDF * n_dot_l / PDF
    //            = refract_weight * v_dot_h / n_dot_v * D * G * JACOBIAN * albedo / G1_v / v_dot_h / D * n_dot_v / JACOBIAN
    //            = refract_weight * G * albedo / G1_v

    // G = G1_v * G1_l
    // => throughput = refract_weight * G1_l * albedo
    return lobes.refract_weight * G1_l * material.albedo / lobes.p_refract;
}

// Refractive case of sampleBSDF, through its half vector ggx_n
[CudaDeviceExport] public func refractSample(ggx_n: float3, n_i: float3, n_i_dot_v: float, alpha: float,
    material: Material, lobes: BSDFLobes, eta_i: float, eta_o: float, random_state: uint) -> SampleBSDF {
    var sample: SampleBSDF = SampleBSDF(float3(1.0f), float3(1.0f), 0u, false, 0u, 0.0f);
    // Refraction is valid
    sample.unit_direction = lobes.refracted;
    sample.random_state = random_state;
    sample.refracted = true;
    sample.lobe = LOBE_REFRACT;
    sample.throughput = refractBSDF(sample.unit_direction, n_i, alpha, material, lobes);
    sample.pdf = refractPDF(0.0f, dot(sample.unit_direction, ggx_n), n_i_dot_v, alpha, lobes, eta_i, eta_o);
    return sample;
}

[CudaDeviceExport] public func refractPDF(n_i_dot_l: float, l_dot_h: float, n_i_dot_v: float, alpha: float,
    lobes: BSDFLobes, eta_i: float, eta_o: float) -> float {
    let pdf_h: float = vndfPDF(n_i_dot_v, alpha, lobes);
    // JACOBIAN = eta_o^2 * |l_dot_h| / (eta_i * v_dot_h + eta_o * l_dot_h)^2

    // PDF_VNDF = G1_v * v_dot_h * D / n_dot_v
    // PDF_REFRACT = PDF_VNDF * JACOBIAN
    //             = G1_v * v_dot_h * D / n_dot_v * JACOBIAN

    // PDF = PDF_REFRACT
    //     = G1_v * v_dot_h * D / n_dot_v * JACOBIAN
    let denom: float = eta_i * lobes.v_dot_h + eta_o * l_dot_h;
    return select(0.0f, lobes.p_refract * pdf_h * eta_o * eta_o * abs(l_dot_h) / (denom * denom), eta_i != eta_o && l_dot_h < 0.0f);
}

[CudaDeviceExport] public func reflectBSDF(l: float3, n_i: float3, alpha: float, material: Material,
    lobes: BSDFLobes) -> float3 {
    let n_i_dot_l: float = dot(n_i, l);
    // Torrance-Sparrow
    var G1_l: float = smithG1(alpha, max(n_i_dot_l, 0.0f));
    // Anisotropic masking toward l in its frame
    if (lobes.alphas.x > 0.0f) {
        G1_l = anisotropicG1(anisotropicLocal(l, lobes.tangent, n_i), lobes.alphas);
    }
    // BSDF = reflect_weight * D * G * F / (4 * n_dot_v * n_dot_l)
    // => BSDF * n_dot_l = reflect_weight * D * G * F / (4 * n_dot_v)

    // throughput = BSDF * n_dot_l / PDF
    //            = reflect_weight * D * G * F / (4 * n_dot_v) / G1_v / D * (4 * n_dot_v)
    //            = reflect_weight * G * F / G1_v

    // G = G1_v * G1_l
    // => throughput = reflect_weight * G1_l * F
    return lobes.reflect_weight * G1_l * lobes.F / lobes.p_reflect;
}

// Reflective case of sampleBSDF, off its half vector ggx_n
[CudaDeviceExport] public func reflectSample(in_dir: float3, ggx_n: float3, n_i: float3, n_i_dot_v: float, alpha: float,
    material: Material, lobes: BSDFLobes, eta_i: float, eta_o: float, random_state: uint) -> SampleBSDF {
    var sample: SampleBSDF = SampleBSDF(float3(1.0f), float3(1.0f), 0u, false, 0u, 0.0f);
    sample.unit_direction = normalize(reflect(in_dir, ggx_n));
    sample.random_state = random_state;
    sample.lobe = LOBE_REFLECT;
    sample.throughput = reflectBSDF(sample.unit_direction, n_i, alpha, material, lobes);
    sample.pdf = reflectPDF(0.0f, 0.0f, n_i_dot_v, alpha, lobes, eta_i, eta_o);
    return sample;
}

[CudaDeviceExport] public func reflectPDF(n_i_dot_l: float, l_dot_h: float, n_i_dot_v: float, alpha: float,
    lobes: BSDFLobes, eta_i: float, eta_o: float) -> float {
    let pdf_h: float = vndfPDF(n_i_dot_v, alpha, lobes);
    // PDF_VNDF = G1_v * v_dot_h * D / n_dot_v
    // JACOBIAN = 1 / (4 * v_dot_h)
    // PDF_REFLECT = PDF_VNDF * JACOBIAN
    // => PDF_REFLECT = G1_v * D / (4 * n_dot_v)

    // PDF = PDF_REFLECT
    // => PDF = G1_v * D / (4 * v_dot_n)
    return select(0.0f, lobes.p_reflect * pdf_h / (4.0f * lobes.v_dot_h), pdf_h > 0.0f);
}

// SampleBSDF takes in incoming direction, surface normal, material and random state and returns an outgoing direction with throughput according to the BSDF for global illumination

[CudaDeviceExport] public func sampleBSDF(in_dir: float3, n: float3, material: Material, eta_i: float, eta_o: float, random_init: uint, screen_space: float2) -> SampleBSDF {
    var random_state: uint = random_init;
    // Basic dot products
    let v: float3 = negate(in_dir);
    let n_dot_v: float = dot(n, v);
    var n_i: float3 = n * sign(n_dot_v);
    let n_i_dot_v: float = abs(n_dot_v);
    // Material constants
    let alpha: float = material.roughness * material.roughness;
    // Sample using GGX importance sampling for potential refractive or reflective case
    let frame: AnisotropicFrame = anisotropicFrame(material, n_i);
    let sheen_profile: SheenProfile = sheenProfile(v, n_i, material);
    let ggx_n: float3 = sampleHalfVector(v, n_i, alpha, frame, random_state);
    var lobes: BSDFLobes = bsdfLobes(in_dir, v, n_i, ggx_n, material, eta_i, eta_o, frame, sheen_profile);
    lobes.translucent_share = translucentShare(material);

    let random_p: Random = pcg(random_state);
    random_state = random_p.state;
    // Sheen case
    if (random_p.value < lobes.p_sheen_velvet) {
        return sheenVelvetSample(n_i, n_i_dot_v, alpha, material, lobes, eta_i, eta_o, random_state);
    }
    // The base lobes over the rest
    let u: float = random_p.value - lobes.p_sheen_velvet;
    // Diffuse case
    if (u < lobes.p_diffuse) {
        return diffuseSample(u, n_i, n_i_dot_v, alpha, material, lobes, eta_i, eta_o, random_state);
    }
#ifdef FK_TOON
    // Toon case
    if (u < lobes.p_diffuse + lobes.p_toon) {
        return toonSample(n_i, toonProfile(v, n_i, material), lobes, random_state);
    }
    let toon_share: float = lobes.p_toon;
#else
    let toon_share: float = 0.0f;
#endif
    // Refractive case
    if (u - toon_share < lobes.p_diffuse + lobes.p_refract) {
        return refractSample(ggx_n, n_i, n_i_dot_v, alpha, material, lobes, eta_i, eta_o, random_state);
    }
    // Otherwise assume reflective case.
    return reflectSample(in_dir, ggx_n, n_i, n_i_dot_v, alpha, material, lobes, eta_i, eta_o, random_state);
}

// sampleBSDF's half vector, drawn from random_state as sampleBSDF draws it: the diffuse and toon lobes'
[CudaDeviceExport] public func sampledHalf(in_dir: float3, n: float3, material: Material, random_state: uint,
    frame: AnisotropicFrame) -> float3 {
    var state: uint = random_state;
    let v: float3 = negate(in_dir);
    // Diffuse half-vector of sampleBSDF
    return sampleHalfVector(v, n * sign(dot(n, v)), material.roughness * material.roughness, frame, state);
}

// The reflection's and the sheen's half vector of out_dir
[CudaDeviceExport] public func reflectedHalf(in_dir: float3, out_dir: float3) -> float3 {
    // Reflective half-vector
    return normalize(negate(in_dir) + out_dir);
}

// The refraction's half vector of out_dir, facing n_i
[CudaDeviceExport] public func refractedHalf(in_dir: float3, out_dir: float3, n: float3, eta_i: float, eta_o: float)
    -> float3 {
    let v: float3 = negate(in_dir);
    // Refractive half-vector (eq. 16)
    let h_t: float3 = negate(eta_i * v + eta_o * out_dir);
    return normalize(h_t) * sign(dot(h_t, n * sign(dot(n, v))));
}

// I = L * PI * radius^2, the sphere's projected area
// => L = color * intensity / (PI * radius^2)
[CudaDeviceExport] public func pointLightRadiance(color: float3, intensity: float, radius: float) -> float3 {
    return color * intensity / (PI * radius * radius);
}

// If the ray is inside a medium, apply Beer's law for absorption.
[CudaDeviceExport] public func beerLambert(distance: float, absorption: float3) -> float3 {
    // The amount of light transmitted is T = exp(-sigma_a * d).
    // sigma_a = -ln(absorption)
    let absorption_coefficient: float3 = max(absorption, float3(BIAS));
    return exp(distance * log(absorption_coefficient));
}

[CudaDeviceExport] public func vertexEta(material: Material, n_dot_v: float) -> float2 {
    let is_entering: bool = n_dot_v < 0.0f;
    // Incident side is air, outgoing side is material (entering)
    let eta_i: float = select(1.0f, material.ior, is_entering);
    // Incident side is material, outgoing side is air (exiting)
    let eta_o: float = select(material.ior, 1.0f, is_entering);
    return float2(eta_i, eta_o);
}

// Decide between next event estimation and emission on the next hit, as the path tracer does
[CudaDeviceExport] public func neeDecision(material: Material, n_dot_v: float, eta_i: float, eta_o: float) -> bool {
    // Calculate fresnel term
    let F_n: float3 = mix(float3(fresnel(abs(n_dot_v), eta_i, eta_o)), material.albedo, material.metallic);
    let F_n_greyscale: float = rgb_to_greyscale(F_n);
    let diffuse_factor_estimate: float = max((1.0f - F_n_greyscale) * (1.0f - material.metallic) * (1.0f - material.transmission), 0.0f);
    return diffuse_factor_estimate > 0.04f || material.roughness > 0.2f;
}

// eta_i = eta_o => F = 0, l = -v, G1_l = 1
// => throughput = transmission * (1 - metallic) * albedo
[CudaDeviceExport] public func straightThrough(material: Material) -> float3 {
    return material.transmission * (1.0f - material.metallic) * material.albedo;
}

#ifdef FK_HAIR
// Hair, baked per lobe p (R, TT, TRT, rest) in nt rows of theta and np columns of phi
[CudaDeviceExport] public func hairRow(in_dir: float3, t: float3, out_dir: float3, p: uint, w: float, alpha: float, nt: uint) -> float {
    let width: float = w * HAIR_WIDTHS[p % 4u];
    let cone: float = asin(clamp(dot(out_dir, t), -1.0f, 1.0f)) - asin(clamp(dot(in_dir, t), -1.0f, 1.0f)) - HAIR_TILTS[p % 4u] * alpha;
    return (asinh(cone / width) / asinh(PI / width) + 1.0f) * 0.5f * float(nt);
}
// Column of out_dir's azimuth about t, relative to the reversed view
[CudaDeviceExport] public func hairColumn(in_dir: float3, t: float3, out_dir: float3, np: uint) -> float {
    let o: float3 = worldToTangent(out_dir, t);
    let v: float3 = worldToTangent(in_dir, t);
    return frac((atan2(o.z, o.x + LEAST_NORMAL) - atan2(- v.z, LEAST_NORMAL - v.x)) / (2.0f * PI) + 0.5f) * float(np);
}
[CudaDeviceExport] public func hairDirection(in_dir: float3, t: float3, p: uint, row: float, column: float, w: float, alpha: float, nt: uint, np: uint) -> float3 {
    let v: float3 = worldToTangent(in_dir, t);
    let width: float = w * HAIR_WIDTHS[p % 4u];
    let theta: float = asin(clamp(dot(in_dir, t), -1.0f, 1.0f)) + HAIR_TILTS[p % 4u] * alpha + width * sinh((row * 2.0f / float(nt) - 1.0f) * asinh(PI / width));
    let phi: float = column * 2.0f * PI / float(np) - PI + atan2(- v.z, LEAST_NORMAL - v.x);
    return tangentToWorld(float3(cos(theta) * cos(phi), sin(theta), cos(theta) * sin(phi)), t);
}
#endif

// A relative 1e-4 short of the end
[CudaDeviceExport] public func shadowLength(shadow: float3) -> float {
    return length(shadow) * (1.0f - 1e-4f);
}

// Covered share straight through at IOR 1, else blocked; the uncovered rest passes
[CudaDeviceExport] public func occluderTransmittance(toward: float3, n: float3, material: Material, coverage: float) -> float3 {
    let through: float3 = material.ior == 1.0f ? straightThrough(material) : float3(0.0f);
    return through * coverage + (1.0f - coverage);
}

__include walk;

[CudaDeviceExport] public func hash(x: uint) -> uint {
    let state: uint = x * 747796405u + 2891336453u;
    let word: uint = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

[CudaDeviceExport] public func stream(seed: uint, index: uint) -> uint {
    return hash(seed ^ hash(index));
}
