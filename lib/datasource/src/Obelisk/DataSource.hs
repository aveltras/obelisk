{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
module Obelisk.DataSource
  ( DataSourceRes
  , DataSource
  , DataSourceT
  , HasDataSource
  , deriveArgDict
  , deriveJSONGADT
  , localDataSource
  , runDataSourceT
  , webSocketDataSource
  ) where

import Control.Monad.Reader
import Control.Monad.Primitive
import Control.Monad.Ref
import qualified Data.Aeson as A
import Data.Aeson.GADT.TH (deriveJSONGADT)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import Data.Constraint.Extras
import Data.Constraint.Forall
import Data.Constraint.Extras.TH (deriveArgDict)
import Data.Map.Strict (toList)
import Data.Text (Text)
import GHCJS.DOM.Document (Document)
import GHCJS.DOM.Types (MonadJSM)
import Reflex.Host.Class
import Reflex.Dom.Core

import Obelisk.ExecutableConfig.Frontend
import Obelisk.Route.Frontend

newtype DataSourceRes res = DataSourceRes (Either String res)

class Monad m => HasDataSource t (ds :: * -> *) m where
  askData :: Event t (ds x) -> m (Event t (DataSourceRes x))
  default askData :: (MonadTrans f, HasDataSource t ds m', m ~ f m') => Event t (ds x) -> m (Event t (DataSourceRes x))
  askData = lift . askData

instance HasDataSource t ds m => HasDataSource t ds (BehaviorWriterT t w m)
instance HasDataSource t ds m => HasDataSource t ds (DynamicWriterT t w m)
instance HasDataSource t ds m => HasDataSource t ds (EventWriterT t w m)
instance HasDataSource t ds m => HasDataSource t ds (PostBuildT t m)
instance HasDataSource t ds m => HasDataSource t ds (QueryT t q m)
instance HasDataSource t ds m => HasDataSource t ds (ReaderT r m)
instance HasDataSource t ds m => HasDataSource t ds (RequesterT t request response m)
instance HasDataSource t ds m => HasDataSource t ds (RouteToUrlT r m)
instance HasDataSource t ds m => HasDataSource t ds (SetRouteT t r m)
instance HasDataSource t ds m => HasDataSource t ds (StaticDomBuilderT t m)
instance HasDataSource t ds m => HasDataSource t ds (TriggerEventT t m)
instance HasDataSource t ds m => HasDataSource t ds (RoutedT t r m)
instance HasDataSource t ds m => HasDataSource t ds (FrontendConfigsT m)
instance HasFrontendConfigs m => HasFrontendConfigs (DataSourceT t ds m)

newtype DataSourceT t (ds :: * -> *) m a = DataSourceT { unDataSourceT :: RequesterT t ds DataSourceRes m a }
  deriving
    ( Functor
    , Applicative
    , DomBuilder t
    , Monad
    , MonadFix
    , MonadHold t
    , MonadIO
#ifndef ghcjs_HOST_OS
    , MonadJSM
#endif
    , MonadRef
    , MonadReflexCreateTrigger t
    , MonadSample t
    , MonadTrans
    , NotReady t
    , PerformEvent t
    , PostBuild t
    , Prerender js t
    , TriggerEvent t
    , HasDocument
    )

instance (Adjustable t m, MonadFix m, MonadHold t m) => Adjustable t (DataSourceT t ds m) where
  runWithReplace a e = DataSourceT $ runWithReplace (unDataSourceT a) (unDataSourceT <$> e)
  traverseDMapWithKeyWithAdjust f m e = DataSourceT $ traverseDMapWithKeyWithAdjust (\k v -> unDataSourceT $ f k v) m e
  traverseIntMapWithKeyWithAdjust f m e = DataSourceT $ traverseIntMapWithKeyWithAdjust (\k v -> unDataSourceT $ f k v) m e
  traverseDMapWithKeyWithAdjustWithMove f m e = DataSourceT $ traverseDMapWithKeyWithAdjustWithMove (\k v -> unDataSourceT $ f k v) m e

instance PrimMonad m => PrimMonad (DataSourceT t ds m) where
  type PrimState (DataSourceT t ds m) = PrimState m
  primitive = lift . primitive

instance (Monad m, Reflex t) => HasDataSource t ds (DataSourceT t ds m) where
  askData = DataSourceT . requesting

data DataSource t ds m = DataSource { reqFn :: Event t (RequesterData ds) -> m (Event t (RequesterData (DataSourceRes))) }

runDataSourceT :: (MonadFix m, Reflex t) => DataSource t ds m -> DataSourceT t ds m a -> m a
runDataSourceT dataSource child = mdo
  eResponse <- (reqFn dataSource) eRequest
  (val, eRequest) <- runRequesterT (unDataSourceT child) eResponse
  return val

localDataSource ::
  ( PerformEvent t m
  , MonadIO (Performable m) )
  => (forall x. (ds x) -> IO (DataSourceRes x))
  -> DataSource t ds m
localDataSource handler = DataSource $ \eRequest -> do
  performEvent $ liftIO . (traverseRequesterData handler) <$> eRequest

webSocketDataSource :: forall t ds m.
  ( HasJSContext m
  , MonadFix m
  , MonadJSM (Performable m)
  , MonadJSM m
  , ForallF A.ToJSON ds
  , Has A.FromJSON ds
  , MonadHold t m
  , PerformEvent t m 
  , PostBuild t m
  , TriggerEvent t m )
  => Text -- WebSocket URL
  -> Event t (Word, Text) -- close event
  -> Bool -- reconnect on close
  -> DataSource t ds m
webSocketDataSource url eClose doReconnect =
  DataSource $ \eRequest -> mdo
    let eSend = (fmap . fmap) encodeReq (toList <$> eMapRawRequest) :: Event t [BS.ByteString]
    ws <- webSocket url $ WebSocketConfig eSend eClose doReconnect []
    (eMapRawRequest, eResponse) <- matchResponsesWithRequests decodeRes2 eRequest (fmapMaybe decodeTag (_webSocket_recv ws))
    return eResponse

    where

      encodeReq :: (Int, A.Value) -> BS.ByteString
      encodeReq = LBS.toStrict . A.encode

      decodeRes2 :: forall b. ds b -> (A.Value, A.Value -> DataSourceRes b)
      decodeRes2 reqG = (whichever @A.ToJSON @ds @b A.toJSON reqG, f)
        where
          f val = do
            let result = has @A.FromJSON reqG A.fromJSON val
            case result of
              A.Error _s -> error "boom"
              A.Success a -> DataSourceRes a

      decodeTag :: BS.ByteString -> Maybe (Int, A.Value)
      decodeTag bs =
        case A.decodeStrict bs of
          Nothing         -> Nothing :: Maybe (Int, A.Value)
          Just (val, rst) -> Just (val, rst)

instance (MonadJSM m, RawDocument (DomBuilderSpace (HydrationDomBuilderT s t m)) ~ Document) => HasDataSource t ds (HydrationDomBuilderT s t m) where
  askData = undefined -- fmap (parseCookies . encodeUtf8) $ getCookie =<< askDocument