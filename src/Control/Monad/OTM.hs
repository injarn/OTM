{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances #-}

module OTM (
    OTM,
    ITM,
    atomic,
    isolated) where

import Data.Typeable
import Control.Monad.State  -- StateT
import Control.Monad.Except -- ExceptT
import Control.Exception
import Foreign.StablePtr
import Internals


data RetryException = RetryException
    deriving (Show, Typeable)

instance Exception RetryException

class (Monad m) => MonadTransaction m where
    retry :: m a

    --newOTVar :: a -> m (OTVar a)
    --readOTVar :: OTVar a -> m a
    --writeOTVar :: OTVar a -> a -> m ()


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


{-  ITM  -}
newtype ITM a = ITM { unITM :: TM a }
    deriving (Functor, Applicative, Monad)

evalITM :: ITM a -> OTRec -> IO (Either RetryException a)
evalITM itm s = runExceptT . flip evalStateT s $ unITM itm

instance MonadTransaction ITM where
    retry = ITM $ throwError RetryException

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