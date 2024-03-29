# `halond` profiling

1. Build `halond` with profiling enabled:

```bash
scripts/h0 make --profile --no-test --flag cep:profiling
```

2. Run it with profiling option:

```diff
--- a/systemd/halond.service
+++ b/systemd/halond.service
@@ -9,7 +9,7 @@ EnvironmentFile=/etc/sysconfig/halond
 # Uncomment to perform cleanup of the old Halon m0trace.PID files on startup,
 # this can be helpful for debugging.
 #ExecStartPre=/usr/bin/systemd-tmpfiles --remove halond.conf
-ExecStart=/usr/bin/halond -l $HALOND_LISTEN +RTS -s -A32m -I0 -RTS
+ExecStart=/usr/bin/halond -l $HALOND_LISTEN +RTS -s -A32m -I0 -p -RTS
 ExecReload=/bin/kill -HUP $MAINPID
 ExecStop=/bin/kill -INT $MAINPID
 TimeoutStopSec=1m 3s
```

```bash
scripts/h0 init
hctl mero bootstrap
```

3. Kill `halond` process with `INT` signal.

```bash
sudo pkill -INT halond
```

The profiling data will be dumped to `/var/lib/halon/halond.prof` file.

## See also

- GHC Users Guide, [Profiling](https://downloads.haskell.org/~ghc/8.0.2/docs/html/users_guide/profiling.html).
