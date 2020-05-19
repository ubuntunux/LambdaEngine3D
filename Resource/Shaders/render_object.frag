#version 450
#extension GL_ARB_separate_shader_objects : enable
#extension GL_GOOGLE_include_directive : enable

#include "SceneConstants.glsl"

layout(binding = 1) uniform sampler2D textureAlbedo;
layout(binding = 2) uniform sampler2D textureMaterial;
layout(binding = 3) uniform sampler2D textureNormal;

layout(location = 0) in vec4 fragColor;
layout(location = 1) in vec3 fragNormal;
layout(location = 2) in vec2 fragTexCoord;

layout(location = 0) out vec4 outAlbedo;
layout(location = 1) out vec4 outMaterial;
layout(location = 2) out vec4 outNormal;
layout(location = 3) out vec4 outVelocity;

void main() {
    outAlbedo = texture(textureAlbedo, fragTexCoord);
    outMaterial = texture(textureMaterial, fragTexCoord);
    outNormal = texture(textureNormal, fragTexCoord);
    outVelocity = vec4(0.0);
}
