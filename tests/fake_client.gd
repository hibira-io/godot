extends HibiraClient
# A HibiraClient whose socket is a list: frame() feeds a server frame in,
# sent holds what the client sent.

var sent: Array = []


func _send(message: Dictionary) -> bool:
	# Round-trip through JSON, as the wire does.
	sent.append(JSON.parse_string(JSON.stringify(message)))
	return true


func frame(event: String, data: Variant, channel_name := "", user_id := "") -> void:
	var msg := {"event": event, "data": JSON.stringify(data)}
	if channel_name != "":
		msg.channel = channel_name
	if user_id != "":
		msg.user_id = user_id
	_handle_message(JSON.stringify(msg))


func last(event: String) -> Variant:
	for i in range(sent.size() - 1, -1, -1):
		if sent[i].event == event:
			return sent[i]
	return null
