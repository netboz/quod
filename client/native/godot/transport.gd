class_name QuodTransport
extends Node
## One session's cancellable HTTPS requests. No retry or redirect to a new origin.

var endpoint := ""
var ca: X509Certificate
var certificate_name := ""
var active: Array[HTTPRequest] = []
var revision := 0
var request_count := 0

func configure(address: String, port: int, ca_path: String, tls_name := "") -> String:
	cancel()
	endpoint = ""
	ca = null
	certificate_name = ""
	var result := origin(address, port)
	if not result.ok:
		return result.error
	if not tls_name.is_empty():
		if ca_path.is_empty() or not origin(tls_name, 443).ok:
			return "A certificate name requires a trusted certificate file and a valid hostname or IP address."
		certificate_name = tls_name.strip_edges()
	if not ca_path.is_empty():
		ca = X509Certificate.new()
		if ca.load(ca_path) != OK:
			return "Cannot load the selected CA certificate."
	endpoint = result.value
	return ""

static func origin(address: String, port: int) -> Dictionary:
	var host := address.strip_edges()
	if port < 1 or port > 65535:
		return {"ok": false, "error": "Port must be between 1 and 65535."}
	if host.begins_with("[") and host.ends_with("]"):
		host = host.substr(1, host.length() - 2)
	if host.contains(":"):
		if not host.is_valid_ip_address():
			return {"ok": false, "error": "Enter a node address; specify its port in the separate field."}
		host = "[" + host + "]"
	else:
		var dns := RegEx.new()
		dns.compile("^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$")
		if dns.search(host) == null or host.contains(".."):
			return {"ok": false, "error": "Enter a hostname, IPv4 address or IPv6 address, without a URL path."}
	return {"ok": true, "value": "https://%s:%d" % [host, port]}

func cancel() -> void:
	revision += 1
	for request in active.duplicate():
		request.cancel_request()
		# Resolve suspended callers too; cancellation cannot leave a loading task alive.
		request.request_completed.emit(HTTPRequest.RESULT_REQUEST_FAILED, 0, PackedStringArray(), PackedByteArray())
	active.clear()

func fetch(path: String, body: Variant = null, maximum: int = -1, deadline_ms: int = 0) -> Dictionary:
	if endpoint.is_empty() or not path.begins_with("/") or path.begins_with("//"):
		return {"ok": false, "error": "Server connection is not configured."}
	var version := revision
	var request := HTTPRequest.new()
	request.use_threads = true
	request.max_redirects = 0
	request.body_size_limit = maximum
	var now_ms := int(Time.get_unix_time_from_system() * 1000)
	var remaining := deadline_ms - now_ms if deadline_ms else 30000
	if remaining <= 0:
		request.free()
		return {"ok": false, "error": "Request deadline expired."}
	request.timeout = float(remaining) / 1000.0
	if ca:
		request.set_tls_options(TLSOptions.client(ca, certificate_name))
	add_child(request)
	active.append(request)
	request_count += 1
	var headers := PackedStringArray(["Content-Type: application/json"]) if body != null else PackedStringArray()
	var method := HTTPClient.METHOD_POST if body != null else HTTPClient.METHOD_GET
	var error := request.request(endpoint + path, headers, method, JSON.stringify(body) if body != null else "")
	if error != OK:
		active.erase(request)
		request.queue_free()
		return {"ok": false, "error": "Cannot start request: " + error_string(error)}
	var response: Array = await request.request_completed
	active.erase(request)
	request.queue_free()
	if version != revision:
		return {"ok": false, "error": "Request cancelled."}
	if response[0] != HTTPRequest.RESULT_SUCCESS:
		return {"ok": false, "error": "Connection, TLS, deadline or response-size failure (%s)." % response[0]}
	if response[1] < 200 or response[1] >= 300:
		return {"ok": false, "error": "Server returned HTTP %s." % response[1], "status": response[1], "value": response[3]}
	return {"ok": true, "value": response[3]}

func post(path: String, body: Dictionary, deadline_ms: int = 0) -> Dictionary:
	var response := await fetch(path, body, -1, deadline_ms)
	if not response.ok:
		if response.has("status"):
			var refusal: Variant = JSON.parse_string(response.value.get_string_from_utf8())
			if refusal is Dictionary and refusal.get("error") is String:
				response.error = refusal.error
				response.rejected = true
		return response
	var decoded: Variant = JSON.parse_string(response.value.get_string_from_utf8())
	if not decoded is Dictionary:
		return {"ok": false, "error": "Malformed server response."}
	return {"ok": true, "value": decoded}
