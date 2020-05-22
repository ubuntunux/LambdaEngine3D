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
import HulkanEngine3D.Utilities.System


type UniformBufferDataMap = HashTable.BasicHashTable Text.Text UniformBufferData

data SceneConstants = SceneConstants
    { _SCREEN_SIZE :: Vec2f
    , _BACKBUFFER_SIZE :: Vec2f
    , _TIME :: Scalar Float
    , _DELTA_TIME :: Scalar Float
    , _JITTER_FRAME :: Scalar Float
    , _SceneConstantsDummy0 :: Scalar Int
    } deriving (Show, Generic)

instance PrimBytes SceneConstants

data ViewProjectionConstants = ViewProjectionConstants
  { _VIEW  :: Mat44f
  , _PROJECTION :: Mat44f
  , _VIEW_PROJECTION :: Mat44f
  , _INV_VIEW_PROJECTION :: Mat44f
  } deriving (Show, Generic)

instance PrimBytes ViewProjectionConstants

data LightConstants = LightConstants
    { _SHADOW_VIEW_PROJECTION :: Mat44f
    , _LIGHT_POSITION :: Vec3f
    , _SHADOW_EXP :: Scalar Float
    , _LIGHT_DIRECTION :: Vec3f
    , _SHADOW_BIAS :: Scalar Float
    , _LIGHT_COLOR :: Vec3f
    , _SHADOW_SAMPLES :: Scalar Int
    } deriving (Show, Generic)

instance PrimBytes LightConstants


registUniformBufferDatas :: VkPhysicalDevice -> VkDevice -> UniformBufferDataMap -> IO ()
registUniformBufferDatas physicalDevice device uniformBufferDataMap = do
    registUniformBufferData uniformBufferDataMap "SceneConstants" (bSizeOf @SceneConstants undefined)
    registUniformBufferData uniformBufferDataMap "ViewProjectionConstants" (bSizeOf @ViewProjectionConstants undefined)
    registUniformBufferData uniformBufferDataMap "LightConstants" (bSizeOf @LightConstants undefined)
    where
        registUniformBufferData uniformBufferDataMap uniformBufferName sizeOfUniformBuffer = do
            uniformBufferData <- createUniformBufferData physicalDevice device uniformBufferName sizeOfUniformBuffer
            HashTable.insert uniformBufferDataMap uniformBufferName uniformBufferData

destroyUniformBufferDatas :: VkDevice -> UniformBufferDataMap -> IO ()
destroyUniformBufferDatas device uniformBufferDataMap = do
    clearHashTable uniformBufferDataMap (\(k, v) -> destroyUniformBufferData device v)