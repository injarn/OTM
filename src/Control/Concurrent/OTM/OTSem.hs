{-# LANGUAGE DeriveDataTypeable #-}
module Control.Concurrent.OTM.OTSem (
      OTSem, newOTSem, waitOTSem, signalOTSem
  ) where

import Control.Concurrent.OTM
import Control.Monad
import Data.Typeable

-- | 'OTSem' is the OTM equivalent of 'Control.Concurrent.STM.TSem' 
-- i.e. a transactional semaphore.  It holds a certain number of
-- units, and units may be acquired or released by 'waitTSem' and
-- 'signalOTSem' respectively.  When the 'OTSem' is empty, 'waitOTSem'
-- blocks.
--
-- Note that 'OTSem' has no concept of fairness, and there is no
-- guarantee that threads blocked in `waitOTSem` will be unblocked in
-- the same order; in fact they will all be unblocked at the same time
-- and will fight over the 'OTSem'.  Hence 'OTSem' is not suitable if
-- you expect there to be a high number of threads contending for the
-- resource.  However, like other OTM and STM abstractions, 'OTSem' is
-- composable.
newtype OTSem = OTSem (OTVar Int)
  deriving (Eq, Typeable)

newOTSem :: Int -> ITM OTSem
newOTSem i = fmap OTSem (newOTVar i)

waitOTSem :: OTSem -> ITM ()
waitOTSem (OTSem t) = do
  i <- readTVar t
  when (i <= 0) retry
  writeOTVar t $! (i-1)

signalOTSem :: OTSem -> ITM ()
signalOTSem (TSem t) = do
  i <- readOTVar t
  writeOTVar t $! i+1
