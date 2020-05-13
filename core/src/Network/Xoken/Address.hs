{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}

{-|
Module      : Network.Xoken.Address
Copyright   : Xoken Labs
License     : Open BSV License

Stability   : experimental
Portability : POSIX

Base58 address and WIF private key serialization support.
-}
module Network.Xoken.Address
    ( Address(..)
    , isPubKeyAddress
    , isScriptAddress
    , addrToString
    , stringToAddr
    , addrToJSON
    , addrFromJSON
    , pubKeyAddr
    , p2pkhAddr
    , p2shAddr
    , inputAddress
    , outputAddress
    , addressToScript
    , addressToScriptBS
    , addressToOutput
    , payToScriptAddress
    , scriptToAddress
    , scriptToAddressBS
      -- * Private Key Wallet Import Format (WIF)
    , fromWif
    , toWif
    ) where

import Control.Applicative
import Control.Monad
import Data.Aeson as A
import Data.Aeson.Types
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Hashable
import Data.Maybe
import Data.Serialize as S
import Data.Text (Text)
import GHC.Generics (Generic)
import Network.Xoken.Address.Base58
import Network.Xoken.Constants
import Network.Xoken.Crypto
import Network.Xoken.Keys.Common
import Network.Xoken.Script
import Network.Xoken.Util

-- | Address format for Bitcoin SV
data Address
    -- | pay to public key hash (regular)
    = PubKeyAddress
          { getAddrHash160 :: !Hash160
                      -- ^ RIPEMD160 hash of public key's SHA256 hash
          }
    -- | pay to script hash
    | ScriptAddress
          { getAddrHash160 :: !Hash160
                      -- ^ RIPEMD160 hash of script's SHA256 hash
          }
    deriving (Eq, Ord, Generic, Show, Read, Serialize, Hashable)

-- | 'Address' pays to a public key hash.
isPubKeyAddress :: Address -> Bool
isPubKeyAddress PubKeyAddress {} = True
isPubKeyAddress _ = False

-- | 'Address' pays to a script hash.
isScriptAddress :: Address -> Bool
isScriptAddress ScriptAddress {} = True
isScriptAddress _ = False

-- | Deserializer for binary 'Base58' addresses.
base58get :: Network -> Get Address
base58get net = do
    pfx <- getWord8
    addr <- S.get
    f pfx addr
  where
    f x a
        | x == getAddrPrefix net = return $ PubKeyAddress a
        | x == getScriptPrefix net = return $ ScriptAddress a
        | otherwise = fail "Does not recognize address prefix"

-- | Binary serializer for 'Base58' addresses.
base58put :: Network -> Putter Address
base58put net (PubKeyAddress h) = do
    putWord8 (getAddrPrefix net)
    put h
base58put net (ScriptAddress h) = do
    putWord8 (getScriptPrefix net)
    put h
base58put _ _ = error "Cannot serialize this address as Base58"

addrToJSON :: Network -> Address -> Value
addrToJSON net a = toJSON (addrToString net a)

-- | JSON parsing for Bitcoin addresses. Works with 'Base58'
addrFromJSON :: Network -> Value -> Parser Address
addrFromJSON net =
    withText "address" $ \t ->
        case stringToAddr net t of
            Nothing -> fail "could not decode address"
            Just x -> return x

-- | Convert address to human-readable string. Uses 'Base58'
addrToString :: Network -> Address -> Maybe Text
addrToString net a@PubKeyAddress {getAddrHash160 = h} = Just . encodeBase58Check . runPut $ base58put net a
addrToString net a@ScriptAddress {getAddrHash160 = h} = Just . encodeBase58Check . runPut $ base58put net a

--
-- | Parse 'Base58' address
stringToAddr :: Network -> Text -> Maybe Address
stringToAddr net bs = b58
  where
    b58 = eitherToMaybe . runGet (base58get net) =<< decodeBase58Check bs

-- | Obtain a standard pay-to-public-key-hash address from a public key.
pubKeyAddr :: PubKeyI -> Address
pubKeyAddr = PubKeyAddress . addressHash . S.encode

-- | Obtain a standard pay-to-public-key-hash (P2PKH) address from a 'Hash160'.
p2pkhAddr :: Hash160 -> Address
p2pkhAddr = PubKeyAddress

-- | Obtain a standard pay-to-script-hash (P2SH) address from a 'Hash160'.
p2shAddr :: Hash160 -> Address
p2shAddr = ScriptAddress

-- | Compute a standard pay-to-script-hash (P2SH) address for an output script.
payToScriptAddress :: ScriptOutput -> Address
payToScriptAddress = p2shAddr . addressHash . encodeOutputBS

-- | Encode an output script from an address. Will fail if using a
-- pay-to-witness address on a non-SegWit network.
addressToOutput :: Address -> ScriptOutput
addressToOutput (PubKeyAddress h) = PayPKHash h
addressToOutput (ScriptAddress h) = PayScriptHash h

-- | Get output script AST for an 'Address'.
addressToScript :: Address -> Script
addressToScript = encodeOutput . addressToOutput

-- | Encode address as output script in 'ByteString' form.
addressToScriptBS :: Address -> ByteString
addressToScriptBS = S.encode . addressToScript

-- | Decode an output script into an 'Address' if it has such representation.
scriptToAddress :: Script -> Either String Address
scriptToAddress = maybeToEither "Could not decode address" . outputAddress <=< decodeOutput

-- | Decode a serialized script into an 'Address'.
scriptToAddressBS :: ByteString -> Either String Address
scriptToAddressBS = maybeToEither "Could not decode address" . outputAddress <=< decodeOutputBS

-- | Get the 'Address' of a 'ScriptOutput'.
outputAddress :: ScriptOutput -> Maybe Address
outputAddress (PayPKHash h) = Just $ PubKeyAddress h
outputAddress (PayScriptHash h) = Just $ ScriptAddress h
outputAddress (PayPK k) = Just $ pubKeyAddr k
outputAddress _ = Nothing

-- | Infer the 'Address' of a 'ScriptInput'.
inputAddress :: ScriptInput -> Maybe Address
inputAddress (RegularInput (SpendPKHash _ key)) = Just $ pubKeyAddr key
inputAddress (ScriptHashInput _ rdm) = Just $ payToScriptAddress rdm
inputAddress _ = Nothing

-- | Decode private key from WIF (wallet import format) string.
fromWif :: Network -> Base58 -> Maybe SecKeyI
fromWif net wif = do
    bs <- decodeBase58Check wif
    -- Check that this is a private key
    guard (B.head bs == getSecretPrefix net)
    case B.length bs
        -- Uncompressed format
          of
        33 -> wrapSecKey False <$> secKey (B.tail bs)
        -- Compressed format
        34 -> do
            guard $ B.last bs == 0x01
            wrapSecKey True <$> secKey (B.tail $ B.init bs)
        -- Bad length
        _ -> Nothing

-- | Encode private key into a WIF string.
toWif :: Network -> SecKeyI -> Base58
toWif net (SecKeyI k c) =
    encodeBase58Check . B.cons (getSecretPrefix net) $
    if c
        then getSecKey k `B.snoc` 0x01
        else getSecKey k
