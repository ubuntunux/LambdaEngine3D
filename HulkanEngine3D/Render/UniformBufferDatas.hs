{-# LANGUAGE DataKinds              #-}
{-# LANGUAGE KindSignatures         #-}
{-# LANGUAGE RecordWildCards        #-}
{-# LANGUAGE Strict                 #-}
{-# LANGUAGE TypeApplications       #-}
{-# LANGUAGE OverloadedStrings      #-}
{-# LANGUAGE DeriveGeneric          #-}

module HulkanEngine3D.Render.UniformBufferDatas where

import GHC.Generics (Generic)

import Graphics.Vulkan
import qualified Data.Text as Text
import qualified Data.HashTable.IO as HashTable

import Numeric.DataFrame

import HulkanEngine3D.Vulkan.UniformBuffer

type UniformBufferDataMap = HashTable.BasicHashTable Text.Text UniformBufferData

data SceneConstantsData = SceneConstantsData
  { _VIEW  :: Mat44f
  , _PROJECTION  :: Mat44f
  } deriving (Show, Generic)

instance PrimBytes SceneConstantsData


registUniformBufferDatas :: VkPhysicalDevice -> VkDevice -> UniformBufferDataMap -> IO ()
registUniformBufferDatas physicalDevice device uniformBufferDataMap = do
    registUniformBufferData uniformBufferDataMap "SceneConstantsData" (bSizeOf @SceneConstantsData undefined)
    where
        registUniformBufferData uniformBufferDataMap uniformBufferName sizeOfUniformBuffer = do
            uniformBufferData <- createUniformBufferData physicalDevice device uniformBufferName sizeOfUniformBuffer
            HashTable.insert uniformBufferDataMap uniformBufferName uniformBufferData

destroyUniformBufferDatas :: VkDevice -> UniformBufferDataMap -> IO ()
destroyUniformBufferDatas device uniformBufferDataMap = do
    HashTable.mapM_ (\(k, v) -> destroyUniformBufferData device v) uniformBufferDataMap