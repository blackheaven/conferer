module Conferer.Source.PropertiesFileSpec where

import           Test.Hspec
import qualified Data.Text as Text
import qualified Data.Map as Map

import Conferer
import Conferer.Core
import Conferer.Types

fakeLookupEnv :: [(String, String)] -> LookupEnvFunc
fakeLookupEnv fakeEnv = \envName ->
  return $ Map.lookup envName $ Map.fromList fakeEnv

spec :: Spec
spec = do
  describe "with a properties file config" $ do
    it "getting an existent key returns unwraps top level value (wihtout \
       \children)" $ do
      c <- mkStandaloneSource $ mkPropertiesFileSource' "some.key=a value"
      res <- getKeyInSource c "some.key"
      res `shouldBe` Just "a value"

    it "getting an existent key for a child gets that value" $ do
      c <- mkStandaloneSource $ mkPropertiesFileSource' $ Text.unlines
                               [ "some.key=a value"
                               , "some.key=b"
                               ]
      res <- getKeyInSource c "some.key"
      res `shouldBe` Just "b"

    it "keys should always be consistent as to how the words are separated" $ do
      c <- mkStandaloneSource $ mkPropertiesFileSource' $ Text.unlines
                               [ "some.key=a value"
                               , "some.key=b"
                               ]
      res <- getKeyInSource c "another.key"
      res `shouldBe` Nothing
