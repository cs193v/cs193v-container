## Ports — read this before starting any server

Only the ports in the $CS193V_PORTS variable are available.

If available, ports in the range 6173-6182 are intended as spares in case a tool's default
is already taken.

Host's localhost is SSH forwarded to the container localhost, so servers can bind
to localhost. Binding ::1 does not work because forwarding is done over IPv4.

## Browser tests

Playwright and the Chromium headless shell are already installed in this image. When a
project needs browser tests, run `playwright --version` and add `@playwright/test` at
exactly that version. Any other version pins a different Chromium build and downloads it on
first run (about 114 MB), which works but is slow and is not what the image was built for.

- Do not run `playwright install` for that version. The browser is already here.
- Headless only. There is no display and only the headless shell is installed, so
  `headless: false` and `channel: 'chromium'` will not work.
- A spec and the dev server it drives both run inside this container, so `$CS193V_PORTS`
  does not limit what a test can reach. That list limits what the student's own browser can
  reach from outside. A test hitting `http://localhost:9999` is fine.

## Miscellaneous

- `sudo` works without a password.
