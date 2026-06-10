extends RefCounted
## This is the implementation stub of a Web3 client for EVM networks.
## In web games, this hits an EIP-1193 wallet wrapped into window.web3
## (Web3, from web3js library). In non-web games, a custom binding is
## used instead.
##
## The surface methods are defined here, and they're redirected to the
## underlying respective binding immediately.

static var _binding_class: Script = null

static func _get_binding_class() -> Script:
	if _binding_class != null:
		return _binding_class

	if OS.has_feature("web"):
		return load("./bindings/web/index.gd")
	else:
		return load("./bindings/native/index.gd")
