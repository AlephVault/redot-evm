extends RefCounted
## This is the implementation stub of a Web3 client for EVM networks.
## In web games, this hits an EIP-1193 wallet wrapped into window.web3
## (Web3, from web3js library). In non-web games, a custom binding is
## used instead.
##
## The surface methods are defined here, and they're redirected to the
## underlying respective binding immediately.

# The binding class. While a game is running, only a binding class will
# be used for all the instances. This depends on whether the platform
# is web (then, an EIP-1193-enabled binding will be used) or one of the
# native formats (desktop or mobile).
static var _binding_class: Script = null

static func _create_binding() -> Script:
	if _binding_class != null:
		_binding_class = _binding_class

	if OS.has_feature("web"):
		_binding_class = load("./bindings/web/index.gd")
	else:
		_binding_class = load("./bindings/native/index.gd")

	return _binding_class.new()

# The binding for this facade in particular.
var _binding = null

def _init():
	_binding = _binding_class.new()
