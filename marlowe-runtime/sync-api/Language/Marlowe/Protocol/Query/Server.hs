{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}

module Language.Marlowe.Protocol.Query.Server
  where

import Control.Concurrent.Async.Lifted (concurrently)
import Control.Monad.Trans.Control (MonadBaseControl)
import Language.Marlowe.Protocol.Query.Types
import Language.Marlowe.Runtime.ChainSync.Api (TxId)
import Language.Marlowe.Runtime.Core.Api (ContractId)
import Language.Marlowe.Runtime.Discovery.Api (ContractHeader)
import Network.TypedProtocol

type MarloweQueryServer = Peer MarloweQuery 'AsServer 'StReq

marloweQueryServer
  :: forall m
   . MonadBaseControl IO m
  => (Range ContractId -> m (Page ContractId ContractHeader))
  -> (ContractId -> m (Maybe SomeContractState))
  -> (TxId -> m (Maybe SomeTransaction))
  -> (ContractId -> m (Maybe SomeTransactions))
  -> MarloweQueryServer m ()
marloweQueryServer getContractHeaders getContractState getTransaction getTransactions = go
  where
    go = Await (ClientAgency TokReq) \case
      MsgRequest req -> Effect do
        result <- serviceRequest req
        pure $ Yield (ServerAgency $ TokRes $ requestToSt req) (MsgRespond result) go
      MsgDone -> Done TokDone ()
    serviceRequest :: Request a -> m a
    serviceRequest = \case
      ReqContractHeaders range -> getContractHeaders range
      ReqContractState contractId -> getContractState contractId
      ReqTransaction txId -> getTransaction txId
      ReqTransactions contractId -> getTransactions contractId
      ReqBoth a b -> concurrently (serviceRequest a) (serviceRequest b)
