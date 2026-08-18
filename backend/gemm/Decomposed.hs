{-# LANGUAGE RankNTypes #-}

module Decomposed
  ( PieceOps (..)
  , FeedForwardResult (..)
  , SoftmaxAttentionResult (..)
  , SoftmaxAttentionSubBlockResult (..)
  , SoftmaxBlockWeights (..)
  , SoftmaxBlockResult (..)
  , GlaAttentionResult (..)
  , GlaAttentionSubBlockResult (..)
  , GlaBlockWeights (..)
  , GlaBlockResult (..)
  , feedForwardDecomposed
  , softmaxAttentionDecomposed
  , softmaxAttentionSubBlockDecomposed
  , softmaxBlockDecomposed
  , glaAttentionDecomposed
  , glaAttentionSubBlockDecomposed
  , glaBlockDecomposed
  , modelLossGradDecomposed
  , denseForwardList
  , densePullbackList
  , batchedGemmList
  , batchedGemmPullbackList
  , gatherChunk
  , assembleChunks
  , putChunkList
  , readSliceList
  , writeSliceList
  ) where

import Blas
import Buffer
import Control.Monad (foldM, unless)
import Dense
import FormalTransformer.Config
import FormalTransformer.Layout

-- The buffer type is abstract so the same traversal runs on host lists (the
-- conformance instantiation) and on device handles (the CUDA runtime). All
-- data-bearing values are `buf`; token vectors are `tok`. The final block of
-- fields is pure data movement: it exists so the traversal never touches
-- buffer contents on the host.
data PieceOps buf tok = PieceOps
  { opsDenseForward :: Int -> Int -> Int -> buf -> buf -> IO buf
  , opsDenseBackward :: Int -> Int -> Int -> buf -> buf -> buf
      -> IO (buf, buf)
  , opsBatchedGemmForward :: Transpose -> Transpose -> Int -> Int -> Int
      -> Int -> Int -> Int -> Int -> buf -> buf -> IO buf
  , opsBatchedGemmBackward :: Transpose -> Transpose -> Int -> Int -> Int
      -> Int -> Int -> Int -> Int -> buf -> buf -> buf
      -> IO (buf, buf)
  , opsRmsForward :: Int -> Int -> buf -> buf -> IO buf
  , opsRmsBackward :: Int -> Int -> buf -> buf -> buf
      -> IO (buf, buf)
  , opsL2HeadsForward :: Int -> Int -> Int -> buf -> IO buf
  , opsL2HeadsBackward :: Int -> Int -> Int -> buf -> buf -> IO buf
  , opsSiluGateForward :: buf -> buf -> IO buf
  , opsSiluGateBackward :: buf -> buf -> buf
      -> IO (buf, buf)
  , opsAddForward :: buf -> buf -> IO buf
  , opsAddBackward :: buf -> IO (buf, buf)
  , opsSplitHeadsForward :: Int -> Int -> Int -> Int -> buf -> IO buf
  , opsSplitHeadsBackward :: Int -> Int -> Int -> Int -> buf -> IO buf
  , opsMergeHeadsForward :: Int -> Int -> Int -> Int -> buf -> IO buf
  , opsMergeHeadsBackward :: Int -> Int -> Int -> Int -> buf -> IO buf
  , opsCausalSoftmaxForward :: Int -> Int -> Int -> buf -> IO buf
  , opsCausalSoftmaxBackward :: Int -> Int -> Int -> buf -> buf
      -> IO buf
  , opsGateCumForward :: Int -> Int -> Int -> buf -> IO (buf, buf)
  , opsGateCumBackward :: Int -> Int -> Int -> buf -> buf -> buf
      -> IO buf
  , opsQkDecayForward :: Int -> Int -> Int -> buf -> buf -> buf
      -> buf -> IO (buf, buf)
  , opsQkDecayBackward :: Int -> Int -> Int -> buf -> buf -> buf
      -> buf -> buf -> buf
      -> IO (buf, buf, buf, buf)
  , opsGlaIntraForward :: Int -> Int -> Int -> buf -> buf -> buf
      -> buf -> IO buf
  , opsGlaIntraBackward :: Int -> Int -> Int -> buf -> buf -> buf
      -> buf -> buf -> IO (buf, buf, buf, buf)
  , opsStateAdvanceForward :: Int -> Int -> buf -> buf -> buf
      -> IO buf
  , opsStateAdvanceBackward :: Int -> Int -> buf -> buf -> buf
      -> buf -> IO (buf, buf, buf)
  , opsEmbeddingGather :: Int -> Int -> buf -> tok -> IO buf
  , opsEmbeddingBackward :: Int -> Int -> tok -> buf -> IO buf
  , opsCeForward :: Int -> Int -> Int -> Int -> buf -> tok -> IO Float
  , opsCeBackward :: Int -> Int -> Int -> Int -> Float -> buf -> tok
      -> IO buf
  , opsZeros :: Int -> IO buf
  , opsLength :: buf -> Int
  , opsTokenCount :: tok -> Int
  , opsFree :: buf -> IO ()
    -- Runs an action inside a nested allocation window: everything it
    -- allocates is released when it returns, except the buffers it names as
    -- survivors.  This is what keeps peak memory at one layer's working set
    -- rather than the whole traversal's.  On host-list backends it is just
    -- `fmap fst` -- the garbage collector already does the job.
  , opsScope :: forall a. IO (a, [buf]) -> IO a
  , opsReadSlice :: Int -> Int -> buf -> IO buf
  , opsWriteSlice :: Int -> buf -> buf -> IO buf
  , opsConcat :: buf -> buf -> IO buf
  , opsGatherChunk :: Int -> Int -> Int -> Int -> buf -> IO buf
  , opsPutChunk :: Int -> Int -> Int -> Int -> buf -> buf -> IO buf
  }

data FeedForwardResult buf = FeedForwardResult
  { ffOutput :: !buf
  , ffXBar :: !buf
  , ffGainBar :: !buf
  , ffWgateBar :: !buf
  , ffWupBar :: !buf
  , ffWdownBar :: !buf
  }

data SoftmaxAttentionResult buf = SoftmaxAttentionResult
  { softmaxOutput :: !buf
  , softmaxQBar :: !buf
  , softmaxKBar :: !buf
  , softmaxVBar :: !buf
  }

data SoftmaxAttentionSubBlockResult buf = SoftmaxAttentionSubBlockResult
  { softmaxBlockOutput :: !buf
  , softmaxBlockXBar :: !buf
  , softmaxBlockGainBar :: !buf
  , softmaxBlockWqBar :: !buf
  , softmaxBlockWkBar :: !buf
  , softmaxBlockWvBar :: !buf
  , softmaxBlockWoBar :: !buf
  }

data SoftmaxBlockWeights buf = SoftmaxBlockWeights
  { softmaxRmsAtt :: !buf
  , softmaxWq :: !buf
  , softmaxWk :: !buf
  , softmaxWv :: !buf
  , softmaxWo :: !buf
  , softmaxRmsFf :: !buf
  , softmaxWgate :: !buf
  , softmaxWup :: !buf
  , softmaxWdown :: !buf
  }

data SoftmaxBlockResult buf = SoftmaxBlockResult
  { fullSoftmaxOutput :: !buf
  , fullSoftmaxXBar :: !buf
  , fullSoftmaxRmsAttBar :: !buf
  , fullSoftmaxWqBar :: !buf
  , fullSoftmaxWkBar :: !buf
  , fullSoftmaxWvBar :: !buf
  , fullSoftmaxWoBar :: !buf
  , fullSoftmaxRmsFfBar :: !buf
  , fullSoftmaxWgateBar :: !buf
  , fullSoftmaxWupBar :: !buf
  , fullSoftmaxWdownBar :: !buf
  }

data GlaAttentionResult buf = GlaAttentionResult
  { glaOutput :: !buf
  , glaQBar :: !buf
  , glaKBar :: !buf
  , glaVBar :: !buf
  , glaGateBar :: !buf
  }

data GlaAttentionSubBlockResult buf = GlaAttentionSubBlockResult
  { glaBlockAttentionOutput :: !buf
  , glaBlockAttentionXBar :: !buf
  , glaBlockAttentionRmsBar :: !buf
  , glaBlockAttentionWqBar :: !buf
  , glaBlockAttentionWkBar :: !buf
  , glaBlockAttentionWvBar :: !buf
  , glaBlockAttentionWoBar :: !buf
  , glaBlockAttentionWalphaBar :: !buf
  }

data GlaBlockWeights buf = GlaBlockWeights
  { glaRmsAtt :: !buf
  , glaWq :: !buf
  , glaWk :: !buf
  , glaWv :: !buf
  , glaWo :: !buf
  , glaWalpha :: !buf
  , glaRmsFf :: !buf
  , glaWgate :: !buf
  , glaWup :: !buf
  , glaWdown :: !buf
  }

data GlaBlockResult buf = GlaBlockResult
  { fullGlaOutput :: !buf
  , fullGlaXBar :: !buf
  , fullGlaRmsAttBar :: !buf
  , fullGlaWqBar :: !buf
  , fullGlaWkBar :: !buf
  , fullGlaWvBar :: !buf
  , fullGlaWoBar :: !buf
  , fullGlaWalphaBar :: !buf
  , fullGlaRmsFfBar :: !buf
  , fullGlaWgateBar :: !buf
  , fullGlaWupBar :: !buf
  , fullGlaWdownBar :: !buf
  }

data LayerWeights buf
  = GlaLayerWeights !(GlaBlockWeights buf)
  | SoftmaxLayerWeights !(SoftmaxBlockWeights buf)

feedForwardDecomposed
  :: PieceOps buf tok
  -> Int
  -> Int
  -> Int
  -> buf
  -> buf
  -> buf
  -> buf
  -> buf
  -> buf
  -> IO (FeedForwardResult buf)
feedForwardDecomposed ops rows d f x gain wgate wup wdown outputBar = do
  normalized <- opsRmsForward ops rows d x gain
  gate <- opsDenseForward ops rows d f normalized wgate
  up <- opsDenseForward ops rows d f normalized wup
  hidden <- opsSiluGateForward ops gate up
  projected <- opsDenseForward ops rows f d hidden wdown
  output <- opsAddForward ops x projected
  (skipBar, projectedBar) <- opsAddBackward ops outputBar
  (hiddenBar, wdownBar) <- opsDenseBackward ops rows f d hidden wdown projectedBar
  (gateBar, upBar) <- opsSiluGateBackward ops gate up hiddenBar
  (normalizedGateBar, wgateBar) <- opsDenseBackward ops rows d f normalized wgate gateBar
  (normalizedUpBar, wupBar) <- opsDenseBackward ops rows d f normalized wup upBar
  normalizedBar <- opsAddForward ops normalizedGateBar normalizedUpBar
  (rmsXBar, gainBar) <- opsRmsBackward ops rows d x gain normalizedBar
  xBar <- opsAddForward ops skipBar rmsXBar
  pure (FeedForwardResult output xBar gainBar wgateBar wupBar wdownBar)

-- Forward-only variants: the layer-stack forward pass needs only each
-- block's output, so these run the identical forward op sequence and skip
-- the pullback machinery entirely (the full functions below previously ran
-- it against a zero cotangent and discarded the results).
feedForwardOutput
  :: PieceOps buf tok -> Int -> Int -> Int
  -> buf -> buf -> buf -> buf -> buf -> IO buf
feedForwardOutput ops rows d f x gain wgate wup wdown = do
  normalized <- opsRmsForward ops rows d x gain
  gate <- opsDenseForward ops rows d f normalized wgate
  up <- opsDenseForward ops rows d f normalized wup
  hidden <- opsSiluGateForward ops gate up
  projected <- opsDenseForward ops rows f d hidden wdown
  opsAddForward ops x projected

softmaxAttentionOutput
  :: PieceOps buf tok -> Int -> Int -> Int -> Int
  -> buf -> buf -> buf -> IO buf
softmaxAttentionOutput ops batch n heads hd q k value = do
  let groups = batch * heads
  qHeads <- opsSplitHeadsForward ops batch n heads hd q
  kHeads <- opsSplitHeadsForward ops batch n heads hd k
  valueHeads <- opsSplitHeadsForward ops batch n heads hd value
  scores <- opsBatchedGemmForward ops NoTrans Trans groups n hd n hd n n qHeads kHeads
  weights <- opsCausalSoftmaxForward ops groups n hd scores
  attendedHeads <- opsBatchedGemmForward ops NoTrans NoTrans groups n n n hd n hd weights valueHeads
  opsMergeHeadsForward ops batch n heads hd attendedHeads

softmaxSubBlockOutput
  :: PieceOps buf tok -> Int -> Int -> Int -> Int
  -> buf -> buf -> buf -> buf -> buf -> buf -> IO buf
softmaxSubBlockOutput ops batch n heads hd x gain wq wk wv wo = do
  let d = heads * hd
      rows = batch * n
  normalized <- opsRmsForward ops rows d x gain
  q <- opsDenseForward ops rows d d normalized wq
  k <- opsDenseForward ops rows d d normalized wk
  value <- opsDenseForward ops rows d d normalized wv
  attention <- softmaxAttentionOutput ops batch n heads hd q k value
  projected <- opsDenseForward ops rows d d attention wo
  opsAddForward ops x projected

softmaxBlockForwardOutput
  :: PieceOps buf tok -> Int -> Int -> Int -> Int -> Int
  -> buf -> SoftmaxBlockWeights buf -> IO buf
softmaxBlockForwardOutput ops batch n heads hd f x weights = do
  let d = heads * hd
      rows = batch * n
  attention <- softmaxSubBlockOutput ops batch n heads hd x
    (softmaxRmsAtt weights) (softmaxWq weights) (softmaxWk weights)
    (softmaxWv weights) (softmaxWo weights)
  feedForwardOutput ops rows d f attention (softmaxRmsFf weights)
    (softmaxWgate weights) (softmaxWup weights) (softmaxWdown weights)

glaAttentionOutput
  :: PieceOps buf tok -> Int -> Int -> Int -> Int -> Int
  -> buf -> buf -> buf -> buf -> IO buf
glaAttentionOutput ops batch n heads hd chunk q k value gateLogits = do
  unless (chunk > 0 && n > 0 && n `mod` chunk == 0) $
    ioError (userError "GLA chunk must be positive and divide sequence length")
  let headGroups = batch * heads
      chunkCount = n `div` chunk
      chunkGroups = headGroups * chunkCount
      chunkElements = chunk * hd
      stateElements = hd * hd
  zeroState <- opsZeros ops (headGroups * stateElements)
  qHeads <- opsSplitHeadsForward ops batch n heads hd q
  kHeads <- opsSplitHeadsForward ops batch n heads hd k
  valueHeads <- opsSplitHeadsForward ops batch n heads hd value
  gateHeads <- opsSplitHeadsForward ops batch n heads hd gateLogits
  (relcum, dec) <- opsGateCumForward ops chunkGroups chunk hd gateHeads
  (qScaled, kScaled) <- opsQkDecayForward ops chunkGroups chunk hd
    qHeads kHeads relcum dec
  contributions <- opsBatchedGemmForward ops Trans NoTrans chunkGroups chunk hd chunk hd
    hd hd kScaled valueHeads
  intra <- opsGlaIntraForward ops chunkGroups chunk hd
    qHeads kHeads valueHeads relcum
  (interReversed, _) <- foldM
    (\(inters, state) chunkIndex -> do
      qChunk <- opsGatherChunk ops headGroups chunkCount chunkElements chunkIndex qScaled
      contribution <- opsGatherChunk ops headGroups chunkCount stateElements chunkIndex contributions
      decChunk <- opsGatherChunk ops headGroups chunkCount hd chunkIndex dec
      inter <- opsBatchedGemmForward ops NoTrans NoTrans headGroups chunk hd hd hd
        chunk hd qChunk state
      state' <- opsStateAdvanceForward ops headGroups hd state contribution decChunk
      pure (inter : inters, state'))
    ([], zeroState)
    [0 .. chunkCount - 1]
  inter <- assembleChunksOps ops headGroups chunkCount chunkElements (reverse interReversed)
  attendedHeads <- opsAddForward ops inter intra
  opsMergeHeadsForward ops batch n heads hd attendedHeads

glaSubBlockOutput
  :: PieceOps buf tok -> Int -> Int -> Int -> Int -> Int
  -> buf -> buf -> buf -> buf -> buf -> buf -> buf -> IO buf
glaSubBlockOutput ops batch n heads hd chunk x gain wq wk wv wo walpha = do
  let d = heads * hd
      rows = batch * n
  normalized <- opsRmsForward ops rows d x gain
  q0 <- opsDenseForward ops rows d d normalized wq
  k0 <- opsDenseForward ops rows d d normalized wk
  value <- opsDenseForward ops rows d d normalized wv
  gate <- opsDenseForward ops rows d d normalized walpha
  q <- opsL2HeadsForward ops rows d heads q0
  k <- opsL2HeadsForward ops rows d heads k0
  attention <- glaAttentionOutput ops batch n heads hd chunk q k value gate
  projected <- opsDenseForward ops rows d d attention wo
  opsAddForward ops x projected

glaBlockForwardOutput
  :: PieceOps buf tok -> Int -> Int -> Int -> Int -> Int -> Int
  -> buf -> GlaBlockWeights buf -> IO buf
glaBlockForwardOutput ops batch n heads hd chunk f x weights = do
  let d = heads * hd
      rows = batch * n
  attention <- glaSubBlockOutput ops batch n heads hd chunk x
    (glaRmsAtt weights) (glaWq weights) (glaWk weights) (glaWv weights)
    (glaWo weights) (glaWalpha weights)
  feedForwardOutput ops rows d f attention (glaRmsFf weights)
    (glaWgate weights) (glaWup weights) (glaWdown weights)

softmaxAttentionDecomposed
  :: PieceOps buf tok
  -> Int
  -> Int
  -> Int
  -> Int
  -> buf
  -> buf
  -> buf
  -> buf
  -> IO (SoftmaxAttentionResult buf)
softmaxAttentionDecomposed ops batch n heads hd q k value outputBar = do
  let groups = batch * heads
      tokenCount = batch * n * heads * hd
      scoreCount = groups * n * n
  qHeads <- opsSplitHeadsForward ops batch n heads hd q
  kHeads <- opsSplitHeadsForward ops batch n heads hd k
  valueHeads <- opsSplitHeadsForward ops batch n heads hd value
  scores <- opsBatchedGemmForward ops NoTrans Trans groups n hd n hd n n qHeads kHeads
  weights <- opsCausalSoftmaxForward ops groups n hd scores
  attendedHeads <- opsBatchedGemmForward ops NoTrans NoTrans groups n n n hd n hd weights valueHeads
  output <- opsMergeHeadsForward ops batch n heads hd attendedHeads
  attendedHeadsBar <- opsMergeHeadsBackward ops batch n heads hd outputBar
  (weightsBar, valueHeadsBar) <- opsBatchedGemmBackward ops NoTrans NoTrans
    groups n n n hd n hd weights valueHeads attendedHeadsBar
  scoresBar <- opsCausalSoftmaxBackward ops groups n hd scores weightsBar
  (qHeadsBar, kHeadsBar) <- opsBatchedGemmBackward ops NoTrans Trans
    groups n hd n hd n n qHeads kHeads scoresBar
  qBar <- opsSplitHeadsBackward ops batch n heads hd qHeadsBar
  kBar <- opsSplitHeadsBackward ops batch n heads hd kHeadsBar
  valueBar <- opsSplitHeadsBackward ops batch n heads hd valueHeadsBar
  unless (all (== tokenCount) (map (opsLength ops) [output, qBar, kBar, valueBar])
    && opsLength ops scores == scoreCount) $
    ioError (userError "decomposed softmax attention produced an invalid buffer length")
  pure (SoftmaxAttentionResult output qBar kBar valueBar)

softmaxAttentionSubBlockDecomposed
  :: PieceOps buf tok
  -> Int
  -> Int
  -> Int
  -> Int
  -> buf
  -> buf
  -> buf
  -> buf
  -> buf
  -> buf
  -> buf
  -> IO (SoftmaxAttentionSubBlockResult buf)
softmaxAttentionSubBlockDecomposed ops batch n heads hd x gain wq wk wv wo outputBar = do
  let d = heads * hd
      rows = batch * n
  normalized <- opsRmsForward ops rows d x gain
  q <- opsDenseForward ops rows d d normalized wq
  k <- opsDenseForward ops rows d d normalized wk
  value <- opsDenseForward ops rows d d normalized wv
  attentionOutput <- softmaxAttentionOutput ops batch n heads hd q k value
  projected <- opsDenseForward ops rows d d attentionOutput wo
  output <- opsAddForward ops x projected
  (skipBar, projectedBar) <- opsAddBackward ops outputBar
  (attentionBar, woBar) <- opsDenseBackward ops rows d d
    attentionOutput wo projectedBar
  attentionBackward <- softmaxAttentionDecomposed ops batch n heads hd q k value attentionBar
  (normalizedQBar, wqBar) <- opsDenseBackward ops rows d d normalized wq
    (softmaxQBar attentionBackward)
  (normalizedKBar, wkBar) <- opsDenseBackward ops rows d d normalized wk
    (softmaxKBar attentionBackward)
  (normalizedVBar, wvBar) <- opsDenseBackward ops rows d d normalized wv
    (softmaxVBar attentionBackward)
  normalizedQKBar <- opsAddForward ops normalizedQBar normalizedKBar
  normalizedBar <- opsAddForward ops normalizedQKBar normalizedVBar
  (rmsXBar, gainBar) <- opsRmsBackward ops rows d x gain normalizedBar
  xBar <- opsAddForward ops skipBar rmsXBar
  pure (SoftmaxAttentionSubBlockResult output xBar gainBar wqBar wkBar wvBar woBar)

softmaxBlockDecomposed
  :: PieceOps buf tok
  -> Int
  -> Int
  -> Int
  -> Int
  -> Int
  -> buf
  -> SoftmaxBlockWeights buf
  -> buf
  -> IO (SoftmaxBlockResult buf)
softmaxBlockDecomposed ops batch n heads hd f x weights outputBar = do
  let d = heads * hd
      rows = batch * n
  attentionOutput <- softmaxSubBlockOutput ops batch n heads hd x
    (softmaxRmsAtt weights) (softmaxWq weights) (softmaxWk weights)
    (softmaxWv weights) (softmaxWo weights)
  ff <- feedForwardDecomposed ops rows d f attentionOutput
    (softmaxRmsFf weights) (softmaxWgate weights) (softmaxWup weights)
    (softmaxWdown weights) outputBar
  attention <- softmaxAttentionSubBlockDecomposed ops batch n heads hd x
    (softmaxRmsAtt weights) (softmaxWq weights) (softmaxWk weights)
    (softmaxWv weights) (softmaxWo weights) (ffXBar ff)
  pure (SoftmaxBlockResult
    (ffOutput ff)
    (softmaxBlockXBar attention)
    (softmaxBlockGainBar attention)
    (softmaxBlockWqBar attention)
    (softmaxBlockWkBar attention)
    (softmaxBlockWvBar attention)
    (softmaxBlockWoBar attention)
    (ffGainBar ff)
    (ffWgateBar ff)
    (ffWupBar ff)
    (ffWdownBar ff))

glaAttentionDecomposed
  :: PieceOps buf tok
  -> Int
  -> Int
  -> Int
  -> Int
  -> Int
  -> buf
  -> buf
  -> buf
  -> buf
  -> buf
  -> IO (GlaAttentionResult buf)
glaAttentionDecomposed ops batch n heads hd chunk q k value gateLogits outputBar = do
  unless (chunk > 0 && n > 0 && n `mod` chunk == 0) $
    ioError (userError "GLA chunk must be positive and divide sequence length")
  let headGroups = batch * heads
      chunkCount = n `div` chunk
      chunkGroups = headGroups * chunkCount
      chunkElements = chunk * hd
      stateElements = hd * hd
      tokenCount = batch * n * heads * hd
  zeroState <- opsZeros ops (headGroups * stateElements)
  qHeads <- opsSplitHeadsForward ops batch n heads hd q
  kHeads <- opsSplitHeadsForward ops batch n heads hd k
  valueHeads <- opsSplitHeadsForward ops batch n heads hd value
  gateHeads <- opsSplitHeadsForward ops batch n heads hd gateLogits
  (relcum, dec) <- opsGateCumForward ops chunkGroups chunk hd gateHeads
  (qScaled, kScaled) <- opsQkDecayForward ops chunkGroups chunk hd
    qHeads kHeads relcum dec
  contributions <- opsBatchedGemmForward ops Trans NoTrans chunkGroups chunk hd chunk hd
    hd hd kScaled valueHeads
  intra <- opsGlaIntraForward ops chunkGroups chunk hd
    qHeads kHeads valueHeads relcum
  (statesReversed, interReversed, _) <- foldM
    (forwardChunk headGroups chunkCount chunkElements stateElements qScaled contributions dec)
    ([], [], zeroState)
    [0 .. chunkCount - 1]
  let states = reverse statesReversed
  inter <- assembleChunksOps ops headGroups chunkCount chunkElements (reverse interReversed)
  attendedHeads <- opsAddForward ops inter intra
  output <- opsMergeHeadsForward ops batch n heads hd attendedHeads
  attendedHeadsBar <- opsMergeHeadsBackward ops batch n heads hd outputBar
  (interBar, intraBar) <- opsAddBackward ops attendedHeadsBar
  (qIntraBar, kIntraBar, vIntraBar, relIntraBar) <-
    opsGlaIntraBackward ops chunkGroups chunk hd
      qHeads kHeads valueHeads relcum intraBar
  zeroStateBar <- opsZeros ops (headGroups * stateElements)
  (_, qScaledChunks, kScaledChunks, vInterChunks, decStateChunks) <- foldM
    (reverseChunk ops headGroups chunkCount chunk hd states qScaled kScaled
      valueHeads contributions dec interBar)
    (zeroStateBar, [], [], [], [])
    (reverse [0 .. chunkCount - 1])
  qScaledBar <- assembleChunksOps ops headGroups chunkCount chunkElements qScaledChunks
  kScaledBar <- assembleChunksOps ops headGroups chunkCount chunkElements kScaledChunks
  vInterBar <- assembleChunksOps ops headGroups chunkCount chunkElements vInterChunks
  decStateBar <- assembleChunksOps ops headGroups chunkCount hd decStateChunks
  (qDecayBar, kDecayBar, relDecayBar, decDecayBar) <-
    opsQkDecayBackward ops chunkGroups chunk hd qHeads kHeads relcum dec
      qScaledBar kScaledBar
  qHeadsBar <- opsAddForward ops qIntraBar qDecayBar
  kHeadsBar <- opsAddForward ops kIntraBar kDecayBar
  valueHeadsBar <- opsAddForward ops vIntraBar vInterBar
  relBar <- opsAddForward ops relIntraBar relDecayBar
  decBar <- opsAddForward ops decStateBar decDecayBar
  gateHeadsBar <- opsGateCumBackward ops chunkGroups chunk hd gateHeads relBar decBar
  qBar <- opsSplitHeadsBackward ops batch n heads hd qHeadsBar
  kBar <- opsSplitHeadsBackward ops batch n heads hd kHeadsBar
  valueBar <- opsSplitHeadsBackward ops batch n heads hd valueHeadsBar
  gateBar <- opsSplitHeadsBackward ops batch n heads hd gateHeadsBar
  unless (all (== tokenCount)
      (map (opsLength ops) [output, qBar, kBar, valueBar, gateBar])) $
    ioError (userError "decomposed GLA attention produced an invalid buffer length")
  pure (GlaAttentionResult output qBar kBar valueBar gateBar)
  where
    forwardChunk headGroups chunkCount chunkElements stateElements
        qScaled contributions dec (states, inters, state) chunkIndex = do
      qChunk <- opsGatherChunk ops headGroups chunkCount chunkElements chunkIndex qScaled
      contribution <- opsGatherChunk ops headGroups chunkCount stateElements chunkIndex contributions
      decChunk <- opsGatherChunk ops headGroups chunkCount hd chunkIndex dec
      inter <- opsBatchedGemmForward ops NoTrans NoTrans headGroups chunk hd hd hd
        chunk hd qChunk state
      state' <- opsStateAdvanceForward ops headGroups hd state contribution decChunk
      pure (state : states, inter : inters, state')

glaAttentionSubBlockDecomposed
  :: PieceOps buf tok
  -> Int
  -> Int
  -> Int
  -> Int
  -> Int
  -> buf
  -> buf
  -> buf
  -> buf
  -> buf
  -> buf
  -> buf
  -> buf
  -> IO (GlaAttentionSubBlockResult buf)
glaAttentionSubBlockDecomposed ops batch n heads hd chunk x gain wq wk wv wo walpha outputBar = do
  let d = heads * hd
      rows = batch * n
  normalized <- opsRmsForward ops rows d x gain
  q0 <- opsDenseForward ops rows d d normalized wq
  k0 <- opsDenseForward ops rows d d normalized wk
  value <- opsDenseForward ops rows d d normalized wv
  gate <- opsDenseForward ops rows d d normalized walpha
  q <- opsL2HeadsForward ops rows d heads q0
  k <- opsL2HeadsForward ops rows d heads k0
  attentionOutput <- glaAttentionOutput ops batch n heads hd chunk
    q k value gate
  projected <- opsDenseForward ops rows d d attentionOutput wo
  output <- opsAddForward ops x projected
  (skipBar, projectedBar) <- opsAddBackward ops outputBar
  (attentionBar, woBar) <- opsDenseBackward ops rows d d
    attentionOutput wo projectedBar
  attentionBackward <- glaAttentionDecomposed ops batch n heads hd chunk
    q k value gate attentionBar
  q0Bar <- opsL2HeadsBackward ops rows d heads q0 (glaQBar attentionBackward)
  k0Bar <- opsL2HeadsBackward ops rows d heads k0 (glaKBar attentionBackward)
  (normalizedQBar, wqBar) <- opsDenseBackward ops rows d d normalized wq q0Bar
  (normalizedKBar, wkBar) <- opsDenseBackward ops rows d d normalized wk k0Bar
  (normalizedVBar, wvBar) <- opsDenseBackward ops rows d d normalized wv
    (glaVBar attentionBackward)
  (normalizedGateBar, walphaBar) <- opsDenseBackward ops rows d d normalized walpha
    (glaGateBar attentionBackward)
  normalizedQKBar <- opsAddForward ops normalizedQBar normalizedKBar
  normalizedQKVBar <- opsAddForward ops normalizedQKBar normalizedVBar
  normalizedBar <- opsAddForward ops normalizedQKVBar normalizedGateBar
  (rmsXBar, gainBar) <- opsRmsBackward ops rows d x gain normalizedBar
  xBar <- opsAddForward ops skipBar rmsXBar
  pure (GlaAttentionSubBlockResult output xBar gainBar wqBar wkBar wvBar
    woBar walphaBar)

glaBlockDecomposed
  :: PieceOps buf tok
  -> Int
  -> Int
  -> Int
  -> Int
  -> Int
  -> Int
  -> buf
  -> GlaBlockWeights buf
  -> buf
  -> IO (GlaBlockResult buf)
glaBlockDecomposed ops batch n heads hd chunk f x weights outputBar = do
  let d = heads * hd
      rows = batch * n
  attentionOutput <- glaSubBlockOutput ops batch n heads hd chunk x
    (glaRmsAtt weights) (glaWq weights) (glaWk weights) (glaWv weights)
    (glaWo weights) (glaWalpha weights)
  ff <- feedForwardDecomposed ops rows d f attentionOutput
    (glaRmsFf weights) (glaWgate weights) (glaWup weights)
    (glaWdown weights) outputBar
  attention <- glaAttentionSubBlockDecomposed ops batch n heads hd chunk x
    (glaRmsAtt weights) (glaWq weights) (glaWk weights) (glaWv weights)
    (glaWo weights) (glaWalpha weights) (ffXBar ff)
  pure (GlaBlockResult
    (ffOutput ff)
    (glaBlockAttentionXBar attention)
    (glaBlockAttentionRmsBar attention)
    (glaBlockAttentionWqBar attention)
    (glaBlockAttentionWkBar attention)
    (glaBlockAttentionWvBar attention)
    (glaBlockAttentionWoBar attention)
    (glaBlockAttentionWalphaBar attention)
    (ffGainBar ff)
    (ffWgateBar ff)
    (ffWupBar ff)
    (ffWdownBar ff))

modelLossGradDecomposed
  :: PieceOps buf tok
  -> Config
  -> Int
  -> Int
  -> Int
  -> buf
  -> tok
  -> IO (Float, buf)
modelLossGradDecomposed ops cfg chunk batch effectiveBatch params tokens = do
  _ <- either (ioError . userError) pure (validateConfig cfg)
  let n = contextSize cfg
      d = modelDim cfg
      f = ffDim cfg
      heads = headCount cfg
      vocab = vocabSize cfg
      rows = batch * n
  unless (opsLength ops params == paramCount cfg
      && opsTokenCount ops tokens == rows) $
    ioError (userError "decomposed model input length mismatch")
  layout <- either (ioError . userError) pure (namedLayout cfg)
  (embedding, layers, finalRms) <- parseModelWeights ops cfg layout params
  initial <- opsEmbeddingGather ops vocab d embedding tokens
  (inputsReversed, hidden) <- foldM
    (forwardLayer ops batch n heads (d `div` heads) chunk f)
    ([], initial)
    layers
  finalHidden <- opsRmsForward ops rows d hidden finalRms
  logits <- opsDenseForward ops rows d vocab finalHidden embedding
  loss <- opsCeForward ops batch n vocab effectiveBatch logits tokens
  logitsBar <- opsCeBackward ops batch n vocab effectiveBatch 1 logits tokens
  (finalHiddenBar, embeddingOutputBar) <- opsDenseBackward ops rows d vocab
    finalHidden embedding logitsBar
  (hiddenBar, finalRmsBar) <- opsRmsBackward ops rows d hidden finalRms finalHiddenBar
  (initialBar, namedBars) <- foldM
    (reverseLayer ops batch n heads (d `div` heads) chunk f)
    (hiddenBar, [])
    (zip3 (reverse [0 .. layerCount cfg - 1]) (reverse layers) inputsReversed)
  embeddingInputBar <- opsEmbeddingBackward ops vocab d tokens initialBar
  embeddingBar <- opsAddForward ops embeddingOutputBar embeddingInputBar
  gradient <- assembleGradient ops layout (paramCount cfg)
    (("embedding", embeddingBar) : concat namedBars ++ [("final_rms", finalRmsBar)])
  unless (opsLength ops gradient == paramCount cfg) $
    ioError (userError "decomposed model gradient length mismatch")
  pure (loss, gradient)

-- Builds the flat gradient from the named cotangents.
--
-- namedLayout's slices are contiguous and cover the parameter vector exactly
-- (backend/test/Main.hs asserts both), and the decomposed traversal emits its
-- cotangents in that same order -- reverseLayer prepends while walking layers
-- backwards, and glaNamedGradient/softmaxNamedGradient list a block's slices in
-- layout order.  So the gradient is simply the ordered concatenation, and a
-- balanced tree of pairwise concatenations builds it in O(m log k).
--
-- The fold this replaces called piece_slice_write once per slice, and that
-- kernel is a functional whole-array update: it rewrote all 115M elements to
-- place one slice.  119 slices x 461 MB is ~55 GB of traffic per step to write
-- 461 MB, 7.0% of kernel time at bpe100m.  The tree moves ~3.2 GB instead.
--
-- The precondition is checked rather than assumed: if the layout ever stops
-- being a contiguous cover in emission order, this falls back to the fold.
assembleGradient
  :: PieceOps buf tok -> [Slice] -> Int -> [(String, buf)] -> IO buf
assembleGradient ops layout total named
  | concatenable = treeConcat ops (map snd named)
  | otherwise = do
      emptyGradient <- opsZeros ops total
      foldM (writeNamedSlice ops layout) emptyGradient named
  where
    expected = [(sliceName slice, sliceOffset slice, sliceLength slice) | slice <- layout]
    actual = [(name, opsLength ops values) | (name, values) <- named]
    -- Same names in the same order, each cotangent the length its slice
    -- declares, offsets exactly the running sum, and the whole vector covered.
    concatenable =
      map (\(name, _, _) -> name) expected == map fst actual
        && map (\(_, _, len) -> len) expected == map snd actual
        && map (\(_, offset, _) -> offset) expected
             == scanl (+) 0 (init (map (\(_, _, len) -> len) expected))
        && sum (map (\(_, _, len) -> len) expected) == total
        && not (null expected)

-- Pairwise merge, halving the list each round.  Operands are freed as soon as
-- they are consumed, exactly as the fold did, so peak memory stays at one
-- round's working set rather than the whole traversal's.
treeConcat :: PieceOps buf tok -> [buf] -> IO buf
treeConcat ops buffers = case buffers of
  [] -> ioError (userError "gradient assembly needs at least one cotangent")
  [single] -> pure single
  _ -> mergePairs buffers >>= treeConcat ops
  where
    mergePairs (a : b : rest) = do
      joined <- opsConcat ops a b
      opsFree ops a
      opsFree ops b
      (joined :) <$> mergePairs rest
    mergePairs remaining = pure remaining

-- Writes one named parameter cotangent into the flat gradient vector at its
-- layout offset.  Retained as the fallback for a layout that is not a
-- contiguous cover in emission order; assembleGradient prefers the tree.
-- The superseded gradient vector and the consumed cotangent are freed eagerly:
-- without this the fold retains every intermediate full-parameter copy until
-- the arena closes (~62 x 42 MB at bpe10m).
writeNamedSlice
  :: PieceOps buf tok -> [Slice] -> buf -> (String, buf) -> IO buf
writeNamedSlice ops layout gradient (name, values) =
  case filter ((== name) . sliceName) layout of
    [slice] -> do
      unless (opsLength ops values == sliceLength slice) $
        ioError (userError ("gradient slice length mismatch for " ++ name))
      updated <- opsWriteSlice ops (sliceOffset slice) gradient values
      opsFree ops gradient
      opsFree ops values
      pure updated
    [] -> ioError (userError ("missing parameter slice: " ++ name))
    _ -> ioError (userError ("duplicate parameter slice: " ++ name))

forwardLayer
  :: PieceOps buf tok -> Int -> Int -> Int -> Int -> Int -> Int
  -> ([buf], buf) -> LayerWeights buf -> IO ([buf], buf)
-- The block's intermediates die with its window; only its output crosses into
-- the next layer.  The input `x` was allocated by the caller and is retained
-- there, which is what the backward pass recomputes from.
forwardLayer ops batch n heads hd chunk f (inputs, x) layer = do
  output <- opsScope ops $ do
    out <- case layer of
      GlaLayerWeights weights ->
        glaBlockForwardOutput ops batch n heads hd chunk f x weights
      SoftmaxLayerWeights weights ->
        softmaxBlockForwardOutput ops batch n heads hd f x weights
    pure (out, [out])
  pure (x : inputs, output)

reverseLayer
  :: PieceOps buf tok -> Int -> Int -> Int -> Int -> Int -> Int
  -> (buf, [[(String, buf)]]) -> (Int, LayerWeights buf, buf)
  -> IO (buf, [[(String, buf)]])
-- This is where the memory goes: the block backward recomputes the whole
-- forward and then runs every pullback, so its working set is the largest of
-- the traversal.  Scoping it per layer means one layer's worth is live at a
-- time instead of all of them.  The survivors are exactly what the caller
-- still needs: the input cotangent that feeds the next layer down, and the
-- parameter cotangents that gradient assembly consumes (and frees itself).
reverseLayer ops batch n heads hd chunk f (outputBar, gradients)
    (layerIndex, layer, x) = do
  (xBar, named) <- opsScope ops $ case layer of
    GlaLayerWeights weights -> do
      result <- glaBlockDecomposed ops batch n heads hd chunk f x weights outputBar
      let bar = fullGlaXBar result
          slices = glaNamedGradient layerIndex result
      pure ((bar, slices), bar : map snd slices)
    SoftmaxLayerWeights weights -> do
      result <- softmaxBlockDecomposed ops batch n heads hd f x weights outputBar
      let bar = fullSoftmaxXBar result
          slices = softmaxNamedGradient layerIndex result
      pure ((bar, slices), bar : map snd slices)
  pure (xBar, named : gradients)

glaNamedGradient :: Int -> GlaBlockResult buf -> [(String, buf)]
glaNamedGradient layer result =
  [ (prefix ++ "rms_att", fullGlaRmsAttBar result)
  , (prefix ++ "wq", fullGlaWqBar result)
  , (prefix ++ "wk", fullGlaWkBar result)
  , (prefix ++ "wv", fullGlaWvBar result)
  , (prefix ++ "wo", fullGlaWoBar result)
  , (prefix ++ "walpha", fullGlaWalphaBar result)
  , (prefix ++ "rms_ff", fullGlaRmsFfBar result)
  , (prefix ++ "wgate", fullGlaWgateBar result)
  , (prefix ++ "wup", fullGlaWupBar result)
  , (prefix ++ "wdown", fullGlaWdownBar result)
  ]
  where
    prefix = "blocks." ++ show layer ++ "."

softmaxNamedGradient :: Int -> SoftmaxBlockResult buf -> [(String, buf)]
softmaxNamedGradient layer result =
  [ (prefix ++ "rms_att", fullSoftmaxRmsAttBar result)
  , (prefix ++ "wq", fullSoftmaxWqBar result)
  , (prefix ++ "wk", fullSoftmaxWkBar result)
  , (prefix ++ "wv", fullSoftmaxWvBar result)
  , (prefix ++ "wo", fullSoftmaxWoBar result)
  , (prefix ++ "rms_ff", fullSoftmaxRmsFfBar result)
  , (prefix ++ "wgate", fullSoftmaxWgateBar result)
  , (prefix ++ "wup", fullSoftmaxWupBar result)
  , (prefix ++ "wdown", fullSoftmaxWdownBar result)
  ]
  where
    prefix = "blocks." ++ show layer ++ "."

parseModelWeights
  :: PieceOps buf tok -> Config -> [Slice] -> buf
  -> IO (buf, [LayerWeights buf], buf)
parseModelWeights ops cfg layout params = do
  embedding <- weight "embedding"
  layers <- mapM layerWeights [0 .. layerCount cfg - 1]
  finalRms <- weight "final_rms"
  pure (embedding, layers, finalRms)
  where
    weight name = case filter ((== name) . sliceName) layout of
      [slice] -> do
        unless (sliceOffset slice >= 0 && sliceLength slice >= 0
            && sliceOffset slice + sliceLength slice <= opsLength ops params) $
          ioError (userError ("parameter vector too short for " ++ name))
        opsReadSlice ops (sliceOffset slice) (sliceLength slice) params
      [] -> ioError (userError ("missing parameter slice: " ++ name))
      _ -> ioError (userError ("duplicate parameter slice: " ++ name))
    layerWeights layer = do
      rmsAtt <- get "rms_att"
      wq <- get "wq"
      wk <- get "wk"
      wv <- get "wv"
      wo <- get "wo"
      rmsFf <- get "rms_ff"
      wgate <- get "wgate"
      wup <- get "wup"
      wdown <- get "wdown"
      if isSoftmaxLayer cfg layer
        then pure (SoftmaxLayerWeights
          (SoftmaxBlockWeights rmsAtt wq wk wv wo rmsFf wgate wup wdown))
        else do
          walpha <- get "walpha"
          pure (GlaLayerWeights
            (GlaBlockWeights rmsAtt wq wk wv wo walpha rmsFf wgate wup wdown))
      where
        get suffix = weight ("blocks." ++ show layer ++ "." ++ suffix)

reverseChunk
  :: PieceOps buf tok
  -> Int
  -> Int
  -> Int
  -> Int
  -> [buf]
  -> buf
  -> buf
  -> buf
  -> buf
  -> buf
  -> buf
  -> (buf, [buf], [buf], [buf], [buf])
  -> Int
  -> IO (buf, [buf], [buf], [buf], [buf])
reverseChunk ops headGroups chunkCount chunk hd states qScaled kScaled values
    contributions dec interBar
    (futureStateBar, qBars, kBars, vBars, decBars) chunkIndex = do
  state <- indexList "GLA state tape" states chunkIndex
  let chunkElements = chunk * hd
      stateElements = hd * hd
  qChunk <- opsGatherChunk ops headGroups chunkCount chunkElements chunkIndex qScaled
  kChunk <- opsGatherChunk ops headGroups chunkCount chunkElements chunkIndex kScaled
  valueChunk <- opsGatherChunk ops headGroups chunkCount chunkElements chunkIndex values
  contribution <- opsGatherChunk ops headGroups chunkCount stateElements chunkIndex contributions
  decChunk <- opsGatherChunk ops headGroups chunkCount hd chunkIndex dec
  interChunkBar <- opsGatherChunk ops headGroups chunkCount chunkElements chunkIndex interBar
  (qChunkBar, stateInterBar) <- opsBatchedGemmBackward ops NoTrans NoTrans
    headGroups chunk hd hd hd chunk hd qChunk state interChunkBar
  (stateRecurrenceBar, contributionBar, decBar) <-
    opsStateAdvanceBackward ops headGroups hd state contribution decChunk futureStateBar
  stateBar <- opsAddForward ops stateInterBar stateRecurrenceBar
  (kChunkBar, valueChunkBar) <- opsBatchedGemmBackward ops Trans NoTrans
    headGroups chunk hd chunk hd hd hd kChunk valueChunk contributionBar
  pure (stateBar, qChunkBar : qBars, kChunkBar : kBars,
    valueChunkBar : vBars, decBar : decBars)

-- Reassembles per-chunk buffers into the grouped layout via opsPutChunk; the
-- inverse of opsGatherChunk applied at every chunk index.
assembleChunksOps
  :: PieceOps buf tok -> Int -> Int -> Int -> [buf] -> IO buf
assembleChunksOps ops groups chunkCount elements chunks = do
  unless (length chunks == chunkCount) $
    ioError (userError "chunk assembly received a wrong chunk count")
  initial <- opsZeros ops (groups * chunkCount * elements)
  foldM
    (\assembled (chunkIndex, chunkValues) ->
      opsPutChunk ops groups chunkCount elements chunkIndex assembled chunkValues)
    initial
    (zip [0 ..] chunks)

indexList :: String -> [a] -> Int -> IO a
indexList label values index = case drop index values of
  value : _ -> pure value
  [] -> ioError (userError (label ++ " index out of bounds"))

-- Pure list reference implementations of the data-movement ops. They are the
-- CPU instantiation of the buffer contract and the conformance oracle for the
-- corresponding Futhark entries.
gatherChunk :: Int -> Int -> Int -> Int -> [a] -> [a]
gatherChunk groups chunkCount elements chunkIndex values = concat
  [ take elements (drop ((group * chunkCount + chunkIndex) * elements) values)
  | group <- [0 .. groups - 1]
  ]

assembleChunks :: Int -> Int -> Int -> [[a]] -> [a]
assembleChunks groups chunkCount elements chunks = concat
  [ concat
      [ take elements (drop (group * elements) chunkValues)
      | chunkValues <- take chunkCount chunks
      ]
  | group <- [0 .. groups - 1]
  ]

putChunkList :: Int -> Int -> Int -> Int -> [a] -> [a] -> [a]
putChunkList groups chunkCount elements chunkIndex destination source = concat
  [ if position == chunkIndex
      then take elements (drop (group * elements) source)
      else segment group position
  | group <- [0 .. groups - 1]
  , position <- [0 .. chunkCount - 1]
  ]
  where
    segment group position =
      take elements (drop ((group * chunkCount + position) * elements) destination)

readSliceList :: Int -> Int -> [a] -> [a]
readSliceList offset count = take count . drop offset

writeSliceList :: Int -> [a] -> [a] -> [a]
writeSliceList offset destination source =
  take offset destination
    ++ source
    ++ drop (offset + length source) destination

denseForwardList :: Int -> Int -> Int -> [Float] -> [Float] -> IO [Float]
denseForwardList rows inputDim outputDim x weights = do
  xBuffer <- bufferFromList x
  weightBuffer <- bufferFromList weights
  outputBuffer <- newBuffer (rows * outputDim)
  xView <- checkedView (matrixView xBuffer 0 rows inputDim inputDim)
  weightView <- checkedView (matrixView weightBuffer 0 outputDim inputDim inputDim)
  outputView <- checkedView (matrixView outputBuffer 0 rows outputDim outputDim)
  denseForward openBlas xView weightView outputView
  bufferToList outputBuffer

densePullbackList
  :: Int
  -> Int
  -> Int
  -> [Float]
  -> [Float]
  -> [Float]
  -> IO ([Float], [Float])
densePullbackList rows inputDim outputDim x weights outputBar = do
  xBuffer <- bufferFromList x
  weightBuffer <- bufferFromList weights
  outputBarBuffer <- bufferFromList outputBar
  xBarBuffer <- bufferFromList (replicate (rows * inputDim) 0)
  weightBarBuffer <- bufferFromList (replicate (outputDim * inputDim) 0)
  xView <- checkedView (matrixView xBuffer 0 rows inputDim inputDim)
  weightView <- checkedView (matrixView weightBuffer 0 outputDim inputDim inputDim)
  outputBarView <- checkedView (matrixView outputBarBuffer 0 rows outputDim outputDim)
  xBarView <- checkedView (matrixView xBarBuffer 0 rows inputDim inputDim)
  weightBarView <- checkedView (matrixView weightBarBuffer 0 outputDim inputDim inputDim)
  densePullback openBlas xView weightView outputBarView xBarView weightBarView
  (,) <$> bufferToList xBarBuffer <*> bufferToList weightBarBuffer

batchedGemmList
  :: Transpose
  -> Transpose
  -> Int
  -> Int
  -> Int
  -> Int
  -> Int
  -> Int
  -> Int
  -> [Float]
  -> [Float]
  -> IO [Float]
batchedGemmList transA transB groups aRows aCols bRows bCols cRows cCols a b = do
  aBuffer <- bufferFromList a
  bBuffer <- bufferFromList b
  cBuffer <- newBuffer (groups * cRows * cCols)
  aMatrix <- checkedView (matrixView aBuffer 0 aRows aCols aCols)
  bMatrix <- checkedView (matrixView bBuffer 0 bRows bCols bCols)
  cMatrix <- checkedView (matrixView cBuffer 0 cRows cCols cCols)
  as <- checkedBatchView (batchView aMatrix groups (aRows * aCols))
  bs <- checkedBatchView (batchView bMatrix groups (bRows * bCols))
  cs <- checkedBatchView (batchView cMatrix groups (cRows * cCols))
  blasGemmBatched openBlas transA transB 1 as bs 0 cs
  bufferToList cBuffer

batchedGemmPullbackList
  :: Transpose
  -> Transpose
  -> Int
  -> Int
  -> Int
  -> Int
  -> Int
  -> Int
  -> Int
  -> [Float]
  -> [Float]
  -> [Float]
  -> IO ([Float], [Float])
batchedGemmPullbackList transA transB groups aRows aCols bRows bCols cRows cCols a b cBar = do
  aBuffer <- bufferFromList a
  bBuffer <- bufferFromList b
  cBarBuffer <- bufferFromList cBar
  aBarBuffer <- bufferFromList (replicate (groups * aRows * aCols) 0)
  bBarBuffer <- bufferFromList (replicate (groups * bRows * bCols) 0)
  aMatrix <- checkedView (matrixView aBuffer 0 aRows aCols aCols)
  bMatrix <- checkedView (matrixView bBuffer 0 bRows bCols bCols)
  cBarMatrix <- checkedView (matrixView cBarBuffer 0 cRows cCols cCols)
  aBarMatrix <- checkedView (matrixView aBarBuffer 0 aRows aCols aCols)
  bBarMatrix <- checkedView (matrixView bBarBuffer 0 bRows bCols bCols)
  as <- checkedBatchView (batchView aMatrix groups (aRows * aCols))
  bs <- checkedBatchView (batchView bMatrix groups (bRows * bCols))
  cBars <- checkedBatchView (batchView cBarMatrix groups (cRows * cCols))
  aBars <- checkedBatchView (batchView aBarMatrix groups (aRows * aCols))
  bBars <- checkedBatchView (batchView bBarMatrix groups (bRows * bCols))
  blasGemmBatchedPullback openBlas transA transB 1 as bs cBars aBars bBars
  (,) <$> bufferToList aBarBuffer <*> bufferToList bBarBuffer

checkedView :: Either String MatrixView -> IO MatrixView
checkedView = either (ioError . userError) pure

checkedBatchView :: Either String BatchView -> IO BatchView
checkedBatchView = either (ioError . userError) pure
