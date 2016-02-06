-- {-# INCLUDE OTM.h #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ScopedTypeVariables #-}

#include "OTM.h"
module OTMs {- (
    OTVar,
    newOTVar,
    otmStartTransaction) -}where

import Control.Concurrent   -- ThreadId
import Control.Applicative  -- <$>, <*>
import Control.Monad.State  -- StateT
import Control.Monad.Except -- ExceptT
import Control.Exception
import Data.Typeable        -- class Typeable a
-- import Control.Monad.Trans
-- import Control.Monad        -- >=>
import Data.Word            -- Mapping of HsWord
import Foreign
import Foreign.Concurrent   -- newForeignPtr with arbitrary IO actions
import Foreign.StablePtr
import Foreign.ForeignPtr
import Foreign.Storable
import Foreign.C.Types

-- Control.Monad.OTM definizione di monadi
-- Control.Monad.OTM.Internals
-- Control.Concurrent.OTM importa tutti i moduli di Control.Concurrent(semafori,..)

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

newOTVarIO:: a -> IO (OTVar a)
newOTVarIO a = do
    value <- newStablePtr a
    ptr <- otmNewOTVar value
    -- finalizer <- mkFinalizer deleteOTVar
    fptr <- Foreign.Concurrent.newForeignPtr ptr $ deleteOTVar ptr
    return $ OTVar fptr

newOTVar:: a -> OTM (OTVar a)
newOTVar = liftIO . newOTVarIO

-- TODO: add throwTo before deleting OTVar
deleteOTVar:: Ptr (OTVar a) -> IO ()
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

{#fun unsafe find {`OTRec'} -> `OTRec' #}
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

{#enum OTState {underscoreToCase} deriving (Eq, Show)#}

propagateException:: OTRec -> IO ()
propagateException otrec = do
    root <- find otrec
    ptr <- withOTRec root {#get OTRecHeader->state.exception #} 
    exp::SomeException <- deRefStablePtr . castPtrToStablePtr $ ptr
    throw exp

checkState:: OTM ()
checkState = do
    otrec <- get
    state <- liftIO $ do 
        otrec <- find otrec
        toEnum . fromIntegral <$> withOTRec otrec {#get OTRecHeader->state.state #}
    case state of
        OtrecRetry -> retry
        OtrecAbort -> retry
        _ -> return ()


--{#pointer *OTRecState as OTRecState newtype nocode#}

data RetryException = RetryException
    deriving (Show, Typeable)

instance Exception RetryException


--type TM = StateT OTRec (ExceptT RetryException IO)

--newtype OTM a = OTM { unOTM :: TM a }
--    deriving Monad

--newtype ITM a = ITM { unITM :: TM a }
--    deriving Monad

--readOTVar' :: OTVar a -> TM a

--readOTVar :: OTVar a -> OTM a
--readOTVar = OTM . readOTVar'


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

{#fun unsafe otmWriteOTVar {`OTRec', withOTVar* `OTVar a' , castStablePtrToPtr `StablePtr a' } -> `()' #}

-- This calls must be Safe because are blocking functions
{#fun otmCommit {`OTRec'} -> `OTState' #}
{#fun otmRetry  {`OTRec'} -> `OTState' #}
{#fun otmAbort  {`OTRec', castStablePtrToPtr `StablePtr SomeException'} -> `OTState' #}

startTransaction :: IO (OTRec)
startTransaction = do
    tid <- myThreadId
    sp <- newStablePtr tid
    outer <- newForeignPtr_ nullPtr
    otmStartTransaction sp (OTRec outer)

readOTVar:: OTVar a -> OTM a
readOTVar var = do
    checkState
    otrec <- get
    v <- liftIO $ do otmReadOTVar otrec var >>= deRefStablePtr
    return v

writeOTVar:: OTVar a -> a -> OTM ()
writeOTVar var value = do
        checkState
        otrec <- get
        s1 <- liftIO $ newStablePtr value
        liftIO $ otmWriteOTVar otrec var s1

retry:: (Monad m) => OTMT m a
retry = throwError RetryException

--abort:: OTM ()
abort :: (Monad m, Integral n) => m n
abort = do
    --evaluate (5 `div` 0) :: IO Int
    return $! 5 `div` 0 

otmHandleTransaction:: OTRec -> OTM a -> OTState -> IO a
otmHandleTransaction otrec otm state = do
    case state of
        OtrecRetryed  -> atomic otm
        OtrecAborted  -> do
            root <- find otrec
            ptr <- withOTRec otrec {#get OTRecHeader->state.exception #} 
            exp::SomeException <- deRefStablePtr . castPtrToStablePtr $ ptr
            throw exp
        _ -> error "Invalid state" 


atomic:: forall a . OTM a -> IO a -- (Either SomeException (Either RetryException a))
atomic otm = do
    otrec <- startTransaction
    result <- try $ runOTM otm otrec :: IO (Either SomeException (Either RetryException a))
    case result of
        Left se -> do
            exp <- newStablePtr se
            state <- otmAbort otrec exp
            otmHandleTransaction otrec otm state
        Right computation ->  case computation of
            Left _ -> do
                state <- otmRetry otrec
                otmHandleTransaction otrec otm state
            Right v -> do
                state <- otmCommit otrec
                case state of
                    OtrecCommited -> return v
                    _ -> otmHandleTransaction otrec otm state

{---------- ITM ----------}

type ITM a = OTMT IO a

runITM :: ITM a -> OTRec -> IO (Either RetryException a)
runITM = runOTMT

{#fun unsafe itmCommitTransaction {`OTRec'} -> `Bool' #}

{#fun unsafe itmReadOTVar {`OTRec', withOTVar* `OTVar a'} -> `StablePtr a' castPtrToStablePtr#}

{#fun unsafe itmWriteOTVar {`OTRec', withOTVar* `OTVar a' , castStablePtrToPtr `StablePtr a' } -> `()' #}


readITVar:: OTVar a -> ITM a
readITVar var = do
    otrec <- get
    v <- liftIO $ do itmReadOTVar otrec var >>= deRefStablePtr
    return v

writeITVar:: OTVar a -> a -> ITM ()
writeITVar var value = do
        otrec <- get
        s1 <- liftIO $ newStablePtr value
        liftIO $ itmWriteOTVar otrec var s1

isolated :: forall a . ITM a -> OTM a
isolated itm = do
    sp <- liftIO $ do 
        tid <- myThreadId
        newStablePtr tid
    outer <- get
    itrec <- liftIO $ otmStartTransaction sp outer
    result <- liftIO $ do
        try $ runITM itm itrec :: IO (Either SomeException (Either RetryException a))
    case result of
        Left se -> liftIO $ do
            throw se
        Right computation -> case computation of
            Left err -> retry
            Right v -> do
                valid <- liftIO $ itmCommitTransaction itrec
                case valid of
                    True -> return v
                    _ -> retry
