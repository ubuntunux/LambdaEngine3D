{-# LANGUAGE DataKinds        #-}
{-# LANGUAGE RecordWildCards  #-}
{-# LANGUAGE Strict           #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TemplateHaskell  #-}

module HulkanEngine3D.Vulkan
  ( RenderFeatures (..)
  , RendererData (..)
  , RendererInterface (..)
  , getColorClearValue
  , getDepthStencilClearValue
  , newRenderPassDataCreateInfo
  , newRendererData
  , drawFrame
  , createRenderer
  , destroyRenderer
  , initializeRenderer
  , resizeWindow
  , recreateSwapChain
  , runCommandsOnce
  , recordCommandBuffer
  , updateRendererData
  ) where

import Control.Monad
import Data.Maybe (fromMaybe)
import qualified Data.Set as Set
import qualified Data.Map as Map
import qualified Data.DList as DList
import qualified Data.HashTable.IO as HashTable
import Data.IORef
import Foreign.Marshal.Array
import Foreign.Marshal.Alloc
import Foreign.Marshal.Utils
import Foreign.Storable
import Foreign.C.String
import Foreign.Ptr

import qualified Graphics.UI.GLFW as GLFW
import Graphics.Vulkan
import Graphics.Vulkan.Core_1_0
import Graphics.Vulkan.Ext.VK_KHR_surface
import Graphics.Vulkan.Ext.VK_KHR_swapchain
import Graphics.Vulkan.Marshal.Create
import Graphics.Vulkan.Marshal.Create.DataFrame
import Numeric.DataFrame

import qualified HulkanEngine3D.Constants as Constants
import HulkanEngine3D.Utilities.Logger
import HulkanEngine3D.Utilities.System
import {-# SOURCE #-} HulkanEngine3D.Render.RenderTarget
import HulkanEngine3D.Vulkan.CommandBuffer
import HulkanEngine3D.Vulkan.Device
import HulkanEngine3D.Vulkan.Descriptor
import HulkanEngine3D.Vulkan.FrameBuffer
import HulkanEngine3D.Vulkan.Mesh
import HulkanEngine3D.Vulkan.Queue
import HulkanEngine3D.Vulkan.RenderPass
import HulkanEngine3D.Vulkan.SwapChain
import HulkanEngine3D.Vulkan.Sync
import HulkanEngine3D.Vulkan.Texture
import HulkanEngine3D.Vulkan.TransformationObject


data RenderFeatures = RenderFeatures
    { _anisotropyEnable :: VkBool32
    , _msaaSamples :: VkSampleCountBitmask FlagBit
    } deriving (Eq, Show)

data RendererData = RendererData
    { _frameIndexRef :: IORef Int
    , _imageIndexPtr :: Ptr Word32
    , _needRecreateSwapChainRef :: IORef Bool
    , _needRecordCommandBufferRef :: IORef Bool
    , _imageAvailableSemaphores :: [VkSemaphore]
    , _renderFinishedSemaphores :: [VkSemaphore]
    , _vkInstance :: VkInstance
    , _vkSurface :: VkSurfaceKHR
    , _device :: VkDevice
    , _physicalDevice :: VkPhysicalDevice
    , _swapChainDataRef :: IORef SwapChainData
    , _swapChainSupportDetailsRef :: IORef SwapChainSupportDetails
    , _queueFamilyDatas :: QueueFamilyDatas
    , _frameFencesPtr :: Ptr VkFence
    , _commandPool :: VkCommandPool
    , _commandBufferCount :: Word32
    , _commandBuffersPtr :: Ptr VkCommandBuffer
    , _commandBuffers :: [VkCommandBuffer]
    , _renderFeatures :: RenderFeatures
    , _renderTargetDataRef :: IORef RenderTargetData
    , _renderPassDataListRef :: IORef (DList.DList RenderPassData)
    , _descriptorPool :: VkDescriptorPool
    } deriving (Eq, Show)


class RendererInterface a where
    getPhysicalDevice :: a -> VkPhysicalDevice
    getDevice :: a -> VkDevice
    getSwapChainData :: a -> IO SwapChainData
    getSwapChainImageCount :: a -> IO Int
    getSwapChainImageViews :: a -> IO [VkImageView]
    getSwapChainSupportDetails :: a -> IO SwapChainSupportDetails
    getCommandPool :: a -> VkCommandPool
    getCommandBuffers :: a -> IO [VkCommandBuffer]
    getGraphicsQueue :: a -> VkQueue
    getPresentQueue :: a -> VkQueue
    getDescriptorPool :: a -> VkDescriptorPool
    getRenderPassData :: a -> IO RenderPassData
    createRenderPass :: a -> RenderPassDataCreateInfo -> IO RenderPassData
    destroyRenderPass :: a -> RenderPassData -> IO ()
    createRenderTarget :: a -> VkFormat -> VkExtent2D -> VkSampleCountFlagBits -> IO TextureData
    createDepthTarget :: a -> VkExtent2D -> VkSampleCountFlagBits -> IO TextureData
    createTexture :: a -> FilePath -> IO TextureData
    destroyTexture :: a -> TextureData -> IO ()
    createGeometryBuffer :: a -> String -> DataFrame Vertex '[XN 3] -> DataFrame Word32 '[XN 3] -> IO GeometryBufferData
    destroyGeometryBuffer :: a -> GeometryBufferData -> IO ()
    deviceWaitIdle :: a -> IO ()

instance RendererInterface RendererData where
    getPhysicalDevice rendererData = (_physicalDevice rendererData)
    getDevice rendererData = (_device rendererData)
    getSwapChainData rendererData = readIORef $ _swapChainDataRef rendererData
    getSwapChainImageCount rendererData = _swapChainImageCount <$> getSwapChainData rendererData
    getSwapChainImageViews rendererData = _swapChainImageViews <$> getSwapChainData rendererData
    getSwapChainSupportDetails rendererData = readIORef $ _swapChainSupportDetailsRef rendererData
    getCommandPool rendererData = (_commandPool rendererData)
    getCommandBuffers rendererData = peekArray (fromIntegral . _commandBufferCount $ rendererData) (_commandBuffersPtr rendererData)
    getGraphicsQueue rendererData = (_graphicsQueue (_queueFamilyDatas rendererData))
    getPresentQueue rendererData = (_presentQueue (_queueFamilyDatas rendererData))
    getDescriptorPool rendererData = _descriptorPool rendererData
    getRenderPassData rendererData = do
        renderPassDataList <- readIORef (_renderPassDataListRef rendererData)
        return $ (DList.toList renderPassDataList) !! 0

    createRenderPass rendererData renderPassDataCreateInfo =
        createRenderPassData (getDevice rendererData) renderPassDataCreateInfo

    destroyRenderPass rendererData renderPassData =
        destroyRenderPassData (getDevice rendererData) renderPassData

    createRenderTarget rendererData format extent samples =
        createColorImageView
            (_physicalDevice rendererData)
            (_device rendererData)
            (_commandPool rendererData)
            (_graphicsQueue (_queueFamilyDatas rendererData))
            format
            extent
            samples
            
    createDepthTarget rendererData extent samples =
        createDepthImageView
            (_physicalDevice rendererData)
            (_device rendererData)
            (_commandPool rendererData)
            (_graphicsQueue (_queueFamilyDatas rendererData))
            extent
            samples
            
    createTexture rendererData filePath =
        createTextureImageView
            (_physicalDevice rendererData)
            (_device rendererData)
            (_commandPool rendererData)
            (_graphicsQueue (_queueFamilyDatas rendererData))
            (_anisotropyEnable (_renderFeatures rendererData))
            filePath

    destroyTexture rendererData textureData =
        destroyTextureData (_device rendererData) textureData

    createGeometryBuffer rendererData bufferName vertices indices = do
        createGeometryBufferData
            (getPhysicalDevice rendererData)
            (getDevice rendererData)
            (getGraphicsQueue rendererData)
            (getCommandPool rendererData)
            bufferName
            vertices
            indices

    destroyGeometryBuffer rendererData geometryBuffer =
        destroyGeometryBufferData (_device rendererData) geometryBuffer

    deviceWaitIdle rendererData =
        throwingVK "vkDeviceWaitIdle failed!" (vkDeviceWaitIdle $ getDevice rendererData)

getColorClearValue :: [Float] -> VkClearValue
getColorClearValue colors = createVk @VkClearValue
        $ setVk @"color"
            $ setVec @"float32" (vec4 (colors !! 0) (colors !! 1) (colors !! 2) (colors !! 3))

getDepthStencilClearValue :: Float -> Word32 -> VkClearValue
getDepthStencilClearValue depthClearValue stencilClearValue = createVk @VkClearValue
    $ setVk @"depthStencil"
        $  set @"depth" depthClearValue
        &* set @"stencil" stencilClearValue

newRenderPassDataCreateInfo :: RendererData -> [VkImageView] -> [VkClearValue] -> IO RenderPassDataCreateInfo
newRenderPassDataCreateInfo rendererData imageViews clearValues = do
    let msaaSamples = _msaaSamples (_renderFeatures rendererData)
    swapChainData <- getSwapChainData rendererData
    depthFormat <- findDepthFormat (getPhysicalDevice rendererData)
    return RenderPassDataCreateInfo
        { _vertexShaderFile = "Resource/Shaders/triangle.vert"
        , _fragmentShaderFile = "Resource/Shaders/triangle.frag"
        , _renderPassSwapChainImageCount = _swapChainImageCount swapChainData
        , _renderPassImageFormat = _swapChainImageFormat swapChainData
        , _renderPassImageExtent = _swapChainExtent swapChainData
        , _renderPassImageViews = imageViews
        , _renderPassResolveImageViews = _swapChainImageViews swapChainData
        , _renderPassSampleCount = msaaSamples
        , _renderPassClearValues = clearValues
        , _renderPassDepthFormat = depthFormat
        , _renderPassDepthClearValue = 1.0
        }

newRendererData :: IO RendererData
newRendererData = do
    imageExtent <- newVkData @VkExtent2D $ \extentPtr -> do
        writeField @"width" extentPtr $ 0
        writeField @"height" extentPtr $ 0
    surfaceCapabilities <- newVkData @VkSurfaceCapabilitiesKHR $ \surfaceCapabilitiesPtr -> do
        return ()
    let defaultSwapChainData = SwapChainData
            { _swapChain = VK_NULL
            , _swapChainImages = []
            , _swapChainImageCount = 0
            , _swapChainImageFormat = VK_FORMAT_UNDEFINED
            , _swapChainImageViews = []
            , _swapChainExtent = imageExtent }
        defaultSwapChainSupportDetails = SwapChainSupportDetails
            { _capabilities = surfaceCapabilities
            , _formats = []
            , _presentModes = [] }
        defaultQueueFamilyIndices = QueueFamilyIndices
            { _graphicsQueueIndex = 0
            , _presentQueueIndex = 0
            , _computeQueueIndex = 0
            , _transferQueueIndex = 0
            , _sparseBindingQueueIndex = 0 }
        defaultQueueFamilyDatas = QueueFamilyDatas
            { _graphicsQueue = VK_NULL
            , _presentQueue = VK_NULL
            , _queueFamilyIndexList = []
            , _queueFamilyCount = 0
            , _queueFamilyIndices = defaultQueueFamilyIndices }
        defaultRenderFeatures = RenderFeatures
            { _anisotropyEnable = VK_FALSE
            , _msaaSamples = VK_SAMPLE_COUNT_1_BIT }

    imageIndexPtr <- new (0 :: Word32)
    frameIndexRef <- newIORef (0::Int)
    needRecreateSwapChainRef <- newIORef False
    needRecordCommandBufferRef <- newIORef True
    renderTargetDataRef <- newIORef (undefined::RenderTargetData)
    renderPassDataListRef <- newIORef (DList.fromList [])
    swapChainDataRef <- newIORef defaultSwapChainData
    swapChainSupportDetailsRef <- newIORef defaultSwapChainSupportDetails

    return RendererData
        { _frameIndexRef = frameIndexRef
        , _imageIndexPtr = imageIndexPtr
        , _needRecreateSwapChainRef = needRecreateSwapChainRef
        , _needRecordCommandBufferRef = needRecordCommandBufferRef
        , _imageAvailableSemaphores = []
        , _renderFinishedSemaphores = []
        , _vkInstance = VK_NULL
        , _vkSurface = VK_NULL
        , _device = VK_NULL
        , _physicalDevice = VK_NULL
        , _swapChainDataRef = swapChainDataRef
        , _swapChainSupportDetailsRef = swapChainSupportDetailsRef
        , _queueFamilyDatas = defaultQueueFamilyDatas
        , _frameFencesPtr = VK_NULL
        , _commandPool = VK_NULL
        , _commandBufferCount = 0
        , _commandBuffersPtr = VK_NULL
        , _commandBuffers = []
        , _renderFeatures = defaultRenderFeatures
        , _renderTargetDataRef = renderTargetDataRef
        , _renderPassDataListRef = renderPassDataListRef
        , _descriptorPool = VK_NULL
        }


drawFrame :: RendererData
          -> Int
          -> [VkDeviceMemory]
          -> Mat44f
          -> IO VkResult
drawFrame rendererData@RendererData {..} frameIndex transformObjectMemories viewMatrix = do
  let QueueFamilyDatas {..} = _queueFamilyDatas
      frameFencePtr = ptrAtIndex _frameFencesPtr frameIndex
      imageAvailableSemaphore = _imageAvailableSemaphores !! frameIndex
      renderFinishedSemaphore = _renderFinishedSemaphores !! frameIndex
  swapChainData@SwapChainData {..} <- getSwapChainData rendererData

  vkWaitForFences _device 1 frameFencePtr VK_TRUE (maxBound :: Word64) >>=
    flip validationVK "vkWaitForFences failed!"

  --  validationVK result "vkAcquireNextImageKHR failed!"
  result <- vkAcquireNextImageKHR _device _swapChain maxBound imageAvailableSemaphore VK_NULL_HANDLE _imageIndexPtr
  if (VK_SUCCESS /= result) then 
      return result
  else do
      imageIndex <- peek _imageIndexPtr
      let commandBufferPtr = ptrAtIndex _commandBuffersPtr (fromIntegral imageIndex)
      let transformObjectMemory = transformObjectMemories !! (fromIntegral imageIndex)
      updateTransformationObject _device _swapChainExtent transformObjectMemory viewMatrix

      let submitInfo = createVk @VkSubmitInfo
                $  set @"sType" VK_STRUCTURE_TYPE_SUBMIT_INFO
                &* set @"pNext" VK_NULL
                &* set @"waitSemaphoreCount" 1
                &* setListRef @"pWaitSemaphores" [imageAvailableSemaphore]
                &* setListRef @"pWaitDstStageMask" [VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT]
                &* set @"commandBufferCount" 1
                &* set @"pCommandBuffers" commandBufferPtr
                &* set @"signalSemaphoreCount" 1
                &* setListRef @"pSignalSemaphores" [renderFinishedSemaphore]

      vkResetFences _device 1 frameFencePtr

      frameFence <- peek frameFencePtr

      withPtr submitInfo $ \submitInfoPtr ->
          vkQueueSubmit _graphicsQueue 1 submitInfoPtr frameFence >>=
            flip validationVK "vkQueueSubmit failed!"

      let presentInfo = createVk @VkPresentInfoKHR
            $  set @"sType" VK_STRUCTURE_TYPE_PRESENT_INFO_KHR
            &* set @"pNext" VK_NULL
            &* set @"pImageIndices" _imageIndexPtr
            &* set @"waitSemaphoreCount" 1
            &* setListRef @"pWaitSemaphores" [renderFinishedSemaphore]
            &* set @"swapchainCount" 1
            &* setListRef @"pSwapchains" [_swapChain]

      presentResult <- withPtr presentInfo $ \presentInfoPtr -> do
        vkQueuePresentKHR _presentQueue presentInfoPtr

      return presentResult


initializeRenderer :: RendererData -> IO ()
initializeRenderer rendererData@RendererData {..} = do
    poke _imageIndexPtr 0
    writeIORef _frameIndexRef (0::Int)
    writeIORef _needRecreateSwapChainRef False
    writeIORef _needRecordCommandBufferRef True

    -- create render targets
    renderTargetData <- createRenderTargets rendererData
    writeIORef _renderTargetDataRef renderTargetData

    -- create render pass data
    renderPassDataCreateInfo <- newRenderPassDataCreateInfo
        rendererData
        [(_imageView (_sceneColorTexture renderTargetData)), (_imageView (_sceneDepthTexture renderTargetData))]
        [getColorClearValue [0.0, 0.0, 0.2, 1.0], getDepthStencilClearValue 1.0 0]
    renderPassData <- createRenderPass rendererData renderPassDataCreateInfo
    writeIORef _renderPassDataListRef (DList.fromList [renderPassData])


createRenderer :: GLFW.Window
               -> String
               -> String
               -> Bool
               -> Bool
               -> [CString]
               -> VkSampleCountFlagBits
               -> IO RendererData
createRenderer window progName engineName enableValidationLayer isConcurrentMode requireExtensions requireMSAASampleCount = do
    let validationLayers = if enableValidationLayer then Constants.vulkanLayers else []
    if enableValidationLayer
    then logInfo $ "Enable validation layers : " ++ show validationLayers
    else logInfo $ "Disabled validation layers"

    defaultRendererData <- newRendererData

    vkInstance <- createVulkanInstance progName engineName validationLayers requireExtensions
    vkSurface <- createVkSurface vkInstance window
    (physicalDevice, Just swapChainSupportDetails, supportedFeatures) <-
        selectPhysicalDevice vkInstance (Just vkSurface)
    deviceProperties <- getPhysicalDeviceProperties physicalDevice
    msaaSamples <- (min requireMSAASampleCount) <$> (getMaxUsableSampleCount deviceProperties)
    queueFamilyIndices <- getQueueFamilyIndices physicalDevice vkSurface isConcurrentMode
    let renderFeatures = RenderFeatures
            { _anisotropyEnable = getField @"samplerAnisotropy" supportedFeatures
            , _msaaSamples = msaaSamples }
    let graphicsQueueIndex = _graphicsQueueIndex queueFamilyIndices
        presentQueueIndex = _presentQueueIndex queueFamilyIndices
        queueFamilyIndexList = Set.toList $ Set.fromList [graphicsQueueIndex, presentQueueIndex]
    device <- createDevice physicalDevice queueFamilyIndexList
    queueMap <- createQueues device queueFamilyIndexList
    let defaultQueue = (Map.elems queueMap) !! 0
        queueFamilyDatas = QueueFamilyDatas
            { _graphicsQueue = fromMaybe defaultQueue $ Map.lookup graphicsQueueIndex queueMap
            , _presentQueue = fromMaybe defaultQueue $ Map.lookup presentQueueIndex queueMap
            , _queueFamilyIndexList = queueFamilyIndexList
            , _queueFamilyCount = fromIntegral $ length queueMap
            , _queueFamilyIndices = queueFamilyIndices }
    commandPool <- createCommandPool device queueFamilyDatas
    imageAvailableSemaphores <- createSemaphores device
    renderFinishedSemaphores <- createSemaphores device
    frameFencesPtr <- createFrameFences device

    swapChainData <- createSwapChainData device swapChainSupportDetails queueFamilyDatas vkSurface Constants.enableImmediateMode
    swapChainDataRef <- newIORef swapChainData
    swapChainSupportDetailsRef <- newIORef swapChainSupportDetails

    let commandBufferCount = fromIntegral $ _swapChainImageCount swapChainData
    commandBuffersPtr <- mallocArray (fromIntegral commandBufferCount)::IO (Ptr VkCommandBuffer)
    createCommandBuffers device commandPool commandBufferCount commandBuffersPtr
    commandBuffers <- peekArray (fromIntegral commandBufferCount) commandBuffersPtr

    descriptorPool <- createDescriptorPool device (_swapChainImageCount swapChainData)

    let rendererData = defaultRendererData
          { _imageAvailableSemaphores = imageAvailableSemaphores
          , _renderFinishedSemaphores = renderFinishedSemaphores
          , _vkInstance = vkInstance
          , _vkSurface = vkSurface
          , _device = device
          , _physicalDevice = physicalDevice
          , _queueFamilyDatas = queueFamilyDatas
          , _frameFencesPtr = frameFencesPtr
          , _commandPool = commandPool
          , _commandBuffersPtr = commandBuffersPtr
          , _commandBufferCount = commandBufferCount
          , _swapChainDataRef = swapChainDataRef
          , _swapChainSupportDetailsRef = swapChainSupportDetailsRef
          , _renderFeatures = renderFeatures
          , _descriptorPool = descriptorPool }
    return rendererData

destroyRenderer :: RendererData -> IO ()
destroyRenderer rendererData@RendererData {..} = do
    -- need VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT flag for createDescriptorPool
    -- destroyDescriptorSetData (getDevice rendererData) descriptorPool descriptorSetData
    destroyDescriptorPool _device _descriptorPool
    renderTargetData <- readIORef _renderTargetDataRef
    destroyTexture rendererData (_sceneColorTexture renderTargetData)
    destroyTexture rendererData (_sceneDepthTexture renderTargetData)

    renderPassDataList <- readIORef _renderPassDataListRef
    forM_ renderPassDataList $ \renderPassData -> do
        destroyRenderPassData _device renderPassData

    destroySemaphores _device _renderFinishedSemaphores
    destroySemaphores _device _imageAvailableSemaphores
    destroyFrameFences _device _frameFencesPtr
    destroyCommandBuffers _device _commandPool _commandBufferCount _commandBuffersPtr
    destroyCommandPool _device _commandPool
    swapChainData <- (getSwapChainData rendererData)
    destroySwapChainData _device swapChainData
    destroyDevice _device
    destroyVkSurface _vkInstance _vkSurface
    destroyVulkanInstance _vkInstance
    free _commandBuffersPtr
    free _imageIndexPtr


resizeWindow :: GLFW.Window -> RendererData -> IO ()
resizeWindow window rendererData@RendererData {..} = do
    logInfo "                  "
    logInfo "<< resizeWindow >>"

    deviceWaitIdle rendererData

    renderPassDataList <- readIORef _renderPassDataListRef
    forM_ renderPassDataList $ \renderPassData -> do
        destroyRenderPass rendererData renderPassData

    renderTargetData <- readIORef _renderTargetDataRef
    destroyTexture rendererData (_sceneColorTexture renderTargetData)
    destroyTexture rendererData (_sceneDepthTexture renderTargetData)

    -- recreate swapChain
    recreateSwapChain rendererData window

    -- recreate resources
    renderTargetData <- createRenderTargets rendererData
    writeIORef _renderTargetDataRef renderTargetData

    renderPassDataCreateInfo <- newRenderPassDataCreateInfo
        rendererData
        [(_imageView (_sceneColorTexture renderTargetData)), (_imageView (_sceneDepthTexture renderTargetData))]
        [getColorClearValue [0.0, 0.0, 0.2, 1.0], getDepthStencilClearValue 1.0 0]
    renderPassData <- createRenderPassData _device renderPassDataCreateInfo
    writeIORef _renderPassDataListRef (DList.fromList [renderPassData])

    writeIORef _needRecordCommandBufferRef True


updateRendererData :: RendererData -> Mat44f -> GeometryBufferData -> [VkDescriptorSet] -> [VkDeviceMemory] -> IO ()
updateRendererData rendererData@RendererData{..} viewMatrix geometryBufferData descriptorSets transformObjectMemories = do
    -- record render commands
    needRecordCommandBuffer <- readIORef _needRecordCommandBufferRef
    when needRecordCommandBuffer $ do
        let vertexBuffer = _vertexBuffer geometryBufferData
            vertexIndexCount = _vertexIndexCount geometryBufferData
            indexBuffer = _indexBuffer geometryBufferData
        renderPassData <- getRenderPassData rendererData
        recordCommandBuffer rendererData renderPassData vertexBuffer (vertexIndexCount, indexBuffer) descriptorSets
        writeIORef _needRecordCommandBufferRef False

    frameIndex <- readIORef _frameIndexRef
    result <- drawFrame rendererData frameIndex transformObjectMemories viewMatrix

    -- waiting
    deviceWaitIdle rendererData

    let needRecreateSwapChain = (VK_ERROR_OUT_OF_DATE_KHR == result || VK_SUBOPTIMAL_KHR == result)
    writeIORef _needRecreateSwapChainRef needRecreateSwapChain

    writeIORef _frameIndexRef $ mod (frameIndex + 1) Constants.maxFrameCount


recreateSwapChain :: RendererData -> GLFW.Window -> IO ()
recreateSwapChain rendererData@RendererData {..} window = do
    logInfo "<< recreateSwapChain >>"
    destroyCommandBuffers _device _commandPool _commandBufferCount _commandBuffersPtr
    swapChainData <- getSwapChainData rendererData
    destroySwapChainData _device swapChainData

    newSwapChainSupportDetails <- querySwapChainSupport _physicalDevice _vkSurface
    newSwapChainData <- createSwapChainData _device newSwapChainSupportDetails _queueFamilyDatas _vkSurface Constants.enableImmediateMode
    writeIORef _swapChainDataRef newSwapChainData
    writeIORef _swapChainSupportDetailsRef newSwapChainSupportDetails

    createCommandBuffers _device _commandPool _commandBufferCount _commandBuffersPtr


recordCommandBuffer :: RendererData
                    -> RenderPassData
                    -> VkBuffer -- vertex data
                    -> (Word32, VkBuffer) -- nr of indices and index data
                    -> [VkDescriptorSet]
                    -> IO ()
recordCommandBuffer rendererData renderPassData vertexBuffer (indexCount, indexBuffer) descriptorSets = do
    let renderPass = _renderPass renderPassData
        graphicsPipelineData = _graphicsPipelineData renderPassData
        pipelineLayout = _pipelineLayout graphicsPipelineData
        pipeline = _pipeline graphicsPipelineData
        frameBufferData = _frameBufferData renderPassData
        frameBuffers = _frameBuffers frameBufferData
        imageExtent = _frameBufferSize frameBufferData
        clearValues = _frameBufferClearValues frameBufferData
    commandBuffers <- getCommandBuffers rendererData

    -- record command buffers
    forM_ (zip3 commandBuffers frameBuffers descriptorSets) $ \(commandBuffer, frameBuffer, descriptorSet) -> do
        -- begin command buffer
        let commandBufferBeginInfo = createVk @VkCommandBufferBeginInfo
                $  set @"sType" VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
                &* set @"pNext" VK_NULL
                &* set @"flags" VK_COMMAND_BUFFER_USAGE_SIMULTANEOUS_USE_BIT

        withPtr commandBufferBeginInfo $ \commandBufferBeginInfoPtr -> do
            result <- vkBeginCommandBuffer commandBuffer commandBufferBeginInfoPtr
            validationVK result "vkBeginCommandBuffer failed!"

        -- begin renderpass
        let renderPassBeginInfo = createVk @VkRenderPassBeginInfo
                $  set @"sType" VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO
                &* set @"pNext" VK_NULL
                &* set @"renderPass" renderPass
                &* set @"framebuffer" frameBuffer
                &* setVk @"renderArea"
                    (  setVk @"offset"
                            (  set @"x" 0
                            &* set @"y" 0 )
                    &* set @"extent" imageExtent )
                &* set @"clearValueCount" (fromIntegral $ length clearValues)
                &* setListRef @"pClearValues" clearValues

        withPtr renderPassBeginInfo $ \renderPassBeginInfoPtr ->
            vkCmdBeginRenderPass commandBuffer renderPassBeginInfoPtr VK_SUBPASS_CONTENTS_INLINE

        -- drawing commands
        vkCmdBindPipeline commandBuffer VK_PIPELINE_BIND_POINT_GRAPHICS pipeline
        withArray [vertexBuffer] $ \vertexBufferPtr ->
            withArray [0] $ \vertexOffsetPtr ->
                vkCmdBindVertexBuffers commandBuffer 0 1 vertexBufferPtr vertexOffsetPtr
        vkCmdBindIndexBuffer commandBuffer indexBuffer 0 VK_INDEX_TYPE_UINT32
        withArray [descriptorSet] $ \descriptorSetPtr ->
            vkCmdBindDescriptorSets commandBuffer VK_PIPELINE_BIND_POINT_GRAPHICS pipelineLayout 0 1 descriptorSetPtr 0 VK_NULL
        vkCmdDrawIndexed commandBuffer indexCount 1 0 0 0

        -- end renderpass & command buffer
        vkCmdEndRenderPass commandBuffer
        vkEndCommandBuffer commandBuffer >>= flip validationVK "vkEndCommandBuffer failed!"


runCommandsOnce :: VkDevice
                -> VkCommandPool
                -> VkQueue
                -> (VkCommandBuffer -> IO ())
                -> IO ()
runCommandsOnce device commandPool commandQueue action = do
    let allocInfo = createVk @VkCommandBufferAllocateInfo
            $  set @"sType" VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO
            &* set @"level" VK_COMMAND_BUFFER_LEVEL_PRIMARY
            &* set @"commandPool" commandPool
            &* set @"commandBufferCount" 1
            &* set @"pNext" VK_NULL

    allocaPeek $ \commandBufferPtr -> do
        withPtr allocInfo $ \allocInfoPtr -> do
            vkAllocateCommandBuffers device allocInfoPtr commandBufferPtr
        commandBuffer <- peek commandBufferPtr

        let beginInfo = createVk @VkCommandBufferBeginInfo
                $  set @"sType" VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
                &* set @"flags" VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT
                &* set @"pNext" VK_NULL

        withPtr beginInfo $ \beginInfoPtr -> do
            vkBeginCommandBuffer commandBuffer beginInfoPtr

        -- run action
        action commandBuffer

        vkEndCommandBuffer commandBuffer

        let submitInfo = createVk @VkSubmitInfo
                $  set @"sType" VK_STRUCTURE_TYPE_SUBMIT_INFO
                &* set @"pNext" VK_NULL
                &* set @"waitSemaphoreCount" 0
                &* set @"pWaitSemaphores"   VK_NULL
                &* set @"pWaitDstStageMask" VK_NULL
                &* set @"commandBufferCount" 1
                &* set @"pCommandBuffers" commandBufferPtr
                &* set @"signalSemaphoreCount" 0
                &* set @"pSignalSemaphores" VK_NULL

        {- TODO: a real app would need a better logic for waiting.

                 In the example below, we create a new fence every time we want to
                 execute a single command. Then, we attach this fence to our command.
                 vkWaitForFences makes the host (CPU) wait until the command is executed.
                 The other way to do this thing is vkQueueWaitIdle.

                 I guess, a good approach could be to pass the fence to this function
                 from the call site. The call site would decide when it wants to wait
                 for this command to finish.

                 Even if we don't pass the fence from outside, maybe we should create
                 the fence oustise of the innermost `locally` scope. This way, the
                 fence would be shared between calls (on the other hand, a possible
                 concurrency would be hurt in this case).
               -}
        --   fence <- createFence dev False
        --   withVkPtr submitInfo $ \siPtr ->
        --       vkQueueSubmit cmdQueue 1 siPtr fence
        --   fencePtr <- newArrayPtr [fence]
        --   vkWaitForFences dev 1 fencePtr VK_TRUE (maxBound :: Word64)

        withPtr submitInfo $ \submitInfoPtr -> do
            result <- vkQueueSubmit commandQueue 1 submitInfoPtr VK_NULL_HANDLE
            validationVK result "vkQueueSubmit error"

        vkQueueWaitIdle commandQueue >>= flip validationVK "vkQueueWaitIdle error"

        vkFreeCommandBuffers device commandPool 1 commandBufferPtr
    return ()

