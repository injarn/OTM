-- {-# INCLUDE OTM.h #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

#include "OTM.h"
module OTM {- (
    OTVar,
    newOTVar,
    otmStartTransaction) -}where

import Control.Concurrent   -- ThreadId
import Control.Monad.State  -- StateT
import Control.Monad.Except -- ExceptT
import Control.Exception
import Data.Typeable        -- class Typeable a
-- import Control.Monad.Trans
-- import Control.Monad        -- >=>
import Data.Word            -- Mapping of HsWord
import Foreign
import Foreign.Concurrent -- newForeignPtr with arbitrary IO actions
import Foreign.StablePtr
import Foreign.ForeignPtr
import Foreign.Storable
import Foreign.C.Types


foreign import ccall "compareStablePtr" compareStablePtr :: StablePtr a -> StablePtr a -> Bool

newtype OTVar a = OTVar (ForeignPtr (OTVar a))

{#pointer *OTVar as 'OTVar a' foreign newtype nocode#}

withOTVar :: OTVar a -> (Ptr (OTVar a) -> IO b) -> IO b
withOTVar (OTVar fptr) = withForeignPtr fptr

foreign import ccall "stdlib.h &free"
    p_free :: FunPtr (Ptr a -> IO ())

foreign import ccall "dynamic"  
    mkFree :: FunPtr (Ptr a -> IO ()) -> (Ptr a -> IO ())

-- Funziona benissimo ma è deprecato:
--OTM-exe: error: a C finalizer called back into Haskell.
   --This was previously allowed, but is disallowed in GHC 6.10.2 and later.
   --To create finalizers that may call back into Haskell, use
   --Foreign.Concurrent.newForeignPtr instead of Foreign.newForeignPtr.

--foreign import ccall "wrapper"
--  mkFinalizer :: (Ptr a -> IO ()) -> IO (FunPtr (Ptr a -> IO ()))

foreign import ccall unsafe "otmNewOTVar" otmNewOTVar :: StablePtr a -> IO (Ptr (OTVar a))
foreign import ccall unsafe "otmDeleteOTVar" otmDeleteOTVar :: Ptr (OTVar a) -> IO ()

newOTVar :: a -> IO (OTVar a)
newOTVar a = do
    value <- newStablePtr a
    ptr <- otmNewOTVar value
    -- finalizer <- mkFinalizer deleteOTVar
    fptr <- Foreign.Concurrent.newForeignPtr ptr $ deleteOTVar ptr
    return $ OTVar fptr

-- TODO: add throwTo before deleting OTVar
deleteOTVar :: Ptr (OTVar a) -> IO ()
deleteOTVar ptr = do
    otmDeleteOTVar ptr
-- ThrowTo BlockIndefinitelyOnOTM

--throwToWatchQueue :: Exception e => (Ptr OTVarWatchQueue) -> e -> IO ()
--throwToWatchQueue ptr = do
--    if (ptr == nullPtr)
--    then return ()
--    else

-- TODO: OTRec needs a finalizer
{#pointer *OTRecHeader as OTRec foreign newtype#}

--data OTState = 
--    OtrecLocked Word
--    | OtrecRunning Word
--    | OtrecCommitt Word
--    | OtrecRetry Word
--    | OtrecAbort SomeException
--    | OtrecCommitted
--    | OtrecRetryed
--    | OtrecAborted
--    | OtrecWaiting
--    | OtrecCondemned

{#enum OTState {underscoreToCase} deriving (Eq)#}
{#pointer *OTRecState as OTRecState newtype nocode#}
--stateOutMarshaller :: Ptr OTRecState -> IO (OTRecState)
--stateOutMarshaller ptr = do
--    s <- liftM . toEnum $ {#get OTRecState->state#} ptr
--    case s of
--        OtrecLocked
--        OtrecRunning
--        OtrecCommitt
--        OtrecRetry
--        OtrecAbort
--        OtrecCommitted
--        OtrecRetryed
--        OtrecAborted
--        OtrecWaiting
--        OtrecCondemned


--newtype ParserT m a = ParserT {unParserT :: StateT AlexInput (ExceptT String m) a}
--  deriving(Monad, MonadState AlexState, MonadError String, Functor, Applicative, MonadIO)

data RetryException = RetryException
 deriving (Show, Typeable)

instance Exception RetryException

newtype OTMT m a = OTMT { unOTMT :: StateT OTRec (ExceptT RetryException m) a }
    deriving(Monad, MonadState OTRec, MonadError RetryException, Functor, Applicative, MonadIO)

type OTM a = OTMT IO a

runOTMT :: (Monad m) => OTMT m a -> OTRec -> m (Either RetryException a)
runOTMT otmt s = runExceptT . flip evalStateT s $ unOTMT otmt

runOTM :: OTM a -> OTRec -> IO (Either RetryException a)
runOTM = runOTMT

getThreadId :: OTRec -> IO (ThreadId)
getThreadId otrec = do 
    ptr <- withOTRec otrec {#get OTRecHeader->thread_id#}
    tid <- deRefStablePtr $ castPtrToStablePtr ptr
    return tid

-- foreign import ccall "otmStartTransaction" otmStartTransaction :: StablePtr a -> IO (OTRec)
{#fun unsafe otmStartTransaction {castStablePtrToPtr `StablePtr ThreadId', `OTRec'} -> `OTRec' #}

{#fun unsafe otmReadOTVar {`OTRec', withOTVar* `OTVar a'} -> `StablePtr a' castPtrToStablePtr#}
-- TODO: remember to free the returned stableptr
{#fun unsafe otmWriteOTVar {`OTRec', withOTVar* `OTVar a' , castStablePtrToPtr `StablePtr a' } -> `()' #}

startTransaction :: IO (OTRec)
startTransaction = do
    tid <- myThreadId
    sp <- newStablePtr tid
    outer <- newForeignPtr_ nullPtr
    otmStartTransaction sp (OTRec outer)

readOTVar:: OTVar a -> OTM a
readOTVar var = do
    otrec <- get
    v <- liftIO $ do otmReadOTVar otrec var >>= deRefStablePtr
    return v

writeOTVar:: OTVar a -> a -> OTM ()
writeOTVar var value = do
        otrec <- get
        s1 <- liftIO $ newStablePtr value
        liftIO $ otmWriteOTVar otrec var s1
