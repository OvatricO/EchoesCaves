extends Node
# Supabase client (REST + Auth) using HTTPRequest only. The publishable key is safe to ship (RLS protects the data).

const URL := "https://jpqmrorhfuqfplzsnvxq.supabase.co"
const KEY := "sb_publishable_74ilp4vPPjpDBhtsKJ8nmw_Ol3iU3RO"
const EMAIL_DOMAIN := "onevoice.game"


func _email(u: String) -> String:
	return u.to_lower() + "@" + EMAIL_DOMAIN


# returns {"status": int (0 = network error), "data": Variant}
func _request(method: int, path: String, body = null, token: String = "", extra: Array = []) -> Dictionary:
	var req := HTTPRequest.new()
	req.timeout = 10.0
	add_child(req)
	var headers := PackedStringArray(["apikey: " + KEY, "Content-Type: application/json"])
	if token != "":
		headers.append("Authorization: Bearer " + token)
	for h in extra:
		headers.append(str(h))
	var payload := ""
	if body != null:
		payload = JSON.stringify(body)
	if req.request(URL + path, headers, method, payload) != OK:
		req.queue_free()
		return {"status": 0, "data": null}
	var res: Array = await req.request_completed
	req.queue_free()
	var text: String = (res[3] as PackedByteArray).get_string_from_utf8()
	var parsed = JSON.parse_string(text) if text != "" else null
	var st := 0
	if int(res[0]) == HTTPRequest.RESULT_SUCCESS:
		st = int(res[1])
	return {"status": st, "data": parsed}


func _rpc(fn: String, body: Dictionary, token: String = "") -> Dictionary:
	var r: Dictionary = await _request(HTTPClient.METHOD_POST, "/rest/v1/rpc/" + fn, body, token)
	return r


func _msg(d) -> String:
	if d is Dictionary:
		for k in ["msg", "error_description", "message", "error"]:
			if d.has(k):
				return str(d[k])
	return ""


func _session(d: Dictionary, uname: String) -> Dictionary:
	return {
		"access_token": str(d.get("access_token", "")),
		"refresh_token": str(d.get("refresh_token", "")),
		"expires_in": int(d.get("expires_in", 3600)),
		"user_id": str((d.get("user", {}) as Dictionary).get("id", "")),
		"username": uname,
	}


# ---------------------------------------------------------------- auth

func sign_up(u: String, p: String) -> Dictionary:
	var free: Dictionary = await _rpc("username_free", {"u": u})
	if int(free["status"]) == 0:
		return {"error": "Can't reach the server. Check your internet."}
	if int(free["status"]) == 200 and free["data"] == false:
		return {"error": "Username already taken."}
	var r: Dictionary = await _request(HTTPClient.METHOD_POST, "/auth/v1/signup", {"email": _email(u), "password": p})
	var st := int(r["status"])
	if st == 0:
		return {"error": "Can't reach the server. Check your internet."}
	if st >= 400:
		var m := _msg(r["data"])
		if m.to_lower().contains("already"):
			return {"error": "Username already taken."}
		return {"error": m if m != "" else "Sign up failed."}
	var s := _session(r["data"], u)
	if s["access_token"] == "":
		return {"error": "Account created. Press Log In to continue."}
	var pr: Dictionary = await _request(HTTPClient.METHOD_POST, "/rest/v1/profiles", {"id": s["user_id"], "username": u}, s["access_token"], ["Prefer: return=minimal"])
	if int(pr["status"]) >= 400:
		return {"error": "Username already taken."}
	return s


func sign_in(u: String, p: String) -> Dictionary:
	var r: Dictionary = await _request(HTTPClient.METHOD_POST, "/auth/v1/token?grant_type=password", {"email": _email(u), "password": p})
	var st := int(r["status"])
	if st == 0:
		return {"error": "Can't reach the server. Check your internet."}
	if st >= 400:
		return {"error": "Wrong username or password."}
	var s := _session(r["data"], u)
	# canonical username from the profile (creates the profile if a past sign-up stopped halfway)
	var pr: Dictionary = await _request(HTTPClient.METHOD_GET, "/rest/v1/profiles?select=username&id=eq." + str(s["user_id"]), null, s["access_token"])
	if int(pr["status"]) == 200 and pr["data"] is Array and (pr["data"] as Array).size() > 0:
		s["username"] = str(pr["data"][0].get("username", u))
	elif int(pr["status"]) == 200:
		await _request(HTTPClient.METHOD_POST, "/rest/v1/profiles", {"id": s["user_id"], "username": u}, s["access_token"], ["Prefer: return=minimal"])
	return s


func refresh(rt: String) -> Dictionary:
	var r: Dictionary = await _request(HTTPClient.METHOD_POST, "/auth/v1/token?grant_type=refresh_token", {"refresh_token": rt})
	if int(r["status"]) != 200 or not (r["data"] is Dictionary):
		return {"error": "refresh failed"}
	return _session(r["data"], "")


# ---------------------------------------------------------------- rooms

# returns the 8-character code made by the server, or "" on failure
func create_room(token: String, ip: String, port: int) -> String:
	var r: Dictionary = await _rpc("create_room", {"p_ip": ip, "p_port": port}, token)
	if int(r["status"]) == 200 and r["data"] is String:
		return str(r["data"])
	return ""


# returns an Array of {ip, port, players} (empty = no such room) or null if the server could not be reached
func find_room(token: String, code: String) -> Variant:
	var r: Dictionary = await _rpc("find_room", {"p_code": code}, token)
	if int(r["status"]) == 200 and r["data"] is Array:
		return r["data"]
	return null


func heartbeat(token: String, code: String, players: int) -> void:
	await _rpc("room_heartbeat", {"p_code": code, "p_players": players}, token)


func delete_room(token: String, code: String) -> void:
	await _request(HTTPClient.METHOD_DELETE, "/rest/v1/rooms?code=eq." + code, null, token)
