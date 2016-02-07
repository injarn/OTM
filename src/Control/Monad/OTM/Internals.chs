{-# LANGUAGE ForeignFunctionInterface #-}

#include "OTM.h"

module Control.Monad.OTM.Internals where

import Control.Concurrent   -- ThreadId
import Control.Exception
import Data.Word            -- Mapping of HsWord
import Debug.Trace
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

-- isolated helper methods

startIsolatedTransaction :: OTRec -> IO (OTRec)
startIsolatedTransaction outer = do
    tid <- myThreadId
    sp <- newStablePtr tid -- Not sure if it is good idea(thread will not be GC)
    otmStartTransaction sp outer


-- utility

getThreadId :: OTRec -> IO (ThreadId)
getThreadId otrec = do 
    ptr <- withOTRec otrec {#get OTRecHeader->thread_id#}
    tid <- deRefStablePtr $ castPtrToStablePtr ptr
    return tid

getState :: OTRec -> IO (OTState)
getState otrec = toEnum . fromIntegral <$> withOTRec otrec {#get OTRecHeader->state.state #}

-- OTVar operations

newOTVarIO:: a -> IO (OTVar a)
newOTVarIO a = do
    value <- newStablePtr a
    ptr <- otmNewOTVar value
    -- finalizer <- mkFinalizer deleteOTVar
    fptr <- Foreign.Concurrent.newForeignPtr ptr $ deleteOTVar ptr
    return $ OTVar fptr

-- TODO: add throwTo before deleting OTVar
deleteOTVar:: Ptr (OTVar a) -> IO ()
deleteOTVar ptr = do
    traceIO $ "Finalizing otvar: " ++ show ptr
    otmDeleteOTVar ptr


-- Wrapers of ffi functions to hide StablePtr operations

-- read in an open transaction
readOTVar':: OTRec -> OTVar a -> IO a
readOTVar' otrec var = do
    -- checkState
    -- otrec <- get
    v <- otmReadOTVar otrec var >>= deRefStablePtr
    return v

-- write in an open transaction
writeOTVar':: OTRec -> OTVar a -> a -> IO ()
writeOTVar' otrec var value = do
        -- checkState
        -- otrec <- get
        s1 <- newStablePtr value
        otmWriteOTVar otrec var s1

-- read in an isolated transaction
readITVar':: OTRec -> OTVar a -> IO a
readITVar' otrec var = do
    -- otrec <- get
    v <- itmReadOTVar otrec var >>= deRefStablePtr
    return v

-- write in an islated transaction
writeITVar':: OTRec -> OTVar a -> a -> IO ()
writeITVar' otrec var value = do
        -- otrec <- get
        s1 <- newStablePtr value
        itmWriteOTVar otrec var s1
