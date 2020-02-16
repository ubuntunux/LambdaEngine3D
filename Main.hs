{-# LANGUAGE DataKinds        #-}
{-# LANGUAGE Strict           #-}

module Main
  ( main
  ) where

import Control.Concurrent (forkIO)
import Control.Monad
import Data.IORef
import Data.Maybe (isNothing)
import qualified Data.DList as DList
import System.Directory
import Foreign.Marshal.Utils
import Foreign.Marshal.Alloc
import Graphics.Vulkan.Core_1_0
import Graphics.Vulkan.Ext.VK_KHR_swapchain
import qualified Graphics.UI.GLFW as GLFW

import HulkanEngine3D.Application
import HulkanEngine3D.Application.Editor
import HulkanEngine3D.Resource.ObjLoader
import HulkanEngine3D.Utilities.System
import HulkanEngine3D.Utilities.Logger
import HulkanEngine3D.Vulkan
import HulkanEngine3D.Vulkan.Mesh
import HulkanEngine3D.Vulkan.Device
import HulkanEngine3D.Vulkan.Descriptor
import HulkanEngine3D.Vulkan.Texture
import HulkanEngine3D.Vulkan.RenderPass
import HulkanEngine3D.Vulkan.TransformationObject
import qualified HulkanEngine3D.Constants as Constants


main::IO()
main = do
    forkIO $ runEditor
    windowSizeChanged <- newIORef False
    maybeWindow <- createGLFWWindow 1024 768 "Vulkan Application" windowSizeChanged
    when (isNothing maybeWindow) (throwVKMsg "Failed to initialize GLFW window.")
    logInfo "                             "
    logInfo "<< Initialized GLFW window >>"
    requireExtensions <- GLFW.getRequiredInstanceExtensions
    instanceExtensionNames <- getInstanceExtensionSupport
    checkExtensionResult <- checkExtensionSupport instanceExtensionNames requireExtensions
    unless checkExtensionResult (throwVKMsg "Failed to initialize GLFW window.")
    let Just window = maybeWindow
        progName = "Hulkan App"
        engineName = "HulkanEngine3D"
        enableValidationLayer = True
        isConcurrentMode = True
        msaaSampleCount = VK_SAMPLE_COUNT_4_BIT
    -- create renderer
    defaultRendererData <- getDefaultRendererData
    rendererData <- createRenderer
        defaultRendererData
            window
            progName
            engineName
            enableValidationLayer
            isConcurrentMode
            requireExtensions
            msaaSampleCount
    rendererDataRef <- newIORef rendererData

    -- create render targets
    (sceneColorTexture, sceneDepthTexture) <- createRenderTargets rendererData

    sceneColorTextureRef <- newIORef sceneColorTexture
    sceneDepthTextureRef <- newIORef sceneDepthTexture

    -- create render pass data
    renderPassDataCreateInfo <- getDefaultRenderPassDataCreateInfo
        rendererData
        [(_imageView sceneColorTexture), (_imageView sceneDepthTexture)]
        [getColorClearValue [0.0, 0.0, 0.2, 1.0], getDepthStencilClearValue 1.0 0]
    renderPassData <- createRenderPass rendererData renderPassDataCreateInfo
    renderPassDataListRef <- newIORef (DList.singleton renderPassData)

    -- create resources
    (vertices, indices) <- loadModel "Resource/Externals/Meshes/suzan.obj"
    geometryBuffer <- createGeometryBuffer rendererData "test" vertices indices
    geometryBufferListRef <- newIORef (DList.singleton geometryBuffer)
    textureData <- createTexture rendererData "Resource/Externals/Textures/texture.jpg"

    (transformObjectMemories, transformObjectBuffers) <- unzip <$> createTransformObjectBuffers
        (getPhysicalDevice rendererData)
        (getDevice rendererData)
        (getSwapChainImageCount rendererData)
    descriptorPool <- createDescriptorPool (getDevice rendererData) (getSwapChainImageCount rendererData)
    descriptorSetData <- createDescriptorSetData (getDevice rendererData) descriptorPool (getSwapChainImageCount rendererData) (getDescriptorSetLayout renderPassData)
    let descriptorBufferInfos = fmap transformObjectBufferInfo transformObjectBuffers
    forM_ (zip descriptorBufferInfos (_descriptorSets descriptorSetData)) $ \(descriptorBufferInfo, descriptorSet) ->
        prepareDescriptorSet (getDevice rendererData) descriptorBufferInfo (getTextureImageInfo textureData) descriptorSet

    -- record render commands
    let vertexBuffer = _vertexBuffer geometryBuffer
        vertexIndexCount = _vertexIndexCount geometryBuffer
        indexBuffer = _indexBuffer geometryBuffer
    recordCommandBuffer rendererData renderPassData vertexBuffer (vertexIndexCount, indexBuffer) (_descriptorSets descriptorSetData)

    -- init system variables
    needRecreateSwapChainRef <- newIORef False
    frameIndexRef <- newIORef 0
    imageIndexPtr <- new (0 :: Word32)

    currentTime <- getSystemTime
    currentTimeRef <- newIORef currentTime
    elapsedTimeRef <- newIORef (0.0 :: Double)
    -- Main Loop
    glfwMainLoop window $ do
        currentTime <- getSystemTime
        previousTime <- readIORef currentTimeRef
        let deltaTime = currentTime - previousTime
        elapsedTime <- do
            elapsedTimePrev <- readIORef elapsedTimeRef
            return $ elapsedTimePrev + deltaTime
        writeIORef currentTimeRef currentTime
        writeIORef elapsedTimeRef elapsedTime
        -- when (0.0 < deltaTime) . logInfo $ show (1.0 / deltaTime) ++ "fps / " ++ show deltaTime ++ "ms"

        needRecreateSwapChain <- readIORef needRecreateSwapChainRef
        when needRecreateSwapChain $ do
            writeIORef needRecreateSwapChainRef False
            logInfo "                        "
            logInfo "<< Recreate SwapChain >>"

            -- cleanUp swapChain
            rendererData <- readIORef rendererDataRef
            result <- vkDeviceWaitIdle $ _device rendererData
            validationVK result "vkDeviceWaitIdle failed!"

            renderPassDataList <- readIORef renderPassDataListRef
            forM_ renderPassDataList $ \renderPassData -> do
                destroyRenderPass rendererData renderPassData

            sceneColorTexture <- readIORef sceneColorTextureRef
            sceneDepthTexture <- readIORef sceneDepthTextureRef
            destroyTexture rendererData sceneColorTexture
            destroyTexture rendererData sceneDepthTexture

            -- recreate swapChain
            rendererData <- recreateSwapChain rendererData window

            -- recreate resources
            (sceneColorTexture, sceneDepthTexture) <- createRenderTargets rendererData
            writeIORef sceneColorTextureRef sceneColorTexture
            writeIORef sceneDepthTextureRef sceneDepthTexture

            renderPassDataCreateInfo <- getDefaultRenderPassDataCreateInfo
                rendererData
                [(_imageView sceneColorTexture), (_imageView sceneDepthTexture)]
                [getColorClearValue [0.0, 0.0, 0.2, 1.0], getDepthStencilClearValue 1.0 0]
            renderPassData <- createRenderPassData (getDevice rendererData) renderPassDataCreateInfo

            -- record render commands
            let vertexBuffer = _vertexBuffer geometryBuffer
                vertexIndexCount = _vertexIndexCount geometryBuffer
                indexBuffer = _indexBuffer geometryBuffer
            recordCommandBuffer rendererData renderPassData vertexBuffer (vertexIndexCount, indexBuffer) (_descriptorSets descriptorSetData)

            writeIORef renderPassDataListRef (DList.fromList [renderPassData])
            writeIORef rendererDataRef rendererData
        frameIndex <- readIORef frameIndexRef
        rendererData <- readIORef rendererDataRef
        renderPassDataList <- readIORef renderPassDataListRef

        result <- drawFrame rendererData frameIndex imageIndexPtr transformObjectMemories
        vkDeviceWaitIdle (getDevice rendererData)
        writeIORef frameIndexRef $ mod (frameIndex + 1) Constants.maxFrameCount
        sizeChanged <- readIORef windowSizeChanged
        when (VK_ERROR_OUT_OF_DATE_KHR == result || VK_SUBOPTIMAL_KHR == result || sizeChanged) $ do
            atomicWriteIORef windowSizeChanged False
            writeIORef needRecreateSwapChainRef True
        return True

    -- Terminate
    logInfo "               "
    logInfo "<< Terminate >>"
    rendererData <- readIORef rendererDataRef
    result <- vkDeviceWaitIdle $ _device rendererData
    validationVK result "vkDeviceWaitIdle failed!"

    destroyTransformObjectBuffers (getDevice rendererData) transformObjectBuffers transformObjectMemories

    -- need VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT flag for createDescriptorPool
    -- destroyDescriptorSetData (getDevice rendererData) descriptorPool descriptorSetData
    destroyDescriptorPool (getDevice rendererData) descriptorPool

    sceneColorTexture <- readIORef sceneColorTextureRef
    sceneDepthTexture <- readIORef sceneDepthTextureRef
    destroyTexture rendererData sceneColorTexture
    destroyTexture rendererData sceneDepthTexture

    destroyTexture rendererData textureData
    
    geometryBufferList <- readIORef geometryBufferListRef
    forM_ geometryBufferList $ \geometryBuffer -> do
        destroyGeometryBuffer rendererData geometryBuffer

    renderPassDataList <- readIORef renderPassDataListRef
    forM_ renderPassDataList $ \renderPassData -> do
        destroyRenderPassData (_device rendererData) renderPassData

    destroyRenderer rendererData
    free imageIndexPtr

    destroyGLFWWindow window
