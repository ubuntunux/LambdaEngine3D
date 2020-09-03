{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE RecordWildCards    #-}

module HulkanEngine3D.Resource.RenderPassCreateInfo.RenderObject where

import Data.Bits
import qualified Data.Text as Text

import Graphics.Vulkan.Core_1_0

import qualified HulkanEngine3D.Constants as Constants
import HulkanEngine3D.Render.Renderer
import HulkanEngine3D.Render.RenderTargetDeclaration
import HulkanEngine3D.Render.UniformBufferDatas (UniformBufferType (..))
import HulkanEngine3D.Vulkan.Descriptor
import HulkanEngine3D.Vulkan.FrameBuffer
import HulkanEngine3D.Vulkan.RenderPass
import HulkanEngine3D.Vulkan.Texture
import HulkanEngine3D.Vulkan.Vulkan
import HulkanEngine3D.Utilities.System (toText)

getRenderPassName :: Constants.RenderObjectType -> Text.Text
getRenderPassName Constants.RenderObject_Static = "render_pass_static_opaque"
getRenderPassName Constants.RenderObject_Skeletal = "render_pass_skeletal_opaque"

getFrameBufferDataCreateInfo :: RendererData -> Text.Text -> Constants.RenderObjectType -> IO FrameBufferDataCreateInfo
getFrameBufferDataCreateInfo rendererData renderPassName renderObjectType = do
    textureSceneAlbedo <- getRenderTarget rendererData RenderTarget_SceneAlbedo
    textureSceneMaterial <- getRenderTarget rendererData RenderTarget_SceneMaterial
    textureSceneNormal <- getRenderTarget rendererData RenderTarget_SceneNormal
    textureSceneVelocity <- getRenderTarget rendererData RenderTarget_SceneVelocity
    textureSceneDepth <- getRenderTarget rendererData RenderTarget_SceneDepth
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
        , _frameBufferImageViewLists = swapChainIndexMapSingleton $ (map _imageView textures) ++ [_imageView textureSceneDepth]
        , _frameBufferClearValues =
            case renderObjectType of
                Constants.RenderObject_Static -> [ getColorClearValue [0.0, 0.0, 0.0]
                                                 , getColorClearValue [0.0, 0.0, 0.0]
                                                 , getColorClearValue [0.5, 0.5, 1.0]
                                                 , getColorClearValue [0.0, 0.0]
                                                 , getDepthStencilClearValue 1.0 0
                                                 ]
                otherwise -> []
        }

getRenderPassDataCreateInfo :: RendererData -> Constants.RenderObjectType -> IO RenderPassDataCreateInfo
getRenderPassDataCreateInfo rendererData renderObjectType = do
    let renderPassName = getRenderPassName renderObjectType
    frameBufferDataCreateInfo <- getFrameBufferDataCreateInfo rendererData renderPassName renderObjectType
    let sampleCount = _frameBufferSampleCount frameBufferDataCreateInfo
        attachmentLoadOperation = case renderObjectType of
            Constants.RenderObject_Static -> VK_ATTACHMENT_LOAD_OP_CLEAR
            otherwise -> VK_ATTACHMENT_LOAD_OP_LOAD
        colorAttachmentDescriptions =
            [ defaultAttachmentDescription
                { _attachmentImageFormat = format
                , _attachmentImageSamples = sampleCount
                , _attachmentLoadOperation = attachmentLoadOperation
                , _attachmentStoreOperation = VK_ATTACHMENT_STORE_OP_STORE
                , _attachmentFinalLayout = VK_IMAGE_LAYOUT_GENERAL
                , _attachmentReferenceLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
                } | format <- _frameBufferColorAttachmentFormats frameBufferDataCreateInfo
            ]
        depthAttachmentDescriptions =
            [ defaultAttachmentDescription
                { _attachmentImageFormat = format
                , _attachmentImageSamples = sampleCount
                , _attachmentLoadOperation = attachmentLoadOperation
                , _attachmentStoreOperation = VK_ATTACHMENT_STORE_OP_STORE
                , _attachmentFinalLayout = VK_IMAGE_LAYOUT_GENERAL
                , _attachmentReferenceLayout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL
                } | format <- _frameBufferDepthAttachmentFormats frameBufferDataCreateInfo
            ]
        subpassDependencies =
            [ createSubpassDependency
                VK_SUBPASS_EXTERNAL
                0
                VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT
                VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
                VK_ACCESS_MEMORY_READ_BIT
                (VK_ACCESS_COLOR_ATTACHMENT_READ_BIT .|. VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT)
                VK_DEPENDENCY_BY_REGION_BIT
            , createSubpassDependency
                0
                VK_SUBPASS_EXTERNAL
                VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
                VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT
                (VK_ACCESS_COLOR_ATTACHMENT_READ_BIT .|. VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT)
                VK_ACCESS_MEMORY_READ_BIT
                VK_DEPENDENCY_BY_REGION_BIT
            ]
        pipelineDataCreateInfos =
            [ PipelineDataCreateInfo
                { _pipelineDataCreateInfoName = "render_object"
                , _pipelineVertexShaderFile = "render_object.vert"
                , _pipelineFragmentShaderFile = "render_object.frag"
                , _pipelineShaderDefines = []
                , _pipelineDynamicStateList = [VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR]
                , _pipelineSampleCount = sampleCount
                , _pipelinePolygonMode = VK_POLYGON_MODE_FILL
                , _pipelineCullMode = VK_CULL_MODE_BACK_BIT
                , _pipelineFrontFace = VK_FRONT_FACE_CLOCKWISE
                , _pipelineViewport = _frameBufferViewPort frameBufferDataCreateInfo
                , _pipelineScissorRect = _frameBufferScissorRect frameBufferDataCreateInfo
                , _pipelineColorBlendModes = replicate (length colorAttachmentDescriptions) $ getColorBlendMode BlendMode_None
                , _depthStencilStateCreateInfo = defaultDepthStencilStateCreateInfo
                , _descriptorDataCreateInfoList =
                    [ DescriptorDataCreateInfo
                        0
                        (toText UniformBuffer_SceneConstants)
                        DescriptorResourceType_UniformBuffer
                        VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER
                        (VK_SHADER_STAGE_VERTEX_BIT .|. VK_SHADER_STAGE_FRAGMENT_BIT)
                    , DescriptorDataCreateInfo
                        1
                        (toText UniformBuffer_ViewConstants)
                        DescriptorResourceType_UniformBuffer
                        VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER
                        (VK_SHADER_STAGE_VERTEX_BIT .|. VK_SHADER_STAGE_FRAGMENT_BIT)
                    , DescriptorDataCreateInfo
                        2
                        (toText UniformBuffer_LightConstants)
                        DescriptorResourceType_UniformBuffer
                        VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER
                        (VK_SHADER_STAGE_VERTEX_BIT .|. VK_SHADER_STAGE_FRAGMENT_BIT)
                    , DescriptorDataCreateInfo
                        3
                        "textureBase"
                        DescriptorResourceType_Texture
                        VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
                        VK_SHADER_STAGE_FRAGMENT_BIT
                    , DescriptorDataCreateInfo
                        4
                        "textureMaterial"
                        DescriptorResourceType_Texture
                        VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
                        VK_SHADER_STAGE_FRAGMENT_BIT
                    , DescriptorDataCreateInfo
                        5
                        "textureNormal"
                        DescriptorResourceType_Texture
                        VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
                        VK_SHADER_STAGE_FRAGMENT_BIT
                    ]
                }
            ]
    return RenderPassDataCreateInfo
        { _renderPassCreateInfoName = renderPassName
        , _renderPassFrameBufferCreateInfo = frameBufferDataCreateInfo
        , _colorAttachmentDescriptions = colorAttachmentDescriptions
        , _depthAttachmentDescriptions = depthAttachmentDescriptions
        , _resolveAttachmentDescriptions = []
        , _subpassDependencies = subpassDependencies
        , _pipelineDataCreateInfos = pipelineDataCreateInfos
        }