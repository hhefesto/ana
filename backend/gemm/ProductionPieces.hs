{-# LANGUAGE ForeignFunctionInterface #-}
{-# OPTIONS_GHC -Wno-incomplete-uni-patterns -Wno-missing-fields #-}

-- Device-resident piece layer: every op maps Futhark device handles to
-- Futhark device handles with no host staging.  Ownership: all model memory
-- is Futhark-owned (allocated by entries, freed by futhark_free_f32_1d);
-- cuBLAS only reads raw pointers and writes into fresh zero_vector outputs.
-- Ordering follows the conservative ownership-transfer contract with
-- dirty-flag elision: pending cuBLAS work is synchronized before any Futhark
-- entry, host read, or free; pending Futhark work is synchronized before a
-- GEMM is enqueued.
module ProductionPieces
  ( Context
  , CContext
  , CF32_1d
  , CI64_1d
  , CBool_1d
  , DevF32 (..)
  , DevI64 (..)
  , withProductionContext
  , productionPieceOps
  , productionPieceOpsWith
  , rawContext
  , uploadF32
  , downloadF32
  , uploadF32Vector
  , downloadF32Vector
  , freeF32
  , uploadI64
  , freeI64
  , uploadBool
  , uploadBoolVector
  , freeBool
  , deviceZeros
  , deviceRawPointer
  , deviceAccumulate
  , deviceClipGlobalNorm
  , deviceAdamwStep
  , deviceMuonStep
  , pushArena
  , popArenaKeeping
  , markFutharkDirty
  , syncFutharkIfDirty
  , markBlasDirty
  , syncBlasIfDirty
  , syncDevice
  , traceOp
  ) where

import Arena (arenaForget, arenaPop, arenaPush, arenaRegister)
import Control.Exception (bracket, onException, throwIO)
import Control.Monad (forM_, unless, when)
import CudaBlasOps (cublasContextSync)
import Data.IORef
import Data.Int (Int64)
import qualified Data.Vector.Storable as VS
import qualified Data.Vector.Storable.Mutable as VSM
import qualified Data.Vector.Unboxed as VU
import Data.Word (Word64, Word8)
import Decomposed (PieceOps (..))
import Foreign
import Foreign.C.String (CString, peekCString, withCString)
import Foreign.C.Types (CInt (..))
import GHC.Float (double2Float, float2Double)
import System.Environment (lookupEnv)
import System.IO (hFlush, hPutStrLn, stderr)
import System.IO.Unsafe (unsafePerformIO)

data CContextConfig
data CContext
data CF32_1d
data CI64_1d
data CBool_1d

-- ctxArena is a stack of windows, innermost first; [] means no window is
-- open. Nesting is what lets a layer's intermediates be reclaimed as the
-- traversal advances instead of at the end of the whole micro-batch.
data Context = Context
  { rawContext :: !(Ptr CContext)
  , ctxArena :: !(IORef [[Ptr CF32_1d]])
  , ctxFutharkDirty :: !(IORef Bool)
  , ctxBlasDirty :: !(IORef Bool)
  }

-- A device f32 vector: the Futhark array handle plus its element count, so
-- the host traversal can check shapes without touching device data.
data DevF32 = DevF32 !(Ptr CF32_1d) !Int

-- A device token vector: flat i64 handle plus its element count.
data DevI64 = DevI64 !(Ptr CI64_1d) !Int

-- The updater lets callers add callbacks introduced in PieceOps concurrently,
-- without making this module depend on their types or implementations.
productionPieceOpsWith
  :: (PieceOps DevF32 DevI64 -> PieceOps DevF32 DevI64)
  -> Context
  -> PieceOps DevF32 DevI64
productionPieceOpsWith extend ctx = extend PieceOps
  { opsRmsForward = rmsForward ctx
  , opsRmsBackward = rmsBackward ctx
  , opsL2HeadsForward = l2HeadsForward ctx
  , opsL2HeadsBackward = l2HeadsBackward ctx
  , opsSiluGateForward = siluGateForward ctx
  , opsSiluGateBackward = siluGateBackward ctx
  , opsAddForward = addForward ctx
  , opsAddBackward = addBackward ctx
  , opsSplitHeadsForward = splitHeadsForward ctx
  , opsSplitHeadsBackward = splitHeadsBackward ctx
  , opsMergeHeadsForward = mergeHeadsForward ctx
  , opsMergeHeadsBackward = mergeHeadsBackward ctx
  , opsCausalSoftmaxForward = causalSoftmaxForward ctx
  , opsCausalSoftmaxBackward = causalSoftmaxBackward ctx
  , opsGateCumForward = gateCumForward ctx
  , opsGateCumBackward = gateCumBackward ctx
  , opsGateCumLogsForward = gateCumLogsForward ctx
  , opsGateCumLogsBackward = gateCumLogsBackward ctx
  , opsRglruLogGateForward = rglruLogGateForward ctx
  , opsRglruLogGateBackward = rglruLogGateBackward ctx
  , opsRglruWriteScaleForward = rglruWriteScaleForward ctx
  , opsRglruWriteScaleBackward = rglruWriteScaleBackward ctx
  , opsQkNormForward = qkNormForward ctx
  , opsQkNormBackward = qkNormBackward ctx
  , opsCausalSoftmaxSinkForward = causalSoftmaxSinkForward ctx
  , opsCausalSoftmaxSinkBackward = causalSoftmaxSinkBackward ctx
  , opsQkDecayForward = qkDecayForward ctx
  , opsQkDecayBackward = qkDecayBackward ctx
  , opsGlaIntraForward = glaIntraForward ctx
  , opsGlaIntraBackward = glaIntraBackward ctx
  , opsStateAdvanceForward = stateAdvanceForward ctx
  , opsStateAdvanceBackward = stateAdvanceBackward ctx
  , opsEmbeddingGather = embeddingGather ctx
  , opsEmbeddingBackward = embeddingBackward ctx
  , opsCeForward = ceForward ctx
  , opsCeBackward = ceBackward ctx
  , opsZeros = deviceZeros ctx
  , opsLength = \(DevF32 _ count) -> count
  , opsTokenCount = \(DevI64 _ count) -> count
  , opsFree = freeF32 ctx
  , opsScope = \action -> do
      pushArena ctx
      (result, survivors) <- action `onException` popArenaKeeping ctx []
      popArenaKeeping ctx survivors
      pure result
  , opsReadSlice = readSlice ctx
  , opsWriteSlice = writeSlice ctx
  , opsConcat = concatPair ctx
  , opsGatherChunk = gatherChunkDevice ctx
  , opsPutChunk = putChunkDevice ctx
  }

productionPieceOps :: Context -> PieceOps DevF32 DevI64
productionPieceOps = productionPieceOpsWith id

withProductionContext :: (Context -> IO a) -> IO a
withProductionContext action = bracket newConfig cConfigFree $ \cfg -> do
  bracket (cContextNew cfg) freeContext $ \rawCtx -> do
    whenNull rawCtx "Futhark context allocation failed"
    check rawCtx "Futhark context creation" =<< cContextSync rawCtx
    arena <- newIORef []
    futharkDirty <- newIORef False
    blasDirty <- newIORef False
    action (Context rawCtx arena futharkDirty blasDirty)
  where
    newConfig = do
      cfg <- cConfigNew
      whenNull cfg "Futhark context config allocation failed"
      profile <- lookupEnv "FUT_PROFILE"
      when (profile == Just "1") (cConfigSetProfiling cfg 1)
      -- The CUDA backend compiles its embedded kernel source with NVRTC at
      -- context creation.  FutharkKernels honours FUT_CACHE for the fused
      -- trainer and deploy/train-cloud.sh exports it unconditionally, but this
      -- module never read it -- so every process start of the production GEMM
      -- trainer recompiled the whole pieces module from scratch, silently, with
      -- the environment variable set and doing nothing.
      cachePath <- lookupEnv "FUT_CACHE"
      case cachePath of
        Nothing -> pure ()
        Just path -> withCString path (cConfigSetCacheFile cfg)
      pure cfg
    freeContext rawCtx = when (rawCtx /= nullPtr) $ do
      -- FUT_PROFILE=1: dump the runtime's per-kernel totals before the
      -- context goes away; the where-does-the-step-time-go diagnostic.
      profile <- lookupEnv "FUT_PROFILE"
      when (profile == Just "1") $ do
        report <- cContextReport rawCtx
        unless (report == nullPtr) $ do
          hPutStrLn stderr =<< peekCString report
          hFlush stderr
          free report
      cContextFree rawCtx

-- Arena: device intermediates allocated between pushArena and popArenaKeeping
-- are freed at pop, except the survivors. Pending cuBLAS work is completed
-- before anything is freed. Uploads and entry outputs outside a window are
-- caller-owned.
pushArena :: Context -> IO ()
pushArena ctx = modifyIORef' (ctxArena ctx) arenaPush

-- The policy lives in Arena; this enacts it.  Pending work is completed
-- before anything is released, because a GEMM may still be reading a buffer
-- the frame is about to free.
popArenaKeeping :: Context -> [DevF32] -> IO ()
popArenaKeeping ctx survivors = do
  frames <- readIORef (ctxArena ctx)
  let kept = [pointer | DevF32 pointer _ <- survivors]
  case arenaPop kept frames of
    Nothing -> throwIO (userError "device arena pop without a window")
    Just (stack, released) -> do
      syncDevice ctx
      writeIORef (ctxArena ctx) stack
      forM_ released $ \pointer ->
        cFreeF32 (rawContext ctx) pointer
          >>= check (rawContext ctx) "arena free f32[1]"

registerArena :: Context -> Ptr CF32_1d -> IO ()
registerArena ctx pointer = modifyIORef' (ctxArena ctx) (arenaRegister pointer)

markFutharkDirty :: Context -> IO ()
markFutharkDirty ctx = writeIORef (ctxFutharkDirty ctx) True

-- Under GEMM_ORDERING=stream the cuBLAS queue is the legacy default stream
-- of the shared CUDA context, so the device itself orders GEMMs against
-- Futhark kernels; the per-boundary host barriers below become no-ops.
-- Host reads, uploads, and the arena/timing boundaries keep their own
-- unconditional synchronization (sync/syncDevice call sites).
{-# NOINLINE streamOrdered #-}
streamOrdered :: Bool
streamOrdered = unsafePerformIO ((== Just "stream") <$> lookupEnv "GEMM_ORDERING")

syncFutharkIfDirty :: Context -> IO ()
syncFutharkIfDirty ctx = unless streamOrdered $ do
  dirty <- readIORef (ctxFutharkDirty ctx)
  when dirty $ do
    traceOp "sync futhark begin"
    sync ctx "pending Futhark work"
    traceOp "sync futhark end"
    writeIORef (ctxFutharkDirty ctx) False

markBlasDirty :: Context -> IO ()
markBlasDirty ctx = writeIORef (ctxBlasDirty ctx) True

syncBlasIfDirty :: Context -> IO ()
syncBlasIfDirty ctx = unless streamOrdered $ do
  dirty <- readIORef (ctxBlasDirty ctx)
  when dirty $ do
    traceOp "sync blas begin"
    cublasContextSync
    traceOp "sync blas end"
    writeIORef (ctxBlasDirty ctx) False

-- Completes all pending work on both queues regardless of ordering mode:
-- the arena free boundary, the bench timing boundary, and the end-of-step
-- barrier.  Syncing the legacy stream then the Futhark stream covers every
-- enqueue order under both contracts.
syncDevice :: Context -> IO ()
syncDevice ctx = do
  traceOp "sync device begin"
  cublasContextSync
  sync ctx "device sync"
  traceOp "sync device end"
  writeIORef (ctxBlasDirty ctx) False
  writeIORef (ctxFutharkDirty ctx) False

rmsForward :: Context -> Int -> Int -> DevF32 -> DevF32 -> IO DevF32
rmsForward ctx rows dim (DevF32 x _) (DevF32 gain _) =
  output1 ctx "piece_rms_norm_fwd" (rows * dim) $ \[out] ->
    entryPieceRmsNormFwd (rawContext ctx) out (f rows) (f dim) x gain

rmsBackward :: Context -> Int -> Int -> DevF32 -> DevF32 -> DevF32
  -> IO (DevF32, DevF32)
rmsBackward ctx rows dim (DevF32 x _) (DevF32 gain _) (DevF32 bar _) =
  output2 ctx "piece_rms_norm_bwd" [rows * dim, dim] $ \[xOut, gainOut] ->
    entryPieceRmsNormBwd (rawContext ctx) xOut gainOut (f rows) (f dim)
      x gain bar

l2HeadsForward :: Context -> Int -> Int -> Int -> DevF32 -> IO DevF32
l2HeadsForward ctx rows dim heads (DevF32 x _) =
  output1 ctx "piece_l2norm_heads_fwd" (rows * dim) $ \[out] ->
    entryPieceL2HeadsFwd (rawContext ctx) out (f rows) (f dim) (f heads) x

l2HeadsBackward :: Context -> Int -> Int -> Int -> DevF32 -> DevF32 -> IO DevF32
l2HeadsBackward ctx rows dim heads (DevF32 x _) (DevF32 bar _) =
  output1 ctx "piece_l2norm_heads_bwd" (rows * dim) $ \[out] ->
    entryPieceL2HeadsBwd (rawContext ctx) out (f rows) (f dim) (f heads) x bar

siluGateForward :: Context -> DevF32 -> DevF32 -> IO DevF32
siluGateForward ctx (DevF32 gate count) (DevF32 up _) =
  output1 ctx "piece_silu_gate_fwd" count $ \[out] ->
    entryPieceSiluGateFwd (rawContext ctx) out gate up

siluGateBackward :: Context -> DevF32 -> DevF32 -> DevF32
  -> IO (DevF32, DevF32)
siluGateBackward ctx (DevF32 gate count) (DevF32 up _) (DevF32 bar _) =
  output2 ctx "piece_silu_gate_bwd" [count, count] $ \[gateOut, upOut] ->
    entryPieceSiluGateBwd (rawContext ctx) gateOut upOut gate up bar

addForward :: Context -> DevF32 -> DevF32 -> IO DevF32
addForward ctx (DevF32 x count) (DevF32 y _) =
  output1 ctx "piece_add_fwd" count $ \[out] ->
    entryPieceAddFwd (rawContext ctx) out x y

addBackward :: Context -> DevF32 -> IO (DevF32, DevF32)
addBackward ctx (DevF32 bar count) =
  output2 ctx "piece_add_bwd" [count, count] $ \[xOut, yOut] ->
    entryPieceAddBwd (rawContext ctx) xOut yOut bar

splitHeadsForward :: Context -> Int -> Int -> Int -> Int -> DevF32 -> IO DevF32
splitHeadsForward ctx batch n heads headDim (DevF32 x count) =
  output1 ctx "piece_split_heads_fwd" count $ \[out] ->
    entryPieceSplitHeadsFwd (rawContext ctx) out (f batch) (f n) (f heads)
      (f headDim) x

splitHeadsBackward :: Context -> Int -> Int -> Int -> Int -> DevF32 -> IO DevF32
splitHeadsBackward ctx batch n heads headDim (DevF32 bar count) =
  output1 ctx "piece_split_heads_bwd" count $ \[out] ->
    entryPieceSplitHeadsBwd (rawContext ctx) out (f batch) (f n) (f heads)
      (f headDim) bar

mergeHeadsForward :: Context -> Int -> Int -> Int -> Int -> DevF32 -> IO DevF32
mergeHeadsForward ctx batch n heads headDim (DevF32 x count) =
  output1 ctx "piece_merge_heads_fwd" count $ \[out] ->
    entryPieceMergeHeadsFwd (rawContext ctx) out (f batch) (f n) (f heads)
      (f headDim) x

mergeHeadsBackward :: Context -> Int -> Int -> Int -> Int -> DevF32 -> IO DevF32
mergeHeadsBackward ctx batch n heads headDim (DevF32 bar count) =
  output1 ctx "piece_merge_heads_bwd" count $ \[out] ->
    entryPieceMergeHeadsBwd (rawContext ctx) out (f batch) (f n) (f heads)
      (f headDim) bar

causalSoftmaxForward :: Context -> Int -> Int -> Int -> DevF32 -> IO DevF32
causalSoftmaxForward ctx groups n headDim (DevF32 scores count) =
  output1 ctx "piece_causal_softmax_fwd" count $ \[out] ->
    entryPieceCausalSoftmaxFwd (rawContext ctx) out (f groups) (f n)
      (f headDim) scores

causalSoftmaxBackward :: Context -> Int -> Int -> Int -> DevF32 -> DevF32
  -> IO DevF32
causalSoftmaxBackward ctx groups n headDim (DevF32 scores count) (DevF32 bar _) =
  output1 ctx "piece_causal_softmax_bwd" count $ \[out] ->
    entryPieceCausalSoftmaxBwd (rawContext ctx) out (f groups) (f n)
      (f headDim) scores bar

gateCumForward :: Context -> Int -> Int -> Int -> DevF32 -> IO (DevF32, DevF32)
gateCumForward ctx groups chunk headDim (DevF32 gate _) =
  output2 ctx "piece_gate_cum_fwd"
    [groups * chunk * headDim, groups * headDim] $ \[relOut, decOut] ->
      entryPieceGateCumFwd (rawContext ctx) relOut decOut (f groups) (f chunk)
        (f headDim) gate

gateCumBackward :: Context -> Int -> Int -> Int -> DevF32 -> DevF32 -> DevF32
  -> IO DevF32
gateCumBackward ctx groups chunk headDim (DevF32 gate _) (DevF32 rel _)
    (DevF32 dec _) =
  output1 ctx "piece_gate_cum_bwd" (groups * chunk * headDim) $ \[out] ->
    entryPieceGateCumBwd (rawContext ctx) out (f groups) (f chunk) (f headDim)
      gate rel dec

gateCumLogsForward :: Context -> Int -> Int -> Int -> DevF32 -> IO (DevF32, DevF32)
gateCumLogsForward ctx groups chunk headDim (DevF32 logs _) =
  output2 ctx "piece_gate_cum_logs_fwd"
    [groups * chunk * headDim, groups * headDim] $ \[relOut, decOut] ->
      entryPieceGateCumLogsFwd (rawContext ctx) relOut decOut (f groups)
        (f chunk) (f headDim) logs

gateCumLogsBackward :: Context -> Int -> Int -> Int -> DevF32 -> DevF32 -> DevF32
  -> IO DevF32
gateCumLogsBackward ctx groups chunk headDim (DevF32 logs _) (DevF32 rel _)
    (DevF32 dec _) =
  output1 ctx "piece_gate_cum_logs_bwd" (groups * chunk * headDim) $ \[out] ->
    entryPieceGateCumLogsBwd (rawContext ctx) out (f groups) (f chunk)
      (f headDim) logs rel dec

rglruLogGateForward :: Context -> Int -> Int -> DevF32 -> DevF32 -> IO DevF32
rglruLogGateForward ctx rows dim (DevF32 z _) (DevF32 lam _) =
  output1 ctx "piece_rglru_log_gate_fwd" (rows * dim) $ \[out] ->
    entryPieceRglruLogGateFwd (rawContext ctx) out (f rows) (f dim) z lam

rglruLogGateBackward :: Context -> Int -> Int -> DevF32 -> DevF32 -> DevF32
  -> IO (DevF32, DevF32)
rglruLogGateBackward ctx rows dim (DevF32 z _) (DevF32 lam _) (DevF32 bar _) =
  output2 ctx "piece_rglru_log_gate_bwd" [rows * dim, dim] $ \[zOut, lamOut] ->
    entryPieceRglruLogGateBwd (rawContext ctx) zOut lamOut (f rows) (f dim)
      z lam bar

rglruWriteScaleForward :: Context -> DevF32 -> DevF32 -> IO DevF32
rglruWriteScaleForward ctx (DevF32 logs count) (DevF32 k _) =
  output1 ctx "piece_rglru_write_scale_fwd" count $ \[out] ->
    entryPieceRglruWriteScaleFwd (rawContext ctx) out logs k

rglruWriteScaleBackward :: Context -> DevF32 -> DevF32 -> DevF32
  -> IO (DevF32, DevF32)
rglruWriteScaleBackward ctx (DevF32 logs count) (DevF32 k _) (DevF32 bar _) =
  output2 ctx "piece_rglru_write_scale_bwd" [count, count] $ \[logsOut, kOut] ->
    entryPieceRglruWriteScaleBwd (rawContext ctx) logsOut kOut logs k bar

qkNormForward :: Context -> Int -> Int -> Int -> DevF32 -> DevF32 -> IO DevF32
qkNormForward ctx rows dim heads (DevF32 x _) (DevF32 gain _) =
  output1 ctx "piece_qk_norm_fwd" (rows * dim) $ \[out] ->
    entryPieceQkNormFwd (rawContext ctx) out (f rows) (f dim) (f heads) x gain

qkNormBackward :: Context -> Int -> Int -> Int -> DevF32 -> DevF32 -> DevF32
  -> IO (DevF32, DevF32)
qkNormBackward ctx rows dim heads (DevF32 x _) (DevF32 gain _) (DevF32 bar _) =
  output2 ctx "piece_qk_norm_bwd" [rows * dim, dim `div` heads] $
    \[xOut, gainOut] ->
      entryPieceQkNormBwd (rawContext ctx) xOut gainOut (f rows) (f dim)
        (f heads) x gain bar

causalSoftmaxSinkForward :: Context -> Int -> Int -> Int -> Int -> DevF32
  -> DevF32 -> IO DevF32
causalSoftmaxSinkForward ctx groups n headDim heads (DevF32 scores count)
    (DevF32 sinks _) =
  output1 ctx "piece_causal_softmax_sink_fwd" count $ \[out] ->
    entryPieceCausalSoftmaxSinkFwd (rawContext ctx) out (f groups) (f n)
      (f headDim) (f heads) scores sinks

causalSoftmaxSinkBackward :: Context -> Int -> Int -> Int -> Int -> DevF32
  -> DevF32 -> DevF32 -> IO (DevF32, DevF32)
causalSoftmaxSinkBackward ctx groups n headDim heads (DevF32 scores count)
    (DevF32 sinks _) (DevF32 bar _) =
  output2 ctx "piece_causal_softmax_sink_bwd" [count, heads] $
    \[scoresOut, sinksOut] ->
      entryPieceCausalSoftmaxSinkBwd (rawContext ctx) scoresOut sinksOut
        (f groups) (f n) (f headDim) (f heads) scores sinks bar

qkDecayForward :: Context -> Int -> Int -> Int -> DevF32 -> DevF32 -> DevF32
  -> DevF32 -> IO (DevF32, DevF32)
qkDecayForward ctx groups chunk headDim (DevF32 q _) (DevF32 k _)
    (DevF32 rel _) (DevF32 dec _) =
  let count = groups * chunk * headDim
  in output2 ctx "piece_qk_decay_fwd" [count, count] $ \[qOut, kOut] ->
    entryPieceQkDecayFwd (rawContext ctx) qOut kOut (f groups) (f chunk)
      (f headDim) q k rel dec

qkDecayBackward :: Context -> Int -> Int -> Int -> DevF32 -> DevF32 -> DevF32
  -> DevF32 -> DevF32 -> DevF32 -> IO (DevF32, DevF32, DevF32, DevF32)
qkDecayBackward ctx groups chunk headDim (DevF32 q _) (DevF32 k _)
    (DevF32 rel _) (DevF32 dec _) (DevF32 qBar _) (DevF32 kBar _) =
  let count = groups * chunk * headDim
  in output4 ctx "piece_qk_decay_bwd"
    [count, count, count, groups * headDim] $ \[qOut, kOut, relOut, decOut] ->
      entryPieceQkDecayBwd (rawContext ctx) qOut kOut relOut decOut
        (f groups) (f chunk) (f headDim) q k rel dec qBar kBar

glaIntraForward :: Context -> Int -> Int -> Int -> DevF32 -> DevF32 -> DevF32
  -> DevF32 -> IO DevF32
glaIntraForward ctx groups chunk headDim (DevF32 q _) (DevF32 k _)
    (DevF32 values _) (DevF32 rel _) =
  output1 ctx "piece_gla_intra_fwd" (groups * chunk * headDim) $ \[out] ->
    entryPieceGlaIntraFwd (rawContext ctx) out (f groups) (f chunk) (f headDim)
      q k values rel

glaIntraBackward :: Context -> Int -> Int -> Int -> DevF32 -> DevF32 -> DevF32
  -> DevF32 -> DevF32 -> IO (DevF32, DevF32, DevF32, DevF32)
glaIntraBackward ctx groups chunk headDim (DevF32 q _) (DevF32 k _)
    (DevF32 values _) (DevF32 rel _) (DevF32 bar _) =
  let count = groups * chunk * headDim
  in output4 ctx "piece_gla_intra_bwd" (replicate 4 count) $
    \[qOut, kOut, valuesOut, relOut] ->
      entryPieceGlaIntraBwd (rawContext ctx) qOut kOut valuesOut relOut
        (f groups) (f chunk) (f headDim) q k values rel bar

stateAdvanceForward :: Context -> Int -> Int -> DevF32 -> DevF32 -> DevF32
  -> IO DevF32
stateAdvanceForward ctx groups headDim (DevF32 state _)
    (DevF32 contribution _) (DevF32 dec _) =
  output1 ctx "piece_state_advance_fwd" (groups * headDim * headDim) $ \[out] ->
    entryPieceStateAdvanceFwd (rawContext ctx) out (f groups) (f headDim)
      state contribution dec

stateAdvanceBackward :: Context -> Int -> Int -> DevF32 -> DevF32 -> DevF32
  -> DevF32 -> IO (DevF32, DevF32, DevF32)
stateAdvanceBackward ctx groups headDim (DevF32 state _)
    (DevF32 contribution _) (DevF32 dec _) (DevF32 bar _) =
  let stateCount = groups * headDim * headDim
  in output3 ctx "piece_state_advance_bwd"
    [stateCount, stateCount, groups * headDim] $
      \[stateOut, contributionOut, decOut] ->
        entryPieceStateAdvanceBwd (rawContext ctx) stateOut contributionOut
          decOut (f groups) (f headDim) state contribution dec bar

embeddingGather :: Context -> Int -> Int -> DevF32 -> DevI64 -> IO DevF32
embeddingGather ctx vocab dim (DevF32 embedding _) (DevI64 tokens count) =
  output1 ctx "piece_embed_gather_fwd" (count * dim) $ \[out] ->
    entryPieceEmbedGatherFwd (rawContext ctx) out (f vocab) (f dim)
      (f count) embedding tokens

embeddingBackward :: Context -> Int -> Int -> DevI64 -> DevF32 -> IO DevF32
embeddingBackward ctx vocab dim (DevI64 tokens count) (DevF32 bar _) =
  output1 ctx "piece_embed_gather_bwd" (vocab * dim) $ \[out] ->
    entryPieceEmbedGatherBwd (rawContext ctx) out (f vocab) (f dim)
      (f count) tokens bar

ceForward :: Context -> Int -> Int -> Int -> Int -> DevF32 -> DevI64 -> IO Float
ceForward ctx batch sequenceLength vocab effectiveBatch (DevF32 logits _)
    (DevI64 tokens _) = do
  traceOp "entry piece_ce_fwd"
  syncBlasIfDirty ctx
  alloca $ \out -> do
    entryPieceCeFwd (rawContext ctx) out (f batch) (f sequenceLength) (f vocab)
      (f effectiveBatch) logits tokens >>= check (rawContext ctx) "piece_ce_fwd"
    traceOp "entry piece_ce_fwd returned"
    sync ctx "piece_ce_fwd"
    writeIORef (ctxFutharkDirty ctx) False
    peek out

ceBackward :: Context -> Int -> Int -> Int -> Int -> Float -> DevF32 -> DevI64
  -> IO DevF32
ceBackward ctx batch sequenceLength vocab effectiveBatch seed (DevF32 logits _)
    (DevI64 tokens _) =
  output1 ctx "piece_ce_bwd" (batch * sequenceLength * vocab) $ \[out] ->
    entryPieceCeBwd (rawContext ctx) out (f batch) (f sequenceLength) (f vocab)
      (f effectiveBatch) seed logits tokens

deviceZeros :: Context -> Int -> IO DevF32
deviceZeros ctx count =
  output1 ctx "zero_vector" count $ \[out] ->
    entryZeroVector (rawContext ctx) out (f count)

readSlice :: Context -> Int -> Int -> DevF32 -> IO DevF32
readSlice ctx offset count (DevF32 source n) =
  output1 ctx "piece_read_slice" count $ \[out] ->
    entryPieceReadSlice (rawContext ctx) out (f n) (f offset) (f count) source

writeSlice :: Context -> Int -> DevF32 -> DevF32 -> IO DevF32
writeSlice ctx offset (DevF32 destination n) (DevF32 source m) =
  output1 ctx "piece_write_slice" n $ \[out] ->
    entryPieceWriteSlice (rawContext ctx) out (f n) (f m) (f offset)
      destination source

concatPair :: Context -> DevF32 -> DevF32 -> IO DevF32
concatPair ctx (DevF32 a n) (DevF32 b m) =
  output1 ctx "piece_concat" (n + m) $ \[out] ->
    entryPieceConcat (rawContext ctx) out (f n) (f m) a b

gatherChunkDevice :: Context -> Int -> Int -> Int -> Int -> DevF32 -> IO DevF32
gatherChunkDevice ctx groups chunkCount elements chunkIndex (DevF32 values _) =
  output1 ctx "piece_gather_chunk" (groups * elements) $ \[out] ->
    entryPieceGatherChunk (rawContext ctx) out (f groups) (f chunkCount)
      (f elements) (f chunkIndex) values

putChunkDevice :: Context -> Int -> Int -> Int -> Int -> DevF32 -> DevF32
  -> IO DevF32
putChunkDevice ctx groups chunkCount elements chunkIndex
    (DevF32 destination total) (DevF32 source _) =
  output1 ctx "piece_put_chunk" total $ \[out] ->
    entryPiecePutChunk (rawContext ctx) out (f groups) (f chunkCount)
      (f elements) (f chunkIndex) destination source

deviceAccumulate :: Context -> DevF32 -> DevF32 -> IO DevF32
deviceAccumulate ctx (DevF32 accumulator count) (DevF32 addition _) =
  output1 ctx "piece_accumulate" count $ \[out] ->
    entryPieceAccumulate (rawContext ctx) out accumulator addition

-- Returns the pre-clip norm (a host scalar, so this synchronizes) and the
-- scaled gradient.
deviceClipGlobalNorm :: Context -> Float -> DevF32 -> IO (Float, DevF32)
deviceClipGlobalNorm ctx maxNorm (DevF32 gradient count) = do
  syncBlasIfDirty ctx
  alloca $ \normOut -> allocaArray 1 $ \slots -> do
    pokeArray slots [nullPtr]
    status <- entryClipGlobalNorm (rawContext ctx) normOut slots maxNorm gradient
    scaled <- peekArray 1 slots
    check (rawContext ctx) "clip_global_norm" status
      `onException` mapM_ (freeIfNonNull ctx) scaled
    forM_ scaled $ \arr -> whenNull arr "clip_global_norm returned a null array"
    sync ctx "clip_global_norm"
    writeIORef (ctxFutharkDirty ctx) False
    let [scaledArr] = scaled
    registerArenaIfActive ctx scaledArr
    norm <- peek normOut
    pure (norm, DevF32 scaledArr count)

deviceAdamwStep
  :: Context -> Int64 -> Float -> Float -> Float -> Float -> Float
  -> DevF32 -> DevF32 -> DevF32 -> DevF32 -> Ptr CBool_1d
  -> IO (DevF32, DevF32, DevF32)
deviceAdamwStep ctx step learningRate beta1 beta2 epsilon weightDecay
    (DevF32 params count) (DevF32 gradient _) (DevF32 firstMoment _)
    (DevF32 secondMoment _) mask =
  output3 ctx "adamw_step" [count, count, count] $ \[paramsOut, mOut, vOut] ->
    entryAdamwStep (rawContext ctx) paramsOut mOut vOut step learningRate
      beta1 beta2 epsilon weightDecay params gradient firstMoment secondMoment
      mask

-- One combined Muon/AdamW update (muon_step in pieces.fut delegates to the
-- same muon_step_def the fused backends run).  Returns
-- (params', momentum', firstMoment', secondMoment').
deviceMuonStep
  :: Context -> Int64 -> Float -> Float -> Float -> Float -> Float -> Float
  -> DevF32 -> DevF32 -> DevF32 -> DevF32 -> DevF32
  -> Ptr CBool_1d -> Ptr CBool_1d -> DevI64 -> DevI64 -> DevI64
  -> IO (DevF32, DevF32, DevF32, DevF32)
deviceMuonStep ctx step learningRate beta1 beta2 epsilon weightDecay muonBeta
    (DevF32 params count) (DevF32 gradient _) (DevF32 momentum _)
    (DevF32 firstMoment _) (DevF32 secondMoment _) decayMask muonMask
    (DevI64 offs _) (DevI64 rows _) (DevI64 cols _) =
  output4 ctx "muon_step" [count, count, count, count] $
    \[paramsOut, momentumOut, mOut, vOut] ->
      entryMuonStep (rawContext ctx) paramsOut momentumOut mOut vOut step
        learningRate beta1 beta2 epsilon weightDecay muonBeta params gradient
        momentum firstMoment secondMoment decayMask muonMask offs rows cols

-- The raw device pointer backing a Futhark array, for the cuBLAS boundary.
-- The wrapper and its Futhark owner must stay live through both barriers;
-- host code never dereferences it.
deviceRawPointer :: Context -> DevF32 -> IO Word64
deviceRawPointer ctx (DevF32 arr _) = cValuesRawF32 (rawContext ctx) arr

uploadF32 :: Context -> [Float] -> IO DevF32
uploadF32 ctx values = do
  traceOp ("upload f32 count=" ++ show (length values))
  syncBlasIfDirty ctx
  withArray values $ \host -> do
    arr <- cNewF32 (rawContext ctx) host (f (length values))
    whenNull arr "upload f32[1] returned null"
    sync ctx "upload f32[1]" `onException` (cFreeF32 (rawContext ctx) arr >> pure ())
    registerArenaIfActive ctx arr
    pure (DevF32 arr (length values))

uploadI64 :: Context -> [Int64] -> IO DevI64
uploadI64 ctx values = do
  syncBlasIfDirty ctx
  withArray values $ \host -> do
    arr <- cNewI64 (rawContext ctx) host (f (length values))
    whenNull arr "upload i64[1] returned null"
    sync ctx "upload i64[1]" `onException` (cFreeI64 (rawContext ctx) arr >> pure ())
    pure (DevI64 arr (length values))

uploadBool :: Context -> [Bool] -> IO (Ptr CBool_1d)
uploadBool ctx values = do
  syncBlasIfDirty ctx
  withArray (map (\b -> if b then 1 else 0 :: Word8) values) $ \host -> do
    arr <- cNewBool (rawContext ctx) host (f (length values))
    whenNull arr "upload bool[1] returned null"
    sync ctx "upload bool[1]"
      `onException` (cFreeBool (rawContext ctx) arr >> pure ())
    pure arr

downloadF32 :: Context -> DevF32 -> IO [Float]
downloadF32 ctx (DevF32 arr count) = do
  syncBlasIfDirty ctx
  syncFutharkIfDirty ctx
  allocaArray count $ \host -> do
    cValuesF32 (rawContext ctx) arr host
      >>= check (rawContext ctx) "download f32[1]"
    sync ctx "download f32[1]"
    peekArray count host

-- Parameter-sized transfers stage through a storable f32 vector instead of a
-- boxed [Float]: 4 bytes an element rather than 40, which at 115M parameters
-- is 462 MB against 4.6 GB. See the same pair in FutharkKernels.

uploadF32Vector :: Context -> VU.Vector Double -> IO DevF32
uploadF32Vector ctx values = do
  let count = VU.length values
      staged = VS.generate count (double2Float . VU.unsafeIndex values)
  traceOp ("upload f32 count=" ++ show count)
  syncBlasIfDirty ctx
  VS.unsafeWith staged $ \host -> do
    arr <- cNewF32 (rawContext ctx) host (f count)
    whenNull arr "upload f32[1] returned null"
    sync ctx "upload f32[1]" `onException` (cFreeF32 (rawContext ctx) arr >> pure ())
    registerArenaIfActive ctx arr
    pure (DevF32 arr count)

downloadF32Vector :: Context -> DevF32 -> IO (VU.Vector Double)
downloadF32Vector ctx (DevF32 arr count) = do
  syncBlasIfDirty ctx
  syncFutharkIfDirty ctx
  staged <- VSM.new count
  VSM.unsafeWith staged $ \host -> do
    cValuesF32 (rawContext ctx) arr host
      >>= check (rawContext ctx) "download f32[1]"
    sync ctx "download f32[1]"
  frozen <- VS.unsafeFreeze staged
  pure (VU.generate count (float2Double . VS.unsafeIndex frozen))

uploadBoolVector :: Context -> VU.Vector Bool -> IO (Ptr CBool_1d)
uploadBoolVector ctx values = do
  let count = VU.length values
      staged = VS.generate count (\i -> if VU.unsafeIndex values i then 1 else 0 :: Word8)
  syncBlasIfDirty ctx
  VS.unsafeWith staged $ \host -> do
    arr <- cNewBool (rawContext ctx) host (f count)
    whenNull arr "upload bool[1] returned null"
    sync ctx "upload bool[1]"
      `onException` (cFreeBool (rawContext ctx) arr >> pure ())
    pure arr

freeF32 :: Context -> DevF32 -> IO ()
freeF32 ctx (DevF32 arr _) = do
  syncBlasIfDirty ctx
  syncFutharkIfDirty ctx
  -- Deregister from every open window before freeing, so a later pop does
  -- not free the same pointer a second time.
  modifyIORef' (ctxArena ctx) (arenaForget arr)
  cFreeF32 (rawContext ctx) arr >>= check (rawContext ctx) "free f32[1]"

freeI64 :: Context -> DevI64 -> IO ()
freeI64 ctx (DevI64 arr _) =
  cFreeI64 (rawContext ctx) arr >>= check (rawContext ctx) "free i64[1]"

freeBool :: Context -> Ptr CBool_1d -> IO ()
freeBool ctx arr =
  cFreeBool (rawContext ctx) arr >>= check (rawContext ctx) "free bool[1]"

registerArenaIfActive :: Context -> Ptr CF32_1d -> IO ()
registerArenaIfActive ctx pointer = do
  frames <- readIORef (ctxArena ctx)
  unless (null frames) (registerArena ctx pointer)

freeIfNonNull :: Context -> Ptr CF32_1d -> IO ()
freeIfNonNull ctx arr = when (arr /= nullPtr) $
  cFreeF32 (rawContext ctx) arr >>= check (rawContext ctx) "output free"

output1 :: Context -> String -> Int -> ([Ptr (Ptr CF32_1d)] -> IO CInt)
  -> IO DevF32
output1 ctx label count entry = do
  values <- deviceOutputs ctx label [count] entry
  case values of
    [a] -> pure a
    _ -> internalOutputCount label

output2 :: Context -> String -> [Int] -> ([Ptr (Ptr CF32_1d)] -> IO CInt)
  -> IO (DevF32, DevF32)
output2 ctx label counts entry = do
  values <- deviceOutputs ctx label counts entry
  case values of
    [a, b] -> pure (a, b)
    _ -> internalOutputCount label

output3 :: Context -> String -> [Int] -> ([Ptr (Ptr CF32_1d)] -> IO CInt)
  -> IO (DevF32, DevF32, DevF32)
output3 ctx label counts entry = do
  values <- deviceOutputs ctx label counts entry
  case values of
    [a, b, c] -> pure (a, b, c)
    _ -> internalOutputCount label

output4 :: Context -> String -> [Int] -> ([Ptr (Ptr CF32_1d)] -> IO CInt)
  -> IO (DevF32, DevF32, DevF32, DevF32)
output4 ctx label counts entry = do
  values <- deviceOutputs ctx label counts entry
  case values of
    [a, b, c, d] -> pure (a, b, c, d)
    _ -> internalOutputCount label

-- Runs one entry handle-to-handle: complete pending cuBLAS work first (its
-- outputs may be entry inputs), invoke, wrap the outputs, and leave the queue
-- asynchronous with the dirty flag set. Errors from the asynchronous queue
-- surface at the next synchronizing operation, attributed there.
deviceOutputs :: Context -> String -> [Int] -> ([Ptr (Ptr CF32_1d)] -> IO CInt)
  -> IO [DevF32]
deviceOutputs ctx label counts entry = do
  traceOp ("entry " ++ label ++ " counts=" ++ show counts)
  syncBlasIfDirty ctx
  allocaArray (length counts) $ \slots -> do
    pokeArray slots (replicate (length counts) nullPtr)
    let outputSlots = [slots `advancePtr` i | i <- [0 .. length counts - 1]]
    status <- entry outputSlots
    traceOp ("entry " ++ label ++ " returned")
    arrays <- peekArray (length counts) slots
    check (rawContext ctx) label status
      `onException` mapM_ (freeIfNonNull ctx) arrays
    forM_ arrays $ \arr -> whenNull arr (label ++ " returned a null array")
    markFutharkDirty ctx
    mapM_ (registerArenaIfActive ctx) arrays
    pure (zipWith DevF32 arrays counts)

sync :: Context -> String -> IO ()
sync ctx label = cContextSync (rawContext ctx) >>= check (rawContext ctx) (label ++ " sync")

f :: Integral a => Int -> a
f = fromIntegral

internalOutputCount :: String -> IO a
internalOutputCount label = throwIO (userError (label ++ ": internal output count mismatch"))

check :: Ptr CContext -> String -> CInt -> IO ()
check ctx label status
  | status == 0 = pure ()
  | otherwise = do
      err <- cContextGetError ctx
      detail <- if err == nullPtr then pure "unknown Futhark error" else peekCString err
      throwIO (userError (label ++ " failed: " ++ detail))

whenNull :: Ptr a -> String -> IO ()
whenNull ptr message = when (ptr == nullPtr) (throwIO (userError message))

{-# NOINLINE traceEnabled #-}
traceEnabled :: Bool
traceEnabled = unsafePerformIO ((== Just "1") <$> lookupEnv "GEMM_TRACE")

-- One flushed stderr line per launched op under GEMM_TRACE=1: the hang
-- diagnostic. A tail ending in "entry X counts=..." with no "returned" means
-- X blocked inside the entry (allocation-triggered internal sync); a "sync
-- ... begin" with no "end" names the barrier that never completed.
traceOp :: String -> IO ()
traceOp message = when traceEnabled $ do
  hPutStrLn stderr ("gemm-trace " ++ message)
  hFlush stderr

foreign import ccall unsafe "futhark_context_config_new" cConfigNew :: IO (Ptr CContextConfig)
foreign import ccall unsafe "futhark_context_config_free" cConfigFree :: Ptr CContextConfig -> IO ()
foreign import ccall unsafe "futhark_context_config_set_profiling" cConfigSetProfiling :: Ptr CContextConfig -> CInt -> IO ()
foreign import ccall unsafe "futhark_context_config_set_cache_file" cConfigSetCacheFile :: Ptr CContextConfig -> CString -> IO ()
foreign import ccall safe "futhark_context_report" cContextReport :: Ptr CContext -> IO CString
foreign import ccall safe "futhark_context_new" cContextNew :: Ptr CContextConfig -> IO (Ptr CContext)
foreign import ccall safe "futhark_context_free" cContextFree :: Ptr CContext -> IO ()
foreign import ccall unsafe "futhark_context_get_error" cContextGetError :: Ptr CContext -> IO CString
foreign import ccall safe "futhark_context_sync" cContextSync :: Ptr CContext -> IO CInt

foreign import ccall safe "futhark_new_f32_1d" cNewF32 :: Ptr CContext -> Ptr Float -> Int64 -> IO (Ptr CF32_1d)
foreign import ccall safe "futhark_new_i64_1d" cNewI64 :: Ptr CContext -> Ptr Int64 -> Int64 -> IO (Ptr CI64_1d)
foreign import ccall safe "futhark_new_bool_1d" cNewBool :: Ptr CContext -> Ptr Word8 -> Int64 -> IO (Ptr CBool_1d)
foreign import ccall safe "futhark_values_f32_1d" cValuesF32 :: Ptr CContext -> Ptr CF32_1d -> Ptr Float -> IO CInt
foreign import ccall unsafe "futhark_values_raw_f32_1d" cValuesRawF32 :: Ptr CContext -> Ptr CF32_1d -> IO Word64
foreign import ccall safe "futhark_free_f32_1d" cFreeF32 :: Ptr CContext -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_free_i64_1d" cFreeI64 :: Ptr CContext -> Ptr CI64_1d -> IO CInt
foreign import ccall safe "futhark_free_bool_1d" cFreeBool :: Ptr CContext -> Ptr CBool_1d -> IO CInt

foreign import ccall safe "futhark_entry_piece_rms_norm_fwd" entryPieceRmsNormFwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Ptr CF32_1d -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_piece_rms_norm_bwd" entryPieceRmsNormBwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Ptr CF32_1d -> Ptr CF32_1d -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_piece_l2norm_heads_fwd" entryPieceL2HeadsFwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Int64 -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_piece_l2norm_heads_bwd" entryPieceL2HeadsBwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Int64 -> Ptr CF32_1d -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_piece_silu_gate_fwd" entryPieceSiluGateFwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Ptr CF32_1d -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_piece_silu_gate_bwd" entryPieceSiluGateBwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Ptr (Ptr CF32_1d) -> Ptr CF32_1d -> Ptr CF32_1d -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_piece_add_fwd" entryPieceAddFwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Ptr CF32_1d -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_piece_add_bwd" entryPieceAddBwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Ptr (Ptr CF32_1d) -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_piece_split_heads_fwd" entryPieceSplitHeadsFwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Int64 -> Int64 -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_piece_split_heads_bwd" entryPieceSplitHeadsBwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Int64 -> Int64 -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_piece_merge_heads_fwd" entryPieceMergeHeadsFwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Int64 -> Int64 -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_piece_merge_heads_bwd" entryPieceMergeHeadsBwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Int64 -> Int64 -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_piece_causal_softmax_fwd" entryPieceCausalSoftmaxFwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Int64 -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_piece_causal_softmax_bwd" entryPieceCausalSoftmaxBwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Int64 -> Ptr CF32_1d -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_piece_gate_cum_fwd" entryPieceGateCumFwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Int64 -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_piece_gate_cum_bwd" entryPieceGateCumBwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Int64 -> Ptr CF32_1d -> Ptr CF32_1d -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_piece_gate_cum_logs_fwd" entryPieceGateCumLogsFwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Int64 -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_piece_gate_cum_logs_bwd" entryPieceGateCumLogsBwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Int64 -> Ptr CF32_1d -> Ptr CF32_1d -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_piece_rglru_log_gate_fwd" entryPieceRglruLogGateFwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Ptr CF32_1d -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_piece_rglru_log_gate_bwd" entryPieceRglruLogGateBwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Ptr CF32_1d -> Ptr CF32_1d -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_piece_rglru_write_scale_fwd" entryPieceRglruWriteScaleFwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Ptr CF32_1d -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_piece_rglru_write_scale_bwd" entryPieceRglruWriteScaleBwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Ptr (Ptr CF32_1d) -> Ptr CF32_1d -> Ptr CF32_1d -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_piece_qk_norm_fwd" entryPieceQkNormFwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Int64 -> Ptr CF32_1d -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_piece_qk_norm_bwd" entryPieceQkNormBwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Int64 -> Ptr CF32_1d -> Ptr CF32_1d -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_piece_causal_softmax_sink_fwd" entryPieceCausalSoftmaxSinkFwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Int64 -> Int64 -> Ptr CF32_1d -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_piece_causal_softmax_sink_bwd" entryPieceCausalSoftmaxSinkBwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Int64 -> Int64 -> Ptr CF32_1d -> Ptr CF32_1d -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_muon_step" entryMuonStep :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Ptr (Ptr CF32_1d) -> Ptr (Ptr CF32_1d) -> Ptr (Ptr CF32_1d) -> Int64 -> Float -> Float -> Float -> Float -> Float -> Float -> Ptr CF32_1d -> Ptr CF32_1d -> Ptr CF32_1d -> Ptr CF32_1d -> Ptr CF32_1d -> Ptr CBool_1d -> Ptr CBool_1d -> Ptr CI64_1d -> Ptr CI64_1d -> Ptr CI64_1d -> IO CInt
foreign import ccall safe "futhark_entry_piece_qk_decay_fwd" entryPieceQkDecayFwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Int64 -> Ptr CF32_1d -> Ptr CF32_1d -> Ptr CF32_1d -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_piece_qk_decay_bwd" entryPieceQkDecayBwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Ptr (Ptr CF32_1d) -> Ptr (Ptr CF32_1d) -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Int64 -> Ptr CF32_1d -> Ptr CF32_1d -> Ptr CF32_1d -> Ptr CF32_1d -> Ptr CF32_1d -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_piece_gla_intra_fwd" entryPieceGlaIntraFwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Int64 -> Ptr CF32_1d -> Ptr CF32_1d -> Ptr CF32_1d -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_piece_gla_intra_bwd" entryPieceGlaIntraBwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Ptr (Ptr CF32_1d) -> Ptr (Ptr CF32_1d) -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Int64 -> Ptr CF32_1d -> Ptr CF32_1d -> Ptr CF32_1d -> Ptr CF32_1d -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_piece_state_advance_fwd" entryPieceStateAdvanceFwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Ptr CF32_1d -> Ptr CF32_1d -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_piece_state_advance_bwd" entryPieceStateAdvanceBwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Ptr (Ptr CF32_1d) -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Ptr CF32_1d -> Ptr CF32_1d -> Ptr CF32_1d -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_piece_embed_gather_fwd" entryPieceEmbedGatherFwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Int64 -> Ptr CF32_1d -> Ptr CI64_1d -> IO CInt
foreign import ccall safe "futhark_entry_piece_embed_gather_bwd" entryPieceEmbedGatherBwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Int64 -> Ptr CI64_1d -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_piece_ce_fwd" entryPieceCeFwd :: Ptr CContext -> Ptr Float -> Int64 -> Int64 -> Int64 -> Int64 -> Ptr CF32_1d -> Ptr CI64_1d -> IO CInt
foreign import ccall safe "futhark_entry_piece_ce_bwd" entryPieceCeBwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Int64 -> Int64 -> Float -> Ptr CF32_1d -> Ptr CI64_1d -> IO CInt
foreign import ccall safe "futhark_entry_piece_accumulate" entryPieceAccumulate :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Ptr CF32_1d -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_zero_vector" entryZeroVector :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Int64 -> IO CInt
foreign import ccall safe "futhark_entry_clip_global_norm" entryClipGlobalNorm :: Ptr CContext -> Ptr Float -> Ptr (Ptr CF32_1d) -> Float -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_adamw_step" entryAdamwStep :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Ptr (Ptr CF32_1d) -> Ptr (Ptr CF32_1d) -> Int64 -> Float -> Float -> Float -> Float -> Float -> Ptr CF32_1d -> Ptr CF32_1d -> Ptr CF32_1d -> Ptr CF32_1d -> Ptr CBool_1d -> IO CInt
foreign import ccall safe "futhark_entry_piece_read_slice" entryPieceReadSlice :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Int64 -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_piece_write_slice" entryPieceWriteSlice :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Int64 -> Ptr CF32_1d -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_piece_concat" entryPieceConcat :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Ptr CF32_1d -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_piece_gather_chunk" entryPieceGatherChunk :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Int64 -> Int64 -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_piece_put_chunk" entryPiecePutChunk :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Int64 -> Int64 -> Ptr CF32_1d -> Ptr CF32_1d -> IO CInt
