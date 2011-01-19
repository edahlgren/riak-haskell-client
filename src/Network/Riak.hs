{-# LANGUAGE OverloadedStrings, RecordWildCards #-}

module Network.Riak
    (
      ClientID
    , Client(..)
    , Connection(connClient)
    , Network.Riak.connect
    , defaultClient
    , makeClientID
    , ping
    , get
    , Network.Riak.put
    ) where

import qualified Data.ByteString.Char8 as B
import Control.Applicative
import Data.Binary hiding (get)
import Data.Binary.Put
import Control.Monad
import Network.Socket.ByteString.Lazy as L
import Network.Socket as Socket
import Network.Riakclient.RpbContent
import Network.Riakclient.RpbPutReq
import Network.Riakclient.RpbPutResp
import qualified Data.ByteString.Lazy.Char8 as L
import Numeric (showHex)
import System.Random
import qualified Network.Riak.Message.Code as Code
import Network.Riakclient.RpbGetReq as GetReq
import Network.Riakclient.RpbGetResp
import Network.Riakclient.RpbSetClientIdReq
import Network.Riak.Message
import Network.Riak.Types as T
import Network.Riak.Types.Internal
import Text.ProtocolBuffers
import Data.IORef

defaultClient :: Client
defaultClient = Client {
                  riakHost = "127.0.0.1"
                , riakPort = "8087"
                , riakPrefix = "riak"
                , riakMapReducePrefix = "mapred"
                , riakClientID = L.empty
                }

makeClientID :: IO ClientID
makeClientID = do
  r <- randomIO :: IO Int
  return . L.append "hs_" . L.pack . showHex (abs r) $ ""

addClientID :: Client -> IO Client
addClientID client
  | L.null (riakClientID client) = do
    i <- makeClientID
    return client { riakClientID = i }
  | otherwise = return client

connect :: Client -> IO Connection
connect cli0 = do
  client@Client{..} <- addClientID cli0
  let hints = defaultHints
  (ai:_) <- getAddrInfo (Just hints) (Just riakHost) (Just riakPort)
  sock <- socket (addrFamily ai) (addrSocketType ai) (addrProtocol ai)
  Socket.connect sock (addrAddress ai)
  buf <- newIORef L.empty
  let conn = Connection sock client buf
  setClientID conn riakClientID
  return conn

ping :: Connection -> IO ()
ping conn@Connection{..} = do
  L.sendAll connSock $ runPut putPingReq
  _ <- recvResponse conn
  return ()

get :: Connection -> T.Bucket -> T.Key -> Maybe R
    -> IO (Maybe (Seq Content, Maybe VClock))
get conn@Connection{..} bucket key r = do
  let req = RpbGetReq { bucket = bucket, key = key, r = fromQuorum <$> r }
  sendRequest conn req
  resp <- recvResponse conn
  case resp of
    Left msg | msg == Code.getResp -> return Nothing
    Right (GetResponse RpbGetResp{..}) -> return . Just $ (content, VClock <$> vclock)
    bad             -> fail $  "get: invalid response " ++ show bad

put :: Connection -> T.Bucket -> T.Key -> Maybe T.VClock
    -> Content -> Maybe W -> Maybe DW -> Bool
    -> IO (Seq Content, Maybe VClock)
put conn@Connection{..} bucket key vclock content w dw returnBody = do
  let req = RpbPutReq bucket key (fromVClock <$> vclock) content (fromQuorum <$> w) (fromQuorum <$> dw) (Just returnBody)
  sendRequest conn req
  resp <- recvResponse_ conn
  case resp of
    PutResponse RpbPutResp{..} -> return (content, VClock <$> vclock)
    bad ->  fail $ "put: invalid response " ++ show bad

setClientID :: Connection -> ClientID -> IO ()
setClientID conn id = do
  let req = RpbSetClientIdReq { client_id = id }
  sendRequest conn req
  resp <- recvResponse_ conn
  unless (resp == SetClientIDResponse) .
    fail $ "setClientID: invalid response " ++ show resp