-- | Test-suite entry point.
--
-- Wiring only: each @*Spec@ module exports a `tests` value, and this file
-- gathers them under one Tasty tree so @cabal test@ (or @--pattern@) can run
-- them all from a single binary. Tasty provides the runner, grouping,
-- QuickCheck/HUnit integration, and the command-line filters
-- (@--quickcheck-tests@, @--pattern ...@, etc.).
import qualified BenchmarkSpec
import qualified EvolutionSpec
import qualified GrammarSpec
import qualified MaxTreeDepthSpec
import qualified MeasureSpec
import qualified PrettyTreeSpec
import Test.Tasty

main =
  defaultMain $
    testGroup
      "Tests"
      [ -- The six groups mirror the dependency layers of the code:
        -- Grammar (the language), Evolution (the search), Benchmark (the
        -- problems), plus focused suites for depth limits, pretty-printing
        -- and tree measures.
        testGroup "Grammar" GrammarSpec.tests,
        testGroup "Evolution" EvolutionSpec.tests,
        testGroup "Benchmark" BenchmarkSpec.tests,
        testGroup "Max tree depth" MaxTreeDepthSpec.tests,
        testGroup "Prettify Tree" PrettyTreeSpec.tests,
        testGroup "Measure" MeasureSpec.tests
      ]
