-- | The host ABI a code-mode guest may import, checked when the guest is
-- embedded. Mirrors scripts/check-codemode-imports.py, which guards the Nix
-- build of the guest; this guards a build that embeds a stale guest (a dev
-- shell evaluated before codemode/quickjs.c changed), which would otherwise
-- compile and then trap on every program with "unknown import".
module Max.CodeMode.Abi (hostImports, guestImports, checkGuestAbi) where

import Data.Bits (shiftL, (.&.), (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE

hostImports :: [(Text, Text)]
hostImports = [("max_v1", name) | name <- ["input_size", "input_read", "output_write"]]

-- | Function imports of a core Wasm v1 module, in order.
guestImports :: ByteString -> Either Text [(Text, Text)]
guestImports bytes
  | BS.take 8 bytes /= BS.pack [0, 0x61, 0x73, 0x6d, 1, 0, 0, 0] = Left "not a core Wasm v1 module"
  | otherwise = sections 8
  where
    sections offset
      | offset >= BS.length bytes = Right []
      | otherwise = do
          (size, start) <- number (offset + 1)
          let next = start + size
          if BS.index bytes offset == 2
            then do
              (count, at) <- number start
              (found, end) <- entries count at
              if end == next then Right found else Left "malformed import section"
            else sections next
    entries :: Int -> Int -> Either Text ([(Text, Text)], Int)
    entries 0 at = Right ([], at)
    entries n at = do
      (module', at1) <- string at
      (name, at2) <- string at1
      if at2 < BS.length bytes && BS.index bytes at2 == 0
        then do
          (_, at3) <- number (at2 + 1)
          (rest, end) <- entries (n - 1) at3
          Right ((module', name) : rest, end)
        else Left ("non-function import " <> module' <> "::" <> name)
    string at = do
      (len, start) <- number at
      if start + len <= BS.length bytes
        then Right (TE.decodeUtf8Lenient (BS.take len (BS.drop start bytes)), start + len)
        else Left "truncated name"
    number = go 0 0
      where
        go value shift at
          | shift > 28 || at >= BS.length bytes = Left "invalid LEB128"
          | otherwise =
              let byte = BS.index bytes at
                  value' = value .|. (fromIntegral (byte .&. 0x7f) `shiftL` shift)
               in if byte < 0x80 then Right (value', at + 1) else go value' (shift + 7) (at + 1)

-- | The guest must import exactly the host ABI.
checkGuestAbi :: ByteString -> Either Text ()
checkGuestAbi bytes = do
  found <- guestImports bytes
  if sort found == sort hostImports
    then Right ()
    else Left ("guest imports " <> render found <> ", host provides " <> render hostImports)
  where
    render = T.intercalate ", " . map (\(m, n) -> m <> "::" <> n)
