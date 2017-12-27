--------------------------------------------------------------------------------
-- |
-- Module      :  Control.Monad.Progress
-- Copyright   :  (c) 2016 Chordify B.V., Groningen
-- License     :  LGPL-3
--
-- Maintainer  :  haskelldevelopers@chordify.net
-- Stability   :  stable
-- Portability :  non-portable
--
-- Summary: Functionality for reporting function progress.
--
--------------------------------------------------------------------------------

{-# LANGUAGE GADTs #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Control.Monad.Progress (
  -- * Data types
  WithProgress,

  -- * Exported functions
  runWithProgress,
  runWithPercentage,
  withProgressFromList,
  withProgressM,
  setWeight,
  printComponentTime,

  -- * Combining progress
  (C.>>>),
  Arrow (..)
  ) where

import Control.DeepSeq
import Control.Monad       ( forM_, when )
import Control.Monad.Trans ( MonadIO (..) )
import Control.Arrow       ( Arrow (..) )
import qualified Control.Category as C

import Data.List           ( genericLength )
import Data.IORef          ( newIORef, atomicModifyIORef', readIORef )
import Data.Time           ( getCurrentTime )

--------------------------------------------------------------------------------  
-- Data type
--------------------------------------------------------------------------------

data WithProgress m a b where
  Id            :: WithProgress m a a
  WithProgressM :: ((Double -> m ()) -> a -> m b)           -> WithProgress m a b
  Combine       :: WithProgress m b c -> WithProgress m a b -> WithProgress m a c
  SetWeight     :: Double             -> WithProgress m a b -> WithProgress m a b
  First         ::                       WithProgress m a b -> WithProgress m (a,c) (b,c)
  Second        ::                       WithProgress m a b -> WithProgress m (c,a) (c,b)

instance C.Category (WithProgress m) where
  id  = Id
  (.) = Combine

instance Monad m => Arrow (WithProgress m) where
  arr = error "WithProgress instances cannot directly be instantiated from pure\
              \ functions"
  first   = First
  second  = Second
  f *** g = First f C.>>> Second g
  f &&& g = WithProgressM (\_ b -> return (b,b)) C.>>> f *** g

--------------------------------------------------------------------------------  
-- Functionality
--------------------------------------------------------------------------------

-- | From a function @a -> [b]@, construct a function that can reports its progress.
--   Important remark: The resulting list must __not__ be lazily constructed, it
--   should be immediately possible to compute the length of this list in order
--   for 'withProgressFromList' to work correctly.
withProgressFromList :: forall a b m. (Monad m, NFData b) => (a -> [b]) -> WithProgress m a [b]
withProgressFromList f = WithProgressM ret where
  ret :: (Double -> m ()) -> a -> m [b]
  ret report input = do
    -- Start with reporting 0 progress
    report 0
    
    -- First construct output list to find its length
    let output = f input
    let len :: Double
        len = genericLength output

    -- Now force evaluation of every element and report progress
    forM_ (zip [1..] output) $ \(n,el) -> do
      () <- deepseq el $ return ()
      report $ n / len

    -- Corner-case, make sure we always report 1 even when list is empty
    when (null output) $ report 1

    -- Return the output
    return output

-- | Set the weight of a pipeline element (default is 1).
setWeight :: Double -> WithProgress m a b -> WithProgress m a b
setWeight = SetWeight

-- | Construct a function that reports its own progress. This function must call
--   the given function to report progress as a fraction between 0 and 1.
withProgressM :: ((Double -> m ()) -> a -> m b) -> WithProgress m a b
withProgressM f = WithProgressM f

-- | Run a computation with progress reporting. The given function will be called
--   each time the progress is updated, and the number is always between 0 and 1.
runWithProgress :: Monad m => WithProgress m a b -> (Double -> m ()) -> a -> m b
runWithProgress Id r a = r 1 >> return a
runWithProgress p  r a = runWithProgress' p (r . (/w)) a where
  w = getWeight p

-- | Run a computation with progress reporting. The given function will be called
--   at most once per percentage, which is a number between 0 and 100.
runWithPercentage :: MonadIO m => WithProgress m a b -> (Int -> m ()) -> a -> m b
runWithPercentage Id r a = r 100 >> return a
runWithPercentage p  r a = do
  let w = getWeight p
  r 0
  prevR <- liftIO $ newIORef 0
  let report d = do
        let new = floor $ (/w) $ (*100) d
        isNew <- liftIO $ atomicModifyIORef' prevR $ \prev -> (new, prev /= new)
        when isNew $ r new
  ret <- runWithProgress' p report a
  final <- liftIO $ readIORef prevR
  when (final /= 100) $ report 100
  return ret

-- | Internal function for actually running the computation, which does not do the
--   scaling of the total weight, so the reported number is between 0 and getWeight p
runWithProgress' :: Monad m => WithProgress m a b -> (Double -> m ()) -> a -> m b
runWithProgress' Id                _ a = return a
runWithProgress' (WithProgressM p) r a = p r a
runWithProgress' (SetWeight w p)   r a = runWithProgress' p (r . (*w) . (/wp)) a where
  wp = getWeight p
runWithProgress' (Combine q p)     r a = runWithProgress' p r a >>= runWithProgress' q (r . (+wp)) where
  wp = getWeight p
runWithProgress' (First p)         r (a,c) = runWithProgress' p r a >>= \b -> return (b,c)
runWithProgress' (Second p)        r (c,a) = runWithProgress' p r a >>= \b -> return (c,b)
  

-- | Run the computation with progress reporting, and measure the time of each
--   component and print that to the screen. This function can be used to decide
--   what the weight of each component should be.
printComponentTime :: MonadIO m => WithProgress m a b -> a -> m b
printComponentTime c a = printTime >> f c a >>= \r -> printTime >> return r where
  f :: MonadIO m => WithProgress m a b -> a -> m b
  f Id                a' = return a'
  f (SetWeight _ p)   a' = f p a'
  f (WithProgressM p) a' = p (const $ return ()) a'
  f (Combine q p)     a' = f p a' >>= \b -> printTime >> f q b
  f (First p)         (a',c') = f p a' >>= \b -> return (b,c')
  f (Second p)        (c',a') = f p a' >>= \b -> return (c',b)

-- | Print the current time to stdout
printTime :: MonadIO m => m ()
printTime = liftIO (getCurrentTime >>= print)

-- | Get the weight of a computation with progress
getWeight :: WithProgress m a b -> Double
getWeight Id                = 0
getWeight (WithProgressM _) = 1
getWeight (Combine p q)     = getWeight p + getWeight q
getWeight (SetWeight w _)   = w
getWeight (First p)         = getWeight p
getWeight (Second p)        = getWeight p
