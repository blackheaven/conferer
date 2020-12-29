-- |
-- Copyright: (c) 2019 Lucas David Traverso
-- License: MPL-2.0
-- Maintainer: Lucas David Traverso <lucas6246@gmail.com>
-- Stability: unstable
-- Portability: portable
--
-- Internal module providing FromConfig functionality
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE AllowAmbiguousTypes #-}

module Conferer.FromConfig.Internal where

import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import Control.Exception
import Data.Typeable
import Text.Read (readMaybe)
import Data.Dynamic
import GHC.Generics
import Data.Function (on, (&))

import Conferer.Key
import Conferer.Config.Internal.Types
import Conferer.Config.Internal
import qualified Data.Char as Char
import Control.Monad (forM)
import Data.Maybe (fromMaybe, mapMaybe)
import qualified System.FilePath as FilePath
import Data.List (nub, foldl', sort)
import Data.String (IsString(..))

-- | The typeclass for defining the way to get values from a 'Config', hiding the
-- 'Text' based nature of the 'Conferer.Source.Source's and parse whatever value
-- as the types sees fit
--
-- Some of these instances are provided in different packages to avoid the heavy
-- dependencies.
--
-- It provides a reasonable default using 'Generic's so most of the time user need
-- not to implement this typeclass.
class FromConfig a where
  -- | This function uses a 'Config' and a scoping 'Key' to get a value.
  --
  -- Some conventions:
  --
  -- * When some 'Key' is missing this function should throw 'MissingRequiredKey'
  --
  -- * For any t it should hold that @fetchFromConfig k (config & addDefault k t) == t@
  -- meaning that a default on the same key with the right type should be used as a
  -- default and with no configuration that value should be returned
  --
  -- * Try desconstructing the value in as many keys as possible since is allows easier
  -- partial overriding.
  fetchFromConfig :: Key -> Config -> IO a
  default fetchFromConfig :: (Typeable a, Generic a, IntoDefaultsG (Rep a), FromConfigG (Rep a)) => Key -> Config -> IO a
  fetchFromConfig k c = do
    defaultValue <- fetchFromDefaults @a k c
    let config =
          case defaultValue of
            Just d -> c & addDefaults (intoDefaultsG k $ from d)
            Nothing -> c
    to <$> fetchFromConfigG k config

-- | Utility only typeclass to smooth the naming differences between default values for
-- external library settings
--
-- This typeclass is not used internally it's only here for convinience for users
class DefaultConfig a where
  configDef :: a

instance {-# OVERLAPPABLE #-} Typeable a => FromConfig a where
  fetchFromConfig key config = do
    fetchFromConfigWith (const Nothing) key config

instance FromConfig () where
  fetchFromConfig _key _config = return ()

instance FromConfig String where
  fetchFromConfig = fetchFromConfigWith (Just . Text.unpack)

instance {-# OVERLAPPABLE #-} (Typeable a, FromConfig a) =>
    FromConfig [a] where
  fetchFromConfig key config = do
    keysForItems <- getSubkeysForItems
    case keysForItems of
      Nothing -> do
        fetchRequiredFromDefaults @[a] key config
      Just subkeys -> do
        defaultsMay <- fetchFromDefaults @[a] key config
        let configWithDefaults :: Config =
              case defaultsMay of
                Just defaults ->
                  foldl' (\c (index, value) ->
                    c & addDefault (key /. "defaults" /. mkKey (show index)) value) config
                  $ zip [0 :: Integer ..] defaults
                Nothing -> config
        forM subkeys $ \k -> do
          fetchFromConfig @a (key /. k)
            (if isKeyPrefixOf (key /. "defaults") (key /. k)
              then
                configWithDefaults
              else
                configWithDefaults & addKeyMappings [(key /. k, key /. "prototype")])
    where
    getSubkeysForItems ::IO (Maybe [Key])
    getSubkeysForItems = do
      fetchFromConfig @(Maybe Text) (key /. "keys") config
        >>= \case
          Just rawKeys -> do
            return $
              Just $
              nub $
              filter (/= "") $
              mkKey .
              Text.unpack <$>
              Text.split (== ',') rawKeys
          Nothing -> do
            subelements <-
              sort
              . nub
              . filter (not . (`elem` ["prototype", "keys", "defaults"]))
              . mapMaybe (\k -> case rawKeyComponents <$> stripKeyPrefix key k of
                    Just (subkey:_) -> Just $ fromText subkey
                    _ -> Nothing)
              <$> listSubkeys key config
            return $ if null subelements then Nothing else Just subelements

instance FromConfig Int where
  fetchFromConfig = fetchFromConfigByRead

instance FromConfig Integer where
  fetchFromConfig k c = do
    fetchFromConfigByRead k c

instance FromConfig Float where
  fetchFromConfig = fetchFromConfigByRead

instance FromConfig BS.ByteString where
  fetchFromConfig = fetchFromConfigWith (Just . Text.encodeUtf8)

instance FromConfig LBS.ByteString where
  fetchFromConfig = fetchFromConfigWith (Just . LBS.fromStrict . Text.encodeUtf8)

instance forall a. (Typeable a, FromConfig a) => FromConfig (Maybe a) where
  fetchFromConfig key config = do
    let
      newConfig =
        case getKeyFromDefaults key config >>= fromDynamic @(Maybe a) of
        Just (Just defaultThing) -> do
          config & addDefault key defaultThing
        Just Nothing -> do
          config & removeDefault key
        _ -> do
          config
    (Just <$> fetchFromConfig @a key newConfig)
      `catch` (\(_e :: MissingRequiredKey) -> return Nothing)

instance FromConfig Text where
  fetchFromConfig = fetchFromConfigWith Just

instance FromConfig Bool where
  fetchFromConfig = fetchFromConfigWith parseBool

-- | A newtype wrapper for a 'FilePath' to allow implementing 'FromConfig'
-- with something better than just a 'String'
newtype File =
  File FilePath
  deriving (Show, Eq, Ord, Read)

instance IsString File where
  fromString s = File s

instance FromConfig File where
  fetchFromConfig key config = do
    filepath <- fetchFromConfig @(Maybe String) key config

    extension <- fetchFromConfig @(Maybe String) (key /. "extension") config
    dirname <- fetchFromConfig @(Maybe String) (key /. "dirname") config
    basename <- fetchFromConfig @(Maybe String) (key /. "basename") config
    filename <- fetchFromConfig @(Maybe String) (key /. "filename") config

    let
      constructedFilePath =
        applyIfPresent FilePath.replaceDirectory dirname
        $ applyIfPresent FilePath.replaceBaseName basename
        $ applyIfPresent FilePath.replaceExtension extension
        $ applyIfPresent FilePath.replaceFileName filename
        $ fromMaybe "" filepath
    if FilePath.isValid constructedFilePath
      then return $ File constructedFilePath
      else throwMissingRequiredKeys @String
        [ key
        , key /. "extension"
        , key /. "dirname"
        , key /. "basename"
        , key /. "filename"
        ]
    where
      applyIfPresent f maybeComponent =
        (\fp -> maybe fp (f fp) maybeComponent)

-- | Helper function to parse a 'Bool' from 'Text'
parseBool :: Text -> Maybe Bool
parseBool text =
  case Text.toLower text of
    "false" -> Just False
    "true" -> Just True
    _ -> Nothing

-- | Helper function to implement fetchFromConfig using the 'Read' instance
fetchFromConfigByRead :: (Typeable a, Read a) => Key -> Config -> IO a
fetchFromConfigByRead = fetchFromConfigWith (readMaybe . Text.unpack)

-- | Helper function to implement fetchFromConfig using the 'IsString' instance
fetchFromConfigByIsString :: (Typeable a, IsString a) => Key -> Config -> IO a
fetchFromConfigByIsString = fetchFromConfigWith (Just . fromString . Text.unpack)

-- | Helper function to implement fetchFromConfig using some parsing function
fetchFromConfigWith :: forall a. Typeable a => (Text -> Maybe a) -> Key -> Config -> IO a
fetchFromConfigWith parseValue key config = do
  getKey key config >>=
    \case
      MissingKey k -> do
        throwMissingRequiredKeys @a k

      FoundInSources k value ->
        case parseValue value of
          Just a -> do
            return a
          Nothing -> do
            throwConfigParsingError @a k value

      FoundInDefaults k dynamic ->
        case fromDynamic dynamic of
          Just a -> do
            return a
          Nothing -> do
            throwTypeMismatchWithDefault @a k dynamic


-- | Helper function does the plumbing of desconstructing a default into smaller
-- defaults, which is usefull for nested 'fetchFromConfig'.
addDefaultsAfterDeconstructingToDefaults
  :: forall a.
  Typeable a =>
  -- | Function to deconstruct the value
  (a -> [(Key, Dynamic)]) ->
  -- | Key where to look for the value
  Key ->
  -- | The config
  Config ->
  IO Config
addDefaultsAfterDeconstructingToDefaults destructureValue key config = do
  fetchFromDefaults @a key config
    >>= \case
    Just value -> do
      let newDefaults =
            ((\(k, d) -> (key /. k, d)) <$> destructureValue value)
      return $
        addDefaults newDefaults config
    Nothing -> do
      return config

-- | Exception to show that a value couldn't be parsed properly
data ConfigParsingError =
  ConfigParsingError Key Text TypeRep
  deriving (Typeable, Eq)

instance Exception ConfigParsingError
instance Show ConfigParsingError where
  show (ConfigParsingError key value aTypeRep) =
    concat
    [ "Couldn't parse value '"
    , Text.unpack value
    , "' from key '"
    , show key
    , "' as "
    , show aTypeRep
    ]

-- | Helper function to throw 'ConfigParsingError'
throwConfigParsingError :: forall a b. (Typeable a) => Key -> Text -> IO b
throwConfigParsingError key text =
  throwIO $ configParsingError @a  key text

-- | Helper function to create a 'ConfigParsingError'
configParsingError :: forall a. (Typeable a) => Key -> Text -> ConfigParsingError
configParsingError key text =
  ConfigParsingError key text $ typeRep (Proxy :: Proxy a)

-- | Exception to show that some non optional 'Key' was missing while trying
-- to 'fetchFromConfig'
data MissingRequiredKey =
  MissingRequiredKey [Key] TypeRep
  deriving (Typeable, Eq)

instance Exception MissingRequiredKey
instance Show MissingRequiredKey where
  show (MissingRequiredKey keys aTypeRep) =
    concat
    [ "Failed to get a '"
    , show aTypeRep
    , "' from keys: "
    , Text.unpack
      $ Text.intercalate ", "
      $ fmap (Text.pack . show)
      $ keys

    ]

-- | Simplified helper function to throw a 'MissingRequiredKey'
throwMissingRequiredKey :: forall t a. Typeable t => Key -> IO a
throwMissingRequiredKey key =
  throwMissingRequiredKeys @t [key]

-- | Simplified helper function to create a 'MissingRequiredKey'
missingRequiredKey :: forall t. Typeable t => Key -> MissingRequiredKey
missingRequiredKey key =
  missingRequiredKeys @t [key]

-- | Helper function to throw a 'MissingRequiredKey'
throwMissingRequiredKeys :: forall t a. Typeable t => [Key] -> IO a
throwMissingRequiredKeys keys =
  throwIO $ missingRequiredKeys @t keys

-- | Helper function to create a 'MissingRequiredKey'
missingRequiredKeys :: forall a. (Typeable a) => [Key] -> MissingRequiredKey
missingRequiredKeys keys =
  MissingRequiredKey keys (typeRep (Proxy :: Proxy a))

-- | Exception to show that the provided default had the wrong type, this is usually a
-- programmer error and a user that configures the library can not do much to fix it.
data TypeMismatchWithDefault =
  TypeMismatchWithDefault Key Dynamic TypeRep
  deriving (Typeable)

instance Eq TypeMismatchWithDefault where
  (==) = (==) `on`
    (\(TypeMismatchWithDefault k dyn t) -> (k, show dyn, t))
instance Exception TypeMismatchWithDefault
instance Show TypeMismatchWithDefault where
  show (TypeMismatchWithDefault key dyn aTypeRep) =
    concat
    [ "Couldn't parse the default from key "
    , show key
    , " since there is a type mismatch. "
    , "Expected type is "
    , show aTypeRep
    , " but the actual type is '"
    , show dyn
    , "'"
    ]

-- | Helper function to throw a 'TypeMismatchWithDefault'
throwTypeMismatchWithDefault :: forall a b. (Typeable a) => Key -> Dynamic -> IO b
throwTypeMismatchWithDefault key dynamic =
  throwIO $ typeMismatchWithDefault @a  key dynamic

-- | Helper function to create a 'TypeMismatchWithDefault'
typeMismatchWithDefault :: forall a. (Typeable a) => Key -> Dynamic -> TypeMismatchWithDefault
typeMismatchWithDefault key dynamic =
  TypeMismatchWithDefault key dynamic $ typeRep (Proxy :: Proxy a)

-- | Fetch from value from the defaults map of a 'Config' or else throw
fetchRequiredFromDefaults :: forall a. (Typeable a) => Key -> Config -> IO a
fetchRequiredFromDefaults key config =
  fetchFromDefaults key config >>=
    \case
    Nothing -> do
      throwMissingRequiredKey @a key
    Just a ->
      return a

-- | Fetch from value from the defaults map of a 'Config' or else return a 'Nothing'
fetchFromDefaults :: forall a. (Typeable a) => Key -> Config -> IO (Maybe a)
fetchFromDefaults key config =
  case getKeyFromDefaults key config of
    Nothing -> do
      return Nothing
    Just dyn ->
      case fromDynamic @a dyn of
        Nothing ->
          throwTypeMismatchWithDefault @a key dyn
        Just a -> return $ Just a

-- | Same as 'fetchFromConfig' using the root key
fetchFromRootConfig :: forall a. (FromConfig a) => Config -> IO a
fetchFromRootConfig =
  fetchFromConfig ""

-- | Same as 'fetchFromConfig' but adding a user defined default before 'fetchFromConfig'ing
-- so it doesn't throw a MissingKeyError
fetchFromConfigWithDefault :: forall a. (Typeable a, FromConfig a) => Config -> Key -> a -> IO a
fetchFromConfigWithDefault config key configDefault =
  fetchFromConfig key (config & addDefault key configDefault)

-- | Same as 'fetchFromConfigWithDefault' using the root key
fetchFromRootConfigWithDefault :: forall a. (Typeable a, FromConfig a) => Config -> a -> IO a
fetchFromRootConfigWithDefault config configDefault =
  fetchFromRootConfig (config & addDefault "" configDefault)

-- | Purely 'Generic's machinery, ignore...
class FromConfigG f where
  fetchFromConfigG :: Key -> Config -> IO (f a)

instance FromConfigG inner =>
    FromConfigG (D1 metadata inner) where
  fetchFromConfigG key config = do
    M1 <$> fetchFromConfigG key config

instance (FromConfigWithConNameG inner, Constructor constructor) =>
    FromConfigG (C1 constructor inner) where
  fetchFromConfigG key config =
    M1 <$> fetchFromConfigWithConNameG @inner (conName @constructor undefined) key config

-- | Purely 'Generic's machinery, ignore...
class FromConfigWithConNameG f where
  fetchFromConfigWithConNameG :: String -> Key -> Config -> IO (f a)

instance (FromConfigWithConNameG left, FromConfigWithConNameG right) =>
    FromConfigWithConNameG (left :*: right) where
  fetchFromConfigWithConNameG s key config = do
    leftValue <- fetchFromConfigWithConNameG @left s key config
    rightValue <- fetchFromConfigWithConNameG @right s key config
    return (leftValue :*: rightValue)

instance (FromConfigG inner, Selector selector) =>
    FromConfigWithConNameG (S1 selector inner) where
  fetchFromConfigWithConNameG s key config =
    let
      applyFirst :: (Char -> Char) -> Text -> Text
      applyFirst f t = case Text.uncons t of
        Just (c, ts) -> Text.cons (f c) ts
        Nothing -> t

      fieldName = Text.pack $ selName @selector undefined
      prefix = applyFirst Char.toLower $ Text.pack s
      scopedKey =
        case Text.stripPrefix prefix fieldName of
          Just stripped -> applyFirst Char.toLower stripped
          Nothing -> fieldName
    in M1 <$> fetchFromConfigG @inner (key /. fromText scopedKey) config

instance (FromConfig inner) => FromConfigG (Rec0 inner) where
  fetchFromConfigG key config = do
    K1 <$> fetchFromConfig @inner key config

-- | Purely 'Generic's machinery, ignore...
class IntoDefaultsG f where
  intoDefaultsG :: Key -> f a -> [(Key, Dynamic)]

instance IntoDefaultsG inner =>
    IntoDefaultsG (D1 metadata inner) where
  intoDefaultsG key (M1 inner) =
    intoDefaultsG key inner

instance (IntoDefaultsWithConNameG inner, Constructor constructor) =>
    IntoDefaultsG (C1 constructor inner) where
  intoDefaultsG key (M1 inner) =
    intoDefaultsWithConNameG @inner (conName @constructor undefined) key inner

-- | Purely 'Generic's machinery, ignore...
class IntoDefaultsWithConNameG f where
  intoDefaultsWithConNameG :: String -> Key -> f a -> [(Key, Dynamic)]

instance (IntoDefaultsWithConNameG left, IntoDefaultsWithConNameG right) =>
    IntoDefaultsWithConNameG (left :*: right) where
  intoDefaultsWithConNameG s key (left :*: right) = do
    intoDefaultsWithConNameG @left s key left
    ++
    intoDefaultsWithConNameG @right s key right

instance (IntoDefaultsG inner, Selector selector) =>
    IntoDefaultsWithConNameG (S1 selector inner) where

  intoDefaultsWithConNameG s key (M1 inner) =
    let
      applyFirst :: (Char -> Char) -> Text -> Text
      applyFirst f t = case Text.uncons t of
        Just (c, ts) -> Text.cons (f c) ts
        Nothing -> t

      fieldName = Text.pack $ selName @selector undefined
      prefix = applyFirst Char.toLower $ Text.pack s
      scopedKey =
        case Text.stripPrefix prefix fieldName of
          Just stripped -> applyFirst Char.toLower stripped
          Nothing -> fieldName
    in intoDefaultsG @inner (key /. fromText scopedKey) inner

instance (Typeable inner) => IntoDefaultsG (Rec0 inner) where
  intoDefaultsG key (K1 inner) = do
    [(key, toDyn inner)]