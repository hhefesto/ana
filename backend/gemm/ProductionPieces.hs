{-# LANGUAGE ForeignFunctionInterface #-}
{-# OPTIONS_GHC -Wno-incomplete-uni-patterns -Wno-missing-fields #-}

module ProductionPieces
  ( Context
  , withProductionContext
  , productionPieceOps
  , productionPieceOpsWith
  ) where

import Control.Exception (bracket, onException, throwIO)
import Control.Monad (forM_, when)
import Decomposed (PieceOps (..))
import Foreign
import Foreign.C.String (CString, peekCString)
import Foreign.C.Types (CInt (..))

data CContextConfig
data CContext
data CF32_1d
data CI64_1d

newtype Context = Context (Ptr CContext)
newtype F32Array = F32Array (Ptr CF32_1d)
newtype I64Array = I64Array (Ptr CI64_1d)

-- The updater lets callers add callbacks introduced in PieceOps concurrently,
-- without making this module depend on their types or implementations.
productionPieceOpsWith :: (PieceOps -> PieceOps) -> Context -> PieceOps
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
  }

productionPieceOps :: Context -> PieceOps
productionPieceOps = productionPieceOpsWith id

withProductionContext :: (Context -> IO a) -> IO a
withProductionContext action = bracket newConfig cConfigFree $ \cfg -> do
  bracket (cContextNew cfg) freeContext $ \rawCtx -> do
    whenNull rawCtx "Futhark context allocation failed"
    check rawCtx "Futhark context creation" =<< cContextSync rawCtx
    action (Context rawCtx)
  where
    newConfig = do
      cfg <- cConfigNew
      whenNull cfg "Futhark context config allocation failed"
      pure cfg
    freeContext rawCtx = when (rawCtx /= nullPtr) (cContextFree rawCtx)

rmsForward :: Context -> Int -> Int -> [Float] -> [Float] -> IO [Float]
rmsForward ctx rows dim x gain = withF32s ctx [x, gain] $ \[xArr, gainArr] ->
  output1 ctx "piece_rms_norm_fwd" (rows * dim) $ \[out] ->
    entryPieceRmsNormFwd (rawContext ctx) out (f rows) (f dim) xArr gainArr

rmsBackward :: Context -> Int -> Int -> [Float] -> [Float] -> [Float]
  -> IO ([Float], [Float])
rmsBackward ctx rows dim x gain outputBar =
  withF32s ctx [x, gain, outputBar] $ \[xArr, gainArr, barArr] ->
    output2 ctx "piece_rms_norm_bwd" [rows * dim, dim] $ \[xOut, gainOut] ->
      entryPieceRmsNormBwd (rawContext ctx) xOut gainOut (f rows) (f dim)
        xArr gainArr barArr

l2HeadsForward :: Context -> Int -> Int -> Int -> [Float] -> IO [Float]
l2HeadsForward ctx rows dim heads x = withF32s ctx [x] $ \[xArr] ->
  output1 ctx "piece_l2norm_heads_fwd" (rows * dim) $ \[out] ->
    entryPieceL2HeadsFwd (rawContext ctx) out (f rows) (f dim) (f heads) xArr

l2HeadsBackward :: Context -> Int -> Int -> Int -> [Float] -> [Float] -> IO [Float]
l2HeadsBackward ctx rows dim heads x outputBar =
  withF32s ctx [x, outputBar] $ \[xArr, barArr] ->
    output1 ctx "piece_l2norm_heads_bwd" (rows * dim) $ \[out] ->
      entryPieceL2HeadsBwd (rawContext ctx) out (f rows) (f dim) (f heads)
        xArr barArr

siluGateForward :: Context -> [Float] -> [Float] -> IO [Float]
siluGateForward ctx gate up = withF32s ctx [gate, up] $ \[gateArr, upArr] ->
  output1 ctx "piece_silu_gate_fwd" (length gate) $ \[out] ->
    entryPieceSiluGateFwd (rawContext ctx) out gateArr upArr

siluGateBackward :: Context -> [Float] -> [Float] -> [Float]
  -> IO ([Float], [Float])
siluGateBackward ctx gate up outputBar =
  withF32s ctx [gate, up, outputBar] $ \[gateArr, upArr, barArr] ->
    output2 ctx "piece_silu_gate_bwd" [length gate, length gate] $ \[gateOut, upOut] ->
      entryPieceSiluGateBwd (rawContext ctx) gateOut upOut gateArr upArr barArr

addForward :: Context -> [Float] -> [Float] -> IO [Float]
addForward ctx x y = withF32s ctx [x, y] $ \[xArr, yArr] ->
  output1 ctx "piece_add_fwd" (length x) $ \[out] ->
    entryPieceAddFwd (rawContext ctx) out xArr yArr

addBackward :: Context -> [Float] -> IO ([Float], [Float])
addBackward ctx outputBar = withF32s ctx [outputBar] $ \[barArr] ->
  output2 ctx "piece_add_bwd" [length outputBar, length outputBar] $ \[xOut, yOut] ->
    entryPieceAddBwd (rawContext ctx) xOut yOut barArr

splitHeadsForward :: Context -> Int -> Int -> Int -> Int -> [Float] -> IO [Float]
splitHeadsForward ctx batch n heads headDim x = withF32s ctx [x] $ \[xArr] ->
  output1 ctx "piece_split_heads_fwd" (length x) $ \[out] ->
    entryPieceSplitHeadsFwd (rawContext ctx) out (f batch) (f n) (f heads)
      (f headDim) xArr

splitHeadsBackward :: Context -> Int -> Int -> Int -> Int -> [Float] -> IO [Float]
splitHeadsBackward ctx batch n heads headDim outputBar =
  withF32s ctx [outputBar] $ \[barArr] ->
    output1 ctx "piece_split_heads_bwd" (length outputBar) $ \[out] ->
      entryPieceSplitHeadsBwd (rawContext ctx) out (f batch) (f n) (f heads)
        (f headDim) barArr

mergeHeadsForward :: Context -> Int -> Int -> Int -> Int -> [Float] -> IO [Float]
mergeHeadsForward ctx batch n heads headDim x = withF32s ctx [x] $ \[xArr] ->
  output1 ctx "piece_merge_heads_fwd" (length x) $ \[out] ->
    entryPieceMergeHeadsFwd (rawContext ctx) out (f batch) (f n) (f heads)
      (f headDim) xArr

mergeHeadsBackward :: Context -> Int -> Int -> Int -> Int -> [Float] -> IO [Float]
mergeHeadsBackward ctx batch n heads headDim outputBar =
  withF32s ctx [outputBar] $ \[barArr] ->
    output1 ctx "piece_merge_heads_bwd" (length outputBar) $ \[out] ->
      entryPieceMergeHeadsBwd (rawContext ctx) out (f batch) (f n) (f heads)
        (f headDim) barArr

causalSoftmaxForward :: Context -> Int -> Int -> Int -> [Float] -> IO [Float]
causalSoftmaxForward ctx groups n headDim scores = withF32s ctx [scores] $ \[scoresArr] ->
  output1 ctx "piece_causal_softmax_fwd" (length scores) $ \[out] ->
    entryPieceCausalSoftmaxFwd (rawContext ctx) out (f groups) (f n)
      (f headDim) scoresArr

causalSoftmaxBackward :: Context -> Int -> Int -> Int -> [Float] -> [Float]
  -> IO [Float]
causalSoftmaxBackward ctx groups n headDim scores weightsBar =
  withF32s ctx [scores, weightsBar] $ \[scoresArr, barArr] ->
    output1 ctx "piece_causal_softmax_bwd" (length scores) $ \[out] ->
      entryPieceCausalSoftmaxBwd (rawContext ctx) out (f groups) (f n)
        (f headDim) scoresArr barArr

gateCumForward :: Context -> Int -> Int -> Int -> [Float] -> IO ([Float], [Float])
gateCumForward ctx groups chunk headDim gateLogits =
  withF32s ctx [gateLogits] $ \[gateArr] ->
    output2 ctx "piece_gate_cum_fwd"
      [groups * chunk * headDim, groups * headDim] $ \[relOut, decOut] ->
        entryPieceGateCumFwd (rawContext ctx) relOut decOut (f groups) (f chunk)
          (f headDim) gateArr

gateCumBackward :: Context -> Int -> Int -> Int -> [Float] -> [Float] -> [Float]
  -> IO [Float]
gateCumBackward ctx groups chunk headDim gateLogits relBar decBar =
  withF32s ctx [gateLogits, relBar, decBar] $ \[gateArr, relArr, decArr] ->
    output1 ctx "piece_gate_cum_bwd" (groups * chunk * headDim) $ \[out] ->
      entryPieceGateCumBwd (rawContext ctx) out (f groups) (f chunk) (f headDim)
        gateArr relArr decArr

qkDecayForward :: Context -> Int -> Int -> Int -> [Float] -> [Float] -> [Float]
  -> [Float] -> IO ([Float], [Float])
qkDecayForward ctx groups chunk headDim q k rel dec =
  withF32s ctx [q, k, rel, dec] $ \[qArr, kArr, relArr, decArr] ->
    let count = groups * chunk * headDim
    in output2 ctx "piece_qk_decay_fwd" [count, count] $ \[qOut, kOut] ->
      entryPieceQkDecayFwd (rawContext ctx) qOut kOut (f groups) (f chunk)
        (f headDim) qArr kArr relArr decArr

qkDecayBackward :: Context -> Int -> Int -> Int -> [Float] -> [Float] -> [Float]
  -> [Float] -> [Float] -> [Float] -> IO ([Float], [Float], [Float], [Float])
qkDecayBackward ctx groups chunk headDim q k rel dec qBar kBar =
  withF32s ctx [q, k, rel, dec, qBar, kBar] $
    \[qArr, kArr, relArr, decArr, qBarArr, kBarArr] ->
      let count = groups * chunk * headDim
      in output4 ctx "piece_qk_decay_bwd"
        [count, count, count, groups * headDim] $ \[qOut, kOut, relOut, decOut] ->
          entryPieceQkDecayBwd (rawContext ctx) qOut kOut relOut decOut
            (f groups) (f chunk) (f headDim) qArr kArr relArr decArr qBarArr kBarArr

glaIntraForward :: Context -> Int -> Int -> Int -> [Float] -> [Float] -> [Float]
  -> [Float] -> IO [Float]
glaIntraForward ctx groups chunk headDim q k values rel =
  withF32s ctx [q, k, values, rel] $ \[qArr, kArr, valuesArr, relArr] ->
    output1 ctx "piece_gla_intra_fwd" (groups * chunk * headDim) $ \[out] ->
      entryPieceGlaIntraFwd (rawContext ctx) out (f groups) (f chunk) (f headDim)
        qArr kArr valuesArr relArr

glaIntraBackward :: Context -> Int -> Int -> Int -> [Float] -> [Float] -> [Float]
  -> [Float] -> [Float] -> IO ([Float], [Float], [Float], [Float])
glaIntraBackward ctx groups chunk headDim q k values rel outputBar =
  withF32s ctx [q, k, values, rel, outputBar] $
    \[qArr, kArr, valuesArr, relArr, barArr] ->
      let count = groups * chunk * headDim
      in output4 ctx "piece_gla_intra_bwd" (replicate 4 count) $
        \[qOut, kOut, valuesOut, relOut] ->
          entryPieceGlaIntraBwd (rawContext ctx) qOut kOut valuesOut relOut
            (f groups) (f chunk) (f headDim) qArr kArr valuesArr relArr barArr

stateAdvanceForward :: Context -> Int -> Int -> [Float] -> [Float] -> [Float]
  -> IO [Float]
stateAdvanceForward ctx groups headDim state contribution dec =
  withF32s ctx [state, contribution, dec] $ \[stateArr, contributionArr, decArr] ->
    output1 ctx "piece_state_advance_fwd" (groups * headDim * headDim) $ \[out] ->
      entryPieceStateAdvanceFwd (rawContext ctx) out (f groups) (f headDim)
        stateArr contributionArr decArr

stateAdvanceBackward :: Context -> Int -> Int -> [Float] -> [Float] -> [Float]
  -> [Float] -> IO ([Float], [Float], [Float])
stateAdvanceBackward ctx groups headDim state contribution dec outputBar =
  withF32s ctx [state, contribution, dec, outputBar] $
    \[stateArr, contributionArr, decArr, barArr] ->
      let stateCount = groups * headDim * headDim
      in output3 ctx "piece_state_advance_bwd"
        [stateCount, stateCount, groups * headDim] $ \[stateOut, contributionOut, decOut] ->
          entryPieceStateAdvanceBwd (rawContext ctx) stateOut contributionOut decOut
            (f groups) (f headDim) stateArr contributionArr decArr barArr

embeddingGather :: Context -> Int -> Int -> [Float] -> [Int64] -> IO [Float]
embeddingGather ctx vocab dim embedding tokens =
  withF32s ctx [embedding] $ \[embeddingArr] -> withI64 ctx tokens $ \tokensArr ->
    output1 ctx "piece_embed_gather_fwd" (length tokens * dim) $ \[out] ->
      entryPieceEmbedGatherFwd (rawContext ctx) out (f vocab) (f dim)
        (f (length tokens)) embeddingArr tokensArr

embeddingBackward :: Context -> Int -> Int -> [Int64] -> [Float] -> IO [Float]
embeddingBackward ctx vocab dim tokens outputBar =
  withI64 ctx tokens $ \tokensArr -> withF32s ctx [outputBar] $ \[barArr] ->
    output1 ctx "piece_embed_gather_bwd" (vocab * dim) $ \[out] ->
      entryPieceEmbedGatherBwd (rawContext ctx) out (f vocab) (f dim)
        (f (length tokens)) tokensArr barArr

ceForward :: Context -> Int -> Int -> Int -> Int -> [Float] -> [Int64] -> IO Float
ceForward ctx batch sequenceLength vocab effectiveBatch logits tokens =
  withF32s ctx [logits] $ \[logitsArr] -> withI64 ctx tokens $ \tokensArr ->
    alloca $ \out -> do
      entryPieceCeFwd (rawContext ctx) out (f batch) (f sequenceLength) (f vocab)
        (f effectiveBatch) logitsArr tokensArr >>= check (rawContext ctx) "piece_ce_fwd"
      sync ctx "piece_ce_fwd"
      peek out

ceBackward :: Context -> Int -> Int -> Int -> Int -> Float -> [Float] -> [Int64]
  -> IO [Float]
ceBackward ctx batch sequenceLength vocab effectiveBatch seed logits tokens =
  withF32s ctx [logits] $ \[logitsArr] -> withI64 ctx tokens $ \tokensArr ->
    output1 ctx "piece_ce_bwd" (batch * sequenceLength * vocab) $ \[out] ->
      entryPieceCeBwd (rawContext ctx) out (f batch) (f sequenceLength) (f vocab)
        (f effectiveBatch) seed logitsArr tokensArr

withF32s :: Context -> [[Float]] -> ([Ptr CF32_1d] -> IO a) -> IO a
withF32s _ [] action = action []
withF32s ctx (values : rest) action =
  bracket (uploadF32 ctx values) (freeF32 ctx) $ \(F32Array arr) ->
    withF32s ctx rest (action . (arr :))

withI64 :: Context -> [Int64] -> (Ptr CI64_1d -> IO a) -> IO a
withI64 ctx values action = bracket (uploadI64 ctx values) (freeI64 ctx) $ \(I64Array arr) ->
  action arr

uploadF32 :: Context -> [Float] -> IO F32Array
uploadF32 ctx values = withArray values $ \host -> do
  arr <- cNewF32 (rawContext ctx) host (f (length values))
  whenNull arr "upload f32[1] returned null"
  sync ctx "upload f32[1]" `onException` (cFreeF32 (rawContext ctx) arr >> pure ())
  pure (F32Array arr)

uploadI64 :: Context -> [Int64] -> IO I64Array
uploadI64 ctx values = withArray values $ \host -> do
  arr <- cNewI64 (rawContext ctx) host (f (length values))
  whenNull arr "upload i64[1] returned null"
  sync ctx "upload i64[1]" `onException` (cFreeI64 (rawContext ctx) arr >> pure ())
  pure (I64Array arr)

freeF32 :: Context -> F32Array -> IO ()
freeF32 ctx (F32Array arr) = cFreeF32 (rawContext ctx) arr >>= check (rawContext ctx) "free f32[1]"

freeI64 :: Context -> I64Array -> IO ()
freeI64 ctx (I64Array arr) = cFreeI64 (rawContext ctx) arr >>= check (rawContext ctx) "free i64[1]"

output1 :: Context -> String -> Int -> ([Ptr (Ptr CF32_1d)] -> IO CInt) -> IO [Float]
output1 ctx label count entry = do
  values <- arrayOutputs ctx label [count] entry
  case values of
    [a] -> pure a
    _ -> internalOutputCount label

output2 :: Context -> String -> [Int] -> ([Ptr (Ptr CF32_1d)] -> IO CInt)
  -> IO ([Float], [Float])
output2 ctx label counts entry = do
  values <- arrayOutputs ctx label counts entry
  case values of
    [a, b] -> pure (a, b)
    _ -> internalOutputCount label

output3 :: Context -> String -> [Int] -> ([Ptr (Ptr CF32_1d)] -> IO CInt)
  -> IO ([Float], [Float], [Float])
output3 ctx label counts entry = do
  values <- arrayOutputs ctx label counts entry
  case values of
    [a, b, c] -> pure (a, b, c)
    _ -> internalOutputCount label

output4 :: Context -> String -> [Int] -> ([Ptr (Ptr CF32_1d)] -> IO CInt)
  -> IO ([Float], [Float], [Float], [Float])
output4 ctx label counts entry = do
  values <- arrayOutputs ctx label counts entry
  case values of
    [a, b, c, d] -> pure (a, b, c, d)
    _ -> internalOutputCount label

arrayOutputs :: Context -> String -> [Int] -> ([Ptr (Ptr CF32_1d)] -> IO CInt)
  -> IO [[Float]]
arrayOutputs ctx label counts entry = allocaArray (length counts) $ \slots -> do
  pokeArray slots (replicate (length counts) nullPtr)
  let outputSlots = [slots `advancePtr` i | i <- [0 .. length counts - 1]]
  status <- entry outputSlots
  arrays <- peekArray (length counts) slots
  bracket (pure arrays) (mapM_ (freeOutput ctx label)) $ \owned -> do
    check (rawContext ctx) label status
    forM_ owned $ \arr -> whenNull arr (label ++ " returned a null array")
    sync ctx label
    sequence (zipWith (downloadF32 ctx label) counts owned)

downloadF32 :: Context -> String -> Int -> Ptr CF32_1d -> IO [Float]
downloadF32 ctx label count arr = allocaArray count $ \host -> do
  cValuesF32 (rawContext ctx) arr host >>= check (rawContext ctx) (label ++ " download")
  sync ctx (label ++ " download")
  peekArray count host

freeOutput :: Context -> String -> Ptr CF32_1d -> IO ()
freeOutput ctx label arr = when (arr /= nullPtr) $
  cFreeF32 (rawContext ctx) arr >>= check (rawContext ctx) (label ++ " output free")

sync :: Context -> String -> IO ()
sync ctx label = cContextSync (rawContext ctx) >>= check (rawContext ctx) (label ++ " sync")

rawContext :: Context -> Ptr CContext
rawContext (Context ctx) = ctx

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

foreign import ccall unsafe "futhark_context_config_new" cConfigNew :: IO (Ptr CContextConfig)
foreign import ccall unsafe "futhark_context_config_free" cConfigFree :: Ptr CContextConfig -> IO ()
foreign import ccall safe "futhark_context_new" cContextNew :: Ptr CContextConfig -> IO (Ptr CContext)
foreign import ccall safe "futhark_context_free" cContextFree :: Ptr CContext -> IO ()
foreign import ccall unsafe "futhark_context_get_error" cContextGetError :: Ptr CContext -> IO CString
foreign import ccall safe "futhark_context_sync" cContextSync :: Ptr CContext -> IO CInt

foreign import ccall safe "futhark_new_f32_1d" cNewF32 :: Ptr CContext -> Ptr Float -> Int64 -> IO (Ptr CF32_1d)
foreign import ccall safe "futhark_new_i64_1d" cNewI64 :: Ptr CContext -> Ptr Int64 -> Int64 -> IO (Ptr CI64_1d)
foreign import ccall safe "futhark_values_f32_1d" cValuesF32 :: Ptr CContext -> Ptr CF32_1d -> Ptr Float -> IO CInt
foreign import ccall safe "futhark_free_f32_1d" cFreeF32 :: Ptr CContext -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_free_i64_1d" cFreeI64 :: Ptr CContext -> Ptr CI64_1d -> IO CInt

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
