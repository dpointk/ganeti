{-# LANGUAGE MultiParamTypeClasses, FunctionalDependencies,
  BangPatterns, TemplateHaskell #-}

{-| Implementation of the RPC client.

-}

{-

Copyright (C) 2012, 2013 Google Inc.

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
02110-1301, USA.

-}

module Ganeti.Rpc
  ( RpcCall
  , Rpc
  , RpcError(..)
  , ERpcError
  , explainRpcError
  , executeRpcCall
  , executeRpcCalls
  , logRpcErrors

  , rpcCallName
  , rpcCallTimeout
  , rpcCallData
  , rpcCallAcceptOffline

  , rpcResultFill

  , RpcCallInstanceInfo(..)
  , InstanceState(..)
  , InstanceInfo(..)
  , RpcResultInstanceInfo(..)

  , RpcCallAllInstancesInfo(..)
  , RpcResultAllInstancesInfo(..)

  , InstanceConsoleInfoParams(..)
  , InstanceConsoleInfo(..)
  , RpcCallInstanceConsoleInfo(..)
  , RpcResultInstanceConsoleInfo(..)

  , RpcCallInstanceList(..)
  , RpcResultInstanceList(..)

  , HvInfo(..)
  , StorageInfo(..)
  , RpcCallNodeInfo(..)
  , RpcResultNodeInfo(..)

  , RpcCallVersion(..)
  , RpcResultVersion(..)

  , RpcCallStorageList(..)
  , RpcResultStorageList(..)

  , RpcCallTestDelay(..)
  , RpcResultTestDelay(..)

  , RpcCallExportList(..)
  , RpcResultExportList(..)

  , RpcCallJobqueueUpdate(..)
  , RpcCallJobqueueRename(..)
  , RpcCallSetWatcherPause(..)
  , RpcCallSetDrainFlag(..)
  ) where

import Control.Arrow (second)
import qualified Codec.Compression.Zlib as Zlib
import qualified Data.ByteString.Lazy.Char8 as BL
import qualified Data.Map as Map
import Data.Maybe (fromMaybe)
import qualified Text.JSON as J
import Text.JSON.Pretty (pp_value)
import qualified Data.ByteString.Base64.Lazy as Base64
import System.Directory

import Network.Curl hiding (content)
import qualified Ganeti.Path as P

import Ganeti.BasicTypes
import qualified Ganeti.Constants as C
import Ganeti.JSON
import Ganeti.Logging
import Ganeti.Objects
import Ganeti.THH
import Ganeti.Types
import Ganeti.Curl.Multi
import Ganeti.Utils

-- * Base RPC functionality and types

-- | The curl options used for RPC.
curlOpts :: [CurlOption]
curlOpts = [ CurlFollowLocation False
           , CurlSSLVerifyHost 0
           , CurlSSLVerifyPeer True
           , CurlSSLCertType "PEM"
           , CurlSSLKeyType "PEM"
           , CurlConnectTimeout (fromIntegral C.rpcConnectTimeout)
           ]

-- | Data type for RPC error reporting.
data RpcError
  = CurlLayerError String
  | JsonDecodeError String
  | RpcResultError String
  | OfflineNodeError
  deriving (Show, Eq)

-- | Provide explanation to RPC errors.
explainRpcError :: RpcError -> String
explainRpcError (CurlLayerError code) =
    "Curl error:" ++ code
explainRpcError (JsonDecodeError msg) =
    "Error while decoding JSON from HTTP response: " ++ msg
explainRpcError (RpcResultError msg) =
    "Error reponse received from RPC server: " ++ msg
explainRpcError OfflineNodeError =
    "Node is marked offline"

type ERpcError = Either RpcError

-- | A generic class for RPC calls.
class (J.JSON a) => RpcCall a where
  -- | Give the (Python) name of the procedure.
  rpcCallName :: a -> String
  -- | Calculate the timeout value for the call execution.
  rpcCallTimeout :: a -> Int
  -- | Prepare arguments of the call to be send as POST.
  rpcCallData :: Node -> a -> String
  -- | Whether we accept offline nodes when making a call.
  rpcCallAcceptOffline :: a -> Bool

-- | Generic class that ensures matching RPC call with its respective
-- result.
class (RpcCall a, J.JSON b) => Rpc a b  | a -> b, b -> a where
  -- | Create a result based on the received HTTP response.
  rpcResultFill :: a -> J.JSValue -> ERpcError b

-- | Http Request definition.
data HttpClientRequest = HttpClientRequest
  { requestUrl  :: String       -- ^ The actual URL for the node endpoint
  , requestData :: String       -- ^ The arguments for the call
  , requestOpts :: [CurlOption] -- ^ The various curl options
  }

-- | Check if a string represented address is IPv6
isIpV6 :: String -> Bool
isIpV6 = (':' `elem`)

-- | Prepare url for the HTTP request.
prepareUrl :: (RpcCall a) => Node -> a -> String
prepareUrl node call =
  let node_ip = nodePrimaryIp node
      node_address = if isIpV6 node_ip
                     then "[" ++ node_ip ++ "]"
                     else node_ip
      port = C.defaultNodedPort
      path_prefix = "https://" ++ node_address ++ ":" ++ show port
  in path_prefix ++ "/" ++ rpcCallName call

-- | Create HTTP request for a given node provided it is online,
-- otherwise create empty response.
prepareHttpRequest :: (RpcCall a) => [CurlOption] -> Node -> a
                   -> ERpcError HttpClientRequest
prepareHttpRequest opts node call
  | rpcCallAcceptOffline call || not (nodeOffline node) =
      Right HttpClientRequest { requestUrl  = prepareUrl node call
                              , requestData = rpcCallData node call
                              , requestOpts = opts ++ curlOpts
                              }
  | otherwise = Left OfflineNodeError

-- | Parse an HTTP reply.
parseHttpReply :: (Rpc a b) =>
                  a -> ERpcError (CurlCode, String) -> ERpcError b
parseHttpReply _ (Left e) = Left e
parseHttpReply call (Right (CurlOK, body)) = parseHttpResponse call body
parseHttpReply _ (Right (code, err)) =
  Left . CurlLayerError $ "code: " ++ show code ++ ", explanation: " ++ err

-- | Parse a result based on the received HTTP response.
parseHttpResponse :: (Rpc a b) => a -> String -> ERpcError b
parseHttpResponse call res =
  case J.decode res of
    J.Error val -> Left $ JsonDecodeError val
    J.Ok (True, res'') -> rpcResultFill call res''
    J.Ok (False, jerr) -> case jerr of
       J.JSString msg -> Left $ RpcResultError (J.fromJSString msg)
       _ -> Left . JsonDecodeError $ show (pp_value jerr)

-- | Scan the list of results produced by executeRpcCall and log all the RPC
-- errors.
logRpcErrors :: [(a, ERpcError b)] -> IO ()
logRpcErrors allElems =
  let logOneRpcErr (_, Right _) = return ()
      logOneRpcErr (_, Left err) =
        logError $ "Error in the RPC HTTP reply: " ++ show err
  in mapM_ logOneRpcErr allElems

-- | Get options for RPC call
getOptionsForCall :: (Rpc a b) => FilePath -> FilePath -> a -> [CurlOption]
getOptionsForCall cert_path client_cert_path call =
  [ CurlTimeout (fromIntegral $ rpcCallTimeout call)
  , CurlSSLCert client_cert_path
  , CurlSSLKey client_cert_path
  , CurlCAInfo cert_path
  ]

-- | Execute multiple RPC calls in parallel
executeRpcCalls :: (Rpc a b) => [(Node, a)] -> IO [(Node, ERpcError b)]
executeRpcCalls nodeCalls = do
  cert_file <- P.nodedCertFile
  client_cert_file_name <- P.nodedClientCertFile
  client_file_exists <- doesFileExist client_cert_file_name
  -- FIXME: This is needed to ensure upgradability to 2.11
  -- Remove in 2.12.
  let client_cert_file = if client_file_exists
                         then client_cert_file_name
                         else cert_file
      (nodes, calls) = unzip nodeCalls
      opts = map (getOptionsForCall cert_file client_cert_file) calls
      opts_urls = zipWith3 (\n c o ->
                         case prepareHttpRequest o n c of
                           Left v -> Left v
                           Right request ->
                             Right (CurlPostFields [requestData request]:
                                    requestOpts request,
                                    requestUrl request)
                    ) nodes calls opts
  -- split the opts_urls list; we don't want to pass the
  -- failed-already nodes to Curl
  let (lefts, rights, trail) = splitEithers opts_urls
  results <- execMultiCall rights
  results' <- case recombineEithers lefts results trail of
                Bad msg -> error msg
                Ok r -> return r
  -- now parse the replies
  let results'' = zipWith parseHttpReply calls results'
      pairedList = zip nodes results''
  logRpcErrors pairedList
  return pairedList

-- | Execute an RPC call for many nodes in parallel.
executeRpcCall :: (Rpc a b) => [Node] -> a -> IO [(Node, ERpcError b)]
executeRpcCall nodes call = executeRpcCalls . zip nodes $ repeat call

-- | Helper function that is used to read dictionaries of values.
sanitizeDictResults :: [(String, J.Result a)] -> ERpcError [(String, a)]
sanitizeDictResults =
  foldr sanitize1 (Right [])
  where
    sanitize1 _ (Left e) = Left e
    sanitize1 (_, J.Error e) _ = Left $ JsonDecodeError e
    sanitize1 (name, J.Ok v) (Right res) = Right $ (name, v) : res

-- | Helper function to tranform JSON Result to Either RpcError b.
-- Note: For now we really only use it for b s.t. Rpc c b for some c
fromJResultToRes :: J.Result a -> (a -> b) -> ERpcError b
fromJResultToRes (J.Error v) _ = Left $ JsonDecodeError v
fromJResultToRes (J.Ok v) f = Right $ f v

-- | Helper function transforming JSValue to Rpc result type.
fromJSValueToRes :: (J.JSON a) => J.JSValue -> (a -> b) -> ERpcError b
fromJSValueToRes val = fromJResultToRes (J.readJSON val)

-- * RPC calls and results

-- ** Instance info

-- | Returns information about a single instance
$(buildObject "RpcCallInstanceInfo" "rpcCallInstInfo"
  [ simpleField "instance" [t| String |]
  , simpleField "hname" [t| Hypervisor |]
  ])

$(declareILADT "InstanceState"
  [ ("InstanceStateRunning", 0)
  , ("InstanceStateShutdown", 1)
  ])

$(makeJSONInstance ''InstanceState)

instance PyValue InstanceState where
  showValue = show . instanceStateToRaw

$(buildObject "InstanceInfo" "instInfo"
  [ simpleField "memory" [t| Int|]
  , simpleField "state"  [t| InstanceState |]
  , simpleField "vcpus"  [t| Int |]
  , simpleField "time"   [t| Int |]
  ])

-- This is optional here because the result may be empty if instance is
-- not on a node - and this is not considered an error.
$(buildObject "RpcResultInstanceInfo" "rpcResInstInfo"
  [ optionalField $ simpleField "inst_info" [t| InstanceInfo |]])

instance RpcCall RpcCallInstanceInfo where
  rpcCallName _          = "instance_info"
  rpcCallTimeout _       = rpcTimeoutToRaw Urgent
  rpcCallAcceptOffline _ = False
  rpcCallData _ call     = J.encode
    ( rpcCallInstInfoInstance call
    , rpcCallInstInfoHname call
    )

instance Rpc RpcCallInstanceInfo RpcResultInstanceInfo where
  rpcResultFill _ res =
    case res of
      J.JSObject res' ->
        case J.fromJSObject res' of
          [] -> Right $ RpcResultInstanceInfo Nothing
          _ -> fromJSValueToRes res (RpcResultInstanceInfo . Just)
      _ -> Left $ JsonDecodeError
           ("Expected JSObject, got " ++ show (pp_value res))

-- ** AllInstancesInfo

-- | Returns information about all running instances on the given nodes
$(buildObject "RpcCallAllInstancesInfo" "rpcCallAllInstInfo"
  [ simpleField "hypervisors" [t| [(Hypervisor, HvParams)] |] ])

$(buildObject "RpcResultAllInstancesInfo" "rpcResAllInstInfo"
  [ simpleField "instances" [t| [(String, InstanceInfo)] |] ])

instance RpcCall RpcCallAllInstancesInfo where
  rpcCallName _          = "all_instances_info"
  rpcCallTimeout _       = rpcTimeoutToRaw Urgent
  rpcCallAcceptOffline _ = False
  rpcCallData _ call     = J.encode (
    map fst $ rpcCallAllInstInfoHypervisors call,
    GenericContainer . Map.fromList $ rpcCallAllInstInfoHypervisors call)

instance Rpc RpcCallAllInstancesInfo RpcResultAllInstancesInfo where
  -- FIXME: Is there a simpler way to do it?
  rpcResultFill _ res =
    case res of
      J.JSObject res' ->
        let res'' = map (second J.readJSON) (J.fromJSObject res')
                        :: [(String, J.Result InstanceInfo)] in
        case sanitizeDictResults res'' of
          Left err -> Left err
          Right insts -> Right $ RpcResultAllInstancesInfo insts
      _ -> Left $ JsonDecodeError
           ("Expected JSObject, got " ++ show (pp_value res))

-- ** InstanceConsoleInfo

-- | Returns information about how to access instances on the given node
$(buildObject "InstanceConsoleInfoParams" "instConsInfoParams"
  [ simpleField "instance"    [t| Instance |]
  , simpleField "node"        [t| Node |]
  , simpleField "group"       [t| NodeGroup |]
  , simpleField "hvParams"    [t| HvParams |]
  , simpleField "beParams"    [t| FilledBeParams |]
  ])

$(buildObject "RpcCallInstanceConsoleInfo" "rpcCallInstConsInfo"
  [ simpleField "instanceInfo" [t| [(String, InstanceConsoleInfoParams)] |] ])

$(buildObject "InstanceConsoleInfo" "instConsInfo"
  [ simpleField "instance"    [t| String |]
  , simpleField "kind"        [t| String |]
  , optionalField $
    simpleField "message"     [t| String |]
  , optionalField $
    simpleField "host"        [t| String |]
  , optionalField $
    simpleField "port"        [t| Int |]
  , optionalField $
    simpleField "user"        [t| String |]
  , optionalField $
    simpleField "command"     [t| [String] |]
  , optionalField $
    simpleField "display"     [t| String |]
  ])

$(buildObject "RpcResultInstanceConsoleInfo" "rpcResInstConsInfo"
  [ simpleField "instancesInfo" [t| [(String, InstanceConsoleInfo)] |] ])

instance RpcCall RpcCallInstanceConsoleInfo where
  rpcCallName _          = "instance_console_info"
  rpcCallTimeout _       = rpcTimeoutToRaw Urgent
  rpcCallAcceptOffline _ = False
  rpcCallData _ call     = J.encode .
    GenericContainer $ Map.fromList (rpcCallInstConsInfoInstanceInfo call)

instance Rpc RpcCallInstanceConsoleInfo RpcResultInstanceConsoleInfo where
  rpcResultFill _ res =
    case res of
      J.JSObject res' ->
        let res'' = map (second J.readJSON) (J.fromJSObject res')
                        :: [(String, J.Result InstanceConsoleInfo)] in
        case sanitizeDictResults res'' of
          Left err -> Left err
          Right instInfos -> Right $ RpcResultInstanceConsoleInfo instInfos
      _ -> Left $ JsonDecodeError
           ("Expected JSObject, got " ++ show (pp_value res))

-- ** InstanceList

-- | Returns the list of running instances on the given nodes
$(buildObject "RpcCallInstanceList" "rpcCallInstList"
  [ simpleField "hypervisors" [t| [Hypervisor] |] ])

$(buildObject "RpcResultInstanceList" "rpcResInstList"
  [ simpleField "instances" [t| [String] |] ])

instance RpcCall RpcCallInstanceList where
  rpcCallName _          = "instance_list"
  rpcCallTimeout _       = rpcTimeoutToRaw Urgent
  rpcCallAcceptOffline _ = False
  rpcCallData _ call     = J.encode [rpcCallInstListHypervisors call]

instance Rpc RpcCallInstanceList RpcResultInstanceList where
  rpcResultFill _ res = fromJSValueToRes res RpcResultInstanceList

-- ** NodeInfo

-- | Returns node information
$(buildObject "RpcCallNodeInfo" "rpcCallNodeInfo"
  [ simpleField "storage_units" [t| Map.Map String [StorageUnit] |]
  , simpleField "hypervisors" [t| [ (Hypervisor, HvParams) ] |]
  ])

$(buildObject "StorageInfo" "storageInfo"
  [ simpleField "name" [t| String |]
  , simpleField "type" [t| String |]
  , optionalField $ simpleField "storage_free" [t| Int |]
  , optionalField $ simpleField "storage_size" [t| Int |]
  ])

-- | We only provide common fields as described in hv_base.py.
$(buildObject "HvInfo" "hvInfo"
  [ simpleField "memory_total" [t| Int |]
  , simpleField "memory_free" [t| Int |]
  , simpleField "memory_dom0" [t| Int |]
  , simpleField "cpu_total" [t| Int |]
  , simpleField "cpu_nodes" [t| Int |]
  , simpleField "cpu_sockets" [t| Int |]
  , simpleField "cpu_dom0" [t| Int |]
  ])

$(buildObject "RpcResultNodeInfo" "rpcResNodeInfo"
  [ simpleField "boot_id" [t| String |]
  , simpleField "storage_info" [t| [StorageInfo] |]
  , simpleField "hv_info" [t| [HvInfo] |]
  ])

instance RpcCall RpcCallNodeInfo where
  rpcCallName _          = "node_info"
  rpcCallTimeout _       = rpcTimeoutToRaw Urgent
  rpcCallAcceptOffline _ = False
  rpcCallData n call     = J.encode
    ( fromMaybe (error $ "Programmer error: missing parameter for node named "
                         ++ nodeName n)
          $ Map.lookup (nodeUuid n) (rpcCallNodeInfoStorageUnits call)
    , rpcCallNodeInfoHypervisors call
    )

instance Rpc RpcCallNodeInfo RpcResultNodeInfo where
  rpcResultFill _ res =
    fromJSValueToRes res (\(b, vg, hv) -> RpcResultNodeInfo b vg hv)

-- ** Version

-- | Query node version.
$(buildObject "RpcCallVersion" "rpcCallVersion" [])

-- | Query node reply.
$(buildObject "RpcResultVersion" "rpcResultVersion"
  [ simpleField "version" [t| Int |]
  ])

instance RpcCall RpcCallVersion where
  rpcCallName _          = "version"
  rpcCallTimeout _       = rpcTimeoutToRaw Urgent
  rpcCallAcceptOffline _ = True
  rpcCallData _          = J.encode

instance Rpc RpcCallVersion RpcResultVersion where
  rpcResultFill _ res = fromJSValueToRes res RpcResultVersion

-- ** StorageList

$(buildObject "RpcCallStorageList" "rpcCallStorageList"
  [ simpleField "su_name" [t| StorageType |]
  , simpleField "su_args" [t| [String] |]
  , simpleField "name"    [t| String |]
  , simpleField "fields"  [t| [StorageField] |]
  ])

-- FIXME: The resulting JSValues should have types appropriate for their
-- StorageField value: Used -> Bool, Name -> String etc
$(buildObject "RpcResultStorageList" "rpcResStorageList"
  [ simpleField "storage" [t| [[(StorageField, J.JSValue)]] |] ])

instance RpcCall RpcCallStorageList where
  rpcCallName _          = "storage_list"
  rpcCallTimeout _       = rpcTimeoutToRaw Normal
  rpcCallAcceptOffline _ = False
  rpcCallData _ call     = J.encode
    ( rpcCallStorageListSuName call
    , rpcCallStorageListSuArgs call
    , rpcCallStorageListName call
    , rpcCallStorageListFields call
    )

instance Rpc RpcCallStorageList RpcResultStorageList where
  rpcResultFill call res =
    let sfields = rpcCallStorageListFields call in
    fromJSValueToRes res (RpcResultStorageList . map (zip sfields))

-- ** TestDelay

-- | Call definition for test delay.
$(buildObject "RpcCallTestDelay" "rpcCallTestDelay"
  [ simpleField "duration" [t| Double |]
  ])

-- | Result definition for test delay.
data RpcResultTestDelay = RpcResultTestDelay
                          deriving Show

-- | Custom JSON instance for null result.
instance J.JSON RpcResultTestDelay where
  showJSON _        = J.JSNull
  readJSON J.JSNull = return RpcResultTestDelay
  readJSON _        = fail "Unable to read RpcResultTestDelay"

instance RpcCall RpcCallTestDelay where
  rpcCallName _          = "test_delay"
  rpcCallTimeout         = ceiling . (+ 5) . rpcCallTestDelayDuration
  rpcCallAcceptOffline _ = False
  rpcCallData _ call     = J.encode [rpcCallTestDelayDuration call]

instance Rpc RpcCallTestDelay RpcResultTestDelay where
  rpcResultFill _ res = fromJSValueToRes res id

-- ** ExportList

-- | Call definition for export list.

$(buildObject "RpcCallExportList" "rpcCallExportList" [])

-- | Result definition for export list.
$(buildObject "RpcResultExportList" "rpcResExportList"
  [ simpleField "exports" [t| [String] |]
  ])

instance RpcCall RpcCallExportList where
  rpcCallName _          = "export_list"
  rpcCallTimeout _       = rpcTimeoutToRaw Fast
  rpcCallAcceptOffline _ = False
  rpcCallData _          = J.encode

instance Rpc RpcCallExportList RpcResultExportList where
  rpcResultFill _ res = fromJSValueToRes res RpcResultExportList

-- ** Job Queue Replication
  
-- | Update a job queue file
  
$(buildObject "RpcCallJobqueueUpdate" "rpcCallJobqueueUpdate"
  [ simpleField "file_name" [t| String |]
  , simpleField "content" [t| String |]
  ])

$(buildObject "RpcResultJobQueueUpdate" "rpcResultJobQueueUpdate" [])

instance RpcCall RpcCallJobqueueUpdate where
  rpcCallName _          = "jobqueue_update"
  rpcCallTimeout _       = rpcTimeoutToRaw Fast
  rpcCallAcceptOffline _ = False
  rpcCallData _ call     = J.encode
    ( rpcCallJobqueueUpdateFileName call
    , ( C.rpcEncodingZlibBase64
      , BL.unpack . Base64.encode . Zlib.compress . BL.pack
          $ rpcCallJobqueueUpdateContent call
      )
    )

instance Rpc RpcCallJobqueueUpdate RpcResultJobQueueUpdate where
  rpcResultFill _ res =
    case res of
      J.JSNull ->  Right RpcResultJobQueueUpdate
      _ -> Left $ JsonDecodeError
           ("Expected JSNull, got " ++ show (pp_value res))

-- | Rename a file in the job queue

$(buildObject "RpcCallJobqueueRename" "rpcCallJobqueueRename"
  [ simpleField "rename" [t| [(String, String)] |]
  ])

$(buildObject "RpcResultJobqueueRename" "rpcResultJobqueueRename" [])

instance RpcCall RpcCallJobqueueRename where
  rpcCallName _          = "jobqueue_rename"
  rpcCallTimeout _       = rpcTimeoutToRaw Fast
  rpcCallAcceptOffline _ = False
  rpcCallData _ call     = J.encode [ rpcCallJobqueueRenameRename call ]

instance Rpc RpcCallJobqueueRename RpcResultJobqueueRename where
  rpcResultFill _ res =
    case res of
      J.JSNull -> Right RpcResultJobqueueRename
      _ -> Left $ JsonDecodeError
           ("Expected JSNull, got " ++ show (pp_value res))

-- ** Watcher Status Update
      
-- | Set the watcher status
      
$(buildObject "RpcCallSetWatcherPause" "rpcCallSetWatcherPause"
  [ simpleField "time" [t| Maybe Double |]
  ])

instance RpcCall RpcCallSetWatcherPause where
  rpcCallName _          = "set_watcher_pause"
  rpcCallTimeout _       = rpcTimeoutToRaw Fast
  rpcCallAcceptOffline _ = False
  rpcCallData _ call     = J.encode
    [ maybe J.JSNull J.showJSON $ rpcCallSetWatcherPauseTime call ]

$(buildObject "RpcResultSetWatcherPause" "rpcResultSetWatcherPause" [])

instance Rpc RpcCallSetWatcherPause RpcResultSetWatcherPause where
  rpcResultFill _ res =
    case res of
      J.JSNull ->  Right RpcResultSetWatcherPause
      _ -> Left $ JsonDecodeError
           ("Expected JSNull, got " ++ show (pp_value res))

-- ** Queue drain status
      
-- | Set the queu drain flag
      
$(buildObject "RpcCallSetDrainFlag" "rpcCallSetDrainFlag"
  [ simpleField "value" [t| Bool |]
  ])

instance RpcCall RpcCallSetDrainFlag where
  rpcCallName _          = "jobqueue_set_drain_flag"
  rpcCallTimeout _       = rpcTimeoutToRaw Fast
  rpcCallAcceptOffline _ = False
  rpcCallData _ call     = J.encode [ rpcCallSetDrainFlagValue call ]

$(buildObject "RpcResultSetDrainFlag" "rpcResultSetDrainFalg" [])

instance Rpc RpcCallSetDrainFlag RpcResultSetDrainFlag where
  rpcResultFill _ res =
    case res of
      J.JSNull ->  Right RpcResultSetDrainFlag
      _ -> Left $ JsonDecodeError
           ("Expected JSNull, got " ++ show (pp_value res))

