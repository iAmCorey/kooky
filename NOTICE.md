# Third-party notices

kooky bundles or links the following third-party projects. Each retains its
upstream license; nothing here is dual-licensed under kooky's MIT.

## Bundled in the source tree

### Onest (font)
- Source: <https://github.com/google/fonts/tree/main/ofl/onest>
- Designer: Martín Sznaider, Indian Type Foundry
- License: SIL Open Font License 1.1
- File: `Sources/KookyKit/Resources/Fonts/Onest.ttf`

### JetBrains Mono (font)
- Source: <https://github.com/JetBrains/JetBrainsMono>
- License: SIL Open Font License 1.1
- File: `Sources/KookyKit/Resources/Fonts/JetBrainsMono-Regular.ttf`

### Shiki terminal theme palettes
- Source: <https://github.com/shikijs/shiki/tree/main/packages/themes>
- Package: `@shikijs/themes` 3.23.0
- License: MIT
- Use: background, foreground, cursor, selection, and 16-color ANSI tables in
-   `Sources/KookyKit/Resources/themes/` Ghostty theme files

Copyright (c) 2021 Pine Wu
Copyright (c) 2023 Anthony Fu <https://github.com/antfu>

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

### lobe-icons (brand PNGs)
- Source: <https://github.com/lobehub/lobe-icons>
- License: MIT
- Files: `Sources/KookyKit/Resources/Icons/{claudecode,codex,gemini,opencode,amp,cursor,githubcopilot,grok,antigravity,kimi,kiro}.png`

### Pi logo (brand PNG)
- Source: <https://pi.dev> (press kit)
- Owner: Earendil Inc.
- License: MIT
- File: `Sources/KookyKit/Resources/Icons/pi.png`

### Droid logo (brand PNG)
- Source: <https://factory.ai> (site favicon)
- Owner: Factory AI, Inc.
- File: `Sources/KookyKit/Resources/Icons/droid.png`

### Oh My Pi logo (brand PNG)
- Source: <https://omp.sh> (site favicon)
- Owner: <https://github.com/can1357/oh-my-pi> — MIT
- File: `Sources/KookyKit/Resources/Icons/omp.png`

### Reasonix logo (brand PNG)
- Source: <https://reasonix.io> (site favicon)
- Owner: <https://github.com/esengine/DeepSeek-Reasonix> — MIT
- File: `Sources/KookyKit/Resources/Icons/reasonix.png`

## Pulled at build time

### libghostty
- Source: <https://github.com/ghostty-org/ghostty>
- License: MIT
- Distribution: prebuilt `GhosttyKit.xcframework` fetched by `scripts/setup-libghostty.sh` into `Vendor/` (gitignored)
