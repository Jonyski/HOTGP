-- |
-- Module      : Benchmark
-- Description : Umbrella module - re-exports the problem registry.
--
-- Importing "Benchmark" gives you every benchmark definition plus the
-- helpers to look them up and run them ("Benchmark.Problems"). The rest of
-- the Benchmark.* modules are implementation details of running a problem
-- and are imported directly where needed.
module Benchmark (module Benchmark.Problems) where

import Benchmark.Problems