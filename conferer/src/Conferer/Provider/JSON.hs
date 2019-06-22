module Conferer.Provider.JSON where

import           Data.Aeson
import qualified Data.HashMap.Strict as HashMap
import           Data.Text (Text)
import qualified Data.Text as Text
import           Data.Vector
import           Text.Read (readMaybe)
import qualified Data.ByteString.Lazy as B
import qualified Data.Text.Encoding as T
import           System.Directory (doesFileExist)

import Conferer.Provider.Files
import Conferer.Provider.Null
import Conferer.Types


boolToString :: Bool -> Text
boolToString True = "true"
boolToString False = "false"

valueToText :: Value -> Maybe Text
valueToText (String t) = Just t
valueToText (Object _o) = Nothing
valueToText (Array _as) = Nothing
valueToText (Number n) = Just $ T.decodeUtf8 $ B.toStrict $ encode $ Number n
valueToText (Bool b) = Just $ boolToString b
valueToText (Null) = Nothing

traverseJSON :: Key -> Value -> Maybe Text
traverseJSON (Path []) v = valueToText v
traverseJSON (Path (k:ks)) (Object o) =
  HashMap.lookup k o >>= traverseJSON (Path ks)
traverseJSON (Path ([k])) (Array vs) = do
  n :: Int <- readMaybe $ Text.unpack k
  value <- vs !? n
  valueToText value
traverseJSON (Path _) _ = Nothing

resultToMaybe :: Result a -> Maybe a
resultToMaybe (Error _) = Nothing
resultToMaybe (Success a) = Just a


mkJsonProvider :: ProviderCreator
mkJsonProvider config = do
  fileToParse <- getFilePathFromEnv config "json"
  fileExists <- doesFileExist fileToParse
  if fileExists
    then do
      value <- decodeFileStrict' fileToParse
      case value of
        Nothing ->
          error $ "Failed to decode file '" <> fileToParse <> "'"
        Just v -> do
          mkJsonProvider' v config
    else do
      mkNullProvider config

mkJsonProvider' :: Value -> ProviderCreator
mkJsonProvider' v = \_config ->
  return $ Provider
  { getKeyInProvider = \k -> do
      return $ traverseJSON k v
  }