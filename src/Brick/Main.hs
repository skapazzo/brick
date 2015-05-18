{-# LANGUAGE BangPatterns #-}
module Brick.Main
  ( App(..)
  , defaultMain
  , defaultMainWithVty

  , supplyVtyEvents
  , withVty
  , runVty

  , neverShowCursor
  , showFirstCursor
  )
where

import Control.Applicative ((<$>))
import Control.Arrow ((>>>))
import Control.Exception (finally)
import Control.Monad (when, forever)
import Control.Concurrent (forkIO, Chan, newChan, readChan, writeChan)
import Data.Default
import Data.Maybe (listToMaybe)
import Graphics.Vty
  ( Vty
  , DisplayRegion
  , Picture(..)
  , Cursor(..)
  , Event(..)
  , update
  , outputIface
  , displayBounds
  , shutdown
  , nextEvent
  , mkVty
  )

import Brick.Prim (Prim, renderFinal)
import Brick.Core (Name(..), Location(..), CursorLocation(..))

data App a e =
    App { appDraw :: a -> [Prim]
        , appChooseCursor :: a -> [CursorLocation] -> Maybe CursorLocation
        , appHandleEvent :: e -> a -> IO a
        , appHandleSize :: Name -> DisplayRegion -> a -> a
        }

instance Default (App a e) where
    def = App { appDraw = const def
              , appChooseCursor = neverShowCursor
              , appHandleEvent = const return
              , appHandleSize = const $ const id
              }

defaultMain :: App a Event -> a -> IO ()
defaultMain = defaultMainWithVty (mkVty def)

defaultMainWithVty :: IO Vty -> App a Event -> a -> IO ()
defaultMainWithVty buildVty app initialState = do
    chan <- newChan
    withVty buildVty $ \vty -> do
        forkIO $ supplyVtyEvents vty id chan
        runVty vty chan app initialState

isResizeEvent :: Event -> Bool
isResizeEvent (EvResize _ _) = True
isResizeEvent _ = False

supplyVtyEvents :: Vty -> (Event -> e) -> Chan e -> IO ()
supplyVtyEvents vty mkEvent chan =
    forever $ do
        e <- nextEvent vty
        -- On resize, send two events to force two redraws to force all
        -- state updates to get flushed to the display
        when (isResizeEvent e) $ writeChan chan $ mkEvent e
        writeChan chan $ mkEvent e

runVty :: Vty -> Chan e -> App a e -> a -> IO ()
runVty vty chan app appState = do
    state' <- renderApp vty app appState
    e <- readChan chan
    appHandleEvent app e state' >>= runVty vty chan app

withVty :: IO Vty -> (Vty -> IO a) -> IO a
withVty buildVty useVty = do
    vty <- buildVty
    useVty vty `finally` shutdown vty

renderApp :: Vty -> App a e -> a -> IO a
renderApp vty app appState = do
    sz <- displayBounds $ outputIface vty
    let (pic, theCursor, theSizes) = renderFinal (appDraw app appState) sz (appChooseCursor app appState)
        picWithCursor = case theCursor of
            Nothing -> pic { picCursor = NoCursor }
            Just (CursorLocation (Location (w, h)) _) -> pic { picCursor = Cursor w h }

    update vty picWithCursor

    let !applyResizes = foldl (>>>) id $ (uncurry (appHandleSize app)) <$> theSizes
        !resizedState = applyResizes appState

    return resizedState

neverShowCursor :: a -> [CursorLocation] -> Maybe CursorLocation
neverShowCursor = const $ const Nothing

showFirstCursor :: a -> [CursorLocation] -> Maybe CursorLocation
showFirstCursor = const $ listToMaybe
