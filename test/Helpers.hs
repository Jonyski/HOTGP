-- |
-- Module      : Helpers
-- Description : Shared QuickCheck generators for the test suite.
--
-- The specs need arbitrary values that are *well-typed by construction*:
-- a property such as \"type inference agrees with the generator\" is only
-- meaningful if the generator never produces an ill-typed tree in the first
-- place. These helpers provide that guarantee.
module Helpers where

import Data.List (find)
import Grammar
import qualified Test.Tasty.QuickCheck as QC

-- | Generate a literal of exactly the requested type.
--
-- Product types are built component-wise (@\<*\>@), lists by generating
-- one or more elements, and functions as /constant/ functions - a lambda
-- whose body ignores its argument. Function literals are hard to generate
-- meaningfully otherwise, and constant functions are enough for every
-- property in the suite.
--
-- Partial: 'GPoly' is a type /variable/, not a concrete type, so there is
-- nothing sensible to generate; a caller asking for one has a bug in its
-- own type instantiation.
genLitOfType :: GType -> QC.Gen Lit
genLitOfType GInt = IntLit . QC.getPositive <$> QC.arbitrary
genLitOfType GFloat = FloatLit . QC.getPositive <$> QC.arbitrary
genLitOfType GBool = BoolLit <$> QC.arbitrary
genLitOfType GChar = CharLit <$> QC.arbitraryASCIIChar
genLitOfType (GPair a b) = PairLit <$> genLitOfType a <*> genLitOfType b
genLitOfType (GList t) = ListLit t <$> QC.listOf1 (genLitOfType t)
genLitOfType (GLambda ft) = flip lambdaLit ft . LeafLit <$> genLitOfType (_outType ft) -- const functions
genLitOfType (GPoly n) = error "Cannot generate lit of Polymorphic type"

-- | Mapping from a type-variable index to the concrete type it stands for
-- (see 'replaceFunctionType'). Empty means \"instantiate everything
-- independently\".
type ConstraintMap = [(Int, GType)]

-- | Turn a polymorphic function type (e.g. @(a -> b) -> [a] -> [b]@) into a
-- concrete one by choosing a random type for every free variable.
instantiatePolymorphicType :: FunctionType -> QC.Gen FunctionType
instantiatePolymorphicType = instantiatePolymorphicTypeWith []

-- | Like 'instantiatePolymorphicType', but variables listed in the
-- constraint map keep their assigned type instead of being re-rolled.
--
-- This is how the specs express *partial* instantiation: fix some variables
-- (say @a = GInt@) and let QuickCheck pick the rest.
instantiatePolymorphicTypeWith :: ConstraintMap -> FunctionType -> QC.Gen FunctionType
instantiatePolymorphicTypeWith cm ft = do
  rands <- QC.infiniteListOf arbitraryType
  return $ replaceFunctionType cm rands ft

-- | A small, closed set of concrete types to instantiate type variables with:
-- the four base types, a list of each, and a pair of each. Deliberately no
-- nested functions - they would make generated programs much harder to
-- evaluate without adding coverage the properties actually need.
arbitraryType :: QC.Gen GType
arbitraryType =
  QC.elements $
    concreteTypes
      <> (GList <$> concreteTypes)
      <> (GPair <$> concreteTypes <*> concreteTypes)
  where
    concreteTypes = [GInt, GBool, GFloat, GChar]

-- | The workhorse behind both instantiators: rewrite every 'GPoly' variable
-- in a function type with either its constraint-map binding or the n-th
-- entry of the random-type stream. Descends into lists, pairs and nested
-- function types so no variable is left behind.
replaceFunctionType :: ConstraintMap -> [GType] -> FunctionType -> FunctionType
replaceFunctionType cm rands (MkFunctionType i o) = (rep <$> i) ->> rep o
  where
    rep :: GType -> GType
    rep (GPoly n) = case find ((== n) . fst) cm of
      Just (n, gt) -> gt
      Nothing -> rands !! n
    rep (GList a) = GList $ rep a
    rep (GPair a b) = GPair (rep a) (rep b)
    rep (GLambda ft) = GLambda (replaceFunctionType cm rands ft)
    rep t = t
