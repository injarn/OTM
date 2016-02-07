{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances #-}

module Control.Monad.OTM (
    OTM,
    ITM,
    atomic,
    isolated,
    retry,
    abort,
    unsafeIOToOTM,
    unsafeIOToITM,
    newOTVarIO,
    newOTVar,
    readOTVar,
    writeOTVar) where

import Data.Typeable
import Control.Monad.State  -- StateT
import Control.Monad.Except -- ExceptT
import Control.Exception
import Foreign.StablePtr
import Control.Monad.OTM.Internals


data RetryException = RetryException
    deriving (Show, Typeable)

instance Exception RetryException

class TransactionalMemory a where


class (Monad m) => MonadTransaction m where
    retry :: m a
    -- oreElse :: m a -> m a -> m a

-- Monad Transactional Memory
class (Monad m) => MonadTM m where
    newOTVar :: a -> m (OTVar a)
    readOTVar :: OTVar a -> m a
    writeOTVar :: OTVar a -> a -> m ()

    

type TM = StateT OTRec (ExceptT RetryException IO)

instance MonadTransaction TM where
    retry = throwError RetryException

{-  OTM  -}
newtype OTM a = OTM { unOTM :: TM a }
    deriving (Functor, Applicative, Monad)

evalOTM :: OTM a -> OTRec -> IO (Either RetryException a)
evalOTM otm s = runExceptT . flip evalStateT s $ unOTM otm

instance MonadTransaction OTM where
    retry = OTM $ throwError RetryException

instance MonadTM OTM where
    newOTVar = OTM . liftIO . newOTVarIO
    readOTVar otvar = do 
        checkState
        OTM $ do
            otrec <- get
            liftIO $ readOTVar' otrec otvar
    writeOTVar otvar value = do
        checkState
        OTM $ do
            otrec <- get
            liftIO $ writeOTVar' otrec otvar value



{-  ITM  -}
newtype ITM a = ITM { unITM :: TM a }
    deriving (Functor, Applicative, Monad)

evalITM :: ITM a -> OTRec -> IO (Either RetryException a)
evalITM itm s = runExceptT . flip evalStateT s $ unITM itm

instance MonadTransaction ITM where
    retry = ITM $ throwError RetryException

instance MonadTM ITM where
    newOTVar = ITM . liftIO . newOTVarIO
    readOTVar otvar = ITM $ do
        otrec <- get
        liftIO $ readITVar' otrec otvar
    writeOTVar otvar value = ITM $ do
        otrec <- get
        liftIO $ writeITVar' otrec otvar value

otmHandleTransaction:: OTRec -> OTM a -> OTState -> IO a
otmHandleTransaction otrec otm state = do
    case state of
        OtrecRetryed  -> atomic otm
        OtrecAborted  -> do
            exp <- getException otrec
            throw exp
        _ -> error "Invalid state" 

atomic:: forall a . OTM a -> IO a
atomic otm = do
    otrec <- startOpenTransaction
    result <- try $ evalOTM otm otrec :: IO (Either SomeException (Either RetryException a))
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

--isolated :: forall a . ITM a -> OTM a
--isolated itm = do
--    outer <- OTM get
--    itrec <- OTM . liftIO $ startIsolatedTransaction outer
--    result <- OTM . liftIO $ do
--        try $ evalITM itm itrec :: IO (Either SomeException (Either RetryException a))
--    case result of
--        Left se -> OTM . liftIO $ do
--            throw se
--        Right computation -> case computation of
--            Left err -> retry
--            Right v -> do
--                valid <- OTM . liftIO $ itmCommitTransaction itrec
--                case valid of
--                    True -> return v
--                    _ -> retry
isolated :: ITM a -> OTM a
isolated = OTM . isolated'

isolated' :: forall a . ITM a -> TM a
isolated' itm = do
    outer <- get
    itrec <- liftIO $ startIsolatedTransaction outer
    result <- liftIO $ do
        try $ evalITM itm itrec :: IO (Either SomeException (Either RetryException a))
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

checkState:: OTM ()
checkState = OTM $ do
    otrec <- get
    state <- liftIO $ do 
        otrec <- find otrec
        getState otrec
    case state of
        OtrecRetry -> retry
        OtrecAbort -> retry
        _ -> return ()


unsafeIOToOTM :: IO a -> OTM a
unsafeIOToOTM = OTM . liftIO

unsafeIOToITM :: IO a -> ITM a
unsafeIOToITM = ITM . liftIO

abort :: (Monad m, Integral n) => m n
abort = do
    return $! 5 `div` 0 


