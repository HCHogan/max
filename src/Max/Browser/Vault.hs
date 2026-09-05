module Max.Browser.Vault (BrowserVault, newBrowserVault, loadBrowserVault, sealBrowserState, openBrowserState) where

import Control.Exception (bracket, onException)
import Control.Monad (unless)
import Crypto.Cipher.AES (AES256)
import Crypto.Cipher.Types (AEADMode (AEAD_GCM), AuthTag (..), aeadInit, aeadSimpleDecrypt, aeadSimpleEncrypt, cipherInit)
import Crypto.Error (CryptoFailable (..))
import Crypto.Random (getRandomBytes)
import Data.Aeson (Value, eitherDecodeStrict', encode)
import Data.ByteArray qualified as BA
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as B64
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import System.Directory (createDirectoryIfMissing, doesFileExist, removeFile)
import System.FilePath (takeDirectory)
import System.IO (hClose, openBinaryTempFile)
import System.IO.Error (catchIOError, isAlreadyExistsError)
import System.Posix.Files (createLink, fileMode, fileOwner, getSymbolicLinkStatus, intersectFileModes, isRegularFile, setFileMode)
import System.Posix.IO (OpenMode (ReadOnly), closeFd, defaultFileFlags, openFd)
import System.Posix.Unistd (fileSynchronise)
import System.Posix.User (getEffectiveUserID)

newtype BrowserVault = BrowserVault AES256

newBrowserVault :: IO BrowserVault
newBrowserVault = getRandomBytes 32 >>= vaultFromBytes

vaultFromBytes :: BS.ByteString -> IO BrowserVault
vaultFromBytes bytes = case cipherInit bytes of
  CryptoPassed cipher -> pure (BrowserVault cipher)
  CryptoFailed _ -> ioError (userError "invalid browser state encryption key")

loadBrowserVault :: FilePath -> IO BrowserVault
loadBrowserVault path = do
  let directory = takeDirectory path
  createDirectoryIfMissing True directory
  exists <- doesFileExist path
  unless exists $
    bracket
      (openBinaryTempFile directory ".browser-key")
      (\(temporary, _) -> removeFile temporary)
      ( \(temporary, handle) -> do
          setFileMode temporary 0o600
          bytes <- getRandomBytes 32
          (BS.hPut handle bytes >> hClose handle) `onException` hClose handle
          syncPath temporary
          createLink temporary path `catchIOError` \exception ->
            unless (isAlreadyExistsError exception) (ioError exception)
          syncPath directory
      )
  status <- getSymbolicLinkStatus path
  owner <- getEffectiveUserID
  unless (isRegularFile status && fileOwner status == owner && fileMode status `intersectFileModes` 0o077 == 0) $
    ioError (userError "browser state key must be an owner-only regular file")
  bytes <- BS.readFile path
  unless (BS.length bytes == 32) (ioError (userError "browser state key must contain 32 bytes"))
  vaultFromBytes bytes

syncPath :: FilePath -> IO ()
syncPath path = bracket (openFd path ReadOnly defaultFileFlags) closeFd fileSynchronise

sealBrowserState :: BrowserVault -> Text -> Value -> IO Text
sealBrowserState (BrowserVault cipher) identity value = do
  nonce <- getRandomBytes 12
  case aeadInit AEAD_GCM cipher (nonce :: BS.ByteString) of
    CryptoFailed _ -> ioError (userError "browser state encryption unavailable")
    CryptoPassed context -> do
      let (tag, ciphertext) = aeadSimpleEncrypt context (TE.encodeUtf8 identity) (LBS.toStrict (encode value)) 16
      pure (TE.decodeUtf8 (B64.encode (nonce <> BA.convert tag <> ciphertext)))

openBrowserState :: BrowserVault -> Text -> Text -> Either Text Value
openBrowserState (BrowserVault cipher) identity encoded = do
  envelope <- either (const denied) Right (B64.decode (TE.encodeUtf8 encoded))
  if BS.length envelope < 28
    then denied
    else do
      let (nonce, payload) = BS.splitAt 12 envelope
          (tag, ciphertext) = BS.splitAt 16 payload
      case aeadInit AEAD_GCM cipher nonce of
        CryptoFailed _ -> denied
        CryptoPassed context -> case aeadSimpleDecrypt context (TE.encodeUtf8 identity) ciphertext (AuthTag (BA.convert tag)) of
          Nothing -> denied
          Just plaintext -> either (const denied) Right (eitherDecodeStrict' plaintext)
  where
    denied = Left "browser checkpoint authentication failed; restore the original key or explicitly reset the workspace"
