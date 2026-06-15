extends RefCounted
## Tracks a JavaScript Promise processed by alephVaultEvmProcessAsync.
##
## This is web-only glue for JavaScriptBridge. It sends a JavaScript expression
## to the HTML-side async processor and exposes the settled result as a standard
## {ok, value|error} dictionary.

const Async = preload("../../../utils/async.gd")

## Emitted once when the JavaScript promise settles.
##
## The result follows the standard AlephVault.EVM response format:
## {"ok": true, "value": Variant} or {"ok": false, "error": Variant}.
signal completed(result: Dictionary)

## The request id assigned by window.alephVaultEvmProcessAsync.
##
## It is 0 until the JavaScript-side async processor accepts the promise.
var id: int = 0

## The settled response.
##
## This is empty until the promise settles or a setup error occurs.
var result: Dictionary = {}

## Whether this request has already completed.
var is_completed: bool = false

var _callback = null

## Creates and starts an AsyncRequest from a JavaScript promise expression.
##
## The expression is evaluated by the HTML helper, so Promise objects do not need
## to cross the JavaScriptBridge boundary. The returned AsyncRequest can be awaited with:
##
## var response = await AsyncRequest.process(expression).wait()
static func process(promise_expression: String):
	var request = new()
	return request.start(promise_expression)

## Starts tracking a JavaScript promise expression.
##
## On success, registers the expression in window.alephVaultEvmProcessExpression
## and returns self immediately. On setup failure, returns self already scheduled
## to complete with an error such as "not_web", "missing_async_processor", or
## "invalid_request".
func start(promise_expression: String):
	if not OS.has_feature("web"):
		_complete_deferred(Async.failed("not_web"))
		return self

	_callback = JavaScriptBridge.create_callback(_on_completed)

	if not JavaScriptBridge.eval("typeof window.alephVaultEvmProcessExpression === 'function'", true):
		_complete_deferred(Async.failed("missing_async_processor"))
		return self

	var window = JavaScriptBridge.get_interface("window")
	id = int(window.alephVaultEvmProcessExpression(promise_expression, _callback))
	if id <= 0:
		_complete_deferred(Async.failed("invalid_request"))

	return self

## Waits until the tracked promise settles and returns the standard response.
##
## If the request has already completed, this returns the cached result without
## yielding. Otherwise, it awaits the completed signal.
func wait():
	if is_completed:
		return result

	return await completed

func _on_completed(args: Array):
	if args.size() < 1 or not (args[0] is String):
		_complete(Async.failed("invalid_response"))
		return

	var parsed = JSON.parse_string(args[0])
	if not (parsed is Dictionary):
		_complete(Async.failed("invalid_response"))
		return

	var response: Dictionary = parsed
	if int(response.get("id", 0)) != id:
		_complete(Async.failed("invalid_response"))
		return

	response.erase("id")
	_complete(response)

func _complete_deferred(next_result: Dictionary):
	result = next_result
	is_completed = true
	call_deferred("_emit_completed")

func _complete(next_result: Dictionary):
	if is_completed:
		return

	result = next_result
	is_completed = true
	_callback = null
	_emit_completed()

func _emit_completed():
	completed.emit(result)
