{-# LANGUAGE GADTs, TypeFamilies, FlexibleContexts, FlexibleInstances #-}
{-# LANGUAGE RankNTypes, MagicHash, UnboxedTuples #-}

module Data.Array.Accelerate.CUDA.Data (
 
  ArrayElem(..)
) where

-- standard libraries

import Control.Monad.State (get, liftIO, put)
import Data.Map (adjust, insert, lookup, notMember)
import Foreign (Ptr, nullPtr)
import Foreign.Ptr (ptrToWordPtr)
import Foreign.Storable (Storable)

import GHC.Int
import GHC.Ptr (Ptr(Ptr))

import qualified Data.Array.Accelerate.Array.Data as Acc
import qualified Data.Array.Accelerate.CUDA.Monad as CUDA
import Data.Array.Accelerate.Array.Representation
import Data.Array.Accelerate.Type
import Foreign.Ptr

import qualified Foreign.CUDA.Driver              as CUDA
import qualified Foreign.CUDA.Driver.Stream       as CUDA

class Acc.ArrayElem e => ArrayElem e where
  type DevicePtrs e
  type HostPtrs   e
  mallocArray      :: Acc.ArrayData e -> Int -> CUDA.CGIO (DevicePtrs e)
  mallocHostArray  :: Acc.ArrayData e -> [CUDA.AllocFlag] -> Int -> CUDA.CGIO (HostPtrs e)
  pokeArray        :: Acc.ArrayData e -> Int -> DevicePtrs e -> CUDA.CGIO ()
  pokeArrayAsync   :: Acc.ArrayData e -> Int -> DevicePtrs e -> Maybe CUDA.Stream -> CUDA.CGIO ()
  peekArray        :: Acc.ArrayData e -> Int -> DevicePtrs e -> CUDA.CGIO ()
  peekArrayAsync   :: Acc.ArrayData e -> Int -> DevicePtrs e -> Maybe CUDA.Stream -> CUDA.CGIO ()
  free             :: Acc.ArrayData e -> DevicePtrs e -> CUDA.CGIO ()
  toFunParams      :: Acc.ArrayData e -> DevicePtrs e -> [CUDA.FunParam]
  dptrsOfArrayData :: Acc.ArrayData e -> CUDA.CGIO (DevicePtrs e)
  decUse           :: Acc.ArrayData e -> CUDA.CGIO Int

instance ArrayElem () where
  type DevicePtrs () = CUDA.DevicePtr ()
  type HostPtrs   () = CUDA.HostPtr   ()
  mallocArray     _ _     = return CUDA.nullDevPtr
  mallocHostArray _ _ _   = return CUDA.nullHostPtr
  pokeArray       _ _ _   = return ()
  pokeArrayAsync  _ _ _ _ = return ()
  peekArray       _ _ _   = return ()
  peekArrayAsync  _ _ _ _ = return ()
  free            _ _     = return ()
  toFunParams     _ _     = []
  dptrsOfArrayData  _     = return CUDA.nullDevPtr
  decUse            _     = return 0

instance ArrayElem Int where
  type DevicePtrs Int = CUDA.DevicePtr Int
  type HostPtrs   Int = CUDA.HostPtr   Int
  mallocArray ad n = do
    currentState <- get
    dptr <- liftIO $ CUDA.mallocArray n
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
        val    = CUDA.MemoryEntry (CUDA.devPtrToWordPtr dptr) 0
    put $ currentState
      {CUDA.memMap = insert key val memMap}
    return dptr
  mallocHostArray _ flags n = liftIO $ CUDA.mallocHostArray flags n
  pokeArray ad n dptr = do
    currentState <- get
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
    case Data.Map.lookup key memMap of
      Just val -> do
        if CUDA.numUse val == 0
          then do
            liftIO $ CUDA.pokeArray n aptr dptr
            let val' = val {CUDA.numUse = 1}
            put $ currentState
              { CUDA.dataTransferHtoD = CUDA.dataTransferHtoD currentState + 1
              , CUDA.memMap = insert key val' memMap}
          else do
            let val' = val {CUDA.numUse = CUDA.numUse val + 1}
            put $ currentState {CUDA.memMap = insert key val' memMap}
      Nothing -> do
        error "Memory allocation information lost."
  pokeArrayAsync ad n dptr s = do
    currentState <- get
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
    case Data.Map.lookup key memMap of
      Just val -> do
        if CUDA.numUse val == 0
          then do
            liftIO $ CUDA.pokeArrayAsync n (CUDA.HostPtr aptr) dptr s
            let val' = val {CUDA.numUse = 1}
            put $ currentState
              { CUDA.dataTransferHtoD = CUDA.dataTransferHtoD currentState + 1
              , CUDA.memMap = insert key val' memMap}
          else do
            let val' = val {CUDA.numUse = CUDA.numUse val + 1}
            put $ currentState {CUDA.memMap = insert key val' memMap}
      Nothing  -> do
        error "Memory allocation information lost."
  peekArray ad n dptr = liftIO $ CUDA.peekArray n dptr (Acc.ptrsOfArrayData ad)
  peekArrayAsync ad n dptr s = liftIO $ CUDA.peekArrayAsync n dptr (CUDA.HostPtr $ Acc.ptrsOfArrayData ad) s
  free     _ dptr = liftIO $ CUDA.free     dptr
  toFunParams ad dptr = [CUDA.VArg dptr]
  dptrsOfArrayData ad = do
    currentState <- get
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
        val    = Data.Map.lookup key memMap
    case Data.Map.lookup key memMap of
      Just val ->
        return $ CUDA.wordPtrToDevPtr $ CUDA.devicePtr val
      Nothing  ->
        error "All input arrays need to be transferred to GPUs before use."
  decUse ad = do
    currentState <- get
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
    case Data.Map.lookup key memMap of
      Just val -> do
        let numUse = CUDA.numUse val
        if numUse == 0
          then
            return numUse
          else do
            let numUse' = numUse - 1
                val' = val {CUDA.numUse = numUse'}
            put $ currentState
              { CUDA.memMap = insert key val' memMap}
            return numUse'
      Nothing  ->
        return 0

instance ArrayElem Int8 where
  type DevicePtrs Int8 = CUDA.DevicePtr Int8
  type HostPtrs   Int8 = CUDA.HostPtr   Int8
  mallocArray ad n = do
    currentState <- get
    dptr <- liftIO $ CUDA.mallocArray n
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
        val    = CUDA.MemoryEntry (CUDA.devPtrToWordPtr dptr) 0
    put $ currentState
      {CUDA.memMap = insert key val memMap}
    return dptr
  mallocHostArray _ flags n = liftIO $ CUDA.mallocHostArray flags n
  pokeArray ad n dptr = do
    currentState <- get
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
    case Data.Map.lookup key memMap of
      Just val -> do
        if CUDA.numUse val == 0
          then do
            liftIO $ CUDA.pokeArray n aptr dptr
            let val' = val {CUDA.numUse = 1}
            put $ currentState
              { CUDA.dataTransferHtoD = CUDA.dataTransferHtoD currentState + 1
              , CUDA.memMap = insert key val' memMap}
          else do
            let val' = val {CUDA.numUse = CUDA.numUse val + 1}
            put $ currentState {CUDA.memMap = insert key val' memMap}
      Nothing -> do
        error "Memory allocation information lost."
  pokeArrayAsync ad n dptr s = do
    currentState <- get
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
    case Data.Map.lookup key memMap of
      Just val -> do
        if CUDA.numUse val == 0
          then do
            liftIO $ CUDA.pokeArrayAsync n (CUDA.HostPtr aptr) dptr s
            let val' = val {CUDA.numUse = 1}
            put $ currentState
              { CUDA.dataTransferHtoD = CUDA.dataTransferHtoD currentState + 1
              , CUDA.memMap = insert key val' memMap}
          else do
            let val' = val {CUDA.numUse = CUDA.numUse val + 1}
            put $ currentState {CUDA.memMap = insert key val' memMap}
      Nothing  -> do
        error "Memory allocation information lost."
  peekArray ad n dptr = liftIO $ CUDA.peekArray n dptr (Acc.ptrsOfArrayData ad)
  peekArrayAsync ad n dptr s = liftIO $ CUDA.peekArrayAsync n dptr (CUDA.HostPtr $ Acc.ptrsOfArrayData ad) s
  free     _ dptr = liftIO $ CUDA.free     dptr
  toFunParams ad dptr = [CUDA.VArg dptr]
  dptrsOfArrayData ad = do
    currentState <- get
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
        val    = Data.Map.lookup key memMap
    case Data.Map.lookup key memMap of
      Just val ->
        return $ CUDA.wordPtrToDevPtr $ CUDA.devicePtr val
      Nothing  ->
        error "All input arrays need to be transferred to GPUs before use."
  decUse ad = do
    currentState <- get
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
    case Data.Map.lookup key memMap of
      Just val -> do
        let numUse = CUDA.numUse val
        if numUse == 0
          then
            return numUse
          else do
            let numUse' = numUse - 1
                val' = val {CUDA.numUse = numUse'}
            put $ currentState
              { CUDA.memMap = insert key val' memMap}
            return numUse'
      Nothing  ->
        return 0

instance ArrayElem Int16 where
  type DevicePtrs Int16 = CUDA.DevicePtr Int16
  type HostPtrs   Int16 = CUDA.HostPtr   Int16
  mallocArray ad n = do
    currentState <- get
    dptr <- liftIO $ CUDA.mallocArray n
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
        val    = CUDA.MemoryEntry (CUDA.devPtrToWordPtr dptr) 0
    put $ currentState
      {CUDA.memMap = insert key val memMap}
    return dptr
  mallocHostArray _ flags n = liftIO $ CUDA.mallocHostArray flags n
  pokeArray ad n dptr = do
    currentState <- get
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
    case Data.Map.lookup key memMap of
      Just val -> do
        if CUDA.numUse val == 0
          then do
            liftIO $ CUDA.pokeArray n aptr dptr
            let val' = val {CUDA.numUse = 1}
            put $ currentState
              { CUDA.dataTransferHtoD = CUDA.dataTransferHtoD currentState + 1
              , CUDA.memMap = insert key val' memMap}
          else do
            let val' = val {CUDA.numUse = CUDA.numUse val + 1}
            put $ currentState {CUDA.memMap = insert key val' memMap}
      Nothing -> do
        error "Memory allocation information lost."
  pokeArrayAsync ad n dptr s = do
    currentState <- get
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
    case Data.Map.lookup key memMap of
      Just val -> do
        if CUDA.numUse val == 0
          then do
            liftIO $ CUDA.pokeArrayAsync n (CUDA.HostPtr aptr) dptr s
            let val' = val {CUDA.numUse = 1}
            put $ currentState
              { CUDA.dataTransferHtoD = CUDA.dataTransferHtoD currentState + 1
              , CUDA.memMap = insert key val' memMap}
          else do
            let val' = val {CUDA.numUse = CUDA.numUse val + 1}
            put $ currentState {CUDA.memMap = insert key val' memMap}
      Nothing  -> do
        error "Memory allocation information lost."
  peekArray ad n dptr = liftIO $ CUDA.peekArray n dptr (Acc.ptrsOfArrayData ad)
  peekArrayAsync ad n dptr s = liftIO $ CUDA.peekArrayAsync n dptr (CUDA.HostPtr $ Acc.ptrsOfArrayData ad) s
  free     _ dptr = liftIO $ CUDA.free     dptr
  toFunParams ad dptr = [CUDA.VArg dptr]
  dptrsOfArrayData ad = do
    currentState <- get
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
        val    = Data.Map.lookup key memMap
    case Data.Map.lookup key memMap of
      Just val ->
        return $ CUDA.wordPtrToDevPtr $ CUDA.devicePtr val
      Nothing  ->
        error "All input arrays need to be transferred to GPUs before use."
  decUse ad = do
    currentState <- get
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
    case Data.Map.lookup key memMap of
      Just val -> do
        let numUse = CUDA.numUse val
        if numUse == 0
          then
            return numUse
          else do
            let numUse' = numUse - 1
                val' = val {CUDA.numUse = numUse'}
            put $ currentState
              { CUDA.memMap = insert key val' memMap}
            return numUse'
      Nothing  ->
        return 0

instance ArrayElem Int32 where
  type DevicePtrs Int32 = CUDA.DevicePtr Int32
  type HostPtrs   Int32 = CUDA.HostPtr   Int32
  mallocArray ad n = do
    currentState <- get
    dptr <- liftIO $ CUDA.mallocArray n
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
        val    = CUDA.MemoryEntry (CUDA.devPtrToWordPtr dptr) 0
    put $ currentState
      {CUDA.memMap = insert key val memMap}
    return dptr
  mallocHostArray _ flags n = liftIO $ CUDA.mallocHostArray flags n
  pokeArray ad n dptr = do
    currentState <- get
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
    case Data.Map.lookup key memMap of
      Just val -> do
        if CUDA.numUse val == 0
          then do
            liftIO $ CUDA.pokeArray n aptr dptr
            let val' = val {CUDA.numUse = 1}
            put $ currentState
              { CUDA.dataTransferHtoD = CUDA.dataTransferHtoD currentState + 1
              , CUDA.memMap = insert key val' memMap}
          else do
            let val' = val {CUDA.numUse = CUDA.numUse val + 1}
            put $ currentState {CUDA.memMap = insert key val' memMap}
      Nothing -> do
        error "Memory allocation information lost."
  pokeArrayAsync ad n dptr s = do
    currentState <- get
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
    case Data.Map.lookup key memMap of
      Just val -> do
        if CUDA.numUse val == 0
          then do
            liftIO $ CUDA.pokeArrayAsync n (CUDA.HostPtr aptr) dptr s
            let val' = val {CUDA.numUse = 1}
            put $ currentState
              { CUDA.dataTransferHtoD = CUDA.dataTransferHtoD currentState + 1
              , CUDA.memMap = insert key val' memMap}
          else do
            let val' = val {CUDA.numUse = CUDA.numUse val + 1}
            put $ currentState {CUDA.memMap = insert key val' memMap}
      Nothing  -> do
        error "Memory allocation information lost."
  peekArray ad n dptr = liftIO $ CUDA.peekArray n dptr (Acc.ptrsOfArrayData ad)
  peekArrayAsync ad n dptr s = liftIO $ CUDA.peekArrayAsync n dptr (CUDA.HostPtr $ Acc.ptrsOfArrayData ad) s
  free     _ dptr = liftIO $ CUDA.free     dptr
  toFunParams ad dptr = [CUDA.VArg dptr]
  dptrsOfArrayData ad = do
    currentState <- get
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
        val    = Data.Map.lookup key memMap
    case Data.Map.lookup key memMap of
      Just val ->
        return $ CUDA.wordPtrToDevPtr $ CUDA.devicePtr val
      Nothing  ->
        error "All input arrays need to be transferred to GPUs before use."
  decUse ad = do
    currentState <- get
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
    case Data.Map.lookup key memMap of
      Just val -> do
        let numUse = CUDA.numUse val
        if numUse == 0
          then
            return numUse
          else do
            let numUse' = numUse - 1
                val' = val {CUDA.numUse = numUse'}
            put $ currentState
              { CUDA.memMap = insert key val' memMap}
            return numUse'
      Nothing  ->
        return 0

instance ArrayElem Int64 where
  type DevicePtrs Int64 = CUDA.DevicePtr Int64
  type HostPtrs   Int64 = CUDA.HostPtr   Int64
  mallocArray ad n = do
    currentState <- get
    dptr <- liftIO $ CUDA.mallocArray n
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
        val    = CUDA.MemoryEntry (CUDA.devPtrToWordPtr dptr) 0
    put $ currentState
      {CUDA.memMap = insert key val memMap}
    return dptr
  mallocHostArray _ flags n = liftIO $ CUDA.mallocHostArray flags n
  pokeArray ad n dptr = do
    currentState <- get
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
    case Data.Map.lookup key memMap of
      Just val -> do
        if CUDA.numUse val == 0
          then do
            liftIO $ CUDA.pokeArray n aptr dptr
            let val' = val {CUDA.numUse = 1}
            put $ currentState
              { CUDA.dataTransferHtoD = CUDA.dataTransferHtoD currentState + 1
              , CUDA.memMap = insert key val' memMap}
          else do
            let val' = val {CUDA.numUse = CUDA.numUse val + 1}
            put $ currentState {CUDA.memMap = insert key val' memMap}
      Nothing -> do
        error "Memory allocation information lost."
  pokeArrayAsync ad n dptr s = do
    currentState <- get
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
    case Data.Map.lookup key memMap of
      Just val -> do
        if CUDA.numUse val == 0
          then do
            liftIO $ CUDA.pokeArrayAsync n (CUDA.HostPtr aptr) dptr s
            let val' = val {CUDA.numUse = 1}
            put $ currentState
              { CUDA.dataTransferHtoD = CUDA.dataTransferHtoD currentState + 1
              , CUDA.memMap = insert key val' memMap}
          else do
            let val' = val {CUDA.numUse = CUDA.numUse val + 1}
            put $ currentState {CUDA.memMap = insert key val' memMap}
      Nothing  -> do
        error "Memory allocation information lost."
  peekArray ad n dptr = liftIO $ CUDA.peekArray n dptr (Acc.ptrsOfArrayData ad)
  peekArrayAsync ad n dptr s = liftIO $ CUDA.peekArrayAsync n dptr (CUDA.HostPtr $ Acc.ptrsOfArrayData ad) s
  free     _ dptr = liftIO $ CUDA.free     dptr
  toFunParams ad dptr = [CUDA.VArg dptr]
  dptrsOfArrayData ad = do
    currentState <- get
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
        val    = Data.Map.lookup key memMap
    case Data.Map.lookup key memMap of
      Just val ->
        return $ CUDA.wordPtrToDevPtr $ CUDA.devicePtr val
      Nothing  ->
        error "All input arrays need to be transferred to GPUs before use."
  decUse ad = do
    currentState <- get
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
    case Data.Map.lookup key memMap of
      Just val -> do
        let numUse = CUDA.numUse val
        if numUse == 0
          then
            return numUse
          else do
            let numUse' = numUse - 1
                val' = val {CUDA.numUse = numUse'}
            put $ currentState
              { CUDA.memMap = insert key val' memMap}
            return numUse'
      Nothing  ->
        return 0

instance ArrayElem Word where
  type DevicePtrs Word = CUDA.DevicePtr Word
  type HostPtrs   Word = CUDA.HostPtr   Word
  mallocArray ad n = do
    currentState <- get
    dptr <- liftIO $ CUDA.mallocArray n
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
        val    = CUDA.MemoryEntry (CUDA.devPtrToWordPtr dptr) 0
    put $ currentState
      {CUDA.memMap = insert key val memMap}
    return dptr
  mallocHostArray _ flags n = liftIO $ CUDA.mallocHostArray flags n
  pokeArray ad n dptr = do
    currentState <- get
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
    case Data.Map.lookup key memMap of
      Just val -> do
        if CUDA.numUse val == 0
          then do
            liftIO $ CUDA.pokeArray n aptr dptr
            let val' = val {CUDA.numUse = 1}
            put $ currentState
              { CUDA.dataTransferHtoD = CUDA.dataTransferHtoD currentState + 1
              , CUDA.memMap = insert key val' memMap}
          else do
            let val' = val {CUDA.numUse = CUDA.numUse val + 1}
            put $ currentState {CUDA.memMap = insert key val' memMap}
      Nothing -> do
        error "Memory allocation information lost."
  pokeArrayAsync ad n dptr s = do
    currentState <- get
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
    case Data.Map.lookup key memMap of
      Just val -> do
        if CUDA.numUse val == 0
          then do
            liftIO $ CUDA.pokeArrayAsync n (CUDA.HostPtr aptr) dptr s
            let val' = val {CUDA.numUse = 1}
            put $ currentState
              { CUDA.dataTransferHtoD = CUDA.dataTransferHtoD currentState + 1
              , CUDA.memMap = insert key val' memMap}
          else do
            let val' = val {CUDA.numUse = CUDA.numUse val + 1}
            put $ currentState {CUDA.memMap = insert key val' memMap}
      Nothing  -> do
        error "Memory allocation information lost."
  peekArray ad n dptr = liftIO $ CUDA.peekArray n dptr (Acc.ptrsOfArrayData ad)
  peekArrayAsync ad n dptr s = liftIO $ CUDA.peekArrayAsync n dptr (CUDA.HostPtr $ Acc.ptrsOfArrayData ad) s
  free     _ dptr = liftIO $ CUDA.free     dptr
  toFunParams ad dptr = [CUDA.VArg dptr]
  dptrsOfArrayData ad = do
    currentState <- get
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
        val    = Data.Map.lookup key memMap
    case Data.Map.lookup key memMap of
      Just val ->
        return $ CUDA.wordPtrToDevPtr $ CUDA.devicePtr val
      Nothing  ->
        error "All input arrays need to be transferred to GPUs before use."
  decUse ad = do
    currentState <- get
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
    case Data.Map.lookup key memMap of
      Just val -> do
        let numUse = CUDA.numUse val
        if numUse == 0
          then
            return numUse
          else do
            let numUse' = numUse - 1
                val' = val {CUDA.numUse = numUse'}
            put $ currentState
              { CUDA.memMap = insert key val' memMap}
            return numUse'
      Nothing  ->
        return 0

instance ArrayElem Word8 where
  type DevicePtrs Word8 = CUDA.DevicePtr Word8
  type HostPtrs   Word8 = CUDA.HostPtr   Word8
  mallocArray ad n = do
    currentState <- get
    dptr <- liftIO $ CUDA.mallocArray n
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
        val    = CUDA.MemoryEntry (CUDA.devPtrToWordPtr dptr) 0
    put $ currentState
      {CUDA.memMap = insert key val memMap}
    return dptr
  mallocHostArray _ flags n = liftIO $ CUDA.mallocHostArray flags n
  pokeArray ad n dptr = do
    currentState <- get
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
    case Data.Map.lookup key memMap of
      Just val -> do
        if CUDA.numUse val == 0
          then do
            liftIO $ CUDA.pokeArray n aptr dptr
            let val' = val {CUDA.numUse = 1}
            put $ currentState
              { CUDA.dataTransferHtoD = CUDA.dataTransferHtoD currentState + 1
              , CUDA.memMap = insert key val' memMap}
          else do
            let val' = val {CUDA.numUse = CUDA.numUse val + 1}
            put $ currentState {CUDA.memMap = insert key val' memMap}
      Nothing -> do
        error "Memory allocation information lost."
  pokeArrayAsync ad n dptr s = do
    currentState <- get
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
    case Data.Map.lookup key memMap of
      Just val -> do
        if CUDA.numUse val == 0
          then do
            liftIO $ CUDA.pokeArrayAsync n (CUDA.HostPtr aptr) dptr s
            let val' = val {CUDA.numUse = 1}
            put $ currentState
              { CUDA.dataTransferHtoD = CUDA.dataTransferHtoD currentState + 1
              , CUDA.memMap = insert key val' memMap}
          else do
            let val' = val {CUDA.numUse = CUDA.numUse val + 1}
            put $ currentState {CUDA.memMap = insert key val' memMap}
      Nothing  -> do
        error "Memory allocation information lost."
  peekArray ad n dptr = liftIO $ CUDA.peekArray n dptr (Acc.ptrsOfArrayData ad)
  peekArrayAsync ad n dptr s = liftIO $ CUDA.peekArrayAsync n dptr (CUDA.HostPtr $ Acc.ptrsOfArrayData ad) s
  free     _ dptr = liftIO $ CUDA.free     dptr
  toFunParams ad dptr = [CUDA.VArg dptr]
  dptrsOfArrayData ad = do
    currentState <- get
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
        val    = Data.Map.lookup key memMap
    case Data.Map.lookup key memMap of
      Just val ->
        return $ CUDA.wordPtrToDevPtr $ CUDA.devicePtr val
      Nothing  ->
        error "All input arrays need to be transferred to GPUs before use."
  decUse ad = do
    currentState <- get
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
    case Data.Map.lookup key memMap of
      Just val -> do
        let numUse = CUDA.numUse val
        if numUse == 0
          then
            return numUse
          else do
            let numUse' = numUse - 1
                val' = val {CUDA.numUse = numUse'}
            put $ currentState
              { CUDA.memMap = insert key val' memMap}
            return numUse'
      Nothing  ->
        return 0

instance ArrayElem Word16 where
  type DevicePtrs Word16 = CUDA.DevicePtr Word16
  type HostPtrs   Word16 = CUDA.HostPtr   Word16
  mallocArray ad n = do
    currentState <- get
    dptr <- liftIO $ CUDA.mallocArray n
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
        val    = CUDA.MemoryEntry (CUDA.devPtrToWordPtr dptr) 0
    put $ currentState
      {CUDA.memMap = insert key val memMap}
    return dptr
  mallocHostArray _ flags n = liftIO $ CUDA.mallocHostArray flags n
  pokeArray ad n dptr = do
    currentState <- get
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
    case Data.Map.lookup key memMap of
      Just val -> do
        if CUDA.numUse val == 0
          then do
            liftIO $ CUDA.pokeArray n aptr dptr
            let val' = val {CUDA.numUse = 1}
            put $ currentState
              { CUDA.dataTransferHtoD = CUDA.dataTransferHtoD currentState + 1
              , CUDA.memMap = insert key val' memMap}
          else do
            let val' = val {CUDA.numUse = CUDA.numUse val + 1}
            put $ currentState {CUDA.memMap = insert key val' memMap}
      Nothing -> do
        error "Memory allocation information lost."
  pokeArrayAsync ad n dptr s = do
    currentState <- get
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
    case Data.Map.lookup key memMap of
      Just val -> do
        if CUDA.numUse val == 0
          then do
            liftIO $ CUDA.pokeArrayAsync n (CUDA.HostPtr aptr) dptr s
            let val' = val {CUDA.numUse = 1}
            put $ currentState
              { CUDA.dataTransferHtoD = CUDA.dataTransferHtoD currentState + 1
              , CUDA.memMap = insert key val' memMap}
          else do
            let val' = val {CUDA.numUse = CUDA.numUse val + 1}
            put $ currentState {CUDA.memMap = insert key val' memMap}
      Nothing  -> do
        error "Memory allocation information lost."
  peekArray ad n dptr = liftIO $ CUDA.peekArray n dptr (Acc.ptrsOfArrayData ad)
  peekArrayAsync ad n dptr s = liftIO $ CUDA.peekArrayAsync n dptr (CUDA.HostPtr $ Acc.ptrsOfArrayData ad) s
  free     _ dptr = liftIO $ CUDA.free     dptr
  toFunParams ad dptr = [CUDA.VArg dptr]
  dptrsOfArrayData ad = do
    currentState <- get
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
        val    = Data.Map.lookup key memMap
    case Data.Map.lookup key memMap of
      Just val ->
        return $ CUDA.wordPtrToDevPtr $ CUDA.devicePtr val
      Nothing  ->
        error "All input arrays need to be transferred to GPUs before use."
  decUse ad = do
    currentState <- get
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
    case Data.Map.lookup key memMap of
      Just val -> do
        let numUse = CUDA.numUse val
        if numUse == 0
          then
            return numUse
          else do
            let numUse' = numUse - 1
                val' = val {CUDA.numUse = numUse'}
            put $ currentState
              { CUDA.memMap = insert key val' memMap}
            return numUse'
      Nothing  ->
        return 0

instance ArrayElem Word32 where
  type DevicePtrs Word32 = CUDA.DevicePtr Word32
  type HostPtrs   Word32 = CUDA.HostPtr   Word32
  mallocArray ad n = do
    currentState <- get
    dptr <- liftIO $ CUDA.mallocArray n
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
        val    = CUDA.MemoryEntry (CUDA.devPtrToWordPtr dptr) 0
    put $ currentState
      {CUDA.memMap = insert key val memMap}
    return dptr
  mallocHostArray _ flags n = liftIO $ CUDA.mallocHostArray flags n
  pokeArray ad n dptr = do
    currentState <- get
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
    case Data.Map.lookup key memMap of
      Just val -> do
        if CUDA.numUse val == 0
          then do
            liftIO $ CUDA.pokeArray n aptr dptr
            let val' = val {CUDA.numUse = 1}
            put $ currentState
              { CUDA.dataTransferHtoD = CUDA.dataTransferHtoD currentState + 1
              , CUDA.memMap = insert key val' memMap}
          else do
            let val' = val {CUDA.numUse = CUDA.numUse val + 1}
            put $ currentState {CUDA.memMap = insert key val' memMap}
      Nothing -> do
        error "Memory allocation information lost."
  pokeArrayAsync ad n dptr s = do
    currentState <- get
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
    case Data.Map.lookup key memMap of
      Just val -> do
        if CUDA.numUse val == 0
          then do
            liftIO $ CUDA.pokeArrayAsync n (CUDA.HostPtr aptr) dptr s
            let val' = val {CUDA.numUse = 1}
            put $ currentState
              { CUDA.dataTransferHtoD = CUDA.dataTransferHtoD currentState + 1
              , CUDA.memMap = insert key val' memMap}
          else do
            let val' = val {CUDA.numUse = CUDA.numUse val + 1}
            put $ currentState {CUDA.memMap = insert key val' memMap}
      Nothing  -> do
        error "Memory allocation information lost."
  peekArray ad n dptr = liftIO $ CUDA.peekArray n dptr (Acc.ptrsOfArrayData ad)
  peekArrayAsync ad n dptr s = liftIO $ CUDA.peekArrayAsync n dptr (CUDA.HostPtr $ Acc.ptrsOfArrayData ad) s
  free     _ dptr = liftIO $ CUDA.free     dptr
  toFunParams ad dptr = [CUDA.VArg dptr]
  dptrsOfArrayData ad = do
    currentState <- get
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
        val    = Data.Map.lookup key memMap
    case Data.Map.lookup key memMap of
      Just val ->
        return $ CUDA.wordPtrToDevPtr $ CUDA.devicePtr val
      Nothing  ->
        error "All input arrays need to be transferred to GPUs before use."
  decUse ad = do
    currentState <- get
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
    case Data.Map.lookup key memMap of
      Just val -> do
        let numUse = CUDA.numUse val
        if numUse == 0
          then
            return numUse
          else do
            let numUse' = numUse - 1
                val' = val {CUDA.numUse = numUse'}
            put $ currentState
              { CUDA.memMap = insert key val' memMap}
            return numUse'
      Nothing  ->
        return 0

instance ArrayElem Word64 where
  type DevicePtrs Word64 = CUDA.DevicePtr Word64
  type HostPtrs   Word64 = CUDA.HostPtr   Word64
  mallocArray ad n = do
    currentState <- get
    dptr <- liftIO $ CUDA.mallocArray n
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
        val    = CUDA.MemoryEntry (CUDA.devPtrToWordPtr dptr) 0
    put $ currentState
      {CUDA.memMap = insert key val memMap}
    return dptr
  mallocHostArray _ flags n = liftIO $ CUDA.mallocHostArray flags n
  pokeArray ad n dptr = do
    currentState <- get
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
    case Data.Map.lookup key memMap of
      Just val -> do
        if CUDA.numUse val == 0
          then do
            liftIO $ CUDA.pokeArray n aptr dptr
            let val' = val {CUDA.numUse = 1}
            put $ currentState
              { CUDA.dataTransferHtoD = CUDA.dataTransferHtoD currentState + 1
              , CUDA.memMap = insert key val' memMap}
          else do
            let val' = val {CUDA.numUse = CUDA.numUse val + 1}
            put $ currentState {CUDA.memMap = insert key val' memMap}
      Nothing -> do
        error "Memory allocation information lost."
  pokeArrayAsync ad n dptr s = do
    currentState <- get
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
    case Data.Map.lookup key memMap of
      Just val -> do
        if CUDA.numUse val == 0
          then do
            liftIO $ CUDA.pokeArrayAsync n (CUDA.HostPtr aptr) dptr s
            let val' = val {CUDA.numUse = 1}
            put $ currentState
              { CUDA.dataTransferHtoD = CUDA.dataTransferHtoD currentState + 1
              , CUDA.memMap = insert key val' memMap}
          else do
            let val' = val {CUDA.numUse = CUDA.numUse val + 1}
            put $ currentState {CUDA.memMap = insert key val' memMap}
      Nothing  -> do
        error "Memory allocation information lost."
  peekArray ad n dptr = liftIO $ CUDA.peekArray n dptr (Acc.ptrsOfArrayData ad)
  peekArrayAsync ad n dptr s = liftIO $ CUDA.peekArrayAsync n dptr (CUDA.HostPtr $ Acc.ptrsOfArrayData ad) s
  free     _ dptr = liftIO $ CUDA.free     dptr
  toFunParams ad dptr = [CUDA.VArg dptr]
  dptrsOfArrayData ad = do
    currentState <- get
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
        val    = Data.Map.lookup key memMap
    case Data.Map.lookup key memMap of
      Just val ->
        return $ CUDA.wordPtrToDevPtr $ CUDA.devicePtr val
      Nothing  ->
        error "All input arrays need to be transferred to GPUs before use."
  decUse ad = do
    currentState <- get
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
    case Data.Map.lookup key memMap of
      Just val -> do
        let numUse = CUDA.numUse val
        if numUse == 0
          then
            return numUse
          else do
            let numUse' = numUse - 1
                val' = val {CUDA.numUse = numUse'}
            put $ currentState
              { CUDA.memMap = insert key val' memMap}
            return numUse'
      Nothing  ->
        return 0

-- FIXME:
-- CShort
-- CUShort
-- CInt
-- CUInt
-- CLong
-- CULong
-- CLLong
-- CULLong

instance ArrayElem Float where
  type DevicePtrs Float = CUDA.DevicePtr Float
  type HostPtrs   Float = CUDA.HostPtr   Float
  mallocArray ad n = do
    currentState <- get
    dptr <- liftIO $ CUDA.mallocArray n
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
        val    = CUDA.MemoryEntry (CUDA.devPtrToWordPtr dptr) 0
    put $ currentState
      {CUDA.memMap = insert key val memMap}
    return dptr
  mallocHostArray _ flags n = liftIO $ CUDA.mallocHostArray flags n
  pokeArray ad n dptr = do
    currentState <- get
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
    case Data.Map.lookup key memMap of
      Just val -> do
        if CUDA.numUse val == 0
          then do
            liftIO $ CUDA.pokeArray n aptr dptr
            let val' = val {CUDA.numUse = 1}
            put $ currentState
              { CUDA.dataTransferHtoD = CUDA.dataTransferHtoD currentState + 1
              , CUDA.memMap = insert key val' memMap}
          else do
            let val' = val {CUDA.numUse = CUDA.numUse val + 1}
            put $ currentState {CUDA.memMap = insert key val' memMap}
      Nothing -> do
        error "Memory allocation information lost."
  pokeArrayAsync ad n dptr s = do
    currentState <- get
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
    case Data.Map.lookup key memMap of
      Just val -> do
        if CUDA.numUse val == 0
          then do
            liftIO $ CUDA.pokeArrayAsync n (CUDA.HostPtr aptr) dptr s
            let val' = val {CUDA.numUse = 1}
            put $ currentState
              { CUDA.dataTransferHtoD = CUDA.dataTransferHtoD currentState + 1
              , CUDA.memMap = insert key val' memMap}
          else do
            let val' = val {CUDA.numUse = CUDA.numUse val + 1}
            put $ currentState {CUDA.memMap = insert key val' memMap}
      Nothing  -> do
        error "Memory allocation information lost."
  peekArray ad n dptr = liftIO $ CUDA.peekArray n dptr (Acc.ptrsOfArrayData ad)
  peekArrayAsync ad n dptr s = liftIO $ CUDA.peekArrayAsync n dptr (CUDA.HostPtr $ Acc.ptrsOfArrayData ad) s
  free     _ dptr = liftIO $ CUDA.free     dptr
  toFunParams ad dptr = [CUDA.VArg dptr]
  dptrsOfArrayData ad = do
    currentState <- get
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
        val    = Data.Map.lookup key memMap
    case Data.Map.lookup key memMap of
      Just val ->
        return $ CUDA.wordPtrToDevPtr $ CUDA.devicePtr val
      Nothing  ->
        error "All input arrays need to be transferred to GPUs before use."
  decUse ad = do
    currentState <- get
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
    case Data.Map.lookup key memMap of
      Just val -> do
        let numUse = CUDA.numUse val
        if numUse == 0
          then
            return numUse
          else do
            let numUse' = numUse - 1
                val' = val {CUDA.numUse = numUse'}
            put $ currentState
              { CUDA.memMap = insert key val' memMap}
            return numUse'
      Nothing  ->
        return 0

instance ArrayElem Double where
  type DevicePtrs Double = CUDA.DevicePtr Double
  type HostPtrs   Double = CUDA.HostPtr   Double
  mallocArray ad n = do
    currentState <- get
    dptr <- liftIO $ CUDA.mallocArray n
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
        val    = CUDA.MemoryEntry (CUDA.devPtrToWordPtr dptr) 0
    put $ currentState
      {CUDA.memMap = insert key val memMap}
    return dptr
  mallocHostArray _ flags n = liftIO $ CUDA.mallocHostArray flags n
  pokeArray ad n dptr = do
    currentState <- get
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
    case Data.Map.lookup key memMap of
      Just val -> do
        if CUDA.numUse val == 0
          then do
            liftIO $ CUDA.pokeArray n aptr dptr
            let val' = val {CUDA.numUse = 1}
            put $ currentState
              { CUDA.dataTransferHtoD = CUDA.dataTransferHtoD currentState + 1
              , CUDA.memMap = insert key val' memMap}
          else do
            let val' = val {CUDA.numUse = CUDA.numUse val + 1}
            put $ currentState {CUDA.memMap = insert key val' memMap}
      Nothing -> do
        error "Memory allocation information lost."
  pokeArrayAsync ad n dptr s = do
    currentState <- get
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
    case Data.Map.lookup key memMap of
      Just val -> do
        if CUDA.numUse val == 0
          then do
            liftIO $ CUDA.pokeArrayAsync n (CUDA.HostPtr aptr) dptr s
            let val' = val {CUDA.numUse = 1}
            put $ currentState
              { CUDA.dataTransferHtoD = CUDA.dataTransferHtoD currentState + 1
              , CUDA.memMap = insert key val' memMap}
          else do
            let val' = val {CUDA.numUse = CUDA.numUse val + 1}
            put $ currentState {CUDA.memMap = insert key val' memMap}
      Nothing  -> do
        error "Memory allocation information lost."
  peekArray ad n dptr = liftIO $ CUDA.peekArray n dptr (Acc.ptrsOfArrayData ad)
  peekArrayAsync ad n dptr s = liftIO $ CUDA.peekArrayAsync n dptr (CUDA.HostPtr $ Acc.ptrsOfArrayData ad) s
  free     _ dptr = liftIO $ CUDA.free     dptr
  toFunParams ad dptr = [CUDA.VArg dptr]
  dptrsOfArrayData ad = do
    currentState <- get
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
        val    = Data.Map.lookup key memMap
    case Data.Map.lookup key memMap of
      Just val ->
        return $ CUDA.wordPtrToDevPtr $ CUDA.devicePtr val
      Nothing  ->
        error "All input arrays need to be transferred to GPUs before use."
  decUse ad = do
    currentState <- get
    let aptr   = Acc.ptrsOfArrayData ad
        memMap = CUDA.memMap currentState
        key    = ptrToWordPtr aptr
    case Data.Map.lookup key memMap of
      Just val -> do
        let numUse = CUDA.numUse val
        if numUse == 0
          then
            return numUse
          else do
            let numUse' = numUse - 1
                val' = val {CUDA.numUse = numUse'}
            put $ currentState
              { CUDA.memMap = insert key val' memMap}
            return numUse'
      Nothing  ->
        return 0

instance ArrayElem Bool where
  type DevicePtrs Bool = CUDA.DevicePtr Word8
  type HostPtrs   Bool = CUDA.HostPtr   Word8

instance ArrayElem Char where
  type DevicePtrs Char = CUDA.DevicePtr Char
  type HostPtrs   Char = CUDA.HostPtr   Char
  -- ???unicode???

-- FIXME:
-- CChar
-- CSChar
-- CUChar

instance (ArrayElem a, ArrayElem b) => ArrayElem (a, b) where
  type DevicePtrs (a, b) = (DevicePtrs a, DevicePtrs b)
  type HostPtrs   (a, b) = (HostPtrs   a, HostPtrs   b)
  mallocArray ad n = do
    dptrA <- mallocArray (Acc.fstArrayData ad) n
    dptrB <- mallocArray (Acc.sndArrayData ad) n
    return (dptrA, dptrB)
  mallocHostArray ad flags n = do
    hptrA <- mallocHostArray (Acc.fstArrayData ad) flags n
    hptrB <- mallocHostArray (Acc.sndArrayData ad) flags n
    return (hptrA, hptrB)
  pokeArray ad n (dptrA, dptrB) = do
    pokeArray (Acc.fstArrayData ad) n dptrA
    pokeArray (Acc.sndArrayData ad) n dptrB
  pokeArrayAsync ad n (dptrA, dptrB) s = do
    pokeArrayAsync (Acc.fstArrayData ad) n dptrA s
    pokeArrayAsync (Acc.sndArrayData ad) n dptrB s
  peekArray ad n (dptrA, dptrB) = do
    peekArray (Acc.fstArrayData ad) n dptrA
    peekArray (Acc.sndArrayData ad) n dptrB
  peekArrayAsync ad n (dptrA, dptrB) s = do
    peekArrayAsync (Acc.fstArrayData ad) n dptrA s
    peekArrayAsync (Acc.sndArrayData ad) n dptrB s
  free ad (dptrA, dptrB) = do
    free (Acc.fstArrayData ad) dptrA
    free (Acc.sndArrayData ad) dptrB
  toFunParams ad (dptrA, dptrB) =
    let paramsA = toFunParams (Acc.fstArrayData ad) dptrA
        paramsB = toFunParams (Acc.sndArrayData ad) dptrB
    in  paramsA ++ paramsB
  dptrsOfArrayData ad = do
    dptrA <- dptrsOfArrayData (Acc.fstArrayData ad)
    dptrB <- dptrsOfArrayData (Acc.sndArrayData ad)
    return (dptrA, dptrB)
  decUse ad = do
    decUseA <- decUse (Acc.fstArrayData ad)
    decUseB <- decUse (Acc.sndArrayData ad)
    return $ max decUseA decUseB
