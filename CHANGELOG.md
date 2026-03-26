# Changelog

## [0.11.2](https://github.com/gi11es/deckard/compare/v0.11.1...v0.11.2) (2026-03-26)


### Bug Fixes

* correct malformed sparkle:edSignature in appcast.xml ([df0e8fd](https://github.com/gi11es/deckard/commit/df0e8fd5d24c7fde816db64d1c33cfb9fc5f3c78))
* keep update feed stable while new release builds ([a4437c9](https://github.com/gi11es/deckard/commit/a4437c9fd321ec13b64d77c7ac5c5e6c5aa7569d))
* save settings text fields on focus loss and window close ([80983bd](https://github.com/gi11es/deckard/commit/80983bd8711a6fa804f17d01dc13452ac33cf28c))
* sync CFBundleVersion with marketing version for Sparkle updates ([1121dc9](https://github.com/gi11es/deckard/commit/1121dc98a2896952a50a01af255a7a708b1a63da))

## [0.11.1](https://github.com/gi11es/deckard/compare/v0.11.0...v0.11.1) (2026-03-26)


### Bug Fixes

* add TCC usage descriptions to prevent repeated file access prompts ([84d97aa](https://github.com/gi11es/deckard/commit/84d97aa69cb7897e8743ba8405f515fcd4ce81f0))
* make sidebar folder chevron clicks reliable ([4c489e8](https://github.com/gi11es/deckard/commit/4c489e8c79f49f2b449c825822387f30e10d9317))
* prevent sidebar rebuild from stealing focus during inline rename ([bff13dd](https://github.com/gi11es/deckard/commit/bff13ddb0c59dc0dc124df88754463296da1282a))
* skip Xcode signing during CI build, codesign in post-build step ([5ec315a](https://github.com/gi11es/deckard/commit/5ec315aa3b9c3947effcd2d5a2cafa704c8dfedf))

## [0.11.0](https://github.com/gi11es/deckard/compare/v0.10.0...v0.11.0) (2026-03-26)


### Features

* add code signing, notarization, and Sparkle auto-updates ([91ca24a](https://github.com/gi11es/deckard/commit/91ca24a7b965c5126367b7a5cde756361211d469))
* add optional sidebar vibrancy with translucent blur effect ([b5f31ff](https://github.com/gi11es/deckard/commit/b5f31ff778a7931ce8650e9b028d5180d2f4db82))


### Bug Fixes

* show 0% when quota reset time has passed ([a20adde](https://github.com/gi11es/deckard/commit/a20adde7f1c65a2bebca76ad37e69eabf7dd3786))

## [0.10.0](https://github.com/gi11es/deckard/compare/v0.9.0...v0.10.0) (2026-03-25)


### Features

* add quota usage widget to sidebar ([9a5843a](https://github.com/gi11es/deckard/commit/9a5843a75ff7c235ef7a167bf9df4605ed5ab4e4))


### Bug Fixes

* resolve SwiftLint violations in quota widget ([e4c4d28](https://github.com/gi11es/deckard/commit/e4c4d28e66ba2400f564ab1ac425cb67b3472fcc))
* tmux copy-on-drag with pbcopy and taller options field ([9d732b0](https://github.com/gi11es/deckard/commit/9d732b08b5a80c9dbd73d07186ee71317762f0f5))

## [0.9.0](https://github.com/gi11es/deckard/compare/v0.8.0...v0.9.0) (2026-03-25)


### Features

* editable tmux options in Settings &gt; Terminal ([481d601](https://github.com/gi11es/deckard/commit/481d601021fea2decdf9f22dc143a987dfb51e07))
* split status indicators into two side-by-side tables ([fcc002d](https://github.com/gi11es/deckard/commit/fcc002dd13b86e77322b6cdd31e46a277f03b736))


### Bug Fixes

* avoid duplicate tab numbers when creating new tabs ([b529d78](https://github.com/gi11es/deckard/commit/b529d78ccaeab1d4ad5400592fafe6ef1c419b64))
* copy text selection to clipboard in tmux terminals ([bd08cdc](https://github.com/gi11es/deckard/commit/bd08cdc448e0a41cb38a3689186ab08bc032efe7))
* dragging only item from folder into folder above stays in place ([4dc24cb](https://github.com/gi11es/deckard/commit/4dc24cbf0132ffcb7b9c5f918322224542a678ea))
* emoji and wide character rendering in tmux terminals ([21d252e](https://github.com/gi11es/deckard/commit/21d252e0f605ea5606534c8c492c7b500b762356))
* emoji and wide character rendering in tmux terminals ([3b0c019](https://github.com/gi11es/deckard/commit/3b0c0192d7c0c84651f30da37be6332e7a49634a))
* exit tmux copy mode when switching tabs ([2f34692](https://github.com/gi11es/deckard/commit/2f346921787537ae7c93740d2a25740fa0db9460))
* fixed settings window size (720x600) for all panes ([d3a114a](https://github.com/gi11es/deckard/commit/d3a114ae3524e4ba0a12d7fb2e78cc13020cd43f))
* keep text selection visible after mouse drag in tmux ([bb5a4c7](https://github.com/gi11es/deckard/commit/bb5a4c7638a80f12084db6ea9d83c987267efb50))
* keep text selection visible after mouse drag in tmux ([57e894d](https://github.com/gi11es/deckard/commit/57e894d6b254614f69354e2709eeacba2fbaebf6))
* lock settings window to 720x600 with contentMinSize/contentMaxSize ([b37a22e](https://github.com/gi11es/deckard/commit/b37a22efac686cfc7457a1aa6f77cc7cf2b00473))
* prevent settings window from shrinking when switching panes ([682feb9](https://github.com/gi11es/deckard/commit/682feb96097c677737407df928a02a245b88a811))
* replace NSTextView with NSTextField for tmux options ([0531045](https://github.com/gi11es/deckard/commit/05310453f06047725c0d6119d6b321345ad19477))
* restart terminal shell on process exit instead of removing the tab ([ffbb343](https://github.com/gi11es/deckard/commit/ffbb343b026736deb6a676a11cf4315444debf4b))
* revert custom tmux clipboard/selection bindings, keep emoji fixes ([25d4fc7](https://github.com/gi11es/deckard/commit/25d4fc7fb3b7f2115910fb538ea44e0caf09941f))
* settings panes lay out top-to-bottom, no vertical stretching ([b34d0c9](https://github.com/gi11es/deckard/commit/b34d0c96b12a2d8ee5ba40b2c58b8a34d3ef26c0))
* settings window size when switching panes ([79ff640](https://github.com/gi11es/deckard/commit/79ff640001356f7832cdadf4f0c4405ae5ad6828))
* settings window stays on screen when switching panes ([523b442](https://github.com/gi11es/deckard/commit/523b442be6d012aa8541e97cecd2cf06e1ffed24))

## [0.8.0](https://github.com/gi11es/deckard/compare/v0.7.1...v0.8.0) (2026-03-24)


### Features

* collapsible sidebar folders for organizing projects ([3b824dd](https://github.com/gi11es/deckard/commit/3b824ddc55f0d016b5803cd05fab2cd2aa16a07e))
* collapsible sidebar folders for organizing projects ([cf93305](https://github.com/gi11es/deckard/commit/cf93305ea4f99a8cc02a03120e5bc4fe0bcb0194))

## [0.7.1](https://github.com/gi11es/deckard/compare/v0.7.0...v0.7.1) (2026-03-23)


### Bug Fixes

* enable tmux mouse support for pane clicks and split dragging ([55f956f](https://github.com/gi11es/deckard/commit/55f956f2b8b17a4c8161562fa6df7c0e8e1fb373))
* mouse drag in tmux panes (pane resize and text selection) ([5864261](https://github.com/gi11es/deckard/commit/5864261cddc6415c730878c003f6dca2639d0ec1))
* restore file drag-and-drop into terminal tabs ([be4aa01](https://github.com/gi11es/deckard/commit/be4aa0111e11d94b467465b67233efcaf9adc133))

## [0.7.0](https://github.com/gi11es/deckard/compare/v0.6.0...v0.7.0) (2026-03-23)


### Features

* tmux session persistence for terminal tabs ([4cecd26](https://github.com/gi11es/deckard/commit/4cecd26e7a65fd0f02ae1825d21f7ddb74b23869))
* tmux session persistence for terminal tabs ([ce45484](https://github.com/gi11es/deckard/commit/ce45484eeae7b048bc70499018f0102c338186cd))


### Bug Fixes

* prevent context usage bar from flickering ([e293a40](https://github.com/gi11es/deckard/commit/e293a40a90cec35cabc9cfd1be8713d9bac56da6))
* prevent context usage bar from flickering in Claude tabs ([2a504a0](https://github.com/gi11es/deckard/commit/2a504a0c75c3f3f6cbb0b4f25fbec0934b7291e7))

## [0.6.0](https://github.com/gi11es/deckard/compare/v0.5.0...v0.6.0) (2026-03-23)


### Features

* configurable scrollback buffer (default 10,000 lines) ([a23de73](https://github.com/gi11es/deckard/commit/a23de73b08762b0c29a2bb17b4559690f699b9d9))


### Bug Fixes

* left-align General pane, fix Shortcuts column widths ([65b06f3](https://github.com/gi11es/deckard/commit/65b06f32bb0439181e8039b8d799faaf08f5ad21))
* read version from bundle instead of hardcoded string ([4ff5a1f](https://github.com/gi11es/deckard/commit/4ff5a1f7d2409d2d34276fb5c4903404adb9149b))
* use fixed pane heights in Settings to prevent window explosion ([e36ca77](https://github.com/gi11es/deckard/commit/e36ca77cb48eedb9cfbff92f6f5ec7b84e4c63a5))

## [0.5.0](https://github.com/gi11es/deckard/compare/v0.4.0...v0.5.0) (2026-03-23)


### Features

* add font picker with preview to Settings, widen settings window ([f481bcd](https://github.com/gi11es/deckard/commit/f481bcdecb1e2358da9ec5759113dea1b1c129f0))
* enable SwiftTerm Metal GPU renderer ([8b5d557](https://github.com/gi11es/deckard/commit/8b5d5571afa8872588abb59fedae630da2c471dc))
* replace theme picker table with 3-column grid of preview cards ([55f7b51](https://github.com/gi11es/deckard/commit/55f7b510e8a95fd4799f98cc0babb56dda250195))


### Bug Fixes

* add health check and auto-restart for control socket ([d015e15](https://github.com/gi11es/deckard/commit/d015e151dbc567d4a076b47879c4d85136b63acf))
* theme card previews now render colored terminal text ([e66911d](https://github.com/gi11es/deckard/commit/e66911d0b2a6eac4372ce89b876751adb94bfb36))
* use serial queue for control socket to prevent concurrent dictionary access ([32c5415](https://github.com/gi11es/deckard/commit/32c541540b13dcee482360a22d9e1a7526d68c4b))

## [0.4.0](https://github.com/gi11es/deckard/compare/v0.3.0...v0.4.0) (2026-03-22)


### Features

* add dynamic theme support to DeckardWindowController ([4054633](https://github.com/gi11es/deckard/commit/40546330656f8371d239ee68c9c34a04680ddb13))
* restore theme support with 485 Ghostty-format themes ([cbdbd99](https://github.com/gi11es/deckard/commit/cbdbd996a1d5e40daf606f4f816cd9a5e52b7b8e))


### Bug Fixes

* cancel dispatch source before closing client fd to prevent EV_VANISHED crash ([ecb511f](https://github.com/gi11es/deckard/commit/ecb511f357597340e9ad883774507ce01d8f28f4))

## [0.3.0](https://github.com/gi11es/deckard/compare/v0.2.0...v0.3.0) (2026-03-21)


### Features

* add crash reporter and startup diagnostic logging ([2cb04aa](https://github.com/gi11es/deckard/commit/2cb04aa99cb1feb5382ecf49dc948c57091d305b))
* migrate from libghostty to SwiftTerm ([a22158d](https://github.com/gi11es/deckard/commit/a22158dfceafbd15eb68250cc248408b9bd542d7))
* surface handling parity with Ghostty upstream ([37c16e9](https://github.com/gi11es/deckard/commit/37c16e9dbf0038670da2dde0abc2d7067f830910))


### Bug Fixes

* prevent deadlock and crashes from rapid tab creation ([3a78b15](https://github.com/gi11es/deckard/commit/3a78b15ab95e7dc48c647b6da0ce1a053da7206e))
* single-active-view model for terminal surfaces ([8fb7bec](https://github.com/gi11es/deckard/commit/8fb7becf8fd361389f607dc815dc778537e16036))

## [0.2.0](https://github.com/gi11es/deckard/compare/v0.1.9...v0.2.0) (2026-03-21)


### Features

* replace claude wrapper with persistent hooks configuration ([5e9c040](https://github.com/gi11es/deckard/commit/5e9c040c371fae78fe02ea69dc4dd2152e0e4405))


### Bug Fixes

* bypass login(1) via direct command execution ([ec3509d](https://github.com/gi11es/deckard/commit/ec3509d054e49c86b6c4dd800d4e3ad78465eec7))
* defer autosave until session restore completes ([2d1b71f](https://github.com/gi11es/deckard/commit/2d1b71f03f9af05e6fd6626e4da039fcdb10e307))
* dispatch ghostty surface calls off main thread to prevent deadlock ([255003e](https://github.com/gi11es/deckard/commit/255003e4ce032f74ac81f14e62c4f59ab1c7f373))
* drain surfaceQueue before freeing ghostty surface ([6ce3e2d](https://github.com/gi11es/deckard/commit/6ce3e2d954eb51bbaf06741e5cea45a0899ea4e2))
* prevent deadlock and crashes from rapid tab creation ([04d3568](https://github.com/gi11es/deckard/commit/04d35685b48402acd4f69668fd6ca78c21219318))
* rebuild sidebar when creating new tabs interactively ([517992d](https://github.com/gi11es/deckard/commit/517992defffb64d473ea3abc5f4d98ae770c8ab3))
* respect user's default shell for terminal tabs ([#15](https://github.com/gi11es/deckard/issues/15)) ([6760c3a](https://github.com/gi11es/deckard/commit/6760c3a9186d3ea99d2e938ea55261d0409f69ad))
* respect user's default shell for terminal tabs ([#15](https://github.com/gi11es/deckard/issues/15)) ([1cef76d](https://github.com/gi11es/deckard/commit/1cef76d7d03517c8a53a60a7d0fd267e46be6f00))
* respect user's default shell for terminal tabs ([#15](https://github.com/gi11es/deckard/issues/15)) ([f11fb9c](https://github.com/gi11es/deckard/commit/f11fb9c94743f2234bfe7636350bd9c5072f6de8))
* rewrite process monitor to use socket-based PID registration ([a29f58c](https://github.com/gi11es/deckard/commit/a29f58c0e0d4d171853af0178540df36ce633751))
* suppress "Last login" message via ghostty macos-hush-login option ([51a575b](https://github.com/gi11es/deckard/commit/51a575b6fe45a267b86c5ca511ccafb5a44a819a))
* sync sidebar dots when tabs are reordered ([e186d76](https://github.com/gi11es/deckard/commit/e186d76aa513aecda06f165f383e8024c34889bd))
* use Deckard's claude wrapper for hooks and activity detection ([43063c3](https://github.com/gi11es/deckard/commit/43063c323dde7c8743bae7cca96a5d52b3d96893))
* use register-pid script for shell-less tab spawning ([505d339](https://github.com/gi11es/deckard/commit/505d3394c3121270b709d60c330b6aa6a22d9ce5))
* use shell PID as activity tracking key instead of login PID ([b4ffa8f](https://github.com/gi11es/deckard/commit/b4ffa8fb6dbac51d3ad9d3d1432dcc9a55159a20))
* write hooks to settings.json without escaped slashes ([489e2bf](https://github.com/gi11es/deckard/commit/489e2bf4a9e2a7f09ac794e4c9dac69e526d5fb3))

## [0.1.9](https://github.com/gi11es/deckard/compare/v0.1.8...v0.1.9) (2026-03-19)


### Bug Fixes

* handle mouse visibility action for hide-while-typing ([f739da8](https://github.com/gi11es/deckard/commit/f739da8d7abacfc187a177379a378495059b2266))
* remove README from release-please extra-files ([236943c](https://github.com/gi11es/deckard/commit/236943cce8c442371aeab80f16398f308f165deb))
* use shields.io query-param format for README badge version ([afbb7c5](https://github.com/gi11es/deckard/commit/afbb7c5044e7e90856a003b32e91dcba912a0c70))
