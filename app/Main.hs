module Main where

import Lib
import OTMs
-- import OTM
import Foreign.StablePtr
import Control.Monad.State -- liftIO
main :: IO ()
main = do
    atomic $ do
        otvar <- newOTVar (5::Integer)
        writeOTVar otvar 10
        v <- readOTVar otvar
        liftIO $ putStrLn . show $ v
        isolated $ return v
    putStrLn "End!"
    atomic $ do
        abort
    atomic $ do
        retry
    --someFunc
    --trec <- startTransaction
    --let a = Just 5
    --s1 <- newStablePtr a
    --s2 <- newStablePtr a
    --if (compareStablePtr s1 s2)
    --then putStrLn "C'è speranza"
    --else putStrLn "Zero"
    --v <- newOTVar 5
    --b <- otmReadOTVar trec v
    --c <- otmReadOTVar trec v
    --if (b == c)
    --then putStrLn "Equal!"
    --else putStrLn "Not Equal!"
    --f <- readOTVar trec v
    --g <- writeOTVar trec v 5
