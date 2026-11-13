extends Node
# Autoload: GameNet - connection, players, roles, local save data (coins + skins),
# local accounts (salted hash), room codes (host code / join code).

const PORT := 7777
const MAX_PLAYERS := 4
const WORLD_SCENE := "res://world.tscn"
const SAVE_PATH := "user://echoes_save.json"
const JOIN_TIMEOUT := 6.0

# Room code: 8 characters = 7 characters (the host IPv4, base-32) + 1 check character.
# 32 symbols: A-Z without I and O, and the digits 2-9 (no 0 / 1, so nothing looks alike).
const CODE_ALPHABET := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
const CODE_LEN := 8

signal players_changed
signal joined_server
signal join_failed(reason: String)      # "notfound" | "full" | "invalid" | "name" | "started"
signal player_left(id: int)
signal coins_changed
signal host_code_changed
signal account_changed

# peer_id -> {"name": String, "role": "lobby" | "carrier" | "guide", "pref": "blind" | "sighted"}
# "role" = the role currently played. "pref" = what the team agreed in the Role Changer (applied only when the run starts).
var players: Dictionary = {}
var my_name: String = "Player"
var in_game := false

# ---- local player data (saved on his machine) ----
var coins: int = 0
var owned_skins: Array = [0]
var equipped_skin: int = 0
var owned_pets: Array = []
var equipped_pet: String = ""

# ---- host code ----
var host_code := ""            # "" until the code is ready
var host_code_msg := ""        # status text shown under the code (port opened / failed ...)
var host_code_ok := false      # true = port opened automatically (UPnP)
var _code_token := 0
var _upnp: UPNP = null
var _upnp_thread: Thread = null
var _upnp_done := false
var _upnp_ok := false
var _upnp_ext := ""

# ---- online (Supabase) ----
var sb: Node
var access_token := ""
var refresh_token := ""
var user_id := ""
var token_expires := 0.0
var _room_code := ""

# ---- joining ----
var _join_pending := false
var _join_token := 0


func _ready() -> void:
	sb = preload("res://supabase.gd").new()
	add_child(sb)
	_register_inputs()
	_load_profile()
	_load_accounts()
	_load_servers()
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


func _exit_tree() -> void:
	_finish_upnp_thread()


# ---------------------------------------------------------------- input keys (registered in code)

func _register_inputs() -> void:
	_add_key("move_forward", KEY_W)
	_add_key("move_back", KEY_S)
	_add_key("move_left", KEY_A)
	_add_key("move_right", KEY_D)
	_add_key("jump", KEY_SPACE)
	_add_key("crouch", KEY_CTRL)
	_add_key("crouch", KEY_C)
	_add_key("interact", KEY_E)
	_add_key("flashlight", KEY_F)
	_add_key("throw", KEY_G)


func _add_key(action: String, keycode: Key) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	var ev := InputEventKey.new()
	ev.physical_keycode = keycode
	InputMap.action_add_event(action, ev)


# ---------------------------------------------------------------- save / load

func _load_save() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		return
	var data = JSON.parse_string(f.get_as_text())
	if data is Dictionary:
		coins = int(data.get("coins", coins))
		var o = data.get("owned", [0])
		owned_skins = []
		for v in o:
			owned_skins.append(int(v))
		if not owned_skins.has(0):
			owned_skins.append(0)
		equipped_skin = int(data.get("equipped", 0))
		owned_pets = []
		for v in data.get("pets", []):
			owned_pets.append(str(v))
		equipped_pet = str(data.get("pet", ""))
		if not owned_pets.has(equipped_pet):
			equipped_pet = ""
		if not owned_skins.has(equipped_skin):
			equipped_skin = 0


# ---------------------------------------------------------------- profile (old format, kept for compatibility)
const PROFILE_PATH := "user://profile.json"
const SERVERS_PATH := "user://servers.json"
var profile: Dictionary = {}          # {"name": String, "steam_id": String, "steam": bool}
var servers: Array = []               # each: {id, name, created, coins, owned, equipped, pets, pet}
var server_id := ""


# true = a player is logged in (the account replaced the old name-only profile)
func has_profile() -> bool:
	return current_account != ""


func _load_profile() -> void:
	if FileAccess.file_exists(PROFILE_PATH):
		var f := FileAccess.open(PROFILE_PATH, FileAccess.READ)
		var d = JSON.parse_string(f.get_as_text()) if f != null else null
		if d is Dictionary:
			profile = d
			my_name = _clean_name(str(profile.get("name", "Player")))


func save_profile(p_name: String, steam_id: String, steam: bool) -> void:
	profile = {"name": _clean_name(p_name), "steam_id": steam_id, "steam": steam}
	my_name = profile["name"]
	var f := FileAccess.open(PROFILE_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(profile))


# Steam is OPTIONAL. Needs the GodotSteam plugin + Steam running; never blocks play.
func steam_login() -> Dictionary:
	if not Engine.has_singleton("Steam"):
		return {"ok": false}
	var s = Engine.get_singleton("Steam")
	if s.has_method("steamInitEx"):
		s.steamInitEx()
	elif s.has_method("steamInit"):
		s.steamInit()
	if s.has_method("isSteamRunning") and not s.isSteamRunning():
		return {"ok": false}
	return {"ok": true, "name": str(s.getPersonaName()), "id": str(s.getSteamID())}


# ---------------------------------------------------------------- accounts (local, salted + hashed)
# user://account.json  ->  {"accounts": [{username, salt, hash, iter, created}], "current": "name"}
# The password is NEVER stored: only SHA-256 repeated HASH_ITERATIONS times over (salt + password).
#
# BACKEND LATER (Firebase / Supabase): only backend_username_free(), backend_register() and
# backend_login() below need to change. The menu only calls create_account() / login().
const ACCOUNT_PATH := "user://account.json"
const HASH_ITERATIONS := 20000
const USER_MIN := 3
const USER_MAX := 16
const PASS_MIN := 8
const PASS_MAX := 32

var accounts: Array = []
var current_account := ""
var legacy_name := ""          # name from an old profile.json (used to pre-fill the Create Account screen)


func _load_accounts() -> void:
	accounts = []
	current_account = ""
	if FileAccess.file_exists(ACCOUNT_PATH):
		var f := FileAccess.open(ACCOUNT_PATH, FileAccess.READ)
		var d = JSON.parse_string(f.get_as_text()) if f != null else null
		if d is Dictionary:
			var arr = d.get("accounts", [])
			if arr is Array:
				for a in arr:
					if a is Dictionary and str(a.get("username", "")) != "":
						accounts.append(a)
			current_account = str(d.get("current", ""))
			refresh_token = str(d.get("refresh_token", ""))
			user_id = str(d.get("user_id", ""))
	if current_account == "":
		refresh_token = ""
	if current_account != "":
		my_name = current_account
	elif accounts.is_empty() and str(profile.get("name", "")) != "":
		legacy_name = sanitize_username(str(profile.get("name", "")))


func _write_accounts() -> void:
	var f := FileAccess.open(ACCOUNT_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"accounts": accounts, "current": current_account, "refresh_token": refresh_token, "user_id": user_id}))


func _find_account(u: String) -> int:
	var low := u.to_lower()
	for i in range(accounts.size()):
		if str(accounts[i].get("username", "")).to_lower() == low:
			return i
	return -1


func last_username() -> String:
	if accounts.is_empty():
		return ""
	return str(accounts[accounts.size() - 1].get("username", ""))


func sanitize_username(n: String) -> String:
	var out := ""
	for i in range(n.length()):
		var c := n.unicode_at(i)
		if (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95:
			out += n[i]
		elif c == 32:
			out += "_"
	out = out.substr(0, USER_MAX)
	while out.length() < USER_MIN:
		out += "_"
	return out


# returns "" if the username is valid, else the error text
func validate_username(u: String) -> String:
	if u.length() < USER_MIN or u.length() > USER_MAX:
		return "Username must be %d-%d characters." % [USER_MIN, USER_MAX]
	for i in range(u.length()):
		var c := u.unicode_at(i)
		var ok := (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95
		if not ok:
			return "Only English letters, numbers and _ are allowed."
	return ""


func validate_password(p: String) -> String:
	if p.length() < PASS_MIN:
		return "Password must be at least %d characters." % PASS_MIN
	if p.length() > PASS_MAX:
		return "Password can't be longer than %d characters." % PASS_MAX
	return ""


# 0.0 .. 1.0 (length + variety of letters / digits / symbols)
func password_strength(p: String) -> float:
	if p == "":
		return 0.0
	var lower := false
	var upper := false
	var digit := false
	var symbol := false
	for i in range(p.length()):
		var c := p.unicode_at(i)
		if c >= 97 and c <= 122:
			lower = true
		elif c >= 65 and c <= 90:
			upper = true
		elif c >= 48 and c <= 57:
			digit = true
		else:
			symbol = true
	var kinds := int(lower) + int(upper) + int(digit) + int(symbol)
	var s := minf(float(p.length()) / 14.0, 1.0) * 0.6 + float(kinds) / 4.0 * 0.4
	if p.length() < PASS_MIN:
		s = minf(s, 0.3)
	return clampf(s, 0.0, 1.0)


func _hash_password(password: String, salt: String, iters: int) -> String:
	var h := (salt + ":" + password).sha256_text()
	for i in range(iters):
		h = (h + salt + password).sha256_text()
	return h


func _make_salt() -> String:
	return Crypto.new().generate_random_bytes(16).hex_encode()


# ---- backend hooks (local only for now) ----
func backend_username_free(_u: String) -> bool:
	return true          # later: ask Firebase / Supabase if the username already exists worldwide


func backend_register(_u: String, _salt: String, _hash: String) -> bool:
	return true          # later: store the account online


# returns "" on success, else the error text
func create_account(u: String, p: String) -> String:
	u = u.strip_edges()
	var e := validate_username(u)
	if e != "":
		return e
	e = validate_password(p)
	if e != "":
		return e
	var r: Dictionary = await sb.sign_up(u, p)        # the password is stored (hashed) by Supabase Auth
	if r.has("error"):
		return str(r["error"])
	_store_tokens(r)
	_apply_login(str(r["username"]))
	return ""


func login(u: String, p: String) -> String:
	u = u.strip_edges()
	var r: Dictionary = await sb.sign_in(u, p)
	if r.has("error"):
		return str(r["error"])
	_store_tokens(r)
	_apply_login(str(r["username"]))
	return ""


func _store_tokens(r: Dictionary) -> void:
	access_token = str(r.get("access_token", ""))
	refresh_token = str(r.get("refresh_token", refresh_token))
	user_id = str(r.get("user_id", user_id))
	token_expires = Time.get_unix_time_from_system() + float(r.get("expires_in", 3600))


# true if we have a valid online session (refreshes the token when needed)
func ensure_token() -> bool:
	if access_token != "" and Time.get_unix_time_from_system() < token_expires - 30.0:
		return true
	if refresh_token == "":
		return false
	var r: Dictionary = await sb.refresh(refresh_token)
	if r.has("error"):
		return false
	_store_tokens(r)
	_write_accounts()
	return true


func _apply_login(u: String) -> void:
	current_account = u
	my_name = u
	_write_accounts()
	save_profile(u, "", false)           # keeps profile.json in sync (old save format)
	account_changed.emit()


func logout() -> void:
	leave()
	current_account = ""
	access_token = ""
	refresh_token = ""
	user_id = ""
	_write_accounts()
	account_changed.emit()


# ---------------------------------------------------------------- servers (each one has its own coins / skins / pets)
func _load_servers() -> void:
	servers = []
	if FileAccess.file_exists(SERVERS_PATH):
		var f := FileAccess.open(SERVERS_PATH, FileAccess.READ)
		var d = JSON.parse_string(f.get_as_text()) if f != null else null
		if d is Array:
			servers = d


func _write_servers() -> void:
	var f := FileAccess.open(SERVERS_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(servers))


# a brand new server: everything starts from zero
func create_server() -> String:
	var rec := {
		"id": str(Time.get_unix_time_from_system()) + str(randi() % 1000),
		"name": "Server %d" % (servers.size() + 1),
		"created": Time.get_datetime_string_from_system(false, true),
		"coins": 0, "owned": [0], "equipped": 0, "pets": [], "pet": "",
	}
	servers.append(rec)
	_write_servers()
	select_server(rec["id"])
	return rec["id"]


func select_server(id: String) -> void:
	for rec in servers:
		if rec["id"] == id:
			server_id = id
			coins = int(rec.get("coins", 0))
			owned_skins = []
			for v in rec.get("owned", [0]):
				owned_skins.append(int(v))
			if not owned_skins.has(0):
				owned_skins.append(0)
			equipped_skin = int(rec.get("equipped", 0))
			if not owned_skins.has(equipped_skin):
				equipped_skin = 0
			owned_pets = []
			for v in rec.get("pets", []):
				owned_pets.append(str(v))
			equipped_pet = str(rec.get("pet", ""))
			if not owned_pets.has(equipped_pet):
				equipped_pet = ""
			return


func delete_server(id: String) -> void:
	for i in range(servers.size()):
		if servers[i]["id"] == id:
			servers.remove_at(i)
			break
	_write_servers()


func save_data() -> void:
	if server_id == "":
		create_server()         # started the world scene directly: use a fresh server
	for rec in servers:
		if rec["id"] == server_id:
			rec["coins"] = coins
			rec["owned"] = owned_skins
			rec["equipped"] = equipped_skin
			rec["pets"] = owned_pets
			rec["pet"] = equipped_pet
			rec["played"] = Time.get_datetime_string_from_system(false, true)
	_write_servers()


func add_coins(n: int) -> void:
	coins += n
	save_data()
	coins_changed.emit()


# returns true if the purchase worked
func buy_skin(idx: int, price: int) -> bool:
	if owned_skins.has(idx) or coins < price:
		return false
	coins -= price
	owned_skins.append(idx)
	save_data()
	coins_changed.emit()
	return true


func equip_skin(idx: int) -> void:
	if owned_skins.has(idx):
		equipped_skin = idx
		save_data()


# ---------------------------------------------------------------- room code (IPv4 <-> 8 characters)

func _checksum(vals: Array) -> int:
	var sum := 0
	for i in range(vals.size()):
		sum += int(vals[i]) * (i + 3)
	return sum % 32


# "203.0.113.7" -> "XXXXXXXX" ("" if the address is not a valid IPv4). One IP = one code, so no two hosts share a code.
func encode_code(ip: String) -> String:
	var parts := ip.strip_edges().split(".")
	if parts.size() != 4:
		return ""
	var n := 0
	for s in parts:
		if not s.is_valid_int():
			return ""
		var v := int(s)
		if v < 0 or v > 255:
			return ""
		n = (n << 8) | v
	var vals: Array = []
	for i in range(7):
		vals.append((n >> (5 * (6 - i))) & 31)
	var out := ""
	for v in vals:
		out += CODE_ALPHABET[int(v)]
	out += CODE_ALPHABET[_checksum(vals)]
	return out


# -> {"ok": bool, "ip": String, "port": int}
func decode_code(code: String) -> Dictionary:
	code = code.strip_edges().to_upper()
	if code.length() != CODE_LEN:
		return {"ok": false}
	var vals: Array = []
	for i in range(CODE_LEN):
		var idx := CODE_ALPHABET.find(code[i])
		if idx < 0:
			return {"ok": false}
		vals.append(idx)
	var chk: int = vals.pop_back()
	if _checksum(vals) != chk:
		return {"ok": false}
	var n := 0
	for v in vals:
		n = (n << 5) | int(v)
	if n <= 0 or n > 0xFFFFFFFF:
		return {"ok": false}
	var ip := "%d.%d.%d.%d" % [(n >> 24) & 255, (n >> 16) & 255, (n >> 8) & 255, n & 255]
	return {"ok": true, "ip": ip, "port": PORT}


# ---------------------------------------------------------------- host code: public IP + UPnP

func _upnp_work() -> void:        # runs in a thread (discover() blocks for a moment)
	var up := UPNP.new()
	var ok := false
	var ext := ""
	var found := false
	for attempt in range(2):                      # the router sometimes ignores the first request
		if up.discover(3000, 2) == UPNP.UPNP_RESULT_SUCCESS:
			found = true
			break
	if found:
		var gw := up.get_gateway()
		if gw != null and gw.is_valid_gateway():
			up.delete_port_mapping(PORT, "UDP")      # clear an old/stale mapping (conflict error)
			var r: int = up.add_port_mapping(PORT, PORT, "OneVoice", "UDP", 0)
			if r != UPNP.UPNP_RESULT_SUCCESS:        # many routers refuse lease 0 -> retry with 1 hour
				r = up.add_port_mapping(PORT, PORT, "OneVoice", "UDP", 3600)
			ok = (r == UPNP.UPNP_RESULT_SUCCESS)
			ext = up.query_external_address()
			_upnp = up
	call_deferred("_upnp_set", ok, ext)


func _upnp_set(ok: bool, ext: String) -> void:
	_upnp_ok = ok
	_upnp_ext = ext
	_upnp_done = true


func _finish_upnp_thread() -> void:
	if _upnp_thread != null and _upnp_thread.is_started():
		_upnp_thread.wait_to_finish()
	_upnp_thread = null


func _fetch_public_ip() -> String:
	# api.ipify.org first (as requested), then backups in case it is blocked / slow on this network
	for url in ["https://api.ipify.org", "https://checkip.amazonaws.com", "https://icanhazip.com", "https://ifconfig.me/ip", "http://api.ipify.org"]:
		var req := HTTPRequest.new()
		req.timeout = 4.0
		add_child(req)
		if req.request(url) != OK:
			req.queue_free()
			continue
		var res: Array = await req.request_completed
		req.queue_free()
		if int(res[0]) != HTTPRequest.RESULT_SUCCESS or int(res[1]) != 200:
			continue
		var ip: String = (res[3] as PackedByteArray).get_string_from_utf8().strip_edges()
		if encode_code(ip) != "" and not _is_private_ip(ip):
			return ip
	return ""


func _local_ip() -> String:
	var best := ""
	for a in IP.get_local_addresses():
		var s := str(a)
		if s.count(".") != 3 or s.begins_with("127.") or s.begins_with("169.254."):
			continue
		if s.begins_with("192.168.") or s.begins_with("10."):
			return s
		if s.begins_with("172."):
			var second := int(s.split(".")[1])
			if second >= 16 and second <= 31:
				return s
		if best == "":
			best = s
	return best


func _is_private_ip(s: String) -> bool:
	if s.begins_with("192.168.") or s.begins_with("10.") or s.begins_with("127."):
		return true
	if s.begins_with("172."):
		var second := int(s.split(".")[1])
		return second >= 16 and second <= 31
	return false


func _set_code(ip: String, msg: String, ok: bool) -> void:
	var tok := _code_token
	var code := ""
	if await ensure_token():
		code = await sb.create_room(access_token, ip, PORT)      # random code made by the server
	if tok != _code_token or multiplayer.multiplayer_peer == null:
		return
	if code != "":
		_room_code = code
		_heartbeat_loop(code, tok)
	else:
		code = encode_code(ip)                                   # offline fallback: the code encodes the IP
		msg += " (offline code)"
	host_code = code
	host_code_msg = msg
	host_code_ok = ok
	host_code_changed.emit()


func _heartbeat_loop(code: String, tok: int) -> void:
	while tok == _code_token and multiplayer.multiplayer_peer != null:
		await get_tree().create_timer(30.0).timeout
		if tok != _code_token or multiplayer.multiplayer_peer == null:
			return
		if await ensure_token():
			await sb.heartbeat(access_token, code, players.size())


# Join with a room code. Returns "" when the connection started (then wait for joined_server / join_failed),
# or a reason: "invalid" | "notfound" | "full" | "name" ...
func join_by_code(code: String) -> String:
	code = code.strip_edges().to_upper()
	if code.length() != CODE_LEN:
		return "invalid"
	for i in range(CODE_LEN):
		if CODE_ALPHABET.find(code[i]) < 0:
			return "invalid"
	var d: Dictionary = {}
	if await ensure_token():
		var rows = await sb.find_room(access_token, code)
		if rows is Array and (rows as Array).size() > 0:
			var row: Dictionary = rows[0]
			if int(row.get("players", 1)) >= MAX_PLAYERS:
				return "full"
			d = {"ok": true, "ip": str(row["ip"]), "port": int(row["port"])}
	if d.is_empty():
		d = decode_code(code)                                    # offline-code fallback
	if not bool(d.get("ok", false)):
		return "notfound"
	if join_game(str(d["ip"]), my_name, int(d["port"])) != OK:
		return "notfound"
	return ""


func _start_host_code() -> void:
	_code_token += 1
	var tok := _code_token
	host_code = ""
	host_code_ok = false
	host_code_msg = "Opening the room..."
	host_code_changed.emit()
	# Testing with two windows on ONE PC: start both with the launch argument  --local
	if OS.get_cmdline_args().has("--local") or OS.get_cmdline_user_args().has("--local"):
		_set_code("127.0.0.1", "Local test mode (--local): only windows on this PC can join.", true)
		return
	_finish_upnp_thread()
	_upnp_done = false
	_upnp_ok = false
	_upnp_ext = ""
	_upnp_thread = Thread.new()
	_upnp_thread.start(_upnp_work)
	var public_ip := await _fetch_public_ip()
	var waited := 0.0
	while not _upnp_done and waited < 14.0:
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	if _upnp_done:
		_finish_upnp_thread()
	if tok != _code_token or multiplayer.multiplayer_peer == null:
		return
	if public_ip == "" and _upnp_ext != "" and encode_code(_upnp_ext) != "" and not _is_private_ip(_upnp_ext):
		public_ip = _upnp_ext
	if public_ip != "":
		if _upnp_ok and _upnp_ext != "" and _upnp_ext != public_ip:
			_set_code(public_ip, "Your ISP uses CGNAT (shared IP): friends outside can't join. Use Radmin VPN / ZeroTier, or ask your ISP for a public IP.", false)
		elif _upnp_ok:
			_set_code(public_ip, "Port %d opened automatically. Friends anywhere can join." % PORT, true)
		else:
			_set_code(public_ip, "Couldn't open port %d automatically. Forward UDP %d on your router (or play on the same network / Radmin VPN)." % [PORT, PORT], false)
		return
	var lan := _local_ip()
	if lan != "":
		_set_code(lan, "No internet detected. This code works on your local network (LAN) only.", false)
	else:
		host_code_msg = "Couldn't create a room code (no network)."
		host_code_changed.emit()


# ---------------------------------------------------------------- connection

func host_game(player_name: String) -> Error:
	my_name = _clean_name(player_name)
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(PORT, MAX_PLAYERS + 4)      # the "full" check is done in register_player (so the joiner gets a clear message)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	in_game = false
	players = {1: {"name": my_name, "role": "lobby", "pref": "sighted"}}
	players_changed.emit()
	_start_host_code()
	return OK


# joins a host by IP. Fires joined_server on success, or join_failed(reason) (also after JOIN_TIMEOUT seconds).
func join_game(ip: String, player_name: String, port: int = PORT) -> Error:
	my_name = _clean_name(player_name)
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(ip.strip_edges(), port)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	players.clear()
	_join_pending = true
	_join_token += 1
	var tok := _join_token
	get_tree().create_timer(JOIN_TIMEOUT).timeout.connect(func():
		if _join_pending and tok == _join_token:
			_join_pending = false
			leave()
			join_failed.emit("notfound"))
	return OK


func leave() -> void:
	_join_pending = false
	_code_token += 1
	if _room_code != "":
		sb.delete_room(access_token, _room_code)       # free the code (fire and forget)
		_room_code = ""
	if _upnp != null:
		_upnp.delete_port_mapping(PORT, "UDP")
		_upnp = null
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	players.clear()
	in_game = false
	if host_code != "" or host_code_msg != "":
		host_code = ""
		host_code_msg = ""
		host_code_ok = false
		host_code_changed.emit()


# if world.tscn is started alone from the editor (F6)
func ensure_offline_session() -> void:
	if players.is_empty():
		players = {1: {"name": my_name, "role": "lobby", "pref": "sighted"}}


func has_other_peers() -> bool:
	return not multiplayer.get_peers().is_empty()


func my_id() -> int:
	if multiplayer.multiplayer_peer == null:
		return 1
	return multiplayer.get_unique_id()


func _clean_name(n: String) -> String:
	n = n.strip_edges()
	return n if n != "" else "Player"


func name_in_use(n: String) -> bool:
	var low := n.to_lower()
	for pid in players.keys():
		if str(players[pid].get("name", "")).to_lower() == low:
			return true
	return false


# ---------------------------------------------------------------- player registration

func _on_connected_to_server() -> void:
	register_player.rpc_id(1, my_name)


func _on_connection_failed() -> void:
	var was_joining := _join_pending
	leave()
	if was_joining or true:
		join_failed.emit("notfound")


func _on_peer_connected(_id: int) -> void:
	pass          # nothing here: the host checks the room (full / started / name) in register_player()


func _on_peer_disconnected(id: int) -> void:
	if not multiplayer.is_server():
		return
	if players.has(id):
		players.erase(id)
		_ensure_one_blind()
		player_left.emit(id)
		_broadcast_players()


func _on_server_disconnected() -> void:
	if _join_pending:
		leave()
		join_failed.emit("notfound")
		return
	leave()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().change_scene_to_file("res://menu.tscn")


@rpc("any_peer", "reliable")
func register_player(player_name: String) -> void:
	if not multiplayer.is_server():
		return
	var id := multiplayer.get_remote_sender_id()
	if players.has(id):
		return
	var nm := _clean_name(player_name)
	if in_game:
		_reject(id, "started")
		return
	if players.size() >= MAX_PLAYERS:
		_reject(id, "full")
		return
	if name_in_use(nm):
		_reject(id, "name")
		return
	players[id] = {"name": nm, "role": "lobby", "pref": "sighted"}
	_ensure_one_blind()
	_broadcast_players()


func _reject(id: int, reason: String) -> void:
	rpc_join_rejected.rpc_id(id, reason)
	await get_tree().create_timer(0.4).timeout
	if multiplayer.multiplayer_peer != null and multiplayer.is_server():
		multiplayer.multiplayer_peer.disconnect_peer(id)


@rpc("authority", "reliable")
func rpc_join_rejected(reason: String) -> void:
	_join_pending = false
	call_deferred("_finish_rejected", reason)


func _finish_rejected(reason: String) -> void:
	leave()
	join_failed.emit(reason)


func _broadcast_players() -> void:
	players_changed.emit()
	if has_other_peers():
		sync_players.rpc(players)


@rpc("authority", "reliable")
func sync_players(p: Dictionary) -> void:
	var first := players.is_empty()
	for id in players.keys():
		if not p.has(id):
			player_left.emit(id)
	players = p
	players_changed.emit()
	if first:
		_join_pending = false
		joined_server.emit()


# the host changes the roles and sends them to everybody
func set_roles(roles: Dictionary) -> void:
	for id in roles.keys():
		if players.has(id):
			players[id]["role"] = roles[id]
	_broadcast_players()


# ---------------------------------------------------------------- Role Changer (Blind / Sighted)
# Exactly ONE player is always "blind". The choice is only a preference: the world applies it
# when the yellow portal starts Cave 1.

func blind_id() -> int:
	for id in players.keys():
		if players[id].get("pref", "sighted") == "blind":
			return id
	return -1


# server only: guarantees exactly one blind player (keeps the existing one, else the lowest id)
func _ensure_one_blind() -> void:
	if players.size() < 2:
		for id in players.keys():
			players[id]["pref"] = "sighted"      # solo: a bot is the blind one (see world.gd)
		return
	var blind_ids: Array = []
	for id in players.keys():
		if players[id].get("pref", "sighted") == "blind":
			blind_ids.append(id)
	blind_ids.sort()
	var keep := -1
	if not blind_ids.is_empty():
		keep = blind_ids[0]
	else:
		var ids: Array = players.keys()
		ids.sort()
		if not ids.is_empty():
			keep = ids[ids.size() - 1]       # the host stays sighted, a joiner becomes blind
	for id in players.keys():
		players[id]["pref"] = "blind" if id == keep else "sighted"


# any player can call this: makes `id` the blind player (everyone else becomes sighted)
func request_blind(id: int) -> void:
	if multiplayer.is_server():
		_server_set_blind(id)
	else:
		rpc_request_blind.rpc_id(1, id)


func _server_set_blind(id: int) -> void:
	if in_game or not players.has(id):
		return
	for pid in players.keys():
		players[pid]["pref"] = "blind" if pid == id else "sighted"
	_broadcast_players()


@rpc("any_peer", "reliable")
func rpc_request_blind(id: int) -> void:
	if multiplayer.is_server():
		_server_set_blind(id)


# ---- pets ----
func buy_pet(id: String, price: int) -> bool:
	if owned_pets.has(id) or coins < price:
		return false
	coins -= price
	owned_pets.append(id)
	save_data()
	coins_changed.emit()
	return true


# id "" = no pet
func equip_pet(id: String) -> void:
	if id == "" or owned_pets.has(id):
		equipped_pet = id
		save_data()
