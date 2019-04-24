## Version 2.6.3.6
 * Removed unnecessary withMVar, which caused locking on close.
   [#330](https://github.com/haskell/network/pull/330)

## Version 2.6.3.5
 * Reverting "Do not closeFd within sendFd"
   [#271](https://github.com/haskell/network/pull/271)

## Version 2.6.3.4

 * Don't touch IPv6Only when running on OpenBSD
   [#227](https://github.com/haskell/network/pull/227)
 * Do not closeFd within sendFd
   [#271](https://github.com/haskell/network/pull/271)
 * Updating examples and docs.

## Version 2.6.3.3

 * Adds a function to show the defaultHints without reading their undefined fields
   [#291](https://github.com/haskell/network/pull/291)
 * Improve exception error messages for getAddrInfo and getNameInfo
   [#289](https://github.com/haskell/network/pull/289)
 * Deprecating SockAddrCan.

## Version 2.6.3.2

 * Zero memory of `sockaddr_un` if abstract socket
   [#220](https://github.com/haskell/network/pull/220)

 * Improving error messages
   [#232](https://github.com/haskell/network/pull/232)

 * Allow non-blocking file descriptors via `setNonBlockIfNeeded`
   [#242](https://github.com/haskell/network/pull/242)

 * Update config.{guess,sub} to latest version
   [#244](https://github.com/haskell/network/pull/244)

 * Rename `my_inet_ntoa` to avoid symbol conflicts
   [#228](https://github.com/haskell/network/pull/228)

 * Test infrastructure improvements
   [#219](https://github.com/haskell/network/pull/219)
   [#217](https://github.com/haskell/network/pull/217)
   [#218](https://github.com/haskell/network/pull/218)

 * House keeping and cleanup
   [#238](https://github.com/haskell/network/pull/238)
   [#237](https://github.com/haskell/network/pull/237)

## Version 2.6.3.1

 * Reverse breaking exception change in `Network.Socket.ByteString.recv`
   [#215](https://github.com/haskell/network/issues/215)

## Version 2.6.3.0

 * New maintainers: Evan Borden (@eborden) and Kazu Yamamoto (@kazu-yamamoto).
   The maintainer for a long period, Johan Tibell (@tibbe) stepped down.
   Thank you, Johan, for your hard work for a long time.

 * New APIs: ntohl, htonl,hostAddressToTuple{,6} and tupleToHostAddress{,6}.
   [#210](https://github.com/haskell/network/pull/210)

 * Added a Read instance for PortNumber. [#145](https://github.com/haskell/network/pull/145)

 * We only set the IPV6_V6ONLY flag to 0 for stream and datagram socket types,
   as opposed to all of them. This makes it possible to use ICMPv6.
   [#180](https://github.com/haskell/network/pull/180)
   [#181](https://github.com/haskell/network/pull/181)

 * Work around GHC bug #12020. Socket errors no longer cause segfaults or
   hangs on Windows. [#192](https://github.com/haskell/network/pull/192)

 * Various documentation improvements and the deprecated pragmas.
   [#186](https://github.com/haskell/network/pull/186)
   [#201](https://github.com/haskell/network/issues/201)
   [#205](https://github.com/haskell/network/pull/205)
   [#206](https://github.com/haskell/network/pull/206)
   [#211](https://github.com/haskell/network/issues/211)

 * Various internal improvements.
   [#193](https://github.com/haskell/network/pull/193)
   [#200](https://github.com/haskell/network/pull/200)

## Version 2.6.2.1

 * Regenerate configure and HsNetworkConfig.h.in.

 * Better detection of CAN sockets.

## Version 2.6.2.0

 * Add support for TCP_USER_TIMEOUT.

 * Don't conditionally export the SockAddr constructors.

 * Add isSupportSockAddr to allow checking for supported address types
   at runtime.
