{-# LANGUAGE DataKinds        #-}
{-# LANGUAGE Strict           #-}

module Main
  ( main
  ) where

import Control.Monad
import Data.IORef
import Data.Maybe (isNothing)
import qualified Data.DList as DList
import System.CPUTime
import Foreign.Marshal.Alloc
import Foreign.Marshal.Utils
import Graphics.Vulkan.Core_1_0
import Graphics.Vulkan.Ext.VK_KHR_swapchain
import qualified Graphics.UI.GLFW as GLFW

import Library.Utils
import Library.Application
import Library.Logger
import Library.Vulkan
import Library.Vulkan.Mesh
import Library.Resource.ObjLoader
import qualified Library.Constants as Constants


main::IO()
main = do
    windowSizeChanged <- newIORef False
    maybeWindow <- createGLFWWindow 1024 768 "Vulkan Application" windowSizeChanged
    when (isNothing maybeWindow) (throwVKMsg "Failed to initialize GLFW window.")
    logInfo "Initialized GLFW window."
    requireExtensions <- GLFW.getRequiredInstanceExtensions
    instanceExtensionNames <- getInstanceExtensionSupport
    checkExtensionResult <- checkExtensionSupport instanceExtensionNames requireExtensions
    unless checkExtensionResult (throwVKMsg "Failed to initialize GLFW window.")
    let Just window = maybeWindow
        progName = "Hulkan App"
        engineName = "HulkanEngine3D"
        isConcurrentMode = True
    needCreateResourceRef <- newIORef True
    needCreateRenderDataRef <- newIORef True
    defaultRenderData <- getDefaultRenderData
    renderDataRef <- newIORef defaultRenderData
    frameIndexRef <- newIORef 0
    imageIndexPtr <- new (0 :: Word32)
    currentTime <- getCPUTime
    currentTimeRef <- newIORef currentTime
    elapsedTimeRef <- newIORef (0.0 :: Double)
    geometryBufferListRef <- newIORef (DList.fromList []::DList.DList GeometryBuffer)
    --resourceRef <- newIORef Resource
    -- Main Loop
    glfwMainLoop window $ do
        currentTime <- getCPUTime
        previousTime <- readIORef currentTimeRef
        let deltaTime = fromIntegral (currentTime - previousTime) / Constants.convertToSecond
        elapsedTime <- do
            elapsedTimePrev <- readIORef elapsedTimeRef
            return $ elapsedTimePrev + deltaTime
        writeIORef currentTimeRef currentTime
        writeIORef elapsedTimeRef elapsedTime
        --when (0.0 < deltaTime) $ print (1.0 / deltaTime)

        needCreateRenderData <- readIORef needCreateRenderDataRef
        when needCreateRenderData $ do
            writeIORef needCreateRenderDataRef False
            readRenderData <- readIORef renderDataRef
            when (VK_NULL /= _device readRenderData) $ do
                result <- vkDeviceWaitIdle $ _device readRenderData
                validationVK result "vkDeviceWaitIdle failed!"
                destroyRenderData readRenderData
            (preRenderData, swapChainSupportDetails) <-
                createRenderer defaultRenderData window progName engineName isConcurrentMode requireExtensions
            newRenderData <- createRenderData preRenderData swapChainSupportDetails
            writeIORef renderDataRef newRenderData
        needCreateResource <- readIORef needCreateResourceRef
        when needCreateResource $ do
            writeIORef needCreateResourceRef False
            renderData <- readIORef renderDataRef
            (vertices, indices) <- loadModel "Resource/Externals/Meshes/suzan.obj"
            geometryBuffer <- createGeometryBuffer "test" renderData vertices indices
            geometryBufferList <- readIORef geometryBufferListRef
            writeIORef geometryBufferListRef (DList.cons geometryBuffer geometryBufferList)
            return ()
        renderData <- readIORef renderDataRef
        frameIndex <- readIORef frameIndexRef
        result <- drawFrame renderData frameIndex imageIndexPtr
        writeIORef frameIndexRef $ mod (frameIndex + 1) Constants.maxFrameCount
        sizeChanged <- readIORef windowSizeChanged
        when (VK_ERROR_OUT_OF_DATE_KHR == result || VK_SUBOPTIMAL_KHR == result || sizeChanged) $ do
            atomicWriteIORef windowSizeChanged False
            writeIORef needCreateRenderDataRef True
        return True
    -- Terminate
    logInfo "[ Terminate ]"
    renderData <- readIORef renderDataRef
    geometryBufferList <- readIORef geometryBufferListRef
    destroyGeometryBuffers (_device renderData) geometryBufferList
    result <- vkDeviceWaitIdle $ _device renderData
    validationVK result "vkDeviceWaitIdle failed!"
    destroyRenderer renderData
    free imageIndexPtr
    
    return ()
