-- | Module      : GpuSpec
--   Description : Parity tests for the GPU evaluation path.
--
-- Three layers are tested, in increasing distance from the interpreter:
--
-- 1. 'Grammar.Flat.evalFlat' against 'Grammar.Eval.evalTree', on a table of
--    hand-built programs that pins down every semantic corner (div/mod signs,
--    division by zero, the NaN rule, eager @if@), plus random populations from
--    the real sampler;
-- 2. 'Benchmark.Gpu.scorePopulation' against the config's own
--    @_fitnessFunction@, i.e. the claim that a batched population is scored
--    exactly like a serial one;
-- 3. the external kernel runner (@gpu/gp_eval_cpu@), which runs the very code
--    that compiles to CUDA. That test is skipped when the binary has not been
--    built with @make -C gpu cpu@.
module GpuSpec where

import Benchmark.BenchmarkToConfig (makeConfig)
import Benchmark.Core (Benchmark (..))
import Benchmark.Gpu
import Benchmark.Problems.Median (median)
import Benchmark.Problems.NumberIO (numberIO)
import Benchmark.Problems.Smallest (smallest)
import qualified Control.Monad.State.Strict as S
import qualified Data.Map as M
import qualified Data.Set as Set
import qualified Data.SortedList as SL
import Evolution
import Evolution.Fitness (Fitness)
import Evolution.Individual (_fitness)
import Grammar
import Grammar.Flat
import Pretty (pretty)
import Data.Maybe (fromMaybe)
import System.Directory (doesFileExist)
import System.Environment (lookupEnv)
import System.Random (mkStdGen)
import Test.Tasty
import Test.Tasty.HUnit
import qualified Test.Tasty.QuickCheck as QC

tests :: [TestTree]
tests =
  [ testGroup
      "Flatten"
      [ testCase "matches the interpreter on every scalar operator" $ do
          mapM_ checkOpCase opCases,
        testCase "rejects non-scalar programs" $ do
          assertBooleans
            [ isLeft (flattenTree 1 (Head <| [arg 0])),
              isLeft (flattenTree 1 (litT (ListLit GInt [IntLit 1]))),
              isLeft (flattenTree 1 (Singleton <| [arg 0]))
            ],
        testCase "enforces the kernel stack bound" $ do
          let chain n = foldr (\k acc -> AddInt <| [iLitT k, acc]) (iLitT 0) [1 .. n]
          assertBooleans
            [ isRight (flattenTree 0 (chain 8)),
              -- 40 pushes deep: more than the kernel's HGP_MAX_STACK (32).
              isLeft (flattenTree 0 (chain 40))
            ],
        QC.testProperty "random populations match the interpreter" $ QC.withMaxSuccess 40 prop_populationParity
      ],
    testGroup
      "Batch fitness"
      [ testCase "median: batched == interpreter" $ checkBatch median medianSet,
        testCase "smallest: batched == interpreter" $ checkBatch smallest smallestSet,
        testCase "number-io: batched == interpreter" $ checkBatch numberIO numberIOSet
      ],
    testGroup
      "Run loop integration"
      [ testCase "initPopBatched == initPop for the same seed" checkInitPopParity
      ],
    testGroup
      "External runner"
      [ testCase "the external runner matches the CPU reference" $ do
          -- The CPU twin by default; HOTGP_GPU_RUNNER lets the same test
          -- verify the CUDA binary on a machine that has one.
          path <- fromMaybe "gpu/gp_eval_cpu" <$> lookupEnv "HOTGP_GPU_RUNNER"
          built <- doesFileExist path
          if not built
            then -- Not a failure: the Haskell build does not depend on the C++
            -- toolchain. The message says exactly how to enable the check.
              putStrLn $ "SKIPPED: " <> path <> " not built; run `make -C gpu cpu` to enable this test"
            else checkExternal path median medianSet
      ]
  ]

-- * Layer 1: the flattened evaluator

-- | Every scalar operator, with argument lists chosen to hit the interesting
-- branches. The expected result is /not/ written down here on purpose: the
-- oracle is 'evalTree', so the test fails if either side drifts.
opCases :: [(String, Tree, [[Lit]])]
opCases =
  [ ("AddInt", AddInt <| [arg 0, arg 1], intArgs),
    ("SubInt", SubInt <| [arg 0, arg 1], intArgs),
    ("MultInt", MultInt <| [arg 0, arg 1], intArgs),
    ("DivInt", DivInt <| [arg 0, arg 1], intArgs),
    ("ModInt", ModInt <| [arg 0, arg 1], intArgs),
    ("MaxInt", MaxInt <| [arg 0, arg 1], intArgs),
    ("MinInt", MinInt <| [arg 0, arg 1], intArgs),
    ("And", And <| [arg 0, arg 1], boolArgs),
    ("Or", Or <| [arg 0, arg 1], boolArgs),
    ("Not", Not <| [arg 0], [[BoolLit True], [BoolLit False]]),
    ( "If",
      If <| [GtInt <| [arg 0, arg 1], AddInt <| [arg 0, iLitT 1], SubInt <| [arg 1, iLitT 1]],
      intArgs
    ),
    ( "If evaluates both branches (crash in the unused one)",
      If <| [bLitT True, iLitT 1, DivInt <| [iLitT 1, iLitT 0]],
      [[]]
    ),
    ( "If selects a NaN branch value",
      If <| [bLitT True, iLitT 1, nanTree],
      [[]]
    ),
    ("AddFloat", AddFloat <| [arg 0, arg 1], floatArgs),
    ("SubFloat", SubFloat <| [arg 0, arg 1], floatArgs),
    ("MultFloat", MultFloat <| [arg 0, arg 1], floatArgs),
    ("DivFloat", DivFloat <| [arg 0, arg 1], floatArgs),
    ("Sqrt", Sqrt <| [arg 0], [[FloatLit x] | x <- [-4, 0, 2, 9, -0.5]]),
    ("Floor", Floor <| [arg 0], [[FloatLit x] | x <- [-2.5, -0.5, 0, 2.5, 7]]),
    ("IntToFloat", IntToFloat <| [arg 0], [[IntLit x] | x <- [-7, 0, 42]]),
    ("EqChar", EqChar <| [arg 0, arg 1], charPairs),
    ("IsLetter", IsLetter <| [arg 0], charArgs),
    ("IsDigit", IsDigit <| [arg 0], charArgs),
    ("GtInt", GtInt <| [arg 0, arg 1], intArgs),
    ("LtInt", LtInt <| [arg 0, arg 1], intArgs),
    ("EqInt", EqInt <| [arg 0, arg 1], intArgs),
    -- inf - inf = NaN, which the interpreter turns into Nothing.
    ("NaN from an operator", SubFloat <| [overflow, overflow], [[]]),
    -- A small composite, to exercise the stack depth accounting.
    ( "Composite",
      AddInt <| [MultInt <| [arg 0, arg 1], Floor <| [Sqrt <| [arg 2]]],
      [[IntLit a, IntLit b, FloatLit c] | (a, b, c) <- [(-2, 5, 16), (3, -4, 2)]]
    )
  ]
  where
    intArgs =
      [ [IntLit a, IntLit b]
        | a <- [-7, -1, 0, 3, 9],
          b <- [-3, -1, 0, 2]
      ]
    floatArgs =
      [ [FloatLit a, FloatLit b]
        | a <- [-3.5, 0, 1.5, 1e38],
          b <- [-2, 0, 0.5, 1e38]
      ]
    boolArgs = [[BoolLit a, BoolLit b] | a <- [True, False], b <- [True, False]]
    charArgs = [[CharLit c] | c <- "aZ5\n"]
    charPairs = [[CharLit a, CharLit b] | a <- "aZ", b <- "a\n"]
    overflow = MultFloat <| [fLitT 1e38, fLitT 1e38]
    nanTree = SubFloat <| [overflow, overflow]

checkOpCase :: (String, Tree, [[Lit]]) -> Assertion
checkOpCase (label, tree, argLists) = case flattenTree nArgs tree of
  Left reason -> assertFailure $ label <> ": flattening failed: " <> reason
  Right prog -> do
    assertEqual (label <> ": arity") nArgs (_flatArity prog)
    mapM_ (\args -> assertEqual (label <> ": " <> show args) (evalTree args tree) (evalFlat prog args)) argLists
  where
    -- All cases in one entry share a program type; the arity is the widest
    -- argument list, which is what the interpreter indexes into.
    nArgs = maximum (0 : map length argLists)

-- | Random trees from the real sampler, evaluated on random arguments.
-- Only trees that fit the scalar subset are compared, but at least one must
-- fit, otherwise the property would pass vacuously.
prop_populationParity :: QC.Property
prop_populationParity =
  QC.forAll (QC.choose (-50, 50)) $ \a ->
    QC.forAll (QC.choose (-50, 50)) $ \b ->
      let cfg = makeTestConfig 20
          trees = S.evalState (ramped cfg) (mkStdGen (abs (a * 131 + b)))
          checked = [t | t <- trees, isRight (flattenTree 2 t)]
          args = [IntLit a, IntLit b]
          mismatches =
            [ (pretty t, evalTree args t, evalFlat prog args)
              | t <- checked,
                Right prog <- [flattenTree 2 t],
                evalTree args t /= evalFlat prog args
            ]
       in QC.counterexample (unlines (map show mismatches)) $
            QC.conjoin
              [ QC.counterexample "no tree could be flattened" (not (null checked)),
                QC.property (null mismatches)
              ]
  where
    makeTestConfig popSize =
      ( makeConfig
          []
          benchmark
      )
        { _popSize = popSize,
          _nEvaluations = 0
        }
    -- A purely scalar program: Int -> Int -> Int, with no list, pair or
    -- lambda type in scope, so the sampler only produces flattenable trees.
    benchmark :: Benchmark ()
    benchmark = benchmarkFor ([GInt, GInt] ->> GInt)

-- * Layer 2: batched fitness

-- | A hand-made training set is enough: what is compared is the /aggregation
-- path/, not the quality of the search.
medianSet :: [([Lit], Lit)]
medianSet =
  [ ([IntLit a, IntLit b, IntLit c], IntLit (median3 a b c))
    | (a, b, c) <- [(1, 2, 3), (3, 2, 1), (5, 5, 5), (-4, 0, 9), (2, 7, 4)]
  ]
  where
    median3 a b c = max (min a b) (min c (max a b))

smallestSet :: [([Lit], Lit)]
smallestSet =
  [ ([IntLit a, IntLit b, IntLit c, IntLit d], IntLit (minimum [a, b, c, d]))
    | (a, b, c, d) <- [(1, 2, 3, 4), (4, 3, 2, 1), (-5, 0, 5, 2), (7, 7, 7, 7)]
  ]

numberIOSet :: [([Lit], Lit)]
numberIOSet =
  [ ([FloatLit x, IntLit n], FloatLit (x + fromIntegral n))
    | (x, n) <- [(1.5, 2), (-3.0, 4), (0, 0)]
  ]

-- | Scores a population twice - through the batch and through the
-- interpreter - and requires identical results, plus full eligibility (these
-- three benchmarks only use scalar types, so nothing should fall back).
checkBatch :: (Monoid a, Show a, Eq a, Ord a, Fitness a) => Benchmark a -> [([Lit], Lit)] -> Assertion
checkBatch bench trainSet = do
  let cfg = (makeConfig trainSet bench) {_popSize = 80}
      trees = S.evalState (ramped cfg) (mkStdGen 7)
      problem = problemFromBenchmark bench trainSet
      expected = map (_fitnessFunction cfg) trees
  (individuals, stats) <- populationBatch CpuReference problem trees
  assertEqual "batched fitness differs from the interpreter" expected (map _fitness individuals)
  assertEqual "trees" (_statTrees stats) (length trees)
  assertEqual "eligible trees (all-scalar benchmark)" (_statEligible stats) (length trees)

-- * Layer 2b: the run loop

-- | The batched initial population must be /the same population/ as the
-- serial one: same trees (the RNG stream is untouched by scoring) and same
-- fitnesses. This is the property that lets 'runAndLogWith' swap scorers
-- without changing a run's outcome.
checkInitPopParity :: Assertion
checkInitPopParity = do
  let cfg = (makeConfig medianSet median) {_popSize = 40}
      seed = mkStdGen 11
      serialPop = S.evalState (initPop cfg) seed
      serialTrees = map _indTree (SL.fromSortedList serialPop)
      serialFits = map _fitness (SL.fromSortedList serialPop)
  scorer <- mkBatchScorer CpuReference median medianSet
  batchedPop <- S.evalStateT (initPopBatched (\_ -> _scoreTrees scorer) cfg) seed
  stats <- _scorerStats scorer
  assertEqual "batched population has different trees" serialTrees (map _indTree (SL.fromSortedList batchedPop))
  assertEqual "batched population has different fitnesses" serialFits (map _fitness (SL.fromSortedList batchedPop))
  assertEqual "trees scored in the batch" (_statEligible stats) 40

-- * Layer 3: the external kernel runner

-- | Runs the same comparison through an external runner, which executes the
-- kernel source that is compiled to CUDA. This is what proves that the kernel,
-- its opcode table and its wire format agree with the Haskell reference.
checkExternal :: (Monoid a, Show a, Eq a, Ord a, Fitness a) => FilePath -> Benchmark a -> [([Lit], Lit)] -> Assertion
checkExternal path bench trainSet = do
  let cfg = (makeConfig trainSet bench) {_popSize = 80}
      trees = S.evalState (ramped cfg) (mkStdGen 7)
      problem = problemFromBenchmark bench trainSet
      expected = map (_fitnessFunction cfg) trees
  (reference, _) <- scorePopulation CpuReference problem trees
  (external, stats) <- scorePopulation (ExternalRunner path) problem trees
  assertEqual "kernel results differ from the CPU reference" reference external
  assertEqual "kernel fitness differs from the interpreter" expected external
  assertEqual "trees sent to the kernel" (_statEligible stats) (length trees)

-- * Fixtures

-- | A minimal benchmark for a given program type: no dataset, no metric, only
-- the sampling tables matter for tree generation.
benchmarkFor :: FunctionType -> Benchmark ()
benchmarkFor fType =
  MkBenchmark
    { _benchmarkId = Nothing,
      _datasetName = "gpu-spec",
      _inputTypes = _argTypes fType,
      _outputType = _outType fType,
      _fitnessMetric = const (const ()),
      _testCases = 0,
      _trainCases = 0,
      _relevantTypes = Set.fromList (typesOf fType),
      _customOutputParser = Nothing,
      _allowedConstants =
        M.fromList
          [ (GInt, [return $ IntLit 42]),
            (GFloat, [return $ FloatLit 1.5]),
            (GBool, [return $ BoolLit True]),
            (GChar, [return $ CharLit 'x'])
          ]
    }
  where
    -- Scalar types only, so 'ramped' cannot build a list/pair/lambda node.
    typesOf (MkFunctionType as o) = filter isScalarType (as <> [o])
    isScalarType GInt = True
    isScalarType GFloat = True
    isScalarType GBool = True
    isScalarType GChar = True
    isScalarType _ = False

-- * Small helpers

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft _ = False

isRight :: Either a b -> Bool
isRight = not . isLeft

assertBooleans :: [Bool] -> Assertion
assertBooleans = mapM_ (assertBool "unexpected Left/Right classification")
