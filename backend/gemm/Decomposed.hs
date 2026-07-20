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
  ) where

import Blas
import Buffer
import Control.Monad (foldM, unless)
import Data.Int (Int64)
import Dense
import FormalTransformer.Config
import FormalTransformer.Layout

data PieceOps = PieceOps
  { opsDenseForward :: Int -> Int -> Int -> [Float] -> [Float] -> IO [Float]
  , opsDenseBackward :: Int -> Int -> Int -> [Float] -> [Float] -> [Float]
      -> IO ([Float], [Float])
  , opsBatchedGemmForward :: Transpose -> Transpose -> Int -> Int -> Int
      -> Int -> Int -> Int -> Int -> [Float] -> [Float] -> IO [Float]
  , opsBatchedGemmBackward :: Transpose -> Transpose -> Int -> Int -> Int
      -> Int -> Int -> Int -> Int -> [Float] -> [Float] -> [Float]
      -> IO ([Float], [Float])
  , opsRmsForward :: Int -> Int -> [Float] -> [Float] -> IO [Float]
  , opsRmsBackward :: Int -> Int -> [Float] -> [Float] -> [Float]
      -> IO ([Float], [Float])
  , opsL2HeadsForward :: Int -> Int -> Int -> [Float] -> IO [Float]
  , opsL2HeadsBackward :: Int -> Int -> Int -> [Float] -> [Float] -> IO [Float]
  , opsSiluGateForward :: [Float] -> [Float] -> IO [Float]
  , opsSiluGateBackward :: [Float] -> [Float] -> [Float]
      -> IO ([Float], [Float])
  , opsAddForward :: [Float] -> [Float] -> IO [Float]
  , opsAddBackward :: [Float] -> IO ([Float], [Float])
  , opsSplitHeadsForward :: Int -> Int -> Int -> Int -> [Float] -> IO [Float]
  , opsSplitHeadsBackward :: Int -> Int -> Int -> Int -> [Float] -> IO [Float]
  , opsMergeHeadsForward :: Int -> Int -> Int -> Int -> [Float] -> IO [Float]
  , opsMergeHeadsBackward :: Int -> Int -> Int -> Int -> [Float] -> IO [Float]
  , opsCausalSoftmaxForward :: Int -> Int -> Int -> [Float] -> IO [Float]
  , opsCausalSoftmaxBackward :: Int -> Int -> Int -> [Float] -> [Float]
      -> IO [Float]
  , opsGateCumForward :: Int -> Int -> Int -> [Float] -> IO ([Float], [Float])
  , opsGateCumBackward :: Int -> Int -> Int -> [Float] -> [Float] -> [Float]
      -> IO [Float]
  , opsQkDecayForward :: Int -> Int -> Int -> [Float] -> [Float] -> [Float]
      -> [Float] -> IO ([Float], [Float])
  , opsQkDecayBackward :: Int -> Int -> Int -> [Float] -> [Float] -> [Float]
      -> [Float] -> [Float] -> [Float]
      -> IO ([Float], [Float], [Float], [Float])
  , opsGlaIntraForward :: Int -> Int -> Int -> [Float] -> [Float] -> [Float]
      -> [Float] -> IO [Float]
  , opsGlaIntraBackward :: Int -> Int -> Int -> [Float] -> [Float] -> [Float]
      -> [Float] -> [Float] -> IO ([Float], [Float], [Float], [Float])
  , opsStateAdvanceForward :: Int -> Int -> [Float] -> [Float] -> [Float]
      -> IO [Float]
  , opsStateAdvanceBackward :: Int -> Int -> [Float] -> [Float] -> [Float]
      -> [Float] -> IO ([Float], [Float], [Float])
  , opsEmbeddingGather :: Int -> Int -> [Float] -> [Int64] -> IO [Float]
  , opsEmbeddingBackward :: Int -> Int -> [Int64] -> [Float] -> IO [Float]
  , opsCeForward :: Int -> Int -> Int -> Int -> [Float] -> [Int64] -> IO Float
  , opsCeBackward :: Int -> Int -> Int -> Int -> Float -> [Float] -> [Int64]
      -> IO [Float]
  }

data FeedForwardResult = FeedForwardResult
  { ffOutput :: ![Float]
  , ffXBar :: ![Float]
  , ffGainBar :: ![Float]
  , ffWgateBar :: ![Float]
  , ffWupBar :: ![Float]
  , ffWdownBar :: ![Float]
  }

data SoftmaxAttentionResult = SoftmaxAttentionResult
  { softmaxOutput :: ![Float]
  , softmaxQBar :: ![Float]
  , softmaxKBar :: ![Float]
  , softmaxVBar :: ![Float]
  }

data SoftmaxAttentionSubBlockResult = SoftmaxAttentionSubBlockResult
  { softmaxBlockOutput :: ![Float]
  , softmaxBlockXBar :: ![Float]
  , softmaxBlockGainBar :: ![Float]
  , softmaxBlockWqBar :: ![Float]
  , softmaxBlockWkBar :: ![Float]
  , softmaxBlockWvBar :: ![Float]
  , softmaxBlockWoBar :: ![Float]
  }

data SoftmaxBlockWeights = SoftmaxBlockWeights
  { softmaxRmsAtt :: ![Float]
  , softmaxWq :: ![Float]
  , softmaxWk :: ![Float]
  , softmaxWv :: ![Float]
  , softmaxWo :: ![Float]
  , softmaxRmsFf :: ![Float]
  , softmaxWgate :: ![Float]
  , softmaxWup :: ![Float]
  , softmaxWdown :: ![Float]
  }

data SoftmaxBlockResult = SoftmaxBlockResult
  { fullSoftmaxOutput :: ![Float]
  , fullSoftmaxXBar :: ![Float]
  , fullSoftmaxRmsAttBar :: ![Float]
  , fullSoftmaxWqBar :: ![Float]
  , fullSoftmaxWkBar :: ![Float]
  , fullSoftmaxWvBar :: ![Float]
  , fullSoftmaxWoBar :: ![Float]
  , fullSoftmaxRmsFfBar :: ![Float]
  , fullSoftmaxWgateBar :: ![Float]
  , fullSoftmaxWupBar :: ![Float]
  , fullSoftmaxWdownBar :: ![Float]
  }

data GlaAttentionResult = GlaAttentionResult
  { glaOutput :: ![Float]
  , glaQBar :: ![Float]
  , glaKBar :: ![Float]
  , glaVBar :: ![Float]
  , glaGateBar :: ![Float]
  }

data GlaAttentionSubBlockResult = GlaAttentionSubBlockResult
  { glaBlockAttentionOutput :: ![Float]
  , glaBlockAttentionXBar :: ![Float]
  , glaBlockAttentionRmsBar :: ![Float]
  , glaBlockAttentionWqBar :: ![Float]
  , glaBlockAttentionWkBar :: ![Float]
  , glaBlockAttentionWvBar :: ![Float]
  , glaBlockAttentionWoBar :: ![Float]
  , glaBlockAttentionWalphaBar :: ![Float]
  }

data GlaBlockWeights = GlaBlockWeights
  { glaRmsAtt :: ![Float]
  , glaWq :: ![Float]
  , glaWk :: ![Float]
  , glaWv :: ![Float]
  , glaWo :: ![Float]
  , glaWalpha :: ![Float]
  , glaRmsFf :: ![Float]
  , glaWgate :: ![Float]
  , glaWup :: ![Float]
  , glaWdown :: ![Float]
  }

data GlaBlockResult = GlaBlockResult
  { fullGlaOutput :: ![Float]
  , fullGlaXBar :: ![Float]
  , fullGlaRmsAttBar :: ![Float]
  , fullGlaWqBar :: ![Float]
  , fullGlaWkBar :: ![Float]
  , fullGlaWvBar :: ![Float]
  , fullGlaWoBar :: ![Float]
  , fullGlaWalphaBar :: ![Float]
  , fullGlaRmsFfBar :: ![Float]
  , fullGlaWgateBar :: ![Float]
  , fullGlaWupBar :: ![Float]
  , fullGlaWdownBar :: ![Float]
  }

data LayerWeights
  = GlaLayerWeights !GlaBlockWeights
  | SoftmaxLayerWeights !SoftmaxBlockWeights

feedForwardDecomposed
  :: PieceOps
  -> Int
  -> Int
  -> Int
  -> [Float]
  -> [Float]
  -> [Float]
  -> [Float]
  -> [Float]
  -> [Float]
  -> IO FeedForwardResult
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

softmaxAttentionDecomposed
  :: PieceOps
  -> Int
  -> Int
  -> Int
  -> Int
  -> [Float]
  -> [Float]
  -> [Float]
  -> [Float]
  -> IO SoftmaxAttentionResult
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
  unless (all (== tokenCount) (map length [output, qBar, kBar, valueBar])
    && length scores == scoreCount) $
    ioError (userError "decomposed softmax attention produced an invalid buffer length")
  pure (SoftmaxAttentionResult output qBar kBar valueBar)

softmaxAttentionSubBlockDecomposed
  :: PieceOps
  -> Int
  -> Int
  -> Int
  -> Int
  -> [Float]
  -> [Float]
  -> [Float]
  -> [Float]
  -> [Float]
  -> [Float]
  -> [Float]
  -> IO SoftmaxAttentionSubBlockResult
softmaxAttentionSubBlockDecomposed ops batch n heads hd x gain wq wk wv wo outputBar = do
  let d = heads * hd
      rows = batch * n
      zeroAttentionBar = replicate (rows * d) 0
  normalized <- opsRmsForward ops rows d x gain
  q <- opsDenseForward ops rows d d normalized wq
  k <- opsDenseForward ops rows d d normalized wk
  value <- opsDenseForward ops rows d d normalized wv
  attentionForward <- softmaxAttentionDecomposed ops batch n heads hd q k value zeroAttentionBar
  projected <- opsDenseForward ops rows d d (softmaxOutput attentionForward) wo
  output <- opsAddForward ops x projected
  (skipBar, projectedBar) <- opsAddBackward ops outputBar
  (attentionBar, woBar) <- opsDenseBackward ops rows d d
    (softmaxOutput attentionForward) wo projectedBar
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
  :: PieceOps
  -> Int
  -> Int
  -> Int
  -> Int
  -> Int
  -> [Float]
  -> SoftmaxBlockWeights
  -> [Float]
  -> IO SoftmaxBlockResult
softmaxBlockDecomposed ops batch n heads hd f x weights outputBar = do
  let d = heads * hd
      rows = batch * n
      zeroBar = replicate (rows * d) 0
  attentionForward <- softmaxAttentionSubBlockDecomposed ops batch n heads hd x
    (softmaxRmsAtt weights) (softmaxWq weights) (softmaxWk weights)
    (softmaxWv weights) (softmaxWo weights) zeroBar
  ff <- feedForwardDecomposed ops rows d f (softmaxBlockOutput attentionForward)
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
  :: PieceOps
  -> Int
  -> Int
  -> Int
  -> Int
  -> Int
  -> [Float]
  -> [Float]
  -> [Float]
  -> [Float]
  -> [Float]
  -> IO GlaAttentionResult
glaAttentionDecomposed ops batch n heads hd chunk q k value gateLogits outputBar = do
  unless (chunk > 0 && n > 0 && n `mod` chunk == 0) $
    ioError (userError "GLA chunk must be positive and divide sequence length")
  let headGroups = batch * heads
      chunkCount = n `div` chunk
      chunkGroups = headGroups * chunkCount
      chunkElements = chunk * hd
      stateElements = hd * hd
      tokenCount = batch * n * heads * hd
      zeroState = replicate (headGroups * stateElements) 0
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
      inter = assembleChunks headGroups chunkCount chunkElements (reverse interReversed)
  attendedHeads <- opsAddForward ops inter intra
  output <- opsMergeHeadsForward ops batch n heads hd attendedHeads
  attendedHeadsBar <- opsMergeHeadsBackward ops batch n heads hd outputBar
  (interBar, intraBar) <- opsAddBackward ops attendedHeadsBar
  (qIntraBar, kIntraBar, vIntraBar, relIntraBar) <-
    opsGlaIntraBackward ops chunkGroups chunk hd
      qHeads kHeads valueHeads relcum intraBar
  (_, qScaledChunks, kScaledChunks, vInterChunks, decStateChunks) <- foldM
    (reverseChunk ops headGroups chunkCount chunk hd states qScaled kScaled
      valueHeads contributions dec interBar)
    (zeroState, [], [], [], [])
    (reverse [0 .. chunkCount - 1])
  let qScaledBar = assembleChunks headGroups chunkCount chunkElements qScaledChunks
      kScaledBar = assembleChunks headGroups chunkCount chunkElements kScaledChunks
      vInterBar = assembleChunks headGroups chunkCount chunkElements vInterChunks
      decStateBar = assembleChunks headGroups chunkCount hd decStateChunks
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
  unless (all (== tokenCount) (map length [output, qBar, kBar, valueBar, gateBar])) $
    ioError (userError "decomposed GLA attention produced an invalid buffer length")
  pure (GlaAttentionResult output qBar kBar valueBar gateBar)
  where
    forwardChunk headGroups chunkCount chunkElements stateElements
        qScaled contributions dec (states, inters, state) chunkIndex = do
      let qChunk = gatherChunk headGroups chunkCount chunkElements chunkIndex qScaled
          contribution = gatherChunk headGroups chunkCount stateElements chunkIndex contributions
          decChunk = gatherChunk headGroups chunkCount hd chunkIndex dec
      inter <- opsBatchedGemmForward ops NoTrans NoTrans headGroups chunk hd hd hd
        chunk hd qChunk state
      state' <- opsStateAdvanceForward ops headGroups hd state contribution decChunk
      pure (state : states, inter : inters, state')

glaAttentionSubBlockDecomposed
  :: PieceOps
  -> Int
  -> Int
  -> Int
  -> Int
  -> Int
  -> [Float]
  -> [Float]
  -> [Float]
  -> [Float]
  -> [Float]
  -> [Float]
  -> [Float]
  -> [Float]
  -> IO GlaAttentionSubBlockResult
glaAttentionSubBlockDecomposed ops batch n heads hd chunk x gain wq wk wv wo walpha outputBar = do
  let d = heads * hd
      rows = batch * n
      zeroAttentionBar = replicate (rows * d) 0
  normalized <- opsRmsForward ops rows d x gain
  q0 <- opsDenseForward ops rows d d normalized wq
  k0 <- opsDenseForward ops rows d d normalized wk
  value <- opsDenseForward ops rows d d normalized wv
  gate <- opsDenseForward ops rows d d normalized walpha
  q <- opsL2HeadsForward ops rows d heads q0
  k <- opsL2HeadsForward ops rows d heads k0
  attentionForward <- glaAttentionDecomposed ops batch n heads hd chunk
    q k value gate zeroAttentionBar
  projected <- opsDenseForward ops rows d d (glaOutput attentionForward) wo
  output <- opsAddForward ops x projected
  (skipBar, projectedBar) <- opsAddBackward ops outputBar
  (attentionBar, woBar) <- opsDenseBackward ops rows d d
    (glaOutput attentionForward) wo projectedBar
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
  :: PieceOps
  -> Int
  -> Int
  -> Int
  -> Int
  -> Int
  -> Int
  -> [Float]
  -> GlaBlockWeights
  -> [Float]
  -> IO GlaBlockResult
glaBlockDecomposed ops batch n heads hd chunk f x weights outputBar = do
  let d = heads * hd
      rows = batch * n
      zeroBar = replicate (rows * d) 0
  attentionForward <- glaAttentionSubBlockDecomposed ops batch n heads hd chunk x
    (glaRmsAtt weights) (glaWq weights) (glaWk weights) (glaWv weights)
    (glaWo weights) (glaWalpha weights) zeroBar
  ff <- feedForwardDecomposed ops rows d f (glaBlockAttentionOutput attentionForward)
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
  :: PieceOps
  -> Config
  -> Int
  -> Int
  -> Int
  -> [Float]
  -> [Int64]
  -> IO (Float, [Float])
modelLossGradDecomposed ops cfg chunk batch effectiveBatch params tokens = do
  _ <- either (ioError . userError) pure (validateConfig cfg)
  let n = contextSize cfg
      d = modelDim cfg
      f = ffDim cfg
      heads = headCount cfg
      vocab = vocabSize cfg
      rows = batch * n
  unless (length params == paramCount cfg && length tokens == rows) $
    ioError (userError "decomposed model input length mismatch")
  (embedding, layers, finalRms) <- parseModelWeights cfg params
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
  (initialBar, layerGradients) <- foldM
    (reverseLayer ops batch n heads (d `div` heads) chunk f)
    (hiddenBar, [])
    (zip (reverse layers) inputsReversed)
  embeddingInputBar <- opsEmbeddingBackward ops vocab d tokens initialBar
  embeddingBar <- opsAddForward ops embeddingOutputBar embeddingInputBar
  let gradient = embeddingBar ++ concat layerGradients ++ finalRmsBar
  unless (length gradient == paramCount cfg) $
    ioError (userError "decomposed model gradient length mismatch")
  pure (loss, gradient)

forwardLayer
  :: PieceOps -> Int -> Int -> Int -> Int -> Int -> Int
  -> ([[Float]], [Float]) -> LayerWeights -> IO ([[Float]], [Float])
forwardLayer ops batch n heads hd chunk f (inputs, x) layer = do
  let zeroBar = replicate (length x) 0
  output <- case layer of
    GlaLayerWeights weights -> fullGlaOutput <$>
      glaBlockDecomposed ops batch n heads hd chunk f x weights zeroBar
    SoftmaxLayerWeights weights -> fullSoftmaxOutput <$>
      softmaxBlockDecomposed ops batch n heads hd f x weights zeroBar
  pure (x : inputs, output)

reverseLayer
  :: PieceOps -> Int -> Int -> Int -> Int -> Int -> Int
  -> ([Float], [[Float]]) -> (LayerWeights, [Float]) -> IO ([Float], [[Float]])
reverseLayer ops batch n heads hd chunk f (outputBar, gradients) (layer, x) =
  case layer of
    GlaLayerWeights weights -> do
      result <- glaBlockDecomposed ops batch n heads hd chunk f x weights outputBar
      pure (fullGlaXBar result, glaGradient result : gradients)
    SoftmaxLayerWeights weights -> do
      result <- softmaxBlockDecomposed ops batch n heads hd f x weights outputBar
      pure (fullSoftmaxXBar result, softmaxGradient result : gradients)

glaGradient :: GlaBlockResult -> [Float]
glaGradient result = concat
  [ fullGlaRmsAttBar result
  , fullGlaWqBar result
  , fullGlaWkBar result
  , fullGlaWvBar result
  , fullGlaWoBar result
  , fullGlaWalphaBar result
  , fullGlaRmsFfBar result
  , fullGlaWgateBar result
  , fullGlaWupBar result
  , fullGlaWdownBar result
  ]

softmaxGradient :: SoftmaxBlockResult -> [Float]
softmaxGradient result = concat
  [ fullSoftmaxRmsAttBar result
  , fullSoftmaxWqBar result
  , fullSoftmaxWkBar result
  , fullSoftmaxWvBar result
  , fullSoftmaxWoBar result
  , fullSoftmaxRmsFfBar result
  , fullSoftmaxWgateBar result
  , fullSoftmaxWupBar result
  , fullSoftmaxWdownBar result
  ]

parseModelWeights :: Config -> [Float] -> IO ([Float], [LayerWeights], [Float])
parseModelWeights cfg params = do
  layout <- either (ioError . userError) pure (namedLayout cfg)
  embedding <- weight "embedding" layout
  layers <- mapM (layerWeights layout) [0 .. layerCount cfg - 1]
  finalRms <- weight "final_rms" layout
  pure (embedding, layers, finalRms)
  where
    weight name layout = case filter ((== name) . sliceName) layout of
      [slice] -> either (ioError . userError) pure (sliceValues slice params)
      [] -> ioError (userError ("missing parameter slice: " ++ name))
      _ -> ioError (userError ("duplicate parameter slice: " ++ name))
    layerWeights layout layer = do
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
        get suffix = weight ("blocks." ++ show layer ++ "." ++ suffix) layout

reverseChunk
  :: PieceOps
  -> Int
  -> Int
  -> Int
  -> Int
  -> [[Float]]
  -> [Float]
  -> [Float]
  -> [Float]
  -> [Float]
  -> [Float]
  -> [Float]
  -> ([Float], [[Float]], [[Float]], [[Float]], [[Float]])
  -> Int
  -> IO ([Float], [[Float]], [[Float]], [[Float]], [[Float]])
reverseChunk ops headGroups chunkCount chunk hd states qScaled kScaled values
    contributions dec interBar
    (futureStateBar, qBars, kBars, vBars, decBars) chunkIndex = do
  state <- indexList "GLA state tape" states chunkIndex
  let chunkElements = chunk * hd
      stateElements = hd * hd
      qChunk = gatherChunk headGroups chunkCount chunkElements chunkIndex qScaled
      kChunk = gatherChunk headGroups chunkCount chunkElements chunkIndex kScaled
      valueChunk = gatherChunk headGroups chunkCount chunkElements chunkIndex values
      contribution = gatherChunk headGroups chunkCount stateElements chunkIndex contributions
      decChunk = gatherChunk headGroups chunkCount hd chunkIndex dec
      interChunkBar = gatherChunk headGroups chunkCount chunkElements chunkIndex interBar
  (qChunkBar, stateInterBar) <- opsBatchedGemmBackward ops NoTrans NoTrans
    headGroups chunk hd hd hd chunk hd qChunk state interChunkBar
  (stateRecurrenceBar, contributionBar, decBar) <-
    opsStateAdvanceBackward ops headGroups hd state contribution decChunk futureStateBar
  stateBar <- opsAddForward ops stateInterBar stateRecurrenceBar
  (kChunkBar, valueChunkBar) <- opsBatchedGemmBackward ops Trans NoTrans
    headGroups chunk hd chunk hd hd hd kChunk valueChunk contributionBar
  pure (stateBar, qChunkBar : qBars, kChunkBar : kBars,
    valueChunkBar : vBars, decBar : decBars)

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

indexList :: String -> [a] -> Int -> IO a
indexList label values index = case drop index values of
  value : _ -> pure value
  [] -> ioError (userError (label ++ " index out of bounds"))

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
