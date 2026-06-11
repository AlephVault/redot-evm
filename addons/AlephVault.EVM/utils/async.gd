extends Object

## Creates a standard successful response.
static func success(value: Variant) -> Dictionary:
	return {"ok": true, "value": value}

## Creates a standard failed response.
static func failed(error: Variant) -> Dictionary:
	return {"ok": false, "error": error}
