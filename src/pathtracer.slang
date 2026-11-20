module pathtracer;

public static const float PI = 3.141592653589793;
public static const float MAX_SAFE_INTEGER_FOR_F32 = 8388607.0;
public static const uint UINT_MAX = 4294967295u;
public static const float BIAS = 0.0000152587890625;
public static const float INV_PI = 0.3183098861837907;
// SHEEN_ALBEDO nodes per side, least sheen_roughness
public static const uint SHEEN_NODES = 24u;
public static const float SHEEN_LEAST = 0.05f;
public static const float LEAST_NORMAL = 1.17549435e-38f;
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
// albedo = integral f * n_dot_l dl over the hemisphere, f of the velvet lobe
// VELVET_ALBEDO[i * SHEEN_NODES + j] = albedo at
// sqrt(n_dot_v) = i / (SHEEN_NODES - 1)
// sqrt(sheen_roughness) = sqrt(VELVET_LEAST) + j / (SHEEN_NODES - 1) * (1 - sqrt(VELVET_LEAST))
// bilinear VELVET_ALBEDO >= albedo
public static const float VELVET_LEAST = 0.1f;
public static const float VELVET_ALBEDO[576] = {
    1.00384f, 1.00429f, 1.00357f, 1.00304f, 1.00262f, 1.00229f, 1.00199f, 1.00171f, 1.00144f,
    1.00121f, 1.00103f, 1.00092f, 1.00088f, 1.0009f, 1.00096f, 1.00106f, 1.00115f, 1.00124f,
    1.00129f, 1.00132f, 1.00133f, 1.00133f, 1.00132f, 1.0013f, 0.990864f, 0.993469f, 0.994398f,
    0.995135f, 0.995742f, 0.996265f, 0.996718f, 0.997099f, 0.997406f, 0.997648f, 0.997835f, 0.997986f,
    0.998119f, 0.998255f, 0.998405f, 0.998571f, 0.998747f, 0.998929f, 0.999092f, 0.999239f, 0.999369f,
    0.99948f, 0.999575f, 0.999658f, 0.940888f, 0.951281f, 0.958666f, 0.964509f, 0.96921f, 0.973053f,
    0.976235f, 0.978901f, 0.981157f, 0.983085f, 0.984749f, 0.986197f, 0.987467f, 0.988588f, 0.989584f,
    0.990473f, 0.99127f, 0.991983f, 0.992621f, 0.993189f, 0.993724f, 0.994268f, 0.994753f, 0.995144f,
    0.861311f, 0.884634f, 0.902127f, 0.915955f, 0.927082f, 0.936173f, 0.943701f, 0.950007f, 0.955347f,
    0.959912f, 0.963847f, 0.967268f, 0.970262f, 0.972899f, 0.975236f, 0.977316f, 0.979174f, 0.980839f,
    0.982335f, 0.983681f, 0.984893f, 0.985985f, 0.986973f, 0.987873f, 0.753063f, 0.79328f, 0.824187f,
    0.848819f, 0.86875f, 0.885062f, 0.898585f, 0.909924f, 0.91953f, 0.927746f, 0.934832f, 0.940992f,
    0.946384f, 0.951135f, 0.955344f, 0.95909f, 0.962437f, 0.965437f, 0.968132f, 0.970557f, 0.972742f,
    0.974712f, 0.97649f, 0.978094f, 0.621835f, 0.680521f, 0.727052f, 0.764527f, 0.795056f, 0.820212f,
    0.841203f, 0.858856f, 0.873841f, 0.886675f, 0.897758f, 0.907399f, 0.915846f, 0.923291f, 0.92989f,
    0.935765f, 0.941015f, 0.945722f, 0.94995f, 0.953756f, 0.957185f, 0.960277f, 0.963067f, 0.965586f,
    0.477425f, 0.552219f, 0.614155f, 0.665209f, 0.707449f, 0.742621f, 0.772139f, 0.797116f, 0.818419f,
    0.83673f, 0.852584f, 0.866409f, 0.878543f, 0.88925f, 0.898748f, 0.907211f, 0.914778f, 0.921565f,
    0.927665f, 0.933157f, 0.938106f, 0.942571f, 0.946601f, 0.950239f, 0.335396f, 0.419081f, 0.492476f,
    0.555312f, 0.608791f, 0.654156f, 0.692747f, 0.725712f, 0.754025f, 0.778491f, 0.799762f, 0.818366f,
    0.834743f, 0.849223f, 0.862089f, 0.873567f, 0.883842f, 0.893064f, 0.901358f, 0.908829f, 0.915566f,
    0.921645f, 0.927134f, 0.93209f, 0.211945f, 0.293658f, 0.371105f, 0.441439f, 0.503697f, 0.558013f,
    0.605212f, 0.646143f, 0.681699f, 0.712683f, 0.739794f, 0.763627f, 0.784676f, 0.803355f, 0.820001f,
    0.834882f, 0.848224f, 0.860215f, 0.871011f, 0.880745f, 0.889528f, 0.897458f, 0.90462f, 0.91109f,
    0.119495f, 0.187457f, 0.259972f, 0.33121f, 0.397735f, 0.458323f, 0.51249f, 0.560488f, 0.602898f,
    0.640327f, 0.673396f, 0.702685f, 0.728704f, 0.751896f, 0.772636f, 0.791245f, 0.80797f, 0.823031f,
    0.836613f, 0.848874f, 0.859949f, 0.869957f, 0.879003f, 0.887179f, 0.0594293f, 0.108397f, 0.167857f,
    0.232366f, 0.297675f, 0.36023f, 0.418429f, 0.471708f, 0.519818f, 0.563013f, 0.601712f, 0.63636f,
    0.667397f, 0.69525f, 0.720287f, 0.742835f, 0.763176f, 0.781557f, 0.798171f, 0.813197f, 0.82679f,
    0.839088f, 0.850214f, 0.860279f, 0.0258466f, 0.0561967f, 0.0991767f, 0.151623f, 0.209416f, 0.269025f,
    0.327575f, 0.383184f, 0.435016f, 0.482714f, 0.526208f, 0.565701f, 0.601497f, 0.633921f, 0.663282f,
    0.689885f, 0.713997f, 0.735866f, 0.755704f, 0.773691f, 0.789997f, 0.804775f, 0.818162f, 0.830283f,
    0.00968609f, 0.0259175f, 0.0531883f, 0.0912181f, 0.137777f, 0.189763f, 0.24416f, 0.298808f, 0.351693f,
    0.401805f, 0.448722f, 0.492132f, 0.532065f, 0.568665f, 0.602143f, 0.632725f, 0.660623f, 0.686054f,
    0.709223f, 0.730312f, 0.749484f, 0.766897f, 0.7827f, 0.797029f, 0.00303823f, 0.0104824f, 0.025683f,
    0.0502538f, 0.0840864f, 0.125614f, 0.1725f, 0.22232f, 0.273094f, 0.323218f, 0.371491f, 0.417324f,
    0.460363f, 0.500438f, 0.537558f, 0.571813f, 0.60333f, 0.632269f, 0.658774f, 0.68302f, 0.705146f,
    0.725304f, 0.743639f, 0.760291f, 0.000762043f, 0.00361976f, 0.0110037f, 0.0251297f, 0.0472746f, 0.07746f,
    0.114603f, 0.156957f, 0.202585f, 0.249717f, 0.297078f, 0.343409f, 0.387995f, 0.430435f, 0.470397f,
    0.507771f, 0.542537f, 0.574734f, 0.604447f, 0.631794f, 0.656868f, 0.679797f, 0.700712f, 0.719746f,
    0.000143453f, 0.00102307f, 0.00407376f, 0.011227f, 0.024238f, 0.0441518f, 0.0710906f, 0.104334f, 0.142594f,
    0.184347f, 0.228108f, 0.272652f, 0.316964f, 0.360164f, 0.401788f, 0.441395f, 0.478756f, 0.513756f,
    0.546351f, 0.576583f, 0.604474f, 0.630091f, 0.653529f, 0.674889f, 1.85842e-05f, 0.000222797f, 0.00124967f,
    0.00435766f, 0.0111303f, 0.0229835f, 0.0407998f, 0.0647794f, 0.0944777f, 0.128973f, 0.16709f, 0.207602f,
    0.249369f, 0.291549f, 0.333204f, 0.373771f, 0.412743f, 0.44978f, 0.484678f, 0.517331f, 0.547692f,
    0.575728f, 0.601478f, 0.625011f, 1.46482e-06f, 3.42905e-05f, 0.000298502f, 0.00140504f, 0.00443578f, 0.0106926f,
    0.0213388f, 0.0371411f, 0.0583603f, 0.0847638f, 0.115723f, 0.150356f, 0.187665f, 0.226655f, 0.266477f,
    0.306324f, 0.345509f, 0.383444f, 0.419707f, 0.454014f, 0.486187f, 0.516142f, 0.543842f, 0.569309f,
    5.83938e-08f, 3.2766e-06f, 5.0554e-05f, 0.000351117f, 0.00145684f, 0.00427944f, 0.00989369f, 0.0192739f, 0.0331028f,
    0.0516872f, 0.0749557f, 0.102509f, 0.133701f, 0.167728f, 0.203721f, 0.240843f, 0.278401f, 0.315642f,
    0.351908f, 0.386748f, 0.419856f, 0.451042f, 0.48021f, 0.50734f, 8.73966e-10f, 1.57742e-07f, 5.21975e-06f,
    6.07958e-05f, 0.000362196f, 0.00138046f, 0.00386845f, 0.00871635f, 0.0167555f, 0.028608f, 0.0446128f, 0.0648084f,
    0.0889527f, 0.116567f, 0.147001f, 0.179507f, 0.213318f, 0.24785f, 0.282377f, 0.316319f, 0.349232f,
    0.380831f, 0.410941f, 0.439467f, 2.88664e-12f, 2.63672e-09f, 2.51094e-07f, 5.9752e-06f, 5.85958e-05f, 0.000319294f,
    0.00116374f, 0.00319524f, 0.00714874f, 0.0137449f, 0.0235638f, 0.0369682f, 0.0540731f, 0.0747511f, 0.0986646f,
    0.125319f, 0.154124f, 0.184462f, 0.215736f, 0.247411f, 0.279039f, 0.310264f, 0.340825f, 0.370542f,
    6.94489e-16f, 7.0429e-12f, 3.21448e-09f, 2.20181e-07f, 4.50593e-06f, 4.15484e-05f, 0.00022263f, 0.00081576f, 0.00227531f,
    0.00519367f, 0.0102001f, 0.0178546f, 0.0285685f, 0.0425603f, 0.0598447f, 0.0802502f, 0.103456f, 0.129044f,
    0.156547f, 0.185496f, 0.215455f, 0.246035f, 0.276908f, 0.307802f, 5.46278e-22f, 3.43168e-16f, 2.29295e-12f,
    9.57797e-10f, 6.87987e-08f, 1.55336e-06f, 1.60082e-05f, 9.55524e-05f, 0.000386313f, 0.00117554f, 0.00289549f, 0.00607588f,
    0.0112671f, 0.0189627f, 0.0295413f, 0.0432329f, 0.0601113f, 0.080105f, 0.10302f, 0.12857f, 0.156403f,
    0.186128f, 0.21734f, 0.249632f, 0.0f, 0.0f, 3.0989e-24f, 2.21276e-18f, 2.67358e-14f, 2.2444e-11f,
    3.13075e-09f, 1.26481e-07f, 2.12952e-06f, 1.90777e-05f, 0.00010754f, 0.000428927f, 0.00131605f, 0.00330014f, 0.00707077f,
    0.0133791f, 0.0229194f, 0.0362238f, 0.0535936f, 0.0750723f, 0.100459f, 0.12935f, 0.161196f, 0.195364f,
};
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

__extern_cpp public struct Random {
    __extern_cpp public uint state;
    __extern_cpp public float value;
};

__extern_cpp public struct RandomSphere {
    __extern_cpp public uint state;
    __extern_cpp public float3 value;
};

[CudaDeviceExport] public func rgb_to_greyscale(rgb: float3) -> float {
    return dot(rgb, float3(0.299, 0.587, 0.114));
}

float random(inout uint state) { return ((state = hash(state)) >> 8) * 0x1p-24f; }

[CudaDeviceExport] public Random pcg(uint state) {
    __target_switch {
    case wgsl:
    case glsl:
    // PCG random number generator
    // Reference: http://www.pcg-random.org/
    return Random(state * 747796405u + 2891336453u, float(hash(state)) / float(UINT_MAX));
    default:
        const float value = random(state);
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
        let cos_psi = sqrt(max(0.0f, 1.0f - sin_psi * sin_psi));
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
    t = normalize(t - n * dot(n, t));
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

// out_dir on in_dir's side of g_n: BSDF * n_dot_l = throughput_diffuse * PDF_diffuse + throughput_reflect * PDF_reflect
// + throughput_sheen * PDF_sheen + throughput_toon * PDF_toon
// otherwise: BSDF * n_dot_l = throughput_refract * PDF_refract
// as throughput = BSDF_lobe * n_dot_l / PDF_lobe
[CudaDeviceExport] public func BSDF(in_dir: float3, out_dir: float3, n: float3, g_n: float3, material: Material, eta_i: float, eta_o: float, random_state: uint, terms: MaterialTerms, view_terms: ViewTerms) -> float3 {
    let v: float3 = negate(in_dir);
    let n_dot_v: float = dot(n, v);
    let n_i: float3 = n * sign(n_dot_v);
    let n_i_dot_l: float = dot(n_i, out_dir);
    let alpha: float = material.roughness * material.roughness;
    // Diffuse, reflection and sheen, then toon where present, on the same side; refraction alone across
    // Test if v and l are on the same side of the surface
    let same_side: bool = dot(g_n, v) * dot(g_n, out_dir) > 0.0f;
#ifdef FK_TOON
    let toon: uint = abs(material.toon.x) > 0.0f ? 1u : 0u;
#else
    let toon: uint = 0u;
#endif
    let lobes: uint = same_side ? 3u + toon : 1u;
    var f: float3 = float3(0.0f);
    // The lobe's half vector and its terms, taken again only where they differ from the last lobe's
    var half_of: uint = UINT_MAX;
    var ggx_n: float3 = float3(0.0f);
    var lobe_terms: HalfTerms = {};
    for (var i: uint = 0u; i < lobes; i++) {
        let lobe: uint = !same_side ? LOBE_REFRACT : i == 0u ? LOBE_DIFFUSE : i == 1u ? LOBE_REFLECT
            : i == 2u ? LOBE_SHEEN_VELVET : LOBE_TOON;
        // sampleBSDF's half vector for the diffuse and toon lobes, out_dir's reflective one for reflection and sheen
        let lobe_half: uint = lobe == LOBE_TOON ? LOBE_DIFFUSE : lobe == LOBE_SHEEN_VELVET ? LOBE_REFLECT : lobe;
        if (lobe_half != half_of) {
            if (lobe_half == LOBE_DIFFUSE) {
                ggx_n = sampledHalf(in_dir, n, material, random_state, view_terms);
            } else if (lobe_half == LOBE_REFRACT) {
                ggx_n = refractedHalf(in_dir, out_dir, n, eta_i, eta_o);
            } else {
                ggx_n = reflectedHalf(in_dir, out_dir);
            }
            lobe_terms = precomputeHalf(in_dir, ggx_n, material, eta_i, eta_o, terms, view_terms);
            half_of = lobe_half;
        }
        var pdf: float = 0.0f;
        var throughput: float3 = float3(0.0f);
        switch (lobe) {
        case LOBE_DIFFUSE:
            pdf = diffusePDF(n_i_dot_l, 0.0f, abs(n_dot_v), alpha, lobe_terms, eta_i, eta_o);
            throughput = diffuseBSDF(out_dir, n_i, alpha, material, lobe_terms);
            break;
        case LOBE_REFRACT:
            pdf = refractPDF(n_i_dot_l, dot(out_dir, ggx_n), abs(n_dot_v), alpha, lobe_terms, eta_i, eta_o);
            throughput = refractBSDF(out_dir, n_i, alpha, material, lobe_terms);
            break;
        case LOBE_SHEEN_VELVET:
            pdf = sheenVelvetPDF(n_i_dot_l, 0.0f, abs(n_dot_v), alpha, lobe_terms, eta_i, eta_o);
            throughput = sheenVelvetBSDF(out_dir, n_i, alpha, material, lobe_terms);
            break;
#ifdef FK_TOON
        case LOBE_TOON:
            pdf = toonPDF(n_i_dot_l, dot(out_dir, lobe_terms.toon_axis), abs(n_dot_v), alpha, lobe_terms, eta_i,
                eta_o);
            throughput = toonBSDF(out_dir, n_i, alpha, material, lobe_terms);
            break;
#endif
        default:
            pdf = reflectPDF(n_i_dot_l, 0.0f, abs(n_dot_v), alpha, lobe_terms, eta_i, eta_o);
            throughput = reflectBSDF(out_dir, n_i, alpha, material, lobe_terms);
            break;
        }
        // Directions the lobe can't sample carry no throughput
        let weighted: float3 = pdf > 0.0f ? throughput * pdf : float3(0.0f);
        f = i == 0u ? weighted : f + weighted;
    }
    return f;
}

// Diffuse lobe toward out_dir through the shading normal: added behind the geometry normal,
// removed in front of it, where BSDF counted it
[CudaDeviceExport] public func translucentCorrection(in_dir: float3, out_dir: float3, n: float3, g_n: float3, material: Material, eta_i: float, eta_o: float, random_state: uint, terms: MaterialTerms, view_terms: ViewTerms) -> float3 {
    // Refractive half-vector (eq. 16)
    let through: bool = dot(n, out_dir) * dot(n, negate(in_dir)) < 0.0f;
    let n_dot_v: float = dot(n, negate(in_dir));
    let n_i: float3 = n * sign(n_dot_v);
    let alpha: float = material.roughness * material.roughness;
    let sampled: HalfTerms = precomputeHalf(in_dir, sampledHalf(in_dir, n, material, random_state, view_terms),
        material, eta_i, eta_o, terms, view_terms);
    let diffuse_pdf: float = diffusePDF(dot(n_i, out_dir), 0.0f, abs(n_dot_v), alpha, sampled, eta_i, eta_o);
    let diffuse: float3 = diffuse_pdf > 0.0f ? diffuseBSDF(out_dir, n_i, alpha, material, sampled) * diffuse_pdf
        : float3(0.0f);
    let incident: bool = dot(g_n, negate(in_dir)) * dot(g_n, out_dir) > 0.0f;
    return select(float3(0.0f), diffuse * select(1.0f, -1.0f, incident), through);
}

// BSDF * n_dot_l with a translucent diffuse lobe
[CudaDeviceExport] public func translucentBSDF(in_dir: float3, out_dir: float3, n: float3, g_n: float3, material: Material, eta_i: float, eta_o: float, random_state: uint) -> float3 {
    // The material's and the view's values once for both
    let terms: MaterialTerms = precomputeMaterial(material, eta_i, eta_o);
    let view_terms: ViewTerms = precomputeView(in_dir, n, material, terms);
    return BSDF(in_dir, out_dir, n, g_n, material, eta_i, eta_o, random_state, terms, view_terms)
        + translucentCorrection(in_dir, out_dir, n, g_n, material, eta_i, eta_o, random_state, terms, view_terms);
}

__extern_cpp public struct SampleBSDF {
    __extern_cpp public float3 unit_direction;
    __extern_cpp public float3 throughput;
    __extern_cpp public uint random_state;
    __extern_cpp public bool refracted;
    __extern_cpp public uint lobe;
    // Solid angle PDF, 0 for delta lobes
    __extern_cpp public float pdf;
}

// Half vector terms of sampleBSDF, shared with the lobes' evaluation toward a given out_dir
__extern_cpp public struct HalfTerms {
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
    // Toon lobe: probability, weight, a, s, b, glossy, K or W, P(theta_v) and the axis R or n
    __extern_cpp public float p_toon = 0.0f;
    __extern_cpp public float3 toon = float3(0.0f);
    __extern_cpp public float toon_a = 0.0f;
    __extern_cpp public float toon_s = 0.0f;
    __extern_cpp public float toon_b = 0.0f;
    __extern_cpp public bool toon_glossy = false;
    __extern_cpp public float toon_norm = 1.0f;
    __extern_cpp public float toon_view = 0.0f;
    __extern_cpp public float3 toon_axis = float3(0.0f);
#endif
}

// Tangent and roughness along tangent and bitangent, 0 when isotropic
__extern_cpp public struct AnisotropicFrame {
    __extern_cpp public float3 tangent;
    __extern_cpp public float2 alphas;
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

// The material's own values on the side of eta_i, the same for every view and half vector of a vertex
__extern_cpp public struct MaterialTerms {
    __extern_cpp public float f0;
    __extern_cpp public float eta_level;
    __extern_cpp public float translucent_share;
#ifdef FK_TOON
    __extern_cpp public float toon_scale;
    __extern_cpp public float toon_component;
    __extern_cpp public float3 toon;
    __extern_cpp public float toon_a;
    __extern_cpp public float toon_s;
    __extern_cpp public float toon_b;
    __extern_cpp public bool toon_glossy;
    __extern_cpp public float toon_norm;
#endif
}
[CudaDeviceExport] public func precomputeMaterial(material: Material, eta_i: float, eta_o: float) -> MaterialTerms {
    // r = sqrt(specular_level) * |eta_i - eta_o| / (eta_i + eta_o)
    // F0 = r^2
    // F0 = ((eta_level - 1) / (eta_level + 1))^2
    // => eta_level = (1 + r) / (1 - r)
    let r: float = min(sqrt(material.specular_level) * abs(eta_i - eta_o) / (eta_i + eta_o), 1.0f - BIAS);
    let f0: float = r * r;
    let eta_level: float = (1.0f + r) / (1.0f - r);
#ifdef FK_TOON
    // Toon of mark (w, w * Size, w * Smooth), glossy for w < 0
    // a = Size * PI / 2, s = Smooth * PI / 2, b = min(a + s, PI / 2)
    // P(t) = 1 below a, 1 - (t - a) / s up to a + s, 0 beyond
    // G(t) = integral_0^t P cos sin = sin(min(t, a))^2 / 2 + (1 + a / s) * (cos(2a) - cos(2t)) / 4
    //      - ((sin(2t) / 8 - t * cos(2t) / 4) - (sin(2a) / 8 - a * cos(2a) / 4)) / s beyond a
    // H(t) = integral_0^t P sin = 1 - cos(min(t, a)) + (1 + a / s) * (cos(a) - cos(t))
    //      - ((sin(t) - t * cos(t)) - (sin(a) - a * cos(a))) / s beyond a
    // K = 2 * PI * G(b), W = 2 * PI * H(b), R = 2 * n_dot_v * n - v
    // Base lobes scaled by 1 - |w|, the toon of weight toon = |w| * albedo chosen by |w| * greyscale(albedo)
    var toon_scale: float = 1.0f;
    var toon_component: float = 0.0f;
    var toon: float3 = float3(0.0f);
    var toon_a: float = 0.0f;
    var toon_s: float = 0.0f;
    var toon_b: float = 0.0f;
    var toon_norm: float = 1.0f;
    let toon_glossy: bool = material.toon.x < 0.0f;
    if (abs(material.toon.x) > 0.0f) {
        toon_scale = 1.0f - min(abs(material.toon.x), 1.0f);
        toon_component = min(abs(material.toon.x), 1.0f) * rgb_to_greyscale(material.albedo);
        toon = min(abs(material.toon.x), 1.0f) * material.albedo;
        toon_a = clamp(material.toon.y / material.toon.x, 1e-5f, 1.0f) * PI / 2.0f;
        toon_s = clamp(material.toon.z / material.toon.x, 0.0f, 1.0f) * PI / 2.0f;
        toon_b = min(toon_a + toon_s, PI / 2.0f);
        let a: float = toon_a;
        let b: float = toon_b;
        var integral: float = toon_glossy ? 1.0f - cos(min(b, a)) : sin(min(b, a)) * sin(min(b, a)) / 2.0f;
        if (b > a && toon_s > 0.0f) {
            integral += toon_glossy ? (1.0f + a / toon_s) * (cos(a) - cos(b))
                - ((sin(b) - b * cos(b)) - (sin(a) - a * cos(a))) / toon_s
                : (1.0f + a / toon_s) * (cos(2.0f * a) - cos(2.0f * b)) / 4.0f
                - ((sin(2.0f * b) / 8.0f - b * cos(2.0f * b) / 4.0f)
                - (sin(2.0f * a) / 8.0f - a * cos(2.0f * a) / 4.0f)) / toon_s;
        }
        toon_norm = 2.0f * PI * integral;
    }
    return MaterialTerms(f0, eta_level, translucentShare(material), toon_scale, toon_component, toon, toon_a, toon_s,
        toon_b, toon_glossy, toon_norm);
#else
    return MaterialTerms(f0, eta_level, translucentShare(material));
#endif
}

// The view's values at a vertex, the same for every half vector: frame, sheen, toon and the metal's rebounce
__extern_cpp public struct ViewTerms {
    __extern_cpp public float3 v;
    __extern_cpp public float3 n_i;
    __extern_cpp public AnisotropicFrame frame;
    __extern_cpp public float3 scale;
    __extern_cpp public float sheen_component;
    __extern_cpp public float3 sheen;
    __extern_cpp public float3 view;
    __extern_cpp public float3 rebounce;
#ifdef FK_TOON
    __extern_cpp public float toon_view;
    __extern_cpp public float3 toon_axis;
#endif
}
[CudaDeviceExport] public func precomputeView(in_dir: float3, n: float3, material: Material, terms: MaterialTerms)
    -> ViewTerms {
    let v: float3 = negate(in_dir);
    let n_i: float3 = n * sign(dot(n, v));
    let frame: AnisotropicFrame = anisotropicFrame(material, n_i);
    // albedo = exp(bilinear SHEEN_ALBEDO), bilinear VELVET_ALBEDO for velvet
    // BSDF = sheen * f
    // sheen = material.sheen / max(albedo, 1)
    // => integral BSDF * n_dot_l dl = material.sheen * min(albedo, 1)
    // scale = 1 - material.sheen * min(albedo, 1)
    // sheen_component = greyscale(material.sheen) * min(albedo, 1)
    var scale: float3 = float3(1.0f);
    var sheen_component: float = 0.0f;
    var sheen: float3 = float3(0.0f);
    var view: float3 = float3(0.0f);
    if (sheenUsed() && rgb_to_greyscale(material.sheen) > 0.0f) {
        let x: float = clamp(sqrt(max(dot(n_i, v), 0.0f)), 0.0f, 1.0f) * float(SHEEN_NODES - 1u);
        let i: uint = min(uint(x), SHEEN_NODES - 2u);
        var least: float = sqrt(SHEEN_LEAST);
        least = select(least, sqrt(VELVET_LEAST), velvetUsed() && material.velvet > 0.0f);
        let y: float = (clamp(sqrt(max(material.sheen_roughness, 0.0f)), least, 1.0f) - least) / (1.0f - least)
            * float(SHEEN_NODES - 1u);
        let j: uint = min(uint(y), SHEEN_NODES - 2u);
        let k: uint = i * SHEEN_NODES + j;
        let u: float = x - float(i);
        let t: float = y - float(j);
        var a: float = SHEEN_ALBEDO[k] + (SHEEN_ALBEDO[k + SHEEN_NODES] - SHEEN_ALBEDO[k]) * u;
        var b: float = SHEEN_ALBEDO[k + 1u] + (SHEEN_ALBEDO[k + SHEEN_NODES + 1u] - SHEEN_ALBEDO[k + 1u]) * u;
        var albedo: float = exp(a + (b - a) * t);
        if (velvetUsed() && material.velvet > 0.0f) {
            a = VELVET_ALBEDO[k] + (VELVET_ALBEDO[k + SHEEN_NODES] - VELVET_ALBEDO[k]) * u;
            b = VELVET_ALBEDO[k + 1u] + (VELVET_ALBEDO[k + SHEEN_NODES + 1u] - VELVET_ALBEDO[k + 1u]) * u;
            albedo = a + (b - a) * t;
        }
        scale = 1.0f - material.sheen * min(albedo, 1.0f);
        sheen_component = rgb_to_greyscale(material.sheen) * min(albedo, 1.0f);
        sheen = material.sheen / max(albedo, 1.0f);
        view = v;
    }
#ifdef FK_TOON
    // P(theta_v) = 1 below a, 1 - (theta_v - a) / s up to a + s, 0 beyond
    // R = 2 * n_dot_v * n - v of a glossy toon, n of a diffuse one
    // => scale holds toon_scale = 1 - |w|
    // => toon_view = P(theta_v)
    // => toon_axis = R
    scale *= terms.toon_scale;
    var toon_view: float = 0.0f;
    var toon_axis: float3 = n_i;
    if (abs(material.toon.x) > 0.0f) {
        let theta_v: float = acos(min(dot(n_i, v), 1.0f));
        toon_view = theta_v < terms.toon_a ? 1.0f
            : max(1.0f - (theta_v - terms.toon_a) / max(terms.toon_s, BIAS), 0.0f);
        toon_axis = terms.toon_glossy ? normalize(2.0f * dot(n_i, v) * n_i - v) : n_i;
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
#ifdef FK_TOON
    return ViewTerms(v, n_i, frame, scale, sheen_component, sheen, view, rebounce, toon_view, toon_axis);
#else
    return ViewTerms(v, n_i, frame, scale, sheen_component, sheen, view, rebounce);
#endif
}

// The values of one half vector ggx_n at a vertex, the lobes' weights and shares
[CudaDeviceExport] public func precomputeHalf(in_dir: float3, ggx_n: float3, material: Material, eta_i: float,
    eta_o: float, terms: MaterialTerms, view_terms: ViewTerms) -> HalfTerms {
    let v: float3 = view_terms.v;
    let n_i: float3 = view_terms.n_i;
    let frame: AnisotropicFrame = view_terms.frame;
    // Calculate shared half vector dot products
    let v_dot_h: float = dot(ggx_n, v);
    let n_dot_h: float = dot(n_i, ggx_n);
    // Try refraction through the properly oriented half vector
    let eta: float = eta_i / eta_o;
    let refracted: float3 = normalize(refract(in_dir, ggx_n, eta));
    // F_dielectric = specular_tint * F0 + (1 - specular_tint * F0) * (F(eta_level) - F0) / (1 - F0)
    // F_dielectric = 1 past total internal reflection: eta_i^2 * (1 - v_dot_h^2) >= eta_o^2
    let f0: float = terms.f0;
    let eta_level: float = terms.eta_level;
    let F_level: float = fresnel(abs(v_dot_h), eta_i > eta_o ? eta_level : 1.0f, eta_i > eta_o ? 1.0f : eta_level);
    let total: bool = eta_i * eta_i * (1.0f - v_dot_h * v_dot_h) >= eta_o * eta_o;
    let F_dielectric: float3 = total ? float3(1.0f) : material.specular_tint * f0 + (1.0f - material.specular_tint * f0)
        * (F_level - f0) / (1.0f - f0);
    let scale: float3 = view_terms.scale;
    let sheen_component: float = view_terms.sheen_component;
    let sheen: float3 = view_terms.sheen;
    let view: float3 = view_terms.view;
#ifdef FK_TOON
    let toon_component: float = terms.toon_component;
#endif
    let rebounce: float3 = view_terms.rebounce;
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
    return HalfTerms(v_dot_h, n_dot_h, refracted, F, F_greyscale, reflect_weight, diffuse_weight, refract_weight,
        p_diffuse, p_reflect, p_refract, terms.translucent_share, sheen, p_sheen_velvet, view, frame.tangent,
        frame.alphas, visible, toon_component * base_component_inv, terms.toon, terms.toon_a, terms.toon_s,
        terms.toon_b, terms.toon_glossy, terms.toon_norm, view_terms.toon_view, view_terms.toon_axis);
#else
    return HalfTerms(v_dot_h, n_dot_h, refracted, F, F_greyscale, reflect_weight, diffuse_weight, refract_weight, p_diffuse, p_reflect, p_refract, terms.translucent_share, sheen, p_sheen_velvet, view, frame.tangent, frame.alphas, visible);
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
    // Any perpendicular where the tangent lies along the normal
    let projected: float3 = material.tangent - n_i * dot(n_i, material.tangent);
    let t: float3 = normalize(select(tangentToWorld(float3(1.0f, 0.0f, 0.0f), n_i), projected, dot(projected, projected) > 0.0f));
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
[CudaDeviceExport] public func vndfPDF(n_i_dot_v: float, alpha: float, lobes: HalfTerms) -> float {
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
    lobes: HalfTerms) -> float3 {
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
    lobes: HalfTerms, eta_i: float, eta_o: float, random_state: uint) -> SampleBSDF {
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
    lobes: HalfTerms, eta_i: float, eta_o: float) -> float {
    // PDF_COSINE_HEMISPHERE = cosine_hemisphere.y / PI
    // => PDF = cosine_hemisphere.y / PI
    // Translucent: PDF = share * |cosine_hemisphere.y| / PI behind, (1 - share) * cosine_hemisphere.y / PI in front
    let share: float = lobes.translucent_share;
    return select(0.0f, select(lobes.p_diffuse * n_i_dot_l * INV_PI, lobes.p_diffuse * abs(n_i_dot_l) * INV_PI
        * select(1.0f - share, share, n_i_dot_l < 0.0f), share > 0.0f), n_i_dot_v > 0.0f);
}

[CudaDeviceExport] public func sheenVelvetBSDF(l: float3, n_i: float3, alpha: float, material: Material,
    lobes: HalfTerms) -> float3 {
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
    if (velvetUsed() && material.velvet > 0.0f) {
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
    lobes: HalfTerms, eta_i: float, eta_o: float, random_state: uint) -> SampleBSDF {
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
    lobes: HalfTerms, eta_i: float, eta_o: float) -> float {
    // PDF_UNIFORM_HEMISPHERE = 1 / (2 * PI)
    // => PDF = p_sheen_velvet / (2 * PI)
    return select(0.0f, lobes.p_sheen_velvet * 0.5f * INV_PI, n_i_dot_l > 0.0f && n_i_dot_v > 0.0f);
}

#ifdef FK_TOON
[CudaDeviceExport] public func toonBSDF(l: float3, n_i: float3, alpha: float, material: Material,
    lobes: HalfTerms) -> float3 {
    // BSDF = toon * P(theta_v) * P(theta_l) / K
    // => BSDF * n_dot_l = toon * P(theta_v) * P(theta_l) * n_dot_l / K

    // throughput = BSDF * n_dot_l / PDF
    //            = toon * P(theta_v) * P(theta_l) * n_dot_l / K / p_toon / P(theta_l) / n_dot_l * K
    //            = toon * P(theta_v) / p_toon

    // toon_view holds P(theta_v)
    // => throughput = toon * toon_view / p_toon
    //
    // Glossy: BSDF = toon * P(alpha) / W, PDF = p_toon * P(alpha) / W
    // => throughput = toon * n_dot_l / p_toon, 0 below the surface
    return lobes.toon * select(lobes.toon_view, max(dot(n_i, l), 0.0f), lobes.toon_glossy) / lobes.p_toon;
}

// Toon case of sampleBSDF
[CudaDeviceExport] public func toonSample(n_i: float3, n_i_dot_v: float, alpha: float, material: Material,
    lobes: HalfTerms, eta_i: float, eta_o: float, random_state: uint) -> SampleBSDF {
    var sample: SampleBSDF = SampleBSDF(float3(1.0f), float3(1.0f), 0u, false, 0u, 0.0f);
    let random_t_1: Random = pcg(random_state);
    let random_t_2: Random = pcg(random_t_1.state);
    sample.random_state = random_t_2.state;
    // Sample toon profile
    // target = u_1 * K / (2 * PI), t = G^-1(target), H^-1 glossy, closed below a
    // t = t - (G(t) - target) / (P(t) * sin(t) * cos(t)), P(t) * sin(t) glossy, 8 steps from (a + b) / 2
    let a: float = lobes.toon_a;
    let s: float = lobes.toon_s;
    let glossy: bool = lobes.toon_glossy;
    let target: float = random_t_1.value * lobes.toon_norm / (2.0f * PI);
    let core: float = glossy ? acos(clamp(1.0f - target, -1.0f, 1.0f)) : asin(min(sqrt(2.0f * target), 1.0f));
    var t: float = core < a ? core : (a + lobes.toon_b) / 2.0f;
    for (var k: int = 0; k < 8; k++) {
        let profile: float = t < a ? 1.0f : max(1.0f - (t - a) / max(s, BIAS), 0.0f);
        var integral: float = glossy ? 1.0f - cos(min(t, a)) : sin(min(t, a)) * sin(min(t, a)) / 2.0f;
        if (t > a && s > 0.0f) {
            integral += glossy ? (1.0f + a / s) * (cos(a) - cos(t))
                - ((sin(t) - t * cos(t)) - (sin(a) - a * cos(a))) / s
                : (1.0f + a / s) * (cos(2.0f * a) - cos(2.0f * t)) / 4.0f
                - ((sin(2.0f * t) / 8.0f - t * cos(2.0f * t) / 4.0f)
                - (sin(2.0f * a) / 8.0f - a * cos(2.0f * a) / 4.0f)) / s;
        }
        let slope: float = profile * sin(t) * (glossy ? 1.0f : cos(t));
        t = clamp(t - select(0.0f, (integral - target) / slope, slope > 0.0f), 0.0f, lobes.toon_b);
    }
    let phi: float = 2.0f * PI * random_t_2.value;
    sample.unit_direction = tangentToWorld(float3(sin(t) * cos(phi), cos(t), sin(t) * sin(phi)), lobes.toon_axis);
    sample.refracted = dot(n_i, sample.unit_direction) < 0.0f;
    sample.lobe = LOBE_TOON;
    sample.throughput = toonBSDF(sample.unit_direction, n_i, alpha, material, lobes);
    sample.pdf = toonPDF(dot(n_i, sample.unit_direction), dot(sample.unit_direction, lobes.toon_axis), n_i_dot_v, alpha,
        lobes, eta_i, eta_o);
    return sample;
}

[CudaDeviceExport] public func toonPDF(n_i_dot_l: float, l_dot_h: float, n_i_dot_v: float, alpha: float,
    lobes: HalfTerms, eta_i: float, eta_o: float) -> float {
    // PDF_TOON = P(theta_l) * n_dot_l / K
    // toon_norm holds K, W glossy
    // => PDF = p_toon * P(theta_l) * n_dot_l / K
    // Glossy: PDF = p_toon * P(alpha) / W, cos(alpha) = l_dot_h
    let t: float = acos(clamp(select(n_i_dot_l, l_dot_h, lobes.toon_glossy), -1.0f, 1.0f));
    let profile: float = t < lobes.toon_a ? 1.0f : max(1.0f - (t - lobes.toon_a) / max(lobes.toon_s, BIAS), 0.0f);
    return select(0.0f, lobes.p_toon * profile * select(n_i_dot_l, 1.0f, lobes.toon_glossy) / lobes.toon_norm,
        lobes.toon_glossy || n_i_dot_l > 0.0f);
}
#endif

[CudaDeviceExport] public func refractBSDF(l: float3, n_i: float3, alpha: float, material: Material,
    lobes: HalfTerms) -> float3 {
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
    material: Material, lobes: HalfTerms, eta_i: float, eta_o: float, random_state: uint) -> SampleBSDF {
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
    lobes: HalfTerms, eta_i: float, eta_o: float) -> float {
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
    lobes: HalfTerms) -> float3 {
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
    material: Material, lobes: HalfTerms, eta_i: float, eta_o: float, random_state: uint) -> SampleBSDF {
    var sample: SampleBSDF = SampleBSDF(float3(1.0f), float3(1.0f), 0u, false, 0u, 0.0f);
    sample.unit_direction = normalize(reflect(in_dir, ggx_n));
    sample.random_state = random_state;
    sample.lobe = LOBE_REFLECT;
    sample.throughput = reflectBSDF(sample.unit_direction, n_i, alpha, material, lobes);
    sample.pdf = reflectPDF(0.0f, 0.0f, n_i_dot_v, alpha, lobes, eta_i, eta_o);
    return sample;
}

[CudaDeviceExport] public func reflectPDF(n_i_dot_l: float, l_dot_h: float, n_i_dot_v: float, alpha: float,
    lobes: HalfTerms, eta_i: float, eta_o: float) -> float {
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

[CudaDeviceExport] public func sampleBSDF(in_dir: float3, n: float3, material: Material, eta_i: float, eta_o: float, random_init: uint, screen_space: float2, terms: MaterialTerms, view_terms: ViewTerms) -> SampleBSDF {
    var random_state: uint = random_init;
    // Basic dot products
    let v: float3 = negate(in_dir);
    let n_dot_v: float = dot(n, v);
    var n_i: float3 = n * sign(n_dot_v);
    let n_i_dot_v: float = abs(n_dot_v);
    // Material constants
    let alpha: float = material.roughness * material.roughness;
    // Sample using GGX importance sampling for potential refractive or reflective case
    let frame: AnisotropicFrame = view_terms.frame;
    let ggx_n: float3 = sampleHalfVector(v, n_i, alpha, frame, random_state);
    let lobes: HalfTerms = precomputeHalf(in_dir, ggx_n, material, eta_i, eta_o, terms, view_terms);

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
        return toonSample(n_i, n_i_dot_v, alpha, material, lobes, eta_i, eta_o, random_state);
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
    view_terms: ViewTerms) -> float3 {
    var state: uint = random_state;
    let v: float3 = negate(in_dir);
    // Diffuse half-vector of sampleBSDF
    return sampleHalfVector(v, n * sign(dot(n, v)), material.roughness * material.roughness, view_terms.frame, state);
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

// Light parts by wavelength only through a dispersive material's refraction
[CudaDeviceExport] public func dispersive(material: Material) -> bool {
    return material.dispersion > 0.0f && material.ior != 1.0f;
}

// Fraunhofer d, F and C lines in um
static const float LINE_D = 0.5875618f;
static const float LINE_F = 0.4861327f;
static const float LINE_C = 0.6562725f;

// Cauchy n(λ) = A + B / λ^2 through n_d = ior with Abbe number V = (n_d - 1) / (n_F - n_C) = 1 / dispersion, λ in um
// n_F - n_C = B (1 / λ_F^2 - 1 / λ_C^2) = (n_d - 1) dispersion
// => n(λ) = n_d + (n_d - 1) dispersion (1 / λ^2 - 1 / λ_d^2) / (1 / λ_F^2 - 1 / λ_C^2)
[CudaDeviceExport] public func dispersedIor(ior: float, dispersion: float, wavelength: float) -> float {
    let b: float = (ior - 1.0f) * dispersion / (1.0f / (LINE_F * LINE_F) - 1.0f / (LINE_C * LINE_C));
    return ior + select(0.0f, b * (1.0f / (wavelength * wavelength) - 1.0f / (LINE_D * LINE_D)), dispersion > 0.0f);
}

// w_c(λ) = M xyz(λ) D65(λ) every 5 nm from 380 to 780 nm: CIE 1931 2 degree observer, illuminant D65 and M from XYZ to
// linear Rec. 709, in 1 / um with integral w_c(λ) dλ = 1 per channel by trapezoids
// => a white light, D65, integrates to (1, 1, 1)
public static const float WAVELENGTH_WEIGHTS[243] = {
    0.0054747f, -0.0046569f, 0.032575f, 0.0093464f, -0.0079637f, 0.055773f, 0.018461f, -0.015794f, 0.11073f,
    0.041641f, -0.035775f, 0.25139f, 0.093493f, -0.080718f, 0.56742f, 0.15851f, -0.13765f, 0.97019f,
    0.30943f, -0.27083f, 1.9174f, 0.55218f, -0.48754f, 3.4689f, 0.95017f, -0.84802f, 6.0944f,
    1.4211f, -1.2893f, 9.452f, 1.7341f, -1.6063f, 12.128f, 2.0803f, -1.9881f, 15.687f,
    2.206f, -2.2012f, 18.477f, 2.0304f, -2.177f, 19.927f, 1.6343f, -2.0034f, 20.869f,
    0.99411f, -1.6263f, 20.578f, 0.20011f, -1.1141f, 19.721f, -0.6796f, -0.45403f, 17.776f,
    -1.6168f, 0.3786f, 14.715f, -2.5341f, 1.2754f, 11.865f, -3.3908f, 2.2146f, 9.1767f,
    -4.0375f, 3.0522f, 6.5951f, -4.613f, 3.8978f, 4.6459f, -5.4304f, 5.0121f, 3.3199f,
    -6.3777f, 6.3381f, 2.297f, -7.4414f, 7.9174f, 1.4539f, -8.3858f, 9.6011f, 0.66466f,
    -9.0168f, 11.24f, -0.044036f, -9.1775f, 12.632f, -0.58127f, -8.9755f, 13.915f, -0.9573f,
    -8.2529f, 14.862f, -1.2443f, -6.9213f, 15.039f, -1.4307f, -5.2917f, 14.909f, -1.5515f,
    -3.4322f, 14.705f, -1.6357f, -1.2719f, 14.244f, -1.6703f, 1.1517f, 13.322f, -1.6362f,
    3.7389f, 12.212f, -1.5692f, 6.4359f, 10.947f, -1.4773f, 9.1644f, 9.5477f, -1.364f,
    12.02f, 8.188f, -1.2545f, 14.787f, 6.7443f, -1.1311f, 16.723f, 5.0878f, -0.96561f,
    18.143f, 3.5702f, -0.80726f, 19.919f, 2.3627f, -0.69273f, 21.055f, 1.3137f, -0.58598f,
    21.39f, 0.4239f, -0.48298f, 20.993f, -0.23857f, -0.39412f, 19.822f, -0.68663f, -0.31502f,
    18.12f, -0.94125f, -0.24891f, 15.709f, -1.0202f, -0.19076f, 13.198f, -0.9892f, -0.14401f,
    11.24f, -0.93347f, -0.11133f, 9.3665f, -0.83821f, -0.085241f, 7.4125f, -0.70064f, -0.062832f,
    5.7123f, -0.56079f, -0.045867f, 4.4228f, -0.44653f, -0.033966f, 3.3449f, -0.34457f, -0.024825f,
    2.4931f, -0.26018f, -0.018081f, 1.8224f, -0.19216f, -0.01297f, 1.295f, -0.13767f, -0.0090757f,
    0.92929f, -0.099564f, -0.0064162f, 0.61836f, -0.066713f, -0.0042115f, 0.40212f, -0.043546f, -0.0027183f,
    0.28445f, -0.030872f, -0.0019144f, 0.20673f, -0.022461f, -0.0013883f, 0.15044f, -0.016345f, -0.0010103f,
    0.10942f, -0.011887f, -0.00073479f, 0.070997f, -0.0077135f, -0.00047679f, 0.045395f, -0.0049319f, -0.00030485f,
    0.034241f, -0.0037201f, -0.00022995f, 0.025576f, -0.0027787f, -0.00017176f, 0.018422f, -0.0020014f, -0.00012371f,
    0.013169f, -0.0014308f, -8.8439e-5f, 0.0083889f, -0.00091141f, -5.6337e-5f, 0.0053708f, -0.00058351f, -3.6068e-5f,
    0.0032828f, -0.00035666f, -2.2046e-5f, 0.0019601f, -0.00021296f, -1.3163e-5f, 0.0016894f, -0.00018354f, -1.1345e-5f,
    0.0014105f, -0.00015325f, -9.4725e-6f, 0.00097124f, -0.00010552f, -6.5224e-6f, 0.00066868f, -7.2649e-5f, -4.4906e-6f
};
// CDF of p(λ) at the nodes, p constant per bin with mass the mean of |w_r| + |w_g| + |w_b| at the bin's ends
public static const float WAVELENGTH_CDF[81] = {
    0.0f, 6.5109e-5f, 0.00018773f, 0.00045414f, 0.0010561f, 0.0021851f, 0.0043017f, 0.0082413f, 0.015215f,
    0.026492f, 0.042028f, 0.061835f, 0.085811f, 0.11225f, 0.1396f, 0.16643f, 0.1913f, 0.21376f,
    0.23379f, 0.252f, 0.26913f, 0.28513f, 0.30023f, 0.31536f, 0.33154f, 0.34944f, 0.36938f,
    0.39128f, 0.41529f, 0.44129f, 0.4684f, 0.49524f, 0.52063f, 0.54398f, 0.56476f, 0.58348f,
    0.60239f, 0.62285f, 0.64475f, 0.6681f, 0.69291f, 0.71846f, 0.74394f, 0.76952f, 0.79534f,
    0.82079f, 0.84549f, 0.86935f, 0.89192f, 0.91229f, 0.92987f, 0.94483f, 0.95753f, 0.96791f,
    0.97606f, 0.98237f, 0.98722f, 0.99086f, 0.99356f, 0.99551f, 0.99691f, 0.99788f, 0.99852f,
    0.99895f, 0.99925f, 0.99948f, 0.99964f, 0.99975f, 0.99983f, 0.99988f, 0.99991f, 0.99994f,
    0.99996f, 0.99998f, 0.99999f, 0.99999f, 0.99999f, 1.0f, 1.0f, 1.0f, 1.0f
};
static const float WAVELENGTH_LEAST = 0.38f;
static const float WAVELENGTH_STEP = 0.005f;

// w(λ), linear between the nodes
[CudaDeviceExport] public func wavelengthWeights(wavelength: float) -> float3 {
    let x: float = clamp((wavelength - WAVELENGTH_LEAST) / WAVELENGTH_STEP, 0.0f, 80.0f);
    let i: uint = min(uint(x), 79u);
    let k: uint = 3u * i;
    let a: float3 = float3(WAVELENGTH_WEIGHTS[k], WAVELENGTH_WEIGHTS[k + 1u], WAVELENGTH_WEIGHTS[k + 2u]);
    let b: float3 = float3(WAVELENGTH_WEIGHTS[k + 3u], WAVELENGTH_WEIGHTS[k + 4u], WAVELENGTH_WEIGHTS[k + 5u]);
    return a + (b - a) * (x - float(i));
}

// u in bin i, CDF_i <= u < CDF_i+1: λ = λ_i + Δ (u - CDF_i) / (CDF_i+1 - CDF_i), p(λ) = (CDF_i+1 - CDF_i) / Δ
// => (λ, p(λ))
[CudaDeviceExport] public func sampleWavelength(u: float) -> float2 {
    var low: uint = 0u;
    var high: uint = 79u;
    while (low < high) {
        let middle: uint = (low + high + 1u) / 2u;
        if (WAVELENGTH_CDF[middle] <= u) {
            low = middle;
        } else {
            high = middle - 1u;
        }
    }
    let mass: float = WAVELENGTH_CDF[low + 1u] - WAVELENGTH_CDF[low];
    return float2(WAVELENGTH_LEAST + WAVELENGTH_STEP * (float(low) + (u - WAVELENGTH_CDF[low]) / mass),
        mass / WAVELENGTH_STEP);
}

// r(λ) = a_0 + a_1 * g_1(λ) + a_2 * g_2(λ), λ in um
// g_1 = exp(-((λ - 0.45) / 0.03)^2 / 2), g_2 = exp(-((λ - 0.64) / 0.04)^2 / 2), g_0 = 1
// integral w_c(λ) r(λ) dλ = rgb_c in every channel: a = G^-1 rgb, G_ck = integral w_c(λ) g_k(λ) dλ
// G by trapezoids over WAVELENGTH_WEIGHTS; integral w_c dλ = 1 is G's first column, so r = 1 for white
// => upsample(rgb, λ) = dot(G^-1 rgb, (1, g_1(λ), g_2(λ))), linear in rgb
[CudaDeviceExport] public func upsample(rgb: float3, wavelength: float) -> float {
    let a: float3 = float3(dot(float3(-0.080117f, 1.089018f, -0.008899f), rgb),
        dot(float3(0.12177f, -1.229032f, 1.10725f), rgb), dot(float3(1.172524f, -1.216034f, 0.043502f), rgb));
    let x_1: float = (wavelength - 0.45f) / 0.03f;
    let x_2: float = (wavelength - 0.64f) / 0.04f;
    return a.x + a.y * exp(-0.5f * x_1 * x_1) + a.z * exp(-0.5f * x_2 * x_2);
}

// The material at λ: each colour its reflectance at λ, emission its radiance at λ, in all three channels
[CudaDeviceExport] public func atWavelength(material: Material, wavelength: float) -> Material {
    var at: Material = material;
    at.albedo = float3(upsample(material.albedo, wavelength));
    at.emissive = float3(upsample(material.emissive, wavelength));
    at.absorption = float3(upsample(material.absorption, wavelength));
    at.specular_tint = float3(upsample(material.specular_tint, wavelength));
    at.translucent = float3(upsample(material.translucent, wavelength));
    at.sheen = float3(upsample(material.sheen, wavelength));
    return at;
}

// Indices at the path's wavelength past its first dispersive hit, at the material's IOR before (wavelength 0)
[CudaDeviceExport] public func wavelengthEta(material: Material, n_dot_v: float, wavelength: float) -> float2 {
    var refractive: Material = material;
    refractive.ior = select(material.ior, dispersedIor(material.ior, material.dispersion, wavelength),
        wavelength > 0.0f);
    return vertexEta(refractive, n_dot_v);
}

// Colour at accumulation: f_c = w_c(λ) / p(λ) * upsample(f, λ), f a spectral path's throughput times the radiance
// it meets; RGB paths (wavelength 0) unchanged
[CudaDeviceExport] public func pathColor(f: float3, weight: float3, wavelength: float) -> float3 {
    return wavelength > 0.0f ? weight * upsample(f, wavelength) : f;
}

// Decide between next event estimation and emission on the next hit, as the path tracer does
[CudaDeviceExport] public func neeDecision(material: Material, n_dot_v: float, eta_i: float, eta_o: float) -> bool {
    // Calculate fresnel term
    let F_n: float3 = mix(float3(fresnel(abs(n_dot_v), eta_i, eta_o)), material.albedo, material.metallic);
    let F_n_greyscale: float = rgb_to_greyscale(F_n);
    let diffuse_factor_estimate: float = max((1.0f - F_n_greyscale) * (1.0f - material.metallic) * (1.0f - material.transmission), 0.0f);
    return diffuse_factor_estimate > 0.04f || material.roughness > 0.2f;
}

// Per lobe: BSDF * n_dot_l = throughput * PDF_lobe, light sample of PDF pdf
// w_balance = pdf / (pdf + PDF_lobe)
// => BSDF * n_dot_l / pdf * w_balance = throughput * PDF_lobe / (PDF_lobe + pdf)
// w_power = pdf^2 / (pdf^2 + PDF_lobe^2)
// => BSDF * n_dot_l / pdf * w_power = throughput * PDF_lobe / (pdf * (1 + (PDF_lobe / pdf)^2))
[CudaDeviceExport] public func neeBSDF(in_dir: float3, dir: float3, n: float3, material: Material, eta_i: float, eta_o: float, refracted: bool, pdf: float, power: bool, random_state: uint, terms: MaterialTerms, view_terms: ViewTerms) -> float3 {
    var each: float3[5];
    var reached: uint = 0u;
    return neeLobes(in_dir, dir, n, material, eta_i, eta_o, refracted, pdf, power, random_state, terms, view_terms,
        each, reached);
}

// neeBSDF, light and sky sampling's one body: the sum, each lobe's term of the diffuse, refraction, reflection, sheen
// and toon lobes in that order, and the bits of the lobes reached
public func neeLobes(in_dir: float3, dir: float3, n: float3, material: Material, eta_i: float, eta_o: float,
    refracted: bool, pdf: float, power: bool, random_state: uint, terms: MaterialTerms, view_terms: ViewTerms,
    out each: float3[5], out reached: uint) -> float3 {
    let n_dot_v: float = dot(n, negate(in_dir));
    let n_i: float3 = n * sign(n_dot_v);
    let n_i_dot_l: float = dot(n_i, dir);
    let alpha: float = material.roughness * material.roughness;
    var f: float3 = float3(0.0f);
    reached = 0u;
    // The lobe's half vector and its terms, taken again only where they differ from the last lobe's
    var half_of: uint = UINT_MAX;
    var ggx_n: float3 = float3(0.0f);
    var lobe_terms: HalfTerms = {};
    // Diffuse, refraction, reflection, sheen and toon lobes
#ifdef FK_TOON
    let lobes: uint = abs(material.toon.x) > 0.0f ? 5u : 4u;
#else
    let lobes: uint = 4u;
#endif
    for (var i: uint = 0u; i < 5u; i++) {
        each[i] = float3(0.0f);
    }
    for (var i: uint = 0u; i < lobes; i++) {
        let lobe: uint = i == 3u ? LOBE_SHEEN_VELVET : i == 4u ? LOBE_TOON : i;
        // Translucent diffuse lobe: through the shading normal on the refracted side
        if (lobe == LOBE_DIFFUSE && translucencyUsed() && rgb_to_greyscale(material.translucent) > 0.0f
            ? (dot(n, dir) * dot(n, negate(in_dir)) < 0.0f) == refracted : (lobe == LOBE_REFRACT) == refracted) {
            // sampleBSDF's half vector for the diffuse and toon lobes, dir's reflective one for reflection and sheen
            let lobe_half: uint = lobe == LOBE_TOON ? LOBE_DIFFUSE : lobe == LOBE_SHEEN_VELVET ? LOBE_REFLECT : lobe;
            if (lobe_half != half_of) {
                if (lobe_half == LOBE_DIFFUSE) {
                    ggx_n = sampledHalf(in_dir, n, material, random_state, view_terms);
                } else if (lobe_half == LOBE_REFRACT) {
                    ggx_n = refractedHalf(in_dir, dir, n, eta_i, eta_o);
                } else {
                    ggx_n = reflectedHalf(in_dir, dir);
                }
                lobe_terms = precomputeHalf(in_dir, ggx_n, material, eta_i, eta_o, terms, view_terms);
                half_of = lobe_half;
            }
            var lobe_pdf: float = 0.0f;
            var throughput: float3 = float3(0.0f);
            switch (lobe) {
            case LOBE_DIFFUSE:
                lobe_pdf = diffusePDF(n_i_dot_l, 0.0f, abs(n_dot_v), alpha, lobe_terms, eta_i, eta_o);
                throughput = diffuseBSDF(dir, n_i, alpha, material, lobe_terms);
                break;
            case LOBE_REFRACT:
                lobe_pdf = refractPDF(n_i_dot_l, dot(dir, ggx_n), abs(n_dot_v), alpha, lobe_terms, eta_i, eta_o);
                throughput = refractBSDF(dir, n_i, alpha, material, lobe_terms);
                break;
            case LOBE_SHEEN_VELVET:
                lobe_pdf = sheenVelvetPDF(n_i_dot_l, 0.0f, abs(n_dot_v), alpha, lobe_terms, eta_i, eta_o);
                throughput = sheenVelvetBSDF(dir, n_i, alpha, material, lobe_terms);
                break;
#ifdef FK_TOON
            case LOBE_TOON:
                lobe_pdf = toonPDF(n_i_dot_l, dot(dir, lobe_terms.toon_axis), abs(n_dot_v), alpha, lobe_terms, eta_i,
                    eta_o);
                throughput = toonBSDF(dir, n_i, alpha, material, lobe_terms);
                break;
#endif
            default:
                lobe_pdf = reflectPDF(n_i_dot_l, 0.0f, abs(n_dot_v), alpha, lobe_terms, eta_i, eta_o);
                throughput = reflectBSDF(dir, n_i, alpha, material, lobe_terms);
                break;
            }
            if (lobe_pdf > 0.0f) {
                each[i] = misWeighted(throughput, lobe_pdf, pdf, power);
                reached |= 1u << i;
                f += each[i];
            }
        }
    }
    return f;
}

// One lobe's term of neeBSDF, of throughput and PDF lobe_pdf
[CudaDeviceExport] public func misWeighted(throughput: float3, lobe_pdf: float, pdf: float, power: bool) -> float3 {
    if (power) {
        let ratio: float = lobe_pdf / pdf;
        return throughput * lobe_pdf / (pdf * (1.0f + ratio * ratio));
    }
    return throughput * lobe_pdf / (lobe_pdf + pdf);
}

// eta_i = eta_o => F = 0, l = -v
// => throughput = transmission * (1 - metallic) * G1_l * albedo
[CudaDeviceExport] public func straightThrough(dir: float3, n: float3, material: Material) -> float3 {
    // Normal facing back along dir
    let n_i: float3 = n * sign(dot(n, negate(dir)));
    let frame: AnisotropicFrame = anisotropicFrame(material, n_i);
    if (frame.alphas.x > 0.0f) {
        return material.transmission * (1.0f - material.metallic) * anisotropicG1(anisotropicLocal(dir, frame.tangent,
            negate(n_i)), frame.alphas) * material.albedo;
    }
    return material.transmission * (1.0f - material.metallic) * smithG1(material.roughness * material.roughness, abs(dot(n, dir))) * material.albedo;
}

#ifdef FK_HAIR
// Hair, baked per lobe p (R, TT, TRT, rest) in nt rows of theta and np columns of phi
// HAIR_WIDTHS and HAIR_TILTS scale the R lobe's width w and the cuticle tilt alpha per lobe
static const float HAIR_WIDTHS[4] = {1.0f, 0.5f, 2.0f, 2.0f};
static const float HAIR_TILTS[4] = {-2.0f, 1.0f, 4.0f, 0.0f};
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
    let through: float3 = material.ior == 1.0f ? straightThrough(toward, n, material) : float3(0.0f);
    return through * coverage + (1.0f - coverage);
}

public static const uint LOBE_DIFFUSE = 0u;
public static const uint LOBE_REFRACT = 1u;
public static const uint LOBE_REFLECT = 2u;
// 3 is the walk's LOBE_NONE of camera rays
public static const uint LOBE_SHEEN_VELVET = 4u;
public static const uint LOBE_TOON = 6u;

__include walk;

[CudaDeviceExport] public func hash(x: uint) -> uint {
    let state: uint = x * 747796405u + 2891336453u;
    let word: uint = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

[CudaDeviceExport] public func stream(seed: uint, index: uint) -> uint {
    return hash(seed ^ hash(index));
}
