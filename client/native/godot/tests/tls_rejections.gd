extends SceneTree
## Negative handshakes keep their expected engine diagnostics in the test log.
func _initialize() -> void:
	create_timer(15.0).timeout.connect(func(): push_error("TLS rejection test deadline"); quit(1))
	run.call_deferred()

func run() -> void:
	var transport := QuodTransport.new()
	root.add_child(transport)
	var cert := OS.get_environment("QUOD_FIXTURE_CA")
	var port := int(OS.get_environment("QUOD_FIXTURE_PORT"))
	var crypto := Crypto.new()
	var unrelated := crypto.generate_self_signed_certificate(crypto.generate_rsa(2048), "CN=localhost,O=Quod test")
	var wrong_cert := cert + "-wrong.pem"
	if unrelated == null or unrelated.save(wrong_cert) != OK:
		push_error("Cannot prepare unrelated test certificate")
		quit(1)
		return
	for test_case in [[cert, "wrong.example"], [wrong_cert, "localhost"]]:
		if not transport.configure("127.0.0.1", port, test_case[0], test_case[1]).is_empty():
			push_error("Cannot configure TLS rejection test")
			quit(1)
			return
		var response := await transport.fetch("/api/ontologies/system")
		if response.ok or not response.error.ends_with("(%s)." % HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR):
			push_error("Expected a TLS handshake rejection, got " + str(response))
			quit(1)
			return
	print("TLS_REJECTIONS_PASS wrong-name and unrelated-certificate rejected")
	quit()
