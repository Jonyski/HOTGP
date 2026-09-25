-- |
-- Module      : Benchmark.Parse
-- Description : Turn JSON dataset lines into typed 'Lit' values.
--
-- The datasets (downloaded by "Benchmark.Download") are JSON-lines files:
-- each line is an object with @input1@, @input2@, ... and an @output1@
-- field. This module converts one such object into a
-- @([inputs], expected output)@ pair in the grammar's value language.
--
-- Parsing is driven by the types declared in the 'Benchmark.Core.Benchmark'
-- record: the i-th input is parsed according to @_inputTypes!!i@, and the
-- output according to @_outputType@ (or a problem-specific parser).
{-# LANGUAGE OverloadedStrings #-}

module Benchmark.Parse where

import Data.Aeson
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Aeson.Key as K
import Data.ByteString.Char8 (pack)
import Data.HashMap.Strict ((!?))
import Data.Scientific (toRealFloat)
import qualified Data.Text as T
import Data.Vector (toList)
import Grammar
import Pretty

-- | A custom parser for a benchmark's expected output.
--
-- Problems whose answer is not simply the @output1@ field (or not of the
-- declared type) supply their own extraction logic.
type OutputParser = Object -> Lit

-- | Decode a single JSON line into an aeson 'Object'.
--
-- Partial: a malformed line means the dataset file is corrupt, and failing
-- fast is preferable to silently training on garbage.
parseJsonLine :: String -> Object
parseJsonLine jsonStr = json where Just (Object json) = decodeStrict (pack jsonStr)

-- | The standard output parser: read the @output1@ field and decode it as
-- the benchmark's declared output type.
defaultOutputParser :: OutputType -> OutputParser
defaultOutputParser gType json = parseJsonLit gType val where Just val = KM.lookup (K.fromString "output1") json

-- | Decode a JSON 'Value' into a 'Lit' of the requested type.
--
-- Note @GChar@ expects a one-character JSON string, and @[Char]@ (i.e.
-- @GList GChar@) expects a whole string - both are natural because the
-- datasets store characters as JSON strings too.
parseJsonLit :: OutputType -> Value -> Lit
parseJsonLit GInt (Number sci) = IntLit $ round $ toRealFloat sci
parseJsonLit GFloat (Number sci) = FloatLit $ toRealFloat sci
parseJsonLit GBool (Bool b) = BoolLit b
parseJsonLit GChar (String txt) = CharLit $ T.head txt
parseJsonLit (GList GChar) (String txt) = stLit $ T.unpack txt
parseJsonLit (GList gt) (Array vec) = ListLit gt $ toList $ fmap (parseJsonLit gt) vec
parseJsonLit typ val = error $ unwords ["Could not parse", pretty typ, "from", show val]

-- | Field accessor for dataset objects: @json ^. "input1"@.
--
-- Partial by design - a missing field is a malformed dataset.
(^.) :: Object -> String -> Value
(^.) json key = let Just val = KM.lookup (K.fromString key) json in val
