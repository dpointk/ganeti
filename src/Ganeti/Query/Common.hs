{-| Implementation of the Ganeti Query2 common objects.

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

module Ganeti.Query.Common
  ( NoDataRuntime(..)
  , rsNoData
  , rsUnavail
  , rsNormal
  , rsMaybeNoData
  , rsMaybeUnavail
  , rsErrorNoData
  , rsUnknown
  , missingRuntime
  , rpcErrorToStatus
  , timeStampFields
  , uuidFields
  , serialFields
  , tagsFields
  , dictFieldGetter
  , buildNdParamField
  , buildBeParamField
  , buildHvParamField
  , getDefaultHypervisorSpec
  , getHvParamsFromCluster
  ) where

import qualified Data.Map as Map
import Data.Maybe (fromMaybe)
import Text.JSON (JSON, showJSON)

import Ganeti.BasicTypes
import qualified Ganeti.Constants as C
import Ganeti.Config
import Ganeti.Errors
import Ganeti.JSON
import Ganeti.Objects
import Ganeti.Rpc
import Ganeti.Query.Language
import Ganeti.Query.Types
import Ganeti.Types

-- | The runtime used by queries which retrieve no live data.
data NoDataRuntime = NoDataRuntime

-- * Generic functions

-- | Conversion from 'VType' to 'FieldType'.
vTypeToQFT :: VType -> FieldType
vTypeToQFT VTypeString      = QFTOther
vTypeToQFT VTypeMaybeString = QFTOther
vTypeToQFT VTypeBool        = QFTBool
vTypeToQFT VTypeSize        = QFTUnit
vTypeToQFT VTypeInt         = QFTNumber

-- * Result helpers

-- | Helper for a result with no data.
rsNoData :: ResultEntry
rsNoData = ResultEntry RSNoData Nothing

-- | Helper for result for an entity which supports no such field.
rsUnavail :: ResultEntry
rsUnavail = ResultEntry RSUnavail Nothing

-- | Helper to declare a normal result.
rsNormal :: (JSON a) => a -> ResultEntry
rsNormal a = ResultEntry RSNormal $ Just (showJSON a)

-- | Helper to declare a result from a 'Maybe' (the item might be
-- missing, in which case we return no data). Note that there's some
-- ambiguity here: in some cases, we mean 'RSNoData', but in other
-- 'RSUnavail'; this is easy to solve in simple cases, but not in
-- nested dicts. If you want to return 'RSUnavail' in case of 'Nothing'
-- use the function 'rsMaybeUnavail'.
rsMaybeNoData :: (JSON a) => Maybe a -> ResultEntry
rsMaybeNoData = maybe rsNoData rsNormal

-- | Helper to declare a result from a 'ErrorResult' (an error happened
-- while retrieving the data from a config, or there was no data).
-- This function should be used if an error signals there was no data.
rsErrorNoData :: (JSON a) => ErrorResult a -> ResultEntry
rsErrorNoData res = case res of
  Ok  x -> rsNormal x
  Bad _ -> rsNoData

-- | Helper to declare a result from a 'Maybe'. This version returns
-- a 'RSUnavail' in case of 'Nothing'. It should be used for optional
-- fields that are not set. For cases where 'Nothing' means that there
-- was an error, consider using 'rsMaybe' instead.
rsMaybeUnavail :: (JSON a) => Maybe a -> ResultEntry
rsMaybeUnavail = maybe rsUnavail rsNormal

-- | Helper for unknown field result.
rsUnknown :: ResultEntry
rsUnknown = ResultEntry RSUnknown Nothing

-- | Helper for a missing runtime parameter.
missingRuntime :: FieldGetter a b
missingRuntime = FieldRuntime (\_ _ -> ResultEntry RSNoData Nothing)

-- * Error conversion

-- | Convert RpcError to ResultStatus
rpcErrorToStatus :: RpcError -> ResultStatus
rpcErrorToStatus OfflineNodeError = RSOffline
rpcErrorToStatus _ = RSNoData

-- * Common fields

-- | The list of timestamp fields.
timeStampFields :: (TimeStampObject a) => FieldList a b
timeStampFields =
  [ (FieldDefinition "ctime" "CTime" QFTTimestamp "Creation timestamp",
     FieldSimple (rsNormal . cTimeOf), QffNormal)
  , (FieldDefinition "mtime" "MTime" QFTTimestamp "Modification timestamp",
     FieldSimple (rsNormal . mTimeOf), QffNormal)
  ]

-- | The list of UUID fields.
uuidFields :: (UuidObject a) => String -> FieldList a b
uuidFields name =
  [ (FieldDefinition "uuid" "UUID" QFTText  (name ++ " UUID"),
     FieldSimple (rsNormal . uuidOf), QffNormal) ]

-- | The list of serial number fields.
serialFields :: (SerialNoObject a) => String -> FieldList a b
serialFields name =
  [ (FieldDefinition "serial_no" "SerialNo" QFTNumber
     (name ++ " object serial number, incremented on each modification"),
     FieldSimple (rsNormal . serialOf), QffNormal) ]

-- | The list of tag fields.
tagsFields :: (TagsObject a) => FieldList a b
tagsFields =
  [ (FieldDefinition "tags" "Tags" QFTOther "Tags",
     FieldSimple (rsNormal . tagsOf), QffNormal) ]

-- * Generic parameter functions

-- | Returns a field from a (possibly missing) 'DictObject'. This is
-- used by parameter dictionaries, usually. Note that we have two
-- levels of maybe: the top level dict might be missing, or one key in
-- the dictionary might be.
dictFieldGetter :: (DictObject a) => String -> Maybe a -> ResultEntry
dictFieldGetter k = maybe rsNoData (rsMaybeNoData . lookup k . toDict)

-- | Ndparams optimised lookup map.
ndParamTypes :: Map.Map String FieldType
ndParamTypes = Map.map vTypeToQFT C.ndsParameterTypes

-- | Ndparams title map.
ndParamTitles :: Map.Map String FieldTitle
ndParamTitles = C.ndsParameterTitles

-- | Ndparam getter builder: given a field, it returns a FieldConfig
-- getter, that is a function that takes the config and the object and
-- returns the Ndparam field specified when the getter was built.
ndParamGetter :: (NdParamObject a) =>
                 String -- ^ The field we're building the getter for
              -> ConfigData -> a -> ResultEntry
ndParamGetter field config =
  dictFieldGetter field . getNdParamsOf config

-- | Builds the ndparam fields for an object.
buildNdParamField :: (NdParamObject a) => String -> FieldData a b
buildNdParamField =
  buildParamField "ndp" "node" ndParamTitles ndParamTypes ndParamGetter

-- | Beparams optimised lookup map.
beParamTypes :: Map.Map String FieldType
beParamTypes = Map.map vTypeToQFT C.besParameterTypes

-- | Builds the beparam fields for an object.
buildBeParamField :: (String -> ConfigData -> a -> ResultEntry)
                  -> String
                  -> FieldData a b
buildBeParamField =
  buildParamField "be" "backend" C.besParameterTitles beParamTypes

-- | Hvparams optimised lookup map.
hvParamTypes :: Map.Map String FieldType
hvParamTypes = Map.map vTypeToQFT C.hvsParameterTypes

-- | Builds the beparam fields for an object.
buildHvParamField :: (String -> ConfigData -> a -> ResultEntry)
                  -> String
                  -> FieldData a b
buildHvParamField =
  buildParamField "hv" "hypervisor" C.hvsParameterTitles hvParamTypes

-- | Builds a param field for a certain getter class
buildParamField :: String -- ^ Prefix
                -> String -- ^ Parameter group name
                -> Map.Map String String -- ^ Parameter title map
                -> Map.Map String FieldType -- ^ Parameter type map
                -> (String -> ConfigData -> a -> ResultEntry)
                -> String -- ^ The parameter name
                -> FieldData a b
buildParamField prefix paramGroupName titleMap typeMap getter field =
  let full_name = prefix ++ "/" ++ field
      title = fromMaybe full_name $ field `Map.lookup` titleMap
      qft = fromMaybe QFTOther $ field `Map.lookup` typeMap
      desc = "The \"" ++ field ++ "\" " ++ paramGroupName ++ " parameter"
  in ( FieldDefinition full_name title qft desc
     , FieldConfig (getter field), QffNormal
     )

-- | Looks up the default hypervisor and its hvparams
getDefaultHypervisorSpec :: ConfigData -> (Hypervisor, HvParams)
getDefaultHypervisorSpec cfg = (hv, getHvParamsFromCluster cfg hv)
  where hv = getDefaultHypervisor cfg

-- | Looks up the cluster's hvparams of the given hypervisor
getHvParamsFromCluster :: ConfigData -> Hypervisor -> HvParams
getHvParamsFromCluster cfg hv =
  fromMaybe (GenericContainer Map.empty) .
    Map.lookup (hypervisorToRaw hv) .
      fromContainer . clusterHvparams $ configCluster cfg
