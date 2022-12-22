{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Best current practice library for UDP servers.
--
--   * Efficient receiving function without memory copy.
--   * Proper buffer size.
--   * Type-safe APIs.
--   * TCP-like APIs (creating a UDP connection from a listing socket).
--
--   'Network.Socket.ByteString.recv' families use 'createAndTrim'
--   internaly.  So, one buffer is allocated before corresponding
--   system calls are called. Then another buffer is allocated
--   according to the input size and the input is copied.
--   Receiving functions provided by this library uses 'createUptoN'
--   to avoid the memory copy.
--
--   Recent application protocols are designed to avoid IP
--   fragmentation. So, the UDP payload size is never over 1,500.
--   This library uses 2,048 for the buffer size. This size ensures
--   no global locking when allocating 'ByteString' (i.e. a buffer).
--
--   To know the background of TCP-like APIs, see:
--
--   * https://kazu-yamamoto.hatenablog.jp/entry/2022/02/25/153122
module Network.UDP.Server (
  -- * Wildcard socket
    ListenSocket
  , listenSocket
  , ClientSockAddr
  , recvMsg
  , sendMsg
  -- * Connected socket
  , ConnectedSocket
  , connectedSocket
  , recv
  , send
  ) where

import Control.Concurrent
import qualified Control.Exception as E
import Control.Monad
import Data.ByteString (ByteString)
import Data.IP hiding (addr)
import qualified GHC.IO.Exception as E
import Network.Socket
import qualified Network.Socket.ByteString as NSB
import qualified System.IO.Error as E

import Network.UDP.Types

----------------------------------------------------------------

anySockAddr :: SockAddr -> SockAddr
anySockAddr (SockAddrInet p _)      = SockAddrInet  p 0
anySockAddr (SockAddrInet6 p f _ s) = SockAddrInet6 p f (0,0,0,0) s
anySockAddr _                       = error "anySockAddr"

isAnySockAddr :: SockAddr -> Bool
isAnySockAddr (SockAddrInet _ 0)              = True
isAnySockAddr (SockAddrInet6 _ _ (0,0,0,0) _) = True
isAnySockAddr _                               = False

----------------------------------------------------------------

-- | A listening socket for UDP which can be used
--   for 'recvMsg' and 'sendMsg'.
--   Optionally, a connected UDP socket can be created
--   with 'connectedSocket' as an emulation of TCP's accept().
data ListenSocket = Wildcard Socket
                  | InterfaceSpecific Socket
                  deriving (Eq, Show)

----------------------------------------------------------------

-- | Creating a listening UDP socket.
listenSocket :: (IP, PortNumber) -> IO (ListenSocket, ServerSockAddr)
listenSocket ip = E.bracketOnError open close $ \s -> do
    setSocketOption s ReuseAddr 1
    withFdSocket s setCloseOnExecIfNeeded
#if !defined(openbsd_HOST_OS)
    when (family == AF_INET6) $ setSocketOption s IPv6Only 1
#endif
    bind s sa
    let wildcard = isAnySockAddr sa
        sock | wildcard  = Wildcard s
             | otherwise = InterfaceSpecific s
    return (sock,ServerSockAddr sa)
  where
    sa     = toSockAddr ip
    family = sockAddrFamily sa
    open   = socket family Datagram defaultProtocol

----------------------------------------------------------------

-- | Receiving data with a listening UDP socket.
recvMsg :: ListenSocket -> IO (ByteString, ClientSockAddr, [Cmsg])
recvMsg (Wildcard s) = do
    (sa,b,c,_) <- NSB.recvMsg s properUDPSize properCMSGSize 0
    return (b,ClientSockAddr sa,c)
recvMsg (InterfaceSpecific s) = do
    (a,sa) <- NSB.recvFrom s properUDPSize
    return (a,ClientSockAddr sa,[])

-- | Sending data with a listening UDP socket.
sendMsg :: ListenSocket -> ByteString -> ClientSockAddr -> [Cmsg] -> IO ()
sendMsg = undefined

----------------------------------------------------------------

-- | Creating a connected UDP socket like TCP's accept().
connectedSocket :: ServerSockAddr -> ClientSockAddr -> IO ConnectedSocket
connectedSocket (ServerSockAddr mysa) (ClientSockAddr peersa) = E.bracketOnError open close $ \s -> do
    setSocketOption s ReuseAddr 1
    withFdSocket s setCloseOnExecIfNeeded
    let mysa' | isAnySockAddr mysa = mysa
              | otherwise          = anySockAddr mysa
    -- wildcard:  (UDP, *.443, *:*) -> (UDP, 127.0.0.1:443, *:*)
    -- otherwise: (UDP, 127.0.0.1:443, *:*) -> (UDP, *:443, *:*)
    bind s mysa'
    -- bind and connect is not atomic
    -- So, bind may results in EADDRINUSE
       `E.catch` postphone (bind s mysa')
    connect s peersa  -- (UDP, 127.0.0.1:443, pa:pp)
    return $ ConnectedSocket s
  where
    postphone action e
      | E.ioeGetErrorType e == E.ResourceBusy = threadDelay 10000 >> action
      | otherwise                             = E.throwIO e
    family = sockAddrFamily mysa
    open   = socket family Datagram defaultProtocol
