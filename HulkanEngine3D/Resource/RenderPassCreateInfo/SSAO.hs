{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE RecordWildCards    #-}

module HulkanEngine3D.Resource.RenderPassCreateInfo.SSAO where

import Data.Bits
import qualified Data.Text as Text

import Graphics.Vulkan.Core_1_0
import Graphics.Vulkan.Ext.VK_KHR_swapchain

import qualified HulkanEngine3D.Constants as Constants
import HulkanEngine3D.Vulkan.Descriptor
import HulkanEngine3D.Vulkan.FrameBuffer
import HulkanEngine3D.Render.Renderer
import HulkanEngine3D.Vulkan.RenderPass
import HulkanEngine3D.Vulkan.Texture
import HulkanEngine3D.Vulkan.Vulkan

renderPassName :: Text.Text
renderPassName = "render_ssao"

getFrameBufferDataCreateInfo :: RendererData -> IO FrameBufferDataCreateInfo
getFrameBufferDataCreateInfo rendererData = do
    textureSceneAlbedo <- getRenderTarget rendererData "SceneAlbedo"
    textureSceneMaterial <- getRenderTarget rendererData "SceneMaterial"
    textureSceneNormal <- getRenderTarget rendererData "SceneNormal"
    textureSceneVelocity <- getRenderTarget rendererData "SceneVelocity"
    textureSceneDepth <- getRenderTarget rendererData "SceneDepth"
    let (width, height, depth) = (_imageWidth textureSceneAlbedo, _imageHeight textureSceneAlbedo, _imageDepth textureSceneAlbedo)
        textures = [textureSceneAlbedo, textureSceneMaterial, textureSceneNormal, textureSceneVelocity]
    return defaultFrameBufferDataCreateInfo
        { _frameBufferName = renderPassName
        , _frameBufferWidth = width
        , _frameBufferHeight = height
        , _frameBufferDepth = depth
        , _frameBufferSampleCount = _imageSampleCount textureSceneAlbedo
        , _frameBufferViewPort = createViewport 0 0 width height 0 1
        , _frameBufferScissorRect = createScissorRect 0 0 width height
        , _frameBufferColorAttachmentFormats = [_imageFormat texture | texture <- textures]
        , _frameBufferDepthAttachmentFormats = [_imageFormat textureSceneDepth]
        , _frameBufferImageViewsList =
            replicate Constants.swapChainImageCount ([_imageView texture | texture <- textures] ++ [_imageView textureSceneDepth])
        , _frameBufferClearValues =
            [ getColorClearValue [0.0, 0.0, 0.0]
            , getColorClearValue [0.0, 0.0, 0.0]
            , getColorClearValue [0.5, 0.5, 1.0]
            , getColorClearValue [0.0, 0.0]
            , getDepthStencilClearValue 1.0 0
            ]
        }

getRenderPassDataCreateInfo :: RendererData -> IO RenderPassDataCreateInfo
getRenderPassDataCreateInfo rendererData = do
    frameBufferDataCreateInfo <- getFrameBufferDataCreateInfo rendererData
    let sampleCount = _frameBufferSampleCount frameBufferDataCreateInfo
        colorAttachmentDescriptions =
            [ defaultAttachmentDescription
                { _attachmentImageFormat = format
                , _attachmentImageSamples = sampleCount
                , _attachmentLoadOperation = VK_ATTACHMENT_LOAD_OP_DONT_CARE
                , _attachmentStoreOperation = VK_ATTACHMENT_STORE_OP_STORE
                , _attachmentFinalLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR
                , _attachmentReferenceLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
                } | format <- _frameBufferColorAttachmentFormats frameBufferDataCreateInfo
            ]
        subpassDependencies =
            [ createSubpassDependency
                VK_SUBPASS_EXTERNAL
                0
                VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
                VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
                VK_ZERO_FLAGS
                (VK_ACCESS_COLOR_ATTACHMENT_READ_BIT .|. VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT)
                VK_DEPENDENCY_BY_REGION_BIT
            ]
        pipelineDataCreateInfos =
            [ PipelineDataCreateInfo
                { _pipelineDataCreateInfoName = "render_ssao"
                , _vertexShaderFile = "Resource/Shaders/render_quad.vert"
                , _fragmentShaderFile = "Resource/Shaders/composite_gbuffer.frag"
                , _pipelineDynamicStateList = [VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR]
                , _pipelineSampleCount = sampleCount
                , _pipelinePolygonMode = VK_POLYGON_MODE_FILL
                , _pipelineCullMode = VK_CULL_MODE_NONE
                , _pipelineFrontFace = VK_FRONT_FACE_CLOCKWISE
                , _pipelineViewport = _frameBufferViewPort frameBufferDataCreateInfo
                , _pipelineScissorRect = _frameBufferScissorRect frameBufferDataCreateInfo
                , _pipelineColorBlendModes = [getColorBlendMode BlendMode_None]
                , _depthStencilStateCreateInfo = defaultDepthStencilStateCreateInfo  { _depthWriteEnable = VK_FALSE }
                , _descriptorDataCreateInfoList =
                    [ DescriptorDataCreateInfo
                        0
                        "SceneConstants"
                        DescriptorResourceType_UniformBuffer
                        VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER
                        (VK_SHADER_STAGE_VERTEX_BIT .|. VK_SHADER_STAGE_FRAGMENT_BIT)
                    , DescriptorDataCreateInfo
                        1
                        "ViewProjectionConstants"
                        DescriptorResourceType_UniformBuffer
                        VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER
                        (VK_SHADER_STAGE_VERTEX_BIT .|. VK_SHADER_STAGE_FRAGMENT_BIT)
                    , DescriptorDataCreateInfo
                        2
                        "LightConstants"
                        DescriptorResourceType_UniformBuffer
                        VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER
                        (VK_SHADER_STAGE_VERTEX_BIT .|. VK_SHADER_STAGE_FRAGMENT_BIT)
                    , DescriptorDataCreateInfo
                        3
                        "SceneAlbedo"
                        DescriptorResourceType_RenderTarget
                        VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
                        VK_SHADER_STAGE_FRAGMENT_BIT
                    , DescriptorDataCreateInfo
                        4
                        "SceneMaterial"
                        DescriptorResourceType_RenderTarget
                        VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
                        VK_SHADER_STAGE_FRAGMENT_BIT
                    , DescriptorDataCreateInfo
                        5
                        "SceneNormal"
                        DescriptorResourceType_RenderTarget
                        VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
                        VK_SHADER_STAGE_FRAGMENT_BIT
                    ]
                }
            ]
    return RenderPassDataCreateInfo
        { _renderPassCreateInfoName = renderPassName
        , _renderPassFrameBufferCreateInfo = frameBufferDataCreateInfo
        , _colorAttachmentDescriptions = colorAttachmentDescriptions
        , _depthAttachmentDescriptions = []
        , _resolveAttachmentDescriptions = []
        , _subpassDependencies = subpassDependencies
        , _pipelineDataCreateInfos = pipelineDataCreateInfos
        }