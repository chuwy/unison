{-# LANGUAGE DataKinds #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeOperators #-}

-- | Implementation of unison LSP
--
-- Goals:
--
-- * Format on save
-- * Hover type-signature/definition
-- * Autocomplete
--
-- Stretch goals:
-- * Jump to definition
module Unison.LSP where

import Colog.Core (LogAction (LogAction))
import Control.Monad.Reader
import Control.Monad.State
import Data.Aeson hiding (Options, defaultOptions)
import Data.Tuple (swap)
import Language.LSP.Server
import Language.LSP.Types
import Language.LSP.Types.SMethodMap
import qualified Language.LSP.Types.SMethodMap as SMM
import Language.LSP.VFS
import qualified Network.Simple.TCP as TCP
import Network.Socket
import Unison.LSP.RequestHandlers
import Unison.LSP.Types
import Unison.Prelude
import UnliftIO

spawnLsp :: IO ()
spawnLsp = do
  putStrLn "Booting up LSP"
  TCP.serve (TCP.Host "127.0.0.1") "5050" $ \(sock, _sockaddr) -> do
    sockHandle <- socketToHandle sock ReadWriteMode
    putStrLn "LSP Client connected."
    initVFS $ \vfs -> do
      vfsVar <- newMVar vfs
      void $ runServerWithHandles (LogAction print) (LogAction $ liftIO . print) sockHandle sockHandle (serverDefinition (liftIO . print) vfsVar)

serverDefinition :: (forall a. Show a => a -> Lsp ()) -> MVar VFS -> ServerDefinition Config
serverDefinition logger vfsVar =
  ServerDefinition
    { defaultConfig = lspDefaultConfig,
      onConfigurationChange = lspOnConfigurationChange,
      doInitialize = lspDoInitialize vfsVar,
      staticHandlers = lspStaticHandlers logger,
      interpretHandler = lspInterpretHandler,
      options = lspOptions
    }

lspOnConfigurationChange :: Config -> Value -> Either Text Config
lspOnConfigurationChange _ _ = pure Config

lspDefaultConfig :: Config
lspDefaultConfig = Config

lspDoInitialize :: MVar VFS -> LanguageContextEnv Config -> Message 'Initialize -> IO (Either ResponseError Env)
lspDoInitialize vfsVar ctx _ = pure $ Right $ Env ctx vfsVar

lspStaticHandlers :: (forall a. Show a => a -> Lsp ()) -> Handlers Lsp
lspStaticHandlers logger =
  Handlers
    { reqHandlers = lspReqHandlers,
      notHandlers = lspNotHandlers logger
    }

lspReqHandlers :: SMethodMap (ClientMessageHandler Lsp 'Request)
lspReqHandlers =
  mempty
    & SMM.insert STextDocumentHover (ClientMessageHandler hoverHandler)

lspNotHandlers :: (forall a. Show a => a -> Lsp ()) -> SMethodMap (ClientMessageHandler Lsp 'Notification)
lspNotHandlers logger =
  mempty
    & SMM.insert STextDocumentDidOpen (ClientMessageHandler $ usingVFS . openVFS (LogAction $ lift . logger))
    & SMM.insert STextDocumentDidClose (ClientMessageHandler $ usingVFS . closeVFS (LogAction $ lift . logger))
    & SMM.insert STextDocumentDidChange (ClientMessageHandler $ usingVFS . changeFromClientVFS (LogAction $ lift . logger))
  where
    usingVFS :: forall a. StateT VFS Lsp a -> Lsp a
    usingVFS m = do
      vfsVar <- asks vfs
      -- transactionally access the virtual filesystem
      modifyMVar vfsVar $ \vfs -> swap <$> runStateT m vfs

lspInterpretHandler :: Env -> Lsp <~> IO
lspInterpretHandler env@(Env {context}) =
  Iso toIO fromIO
  where
    toIO (Lsp m) = flip runReaderT context . unLspT . flip runReaderT env $ m
    fromIO m = liftIO m

lspOptions :: Options
lspOptions = defaultOptions
