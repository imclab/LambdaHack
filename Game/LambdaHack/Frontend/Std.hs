-- | Text frontend based on stdin/stdout, intended for bots.
module Game.LambdaHack.Frontend.Std
  ( -- * Session data type for the frontend
    FrontendSession
    -- * The output and input operations
  , fdisplay, fpromptGetKey
    -- * Frontend administration tools
  , frontendName, startup
  ) where

import qualified Data.ByteString.Char8 as BS
import Data.Char (chr, ord)
import qualified System.IO as SIO

import Game.LambdaHack.Common.Animation
import qualified Game.LambdaHack.Common.Color as Color
import qualified Game.LambdaHack.Common.Key as K

-- | No session data needs to be maintained by this frontend.
data FrontendSession = FrontendSession
  { sdebugCli :: !DebugModeCli  -- ^ client configuration
  }

-- | The name of the frontend.
frontendName :: String
frontendName = "std"

-- | Starts the main program loop using the frontend input and output.
startup :: DebugModeCli -> (FrontendSession -> IO ()) -> IO ()
startup sdebugCli k = k FrontendSession{..}

-- | Output to the screen via the frontend.
fdisplay :: FrontendSession    -- ^ frontend session data
         -> Bool
         -> Maybe SingleFrame  -- ^ the screen frame to draw
         -> IO ()
fdisplay _ _ Nothing = return ()
fdisplay _ _ (Just rawSF) =
  let SingleFrame{sfLevel} = overlayOverlay rawSF
      bs = map (BS.pack . map Color.acChar . decodeLine) sfLevel ++ [BS.empty]
  in mapM_ BS.putStrLn bs

-- | Input key via the frontend.
nextEvent :: FrontendSession -> IO K.KM
nextEvent FrontendSession{sdebugCli=DebugModeCli{snoMore}} =
  if snoMore then return K.escKey
  else do
    l <- BS.hGetLine SIO.stdin
    let c = case BS.uncons l of
          Nothing -> '\n'  -- empty line counts as RET
          Just (hd, _) -> hd
    return $! keyTranslate c

-- | Display a prompt, wait for any key.
fpromptGetKey :: FrontendSession -> SingleFrame -> IO K.KM
fpromptGetKey sess frame = do
  fdisplay sess True $ Just frame
  nextEvent sess

keyTranslate :: Char -> K.KM
keyTranslate e = (\(key, modifier) -> K.KM {..}) $
  case e of
    '\ESC' -> (K.Esc,     K.NoModifier)
    '\n'   -> (K.Return,  K.NoModifier)
    '\r'   -> (K.Return,  K.NoModifier)
    ' '    -> (K.Space,   K.NoModifier)
    '\t'   -> (K.Tab,     K.NoModifier)
    c | ord '\^A' <= ord c && ord c <= ord '\^Z' ->
        -- Alas, only lower-case letters.
        (K.Char $ chr $ ord c - ord '\^A' + ord 'a', K.Control)
        -- Movement keys are more important than leader picking,
        -- so disabling the latter and interpreting the keypad numbers
        -- as movement:
      | c `elem` ['1'..'9'] -> (K.KP c,              K.NoModifier)
      | otherwise           -> (K.Char c,            K.NoModifier)
