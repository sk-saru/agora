{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# OPTIONS_GHC -Wno-unused-matches #-}

-- | Module     : Main
--     Maintainer : emi@haskell.fyi
--     Description: Export scripts given configuration.
--
--     Export scripts given configuration.
module Main (main, GovernorDatumRequest (..)) where

import Agora.Bootstrap qualified as Bootstrap
import Agora.Governor (Governor (Governor), GovernorDatum (GovernorDatum))
import Agora.Proposal (ProposalId (ProposalId), ProposalThresholds (ProposalThresholds))
import Agora.Proposal.Time (MaxTimeRangeWidth (MaxTimeRangeWidth), ProposalTimingConfig (ProposalTimingConfig))
import Agora.SafeMoney (GTTag)
import Agora.Scripts qualified as Scripts
import Agora.Utils (CompiledMintingPolicy (getCompiledMintingPolicy), CompiledValidator (getCompiledValidator))
import Cardano.Binary (Encoding)
import Codec.CBOR.Write qualified as CBOR.Write
import Codec.Serialise.Class (encode)
import Data.Aeson (FromJSON, ToJSON)
import Data.Aeson qualified as Aeson
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Builder.Extra qualified as Builder
import Data.ByteString.Lazy qualified as BSL
import Data.Default (def)
import Data.Function ((&))
import Data.Tagged (Tagged (Tagged))
import Data.Text (Text)
import Data.Text.Encoding (decodeUtf8)
import Development.GitRev (gitBranch, gitHash)
import GHC.Generics qualified as GHC
import Plutarch (Config (Config, tracingMode), TracingMode (DoTracing, NoTracing))
import PlutusLedgerApi.V1
  ( MintingPolicy (getMintingPolicy),
    TxOutRef,
    Validator (getValidator),
  )
import PlutusLedgerApi.V1.Value (AssetClass)
import PlutusLedgerApi.V2 (POSIXTime (POSIXTime), ToData)
import PlutusLedgerApi.V2 qualified as P
import ScriptExport.API (runServer)
import ScriptExport.Options (parseOptions)
import ScriptExport.ScriptInfo (ScriptInfo, mkPolicyInfo, mkScriptInfo, mkValidatorInfo)
import ScriptExport.Types (Builders, insertBuilder)

main :: IO ()
main =
  parseOptions >>= runServer revision builders
  where
    -- This encodes the git revision of the server. It's useful for the caller
    -- to be able to ensure they are compatible with it.
    revision :: Text
    revision = $(gitBranch) <> "@" <> $(gitHash)

-- | Builders for Agora scripts.
--
--     @since 0.2.0
builders :: Builders
builders =
  def
    -- Agora scripts
    & insertBuilder "governorPolicy" ((.governorPolicyInfo) . agoraScripts)
    & insertBuilder "governorValidator" ((.governorValidatorInfo) . agoraScripts)
    & insertBuilder "stakePolicy" ((.stakePolicyInfo) . agoraScripts)
    & insertBuilder "stakeValidator" ((.stakeValidatorInfo) . agoraScripts)
    & insertBuilder "proposalPolicy" ((.proposalPolicyInfo) . agoraScripts)
    & insertBuilder "proposalValidator" ((.proposalValidatorInfo) . agoraScripts)
    & insertBuilder "treasuryValidator" ((.treasuryValidatorInfo) . agoraScripts)
    & insertBuilder "authorityTokenPolicy" ((.authorityTokenPolicyInfo) . agoraScripts)
    -- Trivial scripts. These are useful for testing, but they likely aren't useful
    -- to you if you are actually interested in deploying to mainnet.
    & insertBuilder
      "alwaysSucceedsPolicy"
      (\() -> mkPolicyInfo $ plam $ \_ _ -> popaque (pconstant ()))
    & insertBuilder
      "alwaysSucceedsValidator"
      (\() -> mkValidatorInfo $ plam $ \_ _ _ -> popaque (pconstant ()))
    & insertBuilder
      "neverSucceedsPolicy"
      (\() -> mkPolicyInfo $ plam $ \_ _ -> perror)
    & insertBuilder
      "neverSucceedsValidator"
      (\() -> mkValidatorInfo $ plam $ \_ _ _ -> perror)
    -- Provided Effect scripts
    & insertBuilder "treasuryWithdrawalEffect" ((.treasuryWithdrawalEffectInfo) . agoraScripts)
    -- Provided governor datum
    & insertBuilder
      "governorDatum"
      (dataToCBORText . toGovernorDatum)

toGovernorDatum :: GovernorDatumRequest -> GovernorDatum
toGovernorDatum
  (GovernorDatumRequest [e, c, v] pId [dr, vo, lo, rx] tr pps) =
    GovernorDatum
      (ProposalThresholds (Tagged e) (Tagged c) (Tagged v))
      (ProposalId pId)
      (ProposalTimingConfig (POSIXTime dr) (POSIXTime vo) (POSIXTime lo) (POSIXTime rx))
      (MaxTimeRangeWidth (POSIXTime tr))
      pps
toGovernorDatum _ = error "Wrong governor datum request input"

data GovernorDatumRequest = GovernorDatumRequest
  { gdrProposalThresholds :: [Integer],
    gdrProposalId :: Integer,
    gdrProposalTimingConfig :: [Integer],
    gdrMaxTimeRangeWith :: Integer,
    gdrmaximumProposalsPerStake :: Integer
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

dataToCBORText :: forall a. ToData a => a -> Text
dataToCBORText =
  decodeUtf8
    . Base16.encode
    . BSL.toStrict
    . serializeEncoding
    . encode
    . P.builtinDataToData
    . P.toBuiltinData

serializeEncoding :: Encoding -> BSL.ByteString
serializeEncoding =
  Builder.toLazyByteStringWith strategy mempty . CBOR.Write.toBuilder
  where
    -- 1024 is the size of the first buffer, 4096 is the size of subsequent
    -- buffers. Chosen because they seem to give good performance. They are not
    -- sacred.
    strategy = Builder.safeStrategy 1024 4096

-- | Create scripts from params.
--
--     @since 0.2.0
agoraScripts :: ScriptParams -> AgoraScripts
agoraScripts params =
  AgoraScripts
    { governorPolicyInfo = mkPolicyInfo' scripts.compiledGovernorPolicy,
      governorValidatorInfo = mkValidatorInfo' scripts.compiledGovernorValidator,
      stakePolicyInfo = mkPolicyInfo' scripts.compiledStakePolicy,
      stakeValidatorInfo = mkValidatorInfo' scripts.compiledStakeValidator,
      proposalPolicyInfo = mkPolicyInfo' scripts.compiledProposalPolicy,
      proposalValidatorInfo = mkValidatorInfo' scripts.compiledProposalValidator,
      treasuryValidatorInfo = mkValidatorInfo' scripts.compiledTreasuryValidator,
      authorityTokenPolicyInfo = mkPolicyInfo' scripts.compiledAuthorityTokenPolicy,
      treasuryWithdrawalEffectInfo = mkValidatorInfo' scripts.compiledTreasuryWithdrawalEffect
    }
  where
    governor =
      Agora.Governor.Governor
        params.governorInitialSpend
        params.gtClassRef
        params.maximumCosigners

    scripts = Bootstrap.agoraScripts plutarchConfig governor

    plutarchConfig :: Config
    plutarchConfig = Config {tracingMode = if params.tracing then DoTracing else NoTracing}

-- | Params required for creating script export.
--
--     @since 1.0.0
data ScriptParams = ScriptParams
  { governorInitialSpend :: TxOutRef,
    gtClassRef :: Tagged GTTag AssetClass,
    maximumCosigners :: Integer,
    tracing :: Bool
  }
  deriving anyclass (Aeson.ToJSON, Aeson.FromJSON)
  deriving stock (Show, Eq, GHC.Generic, Ord)

-- | Scripts that get exported.
--
--     @since 0.2.0
data AgoraScripts = AgoraScripts
  { governorPolicyInfo :: ScriptInfo,
    governorValidatorInfo :: ScriptInfo,
    stakePolicyInfo :: ScriptInfo,
    stakeValidatorInfo :: ScriptInfo,
    proposalPolicyInfo :: ScriptInfo,
    proposalValidatorInfo :: ScriptInfo,
    treasuryValidatorInfo :: ScriptInfo,
    authorityTokenPolicyInfo :: ScriptInfo,
    treasuryWithdrawalEffectInfo :: ScriptInfo
  }
  deriving anyclass
    ( -- | @since 0.2.0
      Aeson.ToJSON,
      -- | @since 0.2.0
      Aeson.FromJSON
    )
  deriving stock
    ( -- | @since 0.2.0
      Show,
      -- | @since 0.2.0
      Eq,
      -- | @since 0.2.0
      GHC.Generic
    )

-- | Turn a precompiled minting policy to a 'ScriptInfo'.
--
--     @since 0.2.0
mkPolicyInfo' :: forall redeemer. CompiledMintingPolicy redeemer -> ScriptInfo
mkPolicyInfo' = mkScriptInfo . getMintingPolicy . (.getCompiledMintingPolicy)

-- | Turn a precompiled validator to a 'ScriptInfo'.
--
--     @since 0.2.0
mkValidatorInfo' :: forall redeemer datum. CompiledValidator datum redeemer -> ScriptInfo
mkValidatorInfo' = mkScriptInfo . getValidator . (.getCompiledValidator)
