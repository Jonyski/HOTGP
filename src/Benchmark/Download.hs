-- |
-- Module      : Benchmark.Download
-- Description : Fetches benchmark datasets from GitHub on first use.
--
-- The datasets come from the public
-- @thelmuth/program-synthesis-benchmark-datasets@ repository - the standard
-- collection used by program-synthesis benchmarks. Each problem has two
-- files:
--
-- * @\<name\>-random.json@ - randomly generated cases (the bulk);
-- * @\<name\>-edge.json@   - hand-picked edge cases.
--
-- Downloading happens lazily (only when a benchmark actually needs the
-- files) and is idempotent: if the file is already present it is reused, so
-- each dataset is fetched at most once per machine.
--
-- The pipeline per file is: @curl@ the @.gz@, then @gzip -d | sort -R@ to
-- decompress /and/ shuffle it into a random order (the train/test split
-- later takes a prefix, so a fixed order would be biased).
{-# LANGUAGE ScopedTypeVariables #-}

module Benchmark.Download where

import Benchmark.Core (Benchmark)
import Control.Exception (SomeException, handle)
import Control.Monad
import System.Directory
import System.IO (hFlush, stdout)
import System.Process

-- | Where datasets live, relative to the working directory.
csvDirs :: FilePath
csvDirs = "datasets/"

-- | Downloads both dataset files for a problem, creating the directory if
-- needed.
downloadBenchmark :: FilePath -> String -> IO ()
downloadBenchmark workDir name = do
  createDirectoryIfMissing True $ workDir <> csvDirs
  dlAndUnzip workDir name "random"
  dlAndUnzip workDir name "edge"

-- | Downloads and decompresses one dataset file unless it already exists.
--
-- The shuffle/decompress step runs through a @handle@ that swallows any
-- exception: if it fails (e.g. the download produced HTML instead of gzip),
-- we leave the file in whatever state it reached rather than aborting the
-- run - the caller will surface a clearer error when it tries to parse.
dlAndUnzip :: FilePath -> String -> String -> IO ()
dlAndUnzip workDir name suffix = do
  let url = makeUrl name suffix
      fileName = workDir <> csvDirs <> jsonName name suffix
  fileExists <- doesFileExist fileName
  unless fileExists $ do
    putStrLn $ "::: Downloading " <> fileName <> " :::"
    hFlush stdout
    callCommand $ "curl -LJ -o " <> fileName <> ".gz " <> url
    let unzipAndShuffle = "gzip --to-stdout -d " <> fileName <> ".gz | sort -R > " <> fileName
    handle (\(e :: SomeException) -> return ()) $ do
      callCommand unzipAndShuffle
      removeFile $ fileName <> ".gz"
      putStrLn $ "::: Done! " <> fileName <> " :::"
      hFlush stdout

-- | URL of a gzipped dataset file in the upstream repository.
makeUrl :: String -> String -> String
makeUrl name suffix =
  "https://github.com/thelmuth/program-synthesis-benchmark-datasets/raw/master/datasets/"
    <> name
    <> "/"
    <> jsonName name suffix
    <> ".gz"

-- | On-disk (and upstream) file name: @\<name\>-\<suffix\>.json@.
jsonName :: String -> String -> String
jsonName name suffix = name <> "-" <> suffix <> ".json"