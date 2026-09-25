-- |
-- Module      : ProblemTrees
-- Description : Reference solutions - one hand-written tree per benchmark.
--
-- Each binding is a *known-good* program for the benchmark of the same name
-- (see "Benchmark.Problems"), expressed in the grammar's AST. They serve two
-- purposes in the tests:
--
-- 1. /Evaluation/ - the tree should score perfectly on its own dataset, so
--    specs can assert that the evaluator, the dataset loading and the
--    metric definitions all agree with each other.
-- 2. /Type checking/ - these trees are richer than anything the generators
--    produce (nested lambdas, pairs, nested lists), so they double as
--    regression fixtures for "Grammar.Types".
--
-- The helper combinators come from "Grammar": @\<|@ builds an 'Node'
-- (operation applied to arguments), @arg n@ is the n-th function argument,
-- and the @*LitT@ functions build literals carrying their type.
module ProblemTrees where

import Grammar

-- | @numberIO@: convert the first argument to float and add the second.
numberIOTree :: Tree
numberIOTree = AddFloat <| [IntToFloat <| [arg 0], arg 1]

-- | @smallOrLarge@: nested if - \"small\" below 1000, \"large\" above 2000,
-- empty string in between.
smallOrLargeTree :: Tree
smallOrLargeTree =
  If
    <| [ LtInt <| [arg 0, iLitT 1000],
         stLitT "small",
         If <| [LtInt <| [arg 0, iLitT 2000], stLitT "", stLitT "large"]
       ]

-- | @forLoopIndex@: number each line of a range - `unlines (map show [0..n])`.
forLoopIndexTree :: Tree
forLoopIndexTree = Unlines <| [Map <| [lambdaLitT (ShowInt <| [arg 0]) ([GInt] ->> GList GChar), Range <| [arg 0, arg 1, arg 2]]]

-- | @compareStringLengths@: three strings are pairwise non-increasing in length.
compareStringLengthsTree :: Tree
compareStringLengthsTree =
  And
    <| [ LtInt <| [Len <| [arg 0], Len <| [arg 1]],
         LtInt <| [Len <| [arg 1], Len <| [arg 2]]
       ]

-- | @doubleLetters@: every character doubled; `!` becomes `!!!`, other letters repeat.
doubleLettersTree :: Tree
doubleLettersTree =
  Concat
    <| [ Map
           <| [ lambdaLitT lambda ([GChar] ->> GList GChar),
                arg 0
              ]
       ]
  where
    lambda :: Tree
    lambda =
      If
        <| [ EqChar <| [arg 0, chLitT '!'],
             stLitT "!!!",
             If
               <| [ IsLetter <| [arg 0],
                    listConsNode GChar [arg 0, arg 0],
                    listConsNode GChar [arg 0]
                  ]
           ]

-- | @replaceSpaceWithNewline@: swap spaces for newlines and count the spaces, as a pair.
replaceSpaceWithNewlineTree :: Tree
replaceSpaceWithNewlineTree = ToPair <| [str, count]
  where
    str = Map <| [lambdaLitT lambdaMap ([GChar] ->> GChar), arg 0]
    count = Len <| [Filter <| [lambdaLitT lambdaFilter ([GChar] ->> GBool), arg 0]]

    lambdaMap :: Tree
    lambdaMap =
      If
        <| [ EqChar <| [arg 0, chLitT ' '],
             chLitT '\n',
             arg 0
           ]

    lambdaFilter :: Tree
    lambdaFilter = Not <| [EqChar <| [arg 0, chLitT ' ']]

-- | @stringDifferences@: keep the zip-indexed pairs whose characters differ.
stringDifferencesTree :: Tree
stringDifferencesTree =
  Filter
    <| [ lambdaLitT lambdaFilter ([GPair GInt (GPair GChar GChar)] ->> GBool),
         Zip <| [Range <| [iLitT 0, Len <| [arg 0], iLitT 1], Zip <| [arg 0, arg 1]]
       ]
  where
    lambdaFilter :: Tree
    lambdaFilter = Not <| [EqChar <| [Fst <| [Snd <| [arg 0]], Snd <| [Snd <| [arg 0]]]]

-- | @evenSquares@: squares of the even numbers below the input (via `filter even . map (\x -> x*x) . takeWhile (< n)`).
evenSquaresTree :: Tree
evenSquaresTree =
  Filter
    <| [ lambdaLitT evenTree ([GInt] ->> GBool),
         Map
           <| [ lambdaLitT squaredTree ([GInt] ->> GInt),
                Range <| [iLitT 0, compOp [Floor, Sqrt, IntToFloat] [arg 0], iLitT 1]
              ]
       ]
  where
    squaredTree :: Tree
    squaredTree = MultInt <| [arg 0, arg 0]

    evenTree :: Tree
    evenTree = EqInt <| [iLitT 0, ModInt <| [arg 0, iLitT 2]]

-- | @wallisPi@: Wallis product approximation of pi, taking n terms.
wallisPiTree :: Tree
wallisPiTree = ProductFloats <| [Map <| [lambdaLitT mapTree ([GPair GInt GInt] ->> GFloat), Take <| [arg 0, listTree]]]
  where
    listTree :: Tree
    listTree = Zip <| [top, bot]
    top, bot :: Tree
    top = Cons <| [iLitT 2, dup $ Range <| [iLitT 4, AddInt <| [MultInt <| [iLitT 2, DivInt <| [arg 0, iLitT 2]], iLitT 2], iLitT 2]]
    bot = dup $ Range <| [iLitT 3, AddInt <| [MultInt <| [iLitT 2, DivInt <| [AddInt <| [iLitT 1, arg 0], iLitT 2]], iLitT 1], iLitT 2]

    dup :: Tree -> Tree
    dup x = Concat <| [Map <| [lambdaLitT (listConsNode GInt [arg 0, arg 0]) ([GInt] ->> GList GInt), x]]

    mapTree :: Tree
    mapTree = DivFloat <| [IntToFloat <| [Fst <| [arg 0]], IntToFloat <| [Snd <| [arg 0]]]

-- | @stringLengthsBackwards@: lengths of the strings, in reverse order.
stringLengthsBackwardsTree :: Tree
stringLengthsBackwardsTree = Reverse <| [Map <| [lambdaLitT (Len <| [arg 0]) ([GList GChar] ->> GInt), arg 0]]

-- | @lastIndexOfZero@: index of the last zero, or -1 when absent (implemented as head of the filtered zip).
lastIndexOfZeroTree :: Tree
lastIndexOfZeroTree =
  compOp
    [Fst, Head, Reverse, Filter]
    [lambdaLitT lambda ([GPair GInt GInt] ->> GBool), Zip <| [Range <| [iLitT 0, Len <| [arg 0], iLitT 1], arg 0]]
  where
    lambda :: Tree
    lambda = EqInt <| [iLitT 0, Snd <| [arg 0]]

-- | @vectorAverage@: sum of a float vector divided by its length.
vectorAverageTree :: Tree
vectorAverageTree = DivFloat <| [SumFloats <| [arg 0], IntToFloat <| [Len <| [arg 0]]]

-- | @countOdds@: how many elements are odd.
countOddsTree :: Tree
countOddsTree = Len <| [Filter <| [lambdaLitT lambda ([GList GFloat] ->> GInt), arg 0]]
  where
    lambda :: Tree
    lambda = EqInt <| [iLitT 1, ModInt <| [arg 0, iLitT 2]]

-- | @mirrorImage@: true iff the list equals its reverse (checked through a filtered zip).
mirrorImageTree :: Tree
mirrorImageTree =
  EqInt <| [Len <| [arg 0], Len <| [filtered]]
  where
    filtered :: Tree
    filtered =
      Filter
        <| [ lambdaLitT (EqInt <| [Fst <| [arg 0], Snd <| [arg 0]]) ([GPair GInt GInt] ->> GBool),
             Zip <| [arg 0, Reverse <| [arg 1]]
           ]

-- | @sumOfSquares@: sum of the squares of 1..n.
sumOfSquaresTree :: Tree
sumOfSquaresTree = SumInts <| [Map <| [lambdaLitT (MultInt <| [arg 0, arg 0]) ([GInt] ->> GInt), Range <| [iLitT 1, arg 0, iLitT 1]]]

-- | @vectorsSummed@: element-wise sum of two integer vectors.
vectorsSummedTree :: Tree
vectorsSummedTree = Map <| [lambdaLitT (AddInt <| [Fst <| [arg 0], Snd <| [arg 0]]) ([GPair GInt GInt] ->> GInt), Zip <| [arg 0, arg 1]]

-- | @negativeToZero@: clamp every element at zero.
negativeToZeroTree :: Tree
negativeToZeroTree = Map <| [lambdaLitT (If <| [LtInt <| [arg 0, iLitT 0], iLitT 0, arg 0]) ([GList GInt] ->> GInt), arg 0]

-- | @grade@: letter grade from a numeric score, using the usual A-F thresholds.
gradeTree :: Tree
gradeTree = Concat <| [templateStr]
  where
    templateStr = Cons <| [stLitT "Student has a ", Cons <| [checkF, Singleton <| [stLitT " grade."]]]
    checkF :: Tree
    checkF = If <| [LtInt <| [arg 4, arg 3], stLitT "F", checkD]
    checkD :: Tree
    checkD = If <| [LtInt <| [arg 4, arg 2], stLitT "D", checkC]
    checkC :: Tree
    checkC = If <| [LtInt <| [arg 4, arg 1], stLitT "C", checkB]
    checkB :: Tree
    checkB = If <| [LtInt <| [arg 4, arg 0], stLitT "B", stLitT "A"]

-- min (max (min x0 x1) x2) (max x0 x1)
medianTree :: Tree
medianTree = MinInt <| [MaxInt <| [MinInt <| [arg 0, arg 1], arg 2], MaxInt <| [arg 0, arg 1]]

-- | @smallest@: minimum of four arguments.
smallestTree :: Tree
smallestTree = MinInt <| [MinInt <| [arg 0, arg 1], MinInt <| [arg 2, arg 3]]