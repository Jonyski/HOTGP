-- |
-- Module      : Pretty
-- Description : The project-wide \"render as readable text\" type class.
--
-- A single tiny class so that every layer can offer a human-readable view of
-- its values without depending on a printing library. Instances live next to
-- the types they print: "Grammar.Pretty" for grammar values, "Evolution.Pretty"
-- for populations, and so on.
module Pretty where

-- | Convert a value to a 'String'.
--
-- Used for log lines, the \"perfect solution found\" message, test
-- expectations and the pruner's output files.
class Pretty a where
  pretty :: a -> String