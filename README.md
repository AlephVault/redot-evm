# redot-evm
An implementation of EVM access in Redot, using a native implementation for non-web games, and using Metamask on web games.

## HTML5 exports

For web exports, add `addons/AlephVault.EVM/templates/html5/web3-head-include.html`
to the Web export preset's `Head Include` field, or copy it into a custom HTML
shell before the Godot engine starts.

The template initializes `window.web3 = new Web3(window.ethereum)` from an
injected EIP-1193 wallet provider so the web binding can access it through
Godot's `JavaScriptBridge`.
