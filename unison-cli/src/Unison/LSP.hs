{-# LANGUAGE DataKinds #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeOperators #-}

module Unison.LSP where

import Colog.Core (LogAction (LogAction))
import Colog.Core qualified as Colog
import Compat (onWindows)
import Control.Monad.Reader
import Data.ByteString.Builder.Extra (defaultChunkSize)
import Data.Char (toLower)
import GHC.IO.Exception (ioe_errno)
import Ki qualified
import Language.LSP.Logging qualified as LSP
import Language.LSP.Server
import Language.LSP.Types
import Language.LSP.Types.SMethodMap
import Language.LSP.Types.SMethodMap qualified as SMM
import Language.LSP.VFS
import Network.Simple.TCP qualified as TCP
import System.Environment (lookupEnv)
import System.IO (hPutStrLn)
import Unison.Codebase
import Unison.Codebase.Branch (Branch)
import Unison.Codebase.Path qualified as Path
import Unison.Codebase.Runtime (Runtime)
import Unison.Debug qualified as Debug
import Unison.LSP.CancelRequest (cancelRequestHandler)
import Unison.LSP.CodeAction (codeActionHandler)
import Unison.LSP.CodeLens (codeLensHandler)
import Unison.LSP.Commands (executeCommandHandler, supportedCommands)
import Unison.LSP.Completion (completionHandler, completionItemResolveHandler)
import Unison.LSP.Configuration qualified as Config
import Unison.LSP.FileAnalysis qualified as Analysis
import Unison.LSP.FoldingRange (foldingRangeRequest)
import Unison.LSP.HandlerUtils qualified as Handlers
import Unison.LSP.Hover (hoverHandler)
import Unison.LSP.NotificationHandlers qualified as Notifications
import Unison.LSP.Orphans ()
import Unison.LSP.Types
import Unison.LSP.UCMWorker (ucmWorker)
import Unison.LSP.VFS qualified as VFS
import Unison.Parser.Ann
import Unison.Prelude
import Unison.PrettyPrintEnvDecl qualified as PPED
import Unison.Server.NameSearch.FromNames qualified as NameSearch
import Unison.Symbol
import UnliftIO
import UnliftIO.Foreign (Errno (..), eADDRINUSE)

getLspPort :: IO String
getLspPort = fromMaybe "5757" <$> lookupEnv "UNISON_LSP_PORT"

-- | Spawn an LSP server on the configured port.
spawnLsp :: Codebase IO Symbol Ann -> Runtime Symbol -> STM (Branch IO) -> STM (Path.Absolute) -> IO ()
spawnLsp codebase runtime latestBranch latestPath =
  ifEnabled . TCP.withSocketsDo $ do
    lspPort <- getLspPort
    UnliftIO.handleIO (handleFailure lspPort) $ do
      TCP.serve (TCP.Host "127.0.0.1") lspPort $ \(sock, _sockaddr) -> do
        Ki.scoped \scope -> do
          -- If the socket is closed, reading/writing will throw an exception,
          -- but since the socket is closed, this connection will be shutting down
          -- immediately anyways, so we just ignore it.
          let clientInput = handleAny (\_ -> pure "") do
                -- The server will be in the process of shutting down if the socket is closed,
                -- so just return empty input in the meantime.
                fromMaybe "" <$> TCP.recv sock defaultChunkSize
          let clientOutput output = handleAny (\_ -> pure ()) do
                TCP.sendLazy sock output

          -- currently we have an independent VFS for each LSP client since each client might have
          -- different un-saved state for the same file.
          initVFS $ \vfs -> do
            vfsVar <- newMVar vfs
            void $ runServerWith lspServerLogger lspClientLogger clientInput clientOutput (serverDefinition vfsVar codebase runtime scope latestBranch latestPath)
  where
    handleFailure :: String -> IOException -> IO ()
    handleFailure lspPort ioerr =
      case Errno <$> ioe_errno ioerr of
        Just errNo
          | errNo == eADDRINUSE -> do
              putStrLn $ "Note: Port " <> lspPort <> " is already bound by another process or another UCM. The LSP server will not be started."
        _ -> do
          Debug.debugM Debug.LSP "LSP Exception" ioerr
          Debug.debugM Debug.LSP "LSP Errno" (ioe_errno ioerr)
          putStrLn "LSP server failed to start."
    -- Where to send logs that occur before a client connects
    lspServerLogger = Colog.filterBySeverity Colog.Error Colog.getSeverity $ Colog.cmap (fmap tShow) (LogAction print)
    -- Where to send logs that occur after a client connects
    lspClientLogger = Colog.cmap (fmap tShow) LSP.defaultClientLogger
    ifEnabled :: IO () -> IO ()
    ifEnabled runServer = do
      -- Default LSP to disabled on Windows unless explicitly enabled
      lookupEnv "UNISON_LSP_ENABLED" >>= \case
        Just (fmap toLower -> "false") -> pure ()
        Just (fmap toLower -> "true") -> runServer
        Just x -> hPutStrLn stderr $ "Invalid value for UNISON_LSP_ENABLED, expected 'true' or 'false' but found: " <> x
        Nothing -> when (not onWindows) runServer

serverDefinition ::
  MVar VFS ->
  Codebase IO Symbol Ann ->
  Runtime Symbol ->
  Ki.Scope ->
  STM (Branch IO) ->
  STM (Path.Absolute) ->
  ServerDefinition Config
serverDefinition vfsVar codebase runtime scope latestBranch latestPath =
  ServerDefinition
    { defaultConfig = defaultLSPConfig,
      onConfigurationChange = Config.updateConfig,
      doInitialize = lspDoInitialize vfsVar codebase runtime scope latestBranch latestPath,
      staticHandlers = lspStaticHandlers,
      interpretHandler = lspInterpretHandler,
      options = lspOptions
    }

-- | Initialize any context needed by the LSP server
lspDoInitialize ::
  MVar VFS ->
  Codebase IO Symbol Ann ->
  Runtime Symbol ->
  Ki.Scope ->
  STM (Branch IO) ->
  STM (Path.Absolute) ->
  LanguageContextEnv Config ->
  Message 'Initialize ->
  IO (Either ResponseError Env)
lspDoInitialize vfsVar codebase runtime scope latestBranch latestPath lspContext _initMsg = do
  -- TODO: some of these should probably be MVars so that we correctly wait for names and
  -- things to be generated before serving requests.
  checkedFilesVar <- newTVarIO mempty
  dirtyFilesVar <- newTVarIO mempty
  ppedCacheVar <- newTVarIO PPED.empty
  parseNamesCacheVar <- newTVarIO mempty
  currentPathCacheVar <- newTVarIO Path.absoluteEmpty
  cancellationMapVar <- newTVarIO mempty
  completionsVar <- newTVarIO mempty
  nameSearchCacheVar <- newTVarIO $ NameSearch.makeNameSearch 0 mempty
  let env = Env {ppedCache = readTVarIO ppedCacheVar, parseNamesCache = readTVarIO parseNamesCacheVar, currentPathCache = readTVarIO currentPathCacheVar, nameSearchCache = readTVarIO nameSearchCacheVar, ..}
  let lspToIO = flip runReaderT lspContext . unLspT . flip runReaderT env . runLspM
  Ki.fork scope (lspToIO Analysis.fileAnalysisWorker)
  Ki.fork scope (lspToIO $ ucmWorker ppedCacheVar parseNamesCacheVar nameSearchCacheVar latestBranch latestPath)
  pure $ Right $ env

-- | LSP request handlers that don't register/unregister dynamically
lspStaticHandlers :: Handlers Lsp
lspStaticHandlers =
  Handlers
    { reqHandlers = lspRequestHandlers,
      notHandlers = lspNotificationHandlers
    }

-- | LSP request handlers
lspRequestHandlers :: SMethodMap (ClientMessageHandler Lsp 'Request)
lspRequestHandlers =
  mempty
    & SMM.insert STextDocumentHover (mkHandler hoverHandler)
    & SMM.insert STextDocumentCodeAction (mkHandler codeActionHandler)
    & SMM.insert STextDocumentCodeLens (mkHandler codeLensHandler)
    & SMM.insert SWorkspaceExecuteCommand (mkHandler executeCommandHandler)
    & SMM.insert STextDocumentFoldingRange (mkHandler foldingRangeRequest)
    & SMM.insert STextDocumentCompletion (mkHandler completionHandler)
    & SMM.insert SCompletionItemResolve (mkHandler completionItemResolveHandler)
  where
    defaultTimeout = 10_000 -- 10s
    mkHandler ::
      forall m.
      (Show (RequestMessage m), Show (ResponseMessage m), Show (ResponseResult m)) =>
      ( ( RequestMessage m ->
          (Either ResponseError (ResponseResult m) -> Lsp ()) ->
          Lsp ()
        ) ->
        ClientMessageHandler Lsp 'Request m
      )
    mkHandler h =
      h
        & Handlers.withCancellation (Just defaultTimeout)
        & Handlers.withDebugging
        & ClientMessageHandler

-- | LSP notification handlers
lspNotificationHandlers :: SMethodMap (ClientMessageHandler Lsp 'Notification)
lspNotificationHandlers =
  mempty
    & SMM.insert STextDocumentDidOpen (ClientMessageHandler VFS.lspOpenFile)
    & SMM.insert STextDocumentDidClose (ClientMessageHandler VFS.lspCloseFile)
    & SMM.insert STextDocumentDidChange (ClientMessageHandler VFS.lspChangeFile)
    & SMM.insert SInitialized (ClientMessageHandler Notifications.initializedHandler)
    & SMM.insert SCancelRequest (ClientMessageHandler $ Notifications.withDebugging cancelRequestHandler)
    & SMM.insert SWorkspaceDidChangeConfiguration (ClientMessageHandler Config.workspaceConfigurationChanged)

-- | A natural transformation into IO, required by the LSP lib.
lspInterpretHandler :: Env -> Lsp <~> IO
lspInterpretHandler env@(Env {lspContext}) =
  Iso toIO fromIO
  where
    toIO :: forall a. Lsp a -> IO a
    toIO (Lsp m) = flip runReaderT lspContext . unLspT . flip runReaderT env $ m
    fromIO m = liftIO m

lspOptions :: Options
lspOptions =
  defaultOptions
    { textDocumentSync = Just $ textDocSyncOptions,
      executeCommandCommands = Just supportedCommands
    }
  where
    textDocSyncOptions =
      TextDocumentSyncOptions
        { -- Clients should send file open/close messages so the VFS can handle them
          _openClose = Just True,
          -- Clients should send file change messages so the VFS can handle them
          _change = Just TdSyncIncremental,
          -- Clients should tell us when files are saved
          _willSave = Just False,
          -- If we implement a pre-save hook we can enable this.
          _willSaveWaitUntil = Just False,
          -- If we implement a save hook we can enable this.
          _save = Just (InL False)
        }
