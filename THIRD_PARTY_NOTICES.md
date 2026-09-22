# Third-Party Notices

This file documents third-party software that is incorporated into or used by
official gPTP Studio distributions. It is informational and does not replace the
license terms that apply to each component.

## Glaze

Project: `turinglambdaai/glaze`

License: MIT

Copyright (c) 2025 turinglambdaai

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Racket CS runtime and Racket libraries

Official gPTP Studio builds use Racket CS. Racket is offered under the MIT
License or the Apache License, Version 2.0, at the recipient's option. For the
Racket code incorporated into gPTP Studio distributions, the Apache-2.0 option
is compatible with gPTP Studio's own Apache-2.0 distribution; the full Apache
License is included in this distribution as `LICENSE`.

Racket CS embeds Chez Scheme, which is licensed under Apache-2.0. Racket's
runtime also contains or derives from additional permissively licensed
components. The upstream Racket license notice identifies, among others:

- SHA-224/SHA-256 code from Mbed TLS — Apache-2.0; copyright 2006-2015 ARM
  Limited.
- Zlib — copyright 1995-2022 Jean-loup Gailly and Mark Adler.
- Chez Scheme terminal/expeditor support — Apache-2.0.
- startup-path code adapted from LLVM — Apache-2.0 with LLVM exceptions.

The authoritative Racket licensing inventory is maintained by the Racket
project in `LICENSE.txt` in the `racket/racket` source repository. Official
builds should be reviewed against that upstream file whenever the Racket major
or minor version is changed.

### Zlib notice

Copyright (C) 1995-2022 Jean-loup Gailly and Mark Adler

This software is provided 'as-is', without any express or implied warranty. In
no event will the authors be held liable for any damages arising from the use
of this software.

Permission is granted to anyone to use this software for any purpose, including
commercial applications, and to alter it and redistribute it freely, subject to
the following restrictions:

1. The origin of this software must not be misrepresented; you must not claim
   that you wrote the original software. If you use this software in a product,
   an acknowledgment in the product documentation would be appreciated but is
   not required.
2. Altered source versions must be plainly marked as such, and must not be
   misrepresented as being the original software.
3. This notice may not be removed or altered from any source distribution.

## System-provided dependencies

gPTP Studio's current packaging scripts do **not** copy the following projects
into the Linux tarball or macOS application bundle as application-owned
third-party payloads. They are discovered/used from the operating system or are
installed by the user/build environment:

- linuxptp (`ptp4l`, `phc2sys`, `pmc`)
- libpcap
- WebKitGTK on Linux / WebKit supplied by macOS
- OpenSSL command-line tools
- `ethtool`, `iproute2`, and Linux capability tools

If future packaging starts bundling any of these components, this notice and the
corresponding license payload must be updated before release.

## Distribution rule

Every official Linux/macOS package must contain, at minimum:

- `LICENSE`
- `NOTICE`
- `EULA.md`
- `THIRD_PARTY_NOTICES.md`

The CI packaging smoke tests enforce the presence of these files so license
notices cannot be accidentally dropped from a release artifact.
