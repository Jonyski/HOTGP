{-# LANGUAGE TypeApplications #-}

-- |
-- Module      : GrammarTypesSpec
-- Description : Every operation really produces the type it declares.
--
-- The grammar's type system is what makes crossover and mutation safe, so
-- this spec checks its most fundamental promise: instantiate an operation's
-- polymorphic type, feed it literals of exactly the declared argument types,
-- evaluate, and the result must carry the declared output type.
--
-- If this fails, everything downstream (type-aware sampling, the
-- type-preserving crossover in "Evolution.Crossover") would be building on
-- sand.
module GrammarTypesSpec where

import Grammar
import Helpers (genLitOfType, instantiatePolymorphicType)
import Test.Tasty
import Test.Tasty.QuickCheck (Arbitrary (arbitrary))
import qualified Test.Tasty.QuickCheck as QC
import qualified Text.ParserCombinators.ReadP as QC

-- | A single property: \"all operations run with the provided types\".
tests :: [TestTree]
tests =
  [ QC.testProperty
      "All operations run with the provided types"
      testOperations
  ]

-- | For a random 'Operation':
--
-- 1. instantiate its polymorphic type to something concrete
--    ('Helpers.instantiatePolymorphicType');
-- 2. generate a literal for each declared argument type;
-- 3. evaluate @op \<| [args]@.
--
-- Evaluation may legitimately fail ('Nothing' - e.g. division by zero) in
-- which case the case is 'QC.discard'd; otherwise the result's 'litType'
-- must equal the instantiated output type.
testOperations :: QC.Gen QC.Property
testOperations = do
  operation <- QC.arbitraryBoundedEnum @Operation
  operationType <- instantiatePolymorphicType $ opType operation
  lits <- sequence $ genLitOfType <$> _argTypes operationType
  let evaluated = evalTree [] (operation <| (litT <$> lits))
  case evaluated of
    Nothing -> QC.discard
    Just e -> return $ QC.counterexample (show (operation <| (litT <$> lits))) $ litType e QC.=== _outType operationType
