{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE GADTs             #-}
{-# LANGUAGE OverloadedStrings #-}
--------------------------------------------------------------------------------
-- |
-- Module : Database.EventStore.Internal.Operation.Catchup
-- Copyright : (C) 2015 Yorick Laupa
-- License : (see the file LICENSE)
--
-- Maintainer : Yorick Laupa <yo.eight@gmail.com>
-- Stability : provisional
-- Portability : non-portable
--
--------------------------------------------------------------------------------
module Database.EventStore.Internal.Operation.Catchup
    ( CatchupState(..)
    , CatchupOpResult(..)
    , Checkpoint(..)
    , catchup
    ) where

--------------------------------------------------------------------------------
import Data.Int
import Data.Maybe

--------------------------------------------------------------------------------
import Database.EventStore.Internal.Operation
import Database.EventStore.Internal.Operation.Read.Common
import Database.EventStore.Internal.Operation.ReadAllEvents
import Database.EventStore.Internal.Operation.ReadStreamEvents
import Database.EventStore.Internal.Operation.Volatile
import Database.EventStore.Internal.Prelude
import Database.EventStore.Internal.Settings
import Database.EventStore.Internal.Stream
import Database.EventStore.Internal.Subscription.Types
import Database.EventStore.Internal.Types

--------------------------------------------------------------------------------
-- | Represents the next checkpoint to reach on a catchup subscription. Wheither
--   it's a regular stream or the $all stream, it either point to an 'Int32' or
--   a 'Position'.
data Checkpoint = CheckpointNumber Int32 | CheckpointPosition Position

--------------------------------------------------------------------------------
defaultBatchSize :: Int32
defaultBatchSize = 500

--------------------------------------------------------------------------------
streamNotFound :: Text -> OperationError
streamNotFound stream = StreamNotFound stream

--------------------------------------------------------------------------------
-- | Catchup operation state.
data CatchupState
    = RegularCatchup Text Int64
      -- ^ Indicates the stream name and the next event number to start from.
    | AllCatchup Position
      -- ^ Indicates the commit and prepare position. Used when catching up from
      --   the $all stream.
    deriving Show

--------------------------------------------------------------------------------
fetch :: Settings
      -> Int32
      -> Bool
      -> CatchupState
      -> Maybe Credentials
      -> Code o SomeSlice
fetch setts batch tos state cred =
    case state of
        RegularCatchup stream n -> do
            outcome <- deconstruct $ fmap Left $
                           readStreamEvents setts Forward stream n batch tos cred
            fromReadResult stream outcome (return . toSlice)
        AllCatchup (Position com pre) ->
            deconstruct $ fmap (Left . toSlice) $
                readAllEvents setts com pre batch tos Forward cred

--------------------------------------------------------------------------------
updateState :: CatchupState -> Location -> CatchupState
updateState (RegularCatchup stream _) (StreamEventNumber n) =
    RegularCatchup stream n
updateState (AllCatchup _) (StreamPosition p) = AllCatchup p
updateState x y = error $ "Unexpected input updateState: " <> show (x,y)

--------------------------------------------------------------------------------
sourceStream :: Settings
             -> Int32
             -> Bool
             -> CatchupState
             -> Maybe Credentials
             -> Operation SubAction
sourceStream setts batch tos start cred = unfoldPlan start go
  where
    go state = do
        s <- fetch setts batch tos state cred
        traverse_ (yield . Submit) (sliceEvents s)

        when (sliceEOS s)
            stop

        return $ updateState state (sliceNext s)

--------------------------------------------------------------------------------
catchupStreamName :: CatchupState -> Text
catchupStreamName (RegularCatchup stream _) = stream
catchupStreamName _ = ""

--------------------------------------------------------------------------------
data CatchupOpResult =
    CatchupOpResult { catchupReadEvents :: ![ResolvedEvent]
                    , catchupEndOfStream :: !Bool
                    , catchupCheckpoint :: !Checkpoint
                    }

--------------------------------------------------------------------------------
-- | Stream catching up operation.
catchup :: Settings
        -> CatchupState
        -> Bool
        -> Maybe Int32
        -> Maybe Credentials
        -> Operation SubAction
catchup setts state tos batchSiz cred =
    sourceStream setts batch tos state cred <> volatile stream tos cred
  where
    batch  = fromMaybe defaultBatchSize batchSiz
    stream = catchupStreamName state

--------------------------------------------------------------------------------
fromReadResult :: Text
               -> ReadResult 'RegularStream a
               -> (a -> Code o x)
               -> Code o x
fromReadResult stream res k =
    case res of
        ReadNoStream        -> failure $ streamNotFound stream
        ReadStreamDeleted s -> failure $ StreamDeleted s
        ReadNotModified     -> failure $ ServerError Nothing
        ReadError e         -> failure $ ServerError e
        ReadAccessDenied s  -> failure $ AccessDenied s
        ReadSuccess ss      -> k ss
