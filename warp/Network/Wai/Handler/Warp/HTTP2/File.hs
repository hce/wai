{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE BangPatterns, RecordWildCards #-}

module Network.Wai.Handler.Warp.HTTP2.File (
    RspFileInfo(..)
  , conditionalRequest
  , addContentHeadersForFilePart
  , parseByteRanges
  ) where

import Control.Applicative ((<|>))
import qualified Data.ByteString as B hiding (pack)
import qualified Data.ByteString.Char8 as B (pack, readInteger)
import Data.ByteString (ByteString)
import Data.Maybe (fromMaybe)
import Network.HTTP.Date
import qualified Network.HTTP.Types as H
import Network.Wai
import qualified Network.Wai.Handler.Warp.FileInfoCache as I
import Network.Wai.Handler.Warp.PackInt
import Numeric (showInt)
import Network.HPACK
import Network.HPACK.Token

#ifndef MIN_VERSION_http_types
#define MIN_VERSION_http_types(x,y,z) 1
#endif

-- $setup
-- >>> import Test.QuickCheck

----------------------------------------------------------------

data RspFileInfo = WithoutBody !H.Status
                 | WithBody !H.Status !TokenHeaderList !Integer !Integer
                 deriving (Eq,Show)

----------------------------------------------------------------

conditionalRequest :: I.FileInfo
                   -> TokenHeaderList -- Response
                   -> ValueTable -- Request
                   -> RspFileInfo
conditionalRequest (I.FileInfo _ size mtime date) ths0 reqtbl = case condition of
    nobody@(WithoutBody _) -> nobody
    WithBody s _ off len   -> let !hs = (tokenLastModified,date) :
                                        addContentHeaders ths0 off len size
                              in WithBody s hs off len
  where
    !mcondition = ifmodified    reqtbl size mtime
              <|> ifunmodified  reqtbl size mtime
              <|> ifrange       reqtbl size mtime
    !condition = fromMaybe (unconditional reqtbl size) mcondition

----------------------------------------------------------------

{-# INLINE ifModifiedSince #-}
ifModifiedSince :: ValueTable -> Maybe HTTPDate
ifModifiedSince reqtbl = getHeaderValue tokenIfModifiedSince reqtbl >>= parseHTTPDate

{-# INLINE ifUnmodifiedSince #-}
ifUnmodifiedSince :: ValueTable -> Maybe HTTPDate
ifUnmodifiedSince reqtbl = getHeaderValue tokenIfUnmodifiedSince reqtbl >>= parseHTTPDate

{-# INLINE ifRange #-}
ifRange :: ValueTable -> Maybe HTTPDate
ifRange reqtbl = getHeaderValue tokenIfRange reqtbl >>= parseHTTPDate

----------------------------------------------------------------

{-# INLINE ifmodified #-}
ifmodified :: ValueTable -> Integer -> HTTPDate -> Maybe RspFileInfo
ifmodified reqtbl size mtime = do
    date <- ifModifiedSince reqtbl
    return $ if date /= mtime
             then unconditional reqtbl size
             else WithoutBody H.notModified304

{-# INLINE ifunmodified #-}
ifunmodified :: ValueTable -> Integer -> HTTPDate -> Maybe RspFileInfo
ifunmodified reqtbl size mtime = do
    date <- ifUnmodifiedSince reqtbl
    return $ if date == mtime
             then unconditional reqtbl size
             else WithoutBody H.preconditionFailed412

{-# INLINE ifrange #-}
ifrange :: ValueTable -> Integer -> HTTPDate -> Maybe RspFileInfo
ifrange reqtbl size mtime = do
    date <- ifRange reqtbl
    rng  <- getHeaderValue tokenRange reqtbl
    return $ if date == mtime
             then parseRange rng size
             else WithBody H.ok200 [] 0 size

{-# INLINE unconditional #-}
unconditional :: ValueTable -> Integer -> RspFileInfo
unconditional reqtbl size = case getHeaderValue tokenRange reqtbl of
    Nothing  -> WithBody H.ok200 [] 0 size
    Just rng -> parseRange rng size

----------------------------------------------------------------

{-# INLINE parseRange #-}
parseRange :: ByteString -> Integer -> RspFileInfo
parseRange rng size = case parseByteRanges rng of
    Nothing    -> WithoutBody H.requestedRangeNotSatisfiable416
    Just []    -> WithoutBody H.requestedRangeNotSatisfiable416
    Just (r:_) -> let (!beg, !end) = checkRange r size
                      !len = end - beg + 1
                      s = if beg == 0 && end == size - 1 then
                              H.ok200
                            else
                              H.partialContent206
                  in WithBody s [] beg len

{-# INLINE checkRange #-}
checkRange :: H.ByteRange -> Integer -> (Integer, Integer)
checkRange (H.ByteRangeFrom   beg)     size = (beg, size - 1)
checkRange (H.ByteRangeFromTo beg end) size = (beg,  min (size - 1) end)
checkRange (H.ByteRangeSuffix count)   size = (max 0 (size - count), size - 1)

{-# INLINE parseByteRanges #-}
-- | Parse the value of a Range header into a 'H.ByteRanges'.
parseByteRanges :: B.ByteString -> Maybe H.ByteRanges
parseByteRanges bs1 = do
    bs2 <- stripPrefix "bytes=" bs1
    (r, bs3) <- range bs2
    ranges (r:) bs3
  where
    range bs2 = do
        (i, bs3) <- B.readInteger bs2
        if i < 0 -- has prefix "-" ("-0" is not valid, but here treated as "0-")
            then Just (H.ByteRangeSuffix (negate i), bs3)
            else do
                bs4 <- stripPrefix "-" bs3
                case B.readInteger bs4 of
                    Just (j, bs5) | j >= i -> Just (H.ByteRangeFromTo i j, bs5)
                    _ -> Just (H.ByteRangeFrom i, bs4)
    ranges front bs3
        | B.null bs3 = Just (front [])
        | otherwise = do
            bs4 <- stripPrefix "," bs3
            (r, bs5) <- range bs4
            ranges (front . (r:)) bs5

    stripPrefix x y
        | x `B.isPrefixOf` y = Just (B.drop (B.length x) y)
        | otherwise = Nothing

----------------------------------------------------------------

{-# INLINE contentRangeHeader #-}
-- | @contentRangeHeader beg end total@ constructs a Content-Range 'H.Header'
-- for the range specified.
contentRangeHeader :: Integer -> Integer -> Integer -> TokenHeader
contentRangeHeader beg end total = (tokenContentRange, range)
  where
    range = B.pack
      -- building with ShowS
      $ 'b' : 'y': 't' : 'e' : 's' : ' '
      : (if beg > end then ('*':) else
          showInt beg
          . ('-' :)
          . showInt end)
      ( '/'
      : showInt total "")

{-# INLINE addContentHeaders #-}
addContentHeaders :: TokenHeaderList -> Integer -> Integer -> Integer -> TokenHeaderList
addContentHeaders ths off len size
  | len == size = ths'
  | otherwise   = let !ctrng = contentRangeHeader off (off + len - 1) size
                  in ctrng:ths'
  where
    !lengthBS = packIntegral len
    !ths' = (tokenContentLength, lengthBS) : (tokenAcceptRanges,"bytes") : ths

{-# INLINE addContentHeadersForFilePart #-}
-- |
--
-- >>> addContentHeadersForFilePart [] (FilePart 2 10 16)
-- [("Content-Range","bytes 2-11/16"),("Content-Length","10"),("Accept-Ranges","bytes")]
-- >>> addContentHeadersForFilePart [] (FilePart 0 16 16)
-- [("Content-Length","16"),("Accept-Ranges","bytes")]
addContentHeadersForFilePart :: TokenHeaderList -> FilePart -> TokenHeaderList
addContentHeadersForFilePart hs part = addContentHeaders hs off len size
  where
    off = filePartOffset part
    len = filePartByteCount part
    size = filePartFileSize part
