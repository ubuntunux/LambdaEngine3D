{-# LANGUAGE DataKinds          #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE RecordWildCards    #-}
{-# LANGUAGE TypeApplications   #-}

module HulkanEngine3D.Resource.RenderPassCreateInfo.CompositeGBuffer where

import Data.Bits
import qualified Data.Text as Text
import Data.IORef

import Graphics.Vulkan.Core_1_0
import Graphics.Vulkan.Ext.VK_KHR_swapchain

import HulkanEngine3D.Render.Renderer
import HulkanEngine3D.Render.RenderTargetType
import HulkanEngine3D.Render.UniformBufferDatas (UniformBufferType (..))
import HulkanEngine3D.Vulkan.Descriptor
import HulkanEngine3D.Vulkan.FrameBuffer
import HulkanEngine3D.Vulkan.RenderPass
import HulkanEngine3D.Vulkan.SwapChain
import HulkanEngine3D.Vulkan.Vulkan
import HulkanEngine3D.Utilities.System

renderPassName :: Text.Text
renderPassName = "composite_gbuffer"

getFrameBufferDataCreateInfo :: RendererData -> IO FrameBufferDataCreateInfo
getFrameBufferDataCreateInfo rendererData = do
    swapChainData <- readIORef (_swapChainDataRef rendererData)
    let imageSize = _swapChainExtent swapChainData
        width = getField @"width" imageSize
        height = getField @"height" imageSize
    return defaultFrameBufferDataCreateInfo
        { _frameBufferName = renderPassName
        , _frameBufferWidth = width
        , _frameBufferHeight = height
        , _frameBufferViewPort = createViewport 0 0 width height 0 1
        , _frameBufferScissorRect = createScissorRect 0 0 width height
        , _frameBufferColorAttachmentFormats = [_swapChainImageFormat swapChainData]
        , _frameBufferImageViewsList = [[swapChainImageView] | swapChainImageView <- _swapChainImageViews swapChainData]
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
                { _pipelineDataCreateInfoName = "composite_gbuffer"
                , _vertexShaderFile = "Resource/Shaders/render_quad.vert"
                , _fragmentShaderFile = "Resource/Shaders/composite_gbuffer.frag"
                , _pipelineDynamicStateList = [VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR]
                , _pipelineSampleCount = sampleCount
                , _pipelinePolygonMode = VK_POLYGON_MODE_FILL
                , _pipelineCullMode = VK_CULL_MODE_NONE
                , _pipelineFrontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE
                , _pipelineViewport = _frameBufferViewPort frameBufferDataCreateInfo
                , _pipelineScissorRect = _frameBufferScissorRect frameBufferDataCreateInfo
                , _pipelineColorBlendModes = [getColorBlendMode BlendMode_None]
                , _depthStencilStateCreateInfo = defaultDepthStencilStateCreateInfo  { _depthWriteEnable = VK_FALSE }
                , _descriptorDataCreateInfoList =
                    [ DescriptorDataCreateInfo
                        0
                        (toText UniformBuffer_SceneConstants)
                        DescriptorResourceType_UniformBuffer
                        VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER
                        (VK_SHADER_STAGE_VERTEX_BIT .|. VK_SHADER_STAGE_FRAGMENT_BIT)
                    , DescriptorDataCreateInfo
                        1
                        (toText UniformBuffer_ViewProjectionConstants)
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
                        (toText RenderTarget_SceneAlbedo)
                        DescriptorResourceType_RenderTarget
                        VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
                        VK_SHADER_STAGE_FRAGMENT_BIT
                    , DescriptorDataCreateInfo
                        4
                        (toText RenderTarget_SceneMaterial)
                        DescriptorResourceType_RenderTarget
                        VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
                        VK_SHADER_STAGE_FRAGMENT_BIT
                    , DescriptorDataCreateInfo
                        5
                        (toText RenderTarget_SceneNormal)
                        DescriptorResourceType_RenderTarget
                        VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
                        VK_SHADER_STAGE_FRAGMENT_BIT
                    , DescriptorDataCreateInfo
                        6
                        (toText RenderTarget_SSAO)
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