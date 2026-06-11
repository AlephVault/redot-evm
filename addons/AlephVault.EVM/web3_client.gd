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

static func _create_binding() -> Object:
	if _binding_class == null:
		if OS.has_feature("web"):
			_binding_class = load("./bindings/web/index.gd")
		else:
			_binding_class = load("./bindings/native/index.gd")

	return _binding_class.new()

# The binding for this facade in particular.
var _binding = null

func _init():
	_binding = _create_binding()

# The bindings need to implement the following methods:
#
# 1. (asynchronous) initialize(Callable) returning:
#    - {"ok": true, value: Array[String]}
#      Where value is the array of addresses that belong to valid
#      accounts, configured in the current game (native) or allowed
#      when connecting to the page's domain (web).
#    - {"ok": false, error: String}
#      Where error is an error code. Typically: "user_rejected".
#      Most likely, no other code is needed here.
#
# 2. (asynchronous) get_chain_id() returning:
#    - {"ok": true, value: int}
#      Where value is the id of the current chain. It will be
#      0 if this client is not connected to any chain.
#    - {"ok": false, error: String}
#      Where error is an error code. Typically: "not_ready". This
#      means this client is not ready yet. Another possible option
#      is "no_valid_chains", telling that no chain is actually
#      configured.
#
# 3. (asynchronous) set_chain_id(chain_id: int) returning:
#    - {"ok": true, value: null}
#    - {"ok": false, error: String}
#      Where error is an error code. Typically: "not_ready". This
#      means this client is not ready yet. Another possible option
#      is "invalid_chain", meaning that either the ID is invalid
#      or does not belong to a configured chain.

## Initializes the binding. Each binding has a different way to do
## the initialization. This method is the FIRST THING TO CALL and
## tells the accounts that are allowed and ready in the binding.
##
## - Web bindings will do it directly against the EIP-1193 wallet.
##   When the wallet is ready (the web3 instance), then this call
##   will resolve successfully.
## - Native bindings will make use of a given node in `obj`. The
##   callback will typically resolve the involved accounts and
##   whatever data is needed (e.g. their private keys, to be used
##   inside the binding).
func initialize(callback: Callable):
	return _binding.initialize(callback)

## Returns the chain id for this binding. A binding is connected
## to a single chain id at a given time, and that chain id may
## change later.
func get_chain_id():
	return _binding.get_chain_id()

## Sets the chain id for this binding. A binding is connected to
## a single chain id at a given time, and that chain id may
## change later.
func set_chain_id(chain_id: int):
	return _binding.set_chain_id(chain_id)
