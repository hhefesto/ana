{-# LANGUAGE ForeignFunctionInterface #-}

module PiecesConformance
  ( Context
  , F32Array
  , I64Array
  , withContext
  , withF32
  , withI64
  , downloadF32
  , oracleParameterCount
  , oracleLogits
  , oracleBatchLossGrad
  , pieceCeLoss
  , pieceCeGradient
  , pieceEmbeddingScatter
  , pieceEmbeddingGather
  , pieceRmsNorm
  , pieceRmsNormBackward
  , pieceL2NormHeads
  , pieceL2NormHeadsBackward
  , pieceSiluGate
  , pieceSiluGateBackward
  , pieceAdd
  , pieceAddBackward
  , pieceSplitHeads
  , pieceSplitHeadsBackward
  , pieceMergeHeads
  , pieceMergeHeadsBackward
  , pieceCausalSoftmax
  , pieceCausalSoftmaxBackward
  , pieceGateCum
  , pieceGateCumBackward
  , pieceQkDecay
  , pieceQkDecayBackward
  , pieceGlaIntra
  , pieceGlaIntraBackward
  , pieceStateAdvance
  , pieceStateAdvanceBackward
  ) where

import Control.Exception (bracket, throwIO)
import Foreign
import Foreign.C.String (CString, peekCString)
import Foreign.C.Types

data CContextConfig
data CContext
data CF32_1d
data CI64_1d

newtype Context = Context (Ptr CContext)
newtype F32Array = F32Array (Ptr CF32_1d)
newtype I64Array = I64Array (Ptr CI64_1d)

withContext :: (Context -> IO a) -> IO a
withContext action = bracket c_config_new c_config_free $ \cfg -> do
  whenNull cfg "Futhark context config allocation failed"
  bracket (c_context_new cfg) freeContext $ \ctx -> do
    whenNull ctx "Futhark context allocation failed"
    err <- c_context_get_error ctx
    if err == nullPtr
      then action (Context ctx)
      else peekCString err >>= throwIO . userError . ("Futhark context creation failed: " ++)
  where
    freeContext ctx = if ctx == nullPtr then pure () else c_context_free ctx

withF32 :: Context -> [Float] -> (F32Array -> IO a) -> IO a
withF32 ctx values = bracket (uploadF32 ctx values) (freeF32 ctx)

withI64 :: Context -> [Int64] -> (I64Array -> IO a) -> IO a
withI64 ctx values = bracket (uploadI64 ctx values) (freeI64 ctx)

uploadF32 :: Context -> [Float] -> IO F32Array
uploadF32 (Context ctx) values = withArray values $ \ptr ->
  checkedPtr ctx "upload f32[1]" (c_new_f32_1d ctx ptr (fromIntegral (length values))) F32Array

uploadI64 :: Context -> [Int64] -> IO I64Array
uploadI64 (Context ctx) values = withArray values $ \ptr ->
  checkedPtr ctx "upload i64[1]" (c_new_i64_1d ctx ptr (fromIntegral (length values))) I64Array

downloadF32 :: Context -> Int -> F32Array -> IO [Float]
downloadF32 (Context ctx) count (F32Array arr) = allocaArray count $ \ptr -> do
  c_values_f32_1d ctx arr ptr >>= check ctx "download f32[1]"
  peekArray count ptr

freeF32 :: Context -> F32Array -> IO ()
freeF32 (Context ctx) (F32Array arr) = c_free_f32_1d ctx arr >>= check ctx "free f32[1]"

freeI64 :: Context -> I64Array -> IO ()
freeI64 (Context ctx) (I64Array arr) = c_free_i64_1d ctx arr >>= check ctx "free i64[1]"

oracleParameterCount :: Context -> Int64 -> Int64 -> Int64 -> Int64 -> IO Int64
oracleParameterCount (Context ctx) vocab dim ff layers = alloca $ \out -> do
  entry_oracle_n_params ctx out vocab dim ff layers >>= check ctx "oracle_n_params"
  c_context_sync ctx >>= check ctx "oracle_n_params sync"
  peek out

oracleLogits :: Context -> Int -> Int64 -> Int64 -> Int64 -> Int64 -> Int64 -> Int64 -> F32Array -> I64Array -> IO [Float]
oracleLogits (Context ctx) sequenceLength vocab dim ff heads layers chunk (F32Array params) (I64Array tokens) = alloca $ \out -> do
  entry_oracle_logits ctx out vocab dim ff heads layers chunk params tokens >>= check ctx "oracle_logits"
  c_context_sync ctx >>= check ctx "oracle_logits sync"
  arr <- F32Array <$> peek out
  bracket (pure arr) (freeF32 (Context ctx)) (downloadF32 (Context ctx) (sequenceLength * fromIntegral vocab))

oracleBatchLossGrad :: Context -> Int64 -> Int64 -> Int64 -> Int64 -> Int64 -> Int64 -> Int64 -> Int64 -> F32Array -> I64Array -> IO (Float, [Float])
oracleBatchLossGrad (Context ctx) batch sequenceLength vocab dim ff heads layers chunk (F32Array params) (I64Array tokens) =
  alloca $ \loss -> alloca $ \gradient -> do
    entry_oracle_batch_loss_grad ctx loss gradient batch sequenceLength vocab dim ff heads layers chunk params tokens
      >>= check ctx "oracle_batch_loss_grad"
    c_context_sync ctx >>= check ctx "oracle_batch_loss_grad sync"
    gradientArr <- F32Array <$> peek gradient
    count <- fromIntegral <$> oracleParameterCount (Context ctx) vocab dim ff layers
    values <- bracket (pure gradientArr) (freeF32 (Context ctx))
      (downloadF32 (Context ctx) count)
    (, values) <$> peek loss

pieceCeLoss :: Context -> Int64 -> Int64 -> Int64 -> Int64 -> F32Array -> I64Array -> IO Float
pieceCeLoss (Context ctx) batch sequenceLength vocab effectiveBatch (F32Array logits) (I64Array tokens) = alloca $ \out -> do
  entry_conf_piece_ce_fwd ctx out batch sequenceLength vocab effectiveBatch logits tokens >>= check ctx "conf_piece_ce_fwd"
  c_context_sync ctx >>= check ctx "piece_ce_fwd sync"
  peek out

pieceCeGradient :: Context -> Int -> Int64 -> Int64 -> Int64 -> Int64 -> Float -> F32Array -> I64Array -> IO [Float]
pieceCeGradient (Context ctx) count batch sequenceLength vocab effectiveBatch seed (F32Array logits) (I64Array tokens) = alloca $ \out -> do
  entry_conf_piece_ce_bwd ctx out batch sequenceLength vocab effectiveBatch seed logits tokens >>= check ctx "conf_piece_ce_bwd"
  c_context_sync ctx >>= check ctx "piece_ce_bwd sync"
  arr <- F32Array <$> peek out
  bracket (pure arr) (freeF32 (Context ctx)) (downloadF32 (Context ctx) count)

pieceEmbeddingScatter :: Context -> Int -> Int64 -> Int64 -> Int64 -> I64Array -> F32Array -> IO [Float]
pieceEmbeddingScatter (Context ctx) count vocab dim tokenCount (I64Array tokens) (F32Array outputBar) = alloca $ \out -> do
  entry_conf_piece_embed_gather_bwd ctx out vocab dim tokenCount tokens outputBar >>= check ctx "conf_piece_embed_gather_bwd"
  c_context_sync ctx >>= check ctx "piece_embed_gather_bwd sync"
  arr <- F32Array <$> peek out
  bracket (pure arr) (freeF32 (Context ctx)) (downloadF32 (Context ctx) count)

pieceEmbeddingGather :: Context -> Int -> Int64 -> Int64 -> Int64 -> F32Array -> I64Array -> IO [Float]
pieceEmbeddingGather (Context ctx) outputCount vocab dim tokenCount (F32Array embedding) (I64Array tokens) = alloca $ \out -> do
  entry_conf_piece_embed_gather_fwd ctx out vocab dim tokenCount embedding tokens
    >>= check ctx "conf_piece_embed_gather_fwd"
  c_context_sync ctx >>= check ctx "piece_embed_gather_fwd sync"
  arr <- F32Array <$> peek out
  bracket (pure arr) (freeF32 (Context ctx)) (downloadF32 (Context ctx) outputCount)

pieceRmsNorm :: Context -> Int -> Int64 -> Int64 -> F32Array -> F32Array -> IO [Float]
pieceRmsNorm (Context ctx) count rows dim (F32Array x) (F32Array gain) = alloca $ \out -> do
  entry_conf_piece_rms_norm_fwd ctx out rows dim x gain >>= check ctx "conf_piece_rms_norm_fwd"
  c_context_sync ctx >>= check ctx "piece_rms_norm_fwd sync"
  arr <- F32Array <$> peek out
  bracket (pure arr) (freeF32 (Context ctx)) (downloadF32 (Context ctx) count)

pieceRmsNormBackward :: Context -> Int -> Int -> Int64 -> Int64 -> F32Array -> F32Array -> F32Array -> IO ([Float], [Float])
pieceRmsNormBackward (Context ctx) xCount gainCount rows dim (F32Array x) (F32Array gain) (F32Array outputBar) =
  alloca $ \xOut -> alloca $ \gainOut -> do
    entry_conf_piece_rms_norm_bwd ctx xOut gainOut rows dim x gain outputBar >>= check ctx "conf_piece_rms_norm_bwd"
    c_context_sync ctx >>= check ctx "piece_rms_norm_bwd sync"
    xArr <- F32Array <$> peek xOut
    gainArr <- F32Array <$> peek gainOut
    xValues <- bracket (pure xArr) (freeF32 (Context ctx)) (downloadF32 (Context ctx) xCount)
    gainValues <- bracket (pure gainArr) (freeF32 (Context ctx)) (downloadF32 (Context ctx) gainCount)
    pure (xValues, gainValues)

pieceL2NormHeads :: Context -> Int -> Int64 -> Int64 -> Int64 -> F32Array -> IO [Float]
pieceL2NormHeads (Context ctx) count rows dim heads (F32Array x) = alloca $ \out -> do
  entry_conf_piece_l2norm_heads_fwd ctx out rows dim heads x >>= check ctx "conf_piece_l2norm_heads_fwd"
  c_context_sync ctx >>= check ctx "piece_l2norm_heads_fwd sync"
  arr <- F32Array <$> peek out
  bracket (pure arr) (freeF32 (Context ctx)) (downloadF32 (Context ctx) count)

pieceL2NormHeadsBackward :: Context -> Int -> Int64 -> Int64 -> Int64 -> F32Array -> F32Array -> IO [Float]
pieceL2NormHeadsBackward (Context ctx) count rows dim heads (F32Array x) (F32Array outputBar) = alloca $ \out -> do
  entry_conf_piece_l2norm_heads_bwd ctx out rows dim heads x outputBar >>= check ctx "conf_piece_l2norm_heads_bwd"
  c_context_sync ctx >>= check ctx "piece_l2norm_heads_bwd sync"
  arr <- F32Array <$> peek out
  bracket (pure arr) (freeF32 (Context ctx)) (downloadF32 (Context ctx) count)

pieceSiluGate :: Context -> Int -> F32Array -> F32Array -> IO [Float]
pieceSiluGate (Context ctx) count (F32Array gate) (F32Array up) = alloca $ \out -> do
  entry_conf_piece_silu_gate_fwd ctx out gate up >>= check ctx "conf_piece_silu_gate_fwd"
  c_context_sync ctx >>= check ctx "piece_silu_gate_fwd sync"
  arr <- F32Array <$> peek out
  bracket (pure arr) (freeF32 (Context ctx)) (downloadF32 (Context ctx) count)

pieceSiluGateBackward :: Context -> Int -> F32Array -> F32Array -> F32Array -> IO ([Float], [Float])
pieceSiluGateBackward (Context ctx) count (F32Array gate) (F32Array up) (F32Array outputBar) =
  alloca $ \gateOut -> alloca $ \upOut -> do
    entry_conf_piece_silu_gate_bwd ctx gateOut upOut gate up outputBar >>= check ctx "conf_piece_silu_gate_bwd"
    c_context_sync ctx >>= check ctx "piece_silu_gate_bwd sync"
    gateArr <- F32Array <$> peek gateOut
    upArr <- F32Array <$> peek upOut
    gateValues <- bracket (pure gateArr) (freeF32 (Context ctx)) (downloadF32 (Context ctx) count)
    upValues <- bracket (pure upArr) (freeF32 (Context ctx)) (downloadF32 (Context ctx) count)
    pure (gateValues, upValues)

pieceAdd :: Context -> Int -> F32Array -> F32Array -> IO [Float]
pieceAdd (Context ctx) count (F32Array x) (F32Array y) = alloca $ \out -> do
  entry_conf_piece_add_fwd ctx out x y >>= check ctx "conf_piece_add_fwd"
  c_context_sync ctx >>= check ctx "piece_add_fwd sync"
  arr <- F32Array <$> peek out
  bracket (pure arr) (freeF32 (Context ctx)) (downloadF32 (Context ctx) count)

pieceAddBackward :: Context -> Int -> F32Array -> IO ([Float], [Float])
pieceAddBackward (Context ctx) count (F32Array outputBar) =
  alloca $ \xOut -> alloca $ \yOut -> do
    entry_conf_piece_add_bwd ctx xOut yOut outputBar >>= check ctx "conf_piece_add_bwd"
    c_context_sync ctx >>= check ctx "piece_add_bwd sync"
    xArr <- F32Array <$> peek xOut
    yArr <- F32Array <$> peek yOut
    xValues <- bracket (pure xArr) (freeF32 (Context ctx)) (downloadF32 (Context ctx) count)
    yValues <- bracket (pure yArr) (freeF32 (Context ctx)) (downloadF32 (Context ctx) count)
    pure (xValues, yValues)

pieceSplitHeads :: Context -> Int -> Int64 -> Int64 -> Int64 -> Int64 -> F32Array -> IO [Float]
pieceSplitHeads (Context ctx) count batch sequenceLength heads headDim (F32Array x) = alloca $ \out -> do
  entry_conf_piece_split_heads_fwd ctx out batch sequenceLength heads headDim x >>= check ctx "conf_piece_split_heads_fwd"
  c_context_sync ctx >>= check ctx "piece_split_heads_fwd sync"
  arr <- F32Array <$> peek out
  bracket (pure arr) (freeF32 (Context ctx)) (downloadF32 (Context ctx) count)

pieceSplitHeadsBackward :: Context -> Int -> Int64 -> Int64 -> Int64 -> Int64 -> F32Array -> IO [Float]
pieceSplitHeadsBackward (Context ctx) count batch sequenceLength heads headDim (F32Array outputBar) = alloca $ \out -> do
  entry_conf_piece_split_heads_bwd ctx out batch sequenceLength heads headDim outputBar >>= check ctx "conf_piece_split_heads_bwd"
  c_context_sync ctx >>= check ctx "piece_split_heads_bwd sync"
  arr <- F32Array <$> peek out
  bracket (pure arr) (freeF32 (Context ctx)) (downloadF32 (Context ctx) count)

pieceMergeHeads :: Context -> Int -> Int64 -> Int64 -> Int64 -> Int64 -> F32Array -> IO [Float]
pieceMergeHeads (Context ctx) count batch sequenceLength heads headDim (F32Array x) = alloca $ \out -> do
  entry_conf_piece_merge_heads_fwd ctx out batch sequenceLength heads headDim x >>= check ctx "conf_piece_merge_heads_fwd"
  c_context_sync ctx >>= check ctx "piece_merge_heads_fwd sync"
  arr <- F32Array <$> peek out
  bracket (pure arr) (freeF32 (Context ctx)) (downloadF32 (Context ctx) count)

pieceMergeHeadsBackward :: Context -> Int -> Int64 -> Int64 -> Int64 -> Int64 -> F32Array -> IO [Float]
pieceMergeHeadsBackward (Context ctx) count batch sequenceLength heads headDim (F32Array outputBar) = alloca $ \out -> do
  entry_conf_piece_merge_heads_bwd ctx out batch sequenceLength heads headDim outputBar >>= check ctx "conf_piece_merge_heads_bwd"
  c_context_sync ctx >>= check ctx "piece_merge_heads_bwd sync"
  arr <- F32Array <$> peek out
  bracket (pure arr) (freeF32 (Context ctx)) (downloadF32 (Context ctx) count)

pieceCausalSoftmax :: Context -> Int -> Int64 -> Int64 -> Int64 -> F32Array -> IO [Float]
pieceCausalSoftmax (Context ctx) count groups sequenceLength headDim (F32Array scores) = alloca $ \out -> do
  entry_conf_piece_causal_softmax_fwd ctx out groups sequenceLength headDim scores >>= check ctx "conf_piece_causal_softmax_fwd"
  c_context_sync ctx >>= check ctx "piece_causal_softmax_fwd sync"
  arr <- F32Array <$> peek out
  bracket (pure arr) (freeF32 (Context ctx)) (downloadF32 (Context ctx) count)

pieceCausalSoftmaxBackward :: Context -> Int -> Int64 -> Int64 -> Int64 -> F32Array -> F32Array -> IO [Float]
pieceCausalSoftmaxBackward (Context ctx) count groups sequenceLength headDim (F32Array scores) (F32Array weightsBar) = alloca $ \out -> do
  entry_conf_piece_causal_softmax_bwd ctx out groups sequenceLength headDim scores weightsBar >>= check ctx "conf_piece_causal_softmax_bwd"
  c_context_sync ctx >>= check ctx "piece_causal_softmax_bwd sync"
  arr <- F32Array <$> peek out
  bracket (pure arr) (freeF32 (Context ctx)) (downloadF32 (Context ctx) count)

pieceGateCum :: Context -> Int -> Int -> Int -> F32Array -> IO ([Float], [Float])
pieceGateCum (Context ctx) groups chunk headDim (F32Array gateLogits) =
  alloca $ \relOut -> alloca $ \decOut -> do
    entry_conf_piece_gate_cum_fwd ctx relOut decOut (f groups) (f chunk) (f headDim) gateLogits
      >>= check ctx "conf_piece_gate_cum_fwd"
    c_context_sync ctx >>= check ctx "piece_gate_cum_fwd sync"
    relArr <- F32Array <$> peek relOut
    decArr <- F32Array <$> peek decOut
    rel <- bracket (pure relArr) (freeF32 (Context ctx))
      (downloadF32 (Context ctx) (groups * chunk * headDim))
    dec <- bracket (pure decArr) (freeF32 (Context ctx))
      (downloadF32 (Context ctx) (groups * headDim))
    pure (rel, dec)
  where f = fromIntegral

pieceGateCumBackward :: Context -> Int -> Int -> Int -> F32Array -> F32Array -> F32Array -> IO [Float]
pieceGateCumBackward (Context ctx) groups chunk headDim (F32Array gateLogits) (F32Array relBar) (F32Array decBar) =
  alloca $ \out -> do
    entry_conf_piece_gate_cum_bwd ctx out (f groups) (f chunk) (f headDim)
      gateLogits relBar decBar >>= check ctx "conf_piece_gate_cum_bwd"
    c_context_sync ctx >>= check ctx "piece_gate_cum_bwd sync"
    arr <- F32Array <$> peek out
    bracket (pure arr) (freeF32 (Context ctx))
      (downloadF32 (Context ctx) (groups * chunk * headDim))
  where f = fromIntegral

pieceQkDecay :: Context -> Int -> Int -> Int -> F32Array -> F32Array -> F32Array -> F32Array -> IO ([Float], [Float])
pieceQkDecay (Context ctx) groups chunk headDim (F32Array q) (F32Array k) (F32Array rel) (F32Array dec) =
  alloca $ \qOut -> alloca $ \kOut -> do
    entry_conf_piece_qk_decay_fwd ctx qOut kOut (f groups) (f chunk) (f headDim)
      q k rel dec >>= check ctx "conf_piece_qk_decay_fwd"
    c_context_sync ctx >>= check ctx "piece_qk_decay_fwd sync"
    qArr <- F32Array <$> peek qOut
    kArr <- F32Array <$> peek kOut
    let count = groups * chunk * headDim
    qValues <- bracket (pure qArr) (freeF32 (Context ctx)) (downloadF32 (Context ctx) count)
    kValues <- bracket (pure kArr) (freeF32 (Context ctx)) (downloadF32 (Context ctx) count)
    pure (qValues, kValues)
  where f = fromIntegral

pieceQkDecayBackward
  :: Context -> Int -> Int -> Int -> F32Array -> F32Array -> F32Array
  -> F32Array -> F32Array -> F32Array
  -> IO ([Float], [Float], [Float], [Float])
pieceQkDecayBackward (Context ctx) groups chunk headDim
    (F32Array q) (F32Array k) (F32Array rel) (F32Array dec)
    (F32Array qScaledBar) (F32Array kScaledBar) =
  alloca $ \qOut -> alloca $ \kOut -> alloca $ \relOut -> alloca $ \decOut -> do
    entry_conf_piece_qk_decay_bwd ctx qOut kOut relOut decOut
      (f groups) (f chunk) (f headDim) q k rel dec qScaledBar kScaledBar
      >>= check ctx "conf_piece_qk_decay_bwd"
    c_context_sync ctx >>= check ctx "piece_qk_decay_bwd sync"
    qArr <- F32Array <$> peek qOut
    kArr <- F32Array <$> peek kOut
    relArr <- F32Array <$> peek relOut
    decArr <- F32Array <$> peek decOut
    let count = groups * chunk * headDim
        decCount = groups * headDim
        download count' arr = bracket (pure arr) (freeF32 (Context ctx))
          (downloadF32 (Context ctx) count')
    (,,,) <$> download count qArr <*> download count kArr
      <*> download count relArr <*> download decCount decArr
  where f = fromIntegral

pieceGlaIntra :: Context -> Int -> Int -> Int -> F32Array -> F32Array -> F32Array -> F32Array -> IO [Float]
pieceGlaIntra (Context ctx) groups chunk headDim (F32Array q) (F32Array k)
    (F32Array values) (F32Array rel) = alloca $ \out -> do
  entry_conf_piece_gla_intra_fwd ctx out (f groups) (f chunk) (f headDim)
    q k values rel >>= check ctx "conf_piece_gla_intra_fwd"
  c_context_sync ctx >>= check ctx "piece_gla_intra_fwd sync"
  arr <- F32Array <$> peek out
  bracket (pure arr) (freeF32 (Context ctx))
    (downloadF32 (Context ctx) (groups * chunk * headDim))
  where f = fromIntegral

pieceGlaIntraBackward
  :: Context -> Int -> Int -> Int -> F32Array -> F32Array -> F32Array
  -> F32Array -> F32Array -> IO ([Float], [Float], [Float], [Float])
pieceGlaIntraBackward (Context ctx) groups chunk headDim (F32Array q) (F32Array k)
    (F32Array values) (F32Array rel) (F32Array outputBar) =
  alloca $ \qOut -> alloca $ \kOut -> alloca $ \vOut -> alloca $ \relOut -> do
    entry_conf_piece_gla_intra_bwd ctx qOut kOut vOut relOut
      (f groups) (f chunk) (f headDim) q k values rel outputBar
      >>= check ctx "conf_piece_gla_intra_bwd"
    c_context_sync ctx >>= check ctx "piece_gla_intra_bwd sync"
    qArr <- F32Array <$> peek qOut
    kArr <- F32Array <$> peek kOut
    vArr <- F32Array <$> peek vOut
    relArr <- F32Array <$> peek relOut
    let count = groups * chunk * headDim
        download arr = bracket (pure arr) (freeF32 (Context ctx))
          (downloadF32 (Context ctx) count)
    (,,,) <$> download qArr <*> download kArr <*> download vArr <*> download relArr
  where f = fromIntegral

pieceStateAdvance :: Context -> Int -> Int -> F32Array -> F32Array -> F32Array -> IO [Float]
pieceStateAdvance (Context ctx) groups headDim (F32Array state)
    (F32Array contribution) (F32Array dec) = alloca $ \out -> do
  entry_conf_piece_state_advance_fwd ctx out (f groups) (f headDim)
    state contribution dec >>= check ctx "conf_piece_state_advance_fwd"
  c_context_sync ctx >>= check ctx "piece_state_advance_fwd sync"
  arr <- F32Array <$> peek out
  bracket (pure arr) (freeF32 (Context ctx))
    (downloadF32 (Context ctx) (groups * headDim * headDim))
  where f = fromIntegral

pieceStateAdvanceBackward
  :: Context -> Int -> Int -> F32Array -> F32Array -> F32Array -> F32Array
  -> IO ([Float], [Float], [Float])
pieceStateAdvanceBackward (Context ctx) groups headDim (F32Array state)
    (F32Array contribution) (F32Array dec) (F32Array outputBar) =
  alloca $ \stateOut -> alloca $ \contributionOut -> alloca $ \decOut -> do
    entry_conf_piece_state_advance_bwd ctx stateOut contributionOut decOut
      (f groups) (f headDim) state contribution dec outputBar
      >>= check ctx "conf_piece_state_advance_bwd"
    c_context_sync ctx >>= check ctx "piece_state_advance_bwd sync"
    stateArr <- F32Array <$> peek stateOut
    contributionArr <- F32Array <$> peek contributionOut
    decArr <- F32Array <$> peek decOut
    let stateCount = groups * headDim * headDim
        decCount = groups * headDim
        download count arr = bracket (pure arr) (freeF32 (Context ctx))
          (downloadF32 (Context ctx) count)
    (,,) <$> download stateCount stateArr <*> download stateCount contributionArr
      <*> download decCount decArr
  where f = fromIntegral

checkedPtr :: Ptr CContext -> String -> IO (Ptr a) -> (Ptr a -> b) -> IO b
checkedPtr ctx label action wrap = do
  ptr <- action
  check ctx label =<< c_context_sync ctx
  whenNull ptr (label ++ " returned null")
  pure (wrap ptr)

check :: Ptr CContext -> String -> CInt -> IO ()
check ctx label status
  | status == 0 = pure ()
  | otherwise = do
      err <- c_context_get_error ctx
      detail <- if err == nullPtr then pure "unknown Futhark error" else peekCString err
      throwIO (userError (label ++ " failed: " ++ detail))

whenNull :: Ptr a -> String -> IO ()
whenNull ptr message = if ptr == nullPtr then throwIO (userError message) else pure ()

foreign import ccall unsafe "futhark_context_config_new" c_config_new :: IO (Ptr CContextConfig)
foreign import ccall unsafe "futhark_context_config_free" c_config_free :: Ptr CContextConfig -> IO ()
foreign import ccall safe "futhark_context_new" c_context_new :: Ptr CContextConfig -> IO (Ptr CContext)
foreign import ccall safe "futhark_context_free" c_context_free :: Ptr CContext -> IO ()
foreign import ccall unsafe "futhark_context_get_error" c_context_get_error :: Ptr CContext -> IO CString
foreign import ccall safe "futhark_context_sync" c_context_sync :: Ptr CContext -> IO CInt

foreign import ccall unsafe "futhark_new_f32_1d" c_new_f32_1d :: Ptr CContext -> Ptr Float -> Int64 -> IO (Ptr CF32_1d)
foreign import ccall unsafe "futhark_new_i64_1d" c_new_i64_1d :: Ptr CContext -> Ptr Int64 -> Int64 -> IO (Ptr CI64_1d)
foreign import ccall safe "futhark_values_f32_1d" c_values_f32_1d :: Ptr CContext -> Ptr CF32_1d -> Ptr Float -> IO CInt
foreign import ccall safe "futhark_free_f32_1d" c_free_f32_1d :: Ptr CContext -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_free_i64_1d" c_free_i64_1d :: Ptr CContext -> Ptr CI64_1d -> IO CInt

foreign import ccall safe "futhark_entry_oracle_n_params" entry_oracle_n_params :: Ptr CContext -> Ptr Int64 -> Int64 -> Int64 -> Int64 -> Int64 -> IO CInt
foreign import ccall safe "futhark_entry_oracle_logits" entry_oracle_logits :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Int64 -> Int64 -> Int64 -> Int64 -> Ptr CF32_1d -> Ptr CI64_1d -> IO CInt
foreign import ccall safe "futhark_entry_oracle_batch_loss_grad" entry_oracle_batch_loss_grad :: Ptr CContext -> Ptr Float -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Int64 -> Int64 -> Int64 -> Int64 -> Int64 -> Int64 -> Ptr CF32_1d -> Ptr CI64_1d -> IO CInt
foreign import ccall safe "futhark_entry_conf_piece_ce_fwd" entry_conf_piece_ce_fwd :: Ptr CContext -> Ptr Float -> Int64 -> Int64 -> Int64 -> Int64 -> Ptr CF32_1d -> Ptr CI64_1d -> IO CInt
foreign import ccall safe "futhark_entry_conf_piece_ce_bwd" entry_conf_piece_ce_bwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Int64 -> Int64 -> Float -> Ptr CF32_1d -> Ptr CI64_1d -> IO CInt
foreign import ccall safe "futhark_entry_conf_piece_embed_gather_bwd" entry_conf_piece_embed_gather_bwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Int64 -> Ptr CI64_1d -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_conf_piece_embed_gather_fwd" entry_conf_piece_embed_gather_fwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Int64 -> Ptr CF32_1d -> Ptr CI64_1d -> IO CInt
foreign import ccall safe "futhark_entry_conf_piece_rms_norm_fwd" entry_conf_piece_rms_norm_fwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Ptr CF32_1d -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_conf_piece_rms_norm_bwd" entry_conf_piece_rms_norm_bwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Ptr CF32_1d -> Ptr CF32_1d -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_conf_piece_l2norm_heads_fwd" entry_conf_piece_l2norm_heads_fwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Int64 -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_conf_piece_l2norm_heads_bwd" entry_conf_piece_l2norm_heads_bwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Int64 -> Ptr CF32_1d -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_conf_piece_silu_gate_fwd" entry_conf_piece_silu_gate_fwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Ptr CF32_1d -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_conf_piece_silu_gate_bwd" entry_conf_piece_silu_gate_bwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Ptr (Ptr CF32_1d) -> Ptr CF32_1d -> Ptr CF32_1d -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_conf_piece_add_fwd" entry_conf_piece_add_fwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Ptr CF32_1d -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_conf_piece_add_bwd" entry_conf_piece_add_bwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Ptr (Ptr CF32_1d) -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_conf_piece_split_heads_fwd" entry_conf_piece_split_heads_fwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Int64 -> Int64 -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_conf_piece_split_heads_bwd" entry_conf_piece_split_heads_bwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Int64 -> Int64 -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_conf_piece_merge_heads_fwd" entry_conf_piece_merge_heads_fwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Int64 -> Int64 -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_conf_piece_merge_heads_bwd" entry_conf_piece_merge_heads_bwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Int64 -> Int64 -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_conf_piece_causal_softmax_fwd" entry_conf_piece_causal_softmax_fwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Int64 -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_conf_piece_causal_softmax_bwd" entry_conf_piece_causal_softmax_bwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Int64 -> Ptr CF32_1d -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_conf_piece_gate_cum_fwd" entry_conf_piece_gate_cum_fwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Int64 -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_conf_piece_gate_cum_bwd" entry_conf_piece_gate_cum_bwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Int64 -> Ptr CF32_1d -> Ptr CF32_1d -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_conf_piece_qk_decay_fwd" entry_conf_piece_qk_decay_fwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Int64 -> Ptr CF32_1d -> Ptr CF32_1d -> Ptr CF32_1d -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_conf_piece_qk_decay_bwd" entry_conf_piece_qk_decay_bwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Ptr (Ptr CF32_1d) -> Ptr (Ptr CF32_1d) -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Int64 -> Ptr CF32_1d -> Ptr CF32_1d -> Ptr CF32_1d -> Ptr CF32_1d -> Ptr CF32_1d -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_conf_piece_gla_intra_fwd" entry_conf_piece_gla_intra_fwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Int64 -> Ptr CF32_1d -> Ptr CF32_1d -> Ptr CF32_1d -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_conf_piece_gla_intra_bwd" entry_conf_piece_gla_intra_bwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Ptr (Ptr CF32_1d) -> Ptr (Ptr CF32_1d) -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Int64 -> Ptr CF32_1d -> Ptr CF32_1d -> Ptr CF32_1d -> Ptr CF32_1d -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_conf_piece_state_advance_fwd" entry_conf_piece_state_advance_fwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Ptr CF32_1d -> Ptr CF32_1d -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_entry_conf_piece_state_advance_bwd" entry_conf_piece_state_advance_bwd :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Ptr (Ptr CF32_1d) -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Ptr CF32_1d -> Ptr CF32_1d -> Ptr CF32_1d -> Ptr CF32_1d -> IO CInt
