module Marlowe.Market (contractTemplates) where

-- At some point we will want to keep contract templates in a database. In the
-- meantime, this is a simple solution to get things up and running.
import Examples.PureScript.ContractForDifferences as ContractForDifferences
import Examples.PureScript.Escrow as Escrow
import Examples.PureScript.ZeroCouponBond as ZeroCouponBond
import Language.Marlowe.Extended.V1 (Module)

contractTemplates :: Array Module
contractTemplates =
  [ Escrow.contractModule
  , ZeroCouponBond.contractModule
  , ContractForDifferences.contractModule
  ]
