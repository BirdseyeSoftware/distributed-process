module Main where

import Network.Transport
import Network.Transport.TCP (mkTransport, TCPConfig (..))

import Control.Monad (forever, replicateM_)
import Criterion.Main (Benchmark, bench, defaultMain, nfIO)
import Data.Binary
import Data.ByteString.Lazy (ByteString)
import Data.Maybe (fromJust)
import Data.Int
import System.Environment (getArgs, withArgs)

import qualified Data.ByteString.Lazy as BS

-- | This performs a benchmark on the TCP transport to measure how long
-- it takes to transfer a number of bytes. This can be compiled using:
--
--     ghc --make -idistributed-process/src -inetwork-transport/src -O2 benchmarks/SendTransport.hs
--
-- To use the compiled binary, first set up a server:
--
--     ./benchmarks/SendTransport server 0.0.0.0 8080 sourceAddr
--
-- Once this is established, launch a client to perform the benchmark. The
-- following command sends 1000 bytes per mark.
--
--     ./benchmarks/SendTransport client 0.0.0.0 8081 sourceAddr 1000
--
-- The server must be restarted between benchmarks.
main :: IO ()
main = do
  args <- getArgs
  case args of
    "server" : host : service : sourceAddrFilePath : [] -> do

      -- establish transport
      transport <- mkTransport $ TCPConfig defaultHints host service

      -- create ping end
      putStrLn "server: creating ping end"
      (sourceAddrPing, targetEndPing) <- newConnection transport
      BS.writeFile sourceAddrFilePath $ serialize sourceAddrPing

      -- create pong end
      putStrLn "server: creating pong end"
      [sourceAddrPongBS] <- receive targetEndPing
      sourceEndPong <- connect . fromJust $ deserialize transport sourceAddrPongBS

      -- always respond to a ping with a pong
      putStrLn "server: awaiting pings"
      forever $ pong targetEndPing sourceEndPong


    "client" : host : service : sourceAddrFilePath : sizeStr : args' -> do
      let size = read sizeStr
      let bs = BS.replicate size 0

      -- establish transport
      transport <- mkTransport $ TCPConfig defaultHints host service

      -- create ping end
      sourceAddrPingBS <- BS.readFile sourceAddrFilePath
      sourceEndPing <- connect . fromJust $ deserialize transport sourceAddrPingBS

      -- create pong end
      (sourceAddrPong, targetEndPong) <- newConnection transport
      send sourceEndPing [serialize sourceAddrPong]

      -- benchmark the pings
      withArgs args' $ defaultMain [ benchSend sourceEndPing targetEndPong bs ]

-- | The effect of `ping sourceEndPing targetEndPong bs` is to send the
-- `ByteString` `bs` using `sourceEndPing`, and to then receive
-- a single byte back from `targetEndPong`.
ping :: SourceEnd -> TargetEnd -> ByteString -> IO Word8
ping sourceEndPing targetEndPong bs = do
  send sourceEndPing [bs]
  [cs] <- receive targetEndPong
  return $ decode cs

-- | This function takes a `TargetEnd` for the pings, and a `SourceEnd` for
-- pongs. Whenever a ping is received from the `TargetEnd`, a pong is sent
-- in reply down the `SourceEnd`, repeating whatever was sent.
pong :: TargetEnd -> SourceEnd -> IO ()
pong targetEndPing sourceEndPong = do
  bs <- receive targetEndPing
  send sourceEndPong [encode (0 :: Word8)]

-- | The effect of `benchSend sourceEndPing targetEndPong bs` is to send
-- `bs` pings down `sourceEndPing` using the `ping` function. The time
-- taken is benchmarked.
benchSend :: SourceEnd -> TargetEnd -> ByteString -> Benchmark
benchSend sourceEndPing targetEndPong bs = bench "Transport Ping" $
  nfIO (ping sourceEndPing targetEndPong bs)

