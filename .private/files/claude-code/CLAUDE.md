## Ports — read this before starting any server

Only the ports in the $CS193V_PORTS variable are available.

If available, ports in the range 6173-6182 are intended as spares in case a tool's default
is already taken.

Host's localhost is SSH forwarded to the container localhost, so servers can bind
to localhost. Binding ::1 does not work because forwarding is done over IPv4.

## Miscellaneous

- `sudo` works without a password.
