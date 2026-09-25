{-# LANGUAGE FlexibleInstances #-}

-- |
-- Module      : Evolution.Pretty
-- Description : A bordered table for printing a population.
--
-- Renders a list of individuals as an aligned two-column table:
--
-- @
-- ┬────────┬───────────────────
-- │ Fitness │ Tree
-- ├────────┼───────────────────
-- │ 0       │ length x0
-- ...
-- ┴────────┴───────────────────
-- @
--
-- Column widths are computed by folding the maximum length per column, so
-- the table stays readable regardless of how long the programs are.

module Evolution.Pretty where

import Data.List (intercalate)
import Data.Semigroup (Max (Max, getMax))
import Evolution.Run (Individual (..))
import Pretty (Pretty (..))

-- * Pretty Print Individual

-- | A list wrapper whose 'Semigroup' zips two lists together, keeping the
-- longest element per column (via 'Max').
--
-- Used to fold a whole table of cells into a list of column widths:
-- @foldMap (Zip . map (Max . length)) rows@ gives, for every column, the
-- width of its widest cell.
newtype Zip a = Zip {getZip :: [a]} deriving (Show)

-- | Zips element-wise. If the lists have different lengths the result stops
-- at the shorter one (empty on total mismatch), which is safe here because
-- every row has the same number of columns.
instance Semigroup a => Semigroup (Zip a) where
  Zip (a : as) <> Zip (b : bs) = Zip (a <> b : getZip (Zip as <> Zip bs))
  _ <> _ = Zip []

instance Show a => Pretty [Individual a] where
  pretty is = unlines $ [separator '┬', paddedHeader, separator '┼'] <> padded <> [separator '┴']
    where
      showInd i = [show $ _fitness i, pretty $ _indTree i]
      shown = map showInd is
      header = [["Fitness", "Tree"]]
      widths = map getMax $ getZip $ foldl1 (<>) $ map (Zip . map (Max . length)) (shown <> header)
      pad = intercalate " │ " . zipWith (\p s -> s ++ replicate (p - length s) ' ') widths
      paddedHeader = pad . head $ header
      separator m = intercalate ['─', m, '─'] $ map (`replicate` '─') widths
      padded = map pad shown