{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
-- |
-- Module       : Data.ByteString.Base64.Internal.Head
-- Copyright    : (c) 2019 Emily Pillmore
-- License      : BSD-style
--
-- Maintainer   : Emily Pillmore <emilypi@cohomolo.gy>
-- Stability    : Experimental
-- Portability  : portable
--
-- Shared internal utils
--
module Data.ByteString.Base64.Internal.Head
( encodeBase64_
, encodeBase64Nopad_
, decodeBase64_
, decodeBase64Lenient_
) where

#include "MachDeps.h"

import qualified Data.ByteString as BS
import Data.ByteString.Base64.Internal.Tail
import Data.ByteString.Base64.Internal.Utils
#if WORD_SIZE_IN_BITS == 32
import Data.ByteString.Base64.Internal.W32.Loop
#elif WORD_SIZE_IN_BITS >= 64
import Data.ByteString.Base64.Internal.W64.Loop
#else
import Data.ByteString.Base64.Internal.W16.Loop
#endif
import Data.ByteString.Internal
import Data.Text (Text)

import Foreign.ForeignPtr
import Foreign.Ptr
import Foreign.Storable

import GHC.ForeignPtr
import GHC.Word

import System.IO.Unsafe


encodeBase64_ :: EncodingTable -> ByteString -> ByteString
encodeBase64_ (EncodingTable !aptr !efp) (PS !sfp !soff !slen) =
    unsafeDupablePerformIO $ do
      dfp <- mallocPlainForeignPtrBytes dlen
      withForeignPtr dfp $ \dptr ->
        withForeignPtr sfp $ \sptr ->
        withForeignPtr efp $ \eptr -> do
          let !end = plusPtr sptr (soff + slen)
          innerLoop
            eptr
            (castPtr (plusPtr sptr soff))
            (castPtr dptr)
            end
            (loopTail dfp aptr end)
            0
  where
    !dlen = 4 * ((slen + 2) `div` 3)

encodeBase64Nopad_ :: EncodingTable -> ByteString -> ByteString
encodeBase64Nopad_ (EncodingTable !aptr !efp) (PS !sfp !soff !slen) =
    unsafeDupablePerformIO $ do
      dfp <- mallocPlainForeignPtrBytes dlen
      withForeignPtr dfp $ \dptr ->
        withForeignPtr efp $ \etable ->
        withForeignPtr sfp $ \sptr -> do
          let !end = plusPtr sptr (soff + slen)
          innerLoop
            etable
            (castPtr (plusPtr sptr soff))
            (castPtr dptr)
            end
            (loopTailNoPad dfp aptr end)
            0
  where
    !dlen = 4 * ((slen + 2) `div` 3)

-- | The main decode function. Takes a padding flag, a decoding table, and
-- the input value, producing either an error string on the left, or a
-- decoded value.
--
-- Note: If 'Padding' ~ 'Don\'tCare', then we pad out the input to a multiple of 4.
-- If 'Padding' ~ 'Padded', then we do not, and fail if the input is not
-- a multiple of 4 in length. If 'Padding' ~ 'Unpadded', then we validate
-- correctness of length and the absence of padding and then treat as a std
-- padded string.
--
decodeBase64_
    :: Padding
    -> ForeignPtr Word8
    -> ByteString
    -> Either Text ByteString
decodeBase64_ _ _ (PS _ _ 0) = Right mempty
decodeBase64_ !pad !dtfp !bs@(PS !fp !o !l) = unsafeDupablePerformIO $
    case pad of
      Don'tCare
        | r == 0 -> go bs
        | r == 2 -> go (BS.append bs (BS.replicate 2 0x3d))
        | r == 3 -> go (BS.append bs (BS.replicate 1 0x3d))
        | otherwise -> err "Base64-encoded bytestring has invalid size"
      Padded
        | r /= 0 -> err "Base64-encoded bytestring has invalid padding"
        | otherwise -> go bs
      Unpadded
        | r == 0 -> validateUnpadded (go bs)
        | r == 1 -> err "Base64-encoded bytestring has invalid size"
        | r == 2 -> validateUnpadded (go (BS.append bs (BS.replicate 2 0x3d)))
        | r == 3 -> validateUnpadded (go (BS.append bs (BS.replicate 1 0x3d)))
        | otherwise -> err "Base64-encoded bytestring required to be unpadded"
    where
    (!q, !r) = divMod l 4
    !dlen = q * 3

    err = return . Left

    validateUnpadded io = withForeignPtr fp $ \p -> do
      let !end = l + o
      a <- peek @Word8 (plusPtr p (end - 1))
      b <- peek @Word8 (plusPtr p (end - 2))

      if a == 0x3d || b == 0x3d
      then err "Base64-encoded bytestring required to be unpadded"
      else io

    go (PS !sfp !soff !slen') =
      withForeignPtr dtfp $ \dtable ->
      withForeignPtr sfp $ \sptr -> do
        dfp <- mallocPlainForeignPtrBytes dlen
        withForeignPtr dfp $ \dptr ->
          decodeLoop
            dtable
            (castPtr (plusPtr sptr soff))
            (castPtr dptr)
            (castPtr (plusPtr sptr (soff + slen')))
            dfp
            0

decodeBase64Lenient_ :: ForeignPtr Word8 -> ByteString -> ByteString
decodeBase64Lenient_ !dtfp (PS !sfp !soff !slen) = unsafeDupablePerformIO $
    withForeignPtr dtfp $ \dtable ->
    withForeignPtr sfp $ \sptr -> do
      dfp <- mallocPlainForeignPtrBytes dlen
      withForeignPtr dfp $ \dptr ->
        lenientLoop
          dtable
          (plusPtr sptr soff)
          dptr
          (plusPtr sptr (soff + slen))
          dfp
  where
    !dlen = ((slen + 3) `div` 4) * 3
