{-# LANGUAGE ForeignFunctionInterface #-}

#include "OTM.h"

module Internals where

import Control.Concurrent   -- ThreadId
import Control.Exception
import Data.Word            -- Mapping of HsWord
import Foreign
import Foreign.Concurrent   -- newForeignPtr with arbitrary IO actions
import Foreign.StablePtr
import Foreign.ForeignPtr
import Foreign.Storable
import Foreign.C.Types


newtype OTVar a = OTVar (ForeignPtr (OTVar a))

{#pointer *OTVar as 'OTVar a' foreign newtype nocode#}

-- in marshaller for OTVar
withOTVar :: OTVar a -> (Ptr (OTVar a) -> IO b) -> IO b
withOTVar (OTVar fptr) = withForeignPtr fptr

foreign import ccall unsafe "otmNewOTVar" otmNewOTVar :: StablePtr a -> IO (Ptr (OTVar a))
foreign import ccall unsafe "otmDeleteOTVar" otmDeleteOTVar :: Ptr (OTVar a) -> IO ()


{#pointer *OTRecHeader as OTRec foreign newtype#}

{#fun unsafe find {`OTRec'} -> `OTRec' #}

{#enum OTState {underscoreToCase} deriving (Eq, Show)#}


{#fun unsafe otmStartTransaction {castStablePtrToPtr `StablePtr ThreadId', `OTRec'} -> `OTRec' #}

-- read and write have a spinlock and a tail recursion:
-- they could block the execution of haskell green threads
-- not sure if they can still be marked as unsafe
{#fun unsafe otmReadOTVar {`OTRec', withOTVar* `OTVar a'} -> `StablePtr a' castPtrToStablePtr#}

{#fun unsafe otmWriteOTVar {`OTRec', withOTVar* `OTVar a' , castStablePtrToPtr `StablePtr a' } -> `()' #}

-- This calls must be Safe because are blocking functions
{#fun otmCommit {`OTRec'} -> `OTState' #}
{#fun otmRetry  {`OTRec'} -> `OTState' #}
{#fun otmAbort  {`OTRec', castStablePtrToPtr `StablePtr SomeException'} -> `OTState' #}


{#fun unsafe itmCommitTransaction {`OTRec'} -> `Bool' #}

{#fun unsafe itmReadOTVar {`OTRec', withOTVar* `OTVar a'} -> `StablePtr a' castPtrToStablePtr#}

{#fun unsafe itmWriteOTVar {`OTRec', withOTVar* `OTVar a' , castStablePtrToPtr `StablePtr a' } -> `()' #}

-- atomic helper methods

startOpenTransaction :: IO (OTRec)
startOpenTransaction = do
    tid <- myThreadId
    sp <- newStablePtr tid -- Not sure if it is good idea(thread will not be GC)
    outer <- newForeignPtr_ nullPtr
    otmStartTransaction sp (OTRec outer)

getException :: OTRec -> IO SomeException
getException otrec = do
    ptr <- withOTRec otrec {#get OTRecHeader->state.exception #}
    deRefStablePtr . castPtrToStablePtr $ ptr :: IO SomeException

startIsolatedTransaction :: OTRec -> IO (OTRec)
startIsolatedTransaction outer = do
    tid <- myThreadId
    sp <- newStablePtr tid -- Not sure if it is good idea(thread will not be GC)
    otmStartTransaction sp outer

