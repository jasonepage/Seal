# Vendored code for the recipient page

One file, served from this site, never fetched from anywhere else.

| File | What | Version | License |
|---|---|---|---|
| `noble-mlkem.js` | ML-KEM-768 (`ml_kem768`), which browsers do not have built in | @noble/post-quantum 0.7.1 with @noble/hashes 2.4.0 | MIT, Paul Miller |

SHA-256 of `noble-mlkem.js`: `dd6fd2385eae1ad82b30b22fe960eefebdc6920b82db0b61f3c34cff568548c0`

Rebuild it to check, from an empty folder:

    npm install esbuild@0.25.10 @noble/post-quantum@0.7.1
    echo 'export { ml_kem768 } from "@noble/post-quantum/ml-kem.js";' > entry.js
    npx esbuild entry.js --bundle --format=esm --platform=neutral \
      --target=es2022 --legal-comments=inline --outfile=mlkem.js

`mlkem.js` should match `noble-mlkem.js` below its seven line header.
Everything else on the page is WebCrypto, which every current browser has.
