{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Module      : Benchmark.Gpu.Protocol
--   Description : The binary batch format shared with the GPU runner.
--
-- A batch is one file in, one file out. Sending a whole population in a single
-- transfer is the whole point of the design: kernel launches and host/device
-- round trips are what make small batches pointless, so the caller hands over
-- /every/ eligible program and /every/ training case at once (see @GPU.md@ for
-- the arithmetic).
--
-- Layout (all integers little-endian, @u32@ = 32 bits, @u64@ = 64 bits):
--
-- > request:  "HGB1" u32 version=1 u32 nPrograms u32 nCases u32 nArgs
-- >           nPrograms x { u32 nInstr, u32 nConst, u32 maxStack,
-- >                         nInstr x { u32 opcode, u32 arg },
-- >                         nConst x { u32 tag, u64 payload } }
-- >           nCases x nArgs x { u32 tag, u64 payload }
-- >
-- > response: "HGX1" u32 version=1 u32 nPrograms u32 nCases
-- >           nPrograms x nCases x { u32 ok, u32 tag, u64 payload }
--
-- @ok = 0@ means the program crashed on that case (the interpreter's
-- @Nothing@); tag and payload are then meaningless. Results are in
-- program-major order, matching the order the request listed the programs.
--
-- This module is deliberately dependency-free (no @binary@ package): the
-- format is small enough that a few pokes and byte reads are clearer than a
-- serialisation library, and it keeps the number of moving parts low on the C
-- side too.
module Benchmark.Gpu.Protocol
  ( -- * Encoding a request
    encodeBatch,

    -- * Decoding a response
    decodeOutputs,

    -- * Wire-level constants (also documented in /gpu/README.md)
    requestMagic,
    responseMagic,
    wireVersion,
    headerSize,
    requestHeaderSize,
    recordSize,
    valueSize,
    opPushArg,
    opPushConst,
    opBase,
    opCode,
    nonScalarTag,
  )
where

import Data.Bits (shiftL)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Internal as BSI
import qualified Data.ByteString.Lazy as BL
import Data.Char (ord)
import qualified Data.Vector as V
import Data.Word (Word32, Word64, Word8)
import Foreign.Ptr (Ptr)
import Foreign.Storable (pokeByteOff)
import Grammar.Core (Lit (..))
import Grammar.Flat
  ( FlatInstr (..),
    FlatProgram (..),
    bitsFloat,
    floatBits,
    valueBool,
    valueChar,
    valueFloat,
    valueInt,
  )

-- | Version of the wire format. Bump it whenever the layout changes; the
-- runner refuses a request it does not understand instead of misreading it.
wireVersion :: Word32
wireVersion = 1

-- | @\"HGB1\"@ - \"HOTGP batch\".
requestMagic :: Word32
requestMagic = 0x31424748 -- bytes 'H' 'G' 'B' '1'

-- | @\"HGX1\"@ - \"HOTGP results\".
responseMagic :: Word32
responseMagic = 0x31584748 -- bytes 'H' 'G' 'X' '1'

-- | Bytes before the first program record: magic, version and three counts.
requestHeaderSize :: Int
requestHeaderSize = 20

-- | Bytes before the first result record: magic, version and two counts.
headerSize :: Int
headerSize = 16

-- | Size of one response record: @u32 ok, u32 tag, u64 payload@.
recordSize :: Int
recordSize = 16

-- | Size of one value on the wire: @u32 tag + u64 payload@.
valueSize :: Int
valueSize = 12

-- | Tag used for an argument that has no scalar representation (a list, a
-- pair, a lambda). Distinct from every real tag, so the kernel can recognise
-- and reject it.
nonScalarTag :: Word8
nonScalarTag = 0xff

-- * Opcodes
--
-- The first two opcodes are structural; every operator is encoded as
-- @opBase + fromEnum op@, i.e. the position of the constructor in
-- 'Grammar.Core.Operation'. @cbits/gp_flat_kernel.h@ mirrors this table and
-- spells the constructor names out, so a mismatch is visible in review - and
-- the differential test in @test/GpuSpec.hs@ fails if they ever drift.

-- | Push an argument: @arg@ is the index.
opPushArg :: Word32
opPushArg = 0

-- | Push a constant: @arg@ is the index into the constant pool.
opPushConst :: Word32
opPushConst = 1

-- | Offset of the operator opcodes.
opBase :: Word32
opBase = 2

-- | The @(opcode, arg)@ pair an instruction is encoded as.
opCode :: FlatInstr -> (Word32, Word32)
opCode (FPushArg k) = (opPushArg, fromIntegral k)
opCode (FPushConst k) = (opPushConst, fromIntegral k)
opCode (FApply op) = (opBase + fromIntegral (fromEnum op), 0)

-- * Encoding

-- | Serialises a batch: the programs and, for every training case, its
-- program arguments.
--
-- Precondition: every case has the same number of arguments (true by
-- construction, they all come from one dataset), and every program was
-- flattened with that same arity. The runner trusts @nArgs@ from the header.
--
-- The bytes are written straight into a strict 'BS.ByteString' rather than
-- through a 'Data.ByteString.Builder.Builder'. That is not premature
-- micro-optimisation: a single depth-15 program can carry more than 200k
-- instructions, and the builder version spent 1.6 s on one such program,
-- dwarfing everything else in the batch path. The layout is fixed-width, so
-- the size is known up front and the write loop is a couple of pokes per
-- record.
encodeBatch :: [FlatProgram] -> [[Lit]] -> BL.ByteString
encodeBatch programs cases = BL.fromStrict $ BSI.unsafeCreate totalSize writeAll
  where
    nProgs = length programs
    nCases = length cases
    nArgs = case cases of
      (c : _) -> length c
      [] -> 0

    totalSize =
      requestHeaderSize
        + sum [12 + V.length (_flatInstrs p) * 8 + V.length (_flatConsts p) * valueSize | p <- programs]
        + nCases * nArgs * valueSize

    writeAll :: Ptr Word8 -> IO ()
    writeAll ptr = do
      let put32 :: Int -> Word32 -> IO ()
          put32 = pokeByteOff ptr
          put64 :: Int -> Word64 -> IO ()
          put64 = pokeByteOff ptr
          putValue :: Int -> Lit -> IO ()
          putValue o v = put32 o (fromIntegral (tagOf v)) >> put64 (o + 4) (fromIntegral (payloadOf v))

      put32 0 requestMagic
      put32 4 wireVersion
      put32 8 (fromIntegral nProgs)
      put32 12 (fromIntegral nCases)
      put32 16 (fromIntegral nArgs)
      let writePrograms :: Int -> [FlatProgram] -> IO Int
          writePrograms o [] = pure o
          writePrograms o (p : ps) = do
            let instrs = _flatInstrs p
                consts = _flatConsts p
                nInstr = V.length instrs
                nConst = V.length consts
            put32 o (fromIntegral nInstr)
            put32 (o + 4) (fromIntegral nConst)
            put32 (o + 8) (fromIntegral (_flatMaxStack p))
            let goInstr j ioff
                  | j >= nInstr = pure ioff
                  | otherwise = do
                      let (op, arg) = opCode (instrs `V.unsafeIndex` j)
                      put32 ioff op
                      put32 (ioff + 4) arg
                      goInstr (j + 1) (ioff + 8)
                goConst j coff
                  | j >= nConst = pure coff
                  | otherwise = do
                      putValue coff (consts `V.unsafeIndex` j)
                      goConst (j + 1) (coff + valueSize)
            afterInstrs <- goInstr 0 (o + 12)
            afterConsts <- goConst 0 afterInstrs
            writePrograms afterConsts ps

      startCases <- writePrograms requestHeaderSize programs
      let writeCases :: Int -> [[Lit]] -> IO ()
          writeCases _ [] = pure ()
          writeCases o (c : cs) = do
            let goArg j aoff
                  | j >= length c = pure aoff
                  | otherwise = do
                      putValue aoff (c !! j)
                      goArg (j + 1) (aoff + valueSize)
            end <- goArg 0 o
            writeCases end cs
      writeCases startCases cases

    -- Everything that reaches the wire is a scalar: 'flattenTree' rejects
    -- non-scalar constants, and arguments that are not scalars are sent with
    -- the 'nonScalarTag' sentinel - a scalar program never reads them.
    tagOf :: Lit -> Word8
    tagOf (IntLit _) = valueInt
    tagOf (FloatLit _) = valueFloat
    tagOf (BoolLit _) = valueBool
    tagOf (CharLit _) = valueChar
    tagOf _ = nonScalarTag

    payloadOf :: Lit -> Int
    payloadOf (IntLit x) = x
    payloadOf (FloatLit x) = floatBits x
    payloadOf (BoolLit x) = if x then 1 else 0
    payloadOf (CharLit c) = ord c
    payloadOf _ = 0

-- * Decoding

-- | Parses a response into one list of per-case results per program.
--
-- @'Left' reason@ covers a truncated file, a wrong magic or a mismatched
-- program/case count - all of them bugs in the runner or in an incompatible
-- build, never a user error.
decodeOutputs :: BS.ByteString -> Either String [[Maybe Lit]]
decodeOutputs bs
  | BS.length bs < headerSize = Left "truncated response header"
  | magic /= responseMagic = Left $ "bad response magic " <> show magic
  | version /= wireVersion = Left $ "response version " <> show version <> " is not " <> show wireVersion
  | BS.length bs < needed = Left $ "truncated response: " <> show (BS.length bs) <> " bytes, need " <> show needed
  | otherwise =
      Right
        [ [decodeRecord (headerSize + (p * nCases + c) * recordSize) | c <- [0 .. nCases - 1]]
          | p <- [0 .. nProgs - 1]
        ]
  where
    magic = word32At bs 0
    version = word32At bs 4
    nProgs = fromIntegral (word32At bs 8) :: Int
    nCases = fromIntegral (word32At bs 12) :: Int
    needed = headerSize + nProgs * nCases * recordSize

    decodeRecord :: Int -> Maybe Lit
    decodeRecord o
      | ok == 0 = Nothing
      | tag == fromIntegral valueInt = Just $ IntLit (fromIntegral payload)
      | tag == fromIntegral valueFloat = Just $ FloatLit (bitsFloat payload)
      | tag == fromIntegral valueBool = Just $ BoolLit (payload /= 0)
      | otherwise = Just $ CharLit (toEnum payload)
      where
        ok = word32At bs o
        tag = word32At bs (o + 4)
        payload = fromIntegral (word64At bs (o + 8)) :: Int

-- | Little-endian 32-bit read. Callers have already checked the length.
word32At :: BS.ByteString -> Int -> Word32
word32At bs o =
  b0 + (b1 `shiftL` 8) + (b2 `shiftL` 16) + (b3 `shiftL` 24)
  where
    b0, b1, b2, b3 :: Word32
    b0 = fromIntegral (BS.index bs o)
    b1 = fromIntegral (BS.index bs (o + 1))
    b2 = fromIntegral (BS.index bs (o + 2))
    b3 = fromIntegral (BS.index bs (o + 3))

-- | Little-endian 64-bit read.
word64At :: BS.ByteString -> Int -> Word64
word64At bs o = go 0 0
  where
    go :: Int -> Word64 -> Word64
    go k acc
      | k >= 8 = acc
      | otherwise = go (k + 1) (acc + fromIntegral (BS.index bs (o + k)) * (2 ^ (8 * k :: Int)))
