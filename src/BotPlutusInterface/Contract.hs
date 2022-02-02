{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE RankNTypes #-}

module BotPlutusInterface.Contract (runContract, handleContract) where

import BotPlutusInterface.CardanoCLI qualified as CardanoCLI
import BotPlutusInterface.Effects (
  PABEffect,
  createDirectoryIfMissing,
  threadDelay,
  handlePABEffect,
  logToContract,
  printLog,
  queryChainIndex,
  threadDelay,
 )
import BotPlutusInterface.Files qualified as Files
import BotPlutusInterface.PreBalance qualified as PreBalance
import BotPlutusInterface.Types (ContractEnvironment (..), LogLevel (Debug), Tip (slot))
import Control.Lens ((^.))
import Control.Monad.Freer (Eff, Member, interpret, reinterpret, runM, subsume, type (~>))
import Control.Monad.Freer.Error (runError)
import Control.Monad.Freer.Extras.Log (handleLogIgnore)
import Control.Monad.Freer.Extras.Modify (raiseEnd)
import Control.Monad.Freer.Writer (Writer (Tell))
import Data.Aeson (ToJSON, Value)
import Data.Default (Default (def))
import Data.Either (isRight)
import Data.Kind (Type)
import Data.Map qualified as Map
import Data.Row (Row)
import Data.Text qualified as Text
import Ledger (POSIXTime)
import Ledger.Address (PaymentPubKeyHash (PaymentPubKeyHash))
import Ledger.Constraints.OffChain (UnbalancedTx (..))
import Ledger.Slot (Slot (Slot))
import Ledger.TimeSlot (slotToEndPOSIXTime)
import Ledger.Tx (CardanoTx)
import Ledger.Tx qualified as Tx
import Plutus.ChainIndex.Types (RollbackState (Committed), TxValidity (..))
import Plutus.Contract.Checkpoint (Checkpoint (..))
import Plutus.Contract.Effects (
  BalanceTxResponse (..),
  PABReq (..),
  PABResp (..),
  WriteBalancedTxResponse (..),
 )
import Plutus.Contract.Resumable (Resumable (..))
import Plutus.Contract.Types (Contract (..), ContractEffs)
import Wallet.Emulator.Error (WalletAPIError (..))
import Wallet.Emulator.Types (Wallet)
import Prelude

runContract ::
  forall (w :: Type) (s :: Row Type) (e :: Type) (a :: Type).
  (ToJSON w, Monoid w) =>
  ContractEnvironment w ->
  Wallet ->
  Contract w s e a ->
  IO (Either e a)
runContract contractEnv _ (Contract effs) = do
  runM $ handlePABEffect @w contractEnv $ raiseEnd $ handleContract contractEnv effs

handleContract ::
  forall (w :: Type) (e :: Type) (a :: Type).
  (ToJSON w, Monoid w) =>
  ContractEnvironment w ->
  Eff (ContractEffs w e) a ->
  Eff '[PABEffect w] (Either e a)
handleContract contractEnv =
  subsume @(PABEffect w)
    . handleResumable contractEnv
    . handleCheckpointIgnore
    . handleWriter
    . handleLogIgnore @Value
    . runError
    . raiseEnd

handleWriter ::
  forall (w :: Type) (effs :: [Type -> Type]).
  (ToJSON w, Monoid w) =>
  (Member (PABEffect w) effs) =>
  Eff (Writer w ': effs)
    ~> Eff effs
handleWriter =
  interpret
    (\case Tell msg -> logToContract msg)

handleResumable ::
  forall (w :: Type) (effs :: [Type -> Type]).
  ContractEnvironment w ->
  Eff (Resumable PABResp PABReq ': effs) ~> Eff (PABEffect w ': effs)
handleResumable contractEnv =
  reinterpret
    ( \case
        RRequest o -> handlePABReq @w contractEnv o
        RSelect -> pure True
        RZero -> undefined
    )

-- | Mocking checkpoint calls
handleCheckpointIgnore :: forall (effs :: [Type -> Type]). Eff (Checkpoint ': effs) ~> Eff effs
handleCheckpointIgnore =
  interpret
    ( \case
        DoCheckpoint -> pure ()
        AllocateKey -> pure 1
        Store {} -> pure ()
        Retrieve {} -> pure (Right Nothing)
    )

{- | Interpreting contract monad into CLI calls and chain index requests
 A few of these effects are not handled, these just return some dummy result to make the
 type system happy
-}
handlePABReq ::
  forall (w :: Type) (effs :: [Type -> Type]).
  Member (PABEffect w) effs =>
  ContractEnvironment w ->
  PABReq ->
  Eff effs PABResp
handlePABReq contractEnv req = do
  printLog @w Debug $ show req
  resp <- case req of
    ----------------------
    -- Handled requests --
    ----------------------
    OwnPaymentPublicKeyHashReq ->
      -- TODO: Should be able to get this from the wallet, hardcoded for now
      pure $ OwnPaymentPublicKeyHashResp $ PaymentPubKeyHash $ contractEnv.cePABConfig.pcOwnPubKeyHash
    OwnContractInstanceIdReq ->
      pure $ OwnContractInstanceIdResp (ceContractInstanceId contractEnv)
    ChainIndexQueryReq query ->
      ChainIndexQueryResp <$> queryChainIndex @w query
    BalanceTxReq unbalancedTx ->
      BalanceTxResp <$> balanceTx @w contractEnv unbalancedTx
    WriteBalancedTxReq tx ->
      WriteBalancedTxResp <$> writeBalancedTx @w contractEnv tx
    AwaitSlotReq s -> AwaitSlotResp <$> awaitSlot @w contractEnv s
    CurrentSlotReq -> CurrentSlotResp <$> currentSlot @w contractEnv
    CurrentTimeReq -> CurrentTimeResp <$> currentTime @w contractEnv
    ------------------------
    -- Unhandled requests --
    ------------------------
    -- AwaitTimeReq t -> pure $ AwaitTimeResp t
    -- AwaitUtxoSpentReq txOutRef -> pure $ AwaitUtxoSpentResp ChainIndexTx
    -- AwaitUtxoProducedReq Address -> pure $ AwaitUtxoProducedResp (NonEmpty ChainIndexTx)
    AwaitTxStatusChangeReq txId -> pure $ AwaitTxStatusChangeResp txId (Committed TxValid ())
    -- ExposeEndpointReq ActiveEndpoint -> ExposeEndpointResp EndpointDescription (EndpointValue JSON.Value)
    -- PosixTimeRangeToContainedSlotRangeReq POSIXTimeRange -> PosixTimeRangeToContainedSlotRangeResp (Either SlotConversionError SlotRange)
    unsupported -> error ("Unsupported PAB effect: " ++ show unsupported)

  printLog @w Debug $ show resp
  pure resp

-- | This is not identical to the real balancing, we only do a pre-balance at this stage
balanceTx ::
  forall (w :: Type) (effs :: [Type -> Type]).
  Member (PABEffect w) effs =>
  ContractEnvironment w ->
  UnbalancedTx ->
  Eff effs BalanceTxResponse
balanceTx contractEnv unbalancedTx = do
  -- TODO: Handle paging
  -- (_, Page {pageItems}) <-
  --   chainIndexQueryMany $
  --     ChainIndexClient.getUtxoAtAddress $
  --       addressCredential ownAddress
  -- chainIndexTxOuts <- traverse (chainIndexQueryOne . ChainIndexClient.getTxOut) pageItems
  -- let utxos =
  --       Map.fromList $
  --         catMaybes $ zipWith (\oref txout -> (,) <$> Just oref <*> txout) pageItems chainIndexTxOuts

  eitherPreBalancedTx <-
    PreBalance.preBalanceTxIO @w
      contractEnv.cePABConfig
      (contractEnv.cePABConfig.pcOwnPubKeyHash)
      unbalancedTx

  pure $ either (BalanceTxFailed . InsufficientFunds) (BalanceTxSuccess . Right) eitherPreBalancedTx

-- | This step would build tx files, write them to disk and submit them to the chain
writeBalancedTx ::
  forall (w :: Type) (effs :: [Type -> Type]).
  Member (PABEffect w) effs =>
  ContractEnvironment w ->
  CardanoTx ->
  Eff effs WriteBalancedTxResponse
writeBalancedTx _ (Left _) = error "Cannot handle cardano api tx"
writeBalancedTx contractEnv (Right tx) = do
  createDirectoryIfMissing @w False (Text.unpack contractEnv.cePABConfig.pcScriptFileDir)

  fileWriteRes <-
    Files.writeAll @w contractEnv.cePABConfig tx

  case fileWriteRes of
    Left err ->
      pure $
        WriteBalancedTxFailed $
          OtherError $
            "Failed to write script file(s): " <> Text.pack (show err)
    Right _ -> do
      let ownPkh = contractEnv.cePABConfig.pcOwnPubKeyHash
      let requiredSigners = Map.keys $ tx ^. Tx.signatures
      privKeys <- either (error . Text.unpack) id <$> Files.readPrivateKeys @w contractEnv.cePABConfig

      CardanoCLI.uploadFiles @w contractEnv.cePABConfig

      CardanoCLI.buildTx @w contractEnv.cePABConfig privKeys ownPkh CardanoCLI.BuildAuto tx
      res <- CardanoCLI.signTx @w contractEnv.cePABConfig privKeys tx requiredSigners

      result <-
        if contractEnv.cePABConfig.pcDryRun || isRight res
          then pure Nothing
          else CardanoCLI.submitTx @w contractEnv.cePABConfig tx

      pure $ maybe (WriteBalancedTxSuccess (Right tx)) (WriteBalancedTxFailed . OtherError) result

{- | Wait for at least n slots. The slot number only changes when a new block is appended to the chain
 so it waits for at least one block
-}
awaitSlot ::
  forall (w :: Type) (effs :: [Type -> Type]).
  Member (PABEffect w) effs =>
  ContractEnvironment w ->
  Slot ->
  Eff effs Slot
awaitSlot contractEnv (Slot n) = do
  tip <- CardanoCLI.queryTip @w contractEnv.cePABConfig
  waitNSlots' tip.slot
  where
    waitNSlots' refSlot = do
      threadDelay @w 10_000_000
      tip' <- CardanoCLI.queryTip @w contractEnv.cePABConfig
      if tip'.slot < n
        then waitNSlots' refSlot
        else pure $ Slot tip'.slot

currentSlot ::
  forall (w :: Type) (effs :: [Type -> Type]).
  Member (PABEffect w) effs =>
  ContractEnvironment w ->
  Eff effs Slot
currentSlot contractEnv =
  Slot . slot <$> CardanoCLI.queryTip @w contractEnv.cePABConfig

currentTime ::
  forall (w :: Type) (effs :: [Type -> Type]).
  Member (PABEffect w) effs =>
  ContractEnvironment w ->
  Eff effs POSIXTime
currentTime contractEnv =
  slotToEndPOSIXTime def <$> currentSlot @w contractEnv
